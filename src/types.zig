//! Core type definitions for the neighborhood SWIM membership library.
//!
//! Defines node identity, state machine enums, incarnation numbers,
//! and wire-format message structs.

const std = @import("std");

// ---------------------------------------------------------------
// Node identity
// ---------------------------------------------------------------

/// Maximum length of a node name.
pub const max_name_len = 255;

/// A node name — opaque byte sequence, caller-chosen.
pub const NodeId = []const u8;

/// Network address: IPv4/IPv6 + port, using raw bytes.
pub const Address = struct {
    /// Raw IP bytes: 4 for IPv4, 16 for IPv6.
    ip: [16]u8,
    /// Port in host byte order.
    port: u16,
    /// 4 for IPv4, 16 for IPv6.
    ip_len: u8,

    pub fn initIp4(ip: [4]u8, port: u16) Address {
        var a = Address{ .ip = [_]u8{0} ** 16, .port = port, .ip_len = 4 };
        @memcpy(a.ip[0..4], &ip);
        return a;
    }

    pub fn parseIp4(ip_str: []const u8, port: u16) !Address {
        // Parse "a.b.c.d" into [4]u8
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, ip_str, '.');
        var i: usize = 0;
        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidAddress;
            parts[i] = try std.fmt.parseInt(u8, part, 10);
        }
        if (i != 4) return error.InvalidAddress;
        return initIp4(parts, port);
    }

    pub fn eql(self: Address, other: Address) bool {
        return self.port == other.port and
            self.ip_len == other.ip_len and
            std.mem.eql(u8, self.ip[0..self.ip_len], other.ip[0..other.ip_len]);
    }
};

// ---------------------------------------------------------------
// Node state
// ---------------------------------------------------------------

/// The four stable states a remote node can be in.
pub const NodeState = enum(u8) {
    alive,
    suspect,
    dead,
    left,

    pub fn label(s: NodeState) []const u8 {
        return switch (s) {
            .alive => "alive",
            .suspect => "suspect",
            .dead => "dead",
            .left => "left",
        };
    }
};

// ---------------------------------------------------------------
// Incarnation number
// ---------------------------------------------------------------

/// Monotonically-increasing incarnation counter for a node.
/// Initialised to 0 on join; a node increments its own incarnation
/// when it learns it has been falsely suspected.
pub const Incarnation = u32;

// ---------------------------------------------------------------
// Node
// ---------------------------------------------------------------

/// Full information about a known remote node.
pub const Node = struct {
    name: []const u8,
    addr: Address,
    incarnation: Incarnation,
    state: NodeState,
    protocol_version: u8,

    /// Owned by the allocator that created this Node.
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    /// Deep-copy the node.  Caller owns the returned Node and must
    /// call `deinit` on it.
    pub fn clone(self: Node, allocator: std.mem.Allocator) !Node {
        const name = try allocator.dupe(u8, self.name);
        return Node{
            .name = name,
            .addr = self.addr,
            .incarnation = self.incarnation,
            .state = self.state,
            .protocol_version = self.protocol_version,
        };
    }

    /// Compare nodes by name and address — used for deduplication.
    pub fn eql(self: Node, other: Node) bool {
        return std.mem.eql(u8, self.name, other.name) and self.addr.eql(other.addr);
    }
};

// ---------------------------------------------------------------
// Wire message types
// ---------------------------------------------------------------

/// Protocol message type discriminant.
/// ONLY APPEND — the numeric values are part of the wire protocol.
pub const MessageType = enum(u8) {
    ping = 0,
    indirect_ping = 1,
    ack = 2,
    nack = 3,
    suspect = 4,
    alive = 5,
    dead = 6,
    compound = 7,
    user = 8,

    _,
};

/// A ping message sent directly to a target.
pub const Ping = struct {
    seqno: u32,
    /// The target node name — lets the receiver verify it was the
    /// intended recipient.
    node: []const u8,
};

/// An indirect ping forwarded through a peer to the target.
pub const IndirectPing = struct {
    seqno: u32,
    target_addr: Address,
    /// The target node name (for verification).
    node: []const u8,
};

/// Positive acknowledgement with optional piggybacked gossip.
pub const Ack = struct {
    seqno: u32,
    payload: []const u8,
};

/// Negative acknowledgement.
pub const Nack = struct {
    seqno: u32,
};

/// A suspicion message gossiped through the cluster.
pub const Suspect = struct {
    node: []const u8,
    addr: Address,
    incarnation: Incarnation,
    from: []const u8,
};

/// An alive message (refutation or join announcement).
pub const Alive = struct {
    node: []const u8,
    addr: Address,
    incarnation: Incarnation,
    meta: []const u8,
};

/// A dead/left message distributed through the cluster.
pub const Dead = struct {
    node: []const u8,
    addr: Address,
    incarnation: Incarnation,
    from: []const u8,
};

/// A compound message carrying multiple piggybacked gossip updates.
pub const Compound = struct {
    messages: []struct {
        msg_type: MessageType,
        payload: []const u8,
    },
};

/// Free-form user message not interpreted by the library.
pub const UserMessage = struct {
    payload: []const u8,
};

// ---------------------------------------------------------------
// Action — what the state machine tells the caller to do
// ---------------------------------------------------------------

/// An action the state machine requires the caller to perform after
/// a `tick()` or `handlePacket()` call.
pub const ActionTag = enum {
    send_ping,
    send_indirect_ping,
    send_ack,
    send_nack,
    send_gossip,
    dial_push_pull,
    node_suspected,
    node_failed,
    node_alive,
    node_left,
    /// Full state ready for push/pull.
    push_pull_state,
    user_message,
};

pub const Action = union(ActionTag) {
    send_ping: SendPing,
    send_indirect_ping: SendIndirectPing,
    send_ack: SendAck,
    send_nack: SendNack,
    send_gossip: SendGossip,
    dial_push_pull: DialPushPull,
    node_suspected: NodeEvent,
    node_failed: NodeEvent,
    node_alive: NodeEvent,
    node_left: NodeEvent,
    push_pull_state: PushPullState,
    user_message: ActionUserMessage,
};

pub const ActionUserMessage = struct {
    payload: []const u8,
};

pub const SendPing = struct {
    target: []const u8,
    target_addr: Address,
    seqno: u32,
};

pub const SendIndirectPing = struct {
    peer: []const u8,
    peer_addr: Address,
    target: []const u8,
    target_addr: Address,
    seqno: u32,
};

pub const SendAck = struct {
    target_addr: Address,
    seqno: u32,
    payload: []const u8,
};

pub const SendNack = struct {
    target_addr: Address,
    seqno: u32,
};

pub const SendGossip = struct {
    target_addrs: []const Address,
    payload: []const u8,
};

pub const DialPushPull = struct {
    peer: []const u8,
    peer_addr: Address,
};

pub const NodeEvent = struct {
    node: []const u8,
    addr: Address,
};

pub const PushPullState = struct {
    peer: []const u8,
    peer_addr: Address,
    state_bytes: []const u8,
};

/// Protocol version constants.
pub const protocol_version_min: u8 = 1;
pub const protocol_version_max: u8 = 1;
pub const protocol_version_current: u8 = 1;

/// Maximum size for node metadata.
pub const meta_max_size: usize = 512;

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "NodeState labels" {
    try std.testing.expectEqualStrings("alive", NodeState.alive.label());
    try std.testing.expectEqualStrings("suspect", NodeState.suspect.label());
    try std.testing.expectEqualStrings("dead", NodeState.dead.label());
    try std.testing.expectEqualStrings("left", NodeState.left.label());
}

test "Node clone and eql" {
    const allocator = std.testing.allocator;
    const n1 = Node{
        .name = "node1",
        .addr = Address.initIp4([4]u8{ 127, 0, 0, 1 }, 7946),
        .incarnation = 0,
        .state = .alive,
        .protocol_version = 1,
    };
    var n2 = try n1.clone(allocator);
    defer n2.deinit(allocator);

    try std.testing.expect(n1.eql(n2));
    n2.incarnation = 1;
    try std.testing.expect(n1.eql(n2)); // eql only compares name+addr
}
