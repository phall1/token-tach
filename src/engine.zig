//! The TEA loop: Model, Msg, boot, update. Bridges the UI-free core
//! (tailers, ledger, pricing, prediction, oauth) to the Native SDK
//! effects channel (timers, fetch, spawn).
//!
//! Cadence: a repeating 2 s sweep timer tails both agents' JSONL trees
//! and re-derives every display string; a 30 s gate timer fires OAuth
//! polls when `claude-oauth = true` and the backoff window allows.

const std = @import("std");
const native_sdk = @import("native_sdk");

const types = @import("core/types.zig");
const config = @import("core/config.zig");
const claude = @import("core/claude.zig");
const codex = @import("core/codex.zig");
const pricing = @import("core/pricing.zig");
const ledger_mod = @import("core/ledger.zig");
const predict = @import("core/predict.zig");
const oauth = @import("core/oauth.zig");
const keychain = @import("core/keychain.zig");
const trayfmt = @import("core/trayfmt.zig");

pub const Effects = native_sdk.Effects(Msg);

pub const sweep_timer_key: u64 = 1;
pub const oauth_gate_timer_key: u64 = 2;
pub const oauth_fetch_key: u64 = 3;
pub const tz_spawn_key: u64 = 4;
pub const creds_spawn_key: u64 = 5;

pub const sweep_interval_ms: u32 = 2_000;
pub const oauth_gate_interval_ms: u32 = 30_000;

pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,
    oauth_tick: native_sdk.EffectTimer,
    creds_done: native_sdk.EffectExit,
    oauth_response: native_sdk.EffectResponse,
    tz_done: native_sdk.EffectExit,
};

const text_buf_len = 192;

pub const Model = struct {
    allocator: std.mem.Allocator = undefined,
    ready: bool = false,

    cfg: config.Config = .{},

    claude_tailer: claude.Tailer = undefined,
    codex_tailer: codex.Tailer = undefined,
    claude_roots: []const []const u8 = &.{},
    codex_roots: []const []const u8 = &.{},

    prices: pricing.Db = undefined,
    ledger: ledger_mod.Ledger = undefined,
    burn: predict.BurnRate = .{},
    walls: predict.WallTracker = .{},

    /// Latest limit snapshots for display (windows slices owned by us).
    claude_limits: ?types.LimitSnapshot = null,
    codex_limits: ?types.LimitSnapshot = null,

    // OAuth poller state.
    oauth_backoff: oauth.Backoff = .{},
    oauth_next_ms: i64 = 0,
    oauth_last_success_ms: i64 = 0,
    oauth_inflight: bool = false,

    /// Journaled wall clock, refreshed on every tick — the only clock
    /// the render path may read.
    now_ms: i64 = 0,
    tz_offset_min: i32 = 0,
    first_sweep_done: bool = false,

    /// Plan tier from the keychain credentials ("max"/"pro"), locally
    /// known without any API call.
    claude_plan: []const u8 = "",
    claude_plan_buf: [32]u8 = undefined,

    // Display strings bound by app.native — regenerated each sweep, and
    // pointing into the fixed buffers below (never into stack copies).
    glance_text: []const u8 = "",
    claude_text: []const u8 = "",
    codex_text: []const u8 = "",
    today_text: []const u8 = "",
    status_text: []const u8 = "starting…",

    glance_buf: [text_buf_len]u8 = undefined,
    claude_buf: [text_buf_len]u8 = undefined,
    codex_buf: [text_buf_len]u8 = undefined,
    today_buf: [text_buf_len]u8 = undefined,
    status_buf: [text_buf_len]u8 = undefined,

    // Instrument display state (pure display, refreshed each sweep):
    // the tach needs a stable scale (a ratcheted, slowly decaying burn
    // peak) and the previous/current needle pose so the view's render
    // animation can sweep between them instead of snapping.
    gauge_peak_tpm: f64 = 0,
    needle_from_deg: f32 = -half_sweep_deg,
    needle_to_deg: f32 = -half_sweep_deg,
};

/// The tach sweeps ±120° around 12 o'clock (a classic 240° dial).
pub const half_sweep_deg: f32 = 120;

/// Ratchet decay per 2 s sweep: the peak halves in roughly 30 minutes,
/// so the dial re-ranges down slowly instead of flapping.
const peak_decay_per_sweep: f64 = 0.99923;

/// Smallest 1-2-5 ladder scale (tokens/min) that clears the recent
/// peak with ~15% headroom; never below 10k/m.
pub fn gaugeScaleTpm(peak_tpm: f64) f64 {
    const target = @max(peak_tpm * 1.15, 10_000);
    var decade: f64 = 10_000;
    while (decade < target) {
        if (decade * 2 >= target) return decade * 2;
        if (decade * 5 >= target) return decade * 5;
        decade *= 10;
    }
    return decade;
}

/// Needle pose (degrees clockwise from 12 o'clock) for a burn rate on
/// the current scale.
pub fn needleDeg(tpm: f64, scale_tpm: f64) f32 {
    const frac = std.math.clamp(tpm / @max(scale_tpm, 1), 0, 1);
    return @floatCast(-half_sweep_deg + 2 * half_sweep_deg * frac);
}

/// Redline truth: a wall projected within 45 minutes, or any limit
/// window past 80% utilization.
pub fn dangerState(model: *const Model) bool {
    if (model.walls.maxUtilization()) |hot| {
        if (hot.used_percent > 80) return true;
    }
    if (model.walls.nearestWall(model.now_ms)) |wall| {
        if (wall.at_ms - model.now_ms < 45 * 60_000) return true;
    }
    return false;
}

/// Environment facts setup needs — extracted from the runner's
/// `init.environ_map` by main (keeps setup unit-testable).
pub const Env = struct {
    home: []const u8 = "",
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
};

/// Build the engine state: config, roots, tailers, pricing. Called once
/// on the heap-allocated model before the runtime starts.
pub fn setup(model: *Model, allocator: std.mem.Allocator, env: Env) !void {
    model.allocator = allocator;

    const home = env.home;

    // Config: absent file or bad lines never block startup.
    if (config.defaultPath(allocator, home)) |path| {
        defer allocator.free(path);
        if (config.load(allocator, path) catch null) |result| {
            model.cfg = result.config;
        }
    } else |_| {}

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    model.claude_roots = if (model.cfg.claude_config_dirs.len > 0)
        try appendProjects(allocator, model.cfg.claude_config_dirs)
    else
        try claude.discoverRoots(allocator, io, env.claude_config_dir, home);

    const codex_env: ?[]const u8 = if (model.cfg.codex_home.len > 0)
        model.cfg.codex_home
    else
        env.codex_home;
    model.codex_roots = try codex.sessionsDirs(allocator, codex_env, home);

    model.claude_tailer = claude.Tailer.init(allocator);
    model.codex_tailer = codex.Tailer.init(allocator);
    model.prices = try pricing.Db.init(allocator);
    model.ledger = ledger_mod.Ledger.init(allocator, 0);
    model.ready = true;
}

/// config `claude-config-dir` entries are config roots; the transcripts
/// live under `<root>/projects`.
fn appendProjects(allocator: std.mem.Allocator, dirs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    for (dirs) |d| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/projects", .{d}));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn boot(model: *Model, fx: *Effects) void {
    fx.startTimer(.{
        .key = sweep_timer_key,
        .interval_ms = sweep_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    fx.startTimer(.{
        .key = oauth_gate_timer_key,
        .interval_ms = oauth_gate_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.oauth_tick),
    });
    fx.spawn(.{
        .key = tz_spawn_key,
        .argv = &.{ "date", "+%z" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.tz_done),
    });
    model.now_ms = fx.wallMs();
    refreshDisplay(model);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => {
            model.now_ms = fx.wallMs();
            sweepOnce(model);
            // First OAuth poll shouldn't wait for the 30 s gate.
            if (!model.first_sweep_done) maybeOauthPoll(model, fx);
            model.first_sweep_done = true;
        },
        .oauth_tick => {
            model.now_ms = fx.wallMs();
            maybeOauthPoll(model, fx);
        },
        .creds_done => |exit| {
            model.now_ms = fx.wallMs();
            handleCreds(model, exit, fx);
        },
        .oauth_response => |resp| {
            model.now_ms = fx.wallMs();
            handleOauthResponse(model, resp);
            refreshDisplay(model);
        },
        .tz_done => |exit| {
            if (exit.code == 0) {
                if (parseTzOffsetMin(exit.output)) |offset| {
                    model.tz_offset_min = offset;
                    model.ledger.tz_offset_min = offset;
                }
            }
        },
    }
}

/// "+0530" / "-0700" (optionally newline-terminated) -> minutes east.
pub fn parseTzOffsetMin(raw: []const u8) ?i32 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len != 5 or (s[0] != '+' and s[0] != '-')) return null;
    const hours = std.fmt.parseInt(i32, s[1..3], 10) catch return null;
    const mins = std.fmt.parseInt(i32, s[3..5], 10) catch return null;
    if (hours > 14 or mins > 59) return null;
    const total = hours * 60 + mins;
    return if (s[0] == '-') -total else total;
}

// ------------------------------------------------------------------ sweep

fn sweepOnce(model: *Model) void {
    if (!model.ready) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (model.cfg.sources.claude) {
        var sink = claude.ListSink.init(model.allocator);
        defer sink.deinit();
        model.claude_tailer.sweep(arena, io, model.claude_roots, sink.sink()) catch |err| {
            std.log.warn("claude sweep failed: {s}", .{@errorName(err)});
        };
        for (sink.events.items) |ev| ingest(model, ev);
    }

    if (model.cfg.sources.codex) {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        defer events.deinit(arena);
        model.codex_tailer.sweep(io, arena, model.codex_roots, &events) catch |err| {
            std.log.warn("codex sweep failed: {s}", .{@errorName(err)});
        };
        for (events.items) |ev| ingest(model, ev);

        if (codex.latestLimits(arena, io, model.codex_roots) catch null) |snap| {
            model.walls.observe(snap);
            storeLimits(model, &model.codex_limits, snap);
        }
    }

    refreshDisplay(model);
}

fn ingest(model: *Model, ev: types.UsageEvent) void {
    const cost = model.prices.costOf(ev);
    model.ledger.add(ev, cost) catch return;
    model.burn.addTokens(ev.timestamp_ms, predict.limitWeightedTokens(ev));
}

/// Keep our own copy of a limit snapshot (arena-born snapshots die with
/// the sweep); frees the previous copy.
fn storeLimits(model: *Model, slot: *?types.LimitSnapshot, snap: types.LimitSnapshot) void {
    const windows = model.allocator.dupe(types.LimitWindow, snap.windows) catch return;
    const plan = model.allocator.dupe(u8, snap.plan) catch {
        model.allocator.free(windows);
        return;
    };
    if (slot.*) |old| {
        model.allocator.free(old.windows);
        model.allocator.free(old.plan);
    }
    slot.* = .{ .agent = snap.agent, .read_at_ms = snap.read_at_ms, .plan = plan, .windows = windows };
}

// ------------------------------------------------------------------ oauth

/// Kick a poll: acquire credentials ASYNCHRONOUSLY via Apple's
/// security(1) through the effects channel. A synchronous SecItem read
/// (keychain.zig) blocks the whole dispatch loop on macOS's keychain
/// consent dialog for unsigned binaries — the frozen-tray bug. The
/// spawn keeps any consent prompt in the child; keychain.zig remains
/// the path for signed/bundled builds whose ACL entry sticks.
fn maybeOauthPoll(model: *Model, fx: *Effects) void {
    if (!model.cfg.claude_oauth) return;
    if (model.oauth_inflight or model.now_ms < model.oauth_next_ms) return;

    model.oauth_inflight = true;
    fx.spawn(.{
        .key = creds_spawn_key,
        .argv = &.{ "security", "find-generic-password", "-s", keychain.claude_service, "-w" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.creds_done),
    });
}

fn handleCreds(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    if (exit.code != 0) {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + oauth.poll_interval_ms;
        setStatus(model, "keychain read failed (security exit {d})", .{exit.code});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const creds = oauth.parseCredentials(arena_state.allocator(), std.mem.trim(u8, exit.output, " \t\r\n")) catch {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + oauth.poll_interval_ms;
        setStatus(model, "unreadable Claude credentials payload", .{});
        return;
    };

    if (creds.subscription_type.len > 0 and creds.subscription_type.len <= model.claude_plan_buf.len) {
        @memcpy(model.claude_plan_buf[0..creds.subscription_type.len], creds.subscription_type);
        model.claude_plan = model.claude_plan_buf[0..creds.subscription_type.len];
    }

    var auth_buf: [2048]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{creds.access_token}) catch {
        model.oauth_inflight = false;
        return;
    };

    fx.fetch(.{
        .key = oauth_fetch_key,
        .url = oauth.endpoint_url,
        .headers = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "anthropic-beta", .value = oauth.beta_header },
            .{ .name = "User-Agent", .value = oauth.user_agent },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.oauth_response),
    });
}

fn handleOauthResponse(model: *Model, resp: native_sdk.EffectResponse) void {
    model.oauth_inflight = false;
    if (resp.outcome == .ok and resp.status == 200) {
        const plan = model.claude_plan;
        var arena_state = std.heap.ArenaAllocator.init(model.allocator);
        defer arena_state.deinit();
        const snap = oauth.parseUsageResponse(arena_state.allocator(), resp.body, model.now_ms, plan) catch {
            model.oauth_backoff.onFailure();
            model.oauth_next_ms = model.now_ms + model.oauth_backoff.delayMs();
            setStatus(model, "unparseable usage response", .{});
            return;
        };
        model.walls.observe(snap);
        storeLimits(model, &model.claude_limits, snap);
        model.oauth_backoff.onSuccess();
        model.oauth_last_success_ms = model.now_ms;
        model.oauth_next_ms = model.now_ms + oauth.poll_interval_ms;
    } else {
        model.oauth_backoff.onFailure();
        model.oauth_next_ms = model.now_ms + model.oauth_backoff.delayMs();
        setStatus(model, "usage endpoint: status {d} ({t})", .{ resp.status, resp.outcome });
    }
}

// ---------------------------------------------------------------- display

fn setStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
    model.status_text = std.fmt.bufPrint(&model.status_buf, fmt, args) catch model.status_text;
}

pub fn glanceState(model: *const Model) trayfmt.GlanceState {
    const today = model.ledger.today(model.now_ms);
    const wall = model.walls.nearestWall(model.now_ms);
    const hot = model.walls.maxUtilization();
    return .{
        .now_ms = model.now_ms,
        .tz_offset_min = model.tz_offset_min,
        .burn_tokens_per_min = model.burn.tokensPerMin(model.now_ms),
        .idle = model.burn.isIdle(model.now_ms),
        .wall_at_ms = if (wall) |w| w.at_ms else null,
        .hot_percent = if (hot) |h| h.used_percent else null,
        .next_reset_ms = nextReset(model),
        .today_tokens = today.totalTokens(),
        .today_cost_usd = today.cost_usd,
    };
}

fn nextReset(model: *const Model) ?i64 {
    var best: ?i64 = null;
    inline for (.{ model.claude_limits, model.codex_limits }) |maybe| {
        if (maybe) |snap| {
            for (snap.windows) |w| {
                if (w.resets_at_ms > model.now_ms and (best == null or w.resets_at_ms < best.?)) {
                    best = w.resets_at_ms;
                }
            }
        }
    }
    return best;
}

fn refreshDisplay(model: *Model) void {
    // Instrument state first: ratchet the peak, re-range the dial,
    // journal the needle sweep (from = the pose the user last saw).
    const tpm = model.burn.tokensPerMin(model.now_ms);
    model.gauge_peak_tpm = @max(tpm, model.gauge_peak_tpm * peak_decay_per_sweep);
    model.needle_from_deg = model.needle_to_deg;
    model.needle_to_deg = needleDeg(tpm, gaugeScaleTpm(model.gauge_peak_tpm));

    model.glance_text = trayfmt.render(&model.glance_buf, model.cfg.tray_format, glanceState(model));
    model.claude_text = agentLine(&model.claude_buf, model, .claude, model.claude_limits);
    model.codex_text = agentLine(&model.codex_buf, model, .codex, model.codex_limits);

    const today = model.ledger.today(model.now_ms);
    {
        var w = std.Io.Writer.fixed(&model.today_buf);
        w.writeAll("today ") catch {};
        trayfmt.writeCost(&w, today.cost_usd) catch {};
        w.writeAll(" · ") catch {};
        trayfmt.writeHumanTokens(&w, today.totalTokens()) catch {};
        w.writeAll(" tok") catch {};
        model.today_text = w.buffered();
    }
    if (model.ready and model.status_text.ptr == &model.status_buf or model.status_text.len == 0 or std.mem.eql(u8, model.status_text, "starting…")) {
        setStatus(model, "{d} events · {d} models priced", .{ model.ledger.all.events, model.ledger.per_model.count() });
    }
}

fn agentLine(buf: []u8, model: *const Model, agent: types.Agent, limits: ?types.LimitSnapshot) []const u8 {
    const totals = model.ledger.forAgent(agent);
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(agent.label()) catch {};
    w.writeAll("  ") catch {};
    trayfmt.writeHumanTokens(&w, totals.totalTokens()) catch {};
    w.writeAll(" tok · ") catch {};
    trayfmt.writeCost(&w, totals.cost_usd) catch {};
    if (limits) |snap| {
        for (snap.windows) |win| {
            const label: []const u8 = switch (win.kind) {
                .five_hour => " · 5h ",
                .weekly => " · wk ",
                .weekly_opus => " · opus ",
                .weekly_sonnet => " · sonnet ",
                .monthly => " · mo ",
            };
            w.writeAll(label) catch {};
            w.printInt(@as(u64, @intFromFloat(std.math.clamp(win.used_percent, 0, 100))), 10, .lower, .{}) catch {};
            w.writeByte('%') catch {};
        }
        if (snap.plan.len > 0) {
            w.writeAll(" · ") catch {};
            w.writeAll(snap.plan) catch {};
        }
    }
    return w.buffered();
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "tz offset parsing" {
    try testing.expectEqual(@as(i32, 330), parseTzOffsetMin("+0530\n").?);
    try testing.expectEqual(@as(i32, -420), parseTzOffsetMin("-0700").?);
    try testing.expectEqual(@as(i32, 0), parseTzOffsetMin("+0000").?);
    try testing.expectEqual(@as(?i32, null), parseTzOffsetMin("UTC"));
    try testing.expectEqual(@as(?i32, null), parseTzOffsetMin("+9930"));
}

test "oauth response drives backoff and snapshot state" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    defer if (model.claude_limits) |l| {
        testing.allocator.free(l.windows);
        testing.allocator.free(l.plan);
    };
    model.now_ms = 1_000_000;
    model.oauth_inflight = true;

    handleOauthResponse(&model, .{
        .key = oauth_fetch_key,
        .outcome = .ok,
        .status = 200,
        .body =
        \\{"five_hour":{"utilization":42.0,"resets_at":"2026-07-09T12:00:00Z"}}
        ,
    });
    try testing.expect(!model.oauth_inflight);
    try testing.expectEqual(@as(usize, 1), model.claude_limits.?.windows.len);
    try testing.expectEqual(model.now_ms + oauth.poll_interval_ms, model.oauth_next_ms);

    // A 429 backs off beyond the normal cadence.
    model.oauth_inflight = true;
    handleOauthResponse(&model, .{ .key = oauth_fetch_key, .outcome = .ok, .status = 429 });
    try testing.expect(model.oauth_next_ms >= model.now_ms + 180_000);
    try testing.expectEqual(@as(usize, 1), model.claude_limits.?.windows.len);
}

test "glance state reflects ledger and burn" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    model.now_ms = 10 * 60_000;

    try model.ledger.add(.{
        .agent = .claude,
        .timestamp_ms = model.now_ms - 60_000,
        .model = "claude-fable-5",
        .output_tokens = 5000,
    }, 1.25);
    model.burn.addTokens(model.now_ms - 60_000, 5000);

    const glance = glanceState(&model);
    try testing.expect(!glance.idle);
    try testing.expectEqual(@as(u64, 5000), glance.today_tokens);
    try testing.expectEqual(@as(f64, 1.25), glance.today_cost_usd);
    try testing.expect(glance.burn_tokens_per_min > 0);
}
