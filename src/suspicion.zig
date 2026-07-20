//! Suspicion mechanism — the logarithmic timeout acceleration from SWIM §4.2.
//!
//! When a node is suspected, a timer starts at `max_timeout`.  Each independent
//! confirmation from another node accelerates the timer logarithmically toward
//! `min_timeout`.  When the timer expires, the node is declared dead.

const std = @import("std");

/// Tracks the suspicion state for a single remote node.
pub const Suspicion = struct {
    /// Number of independent confirmations received so far.
    n: i32,
    /// Target number of confirmations for minimum timeout.
    k: i32,
    /// Minimum timeout (when k+ confirmations are received).
    min_ms: i64,
    /// Maximum timeout (starting value, when 0 confirmations).
    max_ms: i64,
    /// Monotonic timestamp (ms) when the timer was started.
    start_ms: i64,
    /// Set of "from" nodes that have confirmed this suspicion (dedup).
    confirmations: std.StringHashMapUnmanaged(void),

    /// Initialise a new suspicion timer.
    pub fn init(
        allocator: std.mem.Allocator,
        from: []const u8,
        k: u8,
        min_ms: i64,
        max_ms: i64,
        start_ms: i64,
    ) !Suspicion {
        var confirmations = std.StringHashMapUnmanaged(void){};
        // Exclude the "from" node from confirmations (SWIM: we may get our
        // own suspicion gossiped back to us).
        try confirmations.put(allocator, from, {});
        return Suspicion{
            .n = 0,
            .k = @intCast(k),
            .min_ms = min_ms,
            .max_ms = max_ms,
            .start_ms = start_ms,
            .confirmations = confirmations,
        };
    }

    /// Free resources.
    pub fn deinit(self: *Suspicion, allocator: std.mem.Allocator) void {
        self.confirmations.deinit(allocator);
    }

    /// Compute the remaining timeout given the current state.
    /// May return negative values — callers should fire the timer immediately.
    pub fn remainingMs(self: *const Suspicion, now_ms: i64) i64 {
        return remainingSuspicionTime(self.n, self.k, now_ms - self.start_ms, self.min_ms, self.max_ms);
    }

    /// Register a confirmation from `from`.  Returns true if this was new
    /// information (i.e. it actually accelerated the timer).
    pub fn confirm(self: *Suspicion, from: []const u8, allocator: std.mem.Allocator) !bool {
        // Cap at k confirmations — if we already have enough, stop.
        if (self.n >= self.k) return false;

        // Dedup: only one confirmation per source.
        if (self.confirmations.contains(from)) return false;
        try self.confirmations.put(allocator, from, {});

        self.n += 1;
        return true;
    }
};

/// The core formula from SWIM §4.2:
///
///   frac = log(n + 1) / log(k + 1)
///   raw  = max - frac * (max - min)
///   timeout = floor(raw * 1000) / 1000  (rounded to ms)
///   remaining = timeout - elapsed
///
/// Returns the remaining time; negative means "expired".
pub fn remainingSuspicionTime(n: i32, k: i32, elapsed_ms: i64, min_ms: i64, max_ms: i64) i64 {
    if (k < 1) {
        return min_ms - elapsed_ms;
    }
    if (n >= k) {
        return min_ms - elapsed_ms;
    }

    const n_f: f64 = @floatFromInt(n);
    const k_f: f64 = @floatFromInt(k);
    const max_f: f64 = @floatFromInt(max_ms);
    const min_f: f64 = @floatFromInt(min_ms);
    const elapsed_f: f64 = @floatFromInt(elapsed_ms);

    const frac = @log(n_f + 1.0) / @log(k_f + 1.0);
    const raw = max_f - frac * (max_f - min_f);
    const timeout: i64 = @intFromFloat(@floor(raw));
    return timeout - @as(i64, @intFromFloat(elapsed_f));
}

// ==============================================================
// Awareness — local health score
// ==============================================================

/// Awareness tracks the local node's estimated health (ability to respond
/// in soft real-time).  Lower scores are healthier.  Timeouts are scaled
/// by (score + 1), so a struggling node gives other nodes more time.
pub const Awareness = struct {
    /// Maximum score (exclusive upper bound).
    max: i32,
    /// Current score (0 = healthy).
    score: i32,

    pub fn init(max: i32) Awareness {
        return Awareness{ .max = max, .score = 0 };
    }

    /// Apply a delta to the score, clamping to [0, max-1].
    pub fn applyDelta(self: *Awareness, delta: i32) void {
        self.score += delta;
        if (self.score < 0) self.score = 0;
        if (self.score >= self.max) self.score = self.max - 1;
    }

    /// Scale a timeout by the current health score.
    pub fn scaleTimeout(self: *const Awareness, timeout_ms: i64) i64 {
        return timeout_ms * (@as(i64, self.score) + 1);
    }

    pub fn getScore(self: *const Awareness) i32 {
        return self.score;
    }
};

// ==============================================================
// Tests
// ==============================================================

test "remainingSuspicionTime: at max (no confirmations)" {
    // With 0 confirmations out of k=5, remaining should be close to max - elapsed
    const rem = remainingSuspicionTime(0, 5, 0, 2000, 10000);
    try std.testing.expect(rem >= 9900);
    try std.testing.expect(rem <= 10000);
}

test "remainingSuspicionTime: at min (k confirmations)" {
    const rem = remainingSuspicionTime(5, 5, 0, 2000, 10000);
    try std.testing.expectEqual(@as(i64, 2000), rem);
}

test "remainingSuspicionTime: halfway" {
    // With n=1 out of k=5, remaining should be between min and max
    const rem = remainingSuspicionTime(1, 5, 0, 2000, 10000);
    try std.testing.expect(rem > 2000);
    try std.testing.expect(rem < 10000);
}

test "remainingSuspicionTime: k=0 uses min immediately" {
    const rem = remainingSuspicionTime(0, 0, 0, 2000, 10000);
    try std.testing.expectEqual(@as(i64, 2000), rem);
}

test "remainingSuspicionTime: elapsed reduces remaining" {
    const rem_no_elapsed = remainingSuspicionTime(0, 5, 0, 2000, 10000);
    const rem_elapsed = remainingSuspicionTime(0, 5, 500, 2000, 10000);
    try std.testing.expect(rem_elapsed < rem_no_elapsed);
}

test "suspicion confirm dedup" {
    const allocator = std.testing.allocator;
    var s = try Suspicion.init(allocator, "node-a", 3, 1000, 10000, 0);
    defer s.deinit(allocator);

    // First confirmation from node-b should be accepted.
    try std.testing.expect(try s.confirm("node-b", allocator));
    try std.testing.expectEqual(@as(i32, 1), s.n);

    // Duplicate from node-b should be rejected.
    try std.testing.expect(!try s.confirm("node-b", allocator));
    try std.testing.expectEqual(@as(i32, 1), s.n);

    // New confirmation from node-c should be accepted.
    try std.testing.expect(try s.confirm("node-c", allocator));
    try std.testing.expectEqual(@as(i32, 2), s.n);

    // "from" node (node-a) should be excluded (already in confirmations).
    try std.testing.expect(!try s.confirm("node-a", allocator));
}

test "suspicion confirm caps at k" {
    const allocator = std.testing.allocator;
    var s = try Suspicion.init(allocator, "node-a", 2, 1000, 10000, 0);
    defer s.deinit(allocator);

    try std.testing.expect(try s.confirm("node-b", allocator));
    try std.testing.expect(try s.confirm("node-c", allocator));
    try std.testing.expectEqual(@as(i32, 2), s.n);

    // Third confirmation should be rejected (k=2 reached).
    try std.testing.expect(!try s.confirm("node-d", allocator));
    try std.testing.expectEqual(@as(i32, 2), s.n);
}

test "awareness score scaling" {
    var a = Awareness.init(8);
    try std.testing.expectEqual(@as(i64, 100), a.scaleTimeout(100)); // score=0, scale=1x

    a.applyDelta(2);
    try std.testing.expectEqual(@as(i64, 300), a.scaleTimeout(100)); // score=2, scale=3x

    a.applyDelta(-1);
    try std.testing.expectEqual(@as(i64, 200), a.scaleTimeout(100)); // score=1, scale=2x
}
