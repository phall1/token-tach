//! CLI mode: `token-tach --json` / `--statusline` print an instant
//! usage/limits snapshot and exit — the GUI never launches. This is the
//! statusline/scripting seam (PLAN.md v1.3): the same UI-free core the
//! app runs, driven once, read-only.
//!
//! Data path (LOCAL ONLY — no network, no keychain):
//!   1. config (`~/.config/token-tach/config`) for roots + enabled sources,
//!   2. `statefile.restore` re-hydrates tailers + ledger from the app's
//!      saved state (~2 ms warm path),
//!   3. ONE incremental sweep picks up bytes appended since the app last
//!      saved (or, with no state file, cold-parses full history — slower
//!      but correct),
//!   4. (--json only) live system telemetry sampled over a ~150 ms
//!      window — mach/sysctl/IOKit reads, still local-only,
//!   5. render.
//!
//! Guarantees:
//! - **Read-only.** `statefile.save` is never called; the app's state file
//!   is never written, so running alongside a live app instance is safe.
//! - **Never crashes.** Missing state/config/roots degrade to an empty
//!   snapshot with an explanatory `note`; exit is always 0 once a CLI
//!   flag was recognized.
//!
//! Honest omissions (v1):
//! - `burn_tokens_per_min` is always null: the ledger persists rollups,
//!   not per-event history, so a one-shot process can only see events
//!   appended since the app's last save — an arbitrary, misleading window
//!   for a rate. The app (which watches continuously) owns burn.
//! - `limits.claude` is always null: Claude plan limits are OAuth server
//!   truth, polled by the app only (statefile deliberately does not
//!   persist them). `claude_hint` says so in-band.
//! - `today`/`month` carry no per-agent split (the ledger's per-day
//!   rollup is agent-blended); `all_time.by_agent` has the split.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app_version = @import("app_version");

const types = @import("core/types.zig");
const config = @import("core/config.zig");
const claude = @import("core/claude.zig");
const codex = @import("core/codex.zig");
const opencode = @import("core/opencode.zig");
const pricing = @import("core/pricing.zig");
const ledger_mod = @import("core/ledger.zig");
const statefile = @import("core/statefile.zig");
const trayfmt = @import("core/trayfmt.zig");
const system = @import("core/system/system.zig");

pub const version: []const u8 = app_version.version;

/// Keep the statusline under ~60 visible chars (Claude Code renders it
/// in a single status row; long lines get cropped by narrow terminals).
pub const Mode = enum { json, statusline, help, version };

const top_n = 10;
const max_windows = 4;

// ---------------------------------------------------------------------------
// Entry point (called first thing in main)
// ---------------------------------------------------------------------------

/// Scan argv for a CLI flag; when one is present, run that mode against
/// stdout and return true (the caller should exit without launching the
/// GUI). No recognized flag → false, GUI proceeds. Unrecognized flags are
/// deliberately ignored — the SDK runner owns its own argv surface.
pub fn maybeRunCli(init: std.process.Init) !bool {
    const mode = detectMode(init.minimal.args) orelse return false;

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout_writer.interface;

    switch (mode) {
        .help => try w.writeAll(help_text),
        .version => try w.print("token-tach {s}\n", .{version}),
        .json, .statusline => {
            const now_ms = native_sdk.nowMs();
            const arena = init.arena.allocator();
            const env = Env{
                .home = init.environ_map.get("HOME") orelse "",
                .claude_config_dir = init.environ_map.get("CLAUDE_CONFIG_DIR"),
                .codex_home = init.environ_map.get("CODEX_HOME"),
                .opencode_db = init.environ_map.get("OPENCODE_DB"),
                .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
                .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
            };
            // Never crash: any collection failure (OOM, pathological fs)
            // degrades to the empty snapshot + note.
            var snap = collect(arena, init.io, env, now_ms) catch emptySnapshot(now_ms);
            if (mode == .json) {
                // Live machine telemetry needs a real-time window for its
                // delta-based rates; 150 ms keeps --json interactive. The
                // statusline path skips it entirely (it renders none of
                // this and is called on a tight cadence).
                var sampler = system.Sampler.init();
                snap.system = system.sampleOnce(&sampler, .{}, 150_000);
            }
            switch (mode) {
                .json => try writeJson(w, snap),
                .statusline => try writeStatusline(w, snap),
                else => unreachable,
            }
        },
    }
    try w.flush();
    return true;
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
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, arg, entry[0])) return entry[1];
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
    \\  token-tach --version      print the version, exit
    \\  token-tach --help         show this help
    \\
    \\The CLI reads the same local data as the app (Claude Code/Codex
    \\JSONL and OpenCode SQLite plus saved state) and never writes, polls,
    \\or touches the keychain. See docs/CLI.md for the JSON schema and a
    \\Claude Code statusline recipe.
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
    claude_total: ledger_mod.Totals = .{},
    codex_total: ledger_mod.Totals = .{},
    opencode_total: ledger_mod.Totals = .{},
    codex_limits: ?types.LimitSnapshot = null,
    models: []const Entry = &.{},
    projects: []const Entry = &.{},
    /// Live machine telemetry (--json only; sampled at invocation, not
    /// read from state). Empty for --statusline.
    system: system.Snapshot = .{},
};

pub fn emptySnapshot(now_ms: i64) Snapshot {
    return .{ .generated_at_ms = now_ms };
}

/// Build the snapshot: config → restore → one sweep → rollups. Read-only
/// on every file it touches. `arena` must be an arena allocator (nothing
/// allocated here is individually freed) and owns every slice in the
/// returned snapshot. Only allocation failure propagates.
pub fn collect(arena: std.mem.Allocator, io: std.Io, env: Env, now_ms: i64) !Snapshot {
    var snap = emptySnapshot(now_ms);

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

    // Warm path: restore offsets + rollups so the sweep below only reads
    // appended bytes. READ-ONLY — this module never calls statefile.save,
    // so it cannot corrupt the app's state or race a running instance.
    if (statefile.defaultPath(arena, env.xdg_state_home, env.home) catch null) |state_path| {
        snap.state = try statefile.restore(arena, io, state_path, &claude_tailer, &codex_tailer, &opencode_poller, &ledger);
        if (snap.state == .invalid) {
            // Restore guarantees pristine args on .invalid, but stay in
            // lockstep with engine.setup's belt-and-suspenders reinit.
            claude_tailer = claude.Tailer.init(arena);
            codex_tailer = codex.Tailer.init(arena);
            opencode_poller = opencode.Poller.init(arena);
            ledger = ledger_mod.Ledger.init(arena, 0);
        }
    }

    var prices: ?pricing.Db = pricing.Db.init(arena) catch null;

    // ONE incremental sweep per enabled source: appended bytes on the warm
    // path, full history on the cold path. Sweep errors degrade to
    // whatever was restored; they never fail the snapshot.
    if (cfg.sources.claude) {
        var sink = claude.ListSink.init(arena);
        _ = claude_tailer.sweepIncremental(arena, io, claude_roots, sink.sink(), now_ms) catch false;
        for (sink.events.items) |ev| {
            ledger.add(ev, if (prices) |*db| db.costOf(ev) else null) catch {};
        }
    }
    if (cfg.sources.codex) {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        _ = codex_tailer.sweepIncremental(io, arena, codex_roots, &events, now_ms) catch false;
        for (events.items) |ev| {
            ledger.add(ev, if (prices) |*db| db.costOf(ev) else null) catch {};
        }
        // Limits ride the tailer: restored from the state file and/or
        // refreshed by token_count lines the sweep just parsed. The
        // borrowed slices are arena-owned, so they outlive the tailer var.
        snap.codex_limits = codex_tailer.lastLimits();
    }
    if (cfg.sources.opencode) {
        var changes: std.ArrayList(opencode.Change) = .empty;
        opencode_poller.poll(arena, opencode_path, &changes) catch {};
        for (changes.items) |change| {
            const new_cost = if (prices) |*db| db.costOf(change.current) else null;
            if (change.previous) |old| {
                ledger.replace(old, if (prices) |*db| db.costOf(old) else null, change.current, new_cost) catch {};
            } else ledger.add(change.current, new_cost) catch {};
        }
    }

    snap.tz_offset_min = ledger.tz_offset_min;
    snap.today = ledger.today(now_ms);
    snap.month = monthTotals(&ledger, now_ms);
    snap.all = ledger.all;
    snap.claude_total = ledger.forAgent(.claude);
    snap.codex_total = ledger.forAgent(.codex);
    snap.opencode_total = ledger.forAgent(.opencode);
    snap.models = try topEntries(arena, ledger.per_model.keys(), ledger.per_model.values());
    snap.projects = try topEntries(arena, ledger.per_project.keys(), ledger.per_project.values());
    return snap;
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
    today: JsonTotals,
    month: JsonTotals,
    all_time: struct {
        cost_usd: f64,
        tokens: u64,
        events: u64,
        by_agent: struct { claude: JsonTotals, codex: JsonTotals, opencode: JsonTotals },
    },
    /// Always null in v1 — see the module doc for why.
    burn_tokens_per_min: ?f64,
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

    const out = JsonOut{
        .version = version,
        .generated_at_ms = snap.generated_at_ms,
        .tz_offset_min = snap.tz_offset_min,
        .note = noteFor(snap),
        .today = jsonTotals(snap.today),
        .month = jsonTotals(snap.month),
        .all_time = .{
            .cost_usd = roundUsd(snap.all.cost_usd),
            .tokens = snap.all.totalTokens(),
            .events = snap.all.events,
            .by_agent = .{
                .claude = jsonTotals(snap.claude_total),
                .codex = jsonTotals(snap.codex_total),
                .opencode = jsonTotals(snap.opencode_total),
            },
        },
        .burn_tokens_per_min = null,
        .limits = .{
            .codex = codex_limits,
            .claude = null,
            .claude_hint = "claude plan limits are OAuth server truth — run the app (claude-oauth = true) to see them",
        },
        .models = models,
        .projects = projects,
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
    try testing.expectEqual(@as(u64, 8), snap.claude_total.events);
    try testing.expectEqual(@as(u64, 3), snap.codex_total.events);
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
        try statefile.save(arena, io, state_path, &claude_tailer, &codex_tailer, &opencode_poller, &ledger);
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
    // Burn is honestly absent in v1.
    try testing.expect(root.get("burn_tokens_per_min").? == .null);
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
