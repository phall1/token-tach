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
const opencode = @import("core/opencode.zig");
const pricing = @import("core/pricing.zig");
const ledger_mod = @import("core/ledger.zig");
const statefile = @import("core/statefile.zig");
const predict = @import("core/predict.zig");
const alerts = @import("core/alerts.zig");
const oauth = @import("core/oauth.zig");
const keychain = @import("core/keychain.zig");
const trayfmt = @import("core/trayfmt.zig");
const system = @import("core/system/system.zig");

pub const Effects = native_sdk.Effects(Msg);

pub const sweep_timer_key: u64 = 1;
pub const oauth_gate_timer_key: u64 = 2;
pub const oauth_fetch_key: u64 = 3;
pub const tz_spawn_key: u64 = 4;
pub const creds_spawn_key: u64 = 5;
pub const catchup_timer_key: u64 = 6;
pub const ignition_timer_key: u64 = 7;

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
    /// Tray "Quit" — accessory apps have no Dock icon to quit from.
    quit,
    /// Display-only: the tray popover just opened (SDK on_command
    /// `tray.popover_opened`) — replay the ignition sweep.
    popover_opened,
    /// Display-only: an ignition phase boundary (one-shot timer).
    ignition_tick: native_sdk.EffectTimer,
    /// Open the history dashboard window (tray menu item or the
    /// popover's DASH button). The flag IS the window: main.zig's
    /// `windows_fn` declares the window while it is set and the runtime
    /// reconciles after every dispatch.
    open_dashboard,
    /// The user closed the dashboard window — clear the flag so the
    /// model agrees with the platform (see WindowDescriptor.on_close).
    dashboard_closed,
    /// Tray "Settings": open ~/.config/token-tach/config in the default
    /// editor (creating a commented template first if absent).
    open_config,
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
    opencode_poller: opencode.Poller = undefined,
    claude_roots: []const []const u8 = &.{},
    codex_roots: []const []const u8 = &.{},
    opencode_db: []const u8 = "",

    prices: pricing.Db = undefined,
    ledger: ledger_mod.Ledger = undefined,
    burn: predict.BurnRate = .{},
    walls: predict.WallTracker = .{},
    alerts: alerts.AlertEngine = .{},

    /// Latest limit snapshots for display (windows slices owned by us).
    claude_limits: ?types.LimitSnapshot = null,
    codex_limits: ?types.LimitSnapshot = null,

    /// System telemetry: per-sampler counter state plus the latest
    /// snapshot (plain values, refreshed each sweep, ephemeral by
    /// design — never persisted).
    system_sampler: system.Sampler = system.Sampler.init(),
    system_snap: system.Snapshot = .{},

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

    // Persisted tailer/ledger state (statefile.zig): resolved path (owned),
    // the ledger event count at the last save (idle ticks skip the write),
    // and the tick countdown to the next save.
    state_path: []const u8 = "",
    state_saved_events: u64 = 0,
    state_dirty: bool = false,
    state_save_countdown: u32 = state_save_ticks,

    // Display strings bound by app.native — regenerated each sweep, and
    // pointing into the fixed buffers below (never into stack copies).
    glance_text: []const u8 = "",
    claude_text: []const u8 = "",
    codex_text: []const u8 = "",
    opencode_text: []const u8 = "",
    today_text: []const u8 = "",
    status_text: []const u8 = "starting…",

    glance_buf: [text_buf_len]u8 = undefined,
    claude_buf: [text_buf_len]u8 = undefined,
    codex_buf: [text_buf_len]u8 = undefined,
    opencode_buf: [text_buf_len]u8 = undefined,
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

    // Ignition sweep (pure display): the key-on needle theatre — 0 →
    // full scale → settle onto truth — runs at boot and on every
    // popover open. The phase machine is stepped by one-shot timers;
    // `ignition_t0_ms` anchors the render animations on the wall
    // clock so mid-sweep rebuilds replay idempotently instead of
    // restarting the sweep.
    ignition_phase: IgnitionPhase = .off,
    ignition_t0_ms: i64 = 0,

    /// The history dashboard window's open flag (pure display). The
    /// runtime reconciles model-declared windows against this after
    /// every dispatch — presence IS visibility.
    dashboard_open: bool = false,
};

pub const IgnitionPhase = enum { off, up, settle };

/// Ignition tempo: needle 0 → full scale, a beat at the top, then a
/// settle onto the true reading (~1.3 s total — a car key turn).
pub const ignition_up_ms: u32 = 700;
pub const ignition_settle_ms: u32 = 620;

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
        .opencode => sources.opencode,
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
        .opencode => null,
    };
    return limits == null;
}

/// Environment facts setup needs — extracted from the runner's
/// `init.environ_map` by main (keeps setup unit-testable).
pub const Env = struct {
    home: []const u8 = "",
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    opencode_db: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
};

/// Persist tailer+ledger state every N sweep ticks (N × 2 s ≈ 60 s).
pub const state_save_ticks: u32 = 30;

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
    model.opencode_db = try opencode.resolvePath(allocator, model.cfg.opencode_db, env.opencode_db, env.xdg_data_home, home);

    model.claude_tailer = claude.Tailer.init(allocator);
    model.codex_tailer = codex.Tailer.init(allocator);
    model.opencode_poller = opencode.Poller.init(allocator);
    model.prices = try pricing.Db.init(allocator);
    model.ledger = ledger_mod.Ledger.init(allocator, 0);

    // Warm launch: restore tailer offsets + ledger rollups so history is
    // never re-parsed. Any doubt about the file -> pristine full catch-up.
    model.state_path = statefile.defaultPath(allocator, env.xdg_state_home, home) catch "";
    if (model.state_path.len > 0) {
        const outcome = statefile.restore(
            allocator,
            io,
            model.state_path,
            &model.claude_tailer,
            &model.codex_tailer,
            &model.opencode_poller,
            &model.ledger,
        ) catch .invalid; // OOM: hydration may be partial — reset below.
        switch (outcome) {
            .restored => model.state_saved_events = model.ledger.all.events,
            .absent => {},
            .invalid => {
                model.claude_tailer.deinit();
                model.codex_tailer.deinit();
                model.opencode_poller.deinit();
                model.ledger.deinit();
                model.claude_tailer = claude.Tailer.init(allocator);
                model.codex_tailer = codex.Tailer.init(allocator);
                model.opencode_poller = opencode.Poller.init(allocator);
                model.ledger = ledger_mod.Ledger.init(allocator, 0);
                std.log.warn("state file invalid — falling back to full catch-up", .{});
            },
        }
    }
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
/// `alert-threshold` (stored for the future notifier), and
/// `system-stats` (the next sweep samples exactly the new module set).
/// Root-path keys (`claude-config-dir`, `codex-home`, `opencode-db`)
/// still require a restart.
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
        .opencode = model.cfg.sources.opencode and !old_sources.opencode,
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
    startIgnition(model, fx);
}

/// Key-on: arm the ignition sweep (display-only) and the one-shot
/// timer that steps it to the settle phase. Restartable — reopening
/// the popover mid-sweep re-anchors the whole sequence.
fn startIgnition(model: *Model, fx: *Effects) void {
    model.ignition_phase = .up;
    model.ignition_t0_ms = model.now_ms;
    fx.startTimer(.{
        .key = ignition_timer_key,
        .interval_ms = ignition_up_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.ignition_tick),
    });
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
                // Warm launch: a file whose restored offset already sits at
                // EOF has nothing to say — keep it out of the queue.
                const known: ?u64 = switch (group.agent) {
                    .claude => model.claude_tailer.offsetFor(path),
                    .codex => model.codex_tailer.offsetFor(path),
                    .opencode => unreachable,
                };
                if (known != null and known.? == stat.size) {
                    model.allocator.free(path);
                    continue;
                }
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
            .opencode => unreachable,
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
        saveStateNow(model);
    }
    refreshDisplay(model);
}

/// The OAuth cadence: `poll-interval` from config (seconds), floored at
/// 60s so a typo can never hammer the endpoint.
fn configuredPollMs(model: *const Model) i64 {
    return @as(i64, @max(model.cfg.poll_interval_s, 60)) * 1000;
}

pub const config_spawn_key: u64 = 8;

const config_template =
    \\# token-tach configuration — live-reloaded while the app runs.
    \\# Tray template tokens: {burn} {eta} {pct} {tok} {cost}
    \\#                       {cpu} {gpu} {mem} {disk} {net} {batt}
    \\#tray-format = {burn} → {eta}
    \\
    \\# System telemetry strip: true/false, or a module list
    \\# (cpu, gpu, mem, disk, net, battery).
    \\#system-stats = true
    \\
    \\# Server-truth Claude limits via your Claude Code OAuth token (Keychain).
    \\#claude-oauth = true
    \\#poll-interval = 180s
    \\
    \\#alert-threshold = 70, 90
    \\#source = claude, codex, opencode
    \\#claude-config-dir = ~/some/other/claude-root
    \\#codex-home = ~/.codex
    \\#opencode-db = ~/.local/share/opencode/opencode.db
    \\
;

/// Tray "Settings": ensure the config file exists (write a fully
/// commented template on first use) and hand it to the default editor.
fn openConfig(model: *Model, fx: *Effects) void {
    if (model.config_path.len == 0) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, model.config_path, .{}) catch {
        if (std.fs.path.dirname(model.config_path)) |dir| {
            cwd.createDirPath(io, dir) catch {};
        }
        cwd.writeFile(io, .{ .sub_path = model.config_path, .data = config_template }) catch |err| {
            setErrorStatus(model, "could not create config: {s}", .{@errorName(err)});
            return;
        };
    };
    fx.spawn(.{
        .key = config_spawn_key,
        .argv = &.{ "open", "-t", model.config_path },
        .output = .collect,
        .on_exit = Effects.exitMsg(.tz_done), // exit is uninteresting; reuse a no-op-safe arm
    });
}

/// Save every `state_save_ticks` sweeps, only if the ledger moved.
fn maybeSaveState(model: *Model) void {
    if (model.state_save_countdown > 1) {
        model.state_save_countdown -= 1;
        return;
    }
    model.state_save_countdown = state_save_ticks;
    if (!model.state_dirty and model.ledger.all.events == model.state_saved_events) return;
    saveStateNow(model);
}

fn saveStateNow(model: *Model) void {
    if (model.state_path.len == 0) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    statefile.save(model.allocator, io, model.state_path, &model.claude_tailer, &model.codex_tailer, &model.opencode_poller, &model.ledger) catch |err| {
        std.log.warn("state save failed: {s}", .{@errorName(err)});
        return;
    };
    model.state_saved_events = model.ledger.all.events;
    model.state_dirty = false;
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
                dispatchAlerts(model, fx);
                maybeSaveState(model);
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
            dispatchAlerts(model, fx);
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
        .popover_opened => {
            model.now_ms = fx.wallMs();
            startIgnition(model, fx);
        },
        .open_config => openConfig(model, fx),
        .quit => {
            // Accessory app: the tray Quit item is the only exit
            // affordance. Flush state, then leave — the runtime has no
            // graceful-shutdown API to hand back to.
            saveStateNow(model);
            std.process.exit(0);
        },
        .open_dashboard => {
            model.now_ms = fx.wallMs();
            model.dashboard_open = true;
        },
        .dashboard_closed => {
            model.dashboard_open = false;
        },
        .ignition_tick => {
            model.now_ms = fx.wallMs();
            switch (model.ignition_phase) {
                .up => {
                    model.ignition_phase = .settle;
                    fx.startTimer(.{
                        .key = ignition_timer_key,
                        .interval_ms = ignition_settle_ms,
                        .mode = .one_shot,
                        .on_fire = Effects.timerMsg(.ignition_tick),
                    });
                },
                .settle, .off => model.ignition_phase = .off,
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
        _ = model.claude_tailer.sweepIncremental(arena, io, model.claude_roots, sink.sink(), model.now_ms) catch |err| blk: {
            std.log.warn("claude sweep failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        for (sink.events.items) |ev| ingest(model, ev);
    }

    if (model.cfg.sources.codex) {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        defer events.deinit(arena);
        _ = model.codex_tailer.sweepIncremental(io, arena, model.codex_roots, &events, model.now_ms) catch |err| blk: {
            std.log.warn("codex sweep failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        for (events.items) |ev| ingest(model, ev);

        // Limits ride the tailer now (captured off token_count lines during
        // parse, restored from the state file) — no per-tick file re-reads.
        if (model.codex_tailer.lastLimits()) |snap| {
            const newer = if (model.codex_limits) |cur| snap.read_at_ms > cur.read_at_ms else true;
            if (newer) {
                model.walls.observe(snap);
                storeLimits(model, &model.codex_limits, snap);
            }
        }
    }

    if (model.cfg.sources.opencode) {
        var changes: std.ArrayList(opencode.Change) = .empty;
        defer {
            opencode.freeChanges(arena, changes.items);
            changes.deinit(arena);
        }
        model.opencode_poller.poll(arena, model.opencode_db, &changes) catch |err| {
            std.log.warn("opencode sweep failed: {s}", .{@errorName(err)});
        };
        for (changes.items) |change| ingestOpenCodeChange(model, change);
    }

    // System telemetry rides the same sweep: microseconds of syscalls,
    // no subprocesses. A config with the strip off skips the calls and
    // clears the snapshot so the view (and tray tokens) go quiet.
    if (model.cfg.system_stats.any()) {
        model.system_snap = model.system_sampler.sample(systemEnabled(model.cfg.system_stats));
    } else {
        model.system_snap = .{};
    }

    refreshDisplay(model);
}

/// config.SystemStats → system.Enabled, field by field (the two structs
/// mirror each other but stay decoupled).
fn systemEnabled(s: config.SystemStats) system.Enabled {
    return .{ .cpu = s.cpu, .gpu = s.gpu, .mem = s.mem, .disk = s.disk, .net = s.net, .battery = s.battery };
}

fn ingest(model: *Model, ev: types.UsageEvent) void {
    const cost = model.prices.costOf(ev);
    model.ledger.add(ev, cost) catch return;
    model.burn.addTokens(ev.timestamp_ms, predict.limitWeightedTokens(ev));
}

fn ingestOpenCodeChange(model: *Model, change: opencode.Change) void {
    const new_cost = model.prices.costOf(change.current);
    if (change.previous) |old| {
        model.ledger.replace(old, model.prices.costOf(old), change.current, new_cost) catch return;
        const delta = types.UsageEvent{
            .agent = .opencode,
            .timestamp_ms = change.current.timestamp_ms,
            .model = change.current.model,
            .input_tokens = change.current.input_tokens -| old.input_tokens,
            .output_tokens = change.current.output_tokens -| old.output_tokens,
            .cache_creation_tokens = change.current.cache_creation_tokens -| old.cache_creation_tokens,
            .cache_read_tokens = change.current.cache_read_tokens -| old.cache_read_tokens,
        };
        model.burn.addTokens(delta.timestamp_ms, predict.limitWeightedTokens(delta));
    } else {
        model.ledger.add(change.current, new_cost) catch return;
        model.burn.addTokens(change.current.timestamp_ms, predict.limitWeightedTokens(change.current));
    }
    model.state_dirty = true;
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

fn dispatchAlerts(model: *Model, fx: *Effects) void {
    var snaps: [2]types.LimitSnapshot = undefined;
    var count: usize = 0;
    if (model.claude_limits) |snap| {
        snaps[count] = snap;
        count += 1;
    }
    if (model.codex_limits) |snap| {
        snaps[count] = snap;
        count += 1;
    }
    const fired = model.alerts.observe(
        model.now_ms,
        model.tz_offset_min,
        snaps[0..count],
        model.walls.nearestWall(model.now_ms),
        model.cfg.alert_thresholds,
    );
    const services = fx.services orelse return;
    for (fired) |*alert| {
        services.showNotification(.{
            .title = alert.title(),
            .subtitle = "Token Tach",
            .body = alert.body(),
        }) catch {};
    }
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
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
        setErrorStatus(model, "keychain read failed (security exit {d})", .{exit.code});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const creds = oauth.parseCredentials(arena_state.allocator(), std.mem.trim(u8, exit.output, " \t\r\n")) catch {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
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
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
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
        .cpu_frac = if (model.system_snap.cpu) |s| s.total_frac else null,
        .gpu_frac = if (model.system_snap.gpu) |s| s.device_utilization else null,
        .mem_frac = if (model.system_snap.mem) |s| s.used_frac else null,
        .disk_free_bytes = if (model.system_snap.disk) |s| s.free_bytes else null,
        .net_rx_bps = if (model.system_snap.net) |s| s.in_bytes_per_sec else null,
        .net_tx_bps = if (model.system_snap.net) |s| s.out_bytes_per_sec else null,
        .battery_frac = if (model.system_snap.battery) |s| s.charge else null,
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
    model.opencode_text = agentLine(&model.opencode_buf, model, .opencode, null);

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

// --------------------------------------------------- dashboard rollups
// Pure display helpers for the history dashboard window: local calendar
// math over the ledger's per-day buckets plus the subscription-value
// framing. All read-only over Model/Ledger — unit-tested below.

/// A local civil date derived from a ledger day key (days since epoch
/// in the ledger's local time; see ledger.dayKey).
pub const CivilDate = struct { year: u16, month: u8, day: u8 };

pub fn civilFromDayKey(day_key: i64) CivilDate {
    const epoch = std.time.epoch;
    const clamped: u47 = @intCast(std.math.clamp(day_key, 0, std.math.maxInt(u47)));
    const year_day = (epoch.EpochDay{ .day = clamped }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1,
    };
}

/// This local calendar month's rollup: the month the journaled clock
/// says it is (in the ledger's tz), summed from per-day buckets.
pub const MonthRollup = struct {
    year: u16,
    /// 1–12.
    month: u8,
    /// Day key of the 1st (inclusive lower bound of the bucket scan).
    first_day_key: i64,
    /// Calendar length of the month in days.
    day_count: u8,
    totals: ledger_mod.Totals,
    /// Local days this month with at least one event.
    active_days: u32,
};

pub fn monthRollup(ledger: *const ledger_mod.Ledger, now_ms: i64) MonthRollup {
    const today_key = ledger_mod.dayKey(now_ms, ledger.tz_offset_min);
    const date = civilFromDayKey(today_key);
    const first = today_key - @as(i64, date.day) + 1;
    const day_count: u8 = std.time.epoch.getDaysInMonth(date.year, @enumFromInt(date.month));
    var out: MonthRollup = .{
        .year = date.year,
        .month = date.month,
        .first_day_key = first,
        .day_count = day_count,
        .totals = .{},
        .active_days = 0,
    };
    for (ledger.per_day.keys(), ledger.per_day.values()) |key, totals| {
        if (key < first or key >= first + day_count) continue;
        accumulateTotals(&out.totals, totals);
        if (totals.events > 0) out.active_days += 1;
    }
    return out;
}

/// Fill `out` with cost per local day for the trailing `out.len` days,
/// oldest first — `out[out.len - 1]` is today. Days with no bucket are 0.
pub fn trailingDailyCost(ledger: *const ledger_mod.Ledger, now_ms: i64, out: []f64) void {
    const today_key = ledger_mod.dayKey(now_ms, ledger.tz_offset_min);
    for (out, 0..) |*slot, i| {
        const key = today_key - @as(i64, @intCast(out.len - 1 - i));
        slot.* = if (ledger.per_day.get(key)) |totals| totals.cost_usd else 0;
    }
}

fn accumulateTotals(dst: *ledger_mod.Totals, src: ledger_mod.Totals) void {
    dst.input_tokens += src.input_tokens;
    dst.output_tokens += src.output_tokens;
    dst.cache_creation_tokens += src.cache_creation_tokens;
    dst.cache_read_tokens += src.cache_read_tokens;
    dst.cost_usd += src.cost_usd;
    dst.events += src.events;
}

/// A known plan's monthly price band. `lo == hi` when the plan string
/// names one price; claude "max" is ambiguous between the 5x ($100) and
/// 20x ($200) tiers — the credentials payload doesn't say which — so it
/// carries the whole band and every derived figure says so.
pub const PlanPrice = struct { lo: f64, hi: f64 };

pub fn planPrice(agent: types.Agent, plan: []const u8) ?PlanPrice {
    const eq = std.ascii.eqlIgnoreCase;
    switch (agent) {
        .claude => {
            if (eq(plan, "pro")) return .{ .lo = 20, .hi = 20 };
            if (eq(plan, "max")) return .{ .lo = 100, .hi = 200 };
        },
        .codex => {
            if (eq(plan, "plus")) return .{ .lo = 20, .hi = 20 };
            if (eq(plan, "pro")) return .{ .lo = 200, .hi = 200 };
            if (eq(plan, "free")) return .{ .lo = 0, .hi = 0 };
        },
        .opencode => return null,
    }
    return null;
}

/// The subscription-value framing: what the ledger's usage would have
/// cost at API rates versus what the visible plans cost per month.
/// Honesty rules: the multiple divides by the plan band's HIGH end (a
/// lower bound, displayed "≥"), and an agent with usage but no
/// recognizable plan marks the figure incomplete — an understated
/// denominator would inflate the multiple, so none is claimed.
pub const SubscriptionValue = struct {
    plan_lo_usd: f64 = 0,
    plan_hi_usd: f64 = 0,
    claude_plan: []const u8 = "",
    codex_plan: []const u8 = "",
    /// Some agent contributed usage without a priceable plan string.
    incomplete: bool = false,

    /// The plan band spans two possible tiers (claude "max").
    pub fn ambiguous(self: SubscriptionValue) bool {
        return self.plan_lo_usd != self.plan_hi_usd;
    }

    /// Conservative "N× the plan" multiple: cost ÷ high end of the plan
    /// band. Null when the denominator is unknown or zero.
    pub fn multipleLowerBound(self: SubscriptionValue, api_cost_usd: f64) ?f64 {
        if (self.incomplete or self.plan_hi_usd <= 0) return null;
        return api_cost_usd / self.plan_hi_usd;
    }
};

pub fn subscriptionValue(model: *const Model) SubscriptionValue {
    var out: SubscriptionValue = .{};
    out.claude_plan = if (model.claude_plan.len > 0)
        model.claude_plan
    else if (model.claude_limits) |snap| snap.plan else "";
    out.codex_plan = if (model.codex_limits) |snap| snap.plan else "";

    const plans = [_]struct { agent: types.Agent, plan: []const u8 }{
        .{ .agent = .claude, .plan = out.claude_plan },
        .{ .agent = .codex, .plan = out.codex_plan },
    };
    for (plans) |entry| {
        const has_usage = model.ledger.forAgent(entry.agent).events > 0;
        if (planPrice(entry.agent, entry.plan)) |price| {
            out.plan_lo_usd += price.lo;
            out.plan_hi_usd += price.hi;
        } else if (has_usage) {
            out.incomplete = true;
        }
    }
    return out;
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

test "civil dates from day keys" {
    // 1970-01-01 is day 0.
    try testing.expectEqual(CivilDate{ .year = 1970, .month = 1, .day = 1 }, civilFromDayKey(0));
    // 2026-07-09 is day 20643 (verified against `date -j -f %F 2026-07-09 +%s` / 86400).
    try testing.expectEqual(CivilDate{ .year = 2026, .month = 7, .day = 9 }, civilFromDayKey(20_643));
    // Leap-year boundary: 2024-02-29 is day 19782, 2024-03-01 is 19783.
    try testing.expectEqual(CivilDate{ .year = 2024, .month = 2, .day = 29 }, civilFromDayKey(19_782));
    try testing.expectEqual(CivilDate{ .year = 2024, .month = 3, .day = 1 }, civilFromDayKey(19_783));
}

test "month rollup sums exactly the local calendar month" {
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    // 2026-07-09T12:00Z. July 2026 spans day keys 20635..20665.
    const now_ms: i64 = (20_643 * 86_400_000) + 12 * 3_600_000;
    const day_ms = 86_400_000;
    const mk = struct {
        fn ev(ts: i64, out: u64) types.UsageEvent {
            return .{ .agent = .claude, .timestamp_ms = ts, .model = "m", .output_tokens = out };
        }
    };
    // June 30 (out of month), July 1, July 9, July 31 (in month).
    try ledger.add(mk.ev(20_634 * day_ms, 1), 10.0);
    try ledger.add(mk.ev(20_635 * day_ms, 2), 1.0);
    try ledger.add(mk.ev(20_643 * day_ms, 4), 2.0);
    try ledger.add(mk.ev(20_665 * day_ms, 8), 4.0);
    // Aug 1 (out of month).
    try ledger.add(mk.ev(20_666 * day_ms, 16), 20.0);

    const rollup = monthRollup(&ledger, now_ms);
    try testing.expectEqual(@as(u16, 2026), rollup.year);
    try testing.expectEqual(@as(u8, 7), rollup.month);
    try testing.expectEqual(@as(i64, 20_635), rollup.first_day_key);
    try testing.expectEqual(@as(u8, 31), rollup.day_count);
    try testing.expectEqual(@as(u64, 14), rollup.totals.totalTokens());
    try testing.expectApproxEqAbs(@as(f64, 7.0), rollup.totals.cost_usd, 1e-9);
    try testing.expectEqual(@as(u32, 3), rollup.active_days);
}

test "month rollup respects the ledger tz offset at a month boundary" {
    // 2026-08-01T02:00Z at UTC-5 is still locally July 31.
    var ledger = ledger_mod.Ledger.init(testing.allocator, -300);
    defer ledger.deinit();
    const now_ms: i64 = 20_666 * 86_400_000 + 2 * 3_600_000;
    try ledger.add(.{ .agent = .claude, .timestamp_ms = now_ms, .model = "m", .output_tokens = 5 }, 1.5);

    const rollup = monthRollup(&ledger, now_ms);
    try testing.expectEqual(@as(u8, 7), rollup.month);
    try testing.expectApproxEqAbs(@as(f64, 1.5), rollup.totals.cost_usd, 1e-9);
}

test "trailing daily cost fills oldest-first with zeros for silent days" {
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    const day_ms = 86_400_000;
    const now_ms: i64 = 20_643 * day_ms + 1;
    try ledger.add(.{ .agent = .claude, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 3.0);
    try ledger.add(.{ .agent = .codex, .timestamp_ms = now_ms - 2 * day_ms, .model = "m", .output_tokens = 1 }, 5.0);

    var out: [4]f64 = undefined;
    trailingDailyCost(&ledger, now_ms, &out);
    try testing.expectEqual(@as(f64, 0), out[0]);
    try testing.expectEqual(@as(f64, 5.0), out[1]);
    try testing.expectEqual(@as(f64, 0), out[2]);
    try testing.expectEqual(@as(f64, 3.0), out[3]);
}

test "plan price table" {
    try testing.expectEqual(PlanPrice{ .lo = 20, .hi = 20 }, planPrice(.claude, "pro").?);
    try testing.expectEqual(PlanPrice{ .lo = 100, .hi = 200 }, planPrice(.claude, "Max").?);
    try testing.expectEqual(PlanPrice{ .lo = 20, .hi = 20 }, planPrice(.codex, "plus").?);
    try testing.expectEqual(PlanPrice{ .lo = 200, .hi = 200 }, planPrice(.codex, "pro").?);
    try testing.expectEqual(PlanPrice{ .lo = 0, .hi = 0 }, planPrice(.codex, "free").?);
    try testing.expectEqual(@as(?PlanPrice, null), planPrice(.claude, "enterprise"));
    try testing.expectEqual(@as(?PlanPrice, null), planPrice(.codex, ""));
}

test "subscription value: bands, ambiguity, and the incomplete guard" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();

    // claude max + codex plus with usage on both.
    @memcpy(model.claude_plan_buf[0..3], "max");
    model.claude_plan = model.claude_plan_buf[0..3];
    const codex_windows = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 1 }};
    model.codex_limits = .{ .agent = .codex, .read_at_ms = 0, .plan = "plus", .windows = &codex_windows };
    try model.ledger.add(.{ .agent = .claude, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 100.0);
    try model.ledger.add(.{ .agent = .codex, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 10.0);
    // OpenCode contributes to the API-equivalent numerator supplied below,
    // never to the Claude/Codex subscription-plan denominator.
    try model.ledger.add(.{ .agent = .opencode, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 4_070.0);

    var value = subscriptionValue(&model);
    try testing.expectEqual(@as(f64, 120), value.plan_lo_usd);
    try testing.expectEqual(@as(f64, 220), value.plan_hi_usd);
    try testing.expect(value.ambiguous());
    try testing.expect(!value.incomplete);
    // ≥ 4180 / 220 = 19×.
    try testing.expectApproxEqAbs(@as(f64, 19.0), value.multipleLowerBound(4_180).?, 1e-9);

    // An agent with usage but no recognizable plan withdraws the claim.
    model.claude_plan = "";
    value = subscriptionValue(&model);
    try testing.expect(value.incomplete);
    try testing.expectEqual(@as(?f64, null), value.multipleLowerBound(4_180));

    // No usage from the unpriced agent: the claim stands on codex alone.
    var fresh = Model{ .allocator = testing.allocator };
    fresh.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer fresh.ledger.deinit();
    fresh.codex_limits = .{ .agent = .codex, .read_at_ms = 0, .plan = "plus", .windows = &codex_windows };
    try fresh.ledger.add(.{ .agent = .codex, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 10.0);
    const solo = subscriptionValue(&fresh);
    try testing.expect(!solo.incomplete);
    try testing.expectEqual(@as(f64, 20), solo.plan_hi_usd);
    try testing.expect(!solo.ambiguous());
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
