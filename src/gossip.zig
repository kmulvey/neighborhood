//! Gossip dissemination — transmit-limited priority queue for SWIM messages.
//!
//! Messages are ordered by (retransmit_count ASC, msg_len DESC, id DESC)
//! so newer messages are sent first.  After `retransmit_mult * log2(N+1)`
//! retransmissions, a message is dropped.  Newer messages about the same
//! node invalidate older ones.

const std = @import("std");

/// A single message in the transmit queue.
pub const QueuedMessage = struct {
    /// Node name for invalidation tracking.
    node: []const u8,
    /// Encoded message payload (owned by the queue).
    payload: []const u8,
    /// Number of times this message has been transmitted.
    transmits: u32,
    /// Message length (cached for ordering).
    msg_len: u32,
    /// Monotonically-increasing ID for FIFO tie-breaking.
    id: u64,
};

/// Transmit-limited queue with priority ordering and invalidation.
pub const TransmitLimitedQueue = struct {
    allocator: std.mem.Allocator,
    /// All queued messages.
    messages: std.ArrayListUnmanaged(QueuedMessage),
    /// Maps node name → index in `messages` for invalidation.
    node_index: std.StringHashMapUnmanaged(usize),
    /// Retransmit multiplier.
    retransmit_mult: u8,
    /// Function to get current node count.
    num_nodes_fn: *const fn () usize,
    /// Next message ID.
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator, retransmit_mult: u8, num_nodes_fn: *const fn () usize) TransmitLimitedQueue {
        return .{
            .allocator = allocator,
            .messages = .{ .items = &.{}, .capacity = 0 },
            .node_index = .{},
            .retransmit_mult = retransmit_mult,
            .num_nodes_fn = num_nodes_fn,
            .next_id = 0,
        };
    }

    pub fn deinit(self: *TransmitLimitedQueue) void {
        for (self.messages.items) |*msg| {
            self.allocator.free(msg.node);
            self.allocator.free(msg.payload);
        }
        self.messages.deinit(self.allocator);
        self.node_index.deinit(self.allocator);
    }

    /// Maximum retransmissions for a message:
    ///   retransmit_mult * ceil(log2(N+1))
    pub fn maxTransmits(self: *const TransmitLimitedQueue) u32 {
        const n: f64 = @floatFromInt(self.num_nodes_fn());
        const log2_n1 = @ceil(@log2(n + 1.0));
        const max: f64 = @floatFromInt(self.retransmit_mult);
        return @intFromFloat(@ceil(max * log2_n1));
    }

    /// Queue a message for broadcast.  If a message for the same node
    /// already exists, it is invalidated (replaced).
    pub fn queueMsg(self: *TransmitLimitedQueue, node: []const u8, payload: []const u8) !void {
        const node_owned = try self.allocator.dupe(u8, node);
        errdefer self.allocator.free(node_owned);
        const payload_owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(payload_owned);

        // Invalidate any existing message for this node.
        if (self.node_index.get(node)) |idx| {
            var old = &self.messages.items[idx];
            self.allocator.free(old.node);
            self.allocator.free(old.payload);
            old.node = node_owned;
            old.payload = payload_owned;
            old.transmits = 0;
            old.msg_len = @intCast(payload_owned.len);
            old.id = self.next_id;
            self.next_id += 1;
            return;
        }

        const id = self.next_id;
        self.next_id += 1;

        const msg = QueuedMessage{
            .node = node_owned,
            .payload = payload_owned,
            .transmits = 0,
            .msg_len = @intCast(payload_owned.len),
            .id = id,
        };

        const idx = self.messages.items.len;
        try self.messages.append(self.allocator, msg);
        try self.node_index.put(self.allocator, node_owned, idx);
    }

    /// Get the next batch of messages to gossip, up to `max_bytes` total.
    /// Returns messages that haven't yet reached the retransmit limit,
    /// ordered by priority.  Increments transmit counts.
    ///
    /// Each returned QueuedMessage owns its .node and .payload — caller must
    /// free them with freeMessages().
    pub fn getMessages(self: *TransmitLimitedQueue, max_bytes: usize) ![]QueuedMessage {
        var result: std.ArrayListUnmanaged(QueuedMessage) = .empty;

        const max_tx = self.maxTransmits();
        var total_bytes: usize = 0;

        // Build a sorted list of eligible messages.
        var eligible: std.ArrayListUnmanaged(usize) = .empty;
        defer eligible.deinit(self.allocator);

        for (self.messages.items, 0..) |_, i| {
            if (self.messages.items[i].transmits < max_tx) {
                try eligible.append(self.allocator, i);
            }
        }

        // Sort eligible by priority: (transmits ASC, msg_len DESC, id DESC)
        const ctx = self;
        std.mem.sort(usize, eligible.items, ctx, lessFn);

        // Collect indices that hit the retransmit limit, then swapRemove
        // them in reverse order so lower indices stay valid.
        var to_remove: std.ArrayListUnmanaged(usize) = .empty;
        defer to_remove.deinit(self.allocator);

        for (eligible.items) |i| {
            const msg = &self.messages.items[i];
            if (total_bytes + msg.payload.len > max_bytes) continue;
            total_bytes += msg.payload.len;

            // Copy message into result with dup'd payload + node, so removals
            // below don't dangle the pointers in result.
            const node_dup = try self.allocator.dupe(u8, msg.node);
            errdefer self.allocator.free(node_dup);
            const payload_dup = try self.allocator.dupe(u8, msg.payload);
            errdefer self.allocator.free(payload_dup);
            try result.append(self.allocator, .{
                .node = node_dup,
                .payload = payload_dup,
                .transmits = msg.transmits,
                .msg_len = msg.msg_len,
                .id = msg.id,
            });
            msg.transmits += 1;

            if (msg.transmits >= max_tx) {
                try to_remove.append(self.allocator, i);
            }
        }

        // Remove in descending order so earlier indices stay valid after
        // each swapRemove.  Update node_index for every moved element.
        if (to_remove.items.len > 0) {
            std.mem.sort(usize, to_remove.items, {}, struct {
                fn desc(_: void, a: usize, b: usize) bool { return a > b; }
            }.desc);
            for (to_remove.items) |ri| {
                _ = self.node_index.remove(self.messages.items[ri].node);
                self.allocator.free(self.messages.items[ri].node);
                self.allocator.free(self.messages.items[ri].payload);
                _ = self.messages.swapRemove(ri);
                // If a different element moved into slot ri, update its index.
                if (ri < self.messages.items.len) {
                    try self.node_index.put(self.allocator, self.messages.items[ri].node, ri);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Sort comparator for priority ordering.
    fn lessFn(ctx: *const TransmitLimitedQueue, a_idx: usize, b_idx: usize) bool {
        const a = ctx.messages.items[a_idx];
        const b = ctx.messages.items[b_idx];
        if (a.transmits < b.transmits) return true;
        if (a.transmits > b.transmits) return false;
        if (a.msg_len > b.msg_len) return true;
        if (a.msg_len < b.msg_len) return false;
        return a.id > b.id;
    }

    /// Number of queued messages.
    pub fn len(self: *const TransmitLimitedQueue) usize {
        return self.messages.items.len;
    }
};

/// Free a slice of QueuedMessages returned by getMessages(), including
/// each entry's .node and .payload.
pub fn freeMessages(alloc: std.mem.Allocator, msgs: []QueuedMessage) void {
    for (msgs) |m| {
        alloc.free(m.node);
        alloc.free(m.payload);
    }
    alloc.free(msgs);
}

// ==============================================================
// Tests
// ==============================================================

test "transmit limited queue ordering" {
    const allocator = std.testing.allocator;
    var q = TransmitLimitedQueue.init(allocator, 4, struct {
        fn f() usize {
            return 3;
        }
    }.f);
    defer q.deinit();

    try q.queueMsg("node-a", "payload-a");
    try q.queueMsg("node-b", "payload-b");
    try q.queueMsg("node-c", "payload-ccc");

    const msgs = try q.getMessages(1024);
    defer freeMessages(allocator, msgs);

    // All should be returned (0 transmits each)
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    // First should be lowest ID (first queued)
    try std.testing.expectEqualStrings("node-a", msgs[0].node);
}

test "transmit limited queue byte budget" {
    const allocator = std.testing.allocator;
    var q = TransmitLimitedQueue.init(allocator, 4, struct {
        fn f() usize {
            return 3;
        }
    }.f);
    defer q.deinit();

    try q.queueMsg("node-a", "aaaa"); // 4 bytes
    try q.queueMsg("node-b", "bbbbbbbbbb"); // 10 bytes

    // Budget only allows first message
    const msgs = try q.getMessages(5);
    defer freeMessages(allocator, msgs);

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
}

test "transmit limited queue invalidation" {
    const allocator = std.testing.allocator;
    var q = TransmitLimitedQueue.init(allocator, 4, struct {
        fn f() usize {
            return 3;
        }
    }.f);
    defer q.deinit();

    try q.queueMsg("node-a", "old-payload");
    try q.queueMsg("node-a", "new-payload"); // Invalidates old

    try std.testing.expectEqual(@as(usize, 1), q.len());
    const msgs = try q.getMessages(1024);
    defer freeMessages(allocator, msgs);
    try std.testing.expectEqualStrings("new-payload", msgs[0].payload);
}
