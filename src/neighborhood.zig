//! neighborhood — SWIM-based gossip membership and failure detection.
//!
//! This library provides weakly-consistent cluster membership with
//! constant-time failure detection and logarithmic gossip dissemination.
//! It is based on the SWIM paper (Das, Gupta, Motivala, DSN '02) and
//! inspired by HashiCorp's memberlist.
//!
//! Two usage modes:
//!
//! **State machine (caller-driven):**
//! ```zig
//! const nb = @import("neighborhood");
//! var ml = try nb.Memberlist.init(allocator, config);
//! defer ml.deinit();
//!
//! // In your event loop:
//! const actions = ml.tick(now);
//! for (actions) |a| { /* send packets, notify app */ }
//! // On incoming packets:
//! const more_actions = ml.handlePacket(data, from, addr, now);
//! ```
//!
//! **Batteries-included (library-driven):**
//! ```zig
//! const nb = @import("neighborhood");
//! var n = try nb.Neighborhood.init(allocator, config);
//! defer n.deinit();
//! try n.join(known_nodes);
//! ```
//!
//! Explicit allocators throughout — no global state.

pub const types = @import("types.zig");
pub const config = @import("config.zig");
pub const protocol = @import("protocol.zig");
pub const suspicion = @import("suspicion.zig");
pub const gossip = @import("gossip.zig");
pub const memberlist = @import("memberlist.zig");
pub const state_sync = @import("state_sync.zig");
pub const transport = @import("transport.zig");
pub const neighborhood = @import("neighborhood_impl.zig");

// Re-export key types at the top level
pub const Config = config.Config;
pub const Node = types.Node;
pub const NodeId = types.NodeId;
pub const NodeState = types.NodeState;
pub const Incarnation = types.Incarnation;
pub const Address = types.Address;
pub const MessageType = types.MessageType;
pub const Action = types.Action;
pub const ActionTag = types.ActionTag;
pub const Memberlist = memberlist.Memberlist;
pub const freeActions = memberlist.freeActions;
pub const Neighborhood = neighborhood.Neighborhood;

// Wire types
pub const Ping = types.Ping;
pub const IndirectPing = types.IndirectPing;
pub const Ack = types.Ack;
pub const Nack = types.Nack;
pub const Suspect = types.Suspect;
pub const Alive = types.Alive;
pub const Dead = types.Dead;
pub const Compound = types.Compound;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
