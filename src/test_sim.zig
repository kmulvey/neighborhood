// Simulation tests — multi-node clusters with controlled network conditions.
const nb = @import("neighborhood");
const std = @import("std");

test "sim 3 node basic" {
    const allocator = std.testing.allocator;

    // Create 3 nodes
    const cfg_a = nb.Config{ .name = "node-a" };
    const cfg_b = nb.Config{ .name = "node-b" };
    const cfg_c = nb.Config{ .name = "node-c" };

    var mla = try nb.Memberlist.init(allocator, cfg_a);
    defer mla.deinit();
    var mlb = try nb.Memberlist.init(allocator, cfg_b);
    defer mlb.deinit();
    var mlc = try nb.Memberlist.init(allocator, cfg_c);
    defer mlc.deinit();
}

test "sim 3 node converge" {
    const allocator = std.testing.allocator;

    // Node A knows B and C
    var mla = try nb.Memberlist.init(allocator, nb.Config{ .name = "node-a" });
    defer mla.deinit();

    // Simulate A receiving alive messages from B and C
    var buf: [256]u8 = undefined;
    const alive_b = nb.Alive{
        .node = "node-b",
        .addr = nb.Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946),
        .incarnation = 0,
        .meta = "",
    };
    const nb_enc = try nb.protocol.encodeAlive(&buf, alive_b);
    const actions = try mla.handlePacket(buf[0..nb_enc], nb.Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), "node-b", 0, allocator);
    defer allocator.free(actions);

    try std.testing.expectEqual(@as(usize, 2), mla.nodeCount());
}

test "sim partition detection" {
    const allocator = std.testing.allocator;
    var mla = try nb.Memberlist.init(allocator, nb.Config{ .name = "node-a" });
    defer mla.deinit();

    // Add node-b alive
    {
        var buf: [256]u8 = undefined;
        const alive = nb.Alive{
            .node = "node-b",
            .addr = nb.Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946),
            .incarnation = 0,
            .meta = "",
        };
        const n = try nb.protocol.encodeAlive(&buf, alive);
        const actions = try mla.handlePacket(buf[0..n], nb.Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946), "node-b", 0, allocator);
        defer allocator.free(actions);
    }

    // Suspect node-b
    {
        var buf: [256]u8 = undefined;
        const suspect = nb.Suspect{
            .node = "node-b",
            .addr = nb.Address.initIp4([4]u8{ 127, 0, 0, 2 }, 7946),
            .incarnation = 0,
            .from = "node-c",
        };
        const n = try nb.protocol.encodeSuspect(&buf, suspect);
        const actions = try mla.handlePacket(buf[0..n], nb.Address.initIp4([4]u8{ 127, 0, 0, 3 }, 7946), "node-c", 0, allocator);
        defer allocator.free(actions);
    }

    // Node-b should be suspect now
    try std.testing.expectEqual(nb.NodeState.suspect, mla.nodes.items[1].node.state);
}
