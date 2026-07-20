//! State sync — full memberlist state exchange over TCP (push/pull).
//!
//! Encodes all known nodes into a byte buffer and decodes remote state,
//! applying incarnation-number preference rules to merge.

const std = @import("std");
const types = @import("types.zig");

const Node = types.Node;
const NodeState = types.NodeState;
const Incarnation = types.Incarnation;
const Address = types.Address;

// ==============================================================
// Buffer helpers
// ==============================================================

fn wrU16(buf: []u8, pos: *usize, v: u16) !void {
    if (pos.* + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[pos.*..][0..2], v, .big);
    pos.* += 2;
}

fn wrU32(buf: []u8, pos: *usize, v: u32) !void {
    if (pos.* + 4 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[pos.*..][0..4], v, .big);
    pos.* += 4;
}

fn rdU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.TruncatedMessage;
    const v = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    return v;
}

fn rdU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.TruncatedMessage;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}

/// Encode a list of nodes into a byte buffer.
pub fn encodeNodes(buf: []u8, nodes: []const Node) !usize {
    if (nodes.len > 65535) return error.TooManyNodes;
    var pos: usize = 0;
    try wrU16(buf, &pos, @intCast(nodes.len));
    for (nodes) |n| {
        if (n.name.len > 255) return error.NameTooLong;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(n.name.len); pos += 1;
        if (pos + n.name.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..n.name.len], n.name); pos += n.name.len;
        if (pos + n.addr.ip_len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..n.addr.ip_len], n.addr.ip[0..n.addr.ip_len]); pos += n.addr.ip_len;
        try wrU16(buf, &pos, n.addr.port);
        try wrU32(buf, &pos, n.incarnation);
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = @intFromEnum(n.state); pos += 1;
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = n.protocol_version; pos += 1;
    }
    return pos;
}

/// Decode a list of nodes from a byte buffer.
pub fn decodeNodes(allocator: std.mem.Allocator, data: []const u8) ![]Node {
    if (data.len < 2) return error.TruncatedMessage;
    var pos: usize = 0;
    const count = try rdU16(data, &pos);
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer {
        for (nodes.items) |*n| allocator.free(n.name);
        nodes.deinit(allocator);
    }
    for (0..count) |_| {
        const name_len = data[pos]; pos += 1;
        if (pos + name_len > data.len) return error.TruncatedMessage;
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        @memcpy(name, data[pos..][0..name_len]); pos += name_len;

        var ip: [4]u8 = undefined;
        if (pos + 4 > data.len) return error.TruncatedMessage;
        @memcpy(&ip, data[pos..][0..4]); pos += 4;
        const port = try rdU16(data, &pos);
        const addr = Address.initIp4(ip, port);
        const incarnation = try rdU32(data, &pos);
        if (pos + 2 > data.len) return error.TruncatedMessage;
        const state: NodeState = @enumFromInt(data[pos]); pos += 1;
        const protocol_version = data[pos]; pos += 1;

        try nodes.append(allocator, .{
            .name = name,
            .addr = addr,
            .incarnation = incarnation,
            .state = state,
            .protocol_version = protocol_version,
        });
    }
    return nodes.toOwnedSlice(allocator);
}

pub fn freeNodes(allocator: std.mem.Allocator, nodes: []Node) void {
    for (nodes) |*n| allocator.free(n.name);
    allocator.free(nodes);
}

/// Merge remote nodes into a local node list.
pub fn mergeNodes(
    local_nodes: *std.ArrayListUnmanaged(Node),
    local_index: *std.StringHashMapUnmanaged(usize),
    remote_nodes: []const Node,
    allocator: std.mem.Allocator,
) !usize {
    var mutations: usize = 0;
    for (remote_nodes) |rn| {
        const existing = local_index.get(rn.name);
        if (existing) |idx| {
            const ln = &local_nodes.items[idx];
            if (rn.incarnation > ln.incarnation) {
                allocator.free(ln.name);
                ln.* = try rn.clone(allocator);
                mutations += 1;
            } else if (rn.incarnation == ln.incarnation) {
                if (rn.state == .alive and ln.state != .alive) { ln.state = .alive; mutations += 1; }
                else if (rn.state == .suspect and ln.state == .alive) { ln.state = .suspect; mutations += 1; }
            }
        } else {
            const name_owned = try allocator.dupe(u8, rn.name);
            errdefer allocator.free(name_owned);
            const idx_new = local_nodes.items.len;
            try local_nodes.append(allocator, .{
                .name = name_owned,
                .addr = rn.addr,
                .incarnation = rn.incarnation,
                .state = rn.state,
                .protocol_version = rn.protocol_version,
            });
            try local_index.put(allocator, name_owned, idx_new);
            mutations += 1;
        }
    }
    return mutations;
}

// ==============================================================
// Tests
// ==============================================================

test "encode/decode nodes round-trip" {
    const allocator = std.testing.allocator;
    const nodes = [_]Node{
        .{ .name = "node-a", .addr = Address.initIp4([4]u8{ 10, 0, 0, 1 }, 7946), .incarnation = 1, .state = .alive, .protocol_version = 1 },
        .{ .name = "node-b", .addr = Address.initIp4([4]u8{ 10, 0, 0, 2 }, 7946), .incarnation = 0, .state = .suspect, .protocol_version = 1 },
    };
    var buf: [512]u8 = undefined;
    const n = try encodeNodes(&buf, &nodes);
    const decoded = try decodeNodes(allocator, buf[0..n]);
    defer freeNodes(allocator, decoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings("node-a", decoded[0].name);
    try std.testing.expectEqual(NodeState.suspect, decoded[1].state);
}

test "merge nodes adds new" {
    const allocator = std.testing.allocator;
    var local: std.ArrayListUnmanaged(Node) = .empty;
    defer { for (local.items) |*n| allocator.free(n.name); local.deinit(allocator); }
    var local_idx: std.StringHashMapUnmanaged(usize) = .{};
    defer local_idx.deinit(allocator);

    const remote = [_]Node{
        .{ .name = "node-remote", .addr = Address.initIp4([4]u8{ 10, 0, 0, 3 }, 7946), .incarnation = 0, .state = .alive, .protocol_version = 1 },
    };
    const mutations = try mergeNodes(&local, &local_idx, &remote, allocator);
    try std.testing.expectEqual(@as(usize, 1), mutations);
    try std.testing.expectEqualStrings("node-remote", local.items[0].name);
}

test "merge nodes incarnation override" {
    const allocator = std.testing.allocator;
    var local: std.ArrayListUnmanaged(Node) = .empty;
    defer { for (local.items) |*n| allocator.free(n.name); local.deinit(allocator); }
    var local_idx: std.StringHashMapUnmanaged(usize) = .{};
    defer local_idx.deinit(allocator);

    const local_name = try allocator.dupe(u8, "node-x");
    try local.append(allocator, .{ .name = local_name, .addr = Address.initIp4([4]u8{ 10, 0, 0, 1 }, 7946), .incarnation = 0, .state = .alive, .protocol_version = 1 });
    try local_idx.put(allocator, "node-x", 0);

    const remote = [_]Node{
        .{ .name = "node-x", .addr = Address.initIp4([4]u8{ 10, 0, 0, 1 }, 7946), .incarnation = 1, .state = .suspect, .protocol_version = 1 },
    };
    const mutations = try mergeNodes(&local, &local_idx, &remote, allocator);
    try std.testing.expectEqual(@as(usize, 1), mutations);
    try std.testing.expectEqual(NodeState.suspect, local.items[0].state);
}
