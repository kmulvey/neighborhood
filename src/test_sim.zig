// Simulation & integration tests — state machine lifecycle, edge cases, compound paths.
const nb = @import("neighborhood");
const std = @import("std");

const Config = nb.Config;
const Memberlist = nb.Memberlist;
const NodeState = nb.NodeState;
const Address = nb.Address;
const Alive = nb.Alive;
const Suspect = nb.Suspect;
const Dead = nb.Dead;
const Action = nb.Action;
const freeActions = nb.freeActions;

const addr_a = Address.initIp4([4]u8{ 127, 0, 0, 1 }, 7946);
const addr_b = Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946);
const addr_c = Address.initIp4([4]u8{ 127, 0, 0, 3 }, 7946);
const addr_d = Address.initIp4([4]u8{ 127, 0, 0, 4 }, 7946);

fn feedAlive(ml: *Memberlist, name: []const u8, addr: Address, inc: u32, ts: i64, alloc: std.mem.Allocator) !void {
    var buf: [256]u8 = undefined;
    const msg = Alive{ .node = name, .addr = addr, .incarnation = inc, .meta = "" };
    const n = try nb.protocol.encodeAlive(&buf, msg);
    const actions = try ml.handlePacket(buf[0..n], addr, name, ts, alloc);
    defer freeActions(alloc, actions);
}

fn feedSuspect(ml: *Memberlist, name: []const u8, addr: Address, inc: u32, from: []const u8, ts: i64, alloc: std.mem.Allocator) !void {
    var buf: [256]u8 = undefined;
    const msg = Suspect{ .node = name, .addr = addr, .incarnation = inc, .from = from };
    const n = try nb.protocol.encodeSuspect(&buf, msg);
    const actions = try ml.handlePacket(buf[0..n], addr, from, ts, alloc);
    defer freeActions(alloc, actions);
}

fn feedDead(ml: *Memberlist, name: []const u8, addr: Address, inc: u32, from: []const u8, ts: i64, alloc: std.mem.Allocator) !void {
    var buf: [256]u8 = undefined;
    const msg = Dead{ .node = name, .addr = addr, .incarnation = inc, .from = from };
    const n = try nb.protocol.encodeDead(&buf, msg);
    const actions = try ml.handlePacket(buf[0..n], addr, from, ts, alloc);
    defer freeActions(alloc, actions);
}

// ==============================================================
// Priority 1: State machine integration tests
// ==============================================================

test "1a: full probe → suspect → dead lifecycle" {
    const alloc = std.testing.allocator;
    // Short protocol period so timeouts trigger in-test.
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 10,
    });
    defer mla.deinit();

    // Add node-b (target) and node-c (indirect peer) via alive messages.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);
    try feedAlive(&mla, "node-c", addr_c, 0, 0, alloc);
    try std.testing.expectEqual(@as(usize, 3), mla.nodeCount());

    // ---- Tick 0: start probing node-b ----
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expect(actions.len >= 1);
        try std.testing.expect(actions[0] == .send_ping);
        try std.testing.expectEqualStrings("node-b", actions[0].send_ping.target);
    }
    // ---- Tick 20: direct timeout → dispatch indirect ping to node-c ----
    {
        const actions = try mla.tick(20, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expect(actions.len >= 1);
        try std.testing.expect(actions[0] == .send_indirect_ping);
        try std.testing.expectEqualStrings("node-b", actions[0].send_indirect_ping.target);
    }
    // ---- Tick 50: indirect deadline → mark node-b suspect ----
    {
        const actions = try mla.tick(50, alloc);
        defer freeActions(alloc, actions);
        var found: bool = false;
        for (actions) |a| {
            if (a == .node_suspected) {
                try std.testing.expectEqualStrings("node-b", a.node_suspected.node);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
    // Verify node-b is suspect with timer.
    try std.testing.expectEqual(NodeState.suspect, mla.nodes.items[1].node.state);
    try std.testing.expect(mla.suspicions.contains("node-b"));

    // ---- Tick 350: suspicion timer expired → mark node-b dead ----
    {
        const actions = try mla.tick(350, alloc);
        defer freeActions(alloc, actions);
        var has_failed: bool = false;
        var has_gossip: bool = false;
        for (actions) |a| {
            switch (a) {
                .node_failed => |ev| {
                    try std.testing.expectEqualStrings("node-b", ev.node);
                    has_failed = true;
                },
                .send_gossip => has_gossip = true,
                else => {},
            }
        }
        try std.testing.expect(has_failed);
        try std.testing.expect(has_gossip);
    }
    // Verify node-b is dead and suspicion removed.
    try std.testing.expectEqual(NodeState.dead, mla.nodes.items[1].node.state);
    try std.testing.expect(!mla.suspicions.contains("node-b"));
}

test "1b: probe succeeds (ack resets state)" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 10,
    });
    defer mla.deinit();
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);

    // Tick to send ping.
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expect(actions[0] == .send_ping);
    }
    try std.testing.expect(mla.probe_state == .waiting_direct);

    // Feed ack with matching seqno before timeout.
    {
        var buf: [128]u8 = undefined;
        const ack = nb.Ack{ .seqno = mla.probe_seqno, .payload = "" };
        const n = try nb.protocol.encodeAck(&buf, ack);
        const actions = try mla.handlePacket(buf[0..n], addr_b, "node-b", 10, alloc);
        defer freeActions(alloc, actions);
    }
    try std.testing.expect(mla.probe_state == .idle);

    // Node stays alive, no suspect transition.
    try std.testing.expectEqual(NodeState.alive, mla.nodes.items[1].node.state);
}

test "1c: indirect ping forwarding" {
    const alloc = std.testing.allocator;
    var mlc = try Memberlist.init(alloc, Config{ .name = "node-c" });
    defer mlc.deinit();

    // C receives an indirect_ping asking it to probe node-b on behalf of node-a.
    var buf: [256]u8 = undefined;
    const iping = nb.IndirectPing{
        .seqno = 42,
        .node = "node-b",
        .target_addr = addr_b,
    };
    const n = try nb.protocol.encodeIndirectPing(&buf, iping);
    const actions = try mlc.handlePacket(buf[0..n], addr_a, "node-a", 0, alloc);
    defer freeActions(alloc, actions);

    // C should emit a send_ping targeting node-b with the same seqno.
    try std.testing.expect(actions.len >= 1);
    try std.testing.expect(actions[0] == .send_ping);
    try std.testing.expectEqualStrings("node-b", actions[0].send_ping.target);
    try std.testing.expectEqual(@as(u32, 42), actions[0].send_ping.seqno);
}

test "1d: suspicion confirm acceleration" {
    const alloc = std.testing.allocator;
    const suspicion_mod = nb.suspicion;

    // Create suspicion for node-x from three different peers.
    var s = try suspicion_mod.Suspicion.init(alloc, "self", 3, 1000, 10000, 0);
    defer s.deinit(alloc);

    const t0 = s.remainingMs(0);
    // Confirm from peer-a should accelerate.
    try std.testing.expect(try s.confirm("peer-a", alloc));
    try std.testing.expectEqual(@as(i32, 1), s.n);
    const t1 = s.remainingMs(0);
    try std.testing.expect(t1 < t0);

    // Confirm from peer-b should accelerate further.
    try std.testing.expect(try s.confirm("peer-b", alloc));
    try std.testing.expectEqual(@as(i32, 2), s.n);
    const t2 = s.remainingMs(0);
    try std.testing.expect(t2 < t1);

    // Confirm from peer-c should hit k=3 (minimum timeout).
    try std.testing.expect(try s.confirm("peer-c", alloc));
    try std.testing.expectEqual(@as(i32, 3), s.n);
    try std.testing.expectEqual(@as(i64, 1000), s.remainingMs(0));

    // Duplicate from peer-a should be rejected (dedup).
    try std.testing.expect(!try s.confirm("peer-a", alloc));
    try std.testing.expectEqual(@as(i32, 3), s.n);
}

test "1e: round-robin wrap + reshuffle" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 1000,
    });
    defer mla.deinit();

    // Add nodes b, c, d.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);
    try feedAlive(&mla, "node-c", addr_c, 0, 0, alloc);
    try feedAlive(&mla, "node-d", addr_d, 0, 0, alloc);
    try std.testing.expectEqual(@as(usize, 4), mla.nodeCount());

    // Tick 3 times: should probe b, c, d in order.
    // After self-skip, probe_index advances to 1,2,3 then wraps to 0 which triggers reshuffle.
    // The reshuffle is Fisher-Yates — we can't predict exact order, but we can
    // verify probe_state transitions correctly.
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expect(actions[0] == .send_ping);
    }
    // Mark probed node dead to test compaction.
    // Find the just-probed node index.
    const probed_idx = mla.join_order.items[mla.probe_index];
    mla.nodes.items[probed_idx].node.state = .dead;

    // After wrap-around (more ticks than nodes), reshuffle should compact out dead.
    // Simulate by calling reshuffleJoinOrder directly.
    try mla.reshuffleJoinOrder(42, alloc);
    try std.testing.expect(mla.join_order.items.len < 4); // dead node compacted
}

// ==============================================================
// Priority 2: Gossip queue lifecycle
// ==============================================================

test "2a: gossip retransmit limit reached + removal" {
    const alloc = std.testing.allocator;
    const gossip_mod = nb.gossip;
    const GossipQueue = gossip_mod.TransmitLimitedQueue;

    // N=1, retransmit_mult=1 → max_tx = 1 * ceil(log2(2)) = 1.
    // Message should appear once, then be removed.
    var q = GossipQueue.init(alloc, 1, struct { fn f() usize { return 1; } }.f);
    defer q.deinit();
    try q.queueMsg("node-a", "payload-a");

    // First call: message appears (transmits 0→1, hits limit, queued for removal).
    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        try std.testing.expectEqual(@as(usize, 1), msgs.len);
    }

    // Second call: message should be gone (removed after first call's cleanup).
    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        try std.testing.expectEqual(@as(usize, 0), msgs.len);
    }
}

test "2b: gossip node_index correctness after swapRemove" {
    const alloc = std.testing.allocator;
    const gossip_mod = nb.gossip;
    const GossipQueue = gossip_mod.TransmitLimitedQueue;

    // N=1 → max_tx = 1.  One getMessages call hits the limit.
    var q = GossipQueue.init(alloc, 1, struct { fn f() usize { return 1; } }.f);
    defer q.deinit();
    try q.queueMsg("node-a", "a");
    try q.queueMsg("node-b", "b");
    try q.queueMsg("node-c", "c");
    try q.queueMsg("node-d", "d");

    // First getMessages: all 4 appear.  After removal they all hit max_tx=1.
    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        try std.testing.expectEqual(@as(usize, 4), msgs.len);
    }
    // All should be removed now.
    try std.testing.expectEqual(@as(usize, 0), q.len());

    // Queue a new message for a node that was moved by swapRemove.
    try q.queueMsg("node-a", "new-a");
    try std.testing.expectEqual(@as(usize, 1), q.len());

    // The message should be retrievable (proves node_index was updated correctly).
    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        try std.testing.expectEqual(@as(usize, 1), msgs.len);
        try std.testing.expectEqualStrings("new-a", msgs[0].payload);
    }
}

test "2c: gossip priority ordering" {
    const alloc = std.testing.allocator;
    const gossip_mod = nb.gossip;
    const GossipQueue = gossip_mod.TransmitLimitedQueue;

    // N=3 → max_tx = 4 * ceil(log2(4)) = 8. Messages won't be removed within test bounds.
    var q = GossipQueue.init(alloc, 4, struct { fn f() usize { return 3; } }.f);
    defer q.deinit();

    // Queue messages with same transmit count (0) but different lengths.
    // Longer payloads should come first (msg_len DESC).
    try q.queueMsg("short", "ab"); // 2 bytes, lower ID
    try q.queueMsg("longer", "abcdefg"); // 7 bytes, higher ID

    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        try std.testing.expect(msgs.len >= 2);
        // First should be longer message (even though it has higher ID,
        // msg_len DESC takes priority over id DESC).
        try std.testing.expect(msgs[0].msg_len > msgs[1].msg_len);
    }

    // Queue two messages with same-length payloads.
    // Higher ID (newer) should come first since transmits and msg_len are equal.
    try q.queueMsg("same-len-1", "abcde"); // 5 bytes, lower ID
    try q.queueMsg("same-len-2", "fghij"); // 5 bytes, higher ID

    {
        const msgs = try q.getMessages(1024);
        defer gossip_mod.freeMessages(alloc, msgs);
        // 'same-len-2' (higher ID) should appear before 'same-len-1' in sorted order.
        // Note: messages from prior call may still be present (not removed).
        var idx1: ?usize = null;
        var idx2: ?usize = null;
        for (msgs, 0..) |m, i| {
            if (std.mem.eql(u8, m.node, "same-len-1")) idx1 = i;
            if (std.mem.eql(u8, m.node, "same-len-2")) idx2 = i;
        }
        try std.testing.expect(idx1 != null);
        try std.testing.expect(idx2 != null);
        try std.testing.expect(idx2.? < idx1.?); // higher ID first
    }
}

// ==============================================================
// Priority 3: Compound message paths
// ==============================================================

test "3a: compound decode → handlePacket" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer mla.deinit();

    // Encode a compound message containing [ping, alive].
    var ping_buf: [128]u8 = undefined;
    const ping = nb.Ping{ .seqno = 99, .node = "node-a" };
    const ping_n = try nb.protocol.encodePing(&ping_buf, ping);

    var alive_buf: [256]u8 = undefined;
    const alive = Alive{ .node = "node-b", .addr = addr_b, .incarnation = 0, .meta = "" };
    const alive_n = try nb.protocol.encodeAlive(&alive_buf, alive);

    var compound_buf: [512]u8 = undefined;
    const inner = [_]nb.protocol.CompoundMessage{
        .{ .msg_type = .ping, .payload = ping_buf[1..ping_n] },
        .{ .msg_type = .alive, .payload = alive_buf[1..alive_n] },
    };
    const cpd_n = try nb.protocol.encodeCompound(&compound_buf, inner[0..]);

    const actions = try mla.handlePacket(compound_buf[0..cpd_n], addr_b, "node-b", 0, alloc);
    defer freeActions(alloc, actions);

    // Should have: send_ack (from ping) + node_alive (from alive).
    var has_ack: bool = false;
    var has_alive: bool = false;
    for (actions) |a| {
        switch (a) {
            .send_ack => has_ack = true,
            .node_alive => |ev| {
                try std.testing.expectEqualStrings("node-b", ev.node);
                has_alive = true;
            },
            else => {},
        }
    }
    try std.testing.expect(has_ack);
    try std.testing.expect(has_alive);
    try std.testing.expectEqual(@as(usize, 2), mla.nodeCount());
}

// ==============================================================
// Priority 4: Edge cases & error paths
// ==============================================================

test "4a: self-probe skip" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a", .protocol_period_ms = 10 });
    defer mla.deinit();

    // Single node — tick returns empty (nodes.len <= 1).
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "4b: dead node skip in probe" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 10,
    });
    defer mla.deinit();

    // Add alive nodes b, c.  Need 3+ nodes so dead-skip finds a live target.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);
    try feedAlive(&mla, "node-c", addr_c, 0, 0, alloc);

    // Mark node-b as dead.
    mla.nodes.items[1].node.state = .dead;

    // Tick 0: probe_index advances from 0 to 1, hits dead node-b, skips.
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len); // dead skipped
    }
    // Tick 10: probe_index advances from 1 to 2, hits alive node-c.
    {
        const actions = try mla.tick(10, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expect(actions.len >= 1);
        try std.testing.expect(actions[0] == .send_ping);
        try std.testing.expectEqualStrings("node-c", actions[0].send_ping.target);
    }
}

test "4c: shutdown stops state machine" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a", .protocol_period_ms = 10 });
    defer mla.deinit();

    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);

    mla.shutdown = true;

    // tick should return empty.
    {
        const actions = try mla.tick(0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
    // handlePacket should return empty.
    {
        var buf: [128]u8 = undefined;
        const ping = nb.Ping{ .seqno = 1, .node = "node-a" };
        const n = try nb.protocol.encodePing(&buf, ping);
        const actions = try mla.handlePacket(buf[0..n], addr_b, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "4d: malformed / truncated packets" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a" });
    defer mla.deinit();

    // 0-byte packet → empty actions, no crash.
    {
        const actions = try mla.handlePacket(&[0]u8{}, addr_b, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }

    // Unknown type byte → no crash, empty actions.
    {
        const actions = try mla.handlePacket(&[_]u8{255}, addr_b, "node-b", 0, alloc);
        defer freeActions(alloc, actions);
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "4e: self-suspect refutation" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 10,
    });
    defer mla.deinit();
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);

    const orig_incarnation = mla.incarnation;

    // Feed a suspect message targeting self (node-a).
    var buf: [256]u8 = undefined;
    const suspect = Suspect{
        .node = "node-a",
        .addr = addr_a,
        .incarnation = 0,
        .from = "node-c",
    };
    const n = try nb.protocol.encodeSuspect(&buf, suspect);
    const actions = try mla.handlePacket(buf[0..n], addr_c, "node-c", 0, alloc);
    defer freeActions(alloc, actions);

    // Should have incremented incarnation and emitted alive gossip.
    try std.testing.expect(mla.incarnation > orig_incarnation);
    var has_gossip: bool = false;
    for (actions) |a| {
        if (a == .send_gossip) {
            // Verify the gossip payload is an alive message with new incarnation.
            const alive_decoded = try nb.protocol.decodeAlive(alloc, a.send_gossip.payload);
            defer nb.protocol.freeDecodedAlive(&alive_decoded, alloc);
            try std.testing.expectEqualStrings("node-a", alive_decoded.node);
            try std.testing.expectEqual(mla.incarnation, alive_decoded.incarnation);
            has_gossip = true;
        }
    }
    try std.testing.expect(has_gossip);
}

// ==============================================================
// Priority 5: Multi-node simulation
// ==============================================================

test "5a: 3-node convergence" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a", .protocol_period_ms = 1000 });
    defer mla.deinit();
    var mlb = try Memberlist.init(alloc, Config{ .name = "node-b", .protocol_period_ms = 1000 });
    defer mlb.deinit();
    var mlc = try Memberlist.init(alloc, Config{ .name = "node-c", .protocol_period_ms = 1000 });
    defer mlc.deinit();

    // Feed alive messages so all three know each other.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);
    try feedAlive(&mla, "node-c", addr_c, 0, 0, alloc);
    try feedAlive(&mlb, "node-a", addr_a, 0, 0, alloc);
    try feedAlive(&mlb, "node-c", addr_c, 0, 0, alloc);
    try feedAlive(&mlc, "node-a", addr_a, 0, 0, alloc);
    try feedAlive(&mlc, "node-b", addr_b, 0, 0, alloc);

    // Each should see 3 nodes (self + 2 others).
    const a_nodes = try mla.aliveNodes(alloc);
    defer alloc.free(a_nodes);
    try std.testing.expectEqual(@as(usize, 3), a_nodes.len);
    const b_nodes = try mlb.aliveNodes(alloc);
    defer alloc.free(b_nodes);
    try std.testing.expectEqual(@as(usize, 3), b_nodes.len);
    const c_nodes = try mlc.aliveNodes(alloc);
    defer alloc.free(c_nodes);
    try std.testing.expectEqual(@as(usize, 3), c_nodes.len);
}

test "5b: 3-node partition + detection" {
    const alloc = std.testing.allocator;
    var mla = try Memberlist.init(alloc, Config{
        .name = "node-a",
        .protocol_period_ms = 10,
    });
    defer mla.deinit();

    // A knows B and C.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);
    try feedAlive(&mla, "node-c", addr_c, 0, 0, alloc);

    // A probes B (tick 0), direct timeout → indirect through C (tick 20),
    // indirect timeout → mark suspect (tick 50).
    {
        const actions0 = try mla.tick(0, alloc); // send_ping to B
        defer freeActions(alloc, actions0);
        const actions = try mla.tick(20, alloc); // dispatch indirect
        defer freeActions(alloc, actions);
    }
    {
        const actions = try mla.tick(50, alloc); // mark suspect
        defer freeActions(alloc, actions);
    }
    try std.testing.expectEqual(NodeState.suspect, mla.nodes.items[1].node.state);

    // Advance time past suspicion timeout → B becomes dead.
    {
        const actions = try mla.tick(350, alloc);
        defer freeActions(alloc, actions);
        var has_failed: bool = false;
        for (actions) |a| {
            if (a == .node_failed) {
                try std.testing.expectEqualStrings("node-b", a.node_failed.node);
                has_failed = true;
            }
        }
        try std.testing.expect(has_failed);
    }
    try std.testing.expectEqual(NodeState.dead, mla.nodes.items[1].node.state);
}

test "5c: false-positive recovery" {
    const alloc = std.testing.allocator;
    // Node A
    var mla = try Memberlist.init(alloc, Config{ .name = "node-a", .protocol_period_ms = 1000 });
    defer mla.deinit();

    // A learns about B.
    try feedAlive(&mla, "node-b", addr_b, 0, 0, alloc);

    // A receives a suspect message for B (from C).  A marks B as suspect.
    try feedSuspect(&mla, "node-b", addr_b, 0, "node-c", 0, alloc);
    try std.testing.expectEqual(NodeState.suspect, mla.nodes.items[1].node.state);

    // B refutes by incrementing incarnation and sending Alive.
    // A receives B's alive with incarnation=1.
    try feedAlive(&mla, "node-b", addr_b, 1, 10, alloc);
    try std.testing.expectEqual(NodeState.alive, mla.nodes.items[1].node.state);

    // Verify incarnation rule: a stale suspect (inc=0) should NOT flip-flop.
    try feedSuspect(&mla, "node-b", addr_b, 0, "node-c", 20, alloc);
    try std.testing.expectEqual(NodeState.alive, mla.nodes.items[1].node.state);
}
