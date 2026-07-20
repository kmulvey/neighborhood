//! Configuration for the neighborhood SWIM membership library.
//!
//! All durations are in milliseconds for user convenience.  Internally
//! the library converts to nanoseconds where needed.

const std = @import("std");
const types = @import("types.zig");

pub const Config = struct {
    /// Unique name of this node in the cluster.
    name: []const u8,

    /// Address to bind the UDP listener to (default "0.0.0.0").
    bind_addr: []const u8 = "0.0.0.0",
    /// Port to bind the UDP listener to (default 7946 — memberlist default).
    bind_port: u16 = 7946,

    /// Advertised address and port (for NAT traversal).  When empty,
    /// the bound address is advertised.
    advertise_addr: ?[]const u8 = null,
    advertise_port: ?u16 = null,

    // -----------------------------------------------------------
    // Timing parameters (all in milliseconds)
    // -----------------------------------------------------------

    /// Interval between protocol probe rounds.  Each round, the node
    /// picks one peer, pings it, and on timeout dispatches indirect
    /// probes through K peers.  (Default: 1 second.)
    protocol_period_ms: u32 = 1000,

    /// Number of indirect probe peers (SWIM parameter K).  (Default: 3.)
    indirect_checks: u8 = 3,

    /// Multiplier for gossip retransmission count:
    ///   retransmits = retransmit_mult * ceil(log2(N+1))
    /// (Default: 4.)
    retransmit_mult: u8 = 4,

    /// Multiplier for the suspicion timeout:
    ///   suspicion_timeout = suspicion_mult * ceil(log2(N+1)) * protocol_period
    /// (Default: 5.)
    suspicion_mult: u8 = 5,

    /// Upper-bound multiplier on suspicion timeout:
    ///   suspicion_max_timeout = suspicion_max_timeout_mult * suspicion_timeout
    /// (Default: 6.)
    suspicion_max_timeout_mult: u8 = 6,

    /// Interval for full TCP state sync (push/pull) with a random peer.
    /// 0 disables push/pull.  (Default: 30 seconds.)
    push_pull_interval_ms: u32 = 30_000,

    /// Interval for gossip emission rounds.  0 disables gossip.
    /// (Default: 200 ms.)
    gossip_interval_ms: u32 = 200,

    /// Number of random nodes targeted per gossip round.
    /// (Default: 3.)
    gossip_nodes: u8 = 3,

    /// Timeout for TCP connections (stream dials and I/O).
    /// (Default: 10 seconds.)
    tcp_timeout_ms: u32 = 10_000,

    // -----------------------------------------------------------
    // Protocol version
    // -----------------------------------------------------------

    /// Protocol version spoken by this node (must be within
    /// [protocol_version_min .. protocol_version_max]).
    protocol_version: u8 = types.protocol_version_current,

    // -----------------------------------------------------------
    // Limits
    // -----------------------------------------------------------

    /// Maximum bytes of per-node metadata included in alive messages.
    meta_max_size: usize = types.meta_max_size,

    // -----------------------------------------------------------
    // Validation
    // -----------------------------------------------------------

    /// Validate all invariants.  Returns the first error found.
    pub fn validate(self: Config) !void {
        if (self.name.len == 0) return error.NameRequired;
        if (self.name.len > types.max_name_len) return error.NameTooLong;
        if (self.protocol_period_ms == 0) return error.ProtocolPeriodZero;
        if (self.indirect_checks == 0) return error.IndirectChecksZero;
        if (self.protocol_version < types.protocol_version_min) return error.ProtocolVersionTooLow;
        if (self.protocol_version > types.protocol_version_max) return error.ProtocolVersionTooHigh;
        if (self.gossip_nodes == 0 and self.gossip_interval_ms > 0) return error.GossipNodesZero;
    }
};

test "Config defaults pass validation" {
    const cfg = Config{ .name = "test-node" };
    try cfg.validate();
}

test "Config: name required" {
    const cfg = Config{ .name = "" };
    try std.testing.expectError(error.NameRequired, cfg.validate());
}

test "Config: protocol version bounds" {
    var cfg = Config{ .name = "n", .protocol_version = 0 };
    try std.testing.expectError(error.ProtocolVersionTooLow, cfg.validate());
    cfg.protocol_version = 255;
    try std.testing.expectError(error.ProtocolVersionTooHigh, cfg.validate());
}

test "Config: indirect checks zero" {
    const cfg = Config{ .name = "n", .indirect_checks = 0 };
    try std.testing.expectError(error.IndirectChecksZero, cfg.validate());
}

test "Config: gossip nodes zero with interval > 0" {
    const cfg = Config{ .name = "n", .gossip_nodes = 0, .gossip_interval_ms = 100 };
    try std.testing.expectError(error.GossipNodesZero, cfg.validate());
}
