//! Memberlist state machine — the pure, caller-driven SWIM membership core.
//!
//! No threads, no sockets, no I/O.  The caller drives time via `tick(now)`,
//! feeds incoming packets via `handlePacket(...)`, and executes the returned
//! `Action` list.

const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");

const Config = config_mod.Config;
const Node = types.Node;
const NodeState = types.NodeState;
const Incarnation = types.Incarnation;
const Address = types.Address;
const MessageType = types.MessageType;
const Action = types.Action;
const ActionTag = types.ActionTag;

const NodeEntry = struct {
    node: Node,
    last_heard_ms: i64,
};

const ProbeState = enum {
    idle,
    waiting_direct,
    waiting_indirect,
    suspect,
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
    indirect_timeout_count: u8,
    probe_start_ms: i64,
    indirect_start_ms: i64,
    ack_handlers: std.AutoHashMapUnmanaged(u32, AckHandler),
    leaving: bool,
    shutdown: bool,
    join_order: std.ArrayListUnmanaged(usize),
    self_name: []const u8,
    self_index: usize,
    protocol_period_ms: i64,
    indirect_timeout_ms: i64,

    const AckHandler = struct {
        ack_fn: *const fn (payload: []const u8, timestamp: i64) void,
        nack_fn: *const fn () void,
        deadline_ms: i64,
    };

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
            .indirect_ack_count = 0, .indirect_timeout_count = 0,
            .probe_start_ms = 0, .indirect_start_ms = 0,
            .ack_handlers = .{},
            .leaving = false, .shutdown = false,
            .join_order = join_order,
            .self_name = self_name, .self_index = 0,
            .protocol_period_ms = @intCast(config.protocol_period_ms),
            .indirect_timeout_ms = @intCast(config.protocol_period_ms),
        };
    }

    pub fn deinit(self: *Memberlist) void {
        for (self.nodes.items) |*entry| self.allocator.free(entry.node.name);
        self.nodes.deinit(self.allocator);
        self.name_to_index.deinit(self.allocator);
        self.ack_handlers.deinit(self.allocator);
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

        switch (self.probe_state) {
            .idle => {
                if (self.nodes.items.len <= 1) return actions.toOwnedSlice(alloc);
                if (self.join_order.items.len <= 1) return actions.toOwnedSlice(alloc);
                // Round-robin: advance index, skip self
                self.probe_index = (self.probe_index + 1) % self.join_order.items.len;
                const node_idx = self.join_order.items[self.probe_index];
                if (node_idx == self.self_index) return actions.toOwnedSlice(alloc);
                const target = self.nodes.items[node_idx];
                if (target.node.state == .dead or target.node.state == .left) return actions.toOwnedSlice(alloc);

                self.probe_seqno = self.seqno;
                self.seqno += 1;
                self.probe_state = .waiting_direct;
                self.probe_start_ms = now_ms;
                try actions.append(alloc, .{ .send_ping = .{
                    .target = target.node.name, .target_addr = target.node.addr, .seqno = self.probe_seqno,
                } });
            },
            .waiting_direct => {
                if (now_ms - self.probe_start_ms > self.protocol_period_ms) {
                    try self.dispatchIndirect(now_ms, alloc, &actions);
                }
            },
            .waiting_indirect => {
                if (now_ms - self.indirect_start_ms > self.indirect_timeout_ms) {
                    self.indirect_timeout_count += 1;
                    if (self.indirect_timeout_count >= self.config.indirect_checks) {
                        try self.markSuspect(self.join_order.items[self.probe_index], now_ms, alloc, &actions);
                    } else {
                        self.indirect_start_ms = now_ms;
                    }
                }
            },
            .suspect => { self.probe_state = .idle; },
        }
        return actions.toOwnedSlice(alloc);
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
        self.indirect_start_ms = now_ms;
        self.indirect_ack_count = 0;
        self.indirect_timeout_count = 0;
    }

    fn markSuspect(self: *Memberlist, target_idx: usize, now_ms: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        var target = &self.nodes.items[target_idx];
        if (target.node.state == .dead or target.node.state == .left) { self.probe_state = .idle; return; }
        target.node.state = .suspect;
        target.last_heard_ms = now_ms;
        self.probe_state = .idle;
        try actions.append(alloc, .{ .node_suspected = .{ .node = target.node.name, .addr = target.node.addr } });
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
        _ = from_name;

        switch (msg_type) {
            .ping => {
                const ping = try protocol.decodePing(alloc, data);
                defer protocol.freeDecodedPing(&ping, alloc);
                if (!std.mem.eql(u8, ping.node, self.self_name)) return actions.toOwnedSlice(alloc);
                var ack_buf: [128]u8 = undefined;
                const ack = types.Ack{ .seqno = ping.seqno, .payload = "" };
                const ack_n = try protocol.encodeAck(&ack_buf, ack);
                try actions.append(alloc, .{ .send_ack = .{
                    .target_addr = from_addr, .seqno = ping.seqno, .payload = ack_buf[0..ack_n],
                } });
            },
            .indirect_ping => {
                const iping = try protocol.decodeIndirectPing(alloc, data);
                defer protocol.freeDecodedIndirectPing(&iping, alloc);
                try actions.append(alloc, .{ .send_ping = .{ .target = iping.node, .target_addr = iping.target_addr, .seqno = iping.seqno } });
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
                    const inner_actions = try self.handlePacket(inner.payload, from_addr, "", timestamp_ms, alloc);
                    defer alloc.free(inner_actions);
                    try actions.appendSlice(alloc, inner_actions);
                }
            },
            .user => { _ = @TypeOf(data); },
            else => {},
        }
        return actions.toOwnedSlice(alloc);
    }

    fn applyAlive(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) {
            if (incarnation > self.incarnation) self.incarnation = incarnation;
            return;
        }
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation > entry.node.incarnation or (incarnation == entry.node.incarnation and entry.node.state != .alive)) {
                entry.node.incarnation = incarnation;
                entry.node.state = .alive;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_alive = .{ .node = name, .addr = addr } });
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
            try actions.append(alloc, .{ .node_alive = .{ .node = name, .addr = addr } });
        }
    }

    fn applySuspect(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) {
            if (incarnation >= self.incarnation) self.incarnation = incarnation + 1;
            return;
        }
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation > entry.node.incarnation or (incarnation == entry.node.incarnation and entry.node.state == .alive)) {
                entry.node.incarnation = incarnation;
                entry.node.state = .suspect;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_suspected = .{ .node = name, .addr = addr } });
            }
        }
    }

    fn applyDead(self: *Memberlist, name: []const u8, addr: Address, incarnation: Incarnation, ts: i64, alloc: std.mem.Allocator, actions: *std.ArrayListUnmanaged(Action)) !void {
        if (std.mem.eql(u8, name, self.self_name)) return;
        if (self.name_to_index.get(name)) |idx| {
            var entry = &self.nodes.items[idx];
            if (incarnation >= entry.node.incarnation) {
                entry.node.incarnation = incarnation;
                entry.node.state = .dead;
                entry.last_heard_ms = ts;
                try actions.append(alloc, .{ .node_failed = .{ .node = name, .addr = addr } });
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
    defer alloc.free(actions);
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
    defer alloc.free(actions);
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
    defer alloc.free(actions);
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
        defer alloc.free(actions);
    }
    // Suspect node-b incarnation 0
    {
        var buf: [256]u8 = undefined;
        const suspect = types.Suspect{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 0, .from = "node-c" };
        const n = try protocol.encodeSuspect(&buf, suspect);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 3 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "", 0, alloc);
        defer alloc.free(actions);
    }
    try std.testing.expectEqual(NodeState.suspect, ml.nodes.items[1].node.state);
    // Alive incarnation 1 should override
    {
        var buf: [256]u8 = undefined;
        const alive = types.Alive{ .node = "node-b", .addr = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), .incarnation = 1, .meta = "" };
        const n = try protocol.encodeAlive(&buf, alive);
        const from = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
        const actions = try ml.handlePacket(buf[0..n], from, "node-b", 0, alloc);
        defer alloc.free(actions);
    }
    try std.testing.expectEqual(NodeState.alive, ml.nodes.items[1].node.state);
    try std.testing.expectEqual(@as(Incarnation, 1), ml.nodes.items[1].node.incarnation);
}
