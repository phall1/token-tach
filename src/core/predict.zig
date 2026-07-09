//! Prediction: burn rate (tokens/min) and ETA-to-wall.
//!
//! Two independent estimators, deliberately:
//! - `BurnRate` measures local token velocity from tailed events. It powers
//!   the tray's "⚡ 4.2k/m" and idle detection. It can NOT project limit
//!   walls by itself (token capacity per plan window is unknown).
//! - `WindowPace` measures each limit window's %/min from consecutive
//!   utilization readings (server truth or Codex-embedded). It powers
//!   "wall @ 3:40p". Slope of what the vendor reports beats guessing
//!   token capacities.

const std = @import("std");
const types = @import("types.zig");

/// After this long without an event, the burn display goes idle.
pub const idle_after_ms: i64 = 5 * 60 * 1000;

/// Token velocity over a decayed minute-bucket window.
/// Fixed memory: `bucket_count` one-minute buckets.
pub const BurnRate = struct {
    const bucket_count = 15;
    /// Half-life for bucket weighting, in minutes.
    const half_life_min: f64 = 4.0;

    buckets: [bucket_count]u64 = @splat(0),
    /// Minute index (timestamp_ms / 60_000) of buckets[head].
    head_minute: i64 = 0,
    head: usize = 0,
    initialized: bool = false,
    last_event_ms: i64 = 0,

    pub fn addTokens(self: *BurnRate, ts_ms: i64, tokens: u64) void {
        const minute = @divFloor(ts_ms, 60_000);
        if (!self.initialized) {
            self.initialized = true;
            self.head_minute = minute;
        }
        if (minute > self.head_minute) {
            // Roll forward, zeroing skipped minutes.
            const steps: usize = @intCast(@min(minute - self.head_minute, bucket_count));
            for (0..steps) |_| {
                self.head = (self.head + 1) % bucket_count;
                self.buckets[self.head] = 0;
            }
            self.head_minute = minute;
        } else if (self.head_minute - minute >= bucket_count) {
            return; // too old to matter
        }
        const back: usize = @intCast(@max(self.head_minute - minute, 0));
        const idx = (self.head + bucket_count - back) % bucket_count;
        self.buckets[idx] +|= tokens;
        if (ts_ms > self.last_event_ms) self.last_event_ms = ts_ms;
    }

    /// Exponentially-weighted tokens/minute as of `now_ms`. Normalized by
    /// the FULL window's weight (a constant), not just the populated
    /// buckets — so the rate decays as activity ages out instead of
    /// re-normalizing upward.
    pub fn tokensPerMin(self: *const BurnRate, now_ms: i64) f64 {
        if (!self.initialized) return 0;
        const total_weight = comptime blk: {
            var sum: f64 = 0;
            for (0..bucket_count) |k| {
                sum += std.math.exp2(-@as(f64, @floatFromInt(k)) / half_life_min);
            }
            break :blk sum;
        };
        const now_minute = @divFloor(now_ms, 60_000);
        var weighted: f64 = 0;
        for (0..bucket_count) |back| {
            const idx = (self.head + bucket_count - back) % bucket_count;
            const bucket_minute = self.head_minute - @as(i64, @intCast(back));
            const age_min: f64 = @floatFromInt(@max(now_minute - bucket_minute, 0));
            if (age_min >= bucket_count) continue;
            const w = std.math.exp2(-age_min / half_life_min);
            weighted += @as(f64, @floatFromInt(self.buckets[idx])) * w;
        }
        return weighted / total_weight;
    }

    pub fn isIdle(self: *const BurnRate, now_ms: i64) bool {
        return self.last_event_ms == 0 or now_ms - self.last_event_ms > idle_after_ms;
    }
};

/// %/minute pace for one limit window, from consecutive utilization
/// readings. EWMA over observed positive slopes; a drop in utilization
/// (window reset) re-baselines without polluting the pace.
pub const WindowPace = struct {
    /// Smoothing for new slope observations (0..1, higher = snappier).
    const alpha: f64 = 0.4;

    last_percent: f64 = -1,
    last_ms: i64 = 0,
    pace_pct_per_min: f64 = 0,

    pub fn observe(self: *WindowPace, read_ms: i64, used_percent: f64) void {
        defer {
            self.last_percent = used_percent;
            self.last_ms = read_ms;
        }
        if (self.last_percent < 0 or read_ms <= self.last_ms) return;
        const dp = used_percent - self.last_percent;
        if (dp < 0) {
            // Window reset: pace survives, baseline moves.
            return;
        }
        const dt_min = @as(f64, @floatFromInt(read_ms - self.last_ms)) / 60_000.0;
        if (dt_min <= 0) return;
        const slope = dp / dt_min;
        self.pace_pct_per_min = alpha * slope + (1 - alpha) * self.pace_pct_per_min;
    }

    /// Projected wall-clock ms when this window hits 100%, or null when
    /// there is no meaningful pace (idle or fresh).
    pub fn etaToWallMs(self: *const WindowPace, now_ms: i64) ?i64 {
        if (self.last_percent < 0 or self.pace_pct_per_min < 0.001) return null;
        const remaining = 100.0 - self.last_percent;
        if (remaining <= 0) return now_ms;
        const minutes = remaining / self.pace_pct_per_min;
        // Beyond a week out, the projection is noise — treat as no wall.
        if (minutes > 7 * 24 * 60) return null;
        return now_ms + @as(i64, @intFromFloat(minutes * 60_000.0));
    }
};

pub const Wall = struct {
    agent: types.Agent,
    kind: types.LimitWindow.Kind,
    at_ms: i64,
    used_percent: f64,
};

/// Tracks pace per (agent, window-kind) and answers "which wall comes
/// first". Fixed capacity: agents × window kinds is a small closed set.
pub const WallTracker = struct {
    const Key = struct { agent: types.Agent, kind: types.LimitWindow.Kind };
    const Slot = struct { key: Key, pace: WindowPace };
    const max_slots = 16;

    slots: [max_slots]?Slot = @splat(null),

    fn slotFor(self: *WallTracker, key: Key) *WindowPace {
        for (&self.slots) |*maybe| {
            if (maybe.*) |*slot| {
                if (slot.key.agent == key.agent and slot.key.kind == key.kind) return &slot.pace;
            }
        }
        for (&self.slots) |*maybe| {
            if (maybe.* == null) {
                maybe.* = .{ .key = key, .pace = .{} };
                return &maybe.*.?.pace;
            }
        }
        // Table full (cannot happen with the closed enum set); reuse last.
        return &self.slots[max_slots - 1].?.pace;
    }

    pub fn observe(self: *WallTracker, snap: types.LimitSnapshot) void {
        for (snap.windows) |w| {
            self.slotFor(.{ .agent = snap.agent, .kind = w.kind }).observe(snap.read_at_ms, w.used_percent);
        }
    }

    /// The earliest projected wall across every tracked window.
    pub fn nearestWall(self: *const WallTracker, now_ms: i64) ?Wall {
        var best: ?Wall = null;
        for (&self.slots) |maybe| {
            const slot = maybe orelse continue;
            const eta = slot.pace.etaToWallMs(now_ms) orelse continue;
            if (best == null or eta < best.?.at_ms) {
                best = .{
                    .agent = slot.key.agent,
                    .kind = slot.key.kind,
                    .at_ms = eta,
                    .used_percent = slot.pace.last_percent,
                };
            }
        }
        return best;
    }

    /// The highest current utilization across windows (distance-to-wall
    /// glance), regardless of pace.
    pub fn maxUtilization(self: *const WallTracker) ?Wall {
        var best: ?Wall = null;
        for (&self.slots) |maybe| {
            const slot = maybe orelse continue;
            if (slot.pace.last_percent < 0) continue;
            if (best == null or slot.pace.last_percent > best.?.used_percent) {
                best = .{
                    .agent = slot.key.agent,
                    .kind = slot.key.kind,
                    .at_ms = 0,
                    .used_percent = slot.pace.last_percent,
                };
            }
        }
        return best;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "burn rate: steady stream approximates the true rate" {
    var burn = BurnRate{};
    // 1000 tokens every minute for 10 minutes.
    var t: i64 = 0;
    while (t < 10 * 60_000) : (t += 60_000) burn.addTokens(t, 1000);
    const rate = burn.tokensPerMin(t);
    try testing.expect(rate > 700 and rate < 1300);
}

test "burn rate: decays after activity stops and goes idle" {
    const t0: i64 = 1_000_000;
    var burn = BurnRate{};
    burn.addTokens(t0, 5000);
    const fresh = burn.tokensPerMin(t0);
    const later = burn.tokensPerMin(t0 + 8 * 60_000);
    try testing.expect(later < fresh);
    try testing.expect(!burn.isIdle(t0 + 4 * 60_000));
    try testing.expect(burn.isIdle(t0 + 6 * 60_000));
}

test "burn rate: empty is zero and idle" {
    const burn = BurnRate{};
    try testing.expectEqual(@as(f64, 0), burn.tokensPerMin(123_456));
    try testing.expect(burn.isIdle(123_456));
}

test "window pace: linear utilization projects the wall" {
    var pace = WindowPace{};
    // 1%/min starting at 50%.
    var m: i64 = 0;
    while (m <= 10) : (m += 1) pace.observe(m * 60_000, 50.0 + @as(f64, @floatFromInt(m)));
    const eta = pace.etaToWallMs(10 * 60_000).?;
    // 60% at t=10min, 1%/min -> wall in ~40min.
    const wall_min = @divFloor(eta - 10 * 60_000, 60_000);
    try testing.expect(wall_min >= 35 and wall_min <= 45);
}

test "window pace: reset re-baselines without corrupting pace" {
    var pace = WindowPace{};
    pace.observe(0, 90);
    pace.observe(60_000, 95);
    pace.observe(120_000, 2); // window reset
    pace.observe(180_000, 7);
    try testing.expect(pace.pace_pct_per_min > 0);
    try testing.expectEqual(@as(f64, 7), pace.last_percent);
}

test "window pace: no pace means no wall" {
    var pace = WindowPace{};
    try testing.expectEqual(@as(?i64, null), pace.etaToWallMs(0));
    pace.observe(0, 40);
    pace.observe(60_000, 40); // flat
    try testing.expectEqual(@as(?i64, null), pace.etaToWallMs(60_000));
}

test "wall tracker: nearest wall across agents and windows" {
    var tracker = WallTracker{};
    // Claude 5h window burning fast.
    tracker.observe(.{ .agent = .claude, .read_at_ms = 0, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 80 },
        .{ .kind = .weekly, .used_percent = 20 },
    } });
    tracker.observe(.{ .agent = .claude, .read_at_ms = 60_000, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 82 },
        .{ .kind = .weekly, .used_percent = 20.1 },
    } });
    // Codex barely moving.
    tracker.observe(.{ .agent = .codex, .read_at_ms = 0, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 5 },
    } });
    tracker.observe(.{ .agent = .codex, .read_at_ms = 60_000, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 5.1 },
    } });

    const wall = tracker.nearestWall(60_000).?;
    try testing.expectEqual(types.Agent.claude, wall.agent);
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, wall.kind);

    const hot = tracker.maxUtilization().?;
    try testing.expectEqual(@as(f64, 82), hot.used_percent);
}
