//! Batteries-included convenience wrapper around the Memberlist state machine.
//!
//! Bundles a Memberlist + UdpTransport + background thread.  Callers who
//! want to control networking themselves should use Memberlist directly.

const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const memberlist_mod = @import("memberlist.zig");
const transport_mod = @import("transport.zig");

const Config = config_mod.Config;
const Memberlist = memberlist_mod.Memberlist;
const Node = types.Node;
const Action = types.Action;

pub const Neighborhood = struct {
    allocator: std.mem.Allocator,
    config: Config,
    memberlist: Memberlist,
    transport: transport_mod.UdpTransport,
    thread: ?std.Thread,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Neighborhood {
        var ml = try Memberlist.init(allocator, config);
        errdefer ml.deinit();

        var transport = try transport_mod.UdpTransport.init(
            allocator,
            config.bind_addr,
            config.bind_port,
        );
        errdefer transport.deinit();

        return Neighborhood{
            .allocator = allocator,
            .config = config,
            .memberlist = ml,
            .transport = transport,
            .thread = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Neighborhood) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
        }
        self.memberlist.deinit();
        self.transport.deinit();
        self.* = undefined;
    }

    /// List of alive nodes (caller owns the returned slice).
    pub fn aliveNodes(self: *Neighborhood, allocator: std.mem.Allocator) ![]Node {
        return self.memberlist.aliveNodes(allocator);
    }

    /// Join a cluster by contacting known nodes.
    pub fn join(self: *Neighborhood, known_nodes: []const Node) !void {
        const actions = try self.memberlist.join(known_nodes);
        defer self.allocator.free(actions);
        try self.executeActions(actions);
    }

    /// Gracefully leave the cluster.
    pub fn leave(self: *Neighborhood) !void {
        const actions = try self.memberlist.leave();
        defer self.allocator.free(actions);
        try self.executeActions(actions);
    }

    /// Execute a list of actions (send packets, etc.).
    fn executeActions(self: *Neighborhood, actions: []const Action) !void {
        for (actions) |action| {
            switch (action) {
                .send_ping => |sp| {
                    var buf: [128]u8 = undefined;
                    const n = try @import("protocol.zig").encodePing(&buf, .{
                        .seqno = sp.seqno,
                        .node = sp.target,
                    });
                    try self.transport.sendTo(buf[0..n], sp.target_addr);
                },
                .send_indirect_ping => |sip| {
                    var buf: [256]u8 = undefined;
                    const n = try @import("protocol.zig").encodeIndirectPing(&buf, .{
                        .seqno = sip.seqno,
                        .target_addr = sip.target_addr,
                        .node = sip.target,
                    });
                    try self.transport.sendTo(buf[0..n], sip.peer_addr);
                },
                .send_ack => |sa| {
                    try self.transport.sendTo(sa.payload, sa.target_addr);
                },
                .send_nack => |sn| {
                    var buf: [64]u8 = undefined;
                    const n = try @import("protocol.zig").encodeNack(&buf, .{ .seqno = sn.seqno });
                    try self.transport.sendTo(buf[0..n], sn.target_addr);
                },
                .send_gossip => |sg| {
                    for (sg.target_addrs) |addr| {
                        self.transport.sendTo(sg.payload, addr) catch {};
                    }
                },
                .dial_push_pull => |dpp| {
                    // Attempt TCP push/pull
                    const conn = transport_mod.dialTcp(
                        self.allocator,
                        dpp.peer_addr,
                        self.config.tcp_timeout_ms,
                    ) catch continue;
                    defer conn.close();
                    // TODO: full push/pull implementation
                },
                .node_suspected => |ne| {
                    // Callback: application notified
                    _ = ne;
                },
                .node_failed => |ne| {
                    _ = ne;
                },
                .node_alive => |ne| {
                    _ = ne;
                },
                .node_left => |ne| {
                    _ = ne;
                },
                .push_pull_state => |pps| {
                    _ = pps;
                    // TODO: send state over TCP
                },
            }
        }
    }
};
