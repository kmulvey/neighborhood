//! Memberlist state machine — the pure, caller-driven SWIM membership core.
//!
//! No threads, no sockets, no I/O.  The caller drives time via `tick(now)`,
//! feeds incoming packets via `handlePacket(...)`, and executes the returned
//! `Action` list.

const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const suspicion_mod = @import("suspicion.zig");

const Config = config_mod.Config;
const Node = types.Node;
const NodeState = types.NodeState;
const Incarnation = types.Incarnation;
const Address = types.Address;
const MessageType = types.MessageType;
const Action = types.Action;
const ActionTag = types.ActionTag;
const Suspicion = suspicion_mod.Suspicion;

const NodeEntry = struct {
    node: Node,
    last_heard_ms: i64,
};

const ProbeState = enum {
    idle,
    waiting_direct,
    waiting_indirect,
};

pub const Memberlist = struct {
    allocator: std.mem.Allocator,
    config: Config,

    nodes: std.ArrayListUnmanaged(NodeEntry),
    name_to_index: std.StringHashMapUnmanaged(usize),
    incarnation: Incarnation,
    seqno: u32,
    probe_index: usize,
    probe_state: ProbeState,
    probe_seqno: u32,
    indirect_peers: [3]usize,
    indirect_ack_count: u8,
    probe_start_ms: i64,
    /// Absolute deadline (ms) by which all indirect probes must be answered.
    indirect_deadline_ms: i64,
    /// Map of node_name → Suspicion for nodes currently in .suspect state.
    suspicions: std.StringHashMapUnmanaged(Suspicion),
    leaving: bool,
    shutdown: bool,
    join_order: std.ArrayListUnmanaged(usize),
    self_name: []const u8,
    self_index: usize,
    protocol_period_ms: i64,
    indirect_timeout_ms: i64,
    /// Counts ticks since last join_order reshuffle.
    tick_count: u64,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Memberlist {
        var nodes: std.ArrayListUnmanaged(NodeEntry) = .empty;
        var name_to_index: std.StringHashMapUnmanaged(usize) = .{};

        const self_addr = try Address.parseIp4(config.bind_addr, config.bind_port);
        const self_name = try allocator.dupe(u8, config.name);

        try nodes.append(allocator, .{ .node = .{
            .name = self_name, .addr = self_addr, .incarnation = 0,
            .state = .alive, .protocol_version = config.protocol_version,
        }, .last_heard_ms = 0 });
        try name_to_index.put(allocator, self_name, 0);

        var join_order: std.ArrayListUnmanaged(usize) = .empty;
        try join_order.append(allocator, 0);

        return Memberlist{
            .allocator = allocator, .config = config,
            .nodes = nodes, .name_to_index = name_to_index,
            .incarnation = 0, .seqno = 1,
            .probe_index = 0, .probe_state = .idle, .probe_seqno = 0,
            .indirect_peers = [_]usize{0} ** 3,
            .indirect_ack_count = 0,
            .probe_start_ms = 0, .indirect_deadline_ms = 0,
            .suspicions = .{},
            .leaving = false, .shutdown = false,
            .join_order = join_order,
            .self_name = self_name, .self_index = 0,
            .protocol_period_ms = @intCast(config.protocol_period_ms),
            .indirect_timeout_ms = @intCast(config.protocol_period_ms),
            .tick_count = 0,
        };
    }

    pub fn deinit(self: *Memberlist) void {
        for (self.nodes.items) |*entry| self.allocator.free(entry.node.name);
        self.nodes.deinit(self.allocator);
        self.name_to_index.deinit(self.allocator);
        // Free suspicion timers.
        var sit = self.suspicions.iterator();
        while (sit.next()) |entry| {
            var s = entry.value_ptr;
            s.deinit(self.allocator);
        }
        self.suspicions.deinit(self.allocator);
        self.join_order.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nodeCount(self: *const Memberlist) usize {
        return self.nodes.items.len;
    }

    pub fn aliveNodes(self: *const Memberlist, alloc: std.mem.Allocator) ![]Node {
        var list: std.ArrayListUnmanaged(Node) = .empty;
        for (self.nodes.items) |entry| {
            if (entry.node.state == .alive) try list.append(alloc, entry.node);
        }
        return list.toOwnedSlice(alloc);
    }

    /// Drive the protocol forward one step. Returns owned slice of actions.
    pub fn tick(self: *Memberlist, now_ms: i64, alloc: std.mem.Allocator) ![]Action {
        if (self.shutdown) return &[_]Action{};
        var actions: std.ArrayListUnmanaged(Action) = .empty;

        // ---- B3: expire suspicion timers ----
        // Collect keys of expired suspicions (must dup because the iterator
        // borrows from the map and we can't remove while iterating).
        var expired: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (expired.items) |k| self.allocator.free(k);
            expired.deinit(self.allocator);
        }

        var sit = self.suspicions.iterator();
        while (sit.next()) |entry| {
            if (entry.value_ptr.remainingMs(now_ms) <= 0) {
                const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(key_copy);
                try expired.append(self.allocator, key_copy);
                // Look up the node index to emit node_failed.
                if (self.name_to_index.get(entry.key_ptr.*)) |idx| {
                    var target = &self.nodes.items[idx];
                    if (target.node.state == .suspect) {
                        target.node.state = .dead;
                        target.last_heard_ms = now_ms;
                        try actions.append(alloc, .{ .node_failed = .{
                            .node = try alloc.dupe(u8, target.node.name), .addr = target.node.addr,
                        } });
                        // Encode a Dead message for gossip dissemination.
                        var dead_buf: [512]u8 = undefined;
                        const dead_msg = types.Dead{
                            .node = target.node.name,
                            .addr = target.node.addr,
                            .incarnation = target.node.incarnation,
                            .from = self.self_name,
                        };
                        const dead_n = try protocol.encodeDead(&dead_buf, dead_msg);
                        const dead_payload = try alloc.alloc(u8, dead_n);
                        errdefer alloc.free(dead_payload);
                        @memcpy(dead_payload, dead_buf[0..dead_n]);
                        try actions.append(alloc, .{ .send_gossip = .{
                            .target_addrs = &.{},
                            .payload = dead_payload,
                        } });
                    }
                }
            }
        }
        // Remove expired suspicions by exact key match.
        for (expired.items) |key_copy| {
            if (self.suspicions.getPtr(key_copy)) |s| {
                s.deinit(self.allocator);
                _ = self.suspicions.remove(key_copy);
            }
        }

        // ---- Probe state machine ----
        switch (self.probe_state) {
            .idle => {
                self.tick_count += 1;
                if (self.nodes.items.len <= 1) return actions.toOwnedSlice(alloc);
                if (self.join_order.items.len <= 1) return actions.toOwnedSlice(alloc);

                // Round-robin: advance index.
                self.probe_index = (self.probe_index + 1) % self.join_order.items.len;

                // B4: reshuffle + compact on wrap-around.
                if (self.probe_index == 0 and self.tick_count > 1) {
                    try self.reshuffleJoinOrder(now_ms, alloc);
                }

                const node_idx = self.join_order.items[self.probe_index];
                if (node_idx == self.self_index) return actions.toOwnedSlice(alloc);
                const target = self.nodes.items[node_idx];
                if (target.node.state == .dead or target.node.state == .left) return actions.toOwnedSlice(alloc);

                self.probe_seqno = self.seqno;
                self.seqno += 1;
                self.probe_state = .waiting_direct;
                self.probe_start_ms = now_ms;
                try actions.append(alloc, .{ .send_ping = .{
                    .target = try alloc.dupe(u8, target.node.name), .target_addr = target.node.addr, .seqno = self.probe_seqno,
                } });
            },
            .waiting_direct => {
                if (now_ms - self.probe_start_ms > self.protocol_period_ms) {
                    try self.dispatchIndirect(now_ms, alloc, &actions);
                }
            },
            .waiting_indirect => {
                // S2: single deadline instead of counting.
                if (now_ms >= self.indirect_deadline_ms) {
                    try self.markSuspect(self.join_order.items[self.probe_index], now_ms, alloc, &actions);
                }
            },
        }
        return actions.toOwnedSlice(alloc);
    }

    /// B4: Reshuffle join_order (Fisher-Yates) and compact dead/left entries.
    fn reshuffleJoinOrder(self: *Memberlist, seed: i64, alloc: std.mem.Allocator) !void {
        // Compact: filter out dead/left entries (except self at position 0).
        var compacted: std.ArrayListUnmanaged(usize) = .empty;
        try compacted.append(alloc, 0); // Keep self.
        for (self.join_order.items) |idx| {
            if (idx == 0) continue; // Already added self.
            const entry = self.nodes.items[idx];
            if (entry.node.state == .dead or entry.node.state == .left) continue;
            try compacted.append(alloc, idx);
        }
        self.join_order.deinit(self.allocator);
        self.join_order = compacted;

        // Shuffle indices 1..len (keep self at position 0).
        if (self.join_order.items.len > 2) {
            var rng = std.Random.DefaultPrng.init(@intCast(seed));
            const random = rng.random();
            var i: usize = self.join_order.items.len - 1;
            while (i > 1) : (i -= 1) {
                const j = 1 + random.uintLessThan(usize, i);
                const tmp = self.join_order.items[i];
                self.join_order.items[i] = self.join_order.items[j];
                self.join_order.items[j] = tmp;
            }
        }
    }

    fn dispatchIndirect(self: *Memberlist, now_ms: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        const n = self.nodes.items.len;
        if (n <= 1) { self.probe_state = .idle; return; }
        const target_idx = self.join_order.items[self.probe_index];
        const target = self.nodes.items[target_idx];

        var rng = std.Random.DefaultPrng.init(@intCast(now_ms));
        const random = rng.random();
        var selected: u8 = 0;
        var attempts: usize = 0;

        while (selected < self.config.indirect_checks and attempts < n * 3) : (attempts += 1) {
            const ci = random.uintLessThan(usize, n);
            if (ci == self.self_index or ci == target_idx) continue;
            var dup = false;
            for (0..selected) |i| { if (self.indirect_peers[i] == ci) { dup = true; break; } }
            if (dup) continue;
            self.indirect_peers[selected] = ci;
            selected += 1;
        }
        if (selected == 0) {
            try self.markSuspect(target_idx, now_ms, alloc, actions);
            return;
        }
        for (0..selected) |i| {
            const peer = self.nodes.items[self.indirect_peers[i]];
            try actions.append(alloc, .{ .send_indirect_ping = .{
                .peer = peer.node.name, .peer_addr = peer.node.addr,
                .target = target.node.name, .target_addr = target.node.addr, .seqno = self.probe_seqno,
            } });
        }
        self.probe_state = .waiting_indirect;
        // S2: single deadline = now + K * timeout_per_cycle.
        self.indirect_deadline_ms = now_ms + self.indirect_timeout_ms * @as(i64, self.config.indirect_checks);
        self.indirect_ack_count = 0;
    }

    fn markSuspect(self: *Memberlist, target_idx: usize, now_ms: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        var target = &self.nodes.items[target_idx];
        if (target.node.state == .dead or target.node.state == .left) { self.probe_state = .idle; return; }
        target.node.state = .suspect;
        target.last_heard_ms = now_ms;
        self.probe_state = .idle;
        // S4: advance probe_index past the just-suspected node to avoid wasted re-probe.
        self.probe_index = (self.probe_index + 1) % self.join_order.items.len;
        try actions.append(alloc, .{ .node_suspected = .{ .node = try alloc.dupe(u8, target.node.name), .addr = target.node.addr } });

        // B3: create a suspicion timer for this node.
        // k = suspicion_mult, min = k * protocol_period_ms, max = min * max_timeout_mult.
        const k: u8 = self.config.suspicion_mult;
        const min_ms: i64 = @as(i64, k) * self.protocol_period_ms;
        const max_ms: i64 = min_ms * @as(i64, self.config.suspicion_max_timeout_mult);
        const s = try Suspicion.init(alloc, self.self_name, k, min_ms, max_ms, now_ms);
        const node_name_owned = try alloc.dupe(u8, target.node.name);
        errdefer alloc.free(node_name_owned);
        try self.suspicions.put(alloc, node_name_owned, s);
    }

    /// Process an incoming raw packet. Returns owned slice of actions.
    pub fn handlePacket(
        self: *Memberlist, data: []const u8, from_addr: Address,
        from_name: []const u8, timestamp_ms: i64, alloc: std.mem.Allocator,
    ) ![]Action {
        if (self.shutdown) return &[_]Action{};
        var actions: std.ArrayListUnmanaged(Action) = .empty;
        if (data.len < 1) return actions.toOwnedSlice(alloc);

        const msg_type: MessageType = @enumFromInt(data[0]);

        switch (msg_type) {
            .ping => {
                const ping = try protocol.decodePing(alloc, data);
                defer protocol.freeDecodedPing(&ping, alloc);
                if (!std.mem.eql(u8, ping.node, self.self_name)) return actions.toOwnedSlice(alloc);
                var ack_buf: [128]u8 = undefined;
                const ack = types.Ack{ .seqno = ping.seqno, .payload = "" };
                const ack_n = try protocol.encodeAck(&ack_buf, ack);
                const ack_payload = try alloc.alloc(u8, ack_n);
                errdefer alloc.free(ack_payload);
                @memcpy(ack_payload, ack_buf[0..ack_n]);
                try actions.append(alloc, .{ .send_ack = .{
                    .target_addr = from_addr, .seqno = ping.seqno, .payload = ack_payload,
                } });
            },
            .indirect_ping => {
                const iping = try protocol.decodeIndirectPing(alloc, data);
                defer protocol.freeDecodedIndirectPing(&iping, alloc);
                try actions.append(alloc, .{ .send_ping = .{ .target = try alloc.dupe(u8, iping.node), .target_addr = iping.target_addr, .seqno = iping.seqno } });
            },
            .ack => {
                const ack = try protocol.decodeAck(alloc, data);
                defer protocol.freeDecodedAck(&ack, alloc);
                if (ack.seqno == self.probe_seqno) self.probe_state = .idle;
            },
            .nack => {},
            .alive => {
                const alive = try protocol.decodeAlive(alloc, data);
                defer protocol.freeDecodedAlive(&alive, alloc);
                try self.applyAlive(alive.node, alive.addr, alive.incarnation, timestamp_ms, alloc, &actions);
            },
            .suspect => {
                const suspect = try protocol.decodeSuspect(alloc, data);
                defer protocol.freeDecodedSuspect(&suspect, alloc);
                // B3: confirm on existing suspicion timer to accelerate it.
                if (self.suspicions.getPtr(suspect.node)) |s| {
                    _ = try s.confirm(suspect.from, alloc);
                }
                try self.applySuspect(suspect.node, suspect.addr, suspect.incarnation, timestamp_ms, alloc, &actions);
            },
            .dead => {
                const dead = try protocol.decodeDead(alloc, data);
                defer protocol.freeDecodedDead(&dead, alloc);
                try self.applyDead(dead.node, dead.addr, dead.incarnation, timestamp_ms, alloc, &actions);
            },
            .compound => {
                var compound = try protocol.decodeCompound(alloc, data);
                defer protocol.freeDecodedCompound(&compound, alloc);
                for (compound.messages.items) |inner| {
                    // Prepend the type byte: handlePacket expects data[0] to
                    // be the message type, but compound payloads store only
                    // the body (after type + length bytes).
                    const inner_with_type = try alloc.alloc(u8, inner.payload.len + 1);
                    defer alloc.free(inner_with_type);
                    inner_with_type[0] = @intFromEnum(inner.msg_type);
                    @memcpy(inner_with_type[1..], inner.payload);
                    const inner_actions = try self.handlePacket(inner_with_type, from_addr, from_name, timestamp_ms, alloc);
                    defer freeActions(alloc, inner_actions);
                    try actions.appendSlice(alloc, inner_actions);
                }
            },
            .user => {},
            else => {},
        }
        return actions.toOwnedSlice(alloc);
    }

    fn applyAlive(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) {
            if (incarnation > self.incarnation) self.incarnation = incarnation;
            return;
        }
        // B3: if this node was suspected, remove its suspicion timer (alive refutes it).
        if (self.suspicions.getPtr(name)) |s| {
            s.deinit(alloc);
            _ = self.suspicions.remove(name);
        }
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation > entry.node.incarnation or (incarnation == entry.node.incarnation and entry.node.state != .alive)) {
                entry.node.incarnation = incarnation;
                entry.node.state = .alive;
                entry.node.addr = addr;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_alive = .{ .node = try alloc.dupe(u8, name), .addr = addr } });
            }
        } else {
            const name_owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_owned);
            const idx_new = self.nodes.items.len;
            try self.nodes.append(self.allocator, .{ .node = .{
                .name = name_owned, .addr = addr, .incarnation = incarnation, .state = .alive, .protocol_version = 1,
            }, .last_heard_ms = ts });
            try self.name_to_index.put(self.allocator, name_owned, idx_new);
            try self.join_order.append(self.allocator, idx_new);
            try actions.append(alloc, .{ .node_alive = .{ .node = try alloc.dupe(u8, name), .addr = addr } });
        }
    }

    fn applySuspect(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) {
            // B2: Emit self-refutation via send_gossip to all alive peers.
            if (incarnation >= self.incarnation) {
                self.incarnation = incarnation + 1;
                // Encode an Alive message for dissemination.
                var alive_buf: [512]u8 = undefined;
                const alive_msg = types.Alive{
                    .node = self.self_name,
                    .addr = self.nodes.items[self.self_index].node.addr,
                    .incarnation = self.incarnation,
                    .meta = "",
                };
                const alive_n = try protocol.encodeAlive(&alive_buf, alive_msg);
                const alive_payload = try alloc.alloc(u8, alive_n);
                errdefer alloc.free(alive_payload);
                @memcpy(alive_payload, alive_buf[0..alive_n]);
                // Collect addresses of all alive peers.
                var peer_addrs: std.ArrayListUnmanaged(Address) = .empty;
                for (self.nodes.items) |entry| {
                    if (entry.node.state == .alive and entry.node.name.len > 0 and
                        !std.mem.eql(u8, entry.node.name, self.self_name))
                    {
                        try peer_addrs.append(alloc, entry.node.addr);
                    }
                }
                try actions.append(alloc, .{ .send_gossip = .{
                    .target_addrs = try peer_addrs.toOwnedSlice(alloc),
                    .payload = alive_payload,
                } });
            }
            return;
        }
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation > entry.node.incarnation or (incarnation == entry.node.incarnation and entry.node.state == .alive)) {
                entry.node.incarnation = incarnation;
                entry.node.state = .suspect;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_suspected = .{ .node = try alloc.dupe(u8, name), .addr = addr } });
            }
        }
    }

    fn applyDead(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) return;
        // B3: remove suspicion timer on dead confirmation.
        if (self.suspicions.getPtr(name)) |s| {
            s.deinit(alloc);
            _ = self.suspicions.remove(name);
        }
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation >= entry.node.incarnation) {
                entry.node.incarnation = incarnation;
                entry.node.state = .dead;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_failed = .{ .node = try alloc.dupe(u8, name), .addr = addr } });
            }
        }
    }

    pub fn join(self: *Memberlist, known_nodes: []const Node) ![]Action {
        var actions: std.ArrayListUnmanaged(Action) = .empty;
        for (known_nodes) |n| {
            try actions.append(self.allocator, .{ .dial_push_pull = .{ .peer = n.name, .peer_addr = n.addr } });
        }
        return actions.toOwnedSlice(self.allocator);
    }

    pub fn leave(self: *Memberlist) ![]Action {
        self.leaving = true;
        var actions: std.ArrayListUnmanaged(Action) = .empty;
        self.nodes.items[self.self_index].node.state = .left;
        try actions.append(self.allocator, .{ .node_left = .{ .node = self.self_name, .addr = self.nodes.items[self.self_index].node.addr } });
        return actions.toOwnedSlice(self.allocator);
    }
};

/// Free heap-allocated fields within a slice of Actions, then free the slice
/// itself.  The allocator must be the same one passed to tick/handlePacket.
pub fn freeActions(alloc: std.mem.Allocator, actions: []Action) void {
    for (actions) |action| {
        switch (action) {
            .send_ping => |sp| alloc.free(sp.target),
            .send_ack => |sa| alloc.free(sa.payload),
            .send_gossip => |sg| {
                alloc.free(sg.payload);
                alloc.free(sg.target_addrs);
            },
            .push_pull_state => |pps| alloc.free(pps.state_bytes),
            .node_alive, .node_suspected, .node_failed => |ev| alloc.free(ev.node),
            else => {},
        }
    }
    alloc.free(actions);
}

// ==============================================================
// Tests
// ==============================================================

test "memberlist init and deinit" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "test-node" });
    defer ml.deinit();
    try std.testing.expectEqual(@as(usize, 1), ml.nodeCount());
}

test "memberlist tick single node" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "test-node" });
    defer ml.deinit();
    const actions = try ml.tick(0, alloc);
    defer freeActions(alloc, actions);
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "memberlist handle ping" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer ml.deinit();
    var buf: [128]u8 = undefined;
    const ping = types.Ping{ .seqno = 42, .node = "node-a" };
    const n = try protocol.encodePing(&buf, ping);
    const from = Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9999);
    const actions = try ml.handlePacket(buf[0..n], from, "", 0, alloc);
    defer freeActions(alloc, actions);
    try std.testing.expect(actions.len >= 1);
}

test "memberlist handle alive adds node" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer ml.deinit();
    var buf: [256]u8 = undefined;
    const alive = types.Alive{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 0, .meta = "" };
    const n = try protocol.encodeAlive(&buf, alive);
    const from = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
    const actions = try ml.handlePacket(buf[0..n], from, "node-b", 0, alloc);
    defer freeActions(alloc, actions);
    try std.testing.expectEqual(@as(usize, 2), ml.nodeCount());
}

test "memberlist incarnation overrides" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer ml.deinit();

    // Add node-b alive
    {
        var buf: [256]u8 = undefined;
        const alive = types.Alive{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 0, .meta = "" };
        const n = try protocol.encodeAlive(&buf, alive);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
    }
    // Suspect node-b incarnation 0
    {
        var buf: [256]u8 = undefined;
        const suspect = types.Suspect{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 0, .from = "node-c" };
        const n = try protocol.encodeSuspect(&buf, suspect);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 3 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "", 0, alloc);
        defer freeActions(alloc, actions);
    }
    try std.testing.expectEqual(NodeState.suspect, ml.nodes.items[1].node.state);
    // Alive incarnation 1 should override
    {
        var buf: [256]u8 = undefined;
        const alive = types.Alive{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 1, .meta = "" };
        const n = try protocol.encodeAlive(&buf, alive);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
    }
    try std.testing.expectEqual(NodeState.alive, ml.nodes.items[1].node.state);
    try std.testing.expectEqual(@as(Incarnation, 1), ml.nodes.items[1].node.incarnation);
}

test "self suspect refutation emits send_gossip" {
    const alloc = std.testing.allocator;
    var ml = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer ml.deinit();

    // First add another node so there's a peer to gossip to.
    {
        var buf: [256]u8 = undefined;
        const alive = types.Alive{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 0, .meta = "" };
        const n = try protocol.encodeAlive(&buf, alive);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
    }

    // Now suspect self.
    {
        var buf: [256]u8 = undefined;
        const suspect = types.Suspect{ .node = "node-a", .addr = Address.initIp4([4]u8{ 127, 0, 0, 1 }, 7946), .incarnation = 0, .from = "node-c" };
        const n = try protocol.encodeSuspect(&buf, suspect);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 3 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "", 0, alloc);
        defer freeActions(alloc, actions);

        // Should have emitted send_gossip with our new alive message.
        try std.testing.expect(actions.len >= 1);
        try std.testing.expectEqual(ActionTag.send_gossip, actions[0]);
        // Incarnation should have been incremented.
        try std.testing.expectEqual(@as(Incarnation, 1), ml.incarnation);
    }
}
