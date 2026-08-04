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
const ring = @import("ring.zig");

/// After this long without an event, the burn display goes idle.
pub const idle_after_ms: i64 = 5 * 60 * 1000;

/// Tokens weighted by how hard they press on plan limits. Cache reads
/// are billed (and rate-limited) at roughly a tenth of input tokens;
/// counting them raw made the tach read 1.8M/m during ordinary cached
/// sessions — technically true, practically noise.
pub fn limitWeightedTokens(ev: types.UsageEvent) u64 {
    return ev.input_tokens + ev.output_tokens +
        ev.cache_creation_tokens + ev.cache_read_tokens / 10;
}

/// Token velocity over a decayed minute-bucket window.
/// Fixed memory: `bucket_count` one-minute buckets.
pub const BurnRate = struct {
    const bucket_count = 15;
    /// Half-life for bucket weighting, in minutes.
    const half_life_min: f64 = 4.0;

    /// How many minutes the window spans — the size a renderer must
    /// allocate for `snapshot`.
    pub const window_minutes: usize = bucket_count;

    /// Sum of every bucket's weight. Hoisted so `tokensPerMin` and
    /// `AgentBurn.totalPerMin` divide by the identical constant: two
    /// copies of this expression would be one edit away from making the
    /// per-agent needle disagree with the blended one.
    const total_weight: f64 = blk: {
        var sum: f64 = 0;
        for (0..bucket_count) |k| {
            sum += std.math.exp2(-@as(f64, @floatFromInt(k)) / half_life_min);
        }
        break :blk sum;
    };

    buckets: [bucket_count]u64 = @splat(0),
    /// Minute index (timestamp_ms / 60_000) of buckets[head].
    head_minute: i64 = 0,
    head: usize = 0,
    initialized: bool = false,
    last_event_ms: i64 = 0,

    /// Move `head` to `minute`, zeroing every minute skipped on the way.
    /// The single roll-forward implementation: `addTokens` used to own it
    /// privately, which meant the ring only ever moved when an event
    /// arrived and `advanceTo` could not exist without duplicating (and
    /// eventually diverging from) this loop.
    fn rollTo(self: *BurnRate, minute: i64) void {
        if (!self.initialized) {
            self.initialized = true;
            self.head_minute = minute;
            return;
        }
        if (minute <= self.head_minute) return;
        const steps: usize = @intCast(@min(minute - self.head_minute, bucket_count));
        for (0..steps) |_| {
            self.head = (self.head + 1) % bucket_count;
            self.buckets[self.head] = 0;
        }
        self.head_minute = minute;
    }

    pub fn addTokens(self: *BurnRate, ts_ms: i64, tokens: u64) void {
        const minute = @divFloor(ts_ms, 60_000);
        self.rollTo(minute);
        if (self.head_minute - minute >= bucket_count) return; // too old to matter
        const back: usize = @intCast(@max(self.head_minute - minute, 0));
        const idx = (self.head + bucket_count - back) % bucket_count;
        self.buckets[idx] +|= tokens;
        if (ts_ms > self.last_event_ms) self.last_event_ms = ts_ms;
    }

    /// Roll the ring forward on wall time alone, with nothing to record.
    /// Call it every refresh.
    ///
    /// Without this the ring advances only inside `addTokens`, so silence
    /// freezes it: after thirty idle minutes the buckets still hold the
    /// last burst under `head`, and a chart that maps slot to x-position
    /// draws that burst at the right edge under a "last 15 min" caption
    /// while `tokensPerMin` beside it correctly reads zero. The chart and
    /// the number contradict each other and the chart is the liar.
    pub fn advanceTo(self: *BurnRate, now_ms: i64) void {
        self.rollTo(@divFloor(now_ms, 60_000));
    }

    /// Tokens recorded in the absolute `minute` (ms / 60_000), or 0 when
    /// that minute lies outside the live window — either still in the
    /// future or already aged out.
    pub fn bucketAt(self: *const BurnRate, minute: i64) u64 {
        if (!self.initialized) return 0;
        if (minute > self.head_minute) return 0;
        const back = self.head_minute - minute;
        if (back >= bucket_count) return 0;
        const idx = (self.head + bucket_count - @as(usize, @intCast(back))) % bucket_count;
        return self.buckets[idx];
    }

    /// Copy the window into `out` OLDEST-FIRST, newest last, anchored on
    /// `now_ms` rather than on `head`. Returns the populated prefix
    /// (`@min(out.len, window_minutes)` entries).
    ///
    /// Anchoring here instead of in the caller is the whole point: given
    /// raw buckets a renderer naturally indexes off `head`, which pins
    /// the last burst to the right edge no matter how long ago it ended.
    /// With `now_ms` as the anchor that bug is not expressible — an idle
    /// ring returns zeros even if nobody remembered to call `advanceTo`.
    ///
    /// The LAST entry is the current, still-filling minute: a partial
    /// sample that always sits below trend mid-burn, so a naive trace
    /// appears to dip at the right edge on every frame. Either drop it
    /// with `snapshotComplete` or scale/dim it using `partialFraction`.
    pub fn snapshot(self: *const BurnRate, now_ms: i64, out: []u64) []u64 {
        return self.snapshotEndingAt(@divFloor(now_ms, 60_000), out);
    }

    /// `snapshot` minus the in-progress minute: every entry returned
    /// covers a full 60 seconds, so the trace cannot dip at the right
    /// edge merely because the clock is mid-minute.
    pub fn snapshotComplete(self: *const BurnRate, now_ms: i64, out: []u64) []u64 {
        return self.snapshotEndingAt(@divFloor(now_ms, 60_000) - 1, out);
    }

    fn snapshotEndingAt(self: *const BurnRate, end_minute: i64, out: []u64) []u64 {
        const n = @min(out.len, bucket_count);
        for (0..n) |i| {
            out[i] = self.bucketAt(end_minute - @as(i64, @intCast(n - 1 - i)));
        }
        return out[0..n];
    }

    /// Fraction of the newest snapshot bucket's minute that has actually
    /// elapsed at `now_ms`, in (0, 1]. A renderer keeping the partial
    /// bucket can divide by this to compare it against full minutes, or
    /// use it as an opacity so the viewer sees the bar is incomplete.
    /// Clamped away from zero so the divide is always safe.
    pub fn partialFraction(now_ms: i64) f64 {
        const into_minute: f64 = @floatFromInt(@mod(now_ms, 60_000));
        return @max(into_minute / 60_000.0, 1.0 / 60_000.0);
    }

    /// Exponentially-weighted tokens/minute as of `now_ms`. Normalized by
    /// the FULL window's weight (a constant), not just the populated
    /// buckets — so the rate decays as activity ages out instead of
    /// re-normalizing upward.
    pub fn tokensPerMin(self: *const BurnRate, now_ms: i64) f64 {
        if (!self.initialized) return 0;
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

const scope_period_ms: i64 = 10_000;
const scope_buckets: usize = 120;

/// A 10-second-resolution burn trace over the last 20 minutes.
///
/// The minute ring is the right shape for a number ("4.2k/m") and the
/// wrong shape for a scope: at 60s per sample a 40-second spike is one
/// bar, and the eye cannot tell a steady grind from a burst that ended.
/// ~1 KB of `ring.Accumulator`, which is wall-clock anchored, so idle
/// time scrolls the trace left to zero instead of freezing it.
pub const ScopeTrace = struct {
    pub const period_ms = scope_period_ms;
    pub const bucket_count = scope_buckets;
    pub const span_ms = scope_period_ms * @as(i64, @intCast(scope_buckets));

    acc: ring.Accumulator(scope_buckets) = .init(scope_period_ms),

    pub fn addTokens(self: *ScopeTrace, ts_ms: i64, tokens: u64) void {
        self.acc.add(ts_ms, tokens);
    }

    /// Roll forward on wall time; see `BurnRate.advanceTo` for why every
    /// ring in this file needs one.
    pub fn advanceTo(self: *ScopeTrace, now_ms: i64) void {
        self.acc.advanceTo(now_ms);
    }

    /// Oldest-first, newest last. As with `BurnRate.snapshot` the final
    /// bucket covers a still-filling 10 seconds.
    pub fn snapshot(self: *const ScopeTrace, out: []u64) []u64 {
        return self.acc.snapshot(out);
    }

    pub fn total(self: *const ScopeTrace) u64 {
        return self.acc.total();
    }

    /// Flat mean tokens/min across the whole 20-minute window. This is
    /// deliberately NOT `BurnRate.tokensPerMin`: no exponential
    /// weighting, so it reads as the area under the trace the viewer is
    /// looking at rather than as a second, differently-lagged needle.
    pub fn tokensPerMin(self: *const ScopeTrace) f64 {
        return self.acc.perMinute();
    }

    pub fn windowStartMs(self: *const ScopeTrace) i64 {
        return self.acc.windowStartMs();
    }
};

/// Burn split by agent, one minute-ring each, plus one blended scope.
///
/// A single blended ring answers "how fast is the fleet burning" and
/// nothing else: with fourteen collectors feeding it, "which agent is
/// burning right now" is unanswerable and the needle is an unattributed
/// sum. Fixed size, no allocator, no failure mode — it can sit in the
/// Model and be journaled with it.
///
/// `totalPerMin` is the compatibility contract: for any event stream it
/// returns bit-for-bit what one blended `BurnRate` returns for the same
/// stream, so swapping the Model's field cannot move the needle. It is
/// bit-exact rather than merely close because it sums buckets in integer
/// space first and then applies the identical weights in the identical
/// order — not because floats happen to be forgiving.
pub const AgentBurn = struct {
    rings: std.EnumArray(types.Agent, BurnRate) = .initFill(.{}),
    /// Fleet-wide fine trace. One shared ring, not fourteen: the scope
    /// answers "what is the shape of right now", and fourteen overlaid
    /// 10-second traces is a smear, not a reading.
    scope: ScopeTrace = .{},

    pub const Hot = struct { agent: types.Agent, tokens_per_min: f64 };

    pub fn addTokens(self: *AgentBurn, agent: types.Agent, ts_ms: i64, tokens: u64) void {
        self.rings.getPtr(agent).addTokens(ts_ms, tokens);
        self.scope.addTokens(ts_ms, tokens);
    }

    /// Record an event with the same limit weighting the blended ring
    /// applies, so callers cannot accidentally feed raw totals here and
    /// weighted totals there.
    pub fn addEvent(self: *AgentBurn, ev: types.UsageEvent) void {
        self.addTokens(ev.agent, ev.timestamp_ms, limitWeightedTokens(ev));
    }

    /// Roll every ring forward on wall time. One call per refresh keeps
    /// the whole fleet's traces honest about silence.
    pub fn advanceTo(self: *AgentBurn, now_ms: i64) void {
        for (&self.rings.values) |*r| r.advanceTo(now_ms);
        self.scope.advanceTo(now_ms);
    }

    pub fn tokensPerMin(self: *const AgentBurn, agent: types.Agent, now_ms: i64) f64 {
        return self.rings.getPtrConst(agent).tokensPerMin(now_ms);
    }

    pub fn burnFor(self: *const AgentBurn, agent: types.Agent) *const BurnRate {
        return self.rings.getPtrConst(agent);
    }

    /// Newest minute any ring has reached — what a single blended ring's
    /// `head_minute` would be for the same stream, since that head is
    /// just the newest event minute seen across all agents.
    fn headMinute(self: *const AgentBurn) ?i64 {
        var best: ?i64 = null;
        for (&self.rings.values) |*r| {
            if (!r.initialized) continue;
            if (best == null or r.head_minute > best.?) best = r.head_minute;
        }
        return best;
    }

    /// The blended needle. Mirrors `BurnRate.tokensPerMin` exactly: same
    /// window anchor, same weights, same accumulation order, with each
    /// bucket summed across agents as u64 before it becomes a float.
    pub fn totalPerMin(self: *const AgentBurn, now_ms: i64) f64 {
        const head_minute = self.headMinute() orelse return 0;
        const now_minute = @divFloor(now_ms, 60_000);
        var weighted: f64 = 0;
        for (0..BurnRate.window_minutes) |back| {
            const bucket_minute = head_minute - @as(i64, @intCast(back));
            const age_min: f64 = @floatFromInt(@max(now_minute - bucket_minute, 0));
            if (age_min >= @as(f64, @floatFromInt(BurnRate.window_minutes))) continue;
            var sum: u64 = 0;
            for (&self.rings.values) |*r| sum +|= r.bucketAt(bucket_minute);
            const w = std.math.exp2(-age_min / BurnRate.half_life_min);
            weighted += @as(f64, @floatFromInt(sum)) * w;
        }
        return weighted / BurnRate.total_weight;
    }

    /// True only when every agent is idle — one live agent keeps the
    /// fleet display awake.
    pub fn isIdle(self: *const AgentBurn, now_ms: i64) bool {
        for (&self.rings.values) |*r| {
            if (!r.isIdle(now_ms)) return false;
        }
        return true;
    }

    /// The agent burning hardest right now, or null when the fleet is
    /// quiet. Ties break toward the earlier enum member so a two-agent
    /// dead heat names one of them stably instead of flickering.
    pub fn hottest(self: *const AgentBurn, now_ms: i64) ?Hot {
        var best: ?Hot = null;
        for (std.enums.values(types.Agent)) |agent| {
            const rate = self.rings.getPtrConst(agent).tokensPerMin(now_ms);
            if (rate <= 0) continue;
            if (best == null or rate > best.?.tokens_per_min) {
                best = .{ .agent = agent, .tokens_per_min = rate };
            }
        }
        return best;
    }
};

/// %/minute pace for one limit window, from consecutive utilization
/// readings. EWMA over observed positive slopes; a drop in utilization
/// (window reset) re-baselines without polluting the pace.
pub const WindowPace = struct {
    /// Smoothing for new slope observations (0..1, higher = snappier).
    const alpha: f64 = 0.4;

    /// 5-minute buckets over 6 hours: a whole 5-hour window's fill curve
    /// fits with room to spare, and a utilization percentage does not
    /// move fast enough for finer buckets to record anything but the
    /// same number twelve times.
    pub const history_period_ms: i64 = 5 * 60 * 1000;
    pub const history_buckets: usize = 72;
    pub const History = ring.Series(f32, history_buckets);

    last_percent: f64 = -1,
    last_ms: i64 = 0,
    pace_pct_per_min: f64 = 0,
    /// The readings behind the pace. A pace is one scalar and cannot say
    /// whether the window climbed steadily or jumped once and stalled —
    /// the shape is what makes "5h window filling up" legible. Gaps read
    /// as null so a stalled poller draws a hole rather than a flat line.
    history: History = .init(history_period_ms),

    pub fn observe(self: *WindowPace, read_ms: i64, used_percent: f64) void {
        self.history.record(read_ms, @floatCast(used_percent));
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

    /// The pace itself, for a UI that wants to show it. Null when there
    /// is nothing worth showing, using the same threshold `etaToWallMs`
    /// uses to refuse a projection — so a popover can never render
    /// "0.0002 %/min" beside "no wall in sight" and look broken.
    pub fn pacePerMin(self: *const WindowPace) ?f64 {
        if (self.last_percent < 0 or self.pace_pct_per_min < 0.001) return null;
        return self.pace_pct_per_min;
    }

    /// Latest observed utilization, or null before the first reading.
    /// The raw field uses -1 as its sentinel; this spares every caller
    /// from re-deriving that.
    pub fn utilization(self: *const WindowPace) ?f64 {
        if (self.last_percent < 0) return null;
        return self.last_percent;
    }

    /// Roll the history forward on wall time. Polls stall; without this
    /// the curve pins its last reading under the head exactly the way
    /// `BurnRate` used to.
    pub fn advanceTo(self: *WindowPace, now_ms: i64) void {
        self.history.advanceTo(now_ms);
    }

    /// The utilization curve oldest-first, newest last, nulls for
    /// buckets with no reading. `out` should hold `history_buckets`.
    pub fn utilizationHistory(self: *const WindowPace, out: []?f32) []?f32 {
        return self.history.snapshot(out);
    }

    /// Wall-clock start of the oldest bucket the curve covers — the
    /// x-axis origin for whatever `utilizationHistory` returned.
    pub fn historyStartMs(self: *const WindowPace) i64 {
        return self.history.windowStartMs();
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

    /// Roll every tracked window's history forward on wall time. One
    /// call per refresh; see `WindowPace.advanceTo`.
    pub fn advanceTo(self: *WallTracker, now_ms: i64) void {
        for (&self.slots) |*maybe| {
            if (maybe.*) |*slot| slot.pace.advanceTo(now_ms);
        }
    }

    /// The pace for one (agent, window) pair, or null when nothing has
    /// been observed for it. `observe` had no read counterpart, so a UI
    /// could not draw a specific window — only whichever wall happened
    /// to be nearest.
    pub fn paceFor(
        self: *const WallTracker,
        agent: types.Agent,
        kind: types.LimitWindow.Kind,
    ) ?*const WindowPace {
        for (&self.slots) |*maybe| {
            if (maybe.*) |*slot| {
                if (slot.key.agent == agent and slot.key.kind == kind) return &slot.pace;
            }
        }
        return null;
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

test "burn rate: advanceTo drains an idle ring to zero" {
    const t0: i64 = 3_600_000;
    var burn = BurnRate{};
    burn.addTokens(t0, 50_000);
    try testing.expect(burn.tokensPerMin(t0) > 0);
    burn.advanceTo(t0 + 30 * 60_000);
    for (burn.buckets) |b| try testing.expectEqual(@as(u64, 0), b);
    try testing.expectEqual(@as(f64, 0), burn.tokensPerMin(t0 + 30 * 60_000));
    // Advancing must not fabricate activity: still idle, marker untouched.
    try testing.expect(burn.isIdle(t0 + 30 * 60_000));
    try testing.expectEqual(t0, burn.last_event_ms);
}

test "burn rate: addTokens is unchanged by the shared roll-forward" {
    var burn = BurnRate{};
    burn.addTokens(0, 100);
    burn.addTokens(2 * 60_000, 300); // minute 1 skipped
    burn.addTokens(2 * 60_000 + 500, 200); // same minute, accumulates
    burn.addTokens(60_000, 7); // late but in-window
    burn.addTokens(0 - 60 * 60_000, 999); // far too old to matter
    var buf: [BurnRate.window_minutes]u64 = undefined;
    const got = burn.snapshot(2 * 60_000, &buf);
    try testing.expectEqual(@as(u64, 500), got[got.len - 1]);
    try testing.expectEqual(@as(u64, 7), got[got.len - 2]);
    try testing.expectEqual(@as(u64, 100), got[got.len - 3]);
    try testing.expectEqual(@as(i64, 2 * 60_000 + 500), burn.last_event_ms);
}

test "burn rate: snapshot is oldest-first and anchored on now, not head" {
    const t0: i64 = 100 * 60_000;
    var burn = BurnRate{};
    burn.addTokens(t0, 1000);
    burn.addTokens(t0 + 60_000, 2000);

    var buf: [BurnRate.window_minutes]u64 = undefined;
    const at_head = burn.snapshot(t0 + 60_000, &buf);
    try testing.expectEqual(BurnRate.window_minutes, at_head.len);
    try testing.expectEqual(@as(u64, 2000), at_head[at_head.len - 1]);
    try testing.expectEqual(@as(u64, 1000), at_head[at_head.len - 2]);
    try testing.expectEqual(@as(u64, 0), at_head[0]);

    // Three minutes later with no events and no advanceTo call: the same
    // buckets must have SLID LEFT, not stayed pinned to the right edge.
    const later = burn.snapshot(t0 + 4 * 60_000, &buf);
    try testing.expectEqual(@as(u64, 0), later[later.len - 1]);
    try testing.expectEqual(@as(u64, 2000), later[later.len - 4]);
    try testing.expectEqual(@as(u64, 1000), later[later.len - 5]);
}

test "burn rate: a burst then 30 idle minutes reads zero and snapshots empty" {
    const t0: i64 = 500 * 60_000;
    var burn = BurnRate{};
    var m: i64 = 0;
    while (m < 3) : (m += 1) burn.addTokens(t0 + m * 60_000, 90_000);
    const now = t0 + 33 * 60_000;

    try testing.expectEqual(@as(f64, 0), burn.tokensPerMin(now));
    try testing.expect(burn.isIdle(now));
    var buf: [BurnRate.window_minutes]u64 = undefined;
    // The bug: the number said 0 while the chart still drew the burst.
    for (burn.snapshot(now, &buf)) |b| try testing.expectEqual(@as(u64, 0), b);
    burn.advanceTo(now);
    for (burn.snapshot(now, &buf)) |b| try testing.expectEqual(@as(u64, 0), b);
}

test "burn rate: snapshotComplete drops the still-filling minute" {
    const t0: i64 = 200 * 60_000;
    var burn = BurnRate{};
    burn.addTokens(t0, 4000);
    burn.addTokens(t0 + 60_000, 10); // barely into the current minute
    const now = t0 + 60_000 + 5_000;

    var buf: [BurnRate.window_minutes]u64 = undefined;
    const raw = burn.snapshot(now, &buf);
    try testing.expectEqual(@as(u64, 10), raw[raw.len - 1]);

    var buf2: [BurnRate.window_minutes]u64 = undefined;
    const complete = burn.snapshotComplete(now, &buf2);
    try testing.expectEqual(@as(u64, 4000), complete[complete.len - 1]);

    // 5s into the minute: the partial bar covers a twelfth of it.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), BurnRate.partialFraction(now), 1e-9);
    try testing.expect(BurnRate.partialFraction(t0) > 0); // never divides by zero
}

test "agent burn: per-agent rings blend to exactly the single-ring value" {
    const Ev = struct { agent: types.Agent, ms: i64, tokens: u64 };
    const stream = [_]Ev{
        .{ .agent = .claude, .ms = 1_000, .tokens = 1200 },
        .{ .agent = .codex, .ms = 1_500, .tokens = 300 },
        .{ .agent = .claude, .ms = 61_000, .tokens = 4000 },
        .{ .agent = .gemini, .ms = 130_000, .tokens = 90 },
        .{ .agent = .codex, .ms = 190_000, .tokens = 2500 },
        .{ .agent = .claude, .ms = 400_000, .tokens = 777 },
        .{ .agent = .droid, .ms = 401_000, .tokens = 55 },
    };
    var blended = BurnRate{};
    var per = AgentBurn{};
    for (stream) |e| {
        blended.addTokens(e.ms, e.tokens);
        per.addTokens(e.agent, e.ms, e.tokens);
    }

    // Bit-exact, not approximately equal: this is the contract that lets
    // the Model swap its single ring for AgentBurn without the needle
    // twitching by a token.
    const now = 420_000;
    try testing.expectEqual(blended.tokensPerMin(now), per.totalPerMin(now));

    // And still exact once both have been rolled forward on wall time.
    const later = 8 * 60_000;
    blended.advanceTo(later);
    per.advanceTo(later);
    try testing.expectEqual(blended.tokensPerMin(later), per.totalPerMin(later));
    try testing.expectEqual(blended.tokensPerMin(later), per.totalPerMin(later));

    // Per-agent shares are non-trivial, so the equality above is not the
    // degenerate "everything is zero" case.
    try testing.expect(per.tokensPerMin(.claude, now) > 0);
    try testing.expect(per.tokensPerMin(.codex, now) > 0);
    try testing.expectEqual(@as(f64, 0), per.tokensPerMin(.kimi, now));
}

test "agent burn: empty blends to the same zero and has no hottest" {
    const per = AgentBurn{};
    const blended = BurnRate{};
    try testing.expectEqual(blended.tokensPerMin(9_000_000), per.totalPerMin(9_000_000));
    try testing.expectEqual(@as(?AgentBurn.Hot, null), per.hottest(9_000_000));
    try testing.expect(per.isIdle(9_000_000));
}

test "agent burn: hottest names the agent burning most" {
    const t0: i64 = 1_000 * 60_000;
    var per = AgentBurn{};
    per.addTokens(.claude, t0, 1000);
    per.addTokens(.codex, t0, 50_000);
    per.addTokens(.gemini, t0, 20_000);
    const hot = per.hottest(t0).?;
    try testing.expectEqual(types.Agent.codex, hot.agent);
    try testing.expectEqual(per.tokensPerMin(.codex, t0), hot.tokens_per_min);
    try testing.expect(!per.isIdle(t0));

    // Codex stops, gemini keeps going: the answer must follow the burn.
    per.addTokens(.gemini, t0 + 6 * 60_000, 80_000);
    try testing.expectEqual(types.Agent.gemini, per.hottest(t0 + 6 * 60_000).?.agent);

    // Everyone stops: no agent is "burning most" once the window drains.
    per.advanceTo(t0 + 40 * 60_000);
    try testing.expectEqual(@as(?AgentBurn.Hot, null), per.hottest(t0 + 40 * 60_000));
    try testing.expect(per.isIdle(t0 + 40 * 60_000));
}

test "agent burn: addEvent applies the same limit weighting" {
    var per = AgentBurn{};
    const ev = types.UsageEvent{
        .agent = .claude,
        .timestamp_ms = 60_000,
        .model = "m",
        .input_tokens = 1000,
        .output_tokens = 200,
        .cache_creation_tokens = 300,
        .cache_read_tokens = 500,
    };
    per.addEvent(ev);
    try testing.expectEqual(limitWeightedTokens(ev), per.burnFor(.claude).bucketAt(1));
    try testing.expectEqual(limitWeightedTokens(ev), per.scope.total());
}

test "scope trace agrees with the minute ring over a shared window" {
    const t0: i64 = 2_000 * 60_000;
    var minute = BurnRate{};
    var per = AgentBurn{};
    // 10 minutes of traffic, well inside both windows (15 min / 20 min).
    var i: i64 = 0;
    while (i < 60) : (i += 1) {
        const ts = t0 + i * 10_000;
        minute.addTokens(ts, 500);
        per.addTokens(.claude, ts, 500);
    }
    const now = t0 + 600_000;
    minute.advanceTo(now);
    per.advanceTo(now);

    var buf: [BurnRate.window_minutes]u64 = undefined;
    var minute_total: u64 = 0;
    for (minute.snapshot(now, &buf)) |b| minute_total += b;
    try testing.expectEqual(@as(u64, 30_000), minute_total);
    try testing.expectEqual(minute_total, per.scope.total());

    // Finer buckets, same area: 30k tokens over a 20-minute window.
    try testing.expectApproxEqAbs(@as(f64, 1500), per.scope.tokensPerMin(), 0.001);

    var fine: [ScopeTrace.bucket_count]u64 = undefined;
    const trace = per.scope.snapshot(&fine);
    try testing.expectEqual(ScopeTrace.bucket_count, trace.len);
    try testing.expectEqual(@as(u64, 0), trace[trace.len - 1]); // filling now
    try testing.expectEqual(@as(u64, 500), trace[trace.len - 2]);
    try testing.expectEqual(@as(u64, 0), trace[0]); // 20 min ago: nothing yet

    // And the scope drains on wall time like everything else here.
    per.advanceTo(now + 60 * 60_000);
    try testing.expectEqual(@as(u64, 0), per.scope.total());
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

test "window pace: exposes the pace a UI can render" {
    var pace = WindowPace{};
    try testing.expectEqual(@as(?f64, null), pace.pacePerMin());
    try testing.expectEqual(@as(?f64, null), pace.utilization());

    var m: i64 = 0;
    while (m <= 5) : (m += 1) pace.observe(m * 60_000, 40.0 + 2.0 * @as(f64, @floatFromInt(m)));
    try testing.expectApproxEqAbs(@as(f64, 2), pace.pacePerMin().?, 0.2);
    try testing.expectEqual(@as(?f64, 50), pace.utilization());

    // Flat readings project no wall, so they must report no pace either
    // rather than a number that contradicts "no wall in sight".
    var flat = WindowPace{};
    flat.observe(0, 40);
    flat.observe(60_000, 40);
    try testing.expectEqual(@as(?i64, null), flat.etaToWallMs(60_000));
    try testing.expectEqual(@as(?f64, null), flat.pacePerMin());
}

test "window pace: history retains the fill curve oldest-first" {
    var pace = WindowPace{};
    // One reading every 5 minutes for an hour: a 5h window filling up.
    var m: i64 = 0;
    while (m <= 12) : (m += 1) {
        pace.observe(m * WindowPace.history_period_ms, 10.0 + 3.0 * @as(f64, @floatFromInt(m)));
    }
    var buf: [WindowPace.history_buckets]?f32 = undefined;
    const curve = pace.utilizationHistory(&buf);
    try testing.expectEqual(WindowPace.history_buckets, curve.len);
    try testing.expectEqual(@as(?f32, 46), curve[curve.len - 1]);
    try testing.expectEqual(@as(?f32, 43), curve[curve.len - 2]);
    try testing.expectEqual(@as(?f32, 10), curve[curve.len - 13]);
    // Before the first reading is a gap, not 0% — a chart must be able
    // to tell "empty window" from "we were not looking".
    try testing.expectEqual(@as(?f32, null), curve[curve.len - 14]);
    // The curve's x-origin is a real wall clock, not a slot index.
    try testing.expectEqual(
        (12 - @as(i64, WindowPace.history_buckets - 1)) * WindowPace.history_period_ms,
        pace.historyStartMs(),
    );

    // A stalled poller scrolls the curve away instead of pinning it.
    pace.advanceTo(12 * WindowPace.history_period_ms + 10 * 60 * 60 * 1000);
    const drained = pace.utilizationHistory(&buf);
    for (drained) |v| try testing.expectEqual(@as(?f32, null), v);
    // The pace itself survives the gap; only the curve scrolled.
    try testing.expect(pace.pacePerMin().? > 0);
}

test "wall tracker: paceFor reads back a tracked window" {
    var tracker = WallTracker{};
    tracker.observe(.{ .agent = .claude, .read_at_ms = 0, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 30 },
    } });
    tracker.observe(.{ .agent = .claude, .read_at_ms = 5 * 60_000, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 35 },
    } });
    const pace = tracker.paceFor(.claude, .five_hour).?;
    try testing.expectEqual(@as(?f64, 35), pace.utilization());
    try testing.expect(pace.pacePerMin().? > 0);
    try testing.expect(tracker.paceFor(.codex, .weekly) == null);

    var buf: [WindowPace.history_buckets]?f32 = undefined;
    try testing.expectEqual(@as(?f32, 35), pace.utilizationHistory(&buf)[WindowPace.history_buckets - 1]);
    tracker.advanceTo(24 * 60 * 60 * 1000);
    for (pace.utilizationHistory(&buf)) |v| try testing.expectEqual(@as(?f32, null), v);
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

test "limit-weighted tokens discount cache reads" {
    try testing.expectEqual(@as(u64, 1000 + 200 + 300 + 50), limitWeightedTokens(.{
        .agent = .claude,
        .timestamp_ms = 0,
        .model = "m",
        .input_tokens = 1000,
        .output_tokens = 200,
        .cache_creation_tokens = 300,
        .cache_read_tokens = 500,
    }));
}
