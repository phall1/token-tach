//! Alert logic for notifications: pure, deterministic, zero-allocation.
//!
//! `AlertEngine.observe` is fed the same inputs the display path already
//! derives (limit snapshots, the nearest predicted wall, the configured
//! thresholds) and answers "which alerts fire NOW". All hysteresis and
//! rate-limit state lives in fixed-capacity tables (like
//! predict.WallTracker's slot table); nothing here allocates.
//!
//! Semantics (spam-proof by construction):
//! - **threshold**: fires once when a window's used_percent crosses a
//!   configured threshold upward; the threshold re-arms only after the
//!   window falls at least `rearm_drop_points` below it (window reset or
//!   usage decay). Tracked per (agent, window-kind, threshold).
//!   When one observation crosses several tiers at once (70 and 90),
//!   only the HIGHEST fires — the lower tiers latch silently.
//! - **wall_imminent**: fires when the predicted wall is within
//!   `wall_fire_within_ms`; re-arms when the wall recedes past
//!   `wall_rearm_beyond_ms` or disappears (the 30→45 min gap is the
//!   hysteresis band).
//! - **window_reset**: fires once when a window that reached at least
//!   `reset_high_floor` drops by `reset_drop_points` or more — the
//!   "you're clear" moment. The high-water mark re-baselines on fire.
//! - Rate limit: at most 1 alert per (agent, alert-kind) per
//!   `rate_limit_ms`, and at most `max_alerts_per_observe` per call
//!   (priority: wall_imminent > threshold high→low > window_reset).
//!   State transitions (latching) happen regardless of delivery — a
//!   suppressed alert is dropped, never queued, so the engine can never
//!   build up a spam backlog.
//! - Cold start: the FIRST observation of a window never fires the
//!   routine tiers for already-high usage (no "70% !" greeting on
//!   install) — but tiers at or above `first_observation_fire_floor`
//!   (90) DO fire, because being near the wall is exactly what the user
//!   installed this for. "First observation" is per (agent, window-kind)
//!   slot, so a window kind that appears later (e.g. weekly_opus after
//!   the first Opus call) gets the same courtesy.
//!
//! Output lifetime: `observe` renders into an engine-owned fixed buffer
//! and returns a slice of it — valid until the next `observe` call.
//! That is the natural shape for the caller (fire the notifications
//! immediately, keep nothing), and it keeps the API allocation- and
//! out-parameter-free.

const std = @import("std");
const types = @import("types.zig");
const predict = @import("predict.zig");
const trayfmt = @import("trayfmt.zig");

pub const AlertKind = enum { threshold, wall_imminent, window_reset };

/// Fire when the predicted wall is this close.
pub const wall_fire_within_ms: i64 = 30 * 60_000;
/// Re-arm when the wall recedes past this.
pub const wall_rearm_beyond_ms: i64 = 45 * 60_000;
/// A threshold re-arms once usage falls this many points below it.
pub const rearm_drop_points: f64 = 5;
/// window_reset needs the window to have reached this high...
pub const reset_high_floor: f64 = 70;
/// ...and then to have dropped by at least this much.
pub const reset_drop_points: f64 = 30;
/// At most one alert per (agent, alert-kind) this often.
pub const rate_limit_ms: i64 = 10 * 60_000;
/// At most this many alerts per observe call.
pub const max_alerts_per_observe = 3;
/// On a slot's first observation, already-crossed tiers below this
/// latch silently; tiers at or above it fire.
pub const first_observation_fire_floor: u8 = 90;

/// SDK limits are 128/1024 (platform.max_notification_title_bytes);
/// our strings are far shorter.
pub const title_cap = 64;
pub const body_cap = 128;

/// One renderable alert. Text lives in inline fixed buffers, so an
/// Alert is safely copyable by value; read it through `title`/`body`
/// on the copy you hold.
pub const Alert = struct {
    kind: AlertKind,
    agent: types.Agent,
    window: ?types.LimitWindow.Kind,
    title_buf: [title_cap]u8 = undefined,
    title_len: u8 = 0,
    body_buf: [body_cap]u8 = undefined,
    body_len: u8 = 0,

    pub fn title(self: *const Alert) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn body(self: *const Alert) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

const agent_count = @typeInfo(types.Agent).@"enum".fields.len;
const kind_count = @typeInfo(AlertKind).@"enum".fields.len;

/// An alert that WOULD fire this observe, pre-rate-limit. Collected,
/// priority-sorted, then trimmed to the delivery budget.
const Candidate = struct {
    priority: u16,
    kind: AlertKind,
    agent: types.Agent,
    window: types.LimitWindow.Kind,
    /// threshold: the tier crossed.
    threshold: u8 = 0,
    /// Current utilization (threshold/wall: now; reset: after the drop).
    percent: f64 = 0,
    /// window_reset: the high-water mark before the drop.
    prev_high: f64 = 0,
    /// threshold: the window's reset time for the body line.
    resets_at_ms: i64 = 0,
    /// wall_imminent: projected wall clock time.
    wall_at_ms: i64 = 0,
};

const wall_priority: u16 = 300;
const reset_priority: u16 = 0;

fn thresholdPriority(t: u8) u16 {
    return 100 + @as(u16, t);
}

pub const AlertEngine = struct {
    const Key = struct { agent: types.Agent, kind: types.LimitWindow.Kind };
    /// Bit t set = threshold t has fired and is not yet re-armed.
    /// Indexing by the threshold VALUE (0–100) keeps the latch correct
    /// across config live-reloads that add/remove tiers.
    const LatchSet = std.StaticBitSet(101);
    const WindowState = struct {
        key: Key,
        latched: LatchSet = .initEmpty(),
        /// Highest utilization seen since the last reset fire; -1 = fresh.
        high_water: f64 = -1,
        seen: bool = false,
    };
    const max_slots = 16;
    const max_candidates = 16;

    slots: [max_slots]?WindowState = @splat(null),
    wall_latched: bool = false,
    /// Rate-limit bookkeeping per (agent, alert-kind).
    last_fired_ms: [agent_count][kind_count]?i64 = @splat(@splat(null)),
    /// Render target for the returned slice (valid until next observe).
    out: [max_alerts_per_observe]Alert = undefined,

    fn slotFor(self: *AlertEngine, key: Key) *WindowState {
        for (&self.slots) |*maybe| {
            if (maybe.*) |*slot| {
                if (slot.key.agent == key.agent and slot.key.kind == key.kind) return slot;
            }
        }
        for (&self.slots) |*maybe| {
            if (maybe.* == null) {
                maybe.* = .{ .key = key };
                return &maybe.*.?;
            }
        }
        // Table full (cannot happen with the closed enum set); reuse last.
        return &self.slots[max_slots - 1].?;
    }

    /// Advance all alert state from the current readings and return the
    /// alerts to fire NOW (0..max_alerts_per_observe, priority-ordered).
    /// The returned slice points into engine-owned storage and is valid
    /// until the next call. Inputs are only read during the call.
    pub fn observe(
        self: *AlertEngine,
        now_ms: i64,
        tz_offset_min: i32,
        snapshots: []const types.LimitSnapshot,
        wall: ?predict.Wall,
        thresholds: []const u8,
    ) []const Alert {
        var candidates: [max_candidates]Candidate = undefined;
        var n_cand: usize = 0;

        // ---- wall_imminent -------------------------------------------
        if (wall) |w| {
            const dt = w.at_ms - now_ms;
            if (dt > wall_rearm_beyond_ms) self.wall_latched = false;
            if (!self.wall_latched and dt <= wall_fire_within_ms) {
                self.wall_latched = true;
                appendCandidate(&candidates, &n_cand, .{
                    .priority = wall_priority,
                    .kind = .wall_imminent,
                    .agent = w.agent,
                    .window = w.kind,
                    .percent = w.used_percent,
                    .wall_at_ms = w.at_ms,
                });
            }
        } else {
            self.wall_latched = false;
        }

        // ---- per-window threshold + reset ----------------------------
        for (snapshots) |snap| {
            for (snap.windows) |w| {
                const slot = self.slotFor(.{ .agent = snap.agent, .kind = w.kind });
                const pct = std.math.clamp(w.used_percent, 0, 100);

                // Hysteresis re-arm: any latched tier the usage has
                // fallen ≥ rearm_drop_points below un-latches. Runs over
                // the latch bits (not the config list) so tiers removed
                // from config still clean up.
                for (0..101) |t| {
                    if (slot.latched.isSet(t) and
                        pct <= @as(f64, @floatFromInt(t)) - rearm_drop_points)
                    {
                        slot.latched.unset(t);
                    }
                }

                if (!slot.seen) {
                    // Cold start for this window: latch everything
                    // already crossed; only the ≥90 tiers fire.
                    slot.seen = true;
                    slot.high_water = pct;
                    var best: ?u8 = null;
                    for (thresholds) |t| {
                        if (pct >= @as(f64, @floatFromInt(t))) {
                            slot.latched.set(t);
                            if (t >= first_observation_fire_floor) {
                                if (best == null or t > best.?) best = t;
                            }
                        }
                    }
                    if (best) |t| {
                        appendCandidate(&candidates, &n_cand, .{
                            .priority = thresholdPriority(t),
                            .kind = .threshold,
                            .agent = snap.agent,
                            .window = w.kind,
                            .threshold = t,
                            .percent = pct,
                            .resets_at_ms = w.resets_at_ms,
                        });
                    }
                    continue;
                }

                // window_reset: previously-hot window dropped hard.
                if (slot.high_water >= reset_high_floor and
                    pct <= slot.high_water - reset_drop_points)
                {
                    appendCandidate(&candidates, &n_cand, .{
                        .priority = reset_priority,
                        .kind = .window_reset,
                        .agent = snap.agent,
                        .window = w.kind,
                        .percent = pct,
                        .prev_high = slot.high_water,
                    });
                    slot.high_water = pct;
                } else if (pct > slot.high_water) {
                    slot.high_water = pct;
                }

                // threshold: upward crossings; highest un-latched tier
                // fires, the rest latch silently.
                var best: ?u8 = null;
                for (thresholds) |t| {
                    if (pct >= @as(f64, @floatFromInt(t)) and !slot.latched.isSet(t)) {
                        slot.latched.set(t);
                        if (best == null or t > best.?) best = t;
                    }
                }
                if (best) |t| {
                    appendCandidate(&candidates, &n_cand, .{
                        .priority = thresholdPriority(t),
                        .kind = .threshold,
                        .agent = snap.agent,
                        .window = w.kind,
                        .threshold = t,
                        .percent = pct,
                        .resets_at_ms = w.resets_at_ms,
                    });
                }
            }
        }

        // ---- priority sort (stable insertion, descending) ------------
        var i: usize = 1;
        while (i < n_cand) : (i += 1) {
            const c = candidates[i];
            var j = i;
            while (j > 0 and candidates[j - 1].priority < c.priority) : (j -= 1) {
                candidates[j] = candidates[j - 1];
            }
            candidates[j] = c;
        }

        // ---- rate limit + truncation, then render --------------------
        var fired: usize = 0;
        for (candidates[0..n_cand]) |cand| {
            if (fired == max_alerts_per_observe) break;
            const ai = @intFromEnum(cand.agent);
            const ki = @intFromEnum(cand.kind);
            if (self.last_fired_ms[ai][ki]) |last| {
                if (now_ms - last < rate_limit_ms) continue;
            }
            self.last_fired_ms[ai][ki] = now_ms;
            self.out[fired] = render(cand, now_ms, tz_offset_min, wall);
            fired += 1;
        }
        return self.out[0..fired];
    }
};

fn appendCandidate(list: *[AlertEngine.max_candidates]Candidate, len: *usize, cand: Candidate) void {
    // Overflow (cannot happen with the closed agent × window set):
    // state already latched above, the notification is simply dropped.
    if (len.* >= list.len) return;
    list[len.*] = cand;
    len.* += 1;
}

// ---------------------------------------------------------------- render

pub fn agentName(agent: types.Agent) []const u8 {
    return switch (agent) {
        .claude => "Claude",
        .codex => "Codex",
    };
}

pub fn windowName(kind: types.LimitWindow.Kind) []const u8 {
    return switch (kind) {
        .five_hour => "5h",
        .weekly => "weekly",
        .weekly_opus => "Opus weekly",
        .weekly_sonnet => "Sonnet weekly",
        .monthly => "monthly",
    };
}

fn pctInt(p: f64) u64 {
    return @intFromFloat(@round(std.math.clamp(p, 0, 100)));
}

fn render(cand: Candidate, now_ms: i64, tz_offset_min: i32, wall: ?predict.Wall) Alert {
    var alert = Alert{ .kind = cand.kind, .agent = cand.agent, .window = cand.window };
    var tw = std.Io.Writer.fixed(&alert.title_buf);
    var bw = std.Io.Writer.fixed(&alert.body_buf);

    switch (cand.kind) {
        .threshold => {
            // "Claude 5h window at 90%"
            tw.writeAll(agentName(cand.agent)) catch {};
            tw.writeByte(' ') catch {};
            tw.writeAll(windowName(cand.window)) catch {};
            tw.writeAll(" window at ") catch {};
            tw.printInt(cand.threshold, 10, .lower, .{}) catch {};
            tw.writeByte('%') catch {};
            // "resets 2h14m · at this pace wall at 3:40p"
            var wrote_any = false;
            if (cand.resets_at_ms > now_ms) {
                bw.writeAll("resets ") catch {};
                trayfmt.writeCountdown(&bw, cand.resets_at_ms - now_ms) catch {};
                wrote_any = true;
            }
            if (wall) |w| {
                if (w.agent == cand.agent and w.kind == cand.window and w.at_ms > now_ms) {
                    if (wrote_any) bw.writeAll(" · ") catch {};
                    bw.writeAll("at this pace wall at ") catch {};
                    trayfmt.writeClock(&bw, w.at_ms, tz_offset_min) catch {};
                }
            }
        },
        .wall_imminent => {
            // "Claude 5h wall in 27m"
            tw.writeAll(agentName(cand.agent)) catch {};
            tw.writeByte(' ') catch {};
            tw.writeAll(windowName(cand.window)) catch {};
            tw.writeAll(" wall in ") catch {};
            trayfmt.writeCountdown(&tw, @max(cand.wall_at_ms - now_ms, 0)) catch {};
            // "now 87% · at this pace limit at 1:27p"
            bw.writeAll("now ") catch {};
            bw.printInt(pctInt(cand.percent), 10, .lower, .{}) catch {};
            bw.writeAll("% · at this pace limit at ") catch {};
            trayfmt.writeClock(&bw, cand.wall_at_ms, tz_offset_min) catch {};
        },
        .window_reset => {
            // "Claude 5h window reset"
            tw.writeAll(agentName(cand.agent)) catch {};
            tw.writeByte(' ') catch {};
            tw.writeAll(windowName(cand.window)) catch {};
            tw.writeAll(" window reset") catch {};
            // "usage fell from 92% to 5% — you're clear"
            bw.writeAll("usage fell from ") catch {};
            bw.printInt(pctInt(cand.prev_high), 10, .lower, .{}) catch {};
            bw.writeAll("% to ") catch {};
            bw.printInt(pctInt(cand.percent), 10, .lower, .{}) catch {};
            bw.writeAll("% — you're clear") catch {};
        },
    }
    alert.title_len = @intCast(tw.buffered().len);
    alert.body_len = @intCast(bw.buffered().len);
    return alert;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Observe a single window reading. The slices only need to live for
/// the duration of the call — observe retains nothing.
fn observeOne(
    eng: *AlertEngine,
    now_ms: i64,
    agent: types.Agent,
    kind: types.LimitWindow.Kind,
    pct: f64,
    resets_at_ms: i64,
    wall: ?predict.Wall,
    thresholds: []const u8,
) []const Alert {
    const wins = [_]types.LimitWindow{
        .{ .kind = kind, .used_percent = pct, .resets_at_ms = resets_at_ms },
    };
    const snaps = [_]types.LimitSnapshot{
        .{ .agent = agent, .read_at_ms = now_ms, .windows = &wins },
    };
    return eng.observe(now_ms, 0, &snaps, wall, thresholds);
}

const min = 60_000; // ms

test "threshold crossing fires once, then stays latched" {
    var eng = AlertEngine{};
    const th = [_]u8{ 70, 90 };

    // Cold-start baseline at a low reading.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &th).len);

    const fired = observeOne(&eng, 11 * min, .claude, .five_hour, 72, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqual(AlertKind.threshold, fired[0].kind);
    try testing.expectEqual(types.Agent.claude, fired[0].agent);
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, fired[0].window.?);

    // Still above 70: latched, silent.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 22 * min, .claude, .five_hour, 74, 0, null, &th).len);
}

test "threshold re-arms only after falling five points below" {
    var eng = AlertEngine{};
    const th = [_]u8{70};

    _ = observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), observeOne(&eng, 11 * min, .claude, .five_hour, 72, 0, null, &th).len);

    // Dips into the hysteresis band (66..70): no re-arm, no re-fire.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 22 * min, .claude, .five_hour, 67, 0, null, &th).len);
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 33 * min, .claude, .five_hour, 72, 0, null, &th).len);

    // Falls to 65 (= 70 - 5): re-armed; the next crossing fires again.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 44 * min, .claude, .five_hour, 65, 0, null, &th).len);
    try testing.expectEqual(@as(usize, 1), observeOne(&eng, 55 * min, .claude, .five_hour, 71, 0, null, &th).len);
}

test "cold start suppresses the 70 tier but fires the 90 tier" {
    const th = [_]u8{ 70, 90 };

    // Already at 75% on install: silence.
    var quiet = AlertEngine{};
    try testing.expectEqual(@as(usize, 0), observeOne(&quiet, 0, .claude, .five_hour, 75, 0, null, &th).len);
    // ...and 70 stays latched afterwards.
    try testing.expectEqual(@as(usize, 0), observeOne(&quiet, 11 * min, .claude, .five_hour, 78, 0, null, &th).len);

    // Already at 93% on install: that's the wall — say so.
    var loud = AlertEngine{};
    const fired = observeOne(&loud, 0, .claude, .five_hour, 93, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqualStrings("Claude 5h window at 90%", fired[0].title());
}

test "crossing two tiers in one observation fires only the highest" {
    var eng = AlertEngine{};
    const th = [_]u8{ 70, 90 };

    _ = observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &th);
    const fired = observeOne(&eng, 11 * min, .claude, .five_hour, 95, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqualStrings("Claude 5h window at 90%", fired[0].title());
    // Both tiers latched: nothing further while high.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 22 * min, .claude, .five_hour, 96, 0, null, &th).len);
}

test "wall imminent fires inside 30 minutes and honors the 45 minute re-arm" {
    var eng = AlertEngine{};

    // 31 minutes out: quiet.
    var wall = predict.Wall{ .agent = .claude, .kind = .five_hour, .at_ms = 31 * min, .used_percent = 80 };
    try testing.expectEqual(@as(usize, 0), eng.observe(0, 0, &.{}, wall, &.{}).len);

    // 29 minutes out: fires.
    wall.at_ms = 29 * min;
    var fired = eng.observe(0, 0, &.{}, wall, &.{});
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqual(AlertKind.wall_imminent, fired[0].kind);

    // Recedes to 40 min out (inside the 30–45 band): no re-arm, so a
    // return to 25 min out stays quiet.
    wall.at_ms = 11 * min + 40 * min;
    try testing.expectEqual(@as(usize, 0), eng.observe(11 * min, 0, &.{}, wall, &.{}).len);
    wall.at_ms = 22 * min + 25 * min;
    try testing.expectEqual(@as(usize, 0), eng.observe(22 * min, 0, &.{}, wall, &.{}).len);

    // Recedes past 45 min: re-armed; the next approach fires.
    wall.at_ms = 33 * min + 50 * min;
    try testing.expectEqual(@as(usize, 0), eng.observe(33 * min, 0, &.{}, wall, &.{}).len);
    wall.at_ms = 44 * min + 20 * min;
    fired = eng.observe(44 * min, 0, &.{}, wall, &.{});
    try testing.expectEqual(@as(usize, 1), fired.len);
}

test "a disappearing wall re-arms the wall alert" {
    var eng = AlertEngine{};
    var wall = predict.Wall{ .agent = .codex, .kind = .weekly, .at_ms = 20 * min, .used_percent = 88 };
    try testing.expectEqual(@as(usize, 1), eng.observe(0, 0, &.{}, wall, &.{}).len);

    // Wall gone (idle): re-arm.
    try testing.expectEqual(@as(usize, 0), eng.observe(11 * min, 0, &.{}, null, &.{}).len);
    wall.at_ms = 22 * min + 20 * min;
    try testing.expectEqual(@as(usize, 1), eng.observe(22 * min, 0, &.{}, wall, &.{}).len);
}

test "window reset fires once when a hot window clears" {
    var eng = AlertEngine{};
    const th = [_]u8{}; // isolate the reset path

    _ = observeOne(&eng, 0, .claude, .five_hour, 40, 0, null, &th);
    _ = observeOne(&eng, 11 * min, .claude, .five_hour, 92, 0, null, &th);

    const fired = observeOne(&eng, 22 * min, .claude, .five_hour, 5, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqual(AlertKind.window_reset, fired[0].kind);
    try testing.expectEqualStrings("Claude 5h window reset", fired[0].title());
    try testing.expectEqualStrings("usage fell from 92% to 5% — you're clear", fired[0].body());

    // Staying low does not re-fire.
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 33 * min, .claude, .five_hour, 5, 0, null, &th).len);
    // A drop from a sub-70 high-water mark is not a "you're clear" moment.
    _ = observeOne(&eng, 44 * min, .claude, .five_hour, 40, 0, null, &th);
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 55 * min, .claude, .five_hour, 8, 0, null, &th).len);
}

test "rate limit: a crossing inside the 10 minute window is dropped, not queued" {
    var eng = AlertEngine{};
    const th = [_]u8{70};

    _ = observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), observeOne(&eng, 1 * min, .claude, .five_hour, 72, 0, null, &th).len);

    // Re-arm, then cross again 4 minutes after the fire: suppressed
    // (and latched — it will NOT fire later without another re-arm).
    _ = observeOne(&eng, 3 * min, .claude, .five_hour, 60, 0, null, &th);
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 5 * min, .claude, .five_hour, 72, 0, null, &th).len);
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 20 * min, .claude, .five_hour, 74, 0, null, &th).len);

    // A fresh re-arm + crossing outside the window fires again.
    _ = observeOne(&eng, 21 * min, .claude, .five_hour, 60, 0, null, &th);
    try testing.expectEqual(@as(usize, 1), observeOne(&eng, 32 * min, .claude, .five_hour, 72, 0, null, &th).len);
}

test "priority truncation: wall first, thresholds high to low, reset dropped" {
    var eng = AlertEngine{};
    const th = [_]u8{ 70, 90 };

    // Baselines: claude 5h low, codex 5h low, codex weekly hot (70
    // latches silently on cold start).
    const base_claude = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 10 }};
    const base_codex = [_]types.LimitWindow{
        .{ .kind = .five_hour, .used_percent = 10 },
        .{ .kind = .weekly, .used_percent = 80 },
    };
    const base = [_]types.LimitSnapshot{
        .{ .agent = .claude, .read_at_ms = 0, .windows = &base_claude },
        .{ .agent = .codex, .read_at_ms = 0, .windows = &base_codex },
    };
    try testing.expectEqual(@as(usize, 0), eng.observe(0, 0, &base, null, &th).len);

    // One observe with four candidates across distinct (agent, kind)
    // pairs: wall(claude), threshold(claude 90), threshold(codex 70),
    // reset(codex weekly). Budget is 3 — the reset loses.
    const now = 11 * min;
    const hot_claude = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 92 }};
    const hot_codex = [_]types.LimitWindow{
        .{ .kind = .five_hour, .used_percent = 75 },
        .{ .kind = .weekly, .used_percent = 45 },
    };
    const snaps = [_]types.LimitSnapshot{
        .{ .agent = .claude, .read_at_ms = now, .windows = &hot_claude },
        .{ .agent = .codex, .read_at_ms = now, .windows = &hot_codex },
    };
    const wall = predict.Wall{ .agent = .claude, .kind = .five_hour, .at_ms = now + 25 * min, .used_percent = 92 };
    const fired = eng.observe(now, 0, &snaps, wall, &th);

    try testing.expectEqual(@as(usize, 3), fired.len);
    try testing.expectEqual(AlertKind.wall_imminent, fired[0].kind);
    try testing.expectEqual(types.Agent.claude, fired[0].agent);
    try testing.expectEqual(AlertKind.threshold, fired[1].kind);
    try testing.expectEqual(types.Agent.claude, fired[1].agent);
    try testing.expectEqualStrings("Claude 5h window at 90%", fired[1].title());
    try testing.expectEqual(AlertKind.threshold, fired[2].kind);
    try testing.expectEqual(types.Agent.codex, fired[2].agent);
    try testing.expectEqualStrings("Codex 5h window at 70%", fired[2].title());
}

test "agents alert independently, including their rate limits" {
    var eng = AlertEngine{};
    const th = [_]u8{70};

    const base = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 10 }};
    const both_low = [_]types.LimitSnapshot{
        .{ .agent = .claude, .read_at_ms = 0, .windows = &base },
        .{ .agent = .codex, .read_at_ms = 0, .windows = &base },
    };
    _ = eng.observe(0, 0, &both_low, null, &th);

    // Both cross in the same observe: two alerts (rate limit is per
    // agent), and claude's latch never leaks onto codex.
    const hot = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 72 }};
    const both_hot = [_]types.LimitSnapshot{
        .{ .agent = .claude, .read_at_ms = 11 * min, .windows = &hot },
        .{ .agent = .codex, .read_at_ms = 11 * min, .windows = &hot },
    };
    const fired = eng.observe(11 * min, 0, &both_hot, null, &th);
    try testing.expectEqual(@as(usize, 2), fired.len);
    try testing.expectEqual(types.Agent.claude, fired[0].agent);
    try testing.expectEqual(types.Agent.codex, fired[1].agent);
}

test "threshold alert text renders exactly" {
    var eng = AlertEngine{};
    const th = [_]u8{ 70, 90 };

    // now = 13:24 UTC; window resets 2h14m out; wall (matching this
    // agent + window) projected at 15:40 UTC = "3:40p".
    const now: i64 = (13 * 60 + 24) * min;
    const resets = now + (2 * 60 + 14) * min;
    const wall = predict.Wall{
        .agent = .claude,
        .kind = .five_hour,
        .at_ms = (15 * 60 + 40) * min,
        .used_percent = 92,
    };

    _ = observeOne(&eng, now - 11 * min, .claude, .five_hour, 10, resets, null, &th);
    const fired = observeOne(&eng, now, .claude, .five_hour, 92, resets, wall, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqualStrings("Claude 5h window at 90%", fired[0].title());
    try testing.expectEqualStrings("resets 2h14m · at this pace wall at 3:40p", fired[0].body());
}

test "wall alert text renders exactly" {
    var eng = AlertEngine{};
    const now: i64 = 13 * 60 * min; // 13:00 UTC
    const wall = predict.Wall{
        .agent = .claude,
        .kind = .five_hour,
        .at_ms = now + 27 * min, // 13:27 = "1:27p"
        .used_percent = 87.4,
    };
    const fired = eng.observe(now, 0, &.{}, wall, &.{});
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqualStrings("Claude 5h wall in 27m", fired[0].title());
    try testing.expectEqualStrings("now 87% · at this pace limit at 1:27p", fired[0].body());
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, fired[0].window.?);
}

test "a threshold body with no reset and no matching wall stays empty" {
    var eng = AlertEngine{};
    const th = [_]u8{70};
    // Wall belongs to a DIFFERENT window — it must not leak into the body.
    const wall = predict.Wall{ .agent = .codex, .kind = .weekly, .at_ms = 999 * min, .used_percent = 50 };

    _ = observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &th);
    const fired = observeOne(&eng, 11 * min, .claude, .five_hour, 72, 0, wall, &th);
    try testing.expectEqual(@as(usize, 1), fired.len);
    try testing.expectEqualStrings("Claude 5h window at 70%", fired[0].title());
    try testing.expectEqualStrings("", fired[0].body());
}

test "empty thresholds produce no threshold alerts" {
    var eng = AlertEngine{};
    _ = observeOne(&eng, 0, .claude, .five_hour, 10, 0, null, &.{});
    try testing.expectEqual(@as(usize, 0), observeOne(&eng, 11 * min, .claude, .five_hour, 95, 0, null, &.{}).len);
}

test "window and agent names cover the closed enum sets" {
    // Rendering pulls from these tables; keep them total.
    try testing.expectEqualStrings("Claude", agentName(.claude));
    try testing.expectEqualStrings("Codex", agentName(.codex));
    try testing.expectEqualStrings("5h", windowName(.five_hour));
    try testing.expectEqualStrings("weekly", windowName(.weekly));
    try testing.expectEqualStrings("Opus weekly", windowName(.weekly_opus));
    try testing.expectEqualStrings("Sonnet weekly", windowName(.weekly_sonnet));
    try testing.expectEqualStrings("monthly", windowName(.monthly));
}
