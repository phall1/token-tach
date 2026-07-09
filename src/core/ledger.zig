//! Ledger: aggregation over the deduped UsageEvent stream.
//! Tailers own dedup; the ledger owns rollups — running totals per day,
//! model, agent, and project (cwd) that the tray, popover, and dashboard
//! read directly. Costs are priced at add time by the caller (pricing.Db)
//! so the ledger stays import-light and trivially testable.

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

pub const Ledger = struct {
    allocator: std.mem.Allocator,
    all: Totals = .{},
    per_agent: std.EnumArray(types.Agent, Totals) = .initFill(.{}),
    per_day: std.AutoArrayHashMapUnmanaged(i64, Totals) = .empty,
    per_model: std.StringArrayHashMapUnmanaged(Totals) = .empty,
    per_project: std.StringArrayHashMapUnmanaged(Totals) = .empty,
    tz_offset_min: i32,

    pub fn init(allocator: std.mem.Allocator, tz_offset_min: i32) Ledger {
        return .{ .allocator = allocator, .tz_offset_min = tz_offset_min };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.per_model.keys()) |k| self.allocator.free(k);
        for (self.per_project.keys()) |k| self.allocator.free(k);
        self.per_day.deinit(self.allocator);
        self.per_model.deinit(self.allocator);
        self.per_project.deinit(self.allocator);
    }

    /// Record one deduped event with its (already computed) cost.
    pub fn add(self: *Ledger, ev: types.UsageEvent, cost: ?f64) !void {
        self.all.add(ev, cost);
        self.per_agent.getPtr(ev.agent).add(ev, cost);

        const day = try self.per_day.getOrPutValue(self.allocator, dayKey(ev.timestamp_ms, self.tz_offset_min), .{});
        day.value_ptr.add(ev, cost);

        try addKeyed(self.allocator, &self.per_model, ev.model, ev, cost);
        if (ev.cwd.len > 0) try addKeyed(self.allocator, &self.per_project, ev.cwd, ev, cost);
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

    pub fn today(self: *const Ledger, now_ms: i64) Totals {
        return self.per_day.get(dayKey(now_ms, self.tz_offset_min)) orelse .{};
    }

    pub fn forAgent(self: *const Ledger, agent: types.Agent) Totals {
        return self.per_agent.get(agent);
    }
};

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
