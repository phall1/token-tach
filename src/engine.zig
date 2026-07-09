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
pub const catchup_timer_key: u64 = 6;

pub const sweep_interval_ms: u32 = 2_000;
pub const oauth_gate_interval_ms: u32 = 30_000;
/// Historical catch-up cadence: fast enough to feel instant, spaced
/// enough that render frames land between chunks.
pub const catchup_interval_ms: u32 = 30;
/// Per-chunk byte budget for catch-up file parsing (~a few ms of work).
pub const catchup_chunk_bytes: u64 = 3 * 1024 * 1024;

pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,
    catchup_tick: native_sdk.EffectTimer,
    oauth_tick: native_sdk.EffectTimer,
    creds_done: native_sdk.EffectExit,
    oauth_response: native_sdk.EffectResponse,
    tz_done: native_sdk.EffectExit,
};

/// One queued history file awaiting its catch-up parse.
pub const CatchupFile = struct {
    agent: types.Agent,
    path: []const u8,
    size: u64,
};

const text_buf_len = 192;

pub const Model = struct {
    allocator: std.mem.Allocator = undefined,
    ready: bool = false,

    cfg: config.Config = .{},
    /// Config live-reload state: the resolved config path (owned), the
    /// mtime of the last text we parsed, and the arena that owns every
    /// slice inside `cfg`. A reload builds a fresh arena, swaps `cfg`,
    /// then frees the old one — nothing else may alias config strings.
    config_path: []const u8 = "",
    config_mtime_ns: ?i128 = null,
    cfg_arena: ?std.heap.ArenaAllocator = null,

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

    // Historical catch-up: the file queue boot enumerated, chewed through
    // in byte-budgeted chunks on a fast timer so the dispatch loop (and
    // the window) never freezes behind months of JSONL.
    catchup_queue: []CatchupFile = &.{},
    catchup_next: usize = 0,
    catchup_active: bool = false,
    catchup_started_ms: i64 = 0,

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

    /// An error status stays visible until the failing path succeeds;
    /// the routine "N events" line never overwrites it.
    status_error: bool = false,

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

/// Minutes since the last successful Claude OAuth poll, once that
/// reading has gone stale (older than `oauth.stale_after_ms`). Null
/// while fresh, before the first success, or when there is no snapshot
/// to be stale about. Note: deliberately NOT gated on
/// `cfg.claude_oauth` — when live-reload disables polling we keep the
/// last snapshot, and this tag is what keeps it honest.
pub fn oauthStaleMin(model: *const Model) ?u64 {
    if (model.claude_limits == null) return null;
    if (model.oauth_last_success_ms <= 0) return null;
    const age_ms = model.now_ms - model.oauth_last_success_ms;
    if (age_ms <= oauth.stale_after_ms) return null;
    return @intCast(@divFloor(age_ms, 60_000));
}

/// Is this agent's source enabled in config?
pub fn sourceEnabled(sources: config.Sources, agent: types.Agent) bool {
    return switch (agent) {
        .claude => sources.claude,
        .codex => sources.codex,
    };
}

/// True when an agent has nothing to report: source enabled but zero
/// ledger events and no limit snapshot. During catch-up the question is
/// still open; afterwards it means "no sessions found".
pub fn agentIsEmpty(model: *const Model, agent: types.Agent) bool {
    if (model.ledger.forAgent(agent).events != 0) return false;
    const limits = switch (agent) {
        .claude => model.claude_limits,
        .codex => model.codex_limits,
    };
    return limits == null;
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

    // Config: absent file or bad lines never block startup. The path and
    // mtime stick around on the model so the 2 s sweep can live-reload.
    if (config.defaultPath(allocator, home)) |path| {
        model.config_path = path;
        model.config_mtime_ns = config.fileMtimeNs(path);
        _ = loadConfigFromDisk(model);
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

/// Read + parse the config file into a fresh arena and swap it in
/// (freeing the previous arena). A missing or unreadable file keeps the
/// current config untouched. Parse never hard-fails, so any readable
/// file yields a config (bad lines degrade to warnings/defaults).
fn loadConfigFromDisk(model: *Model) bool {
    if (model.config_path.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(model.allocator);
    const result = (config.load(arena.allocator(), model.config_path) catch null) orelse {
        arena.deinit();
        return false;
    };
    for (result.warnings) |w| {
        std.log.warn("config:{d}: {s}", .{ w.line, w.message });
    }
    model.cfg = result.config;
    if (model.cfg_arena) |*old| old.deinit();
    model.cfg_arena = arena;
    return true;
}

/// Live-reload poll, called from the 2 s sweep tick: stat the config
/// file and re-load when its mtime moved. Returns the sources that this
/// reload newly ENABLED (they need a history catch-up pass), or null
/// when nothing was reloaded. Applied live: `tray-format` (next tray
/// render), `source` (panels + sweeps), `claude-oauth` (enable polls on
/// the next gate; disable stops polling but KEEPS the last limit
/// snapshots — the staleness tag marks them honestly), and
/// `alert-threshold` (stored for the future notifier). Root-path keys
/// (`claude-config-dir`, `codex-home`) still require a restart.
pub fn maybeReloadConfig(model: *Model) ?config.Sources {
    if (model.config_path.len == 0) return null;
    // A deleted config keeps the old values (ghostty behavior).
    const mtime = config.fileMtimeNs(model.config_path) orelse return null;
    if (model.config_mtime_ns) |old| {
        if (mtime == old) return null;
    }
    model.config_mtime_ns = mtime;
    const old_sources = model.cfg.sources;
    const old_oauth = model.cfg.claude_oauth;
    if (!loadConfigFromDisk(model)) return null;
    std.log.info("config reloaded from {s}", .{model.config_path});
    if (model.cfg.claude_oauth and !old_oauth) {
        // Freshly opted in: poll at the next gate, not after a stale
        // backoff window left over from before the opt-in.
        model.oauth_backoff = .{};
        model.oauth_next_ms = model.now_ms;
    }
    return .{
        .claude = model.cfg.sources.claude and !old_sources.claude,
        .codex = model.cfg.sources.codex and !old_sources.codex,
    };
}

pub fn boot(model: *Model, fx: *Effects) void {
    // Enumerate the historical file queue (directory walk only — fast)
    // and chew through it on the fast catch-up timer. The window shows
    // live scanning progress instead of freezing behind the parse.
    model.now_ms = fx.wallMs();
    if (model.ready) startCatchup(model, model.cfg.sources, fx);
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
    refreshDisplay(model);
}

/// Enumerate history for `only` (a subset of the enabled sources) and,
/// if anything queued, start the catch-up timer. Used at boot for every
/// enabled source and by config live-reload for newly enabled ones.
fn startCatchup(model: *Model, only: config.Sources, fx: *Effects) void {
    enumerateHistory(model, only) catch |err| {
        std.log.warn("history enumeration failed: {s}", .{@errorName(err)});
    };
    if (model.catchup_queue.len > 0) {
        model.catchup_active = true;
        model.catchup_started_ms = model.now_ms;
        fx.startTimer(.{
            .key = catchup_timer_key,
            .interval_ms = catchup_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.catchup_tick),
        });
    }
}

/// Walk the given sources' roots collecting *.jsonl paths + sizes (no
/// parsing).
fn enumerateHistory(model: *Model, only: config.Sources) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var queue: std.ArrayList(CatchupFile) = .empty;
    errdefer {
        for (queue.items) |f| model.allocator.free(f.path);
        queue.deinit(model.allocator);
    }

    var walk_arena = std.heap.ArenaAllocator.init(model.allocator);
    defer walk_arena.deinit();

    const groups = [_]struct { agent: types.Agent, roots: []const []const u8, enabled: bool }{
        .{ .agent = .claude, .roots = model.claude_roots, .enabled = only.claude },
        .{ .agent = .codex, .roots = model.codex_roots, .enabled = only.codex },
    };
    for (groups) |group| {
        if (!group.enabled) continue;
        for (group.roots) |root| {
            var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(walk_arena.allocator());
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
                const path = try std.fs.path.join(model.allocator, &.{ root, entry.path });
                const stat = dir.statFile(io, entry.path, .{}) catch {
                    model.allocator.free(path);
                    continue;
                };
                try queue.append(model.allocator, .{ .agent = group.agent, .path = path, .size = stat.size });
            }
        }
    }
    // Oldest-first so burn/pace see history in causal order (claude
    // session files aren't date-named, but rough order beats none;
    // codex paths ARE date-ordered).
    std.mem.sort(CatchupFile, queue.items, {}, struct {
        fn lt(_: void, a: CatchupFile, b: CatchupFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    model.catchup_queue = try queue.toOwnedSlice(model.allocator);
}

/// Parse queued history files until the byte budget is spent. Runs on
/// the 30 ms catch-up timer; each chunk is a few ms of work, so frames
/// land in between and the needle stays alive.
fn processCatchupChunk(model: *Model, fx: *Effects) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var budget: u64 = catchup_chunk_bytes;
    while (model.catchup_next < model.catchup_queue.len) {
        const file = model.catchup_queue[model.catchup_next];
        switch (file.agent) {
            .claude => {
                var sink = claude.ListSink.init(model.allocator);
                defer sink.deinit();
                model.claude_tailer.scanFile(arena, io, file.path, sink.sink()) catch {};
                for (sink.events.items) |ev| ingest(model, ev);
            },
            .codex => {
                var events: std.ArrayList(types.UsageEvent) = .empty;
                defer events.deinit(arena);
                model.codex_tailer.poll(io, arena, file.path, &events) catch {};
                for (events.items) |ev| ingest(model, ev);
            },
        }
        model.catchup_next += 1;
        if (file.size >= budget) break;
        budget -= file.size;
    }

    if (model.catchup_next >= model.catchup_queue.len) {
        model.catchup_active = false;
        fx.cancelTimer(catchup_timer_key);
        const took_ms = model.now_ms - model.catchup_started_ms;
        std.log.info("history catch-up: {d} files in {d} ms", .{ model.catchup_queue.len, took_ms });
        for (model.catchup_queue) |f| model.allocator.free(f.path);
        model.allocator.free(model.catchup_queue);
        model.catchup_queue = &.{};
        model.catchup_next = 0;
        // Limits + a full display pass now that the ledger is complete.
        sweepOnce(model);
    }
    refreshDisplay(model);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => {
            model.now_ms = fx.wallMs();
            // Config live-reload rides the sweep tick: an mtime stat per
            // 2 s is free, and a newly enabled source gets the same
            // chunked history catch-up boot gives it.
            if (maybeReloadConfig(model)) |newly_enabled| {
                if (newly_enabled.any() and !model.catchup_active) {
                    startCatchup(model, newly_enabled, fx);
                }
                refreshDisplay(model);
            }
            // While catch-up owns the tailers, the steady sweep stands
            // down (offsets make overlap safe, but it's wasted work).
            if (!model.catchup_active) {
                const sweep_start_ns = native_sdk.monotonicNanoseconds();
                sweepOnce(model);
                const sweep_us = (native_sdk.monotonicNanoseconds() - sweep_start_ns) / std.time.ns_per_us;
                std.log.debug("sweep: {d} us", .{sweep_us});
            }
            // First OAuth poll shouldn't wait for the 30 s gate.
            if (!model.first_sweep_done) maybeOauthPoll(model, fx);
            model.first_sweep_done = true;
        },
        .catchup_tick => {
            model.now_ms = fx.wallMs();
            if (model.catchup_active) processCatchupChunk(model, fx);
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
        setErrorStatus(model, "keychain read failed (security exit {d})", .{exit.code});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const creds = oauth.parseCredentials(arena_state.allocator(), std.mem.trim(u8, exit.output, " \t\r\n")) catch {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + oauth.poll_interval_ms;
        setErrorStatus(model, "unreadable Claude credentials payload", .{});
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
            setErrorStatus(model, "unparseable usage response", .{});
            return;
        };
        model.walls.observe(snap);
        storeLimits(model, &model.claude_limits, snap);
        model.oauth_backoff.onSuccess();
        model.status_error = false;
        model.oauth_last_success_ms = model.now_ms;
        model.oauth_next_ms = model.now_ms + oauth.poll_interval_ms;
    } else {
        model.oauth_backoff.onFailure();
        model.oauth_next_ms = model.now_ms + model.oauth_backoff.delayMs();
        setErrorStatus(model, "usage endpoint: status {d} ({t})", .{ resp.status, resp.outcome });
    }
}

// ---------------------------------------------------------------- display

fn setStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
    model.status_text = std.fmt.bufPrint(&model.status_buf, fmt, args) catch model.status_text;
}

fn setErrorStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
    setStatus(model, fmt, args);
    model.status_error = true;
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
    if (model.catchup_active) {
        setStatus(model, "scanning history… {d}/{d} files", .{ model.catchup_next, model.catchup_queue.len });
    } else if (!model.status_error) {
        if (model.ready) {
            setStatus(model, "{d} events · {d} models priced", .{ model.ledger.all.events, model.ledger.per_model.count() });
        }
    }
}

fn agentLine(buf: []u8, model: *const Model, agent: types.Agent, limits: ?types.LimitSnapshot) []const u8 {
    const totals = model.ledger.forAgent(agent);
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(agent.label()) catch {};
    w.writeAll("  ") catch {};
    if (!sourceEnabled(model.cfg.sources, agent)) {
        w.writeAll("disabled") catch {};
        return w.buffered();
    }
    if (agentIsEmpty(model, agent)) {
        w.writeAll(if (model.catchup_active) "scanning…" else "no sessions found") catch {};
        return w.buffered();
    }
    trayfmt.writeHumanTokens(&w, totals.totalTokens()) catch {};
    w.writeAll(" tok · ") catch {};
    trayfmt.writeCost(&w, totals.cost_usd) catch {};
    if (agent == .claude) {
        if (oauthStaleMin(model)) |mins| {
            w.writeAll(" · stale ") catch {};
            w.printInt(mins, 10, .lower, .{}) catch {};
            w.writeByte('m') catch {};
        }
    }
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

test "oauth staleness: fresh, stale, and no-snapshot cases" {
    var model = Model{ .allocator = testing.allocator };
    model.now_ms = 60 * 60_000;

    // No snapshot: nothing to be stale about.
    model.oauth_last_success_ms = 1;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));

    const windows = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 10 }};
    model.claude_limits = .{ .agent = .claude, .read_at_ms = 0, .windows = &windows };

    // Exactly at the threshold is still fresh.
    model.oauth_last_success_ms = model.now_ms - oauth.stale_after_ms;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));
    // Seven minutes old (threshold is five): stale, reported in minutes.
    model.oauth_last_success_ms = model.now_ms - 7 * 60_000;
    try testing.expectEqual(@as(?u64, 7), oauthStaleMin(&model));
    // Never succeeded: no tag (the "no limit data" row covers it).
    model.oauth_last_success_ms = 0;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));
}

test "config live-reload: mtime change reapplies, unchanged mtime does not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config",
        .data = "tray-format = AAA\nsource = codex\n",
    });

    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    defer if (model.cfg_arena) |*a| a.deinit();
    // tmpDir paths are cwd-relative, same contract as config.load's test.
    model.config_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/config", .{tmp.sub_path});
    defer testing.allocator.free(model.config_path);

    // First observation (mtime unknown at setup): reload. Claude was
    // already enabled by default, so nothing is NEWLY enabled by v1.
    const first = maybeReloadConfig(&model) orelse return error.TestUnexpectedResult;
    try testing.expect(!first.claude and !first.codex);
    try testing.expectEqualStrings("AAA", model.cfg.tray_format);
    try testing.expect(!model.cfg.sources.claude);
    try testing.expect(model.cfg.sources.codex);

    // Unchanged mtime: no reload, no churn.
    try testing.expectEqual(@as(?config.Sources, null), maybeReloadConfig(&model));

    // v2 re-enables claude and opts into OAuth. Rewrite until the mtime
    // observably moves (APFS is ns-resolution; one write suffices in
    // practice, the loop just removes the timing assumption).
    model.now_ms = 123_456;
    model.oauth_next_ms = 999_999_999;
    var tries: usize = 0;
    while (config.fileMtimeNs(model.config_path).? == model.config_mtime_ns.?) : (tries += 1) {
        if (tries > 10_000) return error.TestUnexpectedResult;
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "config",
            .data = "tray-format = BBB\nsource = claude, codex\nclaude-oauth = true\n",
        });
    }
    const second = maybeReloadConfig(&model) orelse return error.TestUnexpectedResult;
    try testing.expect(second.claude);
    try testing.expect(!second.codex);
    try testing.expectEqualStrings("BBB", model.cfg.tray_format);
    try testing.expect(model.cfg.claude_oauth);
    // Fresh opt-in reopens the poll gate immediately.
    try testing.expectEqual(model.now_ms, model.oauth_next_ms);

    // Deleted config: keep the last good values, report no reload.
    try tmp.dir.deleteFile(testing.io, "config");
    try testing.expectEqual(@as(?config.Sources, null), maybeReloadConfig(&model));
    try testing.expectEqualStrings("BBB", model.cfg.tray_format);
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
