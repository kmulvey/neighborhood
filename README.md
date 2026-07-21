# Neighborhood

SWIM-based gossip membership and failure detection for Zig 0.16.0.

![Fred Rogers](./Fred-Rogers.jpg "Fred Rogers")

---

## Overview

Neighborhood provides weakly-consistent cluster membership with constant-time failure detection and logarithmic gossip dissemination. It is based on the [SWIM paper](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf) (Das, Gupta, Motivala, DSN '02) and inspired by HashiCorp's [memberlist](https://github.com/hashicorp/memberlist).

**Zero dependencies** — pure Zig standard library.

Two layers:

| Layer | What it does | When to use |
|-------|-------------|-------------|
| `Memberlist` | Pure state machine — no I/O, no threads | You control networking (any event loop, io_uring, embedded) |
| `Neighborhood` | `Memberlist` + UDP transport + background thread | Quick start, standard setups |

---

## Quick start

```zig
const nb = @import("neighborhood");

// State machine mode (caller-owned networking)
var ml = try nb.Memberlist.init(allocator, .{ .name = "node-1" });
defer ml.deinit();

// In your event loop:
const actions = try ml.tick(now_ms, allocator);
defer nb.freeActions(allocator, actions);
for (actions) |a| {
    switch (a) {
        .send_ping => |sp| sendPing(sp.target_addr, sp.payload),
        .send_ack  => |sa| sendAck(sa.target_addr, sa.payload),
        .node_alive => |ev| log.info("{s} joined", .{ev.node}),
        // ... see types.zig Action enum
        else => {},
    }
}

// On incoming packets:
const rx_actions = try ml.handlePacket(data, from_addr, from_name, now_ms, allocator);
defer nb.freeActions(allocator, rx_actions);
```

```zig
// Batteries-included mode
var n = try nb.Neighborhood.init(allocator, .{ .name = "node-1" });
defer n.deinit();
try n.join(&.{ .{ .name = "seed", .addr = seed_addr, ... } });
// Background thread handles UDP + state machine automatically.
```

---

## SWIM protocol

The state machine implements the full SWIM lifecycle:

```
  idle
    │
    ├─ tick → advance probe_index, emit send_ping
    │
  waiting_direct
    │
    ├─ ack received → idle (probe succeeds)
    ├─ timeout → dispatchIndirect (pick K peers)
    │
  waiting_indirect
    │
    ├─ any indirect ack → idle
    ├─ deadline → markSuspect → create suspicion timer
    │
  suspicion timer
    │
    ├─ confirmations accelerate timer logarithmically
    ├─ alive refutation cancels timer
    └─ timeout → markDead
```

Key SWIM features:
- **Round-robin probing** (SWIM §4.3) with Fisher-Yates reshuffle on wrap-around
- **Logarithmic suspicion timeout** (SWIM §4.2) matching Go memberlist exactly
- **Transmit-limited gossip** with priority ordering and invalidation
- **Incarnation numbers** for self-refutation and ordering
- **Indirect ping** through K random peers before suspecting
- **Dead/left node compaction** in probe order on wrap-around

---

## API: `Memberlist`

```zig
pub const Memberlist = struct {
    // Create the state machine. config.name is the only required field.
    pub fn init(allocator: std.mem.Allocator, config: Config) !Memberlist;
    pub fn deinit(self: *Memberlist) void;

    // Drive time forward. Returns owned slice of Action — must call freeActions.
    pub fn tick(self: *Memberlist, now_ms: i64, alloc: std.mem.Allocator) ![]Action;

    // Feed a raw network packet. Returns owned slice of Action.
    pub fn handlePacket(
        self: *Memberlist, data: []const u8, from_addr: Address,
        from_name: []const u8, timestamp_ms: i64, alloc: std.mem.Allocator,
    ) ![]Action;

    // Bootstrap with known peers (emits dial_push_pull actions).
    pub fn join(self: *Memberlist, known_nodes: []const Node) ![]Action;
    pub fn leave(self: *Memberlist) ![]Action;

    pub fn nodeCount(self: *const Memberlist) usize;
    pub fn aliveNodes(self: *const Memberlist, alloc: std.mem.Allocator) ![]Node;
};

/// Free actions returned by tick() / handlePacket(). Uses the same allocator.
pub fn freeActions(alloc: std.mem.Allocator, actions: []Action) void;
```

---

## API: `Config`

```zig
pub const Config = struct {
    name: []const u8,                  // required — unique node name

    // Network (defaults for Neighborhood wrapper)
    bind_addr: []const u8 = "0.0.0.0",
    bind_port: u16 = 7946,

    // Timing (all ms)
    protocol_period_ms: u32 = 1000,    // interval between probe rounds
    indirect_checks: u8 = 3,           // K — indirect probe peers
    retransmit_mult: u8 = 4,           // gossip retransmit = mult * ceil(log₂(N+1))
    suspicion_mult: u8 = 5,            // suspicion timeout multiplier
    suspicion_max_timeout_mult: u8 = 6,// max = suspicion_mult × suspicion_max_timeout_mult × protocol_period
    push_pull_interval_ms: u32 = 30000,// TCP state sync interval (0 = off)
    gossip_interval_ms: u32 = 200,     // gossip emission interval (0 = off)
    gossip_nodes: u8 = 3,              // random peers targeted per gossip round

    // Protocol
    protocol_version: u8 = 1,
    tcp_timeout_ms: u32 = 10000,
    meta_max_size: usize = 512,
};
```

---

## Action types

`tick()` and `handlePacket()` return `[]Action`. Each Action is one of:

```zig
pub const Action = union(enum) {
    send_ping: struct { target: []const u8, target_addr: Address, seqno: u32 },
    send_indirect_ping: struct { peer: []const u8, peer_addr: Address, target: []const u8, target_addr: Address, seqno: u32 },
    send_ack: struct { target_addr: Address, seqno: u32, payload: []const u8 },
    send_nack: struct { target_addr: Address, seqno: u32 },
    send_gossip: struct { target_addrs: []const Address, payload: []const u8 },
    dial_push_pull: struct { peer: []const u8, peer_addr: Address },
    push_pull_state: struct { peer: []const u8, peer_addr: Address, state_bytes: []const u8 },
    node_alive: NodeEvent,
    node_suspected: NodeEvent,
    node_failed: NodeEvent,
    node_left: NodeEvent,
};
```

Network actions (`send_*`, `dial_*`) expect the caller to send the packet.
Node event actions (`node_*`) are notifications for application callbacks.

---

## Building

```sh
zig build test     # run all 43 tests (5 suites)
zig build lib      # build the library
```

---

## Design notes

- **No `std.io`** — manual buffer position tracking for freestanding compatibility.
- **No `std.net.Address`** — custom `Address` with raw IP bytes for freestanding.
- **`ArrayListUnmanaged`** throughout — explicit allocator at every call site.
- **Heap-allocated action payloads** — `freeActions()` frees all owned memory.
- **Suspicion keys owned** — `init`, `confirm`, and `deinit` in `suspicion.zig` own their map keys.

---

## Status

| Area | Status |
|------|--------|
| SWIM probe → suspect → dead lifecycle | ✅ |
| Indirect ping forwarding | ✅ |
| Suspicion timer (logarithmic acceleration) | ✅ |
| Gossip priority queue + invalidation | ✅ |
| Compound message decode/encode | ✅ |
| Self-suspect refutation | ✅ |
| State sync encode/decode/merge | ✅ |
| TCP push/pull state sync | TODO |
| Dead node compaction in tick | ✅ |
| Event loop (Neighborhood wrapper) | TODO |
| Real-network integration tests | TODO |
