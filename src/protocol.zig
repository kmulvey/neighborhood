//! Wire-protocol encoding and decoding for SWIM messages.
//!
//! All encode/decode functions are pure — no side effects, no I/O.
//! Uses explicit buffer position tracking (no std.io dependency).

const std = @import("std");
const types = @import("types.zig");

const MessageType = types.MessageType;
const Ping = types.Ping;
const IndirectPing = types.IndirectPing;
const Ack = types.Ack;
const Nack = types.Nack;
const Suspect = types.Suspect;
const Alive = types.Alive;
const Dead = types.Dead;
const Address = types.Address;

/// Maximum size of a single encoded message.
pub const max_message_size = 1500;

// ==============================================================
// Buffer read/write helpers (manual position tracking)
// ==============================================================

fn bufWriteU8(buf: []u8, pos: *usize, v: u8) !void {
    if (pos.* + 1 > buf.len) return error.BufferTooSmall;
    buf[pos.*] = v;
    pos.* += 1;
}

fn bufWriteU16(buf: []u8, pos: *usize, v: u16) !void {
    if (pos.* + 2 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, buf[pos.*..][0..2], v, .big);
    pos.* += 2;
}

fn bufWriteU32(buf: []u8, pos: *usize, v: u32) !void {
    if (pos.* + 4 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[pos.*..][0..4], v, .big);
    pos.* += 4;
}

fn bufWriteString(buf: []u8, pos: *usize, s: []const u8) !void {
    if (s.len > 255) return error.StringTooLong;
    try bufWriteU8(buf, pos, @intCast(s.len));
    if (pos.* + s.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos.*..][0..s.len], s);
    pos.* += s.len;
}

fn bufWriteBytes(buf: []u8, pos: *usize, data: []const u8) !void {
    if (pos.* + data.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos.*..][0..data.len], data);
    pos.* += data.len;
}

fn bufWriteAddress(buf: []u8, pos: *usize, addr: Address) !void {
    try bufWriteBytes(buf, pos, addr.ip[0..addr.ip_len]);
    try bufWriteU16(buf, pos, addr.port);
}

fn bufReadU8(data: []const u8, pos: *usize) !u8 {
    if (pos.* + 1 > data.len) return error.TruncatedMessage;
    const v = data[pos.*];
    pos.* += 1;
    return v;
}

fn bufReadU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.TruncatedMessage;
    const v = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    return v;
}

fn bufReadU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.TruncatedMessage;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}

fn bufReadString(data: []const u8, pos: *usize) ![]const u8 {
    const len = try bufReadU8(data, pos);
    if (pos.* + len > data.len) return error.TruncatedMessage;
    const s = data[pos.*..][0..len];
    pos.* += len;
    return s;
}

fn bufReadAddress(data: []const u8, pos: *usize) !Address {
    var ip_buf: [4]u8 = undefined;
    if (pos.* + 4 > data.len) return error.TruncatedMessage;
    @memcpy(&ip_buf, data[pos.*..][0..4]);
    pos.* += 4;
    const port = try bufReadU16(data, pos);
    return Address.initIp4(ip_buf, port);
}

// ==============================================================
// Message encoding
// ==============================================================

pub fn encodePing(buf: []u8, msg: Ping) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.ping));
    try bufWriteU32(buf, &pos, msg.seqno);
    try bufWriteString(buf, &pos, msg.node);
    return pos;
}

pub fn encodeIndirectPing(buf: []u8, msg: IndirectPing) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.indirect_ping));
    try bufWriteU32(buf, &pos, msg.seqno);
    try bufWriteAddress(buf, &pos, msg.target_addr);
    try bufWriteString(buf, &pos, msg.node);
    return pos;
}

pub fn encodeAck(buf: []u8, msg: Ack) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.ack));
    try bufWriteU32(buf, &pos, msg.seqno);
    if (msg.payload.len > 65535) return error.PayloadTooLarge;
    try bufWriteU16(buf, &pos, @intCast(msg.payload.len));
    try bufWriteBytes(buf, &pos, msg.payload);
    return pos;
}

pub fn encodeNack(buf: []u8, msg: Nack) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.nack));
    try bufWriteU32(buf, &pos, msg.seqno);
    return pos;
}

pub fn encodeSuspect(buf: []u8, msg: Suspect) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.suspect));
    try bufWriteString(buf, &pos, msg.node);
    try bufWriteAddress(buf, &pos, msg.addr);
    try bufWriteU32(buf, &pos, msg.incarnation);
    try bufWriteString(buf, &pos, msg.from);
    return pos;
}

pub fn encodeAlive(buf: []u8, msg: Alive) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.alive));
    try bufWriteString(buf, &pos, msg.node);
    try bufWriteAddress(buf, &pos, msg.addr);
    try bufWriteU32(buf, &pos, msg.incarnation);
    if (msg.meta.len > 65535) return error.MetaTooLarge;
    try bufWriteU16(buf, &pos, @intCast(msg.meta.len));
    try bufWriteBytes(buf, &pos, msg.meta);
    return pos;
}

pub fn encodeDead(buf: []u8, msg: Dead) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.dead));
    try bufWriteString(buf, &pos, msg.node);
    try bufWriteAddress(buf, &pos, msg.addr);
    try bufWriteU32(buf, &pos, msg.incarnation);
    try bufWriteString(buf, &pos, msg.from);
    return pos;
}

pub fn encodeCompound(buf: []u8, messages: []const CompoundMessage) !usize {
    var pos: usize = 0;
    try bufWriteU8(buf, &pos, @intFromEnum(MessageType.compound));
    try bufWriteU8(buf, &pos, @intCast(messages.len));
    for (messages) |m| {
        try bufWriteU8(buf, &pos, @intFromEnum(m.msg_type));
        if (m.payload.len > 65535) return error.PayloadTooLarge;
        try bufWriteU16(buf, &pos, @intCast(m.payload.len));
        try bufWriteBytes(buf, &pos, m.payload);
    }
    return pos;
}

// ==============================================================
// Message decoding
// ==============================================================

pub const Decoded = union(MessageType) {
    ping: Ping,
    indirect_ping: IndirectPing,
    ack: Ack,
    nack: Nack,
    suspect: Suspect,
    alive: Alive,
    dead: Dead,
    compound: CompoundDecoded,
    user: UserDecoded,
};

pub const CompoundMessage = struct {
    msg_type: MessageType,
    payload: []u8,
};

pub const CompoundDecoded = struct {
    messages: std.ArrayListUnmanaged(CompoundMessage),
};

pub const UserDecoded = struct {
    payload: []u8,
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    if (data.len < 1) return error.TruncatedMessage;
    var pos: usize = 0;
    const msg_type: MessageType = @enumFromInt(try bufReadU8(data, &pos));

    switch (msg_type) {
        .ping => {
            const seqno = try bufReadU32(data, &pos);
            const node = try bufReadString(data, &pos);
            const node_owned = try allocator.dupe(u8, node);
            return Decoded{ .ping = Ping{ .seqno = seqno, .node = node_owned } };
        },
        .indirect_ping => {
            const seqno = try bufReadU32(data, &pos);
            const addr = try bufReadAddress(data, &pos);
            const node = try bufReadString(data, &pos);
            const node_owned = try allocator.dupe(u8, node);
            return Decoded{ .indirect_ping = IndirectPing{ .seqno = seqno, .target_addr = addr, .node = node_owned } };
        },
        .ack => {
            const seqno = try bufReadU32(data, &pos);
            const payload_len = try bufReadU16(data, &pos);
            if (pos + payload_len > data.len) return error.TruncatedMessage;
            const payload = try allocator.alloc(u8, payload_len);
            errdefer allocator.free(payload);
            @memcpy(payload, data[pos..][0..payload_len]);
            pos += payload_len;
            return Decoded{ .ack = Ack{ .seqno = seqno, .payload = payload } };
        },
        .nack => {
            const seqno = try bufReadU32(data, &pos);
            return Decoded{ .nack = Nack{ .seqno = seqno } };
        },
        .suspect => {
            const node = try bufReadString(data, &pos);
            const addr = try bufReadAddress(data, &pos);
            const incarnation = try bufReadU32(data, &pos);
            const from = try bufReadString(data, &pos);
            const node_owned = try allocator.dupe(u8, node);
            errdefer allocator.free(node_owned);
            const from_owned = try allocator.dupe(u8, from);
            return Decoded{ .suspect = Suspect{ .node = node_owned, .addr = addr, .incarnation = incarnation, .from = from_owned } };
        },
        .alive => {
            const node = try bufReadString(data, &pos);
            const addr = try bufReadAddress(data, &pos);
            const incarnation = try bufReadU32(data, &pos);
            const meta_len = try bufReadU16(data, &pos);
            if (pos + meta_len > data.len) return error.TruncatedMessage;
            const meta = try allocator.alloc(u8, meta_len);
            errdefer allocator.free(meta);
            @memcpy(meta, data[pos..][0..meta_len]);
            pos += meta_len;
            const node_owned = try allocator.dupe(u8, node);
            errdefer allocator.free(node_owned);
            return Decoded{ .alive = Alive{ .node = node_owned, .addr = addr, .incarnation = incarnation, .meta = meta } };
        },
        .dead => {
            const node = try bufReadString(data, &pos);
            const addr = try bufReadAddress(data, &pos);
            const incarnation = try bufReadU32(data, &pos);
            const from = try bufReadString(data, &pos);
            const node_owned = try allocator.dupe(u8, node);
            errdefer allocator.free(node_owned);
            const from_owned = try allocator.dupe(u8, from);
            return Decoded{ .dead = Dead{ .node = node_owned, .addr = addr, .incarnation = incarnation, .from = from_owned } };
        },
        .compound => {
            const count = try bufReadU8(data, &pos);
            var msgs: std.ArrayListUnmanaged(CompoundMessage) = .empty;
            errdefer {
                for (msgs.items) |m| allocator.free(m.payload);
                msgs.deinit(allocator);
            }
            for (0..count) |_| {
                const inner_type: MessageType = @enumFromInt(try bufReadU8(data, &pos));
                const payload_len = try bufReadU16(data, &pos);
                if (pos + payload_len > data.len) return error.TruncatedMessage;
                const payload = try allocator.alloc(u8, payload_len);
                errdefer allocator.free(payload);
                @memcpy(payload, data[pos..][0..payload_len]);
                pos += payload_len;
                try msgs.append(allocator, .{ .msg_type = inner_type, .payload = payload });
            }
            return Decoded{ .compound = CompoundDecoded{ .messages = msgs } };
        },
        .user => {
            const remaining = data.len - pos;
            const payload = try allocator.alloc(u8, remaining);
            errdefer allocator.free(payload);
            if (remaining > 0) {
                @memcpy(payload, data[pos..][0..remaining]);
            }
            return Decoded{ .user = UserDecoded{ .payload = payload } };
        },
        else => return error.UnknownMessageType,
    }
}

pub fn freeDecoded(decoded: *Decoded, allocator: std.mem.Allocator) void {
    switch (decoded.*) {
        .ping => |*m| allocator.free(m.node),
        .indirect_ping => |*m| allocator.free(m.node),
        .ack => |*m| allocator.free(m.payload),
        .nack => {},
        .suspect => |*m| { allocator.free(m.node); allocator.free(m.from); },
        .alive => |*m| { allocator.free(m.node); allocator.free(m.meta); },
        .dead => |*m| { allocator.free(m.node); allocator.free(m.from); },
        .compound => |*m| {
            for (m.messages.items) |*msg| allocator.free(msg.payload);
            m.messages.deinit(allocator);
        },
        .user => |*m| allocator.free(m.payload),
    }
}

// ==============================================================
// Per-type convenience wrappers
// ==============================================================

pub fn decodePing(allocator: std.mem.Allocator, data: []const u8) !Ping { const dec = try decode(allocator, data); return dec.ping; }
pub fn decodeIndirectPing(allocator: std.mem.Allocator, data: []const u8) !IndirectPing { const dec = try decode(allocator, data); return dec.indirect_ping; }
pub fn decodeAck(allocator: std.mem.Allocator, data: []const u8) !Ack { const dec = try decode(allocator, data); return dec.ack; }
pub fn decodeNack(allocator: std.mem.Allocator, data: []const u8) !Nack { const dec = try decode(allocator, data); return dec.nack; }
pub fn decodeSuspect(allocator: std.mem.Allocator, data: []const u8) !Suspect { const dec = try decode(allocator, data); return dec.suspect; }
pub fn decodeAlive(allocator: std.mem.Allocator, data: []const u8) !Alive { const dec = try decode(allocator, data); return dec.alive; }
pub fn decodeDead(allocator: std.mem.Allocator, data: []const u8) !Dead { const dec = try decode(allocator, data); return dec.dead; }
pub fn decodeCompound(allocator: std.mem.Allocator, data: []const u8) !CompoundDecoded { const dec = try decode(allocator, data); return dec.compound; }

pub fn freeDecodedPing(ping: *const Ping, allocator: std.mem.Allocator) void { allocator.free(ping.node); }
pub fn freeDecodedIndirectPing(iping: *const IndirectPing, allocator: std.mem.Allocator) void { allocator.free(iping.node); }
pub fn freeDecodedAck(ack: *const Ack, allocator: std.mem.Allocator) void { allocator.free(ack.payload); }
pub fn freeDecodedNack(_: *Nack, _: std.mem.Allocator) void {}
pub fn freeDecodedSuspect(suspect: *const Suspect, allocator: std.mem.Allocator) void { allocator.free(suspect.node); allocator.free(suspect.from); }
pub fn freeDecodedAlive(alive: *const Alive, allocator: std.mem.Allocator) void { allocator.free(alive.node); allocator.free(alive.meta); }
pub fn freeDecodedDead(dead: *const Dead, allocator: std.mem.Allocator) void { allocator.free(dead.node); allocator.free(dead.from); }
pub fn freeDecodedCompound(compound: *CompoundDecoded, allocator: std.mem.Allocator) void {
    for (compound.messages.items) |*msg| allocator.free(msg.payload);
    compound.messages.deinit(allocator);
}

// ==============================================================
// Tests
// ==============================================================

test "round-trip: ping" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const ping = Ping{ .seqno = 42, .node = "node-1" };
    const n = try encodePing(&buf, ping);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqual(ping.seqno, decoded.ping.seqno);
    try std.testing.expectEqualStrings(ping.node, decoded.ping.node);
}

test "round-trip: ack with payload" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const ack = Ack{ .seqno = 7, .payload = "hello" };
    const n = try encodeAck(&buf, ack);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqual(ack.seqno, decoded.ack.seqno);
    try std.testing.expectEqualStrings(ack.payload, decoded.ack.payload);
}

test "round-trip: ack empty payload" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const ack = Ack{ .seqno = 1, .payload = "" };
    const n = try encodeAck(&buf, ack);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqual(ack.seqno, decoded.ack.seqno);
    try std.testing.expectEqualStrings("", decoded.ack.payload);
}

test "round-trip: nack" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const nack = Nack{ .seqno = 99 };
    const n = try encodeNack(&buf, nack);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqual(nack.seqno, decoded.nack.seqno);
}

test "round-trip: alive" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const alive = Alive{
        .node = "node-1",
        .addr = Address.initIp4([4]u8{ 192, 168, 1, 1 }, 7946),
        .incarnation = 3,
        .meta = "v1.0",
    };
    const n = try encodeAlive(&buf, alive);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqualStrings(alive.node, decoded.alive.node);
    try std.testing.expectEqual(alive.incarnation, decoded.alive.incarnation);
    try std.testing.expectEqualStrings(alive.meta, decoded.alive.meta);
}

test "round-trip: suspect" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const suspect = Suspect{
        .node = "node-2",
        .addr = Address.initIp4([4]u8{ 10, 0, 0, 1 }, 7946),
        .incarnation = 2,
        .from = "node-1",
    };
    const n = try encodeSuspect(&buf, suspect);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqualStrings(suspect.node, decoded.suspect.node);
    try std.testing.expectEqual(suspect.incarnation, decoded.suspect.incarnation);
    try std.testing.expectEqualStrings(suspect.from, decoded.suspect.from);
}

test "round-trip: dead" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const dead = Dead{
        .node = "node-3",
        .addr = Address.initIp4([4]u8{ 172, 16, 0, 1 }, 7946),
        .incarnation = 1,
        .from = "node-1",
    };
    const n = try encodeDead(&buf, dead);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqualStrings(dead.node, decoded.dead.node);
    try std.testing.expectEqual(dead.incarnation, decoded.dead.incarnation);
    try std.testing.expectEqualStrings(dead.from, decoded.dead.from);
}

test "round-trip: compound" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;

    var inner1_buf: [128]u8 = undefined;
    const ping = Ping{ .seqno = 1, .node = "n1" };
    const n1 = try encodePing(&inner1_buf, ping);

    var inner2_buf: [128]u8 = undefined;
    const nack = Nack{ .seqno = 2 };
    const n2 = try encodeNack(&inner2_buf, nack);

    const messages = [_]CompoundMessage{
        .{ .msg_type = .ping, .payload = inner1_buf[1..n1] },
        .{ .msg_type = .nack, .payload = inner2_buf[1..n2] },
    };

    const n = try encodeCompound(&buf, &messages);
    var decoded = try decode(allocator, buf[0..n]);
    defer freeDecoded(&decoded, allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.compound.messages.items.len);
}

test "decode truncated" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TruncatedMessage, decode(allocator, &.{}));
    try std.testing.expectError(error.TruncatedMessage, decode(allocator, &.{@intFromEnum(MessageType.ping), 0}));
}
