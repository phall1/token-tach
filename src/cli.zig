//! CLI mode: `token-tach --json` / `--statusline` print an instant
//! usage/limits snapshot and exit; the query verbs (`history`, `burn`,
//! `top`, `sessions`, `export`, `doctor`) read the durable time series.
//! Either way the GUI never launches. This is the statusline/scripting
//! seam (PLAN.md v1.3): the same UI-free core the app runs, driven once,
//! read-only.
//!
//! Data path (LOCAL ONLY — no network, no keychain):
//!   1. config (`~/.config/token-tach/config`) for roots + enabled sources,
//!   2. `statefile.restore` re-hydrates tailers + ledger from the app's
//!      saved state (~2 ms warm path),
//!   3. ONE incremental sweep picks up bytes appended since the app last
//!      saved (or, with no state file, cold-parses full history — slower
//!      but correct),
//!   4. `core/history.zig`'s durable store supplies burn, extents, and
//!      the per-agent time splits the ledger cannot answer,
//!   5. (--json only) live system telemetry sampled over a ~150 ms
//!      window — mach/sysctl/IOKit reads, still local-only,
//!   6. render.
//!
//! Guarantees:
//! - **Read-only.** `statefile.save` is never called; the app's state file
//!   is never written, so running alongside a live app instance is safe.
//!   The same holds for the history store, and more strictly: this module
//!   only ever constructs a `history.Reader`, which takes no flock. It
//!   must never take the writer lock and must never compact — a query
//!   that can stall or displace the collecting process is a query that
//!   loses data, and the store is TRUTH (see `core/history.zig`).
//! - **Never crashes.** Missing state/config/roots degrade to an empty
//!   snapshot with an explanatory `note`; exit is always 0 once a CLI
//!   flag was recognized.
//!
//! Honest omissions:
//! - `limits.claude` is always null: Claude plan limits are OAuth server
//!   truth, polled by the app only (statefile deliberately does not
//!   persist them). `claude_hint` says so in-band.
//!
//! # Time basis (the thing that is quietly wrong if you skip it)
//!
//! Minute and hour buckets are UTC; day buckets are LOCAL days keyed at
//! `days.log`'s stored `tz_offset_min` (see `core/history.zig`'s note on
//! time). A day-aligned query therefore answers in the offset the data
//! was WRITTEN at, which may not be the one the caller is standing in —
//! and at a boundary that is the difference between "yesterday" and
//! "today". Every query surface here states its basis: `--format table`
//! prints a `#` header line, `--format json` carries a `query` object
//! with `time_basis` + `tz_offset_min`, and `--format csv|tsv` sends the
//! same line to STDERR so a redirect keeps a clean file (its `bucket_ms`
//! column is already an absolute instant, so the CSV needs no zone to be
//! interpreted).

const std = @import("std");
const native_sdk = @import("native_sdk");
const app_version = @import("app_version");

const types = @import("core/types.zig");
const config = @import("core/config.zig");
const claude = @import("core/claude.zig");
const codex = @import("core/codex.zig");
const opencode = @import("core/opencode.zig");
const snapsource = @import("core/snapsource.zig");
const fleet_mod = @import("core/fleet.zig");
const pricing = @import("core/pricing.zig");
const ledger_mod = @import("core/ledger.zig");
const statefile = @import("core/statefile.zig");
const project_mod = @import("core/project.zig");
const history_mod = @import("core/history.zig");
const trayfmt = @import("core/trayfmt.zig");
const system = @import("core/system/system.zig");

pub const version: []const u8 = app_version.version;

/// Keep the statusline under ~60 visible chars (Claude Code renders it
/// in a single status row; long lines get cropped by narrow terminals).
pub const Mode = enum { json, statusline, help, version, bench };

const top_n = 10;
const max_windows = 4;

/// Burn window for the `--json` snapshot. Long enough to survive a quiet
/// stretch between two turns, short enough to still read as "right now".
const default_burn_window_min: u32 = 15;

// ---------------------------------------------------------------------------
// Entry point (called first thing in main)
// ---------------------------------------------------------------------------

/// Run a CLI mode against stdout and return true (the caller should exit
/// without launching the GUI); return false to let the GUI proceed.
///
/// Dispatch order — and it matters:
///
///  1. A POSITIONAL verb, read from `argv[1]` ONLY, and only when it does
///     not start with `-`. `token-tach export --since 7d` is a query.
///  2. Otherwise the historical flag scan, byte-for-byte unchanged.
///
/// The flag scan deliberately ignores unrecognized flags: the SDK runner
/// owns its own argv surface, and swallowing an unknown flag here would
/// break app launch. The positional path preserves that contract exactly
/// — a leading word that is not a known verb (and any leading flag at
/// all) falls straight through to the old behavior. Anything else, and
/// `token-tach --some-sdk-flag` stops opening the app.
pub fn maybeRunCli(init: std.process.Init) !bool {
    const arena = init.arena.allocator();
    const argv = collectArgv(arena, init.minimal.args) catch &[_][]const u8{};
    // The slice path is the real one; the iterator fallback exists only
    // for the arena-exhausted case, where `--version` should still work.
    const dispatch: Dispatch = if (argv.len > 0)
        dispatchFor(argv)
    else if (detectMode(init.minimal.args)) |m|
        .{ .mode = m }
    else
        .app;
    const verb: ?Verb = switch (dispatch) {
        .verb => |v| v,
        else => null,
    };
    const mode: ?Mode = switch (dispatch) {
        .mode => |m| m,
        else => null,
    };
    switch (dispatch) {
        .app => return false,
        else => {},
    }

    // Heap, not stack: `export` streams thousands of rows and a wider
    // buffer is the difference between one write syscall per row and one
    // per 64 KiB. Falls back to a small stack buffer if the arena is out.
    var small_buf: [4096]u8 = undefined;
    const out_buf: []u8 = arena.alloc(u8, 64 * 1024) catch &small_buf;
    var stdout_writer = std.Io.File.stdout().writer(init.io, out_buf);
    const w = &stdout_writer.interface;
    var err_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &err_buf);
    const ew = &stderr_writer.interface;

    const now_ms = native_sdk.nowMs();
    const env = envFrom(init);

    if (verb) |v| {
        // A bad option is a usage error, not a reason to launch the GUI:
        // argv[1] already committed us to the query path.
        runVerb(init.gpa, arena, init.io, w, ew, env, now_ms, v, argv[2..]) catch |err| {
            w.flush() catch {};
            try ew.print("token-tach {s}: {s}\n", .{ @tagName(v), verbErrorText(err) });
            try ew.flush();
            return true;
        };
        try w.flush();
        try ew.flush();
        return true;
    }

    switch (mode.?) {
        .help => try w.writeAll(help_text),
        .version => try w.print("token-tach {s}\n", .{version}),
        .bench => try runBench(arena, init.io, w, env, now_ms),
        .json, .statusline => {
            // The statusline runs on a per-prompt cadence and renders
            // none of the durable store, so it skips reading it.
            var snap = collectWith(arena, init.io, env, now_ms, .{
                .history = mode.? == .json,
            }) catch emptySnapshot(now_ms);
            if (mode.? == .json) {
                // Live machine telemetry needs a real-time window for its
                // delta-based rates; 150 ms keeps --json interactive. The
                // statusline path skips it entirely (it renders none of
                // this and is called on a tight cadence).
                var sampler = system.Sampler.init();
                snap.system = system.sampleOnce(&sampler, .{}, 150_000);
            }
            switch (mode.?) {
                .json => try writeJson(w, snap),
                .statusline => try writeStatusline(w, snap),
                else => unreachable,
            }
        },
    }
    try w.flush();
    return true;
}

/// Environment facts read from the process environment, in one place so
/// the snapshot path and `--bench` cannot drift apart.
fn envFrom(init: std.process.Init) Env {
    return .{
        .home = init.environ_map.get("HOME") orelse "",
        .claude_config_dir = init.environ_map.get("CLAUDE_CONFIG_DIR"),
        .codex_home = init.environ_map.get("CODEX_HOME"),
        .opencode_db = init.environ_map.get("OPENCODE_DB"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
        .pi_home = init.environ_map.get("PI_HOME"),
        .gemini_cli_home = init.environ_map.get("GEMINI_CLI_HOME"),
        .qwen_runtime_dir = init.environ_map.get("QWEN_RUNTIME_DIR"),
        .qwen_home = init.environ_map.get("QWEN_HOME"),
        .kimi_share_dir = init.environ_map.get("KIMI_SHARE_DIR"),
        .goose_path_root = init.environ_map.get("GOOSE_PATH_ROOT"),
        .kilo_db = init.environ_map.get("KILO_DB"),
        .cline_dir = init.environ_map.get("CLINE_DIR"),
        .cline_data_dir = init.environ_map.get("CLINE_DATA_DIR"),
    };
}

/// What an argv means. `app` is the pass-through that must survive every
/// future addition here: it is what launches the GUI.
pub const Dispatch = union(enum) { verb: Verb, mode: Mode, app };

/// The whole precedence rule, in one pure function so it can be tested
/// without a process.
///
/// A verb is read from `argv[1]` and nowhere else. Scanning the rest for
/// verbs would let `token-tach --some-sdk-flag top` mean something, and
/// a bare word anywhere in an SDK invocation would start hijacking runs.
pub fn dispatchFor(argv: []const []const u8) Dispatch {
    if (argv.len >= 2) {
        if (verbFor(argv[1])) |v| return .{ .verb = v };
    }
    if (argv.len >= 2) {
        for (argv[1..]) |arg| {
            if (modeForFlag(arg)) |m| return .{ .mode = m };
        }
    }
    return .app;
}

fn collectArgv(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(args);
    while (it.next()) |arg| try out.append(arena, arg);
    return out.toOwnedSlice(arena);
}

fn detectMode(args: std.process.Args) ?Mode {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| {
        if (modeForFlag(arg)) |mode| return mode;
    }
    return null;
}

/// The flag → mode mapping (pure, testable). First recognized flag wins.
pub fn modeForFlag(arg: []const u8) ?Mode {
    const map = .{
        .{ "--json", Mode.json },
        .{ "--statusline", Mode.statusline },
        .{ "--help", Mode.help },
        .{ "-h", Mode.help },
        .{ "--version", Mode.version },
        .{ "-v", Mode.version },
        .{ "--bench", Mode.bench },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, arg, entry[0])) return entry[1];
    }
    return null;
}

/// The positional query verbs. Names are the wire surface; `@"export"`
/// is spelled that way so `@tagName` still prints `export`.
pub const Verb = enum { history, burn, top, sessions, @"export", doctor };

/// argv[1] → verb (pure, testable). Anything starting with `-` is a flag
/// and is NOT a verb, no matter what follows the dash — that is the rule
/// that keeps the SDK runner's argv intact.
pub fn verbFor(arg: []const u8) ?Verb {
    if (arg.len == 0 or arg[0] == '-') return null;
    inline for (@typeInfo(Verb).@"enum".fields) |field| {
        if (std.mem.eql(u8, arg, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

const help_text =
    \\token-tach — menu-bar tachometer for AI coding-agent token usage
    \\
    \\USAGE
    \\  token-tach                launch the menu-bar app (default)
    \\  token-tach --json         print a usage/limits snapshot as JSON, exit
    \\  token-tach --statusline   print a one-line summary (statusline-ready)
    \\  token-tach --bench        time one collection pass, print JSON, exit
    \\  token-tach --version      print the version, exit
    \\  token-tach --help         show this help
    \\
    \\QUERY VERBS (durable time series, read-only)
    \\  token-tach history  [--since 7d|2026-06-01] [--until now] [--bucket minute|hour|day]
    \\                      [--group agent,model,project,session,bucket]
    \\                      [--agent claude,codex] [--project P] [--model M] [--session S]
    \\                      [--format json|csv|tsv|table]
    \\  token-tach burn     [--at <iso|epoch-ms>|--now] [--window 15m]
    \\  token-tach top      --dim project|model|session|agent [--since ..] [-n 20]
    \\  token-tach sessions [--since 30d] [--project P] [--agent A] [-n 20]
    \\  token-tach export   --format csv [--since ..] [--bucket hour]
    \\  token-tach doctor   --history
    \\
    \\  --since/--until accept a relative age (90m, 36h, 7d, 4w), an ISO-8601
    \\  date or timestamp (2026-06-01, 2026-06-01T12:00:00Z), a bare epoch-ms
    \\  integer, or `now`. Minute and hour buckets are UTC; day buckets are
    \\  LOCAL days keyed at the offset days.log was written with. Every query
    \\  states which basis it used — table/json inline, csv/tsv on stderr.
    \\
    \\  `export` is the archival seam: one stable CSV schema
    \\  (bucket_ms,agent,model,project,session,input,output,cache_creation,
    \\  cache_read,cost_usd,events,covered,synthetic) whose bucket_ms is an
    \\  absolute instant, so no zone is needed to read it back.
    \\
    \\The CLI reads the same local data as the app (Claude Code/Codex
    \\JSONL and OpenCode SQLite plus saved state) and never writes, polls,
    \\or touches the keychain. It opens the history store as a reader only:
    \\it never takes the write lock and never compacts. See docs/CLI.md for
    \\the JSON schema and a Claude Code statusline recipe.
    \\
;

// ---------------------------------------------------------------------------
// Snapshot collection
// ---------------------------------------------------------------------------

/// Environment facts, mirroring engine.Env (not imported: cli must not
/// depend on the UI-side engine module).
pub const Env = struct {
    home: []const u8 = "",
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    opencode_db: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    pi_home: ?[]const u8 = null,
    gemini_cli_home: ?[]const u8 = null,
    qwen_runtime_dir: ?[]const u8 = null,
    qwen_home: ?[]const u8 = null,
    kimi_share_dir: ?[]const u8 = null,
    goose_path_root: ?[]const u8 = null,
    kilo_db: ?[]const u8 = null,
    cline_dir: ?[]const u8 = null,
    cline_data_dir: ?[]const u8 = null,
};

/// One (model|project, totals) rollup row.
pub const Entry = struct {
    name: []const u8,
    totals: ledger_mod.Totals,
};

/// Everything the renderers need. All slices point into the arena that
/// was passed to `collect`; the snapshot has no deinit of its own.
pub const Snapshot = struct {
    generated_at_ms: i64,
    /// Minutes east of UTC the day buckets were computed with (restored
    /// from the state file; 0 = UTC when no state exists yet).
    tz_offset_min: i32 = 0,
    state: statefile.RestoreOutcome = .absent,
    today: ledger_mod.Totals = .{},
    month: ledger_mod.Totals = .{},
    all: ledger_mod.Totals = .{},
    /// Per-agent all-time rollup, one slot per Agent member.
    per_agent: std.EnumArray(types.Agent, ledger_mod.Totals) = .initFill(.{}),
    /// Source coverage: is the source enabled in config, and did its
    /// data location resolve/exist on this machine (tt-hr8 "clear
    /// coverage status"). `detected == null` means not probed.
    coverage: std.EnumArray(types.Agent, Coverage) = .initFill(.{}),
    codex_limits: ?types.LimitSnapshot = null,
    models: []const Entry = &.{},
    projects: []const Entry = &.{},
    /// Live machine telemetry (--json only; sampled at invocation, not
    /// read from state). Empty for --statusline.
    system: system.Snapshot = .{},
    /// The durable time series (`core/history.zig`). Absent — every field
    /// at its default, `available = false` — when the store has not been
    /// created yet or could not be read.
    history: HistoryInfo = .{},
    /// Per-agent today/month, which the ledger's agent-blended per-day
    /// rollup cannot produce. Sourced from `days.log`, so these are LOCAL
    /// days keyed at `history.day_tz_offset_min`, which is the offset the
    /// app was running at when it wrote them — not necessarily the one
    /// this process is standing in.
    today_by_agent: std.EnumArray(types.Agent, ledger_mod.Totals) = .initFill(.{}),
    month_by_agent: std.EnumArray(types.Agent, ledger_mod.Totals) = .initFill(.{}),
};

/// One agent's collection status.
pub const Coverage = struct {
    enabled: bool = false,
    detected: ?bool = null,
    /// First/last UTC hour this agent appears in `hours.log`, as the
    /// bucket's START instant. Hour resolution, not event resolution:
    /// the durable record keeps buckets, not timestamps. Null means the
    /// store has never seen this agent.
    first_seen_ms: ?i64 = null,
    last_seen_ms: ?i64 = null,
};

/// What `--json`'s `history` object reports. `records` and `bytes` are
/// PHYSICAL: one event contributes a row to each of the three tiers, and
/// additive duplicates are counted individually, so this is store size,
/// never an event count.
pub const HistoryInfo = struct {
    available: bool = false,
    /// Distinct minute buckets currently in the hot ring (its 48 h reach
    /// minus whatever was idle), not the number of records in it.
    hot_minutes: u32 = 0,
    first_ms: ?i64 = null,
    last_ms: ?i64 = null,
    records: u64 = 0,
    bytes: u64 = 0,
    /// The statefile's one-time backfill gate: has the durable store been
    /// seeded from the full transcript history yet?
    backfilled: bool = false,
    /// Tokens per minute over the last `burn_window_min` minutes of the
    /// hot ring. Null when the ring holds nothing in that window — an
    /// honest "no idea", distinct from a real zero.
    burn_tokens_per_min: ?f64 = null,
    burn_cost_per_min: ?f64 = null,
    burn_window_min: u32 = default_burn_window_min,
    /// The offset `days.log`'s keys were computed with.
    day_tz_offset_min: i32 = 0,
};

pub fn emptySnapshot(now_ms: i64) Snapshot {
    return .{ .generated_at_ms = now_ms };
}

pub const CollectOptions = struct {
    /// Read the durable store (burn, extents, per-agent splits). The
    /// statusline turns it off: it renders none of that and is invoked
    /// once per prompt render, where a handful of extra file reads is a
    /// cost with no matching benefit.
    history: bool = true,
};

/// Build the snapshot: config → restore → one sweep → rollups. Read-only
/// on every file it touches. `arena` must be an arena allocator (nothing
/// allocated here is individually freed) and owns every slice in the
/// returned snapshot. Only allocation failure propagates.
pub fn collect(arena: std.mem.Allocator, io: std.Io, env: Env, now_ms: i64) !Snapshot {
    return collectWith(arena, io, env, now_ms, .{});
}

pub fn collectWith(
    arena: std.mem.Allocator,
    io: std.Io,
    env: Env,
    now_ms: i64,
    opts: CollectOptions,
) !Snapshot {
    var snap = emptySnapshot(now_ms);
    var backfill: statefile.Backfill = .{};

    // Config: same file the app reads; absent/bad config keeps defaults.
    var cfg: config.Config = .{};
    if (config.defaultPath(arena, env.home)) |config_path| {
        if (config.load(arena, config_path) catch null) |result| cfg = result.config;
    } else |_| {}

    // Roots, resolved exactly like engine.setup.
    const claude_roots: []const []const u8 = if (cfg.claude_config_dirs.len > 0)
        try appendProjects(arena, cfg.claude_config_dirs)
    else
        try claude.discoverRoots(arena, io, env.claude_config_dir, env.home);
    const codex_env: ?[]const u8 = if (cfg.codex_home.len > 0) cfg.codex_home else env.codex_home;
    const codex_roots = try codex.sessionsDirs(arena, codex_env, env.home);
    const opencode_path = try opencode.resolvePath(arena, cfg.opencode_db, env.opencode_db, env.xdg_data_home, env.home);

    var claude_tailer = claude.Tailer.init(arena);
    var codex_tailer = codex.Tailer.init(arena);
    var opencode_poller = opencode.Poller.init(arena);
    var ledger = ledger_mod.Ledger.init(arena, 0);
    // The tt-hr8 collector fleet, resolved exactly like engine.setup. A
    // failed build degrades to core-agents-only (never crash the CLI).
    const fleet_env = fleet_mod.Env{
        .home = env.home,
        .pi_home = env.pi_home,
        .gemini_cli_home = env.gemini_cli_home,
        .qwen_runtime_dir = env.qwen_runtime_dir,
        .qwen_home = env.qwen_home,
        .kimi_share_dir = env.kimi_share_dir,
        .goose_path_root = env.goose_path_root,
        .xdg_data_home = env.xdg_data_home,
        .kilo_db = env.kilo_db,
        .cline_dir = env.cline_dir,
        .cline_data_dir = env.cline_data_dir,
    };
    var fl: ?fleet_mod.Fleet = fleet_mod.Fleet.init(arena, fleet_env) catch null;
    var fleet_ptr: ?*fleet_mod.Fleet = null;
    if (fl) |*f| fleet_ptr = f;

    // Same cwd -> repository rollup the app applies at ingest, so
    // `--json`'s project table and the app's PROJECTS panel agree. Arena
    // allocated: this process exits after one snapshot.
    var projects = project_mod.Resolver.init(arena, env.home);
    const rooted = struct {
        fn f(r: *project_mod.Resolver, ev: types.UsageEvent) types.UsageEvent {
            if (ev.cwd.len == 0) return ev;
            var out = ev;
            out.project_root = r.rootFor(ev.cwd);
            return out;
        }
    }.f;

    // Warm path: restore offsets + rollups so the sweep below only reads
    // appended bytes. READ-ONLY — this module never calls statefile.save,
    // so it cannot corrupt the app's state or race a running instance.
    if (statefile.defaultPath(arena, env.xdg_state_home, env.home) catch null) |state_path| {
        snap.state = try statefile.restoreWith(arena, io, state_path, &claude_tailer, &codex_tailer, &opencode_poller, fleet_ptr, &ledger, &backfill);
        if (snap.state == .restored) {
            // Fold the restored PROJECTS keys onto repository roots, the
            // same way engine.setup does, so the CLI and the app never
            // disagree about what a project is.
            ledger.rekeyProjects(&projects) catch {};
        }
        if (snap.state == .invalid) {
            // Restore guarantees pristine args on .invalid, but stay in
            // lockstep with engine.setup's belt-and-suspenders reinit.
            claude_tailer = claude.Tailer.init(arena);
            codex_tailer = codex.Tailer.init(arena);
            opencode_poller = opencode.Poller.init(arena);
            ledger = ledger_mod.Ledger.init(arena, 0);
            fl = fleet_mod.Fleet.init(arena, fleet_env) catch null;
            fleet_ptr = null;
            if (fl) |*f| fleet_ptr = f;
        }
    }

    var prices: ?pricing.Db = pricing.Db.init(arena) catch null;

    // ONE incremental sweep per enabled source: appended bytes on the warm
    // path, full history on the cold path. Sweep errors degrade to
    // whatever was restored; they never fail the snapshot.
    if (cfg.sources.enabled(.claude)) {
        var sink = claude.ListSink.init(arena);
        _ = claude_tailer.sweepIncremental(arena, io, claude_roots, sink.sink(), now_ms) catch false;
        for (sink.events.items) |raw| {
            const ev = rooted(&projects, raw);
            ledger.add(ev, if (prices) |*db| db.costOf(ev) else null) catch {};
        }
    }
    if (cfg.sources.enabled(.codex)) {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        _ = codex_tailer.sweepIncremental(io, arena, codex_roots, &events, now_ms) catch false;
        for (events.items) |raw| {
            const ev = rooted(&projects, raw);
            ledger.add(ev, if (prices) |*db| db.costOf(ev) else null) catch {};
        }
        // Limits ride the tailer: restored from the state file and/or
        // refreshed by token_count lines the sweep just parsed.
        snap.codex_limits = try dupeLimits(arena, codex_tailer.lastLimits());
    }
    if (cfg.sources.enabled(.opencode)) {
        var changes: std.ArrayList(opencode.Change) = .empty;
        opencode_poller.poll(arena, opencode_path, &changes) catch {};
        for (changes.items) |change| {
            const current = rooted(&projects, change.current);
            const new_cost = if (prices) |*db| db.costOf(current) else null;
            if (change.previous) |old_raw| {
                const old = rooted(&projects, old_raw);
                ledger.replace(old, if (prices) |*db| db.costOf(old) else null, current, new_cost) catch {};
            } else ledger.add(current, new_cost) catch {};
        }
    }
    // Collector fleet: one sweep over every enabled fleet source (its
    // internal error handling means a broken source degrades quietly).
    if (fleet_ptr) |f| {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        var changes: std.ArrayList(snapsource.Change) = .empty;
        f.sweep(arena, io, cfg.sources, now_ms, &events, &changes);
        for (events.items) |raw| {
            const ev = rooted(&projects, raw);
            ledger.add(ev, if (prices) |*db| db.costOf(ev) else null) catch {};
        }
        for (changes.items) |change| {
            const current = rooted(&projects, change.current);
            const new_cost = if (prices) |*db| db.costOf(current) else null;
            if (change.previous) |old_raw| {
                const old = rooted(&projects, old_raw);
                ledger.replace(old, if (prices) |*db| db.costOf(old) else null, current, new_cost) catch {};
            } else ledger.add(current, new_cost) catch {};
        }
    }

    snap.tz_offset_min = ledger.tz_offset_min;
    snap.today = ledger.today(now_ms);
    snap.month = monthTotals(&ledger, now_ms);
    snap.all = ledger.all;
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        snap.per_agent.set(agent, ledger.forAgent(agent));
        snap.coverage.set(agent, .{ .enabled = cfg.sources.enabled(agent) });
    }
    snap.coverage.getPtr(.claude).detected = claude_roots.len > 0;
    snap.coverage.getPtr(.codex).detected = codex_roots.len > 0;
    snap.coverage.getPtr(.opencode).detected = opencode_path.len > 0;
    // Fleet agents: did the source's data location exist on this
    // machine? (Null stays for agents the fleet does not own.)
    if (fleet_ptr) |f| {
        inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
            const agent: types.Agent = @enumFromInt(field.value);
            if (f.detected(agent)) |d| snap.coverage.getPtr(agent).detected = d;
        }
    }
    snap.models = try topEntries(arena, ledger.per_model.keys(), ledger.per_model.values());
    snap.projects = try topEntries(arena, ledger.per_project.keys(), ledger.per_project.values());
    if (opts.history) {
        snap.history.backfilled = backfill.backfilled;
        readHistoryInto(arena, io, env, now_ms, &snap) catch {};
    }
    return snap;
}

/// Fold the durable store into the snapshot: burn, extents, per-agent
/// first/last, and the today/month agent splits.
///
/// READER ONLY (see the module doc). Any failure leaves the defaults —
/// a store that cannot be read must not be able to fail a snapshot that
/// is otherwise complete.
fn readHistoryInto(
    arena: std.mem.Allocator,
    io: std.Io,
    env: Env,
    now_ms: i64,
    snap: *Snapshot,
) !void {
    const dir = try history_mod.defaultDir(arena, env.xdg_state_home, env.home);
    var reader = try history_mod.Reader.open(arena, io, dir);
    defer reader.deinit();

    const ext = reader.extent() catch history_mod.Extents{};
    snap.history.available = ext.minute.present or ext.hour.present or ext.day.present;
    if (!snap.history.available) return;
    snap.history.day_tz_offset_min = ext.day.tz_offset_min;

    inline for (.{ history_mod.Tier.minute, .hour, .day }) |tier| {
        const e = ext.get(tier);
        snap.history.records += e.records;
        snap.history.bytes += e.bytes;
        if (e.first_bucket) |b| {
            const ms = bucketStartMs(tier, b, e.tz_offset_min);
            if (snap.history.first_ms == null or ms < snap.history.first_ms.?) snap.history.first_ms = ms;
        }
        if (e.last_bucket) |b| {
            const ms = bucketStartMs(tier, b, e.tz_offset_min);
            if (snap.history.last_ms == null or ms > snap.history.last_ms.?) snap.history.last_ms = ms;
        }
    }

    // ONE scan of the hot ring answers both questions. `burnAt` would
    // re-read the same 4 MiB for the second, and the arithmetic below is
    // its definition verbatim: the inclusive window of minute buckets
    // ending at `now`, divided by the window length (not by the number of
    // buckets that happened to have data — an idle minute is a real zero
    // and must drag the rate down).
    const minutes = reader.series(arena, .minute, 0, std.math.maxInt(u32), .none) catch &[_]history_mod.Row{};
    snap.history.hot_minutes = @intCast(@min(minutes.len, std.math.maxInt(u32)));
    if (minutes.len > 0) {
        const win = default_burn_window_min;
        const end = history_mod.minuteBucket(now_ms);
        const start = if (end >= win - 1) end - (win - 1) else 0;
        var totals = ledger_mod.Totals{};
        for (minutes) |row| {
            if (row.bucket < start or row.bucket > end) continue;
            totals.input_tokens += row.totals.input_tokens;
            totals.output_tokens += row.totals.output_tokens;
            totals.cache_creation_tokens += row.totals.cache_creation_tokens;
            totals.cache_read_tokens += row.totals.cache_read_tokens;
            totals.cost_usd += row.totals.cost_usd;
            totals.events += row.totals.events;
        }
        const span: f64 = @floatFromInt(win);
        snap.history.burn_tokens_per_min = @as(f64, @floatFromInt(totals.totalTokens())) / span;
        snap.history.burn_cost_per_min = totals.cost_usd / span;
    }

    // Per-agent first/last from hours.log: UTC, forever, and one bucket
    // wide — fine enough to answer "when did this tool last run" without
    // pretending the store kept timestamps it did not.
    const hours = reader.query(arena, .hour, .{}, .{ .agent = true, .bucket = true }) catch &[_]history_mod.Row{};
    for (hours) |row| {
        const agent = types.Agent.fromStorageId(row.agent) orelse continue;
        const ms = bucketStartMs(.hour, row.bucket, 0);
        const cov = snap.coverage.getPtr(agent);
        if (cov.first_seen_ms == null or ms < cov.first_seen_ms.?) cov.first_seen_ms = ms;
        if (cov.last_seen_ms == null or ms > cov.last_seen_ms.?) cov.last_seen_ms = ms;
    }

    // Today/month per agent from days.log. These are the store's LOCAL
    // day keys, so `snap.today` (ledger, keyed at the restored tz) and
    // this split agree exactly whenever the two offsets match — and when
    // they don't, `history.day_tz_offset_min` says so rather than the
    // numbers quietly disagreeing at the boundary.
    const tz = ext.day.tz_offset_min;
    const today_key = history_mod.dayBucket(now_ms, tz);
    const this_month = yearMonthOfDay(today_key);
    const days = reader.query(arena, .day, .{}, .{ .agent = true, .bucket = true }) catch &[_]history_mod.Row{};
    for (days) |row| {
        const agent = types.Agent.fromStorageId(row.agent) orelse continue;
        if (row.bucket == today_key) addTotals(snap.today_by_agent.getPtr(agent), row.totals);
        if (yearMonthOfDay(row.bucket) == this_month) addTotals(snap.month_by_agent.getPtr(agent), row.totals);
    }
}

fn addTotals(dst: *ledger_mod.Totals, src: ledger_mod.Totals) void {
    dst.input_tokens += src.input_tokens;
    dst.output_tokens += src.output_tokens;
    dst.cache_creation_tokens += src.cache_creation_tokens;
    dst.cache_read_tokens += src.cache_read_tokens;
    dst.cost_usd += src.cost_usd;
    dst.events += src.events;
}

/// A bucket index → the UTC instant the bucket STARTS at. Mirrors
/// `history.zig`'s private `bucketStartMs`; kept in step by the
/// round-trip test at the bottom of this file.
pub fn bucketStartMs(tier: history_mod.Tier, bucket: u32, tz_offset_min: i32) i64 {
    const b: i64 = bucket;
    return switch (tier) {
        .minute => b * 60_000,
        .hour => b * 3_600_000,
        .day => b * 86_400_000 - @as(i64, tz_offset_min) * 60_000,
    };
}

/// Copy a limits reading into the arena.
///
/// `Tailer.lastLimits` hands back `windows` as a slice of a FIXED ARRAY
/// INSIDE the tailer, and every tailer in `collect` is a stack local —
/// so the snapshot's window slice dangles the instant `collect` returns.
/// It read correctly for as long as nothing else disturbed that stack
/// slot, which is the worst way for a bug like this to behave. The plan
/// string really is arena-owned and needs no copy.
fn dupeLimits(arena: std.mem.Allocator, limits: ?types.LimitSnapshot) !?types.LimitSnapshot {
    const l = limits orelse return null;
    var out = l;
    out.windows = try arena.dupe(types.LimitWindow, l.windows);
    return out;
}

/// config `claude-config-dir` entries are config roots; transcripts live
/// under `<root>/projects` (mirrors engine.setup's private helper).
fn appendProjects(arena: std.mem.Allocator, dirs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (dirs) |d| {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/projects", .{d}));
    }
    return try out.toOwnedSlice(arena);
}

/// Sum of the current local month's day buckets.
fn monthTotals(ledger: *const ledger_mod.Ledger, now_ms: i64) ledger_mod.Totals {
    const this_month = yearMonthOfDay(ledger_mod.dayKey(now_ms, ledger.tz_offset_min));
    var totals = ledger_mod.Totals{};
    var it = ledger.per_day.iterator();
    while (it.next()) |entry| {
        if (yearMonthOfDay(entry.key_ptr.*) != this_month) continue;
        const t = entry.value_ptr.*;
        totals.input_tokens += t.input_tokens;
        totals.output_tokens += t.output_tokens;
        totals.cache_creation_tokens += t.cache_creation_tokens;
        totals.cache_read_tokens += t.cache_read_tokens;
        totals.cost_usd += t.cost_usd;
        totals.events += t.events;
    }
    return totals;
}

/// Civil (year*12 + month-1) for a days-since-epoch key — Howard
/// Hinnant's civil_from_days, reduced to the year-month we bucket by.
pub fn yearMonthOfDay(day: i64) i64 {
    const z = day + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153); // Mar=0 .. Feb=11
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const year = if (m <= 2) y + 1 else y;
    return year * 12 + (m - 1);
}

/// The `n` biggest rollups by cost (then tokens, then name — total order,
/// so output is stable across runs).
fn topEntries(
    arena: std.mem.Allocator,
    keys: []const []const u8,
    values: []const ledger_mod.Totals,
) ![]const Entry {
    var entries = try arena.alloc(Entry, keys.len);
    for (keys, values, 0..) |key, totals, i| {
        entries[i] = .{ .name = key, .totals = totals };
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.totals.cost_usd != b.totals.cost_usd) return a.totals.cost_usd > b.totals.cost_usd;
            if (a.totals.totalTokens() != b.totals.totalTokens()) return a.totals.totalTokens() > b.totals.totalTokens();
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return entries[0..@min(entries.len, top_n)];
}

// ---------------------------------------------------------------------------
// JSON rendering
// ---------------------------------------------------------------------------

const JsonTotals = struct {
    cost_usd: f64,
    tokens: u64,
    input: u64,
    output: u64,
    cache_creation: u64,
    cache_read: u64,
    events: u64,
};

/// `today` / `month`: the ledger's blended totals plus the per-agent
/// split `days.log` can now answer. `by_agent` is a field ADDITION to an
/// existing object, which the stability note below makes non-breaking.
const JsonPeriod = struct {
    cost_usd: f64,
    tokens: u64,
    input: u64,
    output: u64,
    cache_creation: u64,
    cache_read: u64,
    events: u64,
    /// Null when the durable store was not read (`--statusline`) or does
    /// not exist yet — deliberately NOT an all-zero split, which would
    /// read as "no agent spent anything today".
    by_agent: ?JsonByAgent,
};

/// The durable store's shape and reach — see `HistoryInfo`.
const JsonHistory = struct {
    available: bool,
    hot_minutes: u32,
    first_ms: ?i64,
    last_ms: ?i64,
    records: u64,
    bytes: u64,
    backfilled: bool,
    burn_window_min: u32,
    burn_cost_per_min: ?f64,
    day_tz_offset_min: i32,
};

const JsonWindow = struct {
    kind: []const u8,
    used_percent: f64,
    resets_at_ms: ?i64,
};

const JsonLimits = struct {
    plan: []const u8,
    read_at_ms: i64,
    windows: []const JsonWindow,
};

const JsonKeyed = struct {
    name: []const u8,
    cost_usd: f64,
    tokens: u64,
    events: u64,
};

/// The stable `--json` schema. Field additions are non-breaking; renames
/// and removals are breaking and require a docs/CLI.md version note.
const JsonOut = struct {
    version: []const u8,
    generated_at_ms: i64,
    tz_offset_min: i32,
    note: ?[]const u8,
    today: JsonPeriod,
    month: JsonPeriod,
    all_time: struct {
        cost_usd: f64,
        tokens: u64,
        events: u64,
        by_agent: JsonByAgent,
    },
    /// Source coverage (tt-hr8): every known agent, whether its source
    /// is enabled, whether its data location exists on this machine
    /// (null = not probed), and how many events it has contributed.
    coverage: []const JsonCoverage,
    /// Tokens per minute over the last `history.burn_window_min` minutes
    /// of the hot ring. Null when the store is unreadable or holds
    /// nothing in that window — not the same claim as zero.
    burn_tokens_per_min: ?f64,
    /// The durable time series behind `burn_tokens_per_min` and the
    /// `by_agent` splits.
    history: JsonHistory,
    limits: struct {
        codex: ?JsonLimits,
        /// Always null in v1 (OAuth server truth is app-only).
        claude: ?JsonLimits,
        claude_hint: []const u8,
    },
    models: []const JsonKeyed,
    projects: []const JsonKeyed,
    system: JsonSystem,
};

/// Live machine telemetry, sampled at invocation over a ~150 ms window.
/// A null module means unavailable on this machine (no battery, no
/// accelerator). Fractions are 0..1.
const JsonSystem = struct {
    cpu: ?struct { utilization: f64, cores: u32, load_avg_1m: f64 },
    gpu: ?struct { utilization: f64 },
    mem: ?struct { used_bytes: u64, total_bytes: u64, used_fraction: f64, pressure: []const u8 },
    disk: ?struct { total_bytes: u64, free_bytes: u64, used_fraction: f64, read_bytes_per_sec: ?u64, write_bytes_per_sec: ?u64 },
    net: ?struct { rx_bytes_per_sec: ?u64, tx_bytes_per_sec: ?u64 },
    battery: ?struct { charge: f64, charging: bool, on_ac: bool },
};

fn jsonSystem(snap: system.Snapshot) JsonSystem {
    return .{
        .cpu = if (snap.cpu) |s| .{
            .utilization = roundFrac(s.total_frac),
            .cores = s.core_count,
            .load_avg_1m = roundFrac(s.load_avg_1m),
        } else null,
        .gpu = if (snap.gpu) |s| .{ .utilization = roundFrac(s.device_utilization) } else null,
        .mem = if (snap.mem) |s| .{
            .used_bytes = s.used_bytes,
            .total_bytes = s.total_bytes,
            .used_fraction = roundFrac(s.used_frac),
            .pressure = @tagName(s.pressure),
        } else null,
        .disk = if (snap.disk) |s| .{
            .total_bytes = s.total_bytes,
            .free_bytes = s.free_bytes,
            .used_fraction = roundFrac(s.used_fraction),
            .read_bytes_per_sec = bpsInt(s.read_bytes_per_sec),
            .write_bytes_per_sec = bpsInt(s.write_bytes_per_sec),
        } else null,
        .net = if (snap.net) |s| .{
            .rx_bytes_per_sec = bpsInt(s.in_bytes_per_sec),
            .tx_bytes_per_sec = bpsInt(s.out_bytes_per_sec),
        } else null,
        .battery = if (snap.battery) |s| .{
            .charge = roundFrac(s.charge),
            .charging = s.charging,
            .on_ac = s.on_ac,
        } else null,
    };
}

/// Fractions round to 3 decimals for the same legibility reason costs
/// round to micro-dollars.
fn roundFrac(v: f64) f64 {
    return @round(v * 1_000) / 1_000;
}

fn bpsInt(v: ?f64) ?u64 {
    const rate = v orelse return null;
    return @intFromFloat(@max(rate, 0));
}

/// One JsonTotals field per Agent member, keyed by the enum tag name.
/// Zig 0.16 removed struct reification, so the list is spelled out; the
/// comptime block below fails the build the moment types.Agent gains a
/// member this struct lacks (or vice versa).
const JsonByAgent = struct {
    claude: JsonTotals,
    codex: JsonTotals,
    opencode: JsonTotals,
    pi: JsonTotals,
    gemini: JsonTotals,
    qwen: JsonTotals,
    kimi: JsonTotals,
    goose: JsonTotals,
    kilo: JsonTotals,
    cline: JsonTotals,
    roo: JsonTotals,
    copilot: JsonTotals,
    continue_cli: JsonTotals,
    droid: JsonTotals,
};

comptime {
    const agent_fields = @typeInfo(types.Agent).@"enum".fields;
    if (agent_fields.len != @typeInfo(JsonByAgent).@"struct".fields.len)
        @compileError("JsonByAgent is out of sync with types.Agent");
    for (agent_fields) |f| {
        if (!@hasField(JsonByAgent, f.name))
            @compileError("JsonByAgent missing agent field: " ++ f.name);
    }
}

const JsonCoverage = struct {
    agent: []const u8,
    enabled: bool,
    detected: ?bool,
    events: u64,
    /// UTC hour-bucket starts from `hours.log` (null = never seen).
    first_seen_ms: ?i64,
    last_seen_ms: ?i64,
};

fn jsonTotals(t: ledger_mod.Totals) JsonTotals {
    return .{
        .cost_usd = roundUsd(t.cost_usd),
        .tokens = t.totalTokens(),
        .input = t.input_tokens,
        .output = t.output_tokens,
        .cache_creation = t.cache_creation_tokens,
        .cache_read = t.cache_read_tokens,
        .events = t.events,
    };
}

fn jsonPeriod(t: ledger_mod.Totals, by_agent: ?JsonByAgent) JsonPeriod {
    return .{
        .cost_usd = roundUsd(t.cost_usd),
        .tokens = t.totalTokens(),
        .input = t.input_tokens,
        .output = t.output_tokens,
        .cache_creation = t.cache_creation_tokens,
        .cache_read = t.cache_read_tokens,
        .events = t.events,
        .by_agent = by_agent,
    };
}

fn jsonByAgent(totals: std.EnumArray(types.Agent, ledger_mod.Totals)) JsonByAgent {
    var out: JsonByAgent = undefined;
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        @field(out, field.name) = jsonTotals(totals.get(agent));
    }
    return out;
}

/// Costs round to micro-dollars so the JSON stays legible (f64 shortest-
/// print would otherwise leak 114.23000000000002-style noise).
fn roundUsd(v: f64) f64 {
    return @round(v * 1_000_000) / 1_000_000;
}

fn windowKindName(kind: types.LimitWindow.Kind) []const u8 {
    return switch (kind) {
        .five_hour => "five_hour",
        .weekly => "weekly",
        .weekly_opus => "weekly_opus",
        .weekly_sonnet => "weekly_sonnet",
        .monthly => "monthly",
    };
}

fn noteFor(snap: Snapshot) ?[]const u8 {
    switch (snap.state) {
        .restored => return null,
        .absent, .invalid => {
            if (snap.all.events == 0)
                return "no usage data found yet — launch the app once (or start a claude/codex session)";
            return "cold scan — no saved app state; launch the app once to make this snapshot instant";
        },
    }
}

pub fn writeJson(w: *std.Io.Writer, snap: Snapshot) !void {
    var window_buf: [max_windows]JsonWindow = undefined;
    const codex_limits: ?JsonLimits = if (snap.codex_limits) |limits| blk: {
        const n = @min(limits.windows.len, max_windows);
        for (limits.windows[0..n], 0..) |win, i| {
            window_buf[i] = .{
                .kind = windowKindName(win.kind),
                .used_percent = win.used_percent,
                .resets_at_ms = if (win.resets_at_ms > 0) win.resets_at_ms else null,
            };
        }
        break :blk .{
            .plan = limits.plan,
            .read_at_ms = limits.read_at_ms,
            .windows = window_buf[0..n],
        };
    } else null;

    var model_buf: [top_n]JsonKeyed = undefined;
    var project_buf: [top_n]JsonKeyed = undefined;
    const models = fillKeyed(&model_buf, snap.models);
    const projects = fillKeyed(&project_buf, snap.projects);

    const agent_count = @typeInfo(types.Agent).@"enum".fields.len;
    var by_agent: JsonByAgent = undefined;
    var coverage_buf: [agent_count]JsonCoverage = undefined;
    inline for (@typeInfo(types.Agent).@"enum".fields, 0..) |field, i| {
        const agent: types.Agent = @enumFromInt(field.value);
        const totals = snap.per_agent.get(agent);
        @field(by_agent, field.name) = jsonTotals(totals);
        const cov = snap.coverage.get(agent);
        coverage_buf[i] = .{
            .agent = agent.label(),
            .enabled = cov.enabled,
            .detected = cov.detected,
            .events = totals.events,
            .first_seen_ms = cov.first_seen_ms,
            .last_seen_ms = cov.last_seen_ms,
        };
    }

    const split: ?JsonByAgent = if (snap.history.available) jsonByAgent(snap.today_by_agent) else null;
    const month_split: ?JsonByAgent = if (snap.history.available) jsonByAgent(snap.month_by_agent) else null;

    const out = JsonOut{
        .version = version,
        .generated_at_ms = snap.generated_at_ms,
        .tz_offset_min = snap.tz_offset_min,
        .note = noteFor(snap),
        .today = jsonPeriod(snap.today, split),
        .month = jsonPeriod(snap.month, month_split),
        .all_time = .{
            .cost_usd = roundUsd(snap.all.cost_usd),
            .tokens = snap.all.totalTokens(),
            .events = snap.all.events,
            .by_agent = by_agent,
        },
        .burn_tokens_per_min = if (snap.history.burn_tokens_per_min) |v| roundFrac(v) else null,
        .history = .{
            .available = snap.history.available,
            .hot_minutes = snap.history.hot_minutes,
            .first_ms = snap.history.first_ms,
            .last_ms = snap.history.last_ms,
            .records = snap.history.records,
            .bytes = snap.history.bytes,
            .backfilled = snap.history.backfilled,
            .burn_window_min = snap.history.burn_window_min,
            .burn_cost_per_min = if (snap.history.burn_cost_per_min) |v| roundUsd(v) else null,
            .day_tz_offset_min = snap.history.day_tz_offset_min,
        },
        .limits = .{
            .codex = codex_limits,
            .claude = null,
            .claude_hint = "claude plan limits are OAuth server truth — run the app (claude-oauth = true) to see them",
        },
        .models = models,
        .projects = projects,
        .coverage = &coverage_buf,
        .system = jsonSystem(snap.system),
    };
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

fn fillKeyed(buf: []JsonKeyed, entries: []const Entry) []const JsonKeyed {
    const n = @min(entries.len, buf.len);
    for (entries[0..n], 0..) |entry, i| {
        buf[i] = .{
            .name = entry.name,
            .cost_usd = roundUsd(entry.totals.cost_usd),
            .tokens = entry.totals.totalTokens(),
            .events = entry.totals.events,
        };
    }
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Statusline rendering
// ---------------------------------------------------------------------------

/// One compact line for a Claude Code statusline (JSON session data on
/// stdin is deliberately ignored — this tach reports machine-wide usage,
/// not the calling session). Target: under ~60 visible characters.
///   ⚡ tach · today $114.23 · cdx 5h 14% wk 4%
pub fn writeStatusline(w: *std.Io.Writer, snap: Snapshot) !void {
    if (snap.all.events == 0 and snap.codex_limits == null) {
        try w.writeAll("⚡ tach · no data — launch the app once\n");
        return;
    }
    try w.writeAll("⚡ tach · today ");
    try trayfmt.writeCost(w, snap.today.cost_usd);
    if (snap.codex_limits) |limits| {
        if (limits.windows.len > 0) {
            try w.writeAll(" · cdx");
            for (limits.windows) |win| {
                const label: []const u8 = switch (win.kind) {
                    .five_hour => " 5h ",
                    .weekly => " wk ",
                    .weekly_opus => " op ",
                    .weekly_sonnet => " sn ",
                    .monthly => " mo ",
                };
                try w.writeAll(label);
                try w.printInt(pctRounded(win.used_percent), 10, .lower, .{});
                try w.writeByte('%');
            }
        }
    }
    try w.writeByte('\n');
}

fn pctRounded(p: f64) u64 {
    return @intFromFloat(@round(std.math.clamp(p, 0, 100)));
}

// ---------------------------------------------------------------------------
// Civil time
// ---------------------------------------------------------------------------

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant's civil_from_days — the inverse of the `daysFromCivil`
/// the parsers use, and proleptic in both directions so a nonsense
/// pre-epoch bucket still renders a date instead of trapping.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153); // Mar=0 .. Feb=11
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// `2026-07-08T12:34:56Z`. Always UTC and always says so — a bare
/// timestamp with no zone is how boundary bugs get shipped.
pub fn formatIso(buf: []u8, ms: i64) []const u8 {
    const days = @divFloor(ms, 86_400_000);
    var rem = ms - days * 86_400_000;
    const hour = @divFloor(rem, 3_600_000);
    rem -= hour * 3_600_000;
    const minute = @divFloor(rem, 60_000);
    rem -= minute * 60_000;
    const second = @divFloor(rem, 1000);
    const c = civilFromDays(days);
    // Unsigned components on purpose: a signed operand under a width
    // spec renders `+1970`, which is not ISO-8601 and not what any
    // consumer of these timestamps expects. `days` comes from a u32
    // bucket everywhere it matters, so the year cannot go negative.
    const year: u32 = if (c.year < 0) 0 else @intCast(c.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year,
        c.month,
        c.day,
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    }) catch "?";
}

/// `+00:00` / `-05:00` — the offset spelled the way ISO-8601 does, so a
/// reader never has to guess the sign convention of a bare minute count.
fn formatOffset(buf: []u8, tz_offset_min: i32) []const u8 {
    const sign: u8 = if (tz_offset_min < 0) '-' else '+';
    const abs: u32 = @intCast(@abs(tz_offset_min));
    return std.fmt.bufPrint(buf, "{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 }) catch "?";
}

// ---------------------------------------------------------------------------
// Query verbs
// ---------------------------------------------------------------------------

pub const VerbError = error{
    UnknownOption,
    MissingValue,
    BadTime,
    BadBucket,
    BadGroup,
    BadFormat,
    BadDim,
    BadAgent,
    BadNumber,
    MissingDim,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

fn verbErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOption => "unrecognized option (see --help)",
        error.MissingValue => "option needs a value",
        error.BadTime => "bad time — want 7d/36h/90m, an ISO date or timestamp, epoch ms, or `now`",
        error.BadBucket => "bad --bucket — want minute, hour, or day",
        error.BadGroup => "bad --group — want a comma list of agent,model,project,session,bucket",
        error.BadFormat => "bad --format — want table, json, csv, or tsv",
        error.BadDim => "bad --dim — want agent, model, project, or session",
        error.BadAgent => "bad --agent — no such agent",
        error.BadNumber => "bad number",
        error.MissingDim => "this verb needs --dim agent|model|project|session",
        else => @errorName(err),
    };
}

pub const Format = enum { table, json, csv, tsv };

/// A parsed `--since` / `--until` / `--at`.
///
/// A DATE and an INSTANT are deliberately different cases. `2026-06-01`
/// names a calendar day, which is only an instant once you pick a zone —
/// and the zone is a property of the TIER being queried, which the parser
/// does not know. Collapsing the two here is exactly how `--since
/// 2026-06-01 --bucket day` ends up off by one for everyone east or west
/// of UTC.
pub const TimePoint = union(enum) {
    now,
    instant_ms: i64,
    /// Days since the epoch for the named civil date.
    civil_day: i64,
};

/// `now` | `<n>[smhdw]` | ISO date | ISO timestamp | bare epoch ms.
pub fn parseWhen(s: []const u8, now_ms: i64) ?TimePoint {
    if (s.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(s, "now")) return .now;

    // Relative age, e.g. `7d`. Checked before the epoch-ms case because
    // the trailing unit letter makes the two unambiguous.
    if (relativeMs(s)) |delta| return .{ .instant_ms = now_ms - delta };

    // A bare integer is epoch MILLISECONDS (what every other field in
    // this CLI speaks). Seconds would be a silent 1000x error, so there
    // is deliberately no heuristic that tries to tell them apart.
    if (allDigits(s)) return .{ .instant_ms = std.fmt.parseInt(i64, s, 10) catch return null };

    // YYYY-MM-DD
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
        const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
        const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
        if (m < 1 or m > 12 or d < 1 or d > 31) return null;
        return .{ .civil_day = daysFromCivil(y, m, d) };
    }

    // Full ISO-8601. `claude.parseTimestamp` is strict about the zone
    // designator; a local-looking `2026-06-01T12:00` gets `Z` appended
    // rather than rejected, because "no zone" in a UTC-keyed store can
    // only sensibly mean UTC — and the query header says so.
    if (claude.parseTimestamp(s)) |ms| return .{ .instant_ms = ms };
    var buf: [40]u8 = undefined;
    if (s.len + 3 <= buf.len and std.mem.indexOfScalar(u8, s, 'T') != null) {
        if (s.len == 16) { // YYYY-MM-DDTHH:MM
            const padded = std.fmt.bufPrint(&buf, "{s}:00Z", .{s}) catch return null;
            if (claude.parseTimestamp(padded)) |ms| return .{ .instant_ms = ms };
        }
        const padded = std.fmt.bufPrint(&buf, "{s}Z", .{s}) catch return null;
        if (claude.parseTimestamp(padded)) |ms| return .{ .instant_ms = ms };
    }
    return null;
}

/// `<n><unit>` in milliseconds, or null when `s` is not that shape. A
/// leading `-` is accepted and ignored: `--since -7d` and `--since 7d`
/// both mean "seven days ago", because there is no other thing they
/// could mean.
fn relativeMs(s_in: []const u8) ?i64 {
    const s = if (s_in.len > 1 and s_in[0] == '-') s_in[1..] else s_in;
    if (s.len < 2) return null;
    const unit_ms: i64 = switch (s[s.len - 1]) {
        's' => 1000,
        'm' => 60_000,
        'h' => 3_600_000,
        'd' => 86_400_000,
        'w' => 7 * 86_400_000,
        else => return null,
    };
    const digits = s[0 .. s.len - 1];
    if (!allDigits(digits)) return null;
    const n = std.fmt.parseInt(i64, digits, 10) catch return null;
    return std.math.mul(i64, n, unit_ms) catch std.math.maxInt(i64);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Every option any verb understands, parsed once. Verbs pick the
/// subset they use and supply their own defaults; an option a verb has
/// no use for is accepted and ignored rather than rejected, so
/// `--format json` works uniformly.
const Opts = struct {
    since: ?TimePoint = null,
    until: ?TimePoint = null,
    at: ?TimePoint = null,
    tier: ?history_mod.Tier = null,
    group: history_mod.GroupBy = .{},
    group_set: bool = false,
    agents: ?std.EnumSet(types.Agent) = null,
    project: []const u8 = "",
    model: []const u8 = "",
    session: []const u8 = "",
    dim: ?history_mod.Dim = null,
    format: ?Format = null,
    limit: usize = 20,
    window_min: u32 = default_burn_window_min,
    /// `doctor --history`. Present so `doctor` can grow other subjects
    /// without the flag becoming a lie.
    subject_history: bool = false,
};

fn parseOpts(o: *Opts, args: []const []const u8, now_ms: i64) VerbError!void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        var name = args[i];
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, name, "--")) {
            if (std.mem.indexOfScalar(u8, name, '=')) |at| {
                inline_value = name[at + 1 ..];
                name = name[0..at];
            }
        }
        const V = struct {
            fn next(a: []const []const u8, idx: *usize, inl: ?[]const u8) VerbError![]const u8 {
                if (inl) |v| return v;
                idx.* += 1;
                if (idx.* >= a.len) return error.MissingValue;
                return a[idx.*];
            }
        };

        if (eq(name, "--since")) {
            o.since = parseWhen(try V.next(args, &i, inline_value), now_ms) orelse return error.BadTime;
        } else if (eq(name, "--until")) {
            o.until = parseWhen(try V.next(args, &i, inline_value), now_ms) orelse return error.BadTime;
        } else if (eq(name, "--at")) {
            o.at = parseWhen(try V.next(args, &i, inline_value), now_ms) orelse return error.BadTime;
        } else if (eq(name, "--now")) {
            o.at = .now;
        } else if (eq(name, "--window")) {
            o.window_min = try parseWindowMin(try V.next(args, &i, inline_value));
        } else if (eq(name, "--bucket")) {
            o.tier = try parseTier(try V.next(args, &i, inline_value));
        } else if (eq(name, "--group")) {
            o.group = try parseGroup(try V.next(args, &i, inline_value));
            o.group_set = true;
        } else if (eq(name, "--agent")) {
            o.agents = try parseAgents(try V.next(args, &i, inline_value));
        } else if (eq(name, "--project")) {
            o.project = try V.next(args, &i, inline_value);
        } else if (eq(name, "--model")) {
            o.model = try V.next(args, &i, inline_value);
        } else if (eq(name, "--session")) {
            o.session = try V.next(args, &i, inline_value);
        } else if (eq(name, "--format")) {
            o.format = try parseFormat(try V.next(args, &i, inline_value));
        } else if (eq(name, "--dim")) {
            o.dim = try parseDim(try V.next(args, &i, inline_value));
        } else if (eq(name, "-n") or eq(name, "--limit")) {
            const raw = try V.next(args, &i, inline_value);
            o.limit = std.fmt.parseInt(usize, raw, 10) catch return error.BadNumber;
        } else if (eq(name, "--history")) {
            o.subject_history = true;
        } else return error.UnknownOption;
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseTier(s: []const u8) VerbError!history_mod.Tier {
    if (eq(s, "minute") or eq(s, "min") or eq(s, "m")) return .minute;
    if (eq(s, "hour") or eq(s, "h")) return .hour;
    if (eq(s, "day") or eq(s, "d")) return .day;
    return error.BadBucket;
}

fn parseFormat(s: []const u8) VerbError!Format {
    if (eq(s, "table")) return .table;
    if (eq(s, "json")) return .json;
    if (eq(s, "csv")) return .csv;
    if (eq(s, "tsv")) return .tsv;
    return error.BadFormat;
}

fn parseDim(s: []const u8) VerbError!history_mod.Dim {
    if (eq(s, "agent")) return .agent;
    if (eq(s, "model")) return .model;
    if (eq(s, "project")) return .project;
    if (eq(s, "session")) return .session;
    return error.BadDim;
}

fn parseGroup(s: []const u8) VerbError!history_mod.GroupBy {
    var gb = history_mod.GroupBy{};
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        if (eq(part, "bucket") or eq(part, "time")) gb.bucket = true else if (eq(part, "agent")) gb.agent = true else if (eq(part, "model")) gb.model = true else if (eq(part, "project")) gb.project = true else if (eq(part, "session")) gb.session = true else return error.BadGroup;
    }
    return gb;
}

fn parseAgents(s: []const u8) VerbError!std.EnumSet(types.Agent) {
    var set = std.EnumSet(types.Agent).initEmpty();
    var it = std.mem.splitScalar(u8, s, ',');
    var any = false;
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        var found = false;
        inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
            const agent: types.Agent = @enumFromInt(field.value);
            if (eq(part, agent.label()) or eq(part, field.name)) {
                set.insert(agent);
                found = true;
            }
        }
        if (!found) return error.BadAgent;
        any = true;
    }
    if (!any) return error.BadAgent;
    return set;
}

/// `15m`, `2h`, or a bare minute count. Rounds UP to a whole minute: a
/// sub-minute window over a minute-bucketed series is not a finer
/// answer, it is a zero.
fn parseWindowMin(s: []const u8) VerbError!u32 {
    if (relativeMs(s)) |ms| {
        const mins = @divFloor(ms + 59_999, 60_000);
        return @intCast(std.math.clamp(mins, 1, std.math.maxInt(u32)));
    }
    const n = std.fmt.parseInt(u32, s, 10) catch return error.BadNumber;
    return @max(n, 1);
}

/// The resolved bucket window plus the basis it was resolved under.
const Range = struct {
    tier: history_mod.Tier,
    from_bucket: u32,
    to_bucket: u32,
    /// Null when `--since` was omitted (the query reaches back as far as
    /// the store goes).
    since_ms: ?i64,
    until_ms: i64,
    /// True for the day tier: LOCAL days keyed at `tz_offset_min`.
    local: bool,
    tz_offset_min: i32,
};

fn clampBucket(v: i64) u32 {
    if (v <= 0) return 0;
    if (v >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

fn bucketOf(tp: TimePoint, tier: history_mod.Tier, now_ms: i64, tz_offset_min: i32) u32 {
    const ms: i64 = switch (tp) {
        .now => now_ms,
        .instant_ms => |v| v,
        .civil_day => |d| blk: {
            // On the day tier a civil date IS the key — no zone round
            // trip, which is what keeps `--since 2026-06-01` meaning the
            // first of June rather than the 31st of May shifted by the
            // store's offset.
            if (tier == .day) return clampBucket(d);
            break :blk d * 86_400_000; // UTC midnight for the UTC tiers
        },
    };
    return switch (tier) {
        .minute => history_mod.minuteBucket(ms),
        .hour => history_mod.hourBucket(ms),
        .day => history_mod.dayBucket(ms, tz_offset_min),
    };
}

/// Resolve `--since` / `--until` into the bucket window that will
/// actually be scanned.
///
/// The reported instants are derived FROM the resolved buckets, not from
/// the raw input. A query is bucket-granular, so `--since 14:37` on the
/// hour tier really does include everything from 14:00 — printing 14:37
/// back would describe a query nobody ran. `until_ms` is the last
/// millisecond of the last INCLUDED bucket, for the same reason.
fn resolveRange(
    reader: *history_mod.Reader,
    o: Opts,
    tier: history_mod.Tier,
    now_ms: i64,
) Range {
    // Only the day tier needs the stored offset, and asking for it costs
    // a read of days.log — so don't ask unless it matters.
    const tz: i32 = if (tier == .day) (reader.dayTzOffset() orelse 0) else 0;
    const until = o.until orelse TimePoint.now;
    const from_bucket = if (o.since) |s| bucketOf(s, tier, now_ms, tz) else 0;
    const to_bucket = bucketOf(until, tier, now_ms, tz);
    return .{
        .tier = tier,
        .from_bucket = from_bucket,
        .to_bucket = to_bucket,
        .since_ms = if (o.since != null) bucketStartMs(tier, from_bucket, tz) else null,
        .until_ms = bucketEndMs(tier, to_bucket, tz),
        .local = tier == .day,
        .tz_offset_min = tz,
    };
}

/// The last millisecond a bucket contains. Saturates at the top of the
/// bucket space rather than wrapping into the past.
fn bucketEndMs(tier: history_mod.Tier, bucket: u32, tz_offset_min: i32) i64 {
    if (bucket == std.math.maxInt(u32)) return bucketStartMs(tier, bucket, tz_offset_min);
    return bucketStartMs(tier, bucket + 1, tz_offset_min) - 1;
}

fn tierName(tier: history_mod.Tier) []const u8 {
    return switch (tier) {
        .minute => "minute",
        .hour => "hour",
        .day => "day",
    };
}

/// The one line that keeps a boundary query from being quietly wrong.
fn writeBasisNote(w: *std.Io.Writer, verb: Verb, r: Range) !void {
    var off_buf: [8]u8 = undefined;
    var from_buf: [32]u8 = undefined;
    var to_buf: [32]u8 = undefined;
    try w.print("# token-tach {s}  bucket={s}  basis=", .{ @tagName(verb), tierName(r.tier) });
    if (r.local) {
        try w.print("local({s})", .{formatOffset(&off_buf, r.tz_offset_min)});
    } else {
        try w.writeAll("utc");
    }
    if (r.since_ms) |ms| {
        try w.print("  since={s}", .{formatIso(&from_buf, ms)});
    } else {
        try w.writeAll("  since=beginning");
    }
    try w.print("  until={s}  buckets={d}..{d}\n", .{
        formatIso(&to_buf, r.until_ms), r.from_bucket, r.to_bucket,
    });
}

/// One output row, already stringified. Every emitter consumes this, so
/// table/csv/tsv can never disagree about what a column contains.
const OutRow = struct {
    bucket_ms: i64 = 0,
    agent: []const u8 = "",
    model: []const u8 = "",
    project: []const u8 = "",
    session: []const u8 = "",
    totals: ledger_mod.Totals = .{},
    covered_cost_usd: f64 = 0,
    records: u64 = 0,
    synthetic: bool = false,
    /// `sessions` only: the span the session was observed over.
    first_ms: i64 = 0,
    last_ms: i64 = 0,
};

const Cols = struct {
    bucket: bool = false,
    agent: bool = false,
    model: bool = false,
    project: bool = false,
    session: bool = false,
    span: bool = false,
};

fn colsFor(gb: history_mod.GroupBy) Cols {
    return .{
        .bucket = gb.bucket,
        .agent = gb.agent,
        .model = gb.model,
        .project = gb.project,
        .session = gb.session,
    };
}

/// Turn the reader's id-bearing rows into printable ones. Names are
/// duped into the arena because `Reader.name` may hand back a pointer
/// into a stack buffer for a dangling id.
fn shapeRows(
    arena: std.mem.Allocator,
    reader: *const history_mod.Reader,
    rows: []const history_mod.Row,
    tier: history_mod.Tier,
    tz_offset_min: i32,
) ![]OutRow {
    const out = try arena.alloc(OutRow, rows.len);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var agent_buf: [history_mod.name_buf_len]u8 = undefined;
    for (rows, 0..) |row, i| {
        out[i] = .{
            .bucket_ms = bucketStartMs(tier, row.bucket, tz_offset_min),
            .agent = if (row.agent == 0) "" else try arena.dupe(u8, history_mod.agentName(row.agent, &agent_buf)),
            .model = try arena.dupe(u8, reader.name(row.model_id, &name_buf)),
            .project = try arena.dupe(u8, reader.name(row.project_id, &name_buf)),
            .session = try arena.dupe(u8, reader.name(row.session_id, &name_buf)),
            .totals = row.totals,
            .covered_cost_usd = row.covered_cost_usd,
            .records = row.records,
            .synthetic = row.agent == history_mod.synthetic_agent_id,
        };
    }
    return out;
}

// --- emitters --------------------------------------------------------------

const metric_headers = [_][]const u8{
    "input", "output", "cache_creation", "cache_read", "cost_usd", "events", "covered",
};

fn headerCells(arena: std.mem.Allocator, cols: Cols) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (cols.bucket) try list.append(arena, "bucket_ms");
    if (cols.agent) try list.append(arena, "agent");
    if (cols.model) try list.append(arena, "model");
    if (cols.project) try list.append(arena, "project");
    if (cols.session) try list.append(arena, "session");
    if (cols.span) {
        try list.append(arena, "first_ms");
        try list.append(arena, "last_ms");
    }
    for (metric_headers) |h| try list.append(arena, h);
    if (cols.agent) try list.append(arena, "synthetic");
    return list.toOwnedSlice(arena);
}

fn rowCells(arena: std.mem.Allocator, cols: Cols, row: OutRow) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (cols.bucket) try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.bucket_ms}));
    if (cols.agent) try list.append(arena, row.agent);
    if (cols.model) try list.append(arena, row.model);
    if (cols.project) try list.append(arena, row.project);
    if (cols.session) try list.append(arena, row.session);
    if (cols.span) {
        try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.first_ms}));
        try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.last_ms}));
    }
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.totals.input_tokens}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.totals.output_tokens}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.totals.cache_creation_tokens}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.totals.cache_read_tokens}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d:.6}", .{row.totals.cost_usd}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{row.totals.events}));
    try list.append(arena, try std.fmt.allocPrint(arena, "{d:.6}", .{row.covered_cost_usd}));
    if (cols.agent) try list.append(arena, if (row.synthetic) "1" else "0");
    return list.toOwnedSlice(arena);
}

/// RFC 4180. A project path is a user-controlled string that routinely
/// contains a comma, a quote, or (on a bad day) a newline; an unescaped
/// one silently shifts every column after it, which is worse than an
/// error because the file still parses.
fn writeCsvField(w: *std.Io.Writer, s: []const u8) !void {
    const needs_quote = std.mem.indexOfAny(u8, s, ",\"\r\n") != null or
        (s.len > 0 and (s[0] == ' ' or s[s.len - 1] == ' '));
    if (!needs_quote) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// TSV has no quoting mechanism at all, so the separators are escaped
/// C-style instead. Backslash goes first or the escape is ambiguous.
fn writeTsvField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(ch),
    };
}

fn writeDelimited(w: *std.Io.Writer, cells: []const []const u8, fmt: Format) !void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try w.writeByte(if (fmt == .csv) ',' else '\t');
        if (fmt == .csv) try writeCsvField(w, cell) else try writeTsvField(w, cell);
    }
    try w.writeByte('\n');
}

/// Left-aligned padded columns, widths from the content. Buffering the
/// whole result is fine here and nowhere else: `--format table` is the
/// human path, and a human is not going to read a million rows.
fn writeTable(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    header: []const []const u8,
    rows: []const []const []const u8,
) !void {
    const widths = try arena.alloc(usize, header.len);
    for (header, 0..) |h, i| widths[i] = h.len;
    for (rows) |cells| {
        for (cells, 0..) |cell, i| {
            if (i < widths.len and cell.len > widths[i]) widths[i] = cell.len;
        }
    }
    try writePadded(w, header, widths);
    for (rows) |cells| try writePadded(w, cells, widths);
}

fn writePadded(w: *std.Io.Writer, cells: []const []const u8, widths: []const usize) !void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try w.writeAll("  ");
        try w.writeAll(cell);
        if (i + 1 < cells.len) try w.splatByteAll(' ', widths[i] -| cell.len);
    }
    try w.writeByte('\n');
}

fn writeRowsJson(
    w: *std.Io.Writer,
    verb: Verb,
    r: Range,
    cols: Cols,
    rows: []const OutRow,
    note: ?[]const u8,
) !void {
    var js = std.json.Stringify{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("verb");
    try js.write(@tagName(verb));
    try js.objectField("query");
    try js.beginObject();
    try js.objectField("bucket");
    try js.write(tierName(r.tier));
    try js.objectField("time_basis");
    try js.write(if (r.local) "local" else "utc");
    try js.objectField("tz_offset_min");
    try js.write(r.tz_offset_min);
    try js.objectField("since_ms");
    try js.write(r.since_ms);
    try js.objectField("until_ms");
    try js.write(r.until_ms);
    try js.objectField("from_bucket");
    try js.write(r.from_bucket);
    try js.objectField("to_bucket");
    try js.write(r.to_bucket);
    try js.endObject();
    if (note) |n| {
        try js.objectField("note");
        try js.write(n);
    }
    try js.objectField("rows");
    try js.beginArray();
    for (rows) |row| {
        try js.beginObject();
        if (cols.bucket) {
            try js.objectField("bucket_ms");
            try js.write(row.bucket_ms);
        }
        if (cols.agent) {
            try js.objectField("agent");
            try js.write(row.agent);
            try js.objectField("synthetic");
            try js.write(row.synthetic);
        }
        if (cols.model) {
            try js.objectField("model");
            try js.write(row.model);
        }
        if (cols.project) {
            try js.objectField("project");
            try js.write(row.project);
        }
        if (cols.session) {
            try js.objectField("session");
            try js.write(row.session);
        }
        if (cols.span) {
            try js.objectField("first_ms");
            try js.write(row.first_ms);
            try js.objectField("last_ms");
            try js.write(row.last_ms);
        }
        try js.objectField("input");
        try js.write(row.totals.input_tokens);
        try js.objectField("output");
        try js.write(row.totals.output_tokens);
        try js.objectField("cache_creation");
        try js.write(row.totals.cache_creation_tokens);
        try js.objectField("cache_read");
        try js.write(row.totals.cache_read_tokens);
        try js.objectField("tokens");
        try js.write(row.totals.totalTokens());
        try js.objectField("cost_usd");
        try js.write(roundUsd(row.totals.cost_usd));
        try js.objectField("covered_cost_usd");
        try js.write(roundUsd(row.covered_cost_usd));
        try js.objectField("events");
        try js.write(row.totals.events);
        try js.objectField("records");
        try js.write(row.records);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeByte('\n');
}

/// The single emitter every row-shaped verb goes through.
///
/// `notes_w` is where the basis line lands. For csv/tsv the caller
/// passes STDERR: the whole point of `export` is a file you can hand to
/// another tool, and a `#` preamble in it would be one more thing that
/// tool has to be told about.
fn emit(
    w: *std.Io.Writer,
    notes_w: *std.Io.Writer,
    arena: std.mem.Allocator,
    verb: Verb,
    r: Range,
    cols: Cols,
    fmt: Format,
    rows: []const OutRow,
    note: ?[]const u8,
) !void {
    if (fmt == .json) return writeRowsJson(w, verb, r, cols, rows, note);

    try writeBasisNote(notes_w, verb, r);
    if (note) |n| try notes_w.print("# {s}\n", .{n});

    const header = try headerCells(arena, cols);
    switch (fmt) {
        .csv, .tsv => {
            try writeDelimited(w, header, fmt);
            for (rows) |row| try writeDelimited(w, try rowCells(arena, cols, row), fmt);
        },
        .table => {
            const cells = try arena.alloc([]const []const u8, rows.len);
            for (rows, 0..) |row, i| cells[i] = try rowCells(arena, cols, row);
            try writeTable(w, arena, header, cells);
        },
        .json => unreachable,
    }
}

// --- verb dispatch ---------------------------------------------------------

fn runVerb(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    ew: *std.Io.Writer,
    env: Env,
    now_ms: i64,
    verb: Verb,
    args: []const []const u8,
) !void {
    var o = Opts{};
    try parseOpts(&o, args, now_ms);

    const dir = try history_mod.defaultDir(arena, env.xdg_state_home, env.home);
    // Reader, never Writer: no flock, no compaction, no chance of
    // stalling the app that is collecting right now.
    var reader = try history_mod.Reader.open(gpa, io, dir);
    defer reader.deinit();

    switch (verb) {
        .history => try runRows(arena, w, ew, &reader, o, verb, .day, .{ .bucket = true }, .table, now_ms),
        .@"export" => try runRows(arena, w, ew, &reader, o, verb, .hour, .{
            .bucket = true,
            .agent = true,
            .model = true,
            .project = true,
            .session = true,
        }, .csv, now_ms),
        .top => try runTop(arena, w, ew, &reader, o, now_ms),
        .sessions => try runSessions(arena, w, ew, &reader, o, now_ms),
        .burn => try runBurn(w, &reader, o, now_ms),
        .doctor => try runDoctor(arena, w, &reader, o, dir),
    }
}

/// Which writer the basis note goes to: inline for the human formats,
/// stderr for the machine ones so a redirect yields a clean file.
fn notesWriter(w: *std.Io.Writer, ew: *std.Io.Writer, fmt: Format) *std.Io.Writer {
    return if (fmt == .csv or fmt == .tsv) ew else w;
}

/// Resolve a `--model` / `--project` / `--session` name to its id.
///
/// A name this store has never seen is a HARD stop, not a filter of 0:
/// `Filter`'s zero means "any", so passing it through would answer a
/// question nobody asked with a full table of everything.
fn filterId(id: u32, kind: []const u8, name: []const u8, note: *?[]const u8, arena: std.mem.Allocator) !?u32 {
    if (id != 0) return id;
    note.* = try std.fmt.allocPrint(arena, "no {s} named \"{s}\" in this store", .{ kind, name });
    return null;
}

fn runRows(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    ew: *std.Io.Writer,
    reader: *history_mod.Reader,
    o: Opts,
    verb: Verb,
    default_tier: history_mod.Tier,
    default_group: history_mod.GroupBy,
    default_fmt: Format,
    now_ms: i64,
) !void {
    const tier = o.tier orelse default_tier;
    const fmt = o.format orelse default_fmt;
    // `export`'s schema is fixed: the column set IS the contract, so
    // --group is ignored there rather than silently reshaping the file.
    const group = if (verb == .@"export") default_group else if (o.group_set) o.group else default_group;
    const r = resolveRange(reader, o, tier, now_ms);
    const cols = colsFor(group);

    var filter = history_mod.Filter{
        .from_bucket = r.from_bucket,
        .to_bucket = r.to_bucket,
        .agents = o.agents,
    };
    var note: ?[]const u8 = null;
    if (o.model.len > 0) {
        filter.model_id = (try filterId(reader.modelId(o.model), "model", o.model, &note, arena)) orelse
            return emit(w, notesWriter(w, ew, fmt), arena, verb, r, cols, fmt, &.{}, note);
    }
    if (o.project.len > 0) {
        filter.project_id = (try filterId(reader.projectId(o.project), "project", o.project, &note, arena)) orelse
            return emit(w, notesWriter(w, ew, fmt), arena, verb, r, cols, fmt, &.{}, note);
    }
    if (o.session.len > 0) {
        filter.session_id = (try filterId(reader.sessionId(o.session), "session", o.session, &note, arena)) orelse
            return emit(w, notesWriter(w, ew, fmt), arena, verb, r, cols, fmt, &.{}, note);
    }

    const rows = try reader.query(arena, tier, filter, group);
    const shaped = try shapeRows(arena, reader, rows, tier, r.tz_offset_min);
    try emit(w, notesWriter(w, ew, fmt), arena, verb, r, cols, fmt, shaped, note);
}

fn runTop(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    ew: *std.Io.Writer,
    reader: *history_mod.Reader,
    o: Opts,
    now_ms: i64,
) !void {
    const dim = o.dim orelse return error.MissingDim;
    const tier = o.tier orelse .day;
    const fmt = o.format orelse .table;
    const r = resolveRange(reader, o, tier, now_ms);
    const rows = try reader.topBy(arena, tier, dim, r.from_bucket, r.to_bucket, o.limit);
    const shaped = try shapeRows(arena, reader, rows, tier, r.tz_offset_min);
    const cols = Cols{
        .agent = dim == .agent,
        .model = dim == .model,
        .project = dim == .project,
        .session = dim == .session,
    };
    try emit(w, notesWriter(w, ew, fmt), arena, .top, r, cols, fmt, shaped, null);
}

/// `sessions` is the one verb that folds rows itself: the store has no
/// "session span" dimension, so the span comes from grouping by bucket
/// as well and collapsing here. The project shown is the one the session
/// spent the most tokens in — a session that touched two projects is
/// real, and picking the heavier one beats splitting the row in two.
fn runSessions(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    ew: *std.Io.Writer,
    reader: *history_mod.Reader,
    o: Opts,
    now_ms: i64,
) !void {
    const tier = o.tier orelse .day;
    const fmt = o.format orelse .table;
    const r = resolveRange(reader, o, tier, now_ms);

    var filter = history_mod.Filter{
        .from_bucket = r.from_bucket,
        .to_bucket = r.to_bucket,
        .agents = o.agents,
    };
    var note: ?[]const u8 = null;
    const cols = Cols{ .agent = true, .session = true, .project = true, .span = true };
    if (o.project.len > 0) {
        filter.project_id = (try filterId(reader.projectId(o.project), "project", o.project, &note, arena)) orelse
            return emit(w, notesWriter(w, ew, fmt), arena, .sessions, r, cols, fmt, &.{}, note);
    }

    const rows = try reader.query(arena, tier, filter, .{
        .session = true,
        .agent = true,
        .project = true,
        .bucket = true,
    });

    const Acc = struct {
        row: OutRow,
        best_project_tokens: u64,
    };
    var by_session: std.AutoArrayHashMapUnmanaged(struct { u32, u8 }, Acc) = .empty;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var agent_buf: [history_mod.name_buf_len]u8 = undefined;
    for (rows) |row| {
        const start = bucketStartMs(tier, row.bucket, r.tz_offset_min);
        const gop = try by_session.getOrPut(arena, .{ row.session_id, row.agent });
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .row = .{
                    .agent = try arena.dupe(u8, history_mod.agentName(row.agent, &agent_buf)),
                    .session = try arena.dupe(u8, reader.name(row.session_id, &name_buf)),
                    .synthetic = row.agent == history_mod.synthetic_agent_id,
                    .first_ms = start,
                    .last_ms = start,
                },
                .best_project_tokens = 0,
            };
        }
        const acc = gop.value_ptr;
        addTotals(&acc.row.totals, row.totals);
        acc.row.covered_cost_usd += row.covered_cost_usd;
        acc.row.records += row.records;
        if (start < acc.row.first_ms) acc.row.first_ms = start;
        if (start > acc.row.last_ms) acc.row.last_ms = start;
        if (row.totals.totalTokens() > acc.best_project_tokens) {
            acc.best_project_tokens = row.totals.totalTokens();
            acc.row.project = try arena.dupe(u8, reader.name(row.project_id, &name_buf));
        }
    }

    var shaped = try arena.alloc(OutRow, by_session.count());
    for (by_session.values(), 0..) |acc, i| shaped[i] = acc.row;
    std.mem.sort(OutRow, shaped, {}, struct {
        fn lt(_: void, a: OutRow, b: OutRow) bool {
            if (a.last_ms != b.last_ms) return a.last_ms > b.last_ms;
            return a.totals.totalTokens() > b.totals.totalTokens();
        }
    }.lt);
    if (shaped.len > o.limit) shaped = shaped[0..o.limit];
    try emit(w, notesWriter(w, ew, fmt), arena, .sessions, r, cols, fmt, shaped, note);
}

fn runBurn(
    w: *std.Io.Writer,
    reader: *history_mod.Reader,
    o: Opts,
    now_ms: i64,
) !void {
    const fmt = o.format orelse .table;
    const at_ms: i64 = switch (o.at orelse TimePoint.now) {
        .now => now_ms,
        .instant_ms => |v| v,
        .civil_day => |d| d * 86_400_000,
    };
    const burn = try reader.burnAt(at_ms, o.window_min);
    // The hot ring only reaches back 48 h; a longer window silently
    // under-reports, so say so rather than printing a confident number.
    const beyond_hot = @as(i64, o.window_min) * 60_000 > history_mod.hot_max_age_ms;
    var iso_buf: [32]u8 = undefined;
    const ending = formatIso(&iso_buf, at_ms);

    if (fmt == .json) {
        var js = std.json.Stringify{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try js.beginObject();
        try js.objectField("verb");
        try js.write("burn");
        try js.objectField("at_ms");
        try js.write(at_ms);
        try js.objectField("time_basis");
        try js.write("utc");
        try js.objectField("window_min");
        try js.write(burn.window_min);
        try js.objectField("tokens_per_min");
        try js.write(roundFrac(burn.tokens_per_min));
        try js.objectField("cost_usd_per_min");
        try js.write(roundUsd(burn.cost_per_min));
        try js.objectField("tokens");
        try js.write(burn.totals.totalTokens());
        try js.objectField("cost_usd");
        try js.write(roundUsd(burn.totals.cost_usd));
        try js.objectField("events");
        try js.write(burn.totals.events);
        try js.objectField("beyond_hot_tier");
        try js.write(beyond_hot);
        try js.endObject();
        try w.writeByte('\n');
        return;
    }

    try w.print("# token-tach burn  bucket=minute  basis=utc  window={d}m  ending={s}\n", .{ burn.window_min, ending });
    if (beyond_hot) try w.writeAll("# window exceeds the hot ring's 48 h reach — this rate under-reports\n");
    try w.print("tokens_per_min   {d:.1}\n", .{burn.tokens_per_min});
    try w.print("cost_per_min     {d:.6}\n", .{burn.cost_per_min});
    try w.print("tokens           {d}\n", .{burn.totals.totalTokens()});
    try w.print("cost_usd         {d:.6}\n", .{burn.totals.cost_usd});
    try w.print("events           {d}\n", .{burn.totals.events});
}

/// `doctor --history`: everything a human needs to decide whether the
/// store is healthy, without opening it for write.
///
/// The CRC scan is not a separate pass — `Reader.extent` validates every
/// record it counts, so `records` here is the number that PASSED and the
/// difference from the physical slot count is the number that did not.
fn runDoctor(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    reader: *history_mod.Reader,
    o: Opts,
    dir: []const u8,
) !void {
    // `--history` is the only subject today; it is also the default, so
    // `o.subject_history` is accepted and not required.
    const fmt = o.format orelse .table;
    const ext = try reader.extent();

    // Dangling ids: a dictionary entry lost to a crash before the record
    // that references it. `Reader.name` renders those `?id:<n>`.
    var dangling: u32 = 0;
    var sample: []const u8 = "";
    const rows = reader.query(arena, .day, .{}, .{
        .model = true,
        .project = true,
        .session = true,
    }) catch &[_]history_mod.Row{};
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (rows) |row| {
        for ([_]u32{ row.model_id, row.project_id, row.session_id }) |id| {
            if (id == 0) continue;
            const n = reader.name(id, &name_buf);
            if (std.mem.startsWith(u8, n, "?id:")) {
                dangling += 1;
                if (sample.len == 0) sample = try arena.dupe(u8, n);
            }
        }
    }

    const tiers = [_]history_mod.Tier{ .minute, .hour, .day };
    if (fmt == .json) {
        var js = std.json.Stringify{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try js.beginObject();
        try js.objectField("verb");
        try js.write("doctor");
        try js.objectField("dir");
        try js.write(dir);
        try js.objectField("write_lock_taken");
        try js.write(false);
        try js.objectField("dangling_dict_ids");
        try js.write(dangling);
        try js.objectField("tiers");
        try js.beginArray();
        for (tiers) |tier| {
            const e = ext.get(tier);
            try js.beginObject();
            try js.objectField("tier");
            try js.write(tierName(tier));
            try js.objectField("file");
            try js.write(tier.fileName());
            try js.objectField("present");
            try js.write(e.present);
            try js.objectField("bytes");
            try js.write(e.bytes);
            try js.objectField("slots");
            try js.write(slotsOf(e));
            try js.objectField("valid_records");
            try js.write(e.records);
            try js.objectField("unreadable_slots");
            try js.write(slotsOf(e) -| e.records);
            try js.objectField("first_bucket");
            try js.write(e.first_bucket);
            try js.objectField("last_bucket");
            try js.write(e.last_bucket);
            try js.objectField("first_ms");
            try js.write(if (e.first_bucket) |b| bucketStartMs(tier, b, e.tz_offset_min) else null);
            try js.objectField("last_ms");
            try js.write(if (e.last_bucket) |b| bucketStartMs(tier, b, e.tz_offset_min) else null);
            try js.objectField("time_basis");
            try js.write(if (tier == .day) "local" else "utc");
            try js.objectField("tz_offset_min");
            try js.write(e.tz_offset_min);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
        try w.writeByte('\n');
        return;
    }

    try w.print("history store   {s}\n", .{dir});
    try w.writeAll("write lock      not taken (reader only)\n");
    try w.print("dangling ids    {d}{s}{s}\n", .{
        dangling,
        if (sample.len > 0) "  e.g. " else "",
        sample,
    });
    for (tiers) |tier| {
        const e = ext.get(tier);
        var off_buf: [8]u8 = undefined;
        var first_buf: [32]u8 = undefined;
        var last_buf: [32]u8 = undefined;
        try w.print("\n{s}  ({s})\n", .{ tier.fileName(), tierName(tier) });
        if (!e.present) {
            try w.writeAll("  absent or unreadable\n");
            continue;
        }
        try w.print("  bytes         {d}\n", .{e.bytes});
        try w.print("  slots         {d}\n", .{slotsOf(e)});
        try w.print("  valid records {d}\n", .{e.records});
        try w.print("  unreadable    {d}  (failed crc, or never written)\n", .{slotsOf(e) -| e.records});
        try w.print("  basis         {s}", .{if (tier == .day) "local" else "utc"});
        if (tier == .day) try w.print(" {s}", .{formatOffset(&off_buf, e.tz_offset_min)});
        try w.writeByte('\n');
        if (e.first_bucket) |b| {
            try w.print("  first         {d}  {s}\n", .{ b, formatIso(&first_buf, bucketStartMs(tier, b, e.tz_offset_min)) });
        }
        if (e.last_bucket) |b| {
            try w.print("  last          {d}  {s}\n", .{ b, formatIso(&last_buf, bucketStartMs(tier, b, e.tz_offset_min)) });
        }
    }
}

/// Physical record slots in a tier file, valid or not.
fn slotsOf(e: history_mod.Extent) u64 {
    if (e.bytes <= history_mod.header_size) return 0;
    return (e.bytes - history_mod.header_size) / history_mod.record_size;
}

// ---------------------------------------------------------------------------
// Bench mode
// ---------------------------------------------------------------------------

/// `--bench`: time one full collection pass and report what it cost.
///
/// There is no fixture magic here on purpose — every source already
/// resolves its root from an environment variable, so pointing the whole
/// pipeline at a fixture tree is `CLAUDE_CONFIG_DIR=… CODEX_HOME=…
/// XDG_STATE_HOME=… token-tach --bench`. That makes the Wave 1 perf
/// claims a number this repo can regress against instead of an estimate,
/// and it exercises the SAME `collect` the `--json` path uses rather
/// than a parallel benchmark harness that can drift away from it.
///
/// `input_files` / `input_bytes` are the transcript corpus the pass had
/// to consider — the denominator for a bytes/second figure. On a WARM
/// run (a state file present) most of those bytes are never read, which
/// is precisely the effect worth measuring.
fn runBench(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    env: Env,
    now_ms: i64,
) !void {
    const inputs = benchInputs(arena, io, env) catch BenchInputs{};

    const started = native_sdk.monotonicNanoseconds();
    const snap = collect(arena, io, env, now_ms) catch emptySnapshot(now_ms);
    const elapsed_ns = native_sdk.monotonicNanoseconds() -| started;

    const rss = std.posix.getrusage(std.posix.rusage.SELF);

    var js = std.json.Stringify{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("bench");
    try js.write("collect");
    try js.objectField("version");
    try js.write(version);
    try js.objectField("state");
    try js.write(@tagName(snap.state));
    try js.objectField("input_files");
    try js.write(inputs.files);
    try js.objectField("input_bytes");
    try js.write(inputs.bytes);
    try js.objectField("events");
    try js.write(snap.all.events);
    try js.objectField("wall_ms");
    try js.write(roundFrac(@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0));
    try js.objectField("wall_ns");
    try js.write(elapsed_ns);
    try js.objectField("peak_rss_bytes");
    try js.write(rss.maxrss);
    try js.objectField("history_records");
    try js.write(snap.history.records);
    try js.objectField("history_bytes");
    try js.write(snap.history.bytes);
    try js.endObject();
    try w.writeByte('\n');
}

const BenchInputs = struct { files: u64 = 0, bytes: u64 = 0 };

/// Walk the transcript roots the same way `collect` resolves them and
/// measure the corpus. Read-only, and every failure is skipped: a bench
/// that refuses to run because one root is missing is a bench nobody
/// runs.
fn benchInputs(arena: std.mem.Allocator, io: std.Io, env: Env) !BenchInputs {
    var cfg: config.Config = .{};
    if (config.defaultPath(arena, env.home)) |config_path| {
        if (config.load(arena, config_path) catch null) |result| cfg = result.config;
    } else |_| {}

    const claude_roots: []const []const u8 = if (cfg.claude_config_dirs.len > 0)
        try appendProjects(arena, cfg.claude_config_dirs)
    else
        try claude.discoverRoots(arena, io, env.claude_config_dir, env.home);
    const codex_env: ?[]const u8 = if (cfg.codex_home.len > 0) cfg.codex_home else env.codex_home;
    const codex_roots = try codex.sessionsDirs(arena, codex_env, env.home);
    const opencode_path = try opencode.resolvePath(arena, cfg.opencode_db, env.opencode_db, env.xdg_data_home, env.home);

    var out = BenchInputs{};
    var cwd = std.Io.Dir.cwd();
    for ([_][]const []const u8{ claude_roots, codex_roots }) |roots| {
        for (roots) |root| {
            var dir = cwd.openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = dir.walk(arena) catch continue;
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
                const stat = dir.statFile(io, entry.path, .{}) catch continue;
                out.files += 1;
                out.bytes += stat.size;
            }
        }
    }
    if (opencode_path.len > 0) {
        if (cwd.statFile(io, opencode_path, .{})) |stat| {
            out.files += 1;
            out.bytes += stat.size;
        } else |_| {}
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const claude_fixture = @embedFile("core/fixtures/claude/session1.jsonl");
const codex_fixture = @embedFile("core/fixtures/codex/rollout-basic.jsonl");

const claude_session_id = "11111111-2222-4333-8444-555555555555";
const claude_session_rel = "claudecfg/projects/slug/" ++ claude_session_id ++ ".jsonl";
const codex_rollout_rel =
    "codex/sessions/2025/10/09/rollout-2025-10-09T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl";

/// now for the fixture tests: 2026-07-08T04:00Z, an hour after the last
/// claude fixture event (same UTC day) and months after the codex ones.
const fixture_now_ms: i64 = 1_783_483_200_000;

fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => std.math.nan(f64),
    };
}

/// Fixture ground truth (see core/claude.zig + core/statefile.zig tests):
/// 8 claude events (3600 in / 360 out / 10000 cc / 35000 cr) on
/// 2026-07-08 + 3 codex events on 2025-10-09.
const claude_fixture_tokens: u64 = 3600 + 360 + 10000 + 35000;

const TmpTree = struct {
    tmp: testing.TmpDir,
    base_buf: [std.fs.max_path_bytes]u8,

    fn init(io: std.Io) !TmpTree {
        var self = TmpTree{ .tmp = testing.tmpDir(.{}), .base_buf = undefined };
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, "home");
        try self.tmp.dir.createDirPath(io, "claudecfg/projects/slug");
        try self.tmp.dir.createDirPath(io, "codex/sessions/2025/10/09");
        try self.tmp.dir.writeFile(io, .{ .sub_path = claude_session_rel, .data = claude_fixture });
        try self.tmp.dir.writeFile(io, .{ .sub_path = codex_rollout_rel, .data = codex_fixture });
        return self;
    }

    fn deinit(self: *TmpTree) void {
        self.tmp.cleanup();
    }

    fn base(self: *TmpTree, io: std.Io) ![]const u8 {
        return self.base_buf[0..try self.tmp.dir.realPath(io, &self.base_buf)];
    }

    fn env(self: *TmpTree, arena: std.mem.Allocator, io: std.Io) !Env {
        const b = try self.base(io);
        return .{
            .home = try std.fmt.allocPrint(arena, "{s}/home", .{b}),
            .claude_config_dir = try std.fmt.allocPrint(arena, "{s}/claudecfg", .{b}),
            .codex_home = try std.fmt.allocPrint(arena, "{s}/codex", .{b}),
            .xdg_state_home = try std.fmt.allocPrint(arena, "{s}/state", .{b}),
        };
    }
};

test "modeForFlag: recognized flags map, everything else passes through" {
    try testing.expectEqual(@as(?Mode, .json), modeForFlag("--json"));
    try testing.expectEqual(@as(?Mode, .statusline), modeForFlag("--statusline"));
    try testing.expectEqual(@as(?Mode, .help), modeForFlag("--help"));
    try testing.expectEqual(@as(?Mode, .help), modeForFlag("-h"));
    try testing.expectEqual(@as(?Mode, .version), modeForFlag("--version"));
    try testing.expectEqual(@as(?Mode, .version), modeForFlag("-v"));
    // Unknown flags belong to the GUI runner: never intercepted.
    try testing.expectEqual(@as(?Mode, null), modeForFlag("--jsno"));
    try testing.expectEqual(@as(?Mode, null), modeForFlag("token-tach"));
    try testing.expectEqual(@as(?Mode, null), modeForFlag(""));
}

test "yearMonthOfDay: month boundaries and epoch" {
    // 1970-01-01 is day 0 → 1970*12 + 0.
    try testing.expectEqual(@as(i64, 1970 * 12), yearMonthOfDay(0));
    const jun30 = ledger_mod.dayKey(claude.parseTimestamp("2026-06-30T23:59:59Z").?, 0);
    const jul1 = ledger_mod.dayKey(claude.parseTimestamp("2026-07-01T00:00:00Z").?, 0);
    const jul31 = ledger_mod.dayKey(claude.parseTimestamp("2026-07-31T23:59:59Z").?, 0);
    try testing.expectEqual(@as(i64, 2026 * 12 + 5), yearMonthOfDay(jun30));
    try testing.expectEqual(@as(i64, 2026 * 12 + 6), yearMonthOfDay(jul1));
    try testing.expectEqual(yearMonthOfDay(jul1), yearMonthOfDay(jul31));
    // Pre-epoch days stay well-defined (Hinnant is proleptic).
    try testing.expectEqual(@as(i64, 1969 * 12 + 11), yearMonthOfDay(-1));
}

test "collect: cold scan aggregates fixtures, splits today/month, captures codex limits" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = try collect(arena, io, try tree.env(arena, io), fixture_now_ms);

    try testing.expectEqual(statefile.RestoreOutcome.absent, snap.state);
    try testing.expectEqual(@as(u64, 11), snap.all.events);
    try testing.expectEqual(@as(u64, 8), snap.per_agent.get(.claude).events);
    try testing.expectEqual(@as(u64, 3), snap.per_agent.get(.codex).events);
    // The bundled pricing db prices the fixture models.
    try testing.expect(snap.all.cost_usd > 0);

    // Today + this month (2026-07, tz 0) contain exactly the claude
    // fixture events; the 2025-10 codex events fall outside both.
    try testing.expectEqual(@as(u64, 8), snap.today.events);
    try testing.expectEqual(claude_fixture_tokens, snap.today.totalTokens());
    try testing.expectEqual(@as(u64, 8), snap.month.events);
    try testing.expectEqual(claude_fixture_tokens, snap.month.totalTokens());

    // Codex limits come from the rollout's token_count lines — no state
    // file, no network.
    const limits = snap.codex_limits orelse return error.TestExpectedLimits;
    try testing.expectEqualStrings("pro", limits.plan);
    try testing.expectEqual(@as(usize, 2), limits.windows.len);
    try testing.expectEqual(@as(f64, 14.0), limits.windows[0].used_percent);
    try testing.expectEqual(@as(f64, 3.5), limits.windows[1].used_percent);

    // Rollups: 3 models (fable-5, opus-4-8, gpt-5.2-codex), 2 projects,
    // sorted by cost descending.
    try testing.expectEqual(@as(usize, 3), snap.models.len);
    try testing.expectEqual(@as(usize, 2), snap.projects.len);
    var last_cost = std.math.inf(f64);
    for (snap.models) |entry| {
        try testing.expect(entry.totals.cost_usd <= last_cost);
        last_cost = entry.totals.cost_usd;
    }
}

test "collect: warm restore does not double-count and keeps the saved tz" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);

    // Simulate the app: parse everything, then save state where the CLI
    // will look (XDG_STATE_HOME/token-tach/tailers.json).
    {
        var claude_tailer = claude.Tailer.init(arena);
        var codex_tailer = codex.Tailer.init(arena);
        var opencode_poller = opencode.Poller.init(arena);
        var ledger = ledger_mod.Ledger.init(arena, -300);

        var sink = claude.ListSink.init(arena);
        const claude_root = try std.fmt.allocPrint(arena, "{s}/projects", .{env.claude_config_dir.?});
        try claude_tailer.sweep(arena, io, &.{claude_root}, sink.sink());
        for (sink.events.items) |ev| try ledger.add(ev, 0.5);

        var events: std.ArrayList(types.UsageEvent) = .empty;
        const codex_root = try std.fmt.allocPrint(arena, "{s}/sessions", .{env.codex_home.?});
        try codex_tailer.sweep(io, arena, &.{codex_root}, &events);
        for (events.items) |ev| try ledger.add(ev, 0.25);

        const state_path = try statefile.defaultPath(arena, env.xdg_state_home, env.home);
        try statefile.save(arena, io, state_path, &claude_tailer, &codex_tailer, &opencode_poller, null, &ledger);
    }

    const snap = try collect(arena, io, env, fixture_now_ms);
    try testing.expectEqual(statefile.RestoreOutcome.restored, snap.state);
    // Restored rollups + a sweep that re-reads nothing: still 11 events,
    // at the costs the "app" priced them at.
    try testing.expectEqual(@as(u64, 11), snap.all.events);
    try testing.expectEqual(@as(f64, 8 * 0.5 + 3 * 0.25), snap.all.cost_usd);
    // The app's tz (UTC-5) came back with the day buckets.
    try testing.expectEqual(@as(i32, -300), snap.tz_offset_min);
    // Limits survive purely through the state file.
    try testing.expectEqualStrings("pro", (snap.codex_limits orelse return error.TestExpectedLimits).plan);
}

test "collect: read-only — a corrupt state file is left byte-identical and degrades to cold scan" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);

    const garbage = "{\"version\": 1, \"claude_files\": [{{{ definitely not json";
    try tree.tmp.dir.createDirPath(io, "state/token-tach");
    try tree.tmp.dir.writeFile(io, .{ .sub_path = "state/token-tach/tailers.json", .data = garbage });

    const snap = try collect(arena, io, env, fixture_now_ms);
    try testing.expectEqual(statefile.RestoreOutcome.invalid, snap.state);
    // Cold scan still produced the full picture.
    try testing.expectEqual(@as(u64, 11), snap.all.events);

    // The state file was not rewritten, "repaired", or deleted.
    const after = try tree.tmp.dir.readFileAlloc(io, "state/token-tach/tailers.json", arena, .limited(1 << 20));
    try testing.expectEqualStrings(garbage, after);
}

test "writeJson: schema fields, note semantics, and claude-limits hint" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = try collect(arena, io, try tree.env(arena, io), fixture_now_ms);

    var aw = std.Io.Writer.Allocating.init(arena);
    try writeJson(&aw.writer, snap);
    const json = aw.writer.buffered();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const root = parsed.object;
    try testing.expectEqualStrings(version, root.get("version").?.string);
    try testing.expectEqual(fixture_now_ms, root.get("generated_at_ms").?.integer);
    // Cold scan → an explanatory note, not silence.
    try testing.expect(root.get("note").? == .string);
    try testing.expectEqual(@as(i64, @intCast(claude_fixture_tokens)), root.get("today").?.object.get("tokens").?.integer);
    try testing.expectEqual(@as(i64, 11), root.get("all_time").?.object.get("events").?.integer);
    try testing.expect(root.get("all_time").?.object.get("by_agent").?.object.get("claude").? == .object);
    // No history store in this tree: burn is null because there is
    // nothing to read, not because the CLI refuses to compute it (see
    // the `--json carries the history object` test for the other half).
    try testing.expect(root.get("burn_tokens_per_min").? == .null);
    try testing.expectEqual(false, root.get("history").?.object.get("available").?.bool);
    try testing.expect(root.get("today").?.object.get("by_agent").? == .null);
    const limits = root.get("limits").?.object;
    try testing.expect(limits.get("claude").? == .null);
    try testing.expect(limits.get("claude_hint").? == .string);
    const codex_limits = limits.get("codex").?.object;
    try testing.expectEqualStrings("pro", codex_limits.get("plan").?.string);
    const windows = codex_limits.get("windows").?.array;
    try testing.expectEqual(@as(usize, 2), windows.items.len);
    try testing.expectEqualStrings("five_hour", windows.items[0].object.get("kind").?.string);
    try testing.expectEqual(@as(f64, 14.0), jsonNumber(windows.items[0].object.get("used_percent").?));
    try testing.expect(root.get("models").?.array.items.len == 3);
    try testing.expect(root.get("projects").?.array.items.len == 2);
    // The system object is always present; an unsampled snapshot renders
    // every module as null rather than omitting the key.
    const sys = root.get("system").?.object;
    try testing.expect(sys.get("cpu").? == .null);
    try testing.expect(sys.get("battery").? == .null);
}

test "jsonSystem maps live readings and rounds fractions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var snap = emptySnapshot(1);
    snap.system = .{
        .cpu = .{ .total_frac = 0.43456, .core_count = 14, .load_avg_1m = 3.25, .p_cluster_frac = null, .e_cluster_frac = null },
        .mem = .{ .used_bytes = 40, .total_bytes = 100, .used_frac = 0.4, .pressure = .warn },
        .net = .{ .total_bytes_in = 0, .total_bytes_out = 0, .in_bytes_per_sec = 1_234.9, .out_bytes_per_sec = null },
    };
    var aw = std.Io.Writer.Allocating.init(arena);
    try writeJson(&aw.writer, snap);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.writer.buffered(), .{});
    const sys = parsed.object.get("system").?.object;
    try testing.expectEqual(@as(f64, 0.435), jsonNumber(sys.get("cpu").?.object.get("utilization").?));
    try testing.expectEqualStrings("warn", sys.get("mem").?.object.get("pressure").?.string);
    try testing.expectEqual(@as(i64, 1234), sys.get("net").?.object.get("rx_bytes_per_sec").?.integer);
    try testing.expect(sys.get("net").?.object.get("tx_bytes_per_sec").? == .null);
    try testing.expect(sys.get("gpu").? == .null);
}

test "writeJson + writeStatusline: empty snapshot never crashes and says why" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = emptySnapshot(123_456);

    var aw = std.Io.Writer.Allocating.init(arena);
    try writeJson(&aw.writer, snap);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.writer.buffered(), .{});
    const root = parsed.object;
    try testing.expect(std.mem.indexOf(u8, root.get("note").?.string, "launch the app") != null);
    try testing.expectEqual(@as(i64, 0), root.get("today").?.object.get("tokens").?.integer);
    try testing.expect(root.get("limits").?.object.get("codex").? == .null);

    var aw2 = std.Io.Writer.Allocating.init(arena);
    try writeStatusline(&aw2.writer, snap);
    try testing.expectEqualStrings("⚡ tach · no data — launch the app once\n", aw2.writer.buffered());
}

test "writeStatusline: compact line with cost and codex windows" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = try collect(arena, io, try tree.env(arena, io), fixture_now_ms);

    var aw = std.Io.Writer.Allocating.init(arena);
    try writeStatusline(&aw.writer, snap);
    const line = aw.writer.buffered();

    try testing.expect(std.mem.startsWith(u8, line, "⚡ tach · today $"));
    // Single line, under ~60 visible chars (multi-byte glyphs make the
    // byte count a safe over-estimate).
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(line.len <= 70);
}

// ---- verb dispatch --------------------------------------------------------

test "dispatchFor: verbs come from argv[1] only, and unknown flags still launch the app" {
    // A verb in argv[1].
    try testing.expectEqual(Dispatch{ .verb = .history }, dispatchFor(&.{ "token-tach", "history" }));
    try testing.expectEqual(Dispatch{ .verb = .@"export" }, dispatchFor(&.{ "token-tach", "export", "--since", "7d" }));
    try testing.expectEqual(Dispatch{ .verb = .doctor }, dispatchFor(&.{ "token-tach", "doctor", "--history" }));

    // THE CONTRACT: an unrecognized LEADING FLAG is not a verb, is not a
    // mode, and must fall through to app launch. Breaking this breaks
    // every SDK-flagged invocation of the binary.
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{ "token-tach", "--webview-flag" }));
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{ "token-tach", "-x", "history" }));
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{ "token-tach", "--history" }));
    // A bare word that is not a verb is also a pass-through, not an error.
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{ "token-tach", "histor" }));
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{"token-tach"}));
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{}));
    // A verb never wins from a later position.
    try testing.expectEqual(Dispatch.app, dispatchFor(&.{ "token-tach", "--sdk", "top" }));

    // Flags keep working exactly as before, including behind a non-verb.
    try testing.expectEqual(Dispatch{ .mode = .json }, dispatchFor(&.{ "token-tach", "--json" }));
    try testing.expectEqual(Dispatch{ .mode = .bench }, dispatchFor(&.{ "token-tach", "--bench" }));
    try testing.expectEqual(Dispatch{ .mode = .version }, dispatchFor(&.{ "token-tach", "histor", "--version" }));

    // verbFor itself: anything dash-led is a flag, whatever follows.
    try testing.expectEqual(@as(?Verb, .burn), verbFor("burn"));
    try testing.expectEqual(@as(?Verb, null), verbFor("--burn"));
    try testing.expectEqual(@as(?Verb, null), verbFor("-h"));
    try testing.expectEqual(@as(?Verb, null), verbFor(""));
    try testing.expectEqualStrings("export", @tagName(Verb.@"export"));
}

// ---- time parsing ---------------------------------------------------------

test "parseWhen: relative ages, ISO dates, ISO timestamps, epoch ms" {
    const now: i64 = 1_783_598_400_000; // 2026-07-08T12:00:00Z

    try testing.expectEqual(TimePoint.now, parseWhen("now", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = now - 7 * 86_400_000 }, parseWhen("7d", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = now - 36 * 3_600_000 }, parseWhen("36h", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = now - 90 * 60_000 }, parseWhen("90m", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = now - 4 * 7 * 86_400_000 }, parseWhen("4w", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = now - 30_000 }, parseWhen("30s", now).?);
    // A leading minus is the same request, not a jump into the future.
    try testing.expectEqual(parseWhen("7d", now).?, parseWhen("-7d", now).?);

    // A date is a DATE — deliberately not an instant (see TimePoint).
    try testing.expectEqual(
        TimePoint{ .civil_day = daysFromCivil(2026, 6, 1) },
        parseWhen("2026-06-01", now).?,
    );
    // Timestamps are instants. A missing zone reads as UTC, and the two
    // spellings must agree exactly.
    const jun1 = claude.parseTimestamp("2026-06-01T12:00:00Z").?;
    try testing.expectEqual(TimePoint{ .instant_ms = jun1 }, parseWhen("2026-06-01T12:00:00Z", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = jun1 }, parseWhen("2026-06-01T12:00", now).?);
    try testing.expectEqual(TimePoint{ .instant_ms = jun1 }, parseWhen("2026-06-01T12:00:00", now).?);
    // An explicit offset is honored, not ignored.
    try testing.expectEqual(
        TimePoint{ .instant_ms = jun1 + 5 * 3_600_000 },
        parseWhen("2026-06-01T12:00:00-05:00", now).?,
    );
    // A bare integer is epoch MILLISECONDS, never seconds.
    try testing.expectEqual(TimePoint{ .instant_ms = 1_783_483_200_000 }, parseWhen("1783483200000", now).?);

    for ([_][]const u8{ "", "7x", "d7", "2026-13-01", "yesterday", "--json" }) |bad| {
        try testing.expectEqual(@as(?TimePoint, null), parseWhen(bad, now));
    }
}

test "bucketOf: a date means the local day on days.log, UTC midnight everywhere else" {
    const now: i64 = 1_783_598_400_000;
    const tz: i32 = -300; // UTC-5, the offset days.log was written at
    const jun1 = parseWhen("2026-06-01", now).?;

    // THE BOUNDARY CASE. Resolving the date through UTC midnight and
    // then re-bucketing at -300 would land on May 31 — the whole reason
    // TimePoint keeps dates and instants apart.
    try testing.expectEqual(
        @as(u32, @intCast(daysFromCivil(2026, 6, 1))),
        bucketOf(jun1, .day, now, tz),
    );
    // Same answer east of UTC, where the naive path errs the other way.
    try testing.expectEqual(
        @as(u32, @intCast(daysFromCivil(2026, 6, 1))),
        bucketOf(jun1, .day, now, 330),
    );
    // The UTC tiers get UTC midnight, and say so in their basis line.
    try testing.expectEqual(
        history_mod.hourBucket(daysFromCivil(2026, 6, 1) * 86_400_000),
        bucketOf(jun1, .hour, now, tz),
    );

    // An INSTANT near local midnight lands in the store's local day, not
    // the UTC one: 02:00Z on Jun 1 is still May 31 at UTC-5.
    const late = TimePoint{ .instant_ms = claude.parseTimestamp("2026-06-01T02:00:00Z").? };
    try testing.expectEqual(
        @as(u32, @intCast(daysFromCivil(2026, 5, 31))),
        bucketOf(late, .day, now, tz),
    );
    try testing.expectEqual(
        @as(u32, @intCast(daysFromCivil(2026, 6, 1))),
        bucketOf(late, .day, now, 0),
    );

    // bucketStartMs is the inverse, and must match history.zig's private
    // one or every rendered timestamp is off by the offset.
    const day_key = daysFromCivil(2026, 6, 1);
    try testing.expectEqual(
        day_key * 86_400_000 + 300 * 60_000,
        bucketStartMs(.day, @intCast(day_key), tz),
    );
    try testing.expectEqual(@as(i64, 0), bucketStartMs(.hour, 0, tz));
}

test "resolveRange reports the buckets it actually scanned, on every tier" {
    const io = testing.io;
    const now: i64 = 1_783_598_400_000;
    // No store: `dayTzOffset` is null, so the day tier keys at UTC. What
    // is under test is the ARITHMETIC, which must not depend on data.
    var reader = try history_mod.Reader.open(testing.allocator, io, "/nonexistent/token-tach-range-test");
    defer reader.deinit();

    var o = Opts{};
    try parseOpts(&o, &.{ "--since", "2025-10-09" }, now);

    // THE REGRESSION: a civil date is a DAY number, and feeding it to an
    // hour-tier start calculation renders 1972. The reported instant has
    // to come from the resolved bucket, never from the raw input.
    const hour = resolveRange(&reader, o, .hour, now);
    const oct9 = daysFromCivil(2025, 10, 9) * 86_400_000;
    try testing.expectEqual(oct9, hour.since_ms.?);
    try testing.expectEqual(history_mod.hourBucket(oct9), hour.from_bucket);
    try testing.expect(!hour.local);

    const day = resolveRange(&reader, o, .day, now);
    try testing.expectEqual(oct9, day.since_ms.?);
    try testing.expectEqual(@as(u32, @intCast(daysFromCivil(2025, 10, 9))), day.from_bucket);
    try testing.expect(day.local);

    // `until` defaults to now, and lands on the LAST millisecond of the
    // bucket that contains it — the window really is inclusive.
    try testing.expectEqual(history_mod.hourBucket(now), hour.to_bucket);
    try testing.expectEqual(bucketStartMs(.hour, history_mod.hourBucket(now) + 1, 0) - 1, hour.until_ms);

    // A mid-bucket `--since` is reported at the bucket boundary, because
    // that is what got scanned.
    var mid = Opts{};
    try parseOpts(&mid, &.{ "--since", "2025-10-09T14:37:11Z" }, now);
    const r = resolveRange(&reader, mid, .hour, now);
    try testing.expectEqual(oct9 + 14 * 3_600_000, r.since_ms.?);

    // No `--since` at all reaches back to the start of the store.
    const all = resolveRange(&reader, .{}, .day, now);
    try testing.expectEqual(@as(?i64, null), all.since_ms);
    try testing.expectEqual(@as(u32, 0), all.from_bucket);
}

test "formatIso and civil round-trip across a leap day and the epoch" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIso(&buf, 0));
    try testing.expectEqualStrings(
        "2024-02-29T23:59:59Z",
        formatIso(&buf, claude.parseTimestamp("2024-02-29T23:59:59Z").?),
    );
    // Round-trip against the parser rather than a hand-computed epoch:
    // a magic constant only proves the two agree with the person who
    // typed it.
    const round = claude.parseTimestamp("2026-07-08T04:00:00Z").?;
    try testing.expectEqual(fixture_now_ms, round);
    try testing.expectEqualStrings("2026-07-08T04:00:00Z", formatIso(&buf, round));
    // Pre-epoch stays well-defined rather than trapping.
    try testing.expectEqualStrings("1969-12-31T00:00:00Z", formatIso(&buf, -86_400_000));

    var off: [8]u8 = undefined;
    try testing.expectEqualStrings("+00:00", formatOffset(&off, 0));
    try testing.expectEqualStrings("-05:00", formatOffset(&off, -300));
    try testing.expectEqualStrings("+05:30", formatOffset(&off, 330));
}

test "option parsing: values, --key=value, and the errors that are usage errors" {
    var o = Opts{};
    try parseOpts(&o, &.{ "--since", "7d", "--bucket=hour", "--group", "agent,project", "-n", "5", "--format", "csv" }, 0);
    try testing.expectEqual(history_mod.Tier.hour, o.tier.?);
    try testing.expect(o.group.agent and o.group.project);
    try testing.expect(!o.group.bucket);
    try testing.expectEqual(@as(usize, 5), o.limit);
    try testing.expectEqual(Format.csv, o.format.?);

    var agents = Opts{};
    try parseOpts(&agents, &.{ "--agent", "claude,codex" }, 0);
    try testing.expect(agents.agents.?.contains(.claude));
    try testing.expect(!agents.agents.?.contains(.opencode));

    // `--window 15m` and a bare minute count are the same window; a
    // sub-minute window rounds up to one rather than to zero.
    var win = Opts{};
    try parseOpts(&win, &.{ "--window", "15m" }, 0);
    try testing.expectEqual(@as(u32, 15), win.window_min);
    try parseOpts(&win, &.{ "--window", "2h" }, 0);
    try testing.expectEqual(@as(u32, 120), win.window_min);
    try parseOpts(&win, &.{ "--window", "30s" }, 0);
    try testing.expectEqual(@as(u32, 1), win.window_min);

    var bad = Opts{};
    try testing.expectError(error.UnknownOption, parseOpts(&bad, &.{"--nope"}, 0));
    try testing.expectError(error.MissingValue, parseOpts(&bad, &.{"--since"}, 0));
    try testing.expectError(error.BadTime, parseOpts(&bad, &.{ "--since", "soonish" }, 0));
    try testing.expectError(error.BadBucket, parseOpts(&bad, &.{ "--bucket", "week" }, 0));
    try testing.expectError(error.BadGroup, parseOpts(&bad, &.{ "--group", "agent,color" }, 0));
    try testing.expectError(error.BadAgent, parseOpts(&bad, &.{ "--agent", "clod" }, 0));
    try testing.expectError(error.BadFormat, parseOpts(&bad, &.{ "--format", "yaml" }, 0));
}

// ---- delimited output -----------------------------------------------------

test "csv/tsv escaping survives a project path with a comma, a quote, and a tab" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nasty = "/Users/x/proj, \"quoted\"\tname";
    var aw = std.Io.Writer.Allocating.init(arena);
    try writeCsvField(&aw.writer, nasty);
    // Quoted whole, with every embedded quote doubled — RFC 4180, so the
    // comma cannot shift the columns after it.
    try testing.expectEqualStrings(
        "\"/Users/x/proj, \"\"quoted\"\"\tname\"",
        aw.writer.buffered(),
    );

    // A plain field is emitted verbatim (no gratuitous quoting).
    var plain = std.Io.Writer.Allocating.init(arena);
    try writeCsvField(&plain.writer, "/Users/x/plain");
    try testing.expectEqualStrings("/Users/x/plain", plain.writer.buffered());

    // Leading/trailing spaces are load-bearing in a path, so they are
    // preserved by quoting rather than trimmed by a lenient parser.
    var spaced = std.Io.Writer.Allocating.init(arena);
    try writeCsvField(&spaced.writer, " lead");
    try testing.expectEqualStrings("\" lead\"", spaced.writer.buffered());

    // TSV has no quoting at all, so the separators are escaped instead.
    var tsv = std.Io.Writer.Allocating.init(arena);
    try writeTsvField(&tsv.writer, nasty);
    try testing.expectEqualStrings(
        "/Users/x/proj, \"quoted\"\\tname",
        tsv.writer.buffered(),
    );
    var back = std.Io.Writer.Allocating.init(arena);
    try writeTsvField(&back.writer, "a\\b\nc");
    try testing.expectEqualStrings("a\\\\b\\nc", back.writer.buffered());

    // A whole CSV row round-trips through a strict-ish reader: the field
    // count must not change because of the payload.
    var row = std.Io.Writer.Allocating.init(arena);
    try writeDelimited(&row.writer, &.{ "1", nasty, "2" }, .csv);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, row.writer.buffered(), "\n"));
    // One pair wrapping the field plus two doubled inner quotes.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, row.writer.buffered(), "\""));
}

// ---- verbs against a real store -------------------------------------------

/// Seed a history store under `<tmp>/state/token-tach/history` the same
/// way the app would: through the real Writer, then closed so the flock
/// is released before any reader runs.
fn seedHistory(io: std.Io, arena: std.mem.Allocator, env: Env, tz_offset_min: i32) !void {
    const dir = try history_mod.defaultDir(arena, env.xdg_state_home, env.home);
    var writer = try history_mod.Writer.open(testing.allocator, io, dir, .{
        .tz_offset_min = tz_offset_min,
        .now_ms = fixture_now_ms,
        .compact_on_open = false,
    });
    defer writer.deinit();
    try testing.expect(writer.enabled);

    // Two agents, two projects (one with a comma AND a quote in its
    // path), two sessions, three minutes.
    const evs = [_]struct { types.UsageEvent, f64 }{
        .{ mkHistEv(.claude, fixture_now_ms - 120_000, "claude-fable-5", nasty_project, "ses-a", 100), 1.5 },
        .{ mkHistEv(.claude, fixture_now_ms - 60_000, "claude-fable-5", nasty_project, "ses-a", 200), 2.5 },
        .{ mkHistEv(.codex, fixture_now_ms - 60_000, "gpt-5.2-codex", "/w/beta", "ses-b", 300), 4.0 },
    };
    for (evs) |pair| writer.record(pair[0], .{ .cost_usd = pair[1], .now_ms = fixture_now_ms });
    writer.flush();
}

const nasty_project = "/w/al,pha \"one\"";

fn mkHistEv(
    agent: types.Agent,
    ts: i64,
    model: []const u8,
    project: []const u8,
    session: []const u8,
    out: u64,
) types.UsageEvent {
    return .{
        .agent = agent,
        .timestamp_ms = ts,
        .model = model,
        .input_tokens = out * 2,
        .output_tokens = out,
        .cache_creation_tokens = 3,
        .cache_read_tokens = 4,
        .session_id = session,
        .cwd = project,
    };
}

const VerbOutput = struct { out: []const u8, err: []const u8 };

fn runVerbCapture(
    arena: std.mem.Allocator,
    io: std.Io,
    env: Env,
    verb: Verb,
    args: []const []const u8,
) !VerbOutput {
    var aw = std.Io.Writer.Allocating.init(arena);
    var ae = std.Io.Writer.Allocating.init(arena);
    try runVerb(testing.allocator, arena, io, &aw.writer, &ae.writer, env, fixture_now_ms, verb, args);
    return .{ .out = aw.writer.buffered(), .err = ae.writer.buffered() };
}

test "export: the stable CSV schema, escaped, with the basis note on stderr" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);
    try seedHistory(io, arena, env, 0);

    const r = try runVerbCapture(arena, io, env, .@"export", &.{ "--format", "csv", "--since", "7d" });

    // Column set is the contract. Any change here breaks every consumer.
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    try testing.expectEqualStrings(
        "bucket_ms,agent,model,project,session,input,output,cache_creation,cache_read,cost_usd,events,covered,synthetic",
        lines.next().?,
    );

    // The basis line goes to STDERR so a redirect yields a clean file,
    // and the file itself carries no `#` preamble.
    try testing.expect(std.mem.indexOf(u8, r.err, "basis=utc") != null);
    try testing.expect(std.mem.indexOf(u8, r.err, "bucket=hour") != null);
    try testing.expect(!std.mem.startsWith(u8, r.out, "#"));

    // The comma+quote project is quoted, so every data row still has the
    // same field count as the header.
    try testing.expect(std.mem.indexOf(u8, r.out, "\"/w/al,pha \"\"one\"\"\"") != null);
    var rows: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        rows += 1;
        try testing.expectEqual(@as(usize, 12), countUnquotedCommas(line));
    }
    // One hour bucket x {claude/fable/alpha/ses-a, codex/gpt/beta/ses-b}.
    try testing.expectEqual(@as(usize, 2), rows);
}

fn countUnquotedCommas(line: []const u8) usize {
    var in_quotes = false;
    var n: usize = 0;
    for (line) |ch| {
        if (ch == '"') in_quotes = !in_quotes;
        if (ch == ',' and !in_quotes) n += 1;
    }
    return n;
}

test "history/top/sessions/burn/doctor answer from the durable store" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);
    try seedHistory(io, arena, env, -300);

    // history --format json: the query object states its basis, which is
    // LOCAL on the day tier and carries the offset days.log was written
    // at (-300), not whatever this machine is set to.
    {
        const r = try runVerbCapture(arena, io, env, .history, &.{ "--format", "json", "--bucket", "day" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        const q = root.get("query").?.object;
        try testing.expectEqualStrings("day", q.get("bucket").?.string);
        try testing.expectEqualStrings("local", q.get("time_basis").?.string);
        try testing.expectEqual(@as(i64, -300), q.get("tz_offset_min").?.integer);
        const rows = root.get("rows").?.array;
        try testing.expectEqual(@as(usize, 1), rows.items.len);
        // 600 output + 1200 input + 3 cc + 4 cr, summed over 3 events.
        try testing.expectEqual(@as(i64, 600), rows.items[0].object.get("output").?.integer);
        try testing.expectEqual(@as(i64, 3), rows.items[0].object.get("events").?.integer);
    }

    // The UTC tiers say so too — the same query, a different basis.
    {
        const r = try runVerbCapture(arena, io, env, .history, &.{ "--format", "json", "--bucket", "hour" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        try testing.expectEqualStrings("utc", root.get("query").?.object.get("time_basis").?.string);
    }

    // The table format states the basis inline (nobody is redirecting it).
    {
        const r = try runVerbCapture(arena, io, env, .history, &.{"--bucket=day"});
        try testing.expect(std.mem.startsWith(u8, r.out, "# token-tach history"));
        try testing.expect(std.mem.indexOf(u8, r.out, "basis=local(-05:00)") != null);
        try testing.expect(std.mem.indexOf(u8, r.out, "bucket_ms") != null);
    }

    // A filter value the store has never seen is a hard stop, not a
    // silent "any" that answers with everything.
    {
        const r = try runVerbCapture(arena, io, env, .history, &.{ "--project", "/nope", "--format", "json" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        try testing.expectEqual(@as(usize, 0), root.get("rows").?.array.items.len);
        try testing.expect(std.mem.indexOf(u8, root.get("note").?.string, "/nope") != null);
    }

    // top --dim project: heaviest first, names resolved through the dict.
    {
        const r = try runVerbCapture(arena, io, env, .top, &.{ "--dim", "project", "--format", "json", "-n", "5" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        const rows = root.get("rows").?.array;
        try testing.expectEqual(@as(usize, 2), rows.items.len);
        try testing.expectEqualStrings(nasty_project, rows.items[0].object.get("project").?.string);
    }
    try testing.expectError(
        error.MissingDim,
        runVerbCapture(arena, io, env, .top, &.{"--format=json"}),
    );

    // sessions: one row per (session, agent), with the observed span.
    {
        const r = try runVerbCapture(arena, io, env, .sessions, &.{ "--format", "json" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        const rows = root.get("rows").?.array;
        try testing.expectEqual(@as(usize, 2), rows.items.len);
        for (rows.items) |row| {
            const o = row.object;
            try testing.expect(o.get("first_ms").?.integer <= o.get("last_ms").?.integer);
            try testing.expect(o.get("session").?.string.len > 0);
        }
    }

    // burn: the hot ring, always UTC, and honest about its 48 h reach.
    {
        const r = try runVerbCapture(arena, io, env, .burn, &.{ "--format", "json", "--window", "15m" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        try testing.expectEqualStrings("utc", root.get("time_basis").?.string);
        try testing.expectEqual(@as(i64, 15), root.get("window_min").?.integer);
        try testing.expectEqual(@as(i64, 1821), root.get("tokens").?.integer);
        try testing.expect(jsonNumber(root.get("tokens_per_min").?) > 0);
        try testing.expectEqual(false, root.get("beyond_hot_tier").?.bool);
    }
    {
        const r = try runVerbCapture(arena, io, env, .burn, &.{ "--format", "json", "--window", "72h" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        try testing.expectEqual(true, root.get("beyond_hot_tier").?.bool);
    }

    // doctor --history: every tier accounted for, no lock taken, and the
    // CRC scan reported as valid-vs-slots rather than asserted silently.
    {
        const r = try runVerbCapture(arena, io, env, .doctor, &.{ "--history", "--format", "json" });
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
        try testing.expectEqual(false, root.get("write_lock_taken").?.bool);
        try testing.expectEqual(@as(i64, 0), root.get("dangling_dict_ids").?.integer);
        const tiers = root.get("tiers").?.array;
        try testing.expectEqual(@as(usize, 3), tiers.items.len);
        for (tiers.items) |t| {
            const o = t.object;
            try testing.expectEqual(true, o.get("present").?.bool);
            try testing.expect(o.get("valid_records").?.integer > 0);
            try testing.expectEqual(@as(i64, 0), o.get("unreadable_slots").?.integer);
            const basis = o.get("time_basis").?.string;
            const is_day = std.mem.eql(u8, o.get("tier").?.string, "day");
            try testing.expectEqualStrings(if (is_day) "local" else "utc", basis);
        }
    }

    // Human doctor output names the directory and the lock posture.
    {
        const r = try runVerbCapture(arena, io, env, .doctor, &.{"--history"});
        try testing.expect(std.mem.indexOf(u8, r.out, "not taken (reader only)") != null);
        try testing.expect(std.mem.indexOf(u8, r.out, "hot.ring") != null);
        try testing.expect(std.mem.indexOf(u8, r.out, "days.log") != null);
    }
}

test "verbs against an absent store answer empty rather than failing" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);

    const r = try runVerbCapture(arena, io, env, .history, &.{"--format=json"});
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, r.out, .{})).object;
    try testing.expectEqual(@as(usize, 0), root.get("rows").?.array.items.len);

    const d = try runVerbCapture(arena, io, env, .doctor, &.{"--format=json"});
    const droot = (try std.json.parseFromSliceLeaky(std.json.Value, arena, d.out, .{})).object;
    for (droot.get("tiers").?.array.items) |t| {
        try testing.expectEqual(false, t.object.get("present").?.bool);
    }
}

test "--json carries the history object, a real burn, and per-agent first/last" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);
    try seedHistory(io, arena, env, 0);

    const snap = try collect(arena, io, env, fixture_now_ms);
    var aw = std.Io.Writer.Allocating.init(arena);
    try writeJson(&aw.writer, snap);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.writer.buffered(), .{})).object;

    const hist = root.get("history").?.object;
    try testing.expectEqual(true, hist.get("available").?.bool);
    // Three events, but two of them share a minute: the hot tier counts
    // BUCKETS, not records.
    try testing.expectEqual(@as(i64, 2), hist.get("hot_minutes").?.integer);
    try testing.expect(hist.get("records").?.integer > 0);
    try testing.expect(hist.get("bytes").?.integer > 0);
    try testing.expectEqual(@as(i64, 15), hist.get("burn_window_min").?.integer);
    try testing.expect(hist.get("first_ms").?.integer <= hist.get("last_ms").?.integer);
    // No state file was written, so the backfill gate is still unset.
    try testing.expectEqual(false, hist.get("backfilled").?.bool);

    // The apology is gone: burn is a number now. 1821 tokens (1200 in +
    // 600 out + 9 cache-creation + 12 cache-read) over a 15-minute
    // window — divided by the WINDOW, not by the two minutes that
    // happened to have data.
    const burn = jsonNumber(root.get("burn_tokens_per_min").?);
    try testing.expectApproxEqAbs(@as(f64, 1821.0 / 15.0), burn, 0.01);

    // today/month carry the per-agent split days.log can answer.
    const today = root.get("today").?.object;
    const split = today.get("by_agent").?.object;
    try testing.expectEqual(@as(i64, 2), split.get("claude").?.object.get("events").?.integer);
    try testing.expectEqual(@as(i64, 1), split.get("codex").?.object.get("events").?.integer);
    try testing.expectEqual(@as(i64, 0), split.get("goose").?.object.get("events").?.integer);
    try testing.expect(root.get("month").?.object.get("by_agent").? == .object);

    // Coverage gained a first/last per agent, from hours.log.
    for (root.get("coverage").?.array.items) |cov| {
        const o = cov.object;
        const agent = o.get("agent").?.string;
        if (std.mem.eql(u8, agent, "claude") or std.mem.eql(u8, agent, "codex")) {
            try testing.expect(o.get("first_seen_ms").? == .integer);
            try testing.expect(o.get("last_seen_ms").? == .integer);
        } else {
            try testing.expect(o.get("first_seen_ms").? == .null);
        }
    }
}

test "--statusline skips the history read entirely" {
    const io = testing.io;
    var tree = try TmpTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try tree.env(arena, io);
    try seedHistory(io, arena, env, 0);

    const lean = try collectWith(arena, io, env, fixture_now_ms, .{ .history = false });
    try testing.expectEqual(false, lean.history.available);
    try testing.expectEqual(@as(?f64, null), lean.history.burn_tokens_per_min);
    // The ledger side of the snapshot is unaffected.
    try testing.expectEqual(@as(u64, 11), lean.all.events);

    const full = try collectWith(arena, io, env, fixture_now_ms, .{ .history = true });
    try testing.expectEqual(true, full.history.available);
}

test "collect: missing home yields the empty story without errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = try collect(arena, testing.io, .{ .home = "/nonexistent/token-tach-cli-test" }, fixture_now_ms);
    try testing.expectEqual(statefile.RestoreOutcome.absent, snap.state);
    try testing.expectEqual(@as(u64, 0), snap.all.events);
    try testing.expectEqual(@as(?types.LimitSnapshot, null), snap.codex_limits);
    try testing.expectEqual(@as(usize, 0), snap.models.len);
}
