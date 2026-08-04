//! Wall-clock-anchored fixed-period sample rings.
//!
//! The instrument's recurring bug shape is a ring that only advances when
//! a sample arrives: go idle and the newest bucket stays pinned under the
//! write head, so a chart captioned "last 15 minutes" keeps showing a
//! burst that ended an hour ago (`predict.BurnRate` had exactly this).
//! Every ring here advances on `now_ms` instead, so silence scrolls to
//! zero the way a real scope does.
//!
//! Two shapes, one clock discipline:
//! - `Series(T, capacity)` — one value per bucket, last write wins.
//!   Gauges: CPU load, memory pressure, a utilization percentage.
//! - `Accumulator(capacity)` — buckets SUM within their period.
//!   Counters: tokens, events, bytes.
//!
//! Both are fixed-size PODs with no allocator and no failure mode, so
//! they can sit directly in the Model and be journaled/replayed with it.
//! `bucket_index` is absolute (epoch_ms / period_ms), never a slot, so a
//! reader can always place a sample on a real clock.

const std = @import("std");

/// A sample paired with the wall-clock start of the bucket it covers.
pub fn Sample(comptime T: type) type {
    return struct { bucket_ms: i64, value: T };
}

/// Shared roll-forward math. `capacity` buckets of `period_ms` each.
fn Clock(comptime capacity: usize) type {
    return struct {
        /// Absolute bucket index (`@divFloor(ms, period_ms)`) of `head`.
        head_bucket: i64 = 0,
        /// Slot holding `head_bucket`.
        head: usize = 0,
        initialized: bool = false,

        const Self = @This();

        /// Buckets to roll forward to reach `bucket`, and whether the jump
        /// is large enough that the whole ring should simply be cleared.
        fn steps(self: *const Self, bucket: i64) ?struct { n: usize, clear_all: bool } {
            if (bucket <= self.head_bucket) return null;
            const delta = bucket - self.head_bucket;
            if (delta >= @as(i64, @intCast(capacity))) {
                return .{ .n = capacity, .clear_all = true };
            }
            return .{ .n = @intCast(delta), .clear_all = false };
        }

        /// Slot for `bucket`, or null when it is outside the live window.
        fn slotFor(self: *const Self, bucket: i64) ?usize {
            if (bucket > self.head_bucket) return null;
            const back = self.head_bucket - bucket;
            if (back >= @as(i64, @intCast(capacity))) return null;
            return (self.head + capacity - @as(usize, @intCast(back))) % capacity;
        }
    };
}

/// One value per bucket; a later write in the same bucket replaces the
/// earlier one. For sampled levels (percentages, loads, temperatures)
/// where summing would be meaningless.
///
/// Gaps read as `null` — a chart must be able to tell "0% CPU" from
/// "the sampler was not running", and a zero-filled ring cannot.
pub fn Series(comptime T: type, comptime capacity_: usize) type {
    comptime std.debug.assert(capacity_ > 0);
    return struct {
        pub const capacity = capacity_;
        pub const Value = T;

        values: [capacity]T = @splat(std.mem.zeroes(T)),
        filled: [capacity]bool = @splat(false),
        clock: Clock(capacity) = .{},
        period_ms: i64,

        const Self = @This();

        pub fn init(period_ms: i64) Self {
            std.debug.assert(period_ms > 0);
            return .{ .period_ms = period_ms };
        }

        fn bucketOf(self: *const Self, ts_ms: i64) i64 {
            return @divFloor(ts_ms, self.period_ms);
        }

        /// Roll the window forward to `now_ms` without recording anything.
        /// Call this every refresh so idle time scrolls the trace left.
        pub fn advanceTo(self: *Self, now_ms: i64) void {
            const bucket = self.bucketOf(now_ms);
            if (!self.clock.initialized) {
                self.clock.initialized = true;
                self.clock.head_bucket = bucket;
                return;
            }
            const step = self.clock.steps(bucket) orelse return;
            if (step.clear_all) {
                self.filled = @splat(false);
                self.values = @splat(std.mem.zeroes(T));
                self.clock.head = 0;
            } else {
                for (0..step.n) |_| {
                    self.clock.head = (self.clock.head + 1) % capacity;
                    self.filled[self.clock.head] = false;
                    self.values[self.clock.head] = std.mem.zeroes(T);
                }
            }
            self.clock.head_bucket = bucket;
        }

        /// Record `value` at `ts_ms`. Samples older than the window are
        /// dropped; a newer one rolls the window forward first.
        pub fn record(self: *Self, ts_ms: i64, value: T) void {
            self.advanceTo(ts_ms);
            const slot = self.clock.slotFor(self.bucketOf(ts_ms)) orelse return;
            self.values[slot] = value;
            self.filled[slot] = true;
        }

        /// Most recent recorded value, if the window still holds one.
        pub fn latest(self: *const Self) ?T {
            var back: usize = 0;
            while (back < capacity) : (back += 1) {
                const slot = (self.clock.head + capacity - back) % capacity;
                if (self.filled[slot]) return self.values[slot];
            }
            return null;
        }

        /// Copy the window oldest→newest into `out`, which must hold
        /// `capacity` entries. Returns the populated prefix; gaps are
        /// null. The newest entry is always last, so a chart can render
        /// `out` directly with time running left to right.
        pub fn snapshot(self: *const Self, out: []?T) []?T {
            const n = @min(out.len, capacity);
            for (0..n) |i| {
                const back = n - 1 - i;
                const slot = (self.clock.head + capacity - back) % capacity;
                out[i] = if (self.filled[slot]) self.values[slot] else null;
            }
            return out[0..n];
        }

        /// Wall-clock start of the oldest bucket the window covers.
        pub fn windowStartMs(self: *const Self) i64 {
            return (self.clock.head_bucket - @as(i64, @intCast(capacity - 1))) * self.period_ms;
        }

        pub fn isEmpty(self: *const Self) bool {
            for (self.filled) |f| if (f) return false;
            return true;
        }
    };
}

/// Buckets accumulate within their period. For counters (tokens, events,
/// bytes) where two samples in one bucket must add, not replace.
///
/// Saturating adds: a u64 of tokens cannot realistically overflow, but a
/// wrapped counter would render as a spike and be believed.
pub fn Accumulator(comptime capacity_: usize) type {
    comptime std.debug.assert(capacity_ > 0);
    return struct {
        pub const capacity = capacity_;

        buckets: [capacity]u64 = @splat(0),
        clock: Clock(capacity) = .{},
        period_ms: i64,
        /// Newest timestamp ever added — idle detection without needing
        /// to scan the ring.
        last_add_ms: i64 = 0,

        const Self = @This();

        pub fn init(period_ms: i64) Self {
            std.debug.assert(period_ms > 0);
            return .{ .period_ms = period_ms };
        }

        fn bucketOf(self: *const Self, ts_ms: i64) i64 {
            return @divFloor(ts_ms, self.period_ms);
        }

        /// Roll the window forward to `now_ms`, zeroing skipped buckets.
        pub fn advanceTo(self: *Self, now_ms: i64) void {
            const bucket = self.bucketOf(now_ms);
            if (!self.clock.initialized) {
                self.clock.initialized = true;
                self.clock.head_bucket = bucket;
                return;
            }
            const step = self.clock.steps(bucket) orelse return;
            if (step.clear_all) {
                self.buckets = @splat(0);
                self.clock.head = 0;
            } else {
                for (0..step.n) |_| {
                    self.clock.head = (self.clock.head + 1) % capacity;
                    self.buckets[self.clock.head] = 0;
                }
            }
            self.clock.head_bucket = bucket;
        }

        /// Add `amount` into the bucket covering `ts_ms`. Late samples
        /// still land if their bucket is inside the window; older ones
        /// are dropped rather than folded into the oldest bucket, which
        /// would invent a spike that never happened.
        pub fn add(self: *Self, ts_ms: i64, amount: u64) void {
            self.advanceTo(ts_ms);
            const slot = self.clock.slotFor(self.bucketOf(ts_ms)) orelse return;
            self.buckets[slot] +|= amount;
            if (ts_ms > self.last_add_ms) self.last_add_ms = ts_ms;
        }

        /// Copy the window oldest→newest into `out` (newest last).
        pub fn snapshot(self: *const Self, out: []u64) []u64 {
            const n = @min(out.len, capacity);
            for (0..n) |i| {
                const back = n - 1 - i;
                const slot = (self.clock.head + capacity - back) % capacity;
                out[i] = self.buckets[slot];
            }
            return out[0..n];
        }

        /// Sum over the whole live window.
        pub fn total(self: *const Self) u64 {
            var sum: u64 = 0;
            for (self.buckets) |b| sum +|= b;
            return sum;
        }

        /// Mean per minute across the window — the honest denominator is
        /// the full window, not just the populated buckets, so a single
        /// burst decays away instead of re-normalizing upward.
        pub fn perMinute(self: *const Self) f64 {
            const window_ms: f64 = @floatFromInt(self.period_ms * @as(i64, @intCast(capacity)));
            if (window_ms <= 0) return 0;
            return @as(f64, @floatFromInt(self.total())) * 60_000.0 / window_ms;
        }

        pub fn windowStartMs(self: *const Self) i64 {
            return (self.clock.head_bucket - @as(i64, @intCast(capacity - 1))) * self.period_ms;
        }
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "series records and reads back the latest value" {
    var s = Series(f32, 4).init(1000);
    s.record(1_000, 0.25);
    s.record(2_000, 0.50);
    try testing.expectEqual(@as(?f32, 0.50), s.latest());
}

test "series same-bucket writes replace rather than accumulate" {
    var s = Series(f32, 4).init(1000);
    s.record(1_000, 0.25);
    s.record(1_400, 0.75); // same 1-second bucket
    try testing.expectEqual(@as(?f32, 0.75), s.latest());
}

test "series advanceTo scrolls idle time to empty" {
    var s = Series(f32, 4).init(1000);
    s.record(1_000, 0.9);
    try testing.expect(!s.isEmpty());
    // Idle well past the whole window: the trace must clear, not pin.
    s.advanceTo(60_000);
    try testing.expect(s.isEmpty());
    try testing.expectEqual(@as(?f32, null), s.latest());
}

test "series snapshot is oldest-first with gaps preserved" {
    var s = Series(f32, 4).init(1000);
    s.record(1_000, 1.0);
    s.record(3_000, 3.0); // leaves bucket 2 unfilled
    var buf: [4]?f32 = undefined;
    const got = s.snapshot(&buf);
    try testing.expectEqual(@as(usize, 4), got.len);
    // head is bucket 3, so oldest→newest is buckets 0,1,2,3.
    try testing.expectEqual(@as(?f32, null), got[0]);
    try testing.expectEqual(@as(?f32, 1.0), got[1]);
    try testing.expectEqual(@as(?f32, null), got[2]);
    try testing.expectEqual(@as(?f32, 3.0), got[3]);
}

test "series drops samples older than the window" {
    var s = Series(f32, 4).init(1000);
    s.record(10_000, 1.0);
    s.record(1_000, 9.0); // far behind the head — must not land
    try testing.expectEqual(@as(?f32, 1.0), s.latest());
}

test "accumulator sums within a bucket" {
    var a = Accumulator(4).init(1000);
    a.add(1_000, 10);
    a.add(1_500, 5); // same bucket
    try testing.expectEqual(@as(u64, 15), a.total());
}

test "accumulator zeroes skipped buckets on roll-forward" {
    var a = Accumulator(4).init(1000);
    a.add(1_000, 10);
    a.add(3_000, 7); // bucket 2 skipped
    var buf: [4]u64 = undefined;
    const got = a.snapshot(&buf);
    try testing.expectEqual(@as(u64, 0), got[0]);
    try testing.expectEqual(@as(u64, 10), got[1]);
    try testing.expectEqual(@as(u64, 0), got[2]);
    try testing.expectEqual(@as(u64, 7), got[3]);
    try testing.expectEqual(@as(u64, 17), a.total());
}

test "accumulator advanceTo drains the window when idle" {
    var a = Accumulator(4).init(1000);
    a.add(1_000, 100);
    try testing.expectEqual(@as(u64, 100), a.total());
    a.advanceTo(600_000);
    try testing.expectEqual(@as(u64, 0), a.total());
}

test "accumulator perMinute normalizes over the full window" {
    // 4 buckets x 15s = 60s window; 120 tokens in it = 120/min.
    var a = Accumulator(4).init(15_000);
    a.add(15_000, 120);
    try testing.expectApproxEqAbs(@as(f64, 120), a.perMinute(), 0.001);
}

test "accumulator last_add_ms tracks the newest sample only" {
    var a = Accumulator(8).init(1000);
    a.add(5_000, 1);
    a.add(4_000, 1); // late but in-window; must not move the marker back
    try testing.expectEqual(@as(i64, 5_000), a.last_add_ms);
}

test "rings survive a huge forward jump without wrapping state" {
    var a = Accumulator(4).init(1000);
    a.add(1_000, 5);
    a.advanceTo(std.math.maxInt(i32));
    try testing.expectEqual(@as(u64, 0), a.total());
    a.add(std.math.maxInt(i32), 3);
    try testing.expectEqual(@as(u64, 3), a.total());
}
