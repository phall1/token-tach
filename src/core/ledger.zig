//! Ledger: aggregation over the deduped UsageEvent stream.
//! Tailers own dedup; the ledger owns rollups — running totals per day,
//! hour, session, model, agent, and project (cwd) that the tray, popover,
//! and dashboard read directly. Costs are priced at add time by the caller
//! (pricing.Db) so the ledger stays import-light and trivially testable.
//!
//! Two resolutions, on purpose. `per_day` is the persisted, unbounded
//! spine (statefile round-trips it) and answers "this month". `per_hour`
//! is the bounded, in-memory time dimension that makes "today by hour"
//! and "this 5h window" answerable without a scan over raw events, and
//! it carries a per-agent breakdown so a windowed AGENT SHARE stops being
//! all-time archaeology. Anything finer than an hour belongs in
//! `ring.Accumulator`, not here: the ledger is a rollup, not an event log.
//!
//! Memory is capped, not merely "expected to be small" — this process
//! runs for weeks in a menu bar. See `max_hour_buckets` / `max_sessions`.

const std = @import("std");
const types = @import("types.zig");

pub const Totals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cost_usd: f64 = 0,
    events: u64 = 0,

    pub fn add(self: *Totals, ev: types.UsageEvent, cost: ?f64) void {
        self.input_tokens += ev.input_tokens;
        self.output_tokens += ev.output_tokens;
        self.cache_creation_tokens += ev.cache_creation_tokens;
        self.cache_read_tokens += ev.cache_read_tokens;
        self.cost_usd += cost orelse 0;
        self.events += 1;
    }

    pub fn remove(self: *Totals, ev: types.UsageEvent, cost: ?f64) void {
        self.input_tokens -|= ev.input_tokens;
        self.output_tokens -|= ev.output_tokens;
        self.cache_creation_tokens -|= ev.cache_creation_tokens;
        self.cache_read_tokens -|= ev.cache_read_tokens;
        self.cost_usd -= cost orelse 0;
        if (@abs(self.cost_usd) < 1e-12) self.cost_usd = 0;
        self.events -|= 1;
    }

    pub fn totalTokens(self: Totals) u64 {
        return self.input_tokens + self.output_tokens +
            self.cache_creation_tokens + self.cache_read_tokens;
    }
};

/// Local-day bucket key: days since epoch after applying the caller's
/// UTC offset. "Today's spend" is a local concept.
pub fn dayKey(ts_ms: i64, tz_offset_min: i32) i64 {
    const local_ms = ts_ms + @as(i64, tz_offset_min) * 60_000;
    return @divFloor(local_ms, 86_400_000);
}

/// Hour bucket key: hours since epoch after applying the caller's UTC
/// offset — LOCAL hours, the same shift `dayKey` uses.
///
/// The tempting alternative (UTC hours, "hours don't have a timezone")
/// is quietly wrong for this instrument. Every hourly reading the UI
/// wants is a *slice of a local day*: "today by hour", "the current 5h
/// window". With UTC hour keys and a half-hour zone (IST +5:30, NPT
/// +5:45) the local midnight boundary falls in the MIDDLE of a bucket,
/// so the first and last bars of "today" silently include minutes from
/// the neighbouring day and the hourly bars stop summing to the daily
/// total. Shifting before the divide makes the nesting exact for every
/// offset: `dayOfHour(hourKey(t, off)) == dayKey(t, off)` always, because
/// 86_400_000 is a whole multiple of 3_600_000 and both floor the same
/// shifted instant.
///
/// The cost of that choice: an offset change (DST) re-buckets only
/// FUTURE events; already-recorded buckets keep the key they were filed
/// under, so the wall-clock hour a historical bucket represents shifts by
/// the delta. Daily totals are unaffected (per_day carries its own keys),
/// and one ambiguous hour twice a year is a better trade than permanently
/// wrong "today" edges in half the world's timezones.
pub fn hourKey(ts_ms: i64, tz_offset_min: i32) i64 {
    const local_ms = ts_ms + @as(i64, tz_offset_min) * 60_000;
    return @divFloor(local_ms, 3_600_000);
}

/// Hours per local day — the nesting factor between the two bucket keys.
pub const hours_per_day: i64 = 24;

/// The local day an hour bucket belongs to. Exact for any offset (see
/// `hourKey`), so hour bars always sum to their day bar.
pub fn dayOfHour(hour: i64) i64 {
    return @divFloor(hour, hours_per_day);
}

/// First instant (unix ms, UTC) covered by an hour bucket under `offset`.
/// The inverse of `hourKey`, and what range queries compare against.
pub fn hourStartMs(hour: i64, tz_offset_min: i32) i64 {
    return hour * 3_600_000 - @as(i64, tz_offset_min) * 60_000;
}

/// First instant (unix ms, UTC) covered by a day bucket under `offset`.
pub fn dayStartMs(day: i64, tz_offset_min: i32) i64 {
    return day * 86_400_000 - @as(i64, tz_offset_min) * 60_000;
}

/// Rolling window `per_hour` retains, in local days. Everything the UI
/// asks of the hourly series is inside two days ("today by hour", the
/// current 5h window); two weeks leaves room for a trailing-fortnight
/// chart without pretending this map is an archive. Older history is
/// still exact in `per_day`, which is the series that gets persisted.
pub const hour_retention_days: i64 = 14;

/// Hard ceiling on live hour buckets. Eviction keys off the newest bucket
/// observed, so the map holds at most this many distinct keys the moment
/// `add` returns — see `pruneHours`.
///
/// Ceiling: 336 buckets x ~732 B (key + Totals + the per-agent EnumArray)
/// ~= 245 KB, growing ~16 KB per Agent member added to types.Agent.
pub const max_hour_buckets: usize = @intCast(hour_retention_days * hours_per_day);

/// Hard ceiling on tracked sessions; past it the least-recently-seen
/// session is dropped. A busy day is tens of sessions, so 256 is weeks of
/// headroom, and the eviction scan (O(n), only when a NEW session arrives
/// at the cap) is invisible at that size.
///
/// Ceiling: 256 x (rollup ~80 B + key header 16 B + duped id ~40 B)
/// ~= 35 KB. Total bounded ledger overhead stays under ~300 KB.
pub const max_sessions: usize = 256;

/// One hour of usage plus its per-agent split. The split is what lets the
/// dashboard's AGENT SHARE row be scoped to a window instead of shouting
/// ALL-TIME; an EnumArray keeps it automatic when types.Agent grows.
pub const HourBucket = struct {
    totals: Totals = .{},
    per_agent: std.EnumArray(types.Agent, Totals) = .initFill(.{}),
};

/// Per-session rollup. `last_seen_ms` exists so a UI can sort by recency
/// (and so eviction has an honest victim) without re-scanning events;
/// `agent` is the agent that opened the session — collectors never share
/// a session id across agents.
pub const SessionRollup = struct {
    agent: types.Agent,
    totals: Totals = .{},
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
};

/// A session rollup paired with its id, for recency listings.
pub const SessionRef = struct {
    id: []const u8,
    rollup: SessionRollup,
};

/// Which series a trailing-window query reads.
pub const Unit = enum { hour, day };

pub const Ledger = struct {
    allocator: std.mem.Allocator,
    all: Totals = .{},
    per_agent: std.EnumArray(types.Agent, Totals) = .initFill(.{}),
    per_day: std.AutoArrayHashMapUnmanaged(i64, Totals) = .empty,
    /// Per-day cost from subscription-covered agents only (claude/codex —
    /// the agents with a monthly plan). The subscription-value multiple
    /// divides THIS by the plan price so API-billed agents (opencode and
    /// the collector fleet) can't inflate it. Cost only; tokens live in
    /// per_day.
    covered_per_day: std.AutoArrayHashMapUnmanaged(i64, f64) = .empty,
    /// Bounded hourly series (see `max_hour_buckets`). Not persisted yet:
    /// after a warm restore this is empty until the tailers replay, so
    /// hourly queries degrade to "no data", never to wrong data.
    per_hour: std.AutoArrayHashMapUnmanaged(i64, HourBucket) = .empty,
    /// Newest hour key ever recorded — the anchor the retention window
    /// trails. Tracked incrementally so pruning never scans for a max.
    newest_hour: i64 = std.math.minInt(i64),
    /// Per-session rollups, keyed by the `session_id` every collector
    /// already stamps. Bounded by `max_sessions`, LRU-by-`last_seen_ms`.
    per_session: std.StringArrayHashMapUnmanaged(SessionRollup) = .empty,
    per_model: std.StringArrayHashMapUnmanaged(Totals) = .empty,
    per_project: std.StringArrayHashMapUnmanaged(Totals) = .empty,
    tz_offset_min: i32,

    pub fn init(allocator: std.mem.Allocator, tz_offset_min: i32) Ledger {
        return .{ .allocator = allocator, .tz_offset_min = tz_offset_min };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.per_model.keys()) |k| self.allocator.free(k);
        for (self.per_project.keys()) |k| self.allocator.free(k);
        for (self.per_session.keys()) |k| self.allocator.free(k);
        self.per_day.deinit(self.allocator);
        self.covered_per_day.deinit(self.allocator);
        self.per_hour.deinit(self.allocator);
        self.per_session.deinit(self.allocator);
        self.per_model.deinit(self.allocator);
        self.per_project.deinit(self.allocator);
    }

    /// Record one deduped event with its (already computed) cost.
    pub fn add(self: *Ledger, ev: types.UsageEvent, cost: ?f64) !void {
        self.all.add(ev, cost);
        self.per_agent.getPtr(ev.agent).add(ev, cost);

        const key = dayKey(ev.timestamp_ms, self.tz_offset_min);
        const day = try self.per_day.getOrPutValue(self.allocator, key, .{});
        day.value_ptr.add(ev, cost);
        if (ev.agent.hasLimitsPanel()) {
            const covered = try self.covered_per_day.getOrPutValue(self.allocator, key, 0);
            covered.value_ptr.* += cost orelse 0;
        }

        const hkey = hourKey(ev.timestamp_ms, self.tz_offset_min);
        {
            const bucket = try self.per_hour.getOrPutValue(self.allocator, hkey, .{});
            bucket.value_ptr.totals.add(ev, cost);
            bucket.value_ptr.per_agent.getPtr(ev.agent).add(ev, cost);
        }
        // Prune only after the bucket pointer above is dead: pruning
        // swap-removes entries and invalidates every value pointer.
        if (hkey > self.newest_hour) self.newest_hour = hkey;
        self.pruneHours();

        // A blank session id means the collector had none to give; a
        // shared "" rollup would blend every such agent into one fake
        // session, so those events stay out of the session dimension.
        if (ev.session_id.len > 0) try self.addSession(ev, cost);

        // A blank model string is not a model — unpriced sources (e.g.
        // kimi) would otherwise collapse into one nameless rollup row.
        if (ev.model.len > 0) try addKeyed(self.allocator, &self.per_model, ev.model, ev, cost);
        if (ev.cwd.len > 0) try addKeyed(self.allocator, &self.per_project, ev.cwd, ev, cost);
    }

    /// Drop hour buckets older than the retention window. Anchored to the
    /// newest bucket seen rather than a `now` the ledger doesn't have, and
    /// run only once the map is over cap so a sparse-usage machine (a few
    /// buckets a month) never loses history it isn't paying for.
    ///
    /// The window spans exactly `max_hour_buckets` distinct keys, so after
    /// this returns the map holds at most that many entries — the ceiling
    /// is structural, not aspirational.
    fn pruneHours(self: *Ledger) void {
        if (self.per_hour.count() <= max_hour_buckets) return;
        const cutoff = self.newest_hour - @as(i64, @intCast(max_hour_buckets)) + 1;
        // Backwards: swapRemoveAt moves the last entry into the hole, and
        // walking down means that entry has already been inspected.
        var i = self.per_hour.count();
        while (i > 0) {
            i -= 1;
            if (self.per_hour.keys()[i] < cutoff) self.per_hour.swapRemoveAt(i);
        }
    }

    fn addSession(self: *Ledger, ev: types.UsageEvent, cost: ?f64) !void {
        if (self.per_session.getPtr(ev.session_id)) |rollup| {
            rollup.totals.add(ev, cost);
            if (ev.timestamp_ms > rollup.last_seen_ms) rollup.last_seen_ms = ev.timestamp_ms;
            if (ev.timestamp_ms < rollup.first_seen_ms) rollup.first_seen_ms = ev.timestamp_ms;
            return;
        }
        // Make room BEFORE inserting: evicting after would let the map
        // touch cap+1 and hand the eviction scan the row we just wrote.
        self.evictSessions();
        const gop = try self.per_session.getOrPut(self.allocator, ev.session_id);
        gop.key_ptr.* = self.allocator.dupe(u8, ev.session_id) catch |err| {
            _ = self.per_session.swapRemove(ev.session_id);
            return err;
        };
        gop.value_ptr.* = .{
            .agent = ev.agent,
            .first_seen_ms = ev.timestamp_ms,
            .last_seen_ms = ev.timestamp_ms,
        };
        gop.value_ptr.totals.add(ev, cost);
    }

    /// Evict least-recently-seen sessions until one more will fit.
    /// Recency, not insertion order: a long-lived session that is still
    /// producing events must outlive a burst of short dead ones.
    fn evictSessions(self: *Ledger) void {
        while (self.per_session.count() >= max_sessions) {
            var victim: usize = 0;
            var oldest: i64 = std.math.maxInt(i64);
            for (self.per_session.values(), 0..) |rollup, i| {
                if (rollup.last_seen_ms < oldest) {
                    oldest = rollup.last_seen_ms;
                    victim = i;
                }
            }
            const key = self.per_session.keys()[victim];
            self.per_session.swapRemoveAt(victim);
            self.allocator.free(key);
        }
    }

    /// Replace an updated-in-place source row without double-counting it.
    pub fn replace(self: *Ledger, old: types.UsageEvent, old_cost: ?f64, new: types.UsageEvent, new_cost: ?f64) !void {
        self.remove(old, old_cost);
        try self.add(new, new_cost);
    }

    fn remove(self: *Ledger, ev: types.UsageEvent, cost: ?f64) void {
        self.all.remove(ev, cost);
        self.per_agent.getPtr(ev.agent).remove(ev, cost);
        const key = dayKey(ev.timestamp_ms, self.tz_offset_min);
        if (self.per_day.getPtr(key)) |totals| totals.remove(ev, cost);
        if (ev.agent.hasLimitsPanel()) {
            if (self.covered_per_day.getPtr(key)) |c| {
                c.* -= cost orelse 0;
                if (@abs(c.*) < 1e-12) c.* = 0;
            }
        }
        // A pruned hour bucket or an evicted session is a no-op here, the
        // same way a missing per_day bucket already is: the correction
        // belongs to history the ledger deliberately stopped keeping.
        if (self.per_hour.getPtr(hourKey(ev.timestamp_ms, self.tz_offset_min))) |bucket| {
            bucket.totals.remove(ev, cost);
            bucket.per_agent.getPtr(ev.agent).remove(ev, cost);
        }
        if (ev.session_id.len > 0) {
            if (self.per_session.getPtr(ev.session_id)) |rollup| rollup.totals.remove(ev, cost);
        }
        if (ev.model.len > 0) if (self.per_model.getPtr(ev.model)) |totals| totals.remove(ev, cost);
        if (ev.cwd.len > 0) if (self.per_project.getPtr(ev.cwd)) |totals| totals.remove(ev, cost);
    }

    fn addKeyed(
        allocator: std.mem.Allocator,
        map: *std.StringArrayHashMapUnmanaged(Totals),
        key: []const u8,
        ev: types.UsageEvent,
        cost: ?f64,
    ) !void {
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, key);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.add(ev, cost);
    }

    /// Statefile restore: seed one day bucket wholesale (overwrites).
    pub fn putDay(self: *Ledger, day: i64, totals: Totals) !void {
        try self.per_day.put(self.allocator, day, totals);
    }

    /// Statefile restore: seed one covered-cost day bucket (overwrites).
    pub fn putCoveredDay(self: *Ledger, day: i64, cost_usd: f64) !void {
        try self.covered_per_day.put(self.allocator, day, cost_usd);
    }

    /// Subscription-covered API-equivalent cost over the day-key range
    /// [first, first + count) — the honest numerator for the
    /// subscription-value multiple (claude/codex only).
    pub fn coveredCostInRange(self: *const Ledger, first: i64, count: i64) f64 {
        var total: f64 = 0;
        for (self.covered_per_day.keys(), self.covered_per_day.values()) |key, cost| {
            if (key >= first and key < first + count) total += cost;
        }
        return total;
    }

    /// Statefile restore: seed one model rollup wholesale (overwrites).
    pub fn putModel(self: *Ledger, model: []const u8, totals: Totals) !void {
        try putKeyed(self.allocator, &self.per_model, model, totals);
    }

    /// Statefile restore: seed one project rollup wholesale (overwrites).
    pub fn putProject(self: *Ledger, project: []const u8, totals: Totals) !void {
        try putKeyed(self.allocator, &self.per_project, project, totals);
    }

    fn putKeyed(
        allocator: std.mem.Allocator,
        map: *std.StringArrayHashMapUnmanaged(Totals),
        key: []const u8,
        totals: Totals,
    ) !void {
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, key) catch |err| {
                _ = map.orderedRemove(key);
                return err;
            };
        }
        gop.value_ptr.* = totals;
    }

    /// Statefile restore (Wave 2): seed one hour bucket wholesale. Kept
    /// symmetric with `putDay` so persisting the hourly series later is a
    /// wire-format change only, not a ledger change.
    pub fn putHour(self: *Ledger, hour: i64, bucket: HourBucket) !void {
        try self.per_hour.put(self.allocator, hour, bucket);
        if (hour > self.newest_hour) self.newest_hour = hour;
        self.pruneHours();
    }

    /// Statefile restore (Wave 2): seed one session rollup wholesale.
    pub fn putSession(self: *Ledger, id: []const u8, rollup: SessionRollup) !void {
        if (self.per_session.getPtr(id)) |existing| {
            existing.* = rollup;
            return;
        }
        self.evictSessions();
        const gop = try self.per_session.getOrPut(self.allocator, id);
        gop.key_ptr.* = self.allocator.dupe(u8, id) catch |err| {
            _ = self.per_session.swapRemove(id);
            return err;
        };
        gop.value_ptr.* = rollup;
    }

    pub fn today(self: *const Ledger, now_ms: i64) Totals {
        return self.per_day.get(dayKey(now_ms, self.tz_offset_min)) orelse .{};
    }

    /// Usage inside the hour containing `now_ms`.
    pub fn thisHour(self: *const Ledger, now_ms: i64) Totals {
        const bucket = self.per_hour.get(hourKey(now_ms, self.tz_offset_min)) orelse return .{};
        return bucket.totals;
    }

    pub fn forAgent(self: *const Ledger, agent: types.Agent) Totals {
        return self.per_agent.get(agent);
    }

    /// Totals over the half-open window [from_ms, to_ms).
    ///
    /// Resolution is one hour: a bucket counts iff its START instant falls
    /// in the window. That makes the boundaries exact for the queries the
    /// UI actually asks — `totalsInRange(dayStartMs(d), dayStartMs(d + 1))`
    /// equals `per_day.get(d)` bucket-for-bucket — and makes the failure
    /// mode legible for the ones it doesn't: a sub-hour window ("the last
    /// 60 seconds") lands on at most one bucket start and is therefore an
    /// hour-granular answer, not a wrong one. Sub-hour resolution is
    /// `ring.Accumulator`'s job.
    ///
    /// Only the retained hourly window is visible here; older days live in
    /// `per_day` and are reachable via `trailing(.day, ...)`.
    pub fn totalsInRange(self: *const Ledger, from_ms: i64, to_ms: i64) Totals {
        var out: Totals = .{};
        if (to_ms <= from_ms) return out;
        for (self.per_hour.keys(), self.per_hour.values()) |key, *bucket| {
            const start = hourStartMs(key, self.tz_offset_min);
            if (start >= from_ms and start < to_ms) accumulate(&out, bucket.totals);
        }
        return out;
    }

    /// One agent's totals over [from_ms, to_ms) — same bucket semantics as
    /// `totalsInRange`.
    pub fn agentTotalsInRange(self: *const Ledger, agent: types.Agent, from_ms: i64, to_ms: i64) Totals {
        var out: Totals = .{};
        if (to_ms <= from_ms) return out;
        for (self.per_hour.keys(), self.per_hour.values()) |key, *bucket| {
            const start = hourStartMs(key, self.tz_offset_min);
            if (start >= from_ms and start < to_ms) accumulate(&out, bucket.per_agent.get(agent));
        }
        return out;
    }

    /// Every agent's totals over [from_ms, to_ms) in one scan — what a
    /// windowed AGENT SHARE row wants, without N passes over the map.
    pub fn agentsInRange(self: *const Ledger, from_ms: i64, to_ms: i64) std.EnumArray(types.Agent, Totals) {
        var out: std.EnumArray(types.Agent, Totals) = .initFill(.{});
        if (to_ms <= from_ms) return out;
        for (self.per_hour.keys(), self.per_hour.values()) |key, *bucket| {
            const start = hourStartMs(key, self.tz_offset_min);
            if (start < from_ms or start >= to_ms) continue;
            for (std.enums.values(types.Agent)) |agent| {
                accumulate(out.getPtr(agent), bucket.per_agent.get(agent));
            }
        }
        return out;
    }

    /// Fill `out` with the trailing `out.len` buckets of `unit`, oldest
    /// first, so `out[out.len - 1]` is the bucket containing `now_ms` and
    /// gaps read as zero. The general form of engine.trailingDailyCost —
    /// a chart asking for hours instead of days is a parameter, not
    /// another special case in the engine.
    pub fn trailing(self: *const Ledger, unit: Unit, now_ms: i64, out: []Totals) void {
        const newest = switch (unit) {
            .hour => hourKey(now_ms, self.tz_offset_min),
            .day => dayKey(now_ms, self.tz_offset_min),
        };
        for (out, 0..) |*slot, i| {
            const key = newest - @as(i64, @intCast(out.len - 1 - i));
            slot.* = switch (unit) {
                .hour => if (self.per_hour.get(key)) |bucket| bucket.totals else .{},
                .day => self.per_day.get(key) orelse .{},
            };
        }
    }

    /// `trailing` reduced to cost, for sparklines that only plot dollars.
    pub fn trailingCost(self: *const Ledger, unit: Unit, now_ms: i64, out: []f64) void {
        const newest = switch (unit) {
            .hour => hourKey(now_ms, self.tz_offset_min),
            .day => dayKey(now_ms, self.tz_offset_min),
        };
        for (out, 0..) |*slot, i| {
            const key = newest - @as(i64, @intCast(out.len - 1 - i));
            slot.* = switch (unit) {
                .hour => if (self.per_hour.get(key)) |bucket| bucket.totals.cost_usd else 0,
                .day => if (self.per_day.get(key)) |totals| totals.cost_usd else 0,
            };
        }
    }

    pub fn forSession(self: *const Ledger, id: []const u8) ?SessionRollup {
        return self.per_session.get(id);
    }

    /// Fill `out` with the most-recently-seen sessions, newest first, and
    /// return how many slots were written. Caller-provided buffer: the
    /// dashboard wants the top handful and the ledger refuses to allocate
    /// for a read.
    pub fn sessionsByRecency(self: *const Ledger, out: []SessionRef) usize {
        var n: usize = 0;
        for (self.per_session.keys(), self.per_session.values()) |id, rollup| {
            const ref: SessionRef = .{ .id = id, .rollup = rollup };
            // Insertion sort into the bounded window: O(cap * out.len)
            // with cap = max_sessions, and no allocation or scratch.
            var i = n;
            while (i > 0 and out[i - 1].rollup.last_seen_ms < ref.rollup.last_seen_ms) : (i -= 1) {
                if (i < out.len) out[i] = out[i - 1];
            }
            if (i < out.len) out[i] = ref;
            if (n < out.len) n += 1;
        }
        return n;
    }
};

fn accumulate(dst: *Totals, src: Totals) void {
    dst.input_tokens += src.input_tokens;
    dst.output_tokens += src.output_tokens;
    dst.cache_creation_tokens += src.cache_creation_tokens;
    dst.cache_read_tokens += src.cache_read_tokens;
    dst.cost_usd += src.cost_usd;
    dst.events += src.events;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn mkEv(agent: types.Agent, ts: i64, model: []const u8, out: u64) types.UsageEvent {
    return .{ .agent = agent, .timestamp_ms = ts, .model = model, .output_tokens = out, .cwd = "/w/proj" };
}

test "ledger rolls up across all dimensions" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    try ledger.add(mkEv(.claude, 1_000, "claude-fable-5", 100), 0.5);
    try ledger.add(mkEv(.claude, 2_000, "claude-sonnet-5", 50), 0.1);
    try ledger.add(mkEv(.codex, 3_000, "gpt-5.2-codex", 25), null);

    try testing.expectEqual(@as(u64, 175), ledger.all.totalTokens());
    try testing.expectEqual(@as(u64, 3), ledger.all.events);
    try testing.expectApproxEqAbs(@as(f64, 0.6), ledger.all.cost_usd, 1e-9);
    try testing.expectEqual(@as(u64, 150), ledger.forAgent(.claude).totalTokens());
    try testing.expectEqual(@as(u64, 25), ledger.forAgent(.codex).totalTokens());
    try testing.expectEqual(@as(u64, 100), ledger.per_model.get("claude-fable-5").?.totalTokens());
    try testing.expectEqual(@as(u64, 175), ledger.per_project.get("/w/proj").?.totalTokens());
}

test "covered_per_day counts only subscription-covered agents" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    // day 0 (ts within [0, 86_400_000)): claude+codex covered, opencode not.
    try ledger.add(mkEv(.claude, 1_000, "m", 10), 0.50);
    try ledger.add(mkEv(.codex, 2_000, "m", 10), 0.30);
    try ledger.add(mkEv(.opencode, 3_000, "m", 10), 2.00);
    try ledger.add(mkEv(.goose, 4_000, "m", 10), 5.00);

    // Covered cost for day 0 excludes opencode + goose.
    try testing.expectApproxEqAbs(@as(f64, 0.80), ledger.coveredCostInRange(0, 1), 1e-9);
    // The blended per_day still has everyone.
    try testing.expectApproxEqAbs(@as(f64, 7.80), ledger.per_day.get(0).?.cost_usd, 1e-9);
}

test "blank model string creates no per_model row" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    try ledger.add(.{ .agent = .kimi, .timestamp_ms = 1_000, .model = "", .output_tokens = 42 }, null);
    try testing.expectEqual(@as(usize, 0), ledger.per_model.count());
    // The event still counts everywhere else.
    try testing.expectEqual(@as(u64, 42), ledger.forAgent(.kimi).totalTokens());
    try testing.expectEqual(@as(u64, 1), ledger.all.events);
}

test "replace updates cumulative row totals without adding an event" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    const old = types.UsageEvent{ .agent = .opencode, .timestamp_ms = 1_000, .model = "gpt-5.4", .input_tokens = 10, .output_tokens = 20, .cwd = "/old" };
    const new = types.UsageEvent{ .agent = .opencode, .timestamp_ms = 2_000, .model = "gpt-5.4", .input_tokens = 15, .output_tokens = 30, .cwd = "/new" };
    try ledger.add(old, 0.1);
    try ledger.replace(old, 0.1, new, 0.2);
    try testing.expectEqual(@as(u64, 1), ledger.all.events);
    try testing.expectEqual(@as(u64, 45), ledger.all.totalTokens());
    try testing.expectApproxEqAbs(@as(f64, 0.2), ledger.all.cost_usd, 1e-12);
    try testing.expectEqual(@as(u64, 0), ledger.per_project.get("/old").?.events);
    try testing.expectEqual(@as(u64, 1), ledger.per_project.get("/new").?.events);
}

test "today respects the tz offset day boundary" {
    // 2026-07-09T02:00:00Z with UTC-5: locally still 2026-07-08.
    const t: i64 = 1_783_562_400_000;
    var ledger = Ledger.init(testing.allocator, -300);
    defer ledger.deinit();
    try ledger.add(mkEv(.claude, t, "m", 10), null);

    try testing.expectEqual(@as(u64, 10), ledger.today(t).totalTokens());
    // Same UTC instant bucketed with UTC tz would be a different local day
    // than six hours earlier.
    try testing.expect(dayKey(t, 0) != dayKey(t, -300));
}

test "dayKey boundaries" {
    try testing.expectEqual(@as(i64, 0), dayKey(0, 0));
    try testing.expectEqual(@as(i64, 0), dayKey(86_399_999, 0));
    try testing.expectEqual(@as(i64, 1), dayKey(86_400_000, 0));
    try testing.expectEqual(@as(i64, -1), dayKey(-1, 0));
}

test "hour buckets nest exactly inside local days, including half-hour zones" {
    // Local hours, not UTC hours: the nesting must hold for offsets that
    // are not whole hours, which is exactly where UTC hours break.
    for ([_]i32{ 0, -300, 330, 345, -570 }) |off| {
        for ([_]i64{ 0, 1, 3_599_999, 3_600_000, 86_399_999, 86_400_000, -1, 1_783_562_400_000 }) |ts| {
            try testing.expectEqual(dayKey(ts, off), dayOfHour(hourKey(ts, off)));
        }
    }

    try testing.expectEqual(@as(i64, 0), hourKey(0, 0));
    try testing.expectEqual(@as(i64, 0), hourKey(3_599_999, 0));
    try testing.expectEqual(@as(i64, 1), hourKey(3_600_000, 0));
    try testing.expectEqual(@as(i64, -1), hourKey(-1, 0));

    // hourStartMs inverts hourKey, and a bucket's start is the instant a
    // range query compares against.
    try testing.expectEqual(@as(i64, 3_600_000), hourStartMs(1, 0));
    try testing.expectEqual(@as(i64, 3_600_000 + 300 * 60_000), hourStartMs(1, -300));
    try testing.expectEqual(@as(i64, 1), hourKey(hourStartMs(1, 330), 330));
    try testing.expectEqual(@as(i64, 0), dayKey(dayStartMs(0, 345), 345));
}

test "hour bucketing across a day boundary and a DST-ish offset change" {
    var ledger = Ledger.init(testing.allocator, -300);
    defer ledger.deinit();

    // 23:30 then 00:30 local under UTC-5: adjacent hours, adjacent days.
    const late: i64 = 86_400_000 + 4 * 3_600_000 + 1_800_000; // local d0 23:30
    const early: i64 = late + 3_600_000; // local d1 00:30
    try ledger.add(mkEv(.claude, late, "m", 10), 0.1);
    try ledger.add(mkEv(.claude, early, "m", 20), 0.2);

    const h_late = hourKey(late, -300);
    try testing.expectEqual(h_late + 1, hourKey(early, -300));
    try testing.expectEqual(dayKey(late, -300) + 1, dayKey(early, -300));
    try testing.expectEqual(@as(u64, 10), ledger.per_hour.get(h_late).?.totals.totalTokens());
    try testing.expectEqual(@as(u64, 20), ledger.per_hour.get(h_late + 1).?.totals.totalTokens());
    // The per-agent split inside an hour is what a windowed AGENT SHARE reads.
    try testing.expectEqual(@as(u64, 10), ledger.per_hour.get(h_late).?.per_agent.get(.claude).totalTokens());
    try testing.expectEqual(@as(u64, 0), ledger.per_hour.get(h_late).?.per_agent.get(.codex).totalTokens());

    // Spring forward: the same instant files one bucket later, and events
    // recorded after the change use the new offset. Old buckets keep their
    // old key by design (documented on hourKey).
    try testing.expectEqual(hourKey(early, -300) + 1, hourKey(early, -240));
    const before = ledger.per_hour.count();
    ledger.tz_offset_min = -240;
    try ledger.add(mkEv(.claude, early, "m", 5), 0.05);
    try testing.expectEqual(before + 1, ledger.per_hour.count());
    try testing.expectEqual(@as(u64, 5), ledger.per_hour.get(hourKey(early, -240)).?.totals.totalTokens());
}

test "totalsInRange is half-open and agrees with the per_day sum" {
    var ledger = Ledger.init(testing.allocator, -300);
    defer ledger.deinit();

    const d0 = dayStartMs(20_000, -300);
    try ledger.add(mkEv(.claude, d0, "m", 10), 1.0); // first instant of d0
    try ledger.add(mkEv(.codex, d0 + 5 * 3_600_000, "m", 20), 2.0);
    try ledger.add(mkEv(.claude, d0 + 86_400_000, "m", 40), 4.0); // first instant of d1

    // A whole local day matches the per_day bucket exactly.
    const day0 = ledger.totalsInRange(d0, d0 + 86_400_000);
    try testing.expectEqual(@as(u64, 30), day0.totalTokens());
    try testing.expectEqual(ledger.per_day.get(20_000).?.totalTokens(), day0.totalTokens());
    try testing.expectApproxEqAbs(ledger.per_day.get(20_000).?.cost_usd, day0.cost_usd, 1e-9);
    try testing.expectEqual(@as(u64, 2), day0.events);

    // Half-open: `from` includes its bucket, `to` excludes it.
    try testing.expectEqual(@as(u64, 10), ledger.totalsInRange(d0, d0 + 1).totalTokens());
    try testing.expectEqual(@as(u64, 0), ledger.totalsInRange(d0 + 1, d0 + 3_600_000).totalTokens());
    try testing.expectEqual(@as(u64, 20), ledger.totalsInRange(d0 + 5 * 3_600_000, d0 + 6 * 3_600_000).totalTokens());
    // Empty and inverted windows are zero, not a wraparound.
    try testing.expectEqual(@as(u64, 0), ledger.totalsInRange(d0, d0).totalTokens());
    try testing.expectEqual(@as(u64, 0), ledger.totalsInRange(d0 + 86_400_000, d0).totalTokens());

    // Two days spanned == the manual sum over per_day.
    var manual: Totals = .{};
    for (ledger.per_day.values()) |totals| accumulate(&manual, totals);
    const both = ledger.totalsInRange(d0, d0 + 2 * 86_400_000);
    try testing.expectEqual(manual.totalTokens(), both.totalTokens());
    try testing.expectEqual(manual.events, both.events);

    // Per-agent scoping: the point of the whole exercise.
    try testing.expectEqual(@as(u64, 10), ledger.agentTotalsInRange(.claude, d0, d0 + 86_400_000).totalTokens());
    try testing.expectEqual(@as(u64, 20), ledger.agentTotalsInRange(.codex, d0, d0 + 86_400_000).totalTokens());
    const agents = ledger.agentsInRange(d0, d0 + 2 * 86_400_000);
    try testing.expectEqual(@as(u64, 50), agents.get(.claude).totalTokens());
    try testing.expectEqual(@as(u64, 20), agents.get(.codex).totalTokens());
    try testing.expectEqual(@as(u64, 0), agents.get(.opencode).events);
}

test "trailing buckets chart hours and days from one accessor" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    const now: i64 = 100 * 86_400_000 + 10 * 3_600_000; // day 100, 10:00 UTC
    try ledger.add(mkEv(.claude, now, "m", 10), 1.0);
    try ledger.add(mkEv(.claude, now - 2 * 3_600_000, "m", 20), 2.0);
    try ledger.add(mkEv(.claude, now - 3 * 86_400_000, "m", 40), 4.0);

    var hours: [4]Totals = @splat(.{});
    ledger.trailing(.hour, now, &hours);
    try testing.expectEqual(@as(u64, 20), hours[1].totalTokens()); // now - 2h
    try testing.expectEqual(@as(u64, 0), hours[2].totalTokens());
    try testing.expectEqual(@as(u64, 10), hours[3].totalTokens()); // current hour

    var days: [4]f64 = @splat(0);
    ledger.trailingCost(.day, now, &days);
    try testing.expectApproxEqAbs(@as(f64, 4.0), days[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), days[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), days[3], 1e-9);
    try testing.expectEqual(@as(u64, 10), ledger.thisHour(now).totalTokens());
}

test "per_session accumulates, tracks recency, and evicts at the cap" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    var ev = mkEv(.claude, 10_000, "m", 10);
    ev.session_id = "sess-a";
    try ledger.add(ev, 0.5);
    ev.timestamp_ms = 20_000;
    ev.output_tokens = 15;
    try ledger.add(ev, 0.25);

    const a = ledger.forSession("sess-a").?;
    try testing.expectEqual(@as(u64, 25), a.totals.totalTokens());
    try testing.expectEqual(@as(u64, 2), a.totals.events);
    try testing.expectApproxEqAbs(@as(f64, 0.75), a.totals.cost_usd, 1e-9);
    try testing.expectEqual(@as(i64, 10_000), a.first_seen_ms);
    try testing.expectEqual(@as(i64, 20_000), a.last_seen_ms);
    try testing.expectEqual(types.Agent.claude, a.agent);

    // An empty session_id must not create a shared phantom session.
    try ledger.add(mkEv(.goose, 30_000, "m", 5), 0.1);
    try testing.expectEqual(@as(usize, 1), ledger.per_session.count());

    // Fill past the cap; the map holds the ceiling and drops the oldest.
    var buf: [32]u8 = undefined;
    for (0..max_sessions + 50) |i| {
        var filler = mkEv(.codex, 100_000 + @as(i64, @intCast(i)) * 1_000, "m", 1);
        filler.session_id = try std.fmt.bufPrint(&buf, "fill-{d}", .{i});
        try ledger.add(filler, 0.01);
    }
    try testing.expectEqual(max_sessions, ledger.per_session.count());
    // sess-a was the least-recently-seen, so it is gone; the newest survive.
    try testing.expectEqual(@as(?SessionRollup, null), ledger.forSession("sess-a"));
    try testing.expect(ledger.forSession("fill-305") != null);
    // The oldest fillers are gone too, not just the pre-cap strays.
    try testing.expectEqual(@as(?SessionRollup, null), ledger.forSession("fill-0"));

    var top: [3]SessionRef = undefined;
    try testing.expectEqual(@as(usize, 3), ledger.sessionsByRecency(&top));
    try testing.expectEqualStrings("fill-305", top[0].id);
    try testing.expectEqualStrings("fill-304", top[1].id);
    try testing.expectEqualStrings("fill-303", top[2].id);
    try testing.expect(top[0].rollup.last_seen_ms > top[1].rollup.last_seen_ms);
}

test "hour retention bounds growth over months of data" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    // 60 days x 24 hours = 1440 candidate buckets, added oldest-first.
    for (0..60) |d| {
        for (0..24) |h| {
            const ts = (@as(i64, @intCast(d)) * 24 + @as(i64, @intCast(h))) * 3_600_000;
            try ledger.add(mkEv(.claude, ts, "m", 1), 0.001);
            try testing.expect(ledger.per_hour.count() <= max_hour_buckets);
        }
    }
    try testing.expectEqual(max_hour_buckets, ledger.per_hour.count());
    // per_day is the archive and keeps every day.
    try testing.expectEqual(@as(usize, 60), ledger.per_day.count());
    try testing.expectEqual(@as(u64, 1440), ledger.all.events);

    // The retained window is the newest one, and it is contiguous.
    const newest = ledger.newest_hour;
    try testing.expectEqual(@as(i64, 59 * 24 + 23), newest);
    try testing.expect(ledger.per_hour.get(newest) != null);
    try testing.expectEqual(@as(?HourBucket, null), ledger.per_hour.get(newest - @as(i64, @intCast(max_hour_buckets))));
    try testing.expect(ledger.per_hour.get(newest - @as(i64, @intCast(max_hour_buckets)) + 1) != null);
}

test "replace corrects the hour and session dimensions too" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    const old = types.UsageEvent{ .agent = .opencode, .timestamp_ms = 1_000, .model = "gpt-5.4", .output_tokens = 20, .session_id = "s1" };
    const new = types.UsageEvent{ .agent = .opencode, .timestamp_ms = 1_000, .model = "gpt-5.4", .output_tokens = 35, .session_id = "s1" };
    try ledger.add(old, 0.1);
    try ledger.replace(old, 0.1, new, 0.2);

    try testing.expectEqual(@as(u64, 35), ledger.per_hour.get(0).?.totals.totalTokens());
    try testing.expectEqual(@as(u64, 1), ledger.per_hour.get(0).?.totals.events);
    try testing.expectEqual(@as(u64, 35), ledger.per_hour.get(0).?.per_agent.get(.opencode).totalTokens());
    try testing.expectEqual(@as(u64, 35), ledger.forSession("s1").?.totals.totalTokens());
    try testing.expectEqual(@as(u64, 1), ledger.forSession("s1").?.totals.events);
}

test "putHour and putSession seed restored state without unbounded growth" {
    var ledger = Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    var bucket: HourBucket = .{};
    bucket.totals = .{ .output_tokens = 7, .cost_usd = 0.7, .events = 1 };
    bucket.per_agent.getPtr(.gemini).* = bucket.totals;
    try ledger.putHour(5, bucket);
    try testing.expectEqual(@as(u64, 7), ledger.thisHour(5 * 3_600_000).totalTokens());
    try testing.expectEqual(@as(u64, 7), ledger.agentTotalsInRange(.gemini, 5 * 3_600_000, 6 * 3_600_000).totalTokens());

    var buf: [32]u8 = undefined;
    for (0..max_sessions + 10) |i| {
        const id = try std.fmt.bufPrint(&buf, "r-{d}", .{i});
        try ledger.putSession(id, .{ .agent = .kilo, .last_seen_ms = @intCast(i) });
    }
    try testing.expectEqual(max_sessions, ledger.per_session.count());
}
