//! The popover's interface. No SDK, filesystem, credentials, or engine model.
//! Harness usage and account allowances are adjacent facts, never an inferred
//! billing join. All freshness policy lives here, shared by tray and panel.
const std = @import("std");
const types = @import("core/types.zig");
const config = @import("core/config.zig");
const summary = @import("core/usage_summary.zig");
const sessions = @import("core/sessions.zig");

pub const max_sources = std.enums.values(types.Agent).len;
pub const stale_after_ms: i64 = 5 * 60_000;
pub const Page = enum { overview, sources, sessions, days };
pub const Provider = enum { anthropic, openai };

pub const Account = struct {
    provider: Provider,
    /// Null means the observation cannot identify an account. Never substitute
    /// a harness name or model vendor for an account ID.
    id: ?[]const u8 = null,
};

pub const Freshness = enum { fresh, stale, reset_passed };

pub fn freshness(read_ms: i64, reset_ms: i64, now_ms: i64) Freshness {
    if (reset_ms > 0 and reset_ms <= now_ms) return .reset_passed;
    if (read_ms <= 0 or read_ms > now_ms) return .stale;
    if (now_ms - read_ms > stale_after_ms) return .stale;
    return .fresh;
}

pub fn validPercent(percent: f64) bool {
    return std.math.isFinite(percent) and percent >= 0 and percent <= 100;
}

pub const Allowance = struct {
    account: Account,
    plan: []const u8 = "",
    provenance: []const u8,
    read_ms: i64,
    windows: []const types.LimitWindow,
};

pub const Source = struct {
    harness: types.Agent,
    name: []const u8,
    allowance: ?Allowance = null,
    help: []const u8 = "",
    usage: *const summary.Source,
};

pub const Input = struct {
    now_ms: i64,
    tz_offset_min: i32 = 0,
    ready: bool = false,
    scanning: bool = false,
    enabled: config.Sources = .{},
    recorded: std.EnumSet(types.Agent) = .{},
    claude: ?types.LimitSnapshot = null,
    codex: ?types.LimitSnapshot = null,
    claude_oauth: bool = false,
    claude_inflight: bool = false,
    claude_error: []const u8 = "",
    history_error: bool = false,
    history_blocked: bool = false,
    usage: *const summary.Snapshot,
    roster: *const sessions.Roster,
    selected: ?types.Agent = null,
    page: Page = .overview,
};

pub const Snapshot = struct {
    enabled: config.Sources,
    now_ms: i64,
    tz_offset_min: i32,
    ready: bool,
    scanning: bool,
    history_error: bool,
    history_blocked: bool,
    usage: *const summary.Snapshot,
    roster: *const sessions.Roster,
    page: Page,
    sources: [max_sources]Source = undefined,
    len: usize = 0,
    selected_index: usize = 0,

    pub fn selected(self: *const Snapshot) ?*const Source {
        if (self.len == 0) return null;
        return &self.sources[self.selected_index];
    }
};

pub fn snapshot(input: Input) Snapshot {
    var result: Snapshot = .{
        .enabled = input.enabled,
        .now_ms = input.now_ms,
        .tz_offset_min = input.tz_offset_min,
        .ready = input.ready,
        .scanning = input.scanning,
        .history_error = input.history_error,
        .history_blocked = input.history_blocked,
        .usage = input.usage,
        .roster = input.roster,
        .page = input.page,
    };
    for (std.enums.values(types.Agent)) |agent| {
        if (!input.enabled.enabled(agent)) continue;
        const allowance = allowanceFor(input, agent);
        if (!input.recorded.contains(agent) and input.usage.sources.getPtrConst(agent).total.events == 0 and allowance == null) continue;
        result.sources[result.len] = .{
            .harness = agent,
            .name = sourceName(agent),
            .allowance = allowance,
            .help = sourceHelp(input, agent),
            .usage = input.usage.sources.getPtrConst(agent),
        };
        result.len += 1;
    }
    result.selected_index = selection(&result, input.selected);
    return result;
}

fn selection(result: *const Snapshot, requested: ?types.Agent) usize {
    for (result.sources[0..result.len], 0..) |source, i| {
        if (source.harness == requested) return i;
    }
    for (result.sources[0..result.len], 0..) |source, i| {
        if (source.allowance != null) return i;
    }
    return 0;
}

fn allowanceFor(input: Input, agent: types.Agent) ?Allowance {
    return switch (agent) {
        .claude => if (input.claude_oauth) fromLimits(input.claude, .anthropic, "Anthropic / current sign-in") else null,
        .codex => fromLimits(input.codex, .openai, "OpenAI / observed in Codex logs"),
        else => null,
    };
}

fn fromLimits(maybe: ?types.LimitSnapshot, provider: Provider, provenance: []const u8) ?Allowance {
    const limits = maybe orelse return null;
    if (limits.windows.len == 0) return null;
    return .{ .account = .{ .provider = provider }, .plan = limits.plan, .provenance = provenance, .read_ms = limits.read_at_ms, .windows = limits.windows };
}

fn sourceHelp(input: Input, agent: types.Agent) []const u8 {
    if (agent == .claude) return claudeHelp(input);
    if (agent == .codex) return "Limits are the last observation in local Codex logs.";
    return "Local usage only. Subscription attribution is unknown.";
}

fn claudeHelp(input: Input) []const u8 {
    if (!input.claude_oauth) return "Enable claude-oauth in Settings to read allowance.";
    if (input.claude_error.len > 0) return input.claude_error;
    if (input.claude_inflight) return "Checking allowance...";
    if (input.claude == null) return "Allowance unavailable. Sign in with Claude Code.";
    return "Allowance covers the signed-in account; usage below is local.";
}

pub fn sourceName(agent: types.Agent) []const u8 {
    const names = [_][]const u8{ "Claude Code", "Codex", "OpenCode", "Pi", "Gemini CLI", "Qwen Code", "Kimi CLI", "Goose", "Kilo Code", "Cline", "Roo Code", "Copilot", "Continue", "Droid" };
    return names[@intFromEnum(agent)];
}

pub fn windowName(kind: types.LimitWindow.Kind) []const u8 {
    return switch (kind) {
        .five_hour => "5-hour window",
        .weekly => "Weekly",
        .weekly_opus => "Weekly / Opus",
        .weekly_sonnet => "Weekly / Sonnet",
        .monthly => "Monthly",
    };
}

pub const Glance = struct { name: []const u8, percent: f64 };

pub fn glance(input: Input) ?Glance {
    const view = snapshot(input);
    var best: ?Glance = null;
    for (view.sources[0..view.len]) |source| {
        const allowance = source.allowance orelse continue;
        for (allowance.windows) |window| {
            if (!validPercent(window.used_percent)) continue;
            if (freshness(allowance.read_ms, window.resets_at_ms, input.now_ms) != .fresh) continue;
            if (best == null or window.used_percent > best.?.percent)
                best = .{ .name = source.name, .percent = window.used_percent };
        }
    }
    return best;
}

/// Human labels for observational liveness; the underlying state machine stays
/// compatible with existing CLI output and roster retention.
pub fn activityLabel(session: *const sessions.Session, now_ms: i64) []const u8 {
    if (session.activityAt(now_ms) == .done) return "No recent activity";
    if (session.activityAt(now_ms) == .idle) return "Quiet";
    return if (session.mid_turn) "Possibly working" else "Recently active";
}

pub fn sessionRows(snapshot_value: *const Snapshot, out: []*const sessions.Session) []*const sessions.Session {
    var n: usize = 0;
    for (snapshot_value.roster.sessions[0..snapshot_value.roster.len]) |*session| {
        if (n == out.len) break;
        if (!snapshot_value.enabled.enabled(session.agent)) continue;
        out[n] = session;
        n += 1;
    }
    std.mem.sort(*const sessions.Session, out[0..n], snapshot_value.now_ms, sessionLess);
    return out[0..n];
}

fn sessionLess(now_ms: i64, a: *const sessions.Session, b: *const sessions.Session) bool {
    const ar = a.activityAt(now_ms).rank();
    const br = b.activityAt(now_ms).rank();
    if (ar != br) return ar < br;
    return a.lastActivityMs() > b.lastActivityMs();
}

test "freshness rejects expired resets and future clocks" {
    const t = std.testing;
    try t.expectEqual(Freshness.fresh, freshness(1_000, 900_000, 301_000));
    try t.expectEqual(Freshness.stale, freshness(1_000, 900_000, 301_001));
    try t.expectEqual(Freshness.stale, freshness(400_000, 900_000, 301_000));
    try t.expectEqual(Freshness.reset_passed, freshness(300_000, 301_000, 301_000));
    try t.expect(!validPercent(std.math.nan(f64)));
}

test "selection is stable and local harness usage never claims an account" {
    const t = std.testing;
    const usage: summary.Snapshot = .{};
    const roster: sessions.Roster = .{};
    var input: Input = .{ .now_ms = 100, .usage = &usage, .roster = &roster, .selected = .opencode };
    input.recorded.insert(.opencode);
    input.recorded.insert(.claude);
    var result = snapshot(input);
    try t.expectEqual(types.Agent.opencode, result.selected().?.harness);
    try t.expect(result.selected().?.allowance == null);
    input.enabled = config.Sources.none;
    input.enabled.enable(.opencode);
    result = snapshot(input);
    try t.expectEqual(@as(usize, 1), result.len);
    try t.expectEqual(types.Agent.opencode, result.selected().?.harness);
}
