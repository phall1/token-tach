//! Persisted tailer + ledger state: what makes a warm launch near-instant.
//!
//! On a cold launch the engine re-parses every JSONL transcript (~hundreds
//! of ms of background catch-up). This module snapshots everything that
//! parse produced — per-file byte offsets, the claude dedup set, codex
//! per-file cumulative baselines + session attribution, the freshest codex
//! rate-limits reading, and the ledger rollups — into one versioned JSON
//! file, and re-hydrates freshly-initialized tailers/ledger from it so
//! catch-up only touches bytes appended since the last save.
//!
//! Format: a single JSON object, `{"version": 5, ...}`, written atomically
//! (tmp file + rename) at a caller-provided path (`defaultPath` yields
//! `$XDG_STATE_HOME/token-tach/tailers.json`, falling back to
//! `~/.local/state/...`) with mode 0600 inside a mode-0700 app state directory.
//! Unknown fields are ignored on read; any version mismatch, parse failure,
//! or read failure degrades to `.invalid`/`.absent`, and the caller falls back
//! to a full catch-up. The state file is a pure cache, never truth.
//!
//! Design notes:
//!
//! - **The claude dedup set is persisted in full.** Offsets alone cannot
//!   protect against old messages re-logged into NEW files after a restart
//!   (resumed sessions and subagent re-logs do exactly that), and a bloom
//!   filter's false positives would silently DROP real usage — a worse
//!   failure mode than a bigger file. Keys are ~55 bytes; a heavy month is
//!   a few tens of thousands of events, so the set costs on the order of
//!   1–3 MB of JSON — fine for a once-a-minute atomic write.
//! - **Ledger rollups ride along** because restored offsets mean history is
//!   never re-parsed: without the rollups the totals would silently reset.
//!   Costs are stored as f64 bit patterns (`cost_usd_bits`) so restored
//!   totals are bit-identical, not shortest-float-round-trip-identical.
//!   That includes the BOUNDED rollups (`per_hour`, `per_session`): they
//!   are derived from events the restored offsets guarantee we will never
//!   re-read, so leaving them out did not make them cheap — it made
//!   "today by hour" blank for the first minutes of every warm launch.
//!   Both maps are capped by the ledger itself (`max_hour_buckets`,
//!   `max_sessions`) and are re-seeded through `putHour`/`putSession`,
//!   which re-apply retention and LRU eviction on the way in, so a
//!   hand-edited or stale file cannot restore an unbounded map.
//! - **Only the PROCESS-lifetime session rollup lives here.** Per-session
//!   data exists at three lifetimes on purpose: `sessions.Roster` is
//!   INSTANT (live liveness, never persisted — a restored "running"
//!   agent would be a lie about a process that exited), `ledger.per_session`
//!   is PROCESS (this file), and the `history.zig` session dimension is
//!   FOREVER. Persisting the roster here would collapse two of them.
//! - **The `history` section is a gate, not a mirror.** `history.zig` is
//!   its own durable store with its own files; nothing about its contents
//!   is duplicated here. What is recorded is whether the one-time
//!   backfill has run — see `Backfill`.
//! - **Offsets are saved minus any partial-line carry**, so a restore
//!   re-reads that line from its start; carry buffers themselves are not
//!   persisted. For claude the dedup set makes the re-read idempotent; for
//!   codex the line had not reached the baseline yet, so re-parsing it is
//!   the correct continuation.
//! - Claude OAuth limit snapshots are NOT persisted: they are server truth
//!   and re-polled seconds after boot anyway.

const std = @import("std");
const types = @import("types.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const opencode = @import("opencode.zig");
const snapsource = @import("snapsource.zig");
const fleet_mod = @import("fleet.zig");
const ledger_mod = @import("ledger.zig");

/// Bumped on every wire change. `restore` demands an EXACT match, so no
/// older file is ever partially read: it is declined (`.invalid`) and the
/// boot path re-derives the whole thing with one full catch-up, after
/// which the next save is current. That is the entire upgrade mechanism —
/// there is no migration code here and there never has been.
///
/// v3 added the collector-fleet sections (`tailers`, `sqlite`,
/// `snapshots`) and `ledger.others`. v4 added `ledger.covered_per_day`
/// (subscription-value numerator). v5 adds the bounded ledger rollups
/// Wave 1 grew (`ledger.per_hour`, `ledger.per_session`) and the
/// `history` backfill gate.
pub const format_version: u32 = 5;

/// Hard ceiling on a plausible state file; anything bigger is corrupt.
const max_state_bytes = 64 * 1024 * 1024;

pub const RestoreOutcome = enum {
    /// State hydrated; catch-up will only re-read appended bytes.
    restored,
    /// No state file (first run / cleaned); do a full catch-up.
    absent,
    /// Unreadable, unparseable, or wrong version; state untouched — do a
    /// full catch-up. (The next save overwrites the bad file.)
    invalid,
};

/// The one-time history backfill gate.
///
/// `history.zig` is a durable store that starts EMPTY, and there is no
/// honest migration into it from a v4 statefile: the dimension
/// cross-product it needs (bucket x model x project x session, at minute
/// resolution) was never persisted. `per_day` is six blended scalars per
/// local day and `per_model`/`per_project` are all-time cumulative with
/// no time axis at all — you cannot factor a product back out of its
/// marginals. Any "migration" would be invented data, and this store is
/// the one place in the app that is TRUTH rather than cache.
///
/// The real history is still on disk: the agents' own JSONL/SQLite trees.
/// So the fix is not a migration but one cold-start catch-up run with the
/// history writer attached, and this struct is the flag that says it
/// happened. Running it twice would DOUBLE-COUNT — history records are
/// additive and event dedup belongs to the tailers, which have no memory
/// of a pass that ignored their offsets — so the gate is load-bearing,
/// not a nicety.
///
/// `dict_generation` is what makes the flag falsifiable. A quarantined or
/// rebuilt `history/dict.log` mints a fresh generation and every tier
/// file stamped with the old one is abandoned; the store is then empty
/// again and a `backfilled: true` from the previous generation is a claim
/// about files that no longer exist. Comparing generations turns that
/// from silent permanent data loss into one more catch-up.
///
/// This module only PERSISTS the gate. Deciding to run the backfill,
/// running it, and setting the fields is the engine's job.
pub const Backfill = struct {
    /// The catch-up-with-history-attached pass has completed.
    backfilled: bool = false,
    /// Newest event timestamp (unix ms) that pass covered. Kept so a
    /// resumed or extended backfill knows where the durable record
    /// already reaches; zero means "nothing covered".
    backfill_watermark_ms: i64 = 0,
    /// `history.Writer.dict.generation` the backfill ran against.
    dict_generation: u32 = 0,

    /// Whether the backfill still owes a run against the store currently
    /// on disk. Never backfilled, or backfilled into a dictionary
    /// generation that has since been replaced, both mean yes.
    pub fn needsRun(self: Backfill, current_dict_generation: u32) bool {
        return !self.backfilled or self.dict_generation != current_dict_generation;
    }
};

/// `$XDG_STATE_HOME/token-tach/tailers.json`, or
/// `<home>/.local/state/token-tach/tailers.json` when the env var is
/// unset/blank. Caller owns the returned path.
pub fn defaultPath(
    allocator: std.mem.Allocator,
    env_xdg_state_home: ?[]const u8,
    home: []const u8,
) ![]u8 {
    if (env_xdg_state_home) |raw| {
        const base = std.mem.trim(u8, raw, " \t");
        if (base.len > 0) {
            return std.fs.path.join(allocator, &.{ base, "token-tach", "tailers.json" });
        }
    }
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "token-tach", "tailers.json" });
}

// ---------------------------------------------------------------------------
// Wire format (std.json-serializable mirror structs)
// ---------------------------------------------------------------------------

const WireTotals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_creation: u64 = 0,
    cache_read: u64 = 0,
    /// f64 bit pattern — exact round-trip, no float formatting involved.
    cost_usd_bits: u64 = 0,
    events: u64 = 0,
};

const WireClaudeFile = struct {
    path: []const u8,
    offset: u64,
};

const WireCodexBaseline = struct { input: u64 = 0, cached: u64 = 0, output: u64 = 0 };

const WireCodexFile = struct {
    path: []const u8,
    offset: u64,
    baseline: ?WireCodexBaseline = null,
    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: []const u8 = "",
};

const WireOpenCodeRow = struct {
    id: []const u8,
    updated_ms: i64,
    timestamp_ms: i64,
    model: []const u8,
    input: u64 = 0,
    output: u64 = 0,
    cache_creation: u64 = 0,
    cache_read: u64 = 0,
    session_id: []const u8 = "",
    cwd: []const u8 = "",
};

const WireLimits = struct {
    read_at_ms: i64 = 0,
    plan: []const u8 = "",
    windows: []const types.LimitWindow = &.{},
};

const WireDay = struct { day: i64, totals: WireTotals };
/// Subscription-covered cost for one day; f64 bit pattern for an exact
/// round-trip like WireTotals.cost_usd_bits.
const WireCoveredDay = struct { day: i64, cost_usd_bits: u64 = 0 };
const WireKeyed = struct { key: []const u8, totals: WireTotals };

/// One agent's slice of an hour bucket. Split out by stable label rather
/// than written as a fixed array so adding a types.Agent member neither
/// invalidates old files nor renumbers anything.
const WireHourAgent = struct { agent: []const u8, totals: WireTotals };

/// One bounded hourly bucket (`ledger.HourBucket`). `per_agent` carries
/// only the agents that actually have events in the hour: the full
/// cross-product would be ~336 buckets x every Agent member of mostly
/// zeroes, which is pure file size for no information.
const WireHour = struct {
    hour: i64,
    totals: WireTotals = .{},
    per_agent: []const WireHourAgent = &.{},
};

/// One PROCESS-lifetime session rollup (`ledger.SessionRollup`). The
/// agent rides as a stable label, so a session whose agent was removed
/// from the build is dropped on restore rather than mis-attributed.
const WireSession = struct {
    id: []const u8,
    agent: []const u8,
    totals: WireTotals = .{},
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
};

/// The history backfill gate — see `Backfill` for why this is a flag and
/// not a migration.
const WireBackfill = struct {
    backfilled: bool = false,
    backfill_watermark_ms: i64 = 0,
    dict_generation: u32 = 0,
};

/// One fleet JSONL-tailer file: line-boundary offset plus the cwd
/// attribution captured from meta lines before that offset.
const WireTailerFile = struct {
    path: []const u8,
    offset: u64,
    cwd: []const u8 = "",
};

/// One fleet JSONL tailer, keyed by the agent's stable label.
const WireTailer = struct {
    agent: []const u8,
    files: []const WireTailerFile = &.{},
    seen: []const []const u8 = &.{},
};

/// One fleet SQLite poller's high-water mark (goose rowid / kilo
/// time_updated ms), keyed by the agent's stable label.
const WireSqlite = struct {
    agent: []const u8,
    high_water: i64 = 0,
};

/// One snapshot-poller file: the mtime/size change gate plus every
/// stable record baseline (snapsource.Poller.WireRecord is JSON-shaped).
const WireSnapFile = struct {
    path: []const u8,
    mtime_ns: i96 = 0,
    size: u64 = 0,
    records: []const snapsource.Poller.WireRecord = &.{},
};

/// One fleet snapshot poller, keyed by its stable fleet.SnapName tag.
const WireSnapPoller = struct {
    name: []const u8,
    files: []const WireSnapFile = &.{},
};

/// Per-agent all-time totals for every agent beyond claude/codex/
/// opencode that has events, keyed by the agent's stable label.
const WireAgentTotals = struct {
    agent: []const u8,
    totals: WireTotals = .{},
};

const WireLedger = struct {
    tz_offset_min: i32 = 0,
    all: WireTotals = .{},
    claude: WireTotals = .{},
    codex: WireTotals = .{},
    opencode: WireTotals = .{},
    others: []const WireAgentTotals = &.{},
    per_day: []const WireDay = &.{},
    covered_per_day: []const WireCoveredDay = &.{},
    per_hour: []const WireHour = &.{},
    per_model: []const WireKeyed = &.{},
    per_project: []const WireKeyed = &.{},
    per_session: []const WireSession = &.{},
};

const WireState = struct {
    version: u32 = 0,
    claude_files: []const WireClaudeFile = &.{},
    claude_seen: []const []const u8 = &.{},
    codex_files: []const WireCodexFile = &.{},
    codex_limits: ?WireLimits = null,
    opencode_rows: []const WireOpenCodeRow = &.{},
    tailers: []const WireTailer = &.{},
    sqlite: []const WireSqlite = &.{},
    snapshots: []const WireSnapPoller = &.{},
    ledger: WireLedger = .{},
    history: WireBackfill = .{},
};

/// Stable label -> Agent (labels are the persisted identity; enum
/// ordinals may reorder freely across versions). Unknown labels are
/// skipped by callers, so removed agents degrade gracefully.
fn agentFromLabel(label: []const u8) ?types.Agent {
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        if (std.mem.eql(u8, agent.label(), label)) return agent;
    }
    return null;
}

fn wireTotals(t: ledger_mod.Totals) WireTotals {
    return .{
        .input = t.input_tokens,
        .output = t.output_tokens,
        .cache_creation = t.cache_creation_tokens,
        .cache_read = t.cache_read_tokens,
        .cost_usd_bits = @bitCast(t.cost_usd),
        .events = t.events,
    };
}

fn unwireTotals(w: WireTotals) ledger_mod.Totals {
    return .{
        .input_tokens = w.input,
        .output_tokens = w.output,
        .cache_creation_tokens = w.cache_creation,
        .cache_read_tokens = w.cache_read,
        .cost_usd = @bitCast(w.cost_usd_bits),
        .events = w.events,
    };
}

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

/// Snapshot the tailers, the collector fleet (when given), and the
/// ledger to `path` (atomic: `<path>.tmp` + rename). Parent directories
/// are created as needed. Call only from the engine thread — the
/// tailers must not be mid-feed. `fleet_opt` may be null (tests that
/// don't care); the fleet sections are then omitted.
///
/// Writes a DEFAULT (never-backfilled) history gate. A caller that owns a
/// history writer must use `saveWith` instead: saving through this entry
/// point clears the flag, and a cleared flag re-runs the one-time
/// backfill on the next boot, which double-counts (see `Backfill`).
/// Read-only and test callers with no history store are unaffected —
/// their gate is already default.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *const claude.Tailer,
    codex_tailer: *const codex.Tailer,
    opencode_poller: *const opencode.Poller,
    fleet_opt: ?*const fleet_mod.Fleet,
    ledger: *const ledger_mod.Ledger,
) !void {
    return saveWith(allocator, io, path, claude_tailer, codex_tailer, opencode_poller, fleet_opt, ledger, .{});
}

/// `save` plus the history backfill gate the caller owns. Separate entry
/// point rather than an extra parameter so the existing signature (and
/// the read-only CLI path that has no history store) keeps working.
pub fn saveWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *const claude.Tailer,
    codex_tailer: *const codex.Tailer,
    opencode_poller: *const opencode.Poller,
    fleet_opt: ?*const fleet_mod.Fleet,
    ledger: *const ledger_mod.Ledger,
    backfill: Backfill,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state = try toWire(arena, claude_tailer, codex_tailer, opencode_poller, fleet_opt, ledger, backfill);
    const json = try std.json.Stringify.valueAlloc(arena, state, .{});

    var cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir_path| {
        cwd.createDirPath(io, dir_path) catch {};
        setMode(arena, dir_path, 0o700);
    }
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = json });
    setMode(arena, tmp_path, 0o600);
    try cwd.rename(tmp_path, cwd, path, io);
    setMode(arena, path, 0o600);
}

extern fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

fn setMode(allocator: std.mem.Allocator, path: []const u8, mode: c_uint) void {
    const zpath = allocator.dupeZ(u8, path) catch return;
    _ = chmod(zpath.ptr, mode);
}

fn toWire(
    arena: std.mem.Allocator,
    claude_tailer: *const claude.Tailer,
    codex_tailer: *const codex.Tailer,
    opencode_poller: *const opencode.Poller,
    fleet_opt: ?*const fleet_mod.Fleet,
    ledger: *const ledger_mod.Ledger,
    backfill: Backfill,
) !WireState {
    var state = WireState{ .version = format_version, .history = .{
        .backfilled = backfill.backfilled,
        .backfill_watermark_ms = backfill.backfill_watermark_ms,
        .dict_generation = backfill.dict_generation,
    } };

    // Claude: offsets (minus carry — see module doc) and the dedup set.
    {
        var files: std.ArrayList(WireClaudeFile) = .empty;
        var it = claude_tailer.files.iterator();
        while (it.next()) |entry| {
            try files.append(arena, .{
                .path = entry.key_ptr.*,
                // -| : a feed()-fed key can hold carry without any offset.
                .offset = entry.value_ptr.offset -| entry.value_ptr.carry.items.len,
            });
        }
        state.claude_files = try files.toOwnedSlice(arena);

        var seen: std.ArrayList([]const u8) = .empty;
        var kit = claude_tailer.seen.keyIterator();
        while (kit.next()) |key| try seen.append(arena, key.*);
        state.claude_seen = try seen.toOwnedSlice(arena);
    }

    // OpenCode: stable row identities plus their latest safe usage snapshot.
    // This is sufficient to suppress duplicates and replace rows updated in
    // place after restart; no source payload text is persisted.
    {
        var rows: std.ArrayList(WireOpenCodeRow) = .empty;
        var it = opencode_poller.seen.iterator();
        while (it.next()) |entry| {
            const stored = entry.value_ptr.*;
            const ev = stored.event;
            try rows.append(arena, .{
                .id = entry.key_ptr.*,
                .updated_ms = stored.updated_ms,
                .timestamp_ms = ev.timestamp_ms,
                .model = ev.model,
                .input = ev.input_tokens,
                .output = ev.output_tokens,
                .cache_creation = ev.cache_creation_tokens,
                .cache_read = ev.cache_read_tokens,
                .session_id = ev.session_id,
                .cwd = ev.cwd,
            });
        }
        state.opencode_rows = try rows.toOwnedSlice(arena);
    }

    // Codex: offsets, baselines, session attribution, freshest limits.
    {
        var files: std.ArrayList(WireCodexFile) = .empty;
        var it = codex_tailer.files.iterator();
        while (it.next()) |entry| {
            const fs = entry.value_ptr;
            try files.append(arena, .{
                .path = entry.key_ptr.*,
                .offset = fs.offset -| fs.carry.items.len,
                .baseline = if (fs.baseline) |b|
                    .{ .input = b.input, .cached = b.cached, .output = b.output }
                else
                    null,
                .session_id = fs.session_id,
                .cwd = fs.cwd,
                .model = fs.model,
            });
        }
        state.codex_files = try files.toOwnedSlice(arena);

        if (codex_tailer.lastLimits()) |snap| {
            state.codex_limits = .{
                .read_at_ms = snap.read_at_ms,
                .plan = snap.plan,
                .windows = snap.windows,
            };
        }
    }

    // Collector fleet: JSONL offsets + dedup keys, SQLite high-water
    // marks, and snapshot-poller record baselines.
    if (fleet_opt) |fl| {
        var tailers: std.ArrayList(WireTailer) = .empty;
        for (fleet_mod.jsonl_agents) |agent| {
            const t = fl.tailerConst(agent) orelse continue;
            var files: std.ArrayList(WireTailerFile) = .empty;
            var it = t.files();
            while (it.next()) |entry| {
                try files.append(arena, .{
                    .path = entry.path,
                    .offset = entry.offset,
                    .cwd = entry.cwd,
                });
            }
            var seen: std.ArrayList([]const u8) = .empty;
            var kit = t.seen.keyIterator();
            while (kit.next()) |key| try seen.append(arena, key.*);
            if (files.items.len == 0 and seen.items.len == 0) continue;
            try tailers.append(arena, .{
                .agent = agent.label(),
                .files = try files.toOwnedSlice(arena),
                .seen = try seen.toOwnedSlice(arena),
            });
        }
        state.tailers = try tailers.toOwnedSlice(arena);

        var sqlite: std.ArrayList(WireSqlite) = .empty;
        for (fleet_mod.sqlite_agents) |agent| {
            const high_water = fl.highWater(agent) orelse continue;
            if (high_water == 0) continue;
            try sqlite.append(arena, .{ .agent = agent.label(), .high_water = high_water });
        }
        state.sqlite = try sqlite.toOwnedSlice(arena);

        var snaps: std.ArrayList(WireSnapPoller) = .empty;
        inline for (comptime std.enums.values(fleet_mod.SnapName)) |name| {
            var files: std.ArrayList(WireSnapFile) = .empty;
            var fit = fl.snapPollerConst(name).files();
            while (fit.next()) |entry| {
                var records: std.ArrayList(snapsource.Poller.WireRecord) = .empty;
                var rit = entry.records;
                while (rit.next()) |record| try records.append(arena, record);
                try files.append(arena, .{
                    .path = entry.path,
                    .mtime_ns = entry.mtime_ns,
                    .size = entry.size,
                    .records = try records.toOwnedSlice(arena),
                });
            }
            if (files.items.len != 0) {
                try snaps.append(arena, .{
                    .name = @tagName(name),
                    .files = try files.toOwnedSlice(arena),
                });
            }
        }
        state.snapshots = try snaps.toOwnedSlice(arena);
    }

    // Ledger rollups.
    {
        var days: std.ArrayList(WireDay) = .empty;
        var dit = ledger.per_day.iterator();
        while (dit.next()) |entry| {
            try days.append(arena, .{ .day = entry.key_ptr.*, .totals = wireTotals(entry.value_ptr.*) });
        }
        var covered_days: std.ArrayList(WireCoveredDay) = .empty;
        var cit = ledger.covered_per_day.iterator();
        while (cit.next()) |entry| {
            try covered_days.append(arena, .{ .day = entry.key_ptr.*, .cost_usd_bits = @bitCast(entry.value_ptr.*) });
        }
        // Hour buckets, each with the non-empty part of its per-agent
        // split. Bounded by ledger.max_hour_buckets, so this section is
        // hundreds of small objects, not an archive.
        var hours: std.ArrayList(WireHour) = .empty;
        var hit = ledger.per_hour.iterator();
        while (hit.next()) |entry| {
            const bucket = entry.value_ptr;
            var split: std.ArrayList(WireHourAgent) = .empty;
            inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
                const agent: types.Agent = @enumFromInt(field.value);
                const totals = bucket.per_agent.get(agent);
                if (totals.events != 0) {
                    try split.append(arena, .{ .agent = agent.label(), .totals = wireTotals(totals) });
                }
            }
            try hours.append(arena, .{
                .hour = entry.key_ptr.*,
                .totals = wireTotals(bucket.totals),
                .per_agent = try split.toOwnedSlice(arena),
            });
        }
        var sessions: std.ArrayList(WireSession) = .empty;
        var sit = ledger.per_session.iterator();
        while (sit.next()) |entry| {
            const rollup = entry.value_ptr;
            try sessions.append(arena, .{
                .id = entry.key_ptr.*,
                .agent = rollup.agent.label(),
                .totals = wireTotals(rollup.totals),
                .first_seen_ms = rollup.first_seen_ms,
                .last_seen_ms = rollup.last_seen_ms,
            });
        }
        var models: std.ArrayList(WireKeyed) = .empty;
        var mit = ledger.per_model.iterator();
        while (mit.next()) |entry| {
            try models.append(arena, .{ .key = entry.key_ptr.*, .totals = wireTotals(entry.value_ptr.*) });
        }
        var projects: std.ArrayList(WireKeyed) = .empty;
        var pit = ledger.per_project.iterator();
        while (pit.next()) |entry| {
            try projects.append(arena, .{ .key = entry.key_ptr.*, .totals = wireTotals(entry.value_ptr.*) });
        }
        var others: std.ArrayList(WireAgentTotals) = .empty;
        inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
            const agent: types.Agent = @enumFromInt(field.value);
            switch (agent) {
                .claude, .codex, .opencode => {},
                else => {
                    const totals = ledger.per_agent.get(agent);
                    if (totals.events != 0) {
                        try others.append(arena, .{
                            .agent = agent.label(),
                            .totals = wireTotals(totals),
                        });
                    }
                },
            }
        }
        state.ledger = .{
            .tz_offset_min = ledger.tz_offset_min,
            .all = wireTotals(ledger.all),
            .claude = wireTotals(ledger.per_agent.get(.claude)),
            .codex = wireTotals(ledger.per_agent.get(.codex)),
            .opencode = wireTotals(ledger.per_agent.get(.opencode)),
            .others = try others.toOwnedSlice(arena),
            .per_day = try days.toOwnedSlice(arena),
            .covered_per_day = try covered_days.toOwnedSlice(arena),
            .per_hour = try hours.toOwnedSlice(arena),
            .per_model = try models.toOwnedSlice(arena),
            .per_project = try projects.toOwnedSlice(arena),
            .per_session = try sessions.toOwnedSlice(arena),
        };
    }

    return state;
}

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

/// Re-hydrate freshly-initialized tailers, the collector fleet (when
/// given), and the ledger from `path`. Accepts EXACTLY `format_version`;
/// every older file (v2, v3, v4, ...) is declined as `.invalid` and the
/// caller does one full catch-up instead — there is no partial or
/// best-effort read of an older format. Never touches the arguments
/// unless the file parsed cleanly at that version (so `.absent`/
/// `.invalid` leave them pristine for that catch-up). Only OutOfMemory
/// propagates — and can leave the arguments partially hydrated; treat it
/// as fatal or reinit everything.
pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *claude.Tailer,
    codex_tailer: *codex.Tailer,
    opencode_poller: *opencode.Poller,
    fleet_opt: ?*fleet_mod.Fleet,
    ledger: *ledger_mod.Ledger,
) error{OutOfMemory}!RestoreOutcome {
    var ignored: Backfill = .{};
    return restoreWith(allocator, io, path, claude_tailer, codex_tailer, opencode_poller, fleet_opt, ledger, &ignored);
}

/// `restore` plus the history backfill gate, written into `backfill_out`.
///
/// Only a `.restored` outcome writes it, which is what makes the v5
/// upgrade self-executing: a v4 file returns `.invalid`, `backfill_out`
/// keeps the caller's default (`backfilled = false`), and the same full
/// catch-up that rebuilds the ledger is the one that seeds history —
/// with the writer attached, once, and never again.
pub fn restoreWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *claude.Tailer,
    codex_tailer: *codex.Tailer,
    opencode_poller: *opencode.Poller,
    fleet_opt: ?*fleet_mod.Fleet,
    ledger: *ledger_mod.Ledger,
    backfill_out: *Backfill,
) error{OutOfMemory}!RestoreOutcome {
    var cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(max_state_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .absent,
        else => return .invalid,
    };
    defer allocator.free(data);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const state = std.json.parseFromSliceLeaky(WireState, arena_state.allocator(), data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    // Warm restore requires the exact current format. An older readable
    // file re-derives once: neither covered_per_day (v4) nor the hourly /
    // session rollups (v5) can be reconstructed from what earlier
    // versions wrote down, so `.invalid` here routes the boot path
    // through a one-time full catch-up, after which the next save is
    // current. That catch-up is also the history backfill (see
    // `Backfill`), so the upgrade executes itself.
    // A newer file (downgrade) is never guessed at.
    if (state.version != format_version) return .invalid;

    for (state.claude_files) |f| try claude_tailer.restoreFile(f.path, f.offset);
    for (state.claude_seen) |key| try claude_tailer.restoreSeen(key);

    for (state.codex_files) |f| {
        try codex_tailer.restoreFile(f.path, .{
            .offset = f.offset,
            .baseline = if (f.baseline) |b|
                .{ .input = b.input, .cached = b.cached, .output = b.output }
            else
                null,
            .session_id = f.session_id,
            .cwd = f.cwd,
            .model = f.model,
        });
    }
    if (state.codex_limits) |l| {
        try codex_tailer.restoreLimits(l.read_at_ms, l.plan, l.windows);
    }
    for (state.opencode_rows) |row| {
        try opencode_poller.restore(row.id, row.updated_ms, .{
            .agent = .opencode,
            .timestamp_ms = row.timestamp_ms,
            .model = row.model,
            .input_tokens = row.input,
            .output_tokens = row.output,
            .cache_creation_tokens = row.cache_creation,
            .cache_read_tokens = row.cache_read,
            .session_id = row.session_id,
            .cwd = row.cwd,
        });
    }

    if (fleet_opt) |fl| {
        for (state.tailers) |wt| {
            const agent = agentFromLabel(wt.agent) orelse continue;
            const t = fl.tailer(agent) orelse continue;
            for (wt.files) |f| {
                try t.seedOffset(f.path, f.offset);
                if (f.cwd.len > 0) try t.seedCwd(f.path, f.cwd);
            }
            for (wt.seen) |key| try t.seedSeen(key);
        }
        for (state.sqlite) |ws| {
            const agent = agentFromLabel(ws.agent) orelse continue;
            fl.seedHighWater(agent, ws.high_water);
        }
        for (state.snapshots) |wp| {
            const name = std.meta.stringToEnum(fleet_mod.SnapName, wp.name) orelse continue;
            const poller = fl.snapPoller(name);
            for (wp.files) |f| try poller.seed(f.path, f.mtime_ns, f.size, f.records);
        }
    }

    ledger.tz_offset_min = state.ledger.tz_offset_min;
    ledger.all = unwireTotals(state.ledger.all);
    ledger.per_agent.set(.claude, unwireTotals(state.ledger.claude));
    ledger.per_agent.set(.codex, unwireTotals(state.ledger.codex));
    ledger.per_agent.set(.opencode, unwireTotals(state.ledger.opencode));
    for (state.ledger.others) |o| {
        const agent = agentFromLabel(o.agent) orelse continue;
        ledger.per_agent.set(agent, unwireTotals(o.totals));
    }
    for (state.ledger.per_day) |d| try ledger.putDay(d.day, unwireTotals(d.totals));
    for (state.ledger.covered_per_day) |c| try ledger.putCoveredDay(c.day, @bitCast(c.cost_usd_bits));
    // putHour/putSession re-apply retention and LRU eviction, so the
    // bounded maps stay bounded no matter what the file claims, and the
    // insertion order below is irrelevant: a saved window already spans
    // at most `max_hour_buckets` contiguous keys, so no bucket in it can
    // fall outside the window anchored on any other bucket in it.
    for (state.ledger.per_hour) |h| {
        var bucket: ledger_mod.HourBucket = .{ .totals = unwireTotals(h.totals) };
        for (h.per_agent) |a| {
            const agent = agentFromLabel(a.agent) orelse continue;
            bucket.per_agent.set(agent, unwireTotals(a.totals));
        }
        try ledger.putHour(h.hour, bucket);
    }
    for (state.ledger.per_model) |m| try ledger.putModel(m.key, unwireTotals(m.totals));
    for (state.ledger.per_project) |p| try ledger.putProject(p.key, unwireTotals(p.totals));
    for (state.ledger.per_session) |s| {
        // No label match means the agent left the build; a rollup with no
        // owner would be attributed to whatever enum ordinal 0 happens to
        // be, so drop it.
        const agent = agentFromLabel(s.agent) orelse continue;
        try ledger.putSession(s.id, .{
            .agent = agent,
            .totals = unwireTotals(s.totals),
            .first_seen_ms = s.first_seen_ms,
            .last_seen_ms = s.last_seen_ms,
        });
    }

    backfill_out.* = .{
        .backfilled = state.history.backfilled,
        .backfill_watermark_ms = state.history.backfill_watermark_ms,
        .dict_generation = state.history.dict_generation,
    };

    return .restored;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const claude_fixture = @embedFile("fixtures/claude/session1.jsonl");
const codex_fixture = @embedFile("fixtures/codex/rollout-basic.jsonl");
const pi_fixture = @embedFile("fixtures/pi/session1.jsonl");
const cline_sdk_fixture = @embedFile("fixtures/cline/session1.messages.json");

const claude_session_id = "11111111-2222-4333-8444-555555555555";
const claude_session_rel = "claude/projects/slug/" ++ claude_session_id ++ ".jsonl";
const codex_rollout_rel =
    "codex/sessions/2025/10/09/rollout-2025-10-09T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl";

/// Everything one save/restore cycle needs, wired to a tmp dir.
const Harness = struct {
    claude_tailer: claude.Tailer,
    codex_tailer: codex.Tailer,
    opencode_poller: opencode.Poller,
    ledger: ledger_mod.Ledger,

    fn init(tz_offset_min: i32) Harness {
        return .{
            .claude_tailer = claude.Tailer.init(testing.allocator),
            .codex_tailer = codex.Tailer.init(testing.allocator),
            .opencode_poller = opencode.Poller.init(testing.allocator),
            .ledger = ledger_mod.Ledger.init(testing.allocator, tz_offset_min),
        };
    }

    fn deinit(self: *Harness) void {
        self.claude_tailer.deinit();
        self.codex_tailer.deinit();
        self.opencode_poller.deinit();
        self.ledger.deinit();
    }

    /// Sweep both trees, ingest every event at a distinctive cost, and
    /// return the number of events seen.
    fn sweepAndIngest(self: *Harness, io: std.Io, claude_root: []const u8, codex_root: []const u8) !usize {
        var sink = claude.ListSink.init(testing.allocator);
        defer sink.deinit();
        try self.claude_tailer.sweep(testing.allocator, io, &.{claude_root}, sink.sink());
        for (sink.events.items) |ev| try self.ledger.add(ev, 0.000123456789);

        var events: std.ArrayList(types.UsageEvent) = .empty;
        defer {
            codex.freeEvents(testing.allocator, events.items);
            events.deinit(testing.allocator);
        }
        try self.codex_tailer.sweep(io, testing.allocator, &.{codex_root}, &events);
        for (events.items) |ev| try self.ledger.add(ev, 0.000987654321);

        return sink.events.items.len + events.items.len;
    }
};

fn expectTotalsEqual(want: ledger_mod.Totals, got: ledger_mod.Totals) !void {
    try testing.expectEqual(want.input_tokens, got.input_tokens);
    try testing.expectEqual(want.output_tokens, got.output_tokens);
    try testing.expectEqual(want.cache_creation_tokens, got.cache_creation_tokens);
    try testing.expectEqual(want.cache_read_tokens, got.cache_read_tokens);
    // Bit-exact, not approximately equal: the whole point of cost_usd_bits.
    try testing.expectEqual(@as(u64, @bitCast(want.cost_usd)), @as(u64, @bitCast(got.cost_usd)));
    try testing.expectEqual(want.events, got.events);
}

test "defaultPath honors XDG_STATE_HOME and falls back to ~/.local/state" {
    const xdg = try defaultPath(testing.allocator, "/x/state", "/home/u");
    defer testing.allocator.free(xdg);
    try testing.expectEqualStrings("/x/state/token-tach/tailers.json", xdg);

    const blank = try defaultPath(testing.allocator, "  ", "/home/u");
    defer testing.allocator.free(blank);
    try testing.expectEqualStrings("/home/u/.local/state/token-tach/tailers.json", blank);

    const unset = try defaultPath(testing.allocator, null, "/home/u");
    defer testing.allocator.free(unset);
    try testing.expectEqualStrings("/home/u/.local/state/token-tach/tailers.json", unset);
}

test "statefile round-trip: identical totals, no re-reads, dedup survives restart" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "claude/projects/slug");
    try tmp.dir.createDirPath(io, "codex/sessions/2025/10/09");
    try tmp.dir.writeFile(io, .{ .sub_path = claude_session_rel, .data = claude_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = codex_rollout_rel, .data = codex_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const claude_root = try std.fmt.allocPrint(arena, "{s}/claude/projects", .{base});
    const codex_root = try std.fmt.allocPrint(arena, "{s}/codex/sessions", .{base});
    const state_path = try std.fmt.allocPrint(arena, "{s}/state/token-tach/tailers.json", .{base});

    // Cold parse, then save.
    var h1 = Harness.init(-300);
    defer h1.deinit();
    // 8 claude events + 3 codex events.
    try testing.expectEqual(@as(usize, 11), try h1.sweepAndIngest(io, claude_root, codex_root));
    const opencode_event = types.UsageEvent{
        .agent = .opencode,
        .timestamp_ms = 1_783_483_000_000,
        .model = "gpt-5.4",
        .input_tokens = 10,
        .output_tokens = 20,
        .cache_read_tokens = 30,
        .session_id = "ses_state",
        .cwd = "/work/private-project",
    };
    try h1.opencode_poller.restore("msg_state", 1_783_483_000_100, opencode_event);
    try h1.ledger.add(opencode_event, 0.0042);

    // Collector fleet: pi JSONL history + a cline SDK session store on
    // disk, goose/kilo high-water marks seeded as if polled.
    try tmp.dir.createDirPath(io, "pihome/agent/sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "pihome/agent/sessions/2026-01-05T00-00-00_019faaaa-bbbb-7ccc-8ddd-eeeeffff0001.jsonl",
        .data = pi_fixture,
    });
    try tmp.dir.createDirPath(io, "clinedata/sessions/s1");
    try tmp.dir.writeFile(io, .{
        .sub_path = "clinedata/sessions/s1/s1.messages.json",
        .data = cline_sdk_fixture,
    });
    const fleet_env = fleet_mod.Env{
        .home = try std.fmt.allocPrint(arena, "{s}/home", .{base}),
        .pi_home = try std.fmt.allocPrint(arena, "{s}/pihome", .{base}),
        .cline_data_dir = try std.fmt.allocPrint(arena, "{s}/clinedata", .{base}),
    };
    var f1 = try fleet_mod.Fleet.init(testing.allocator, fleet_env);
    defer f1.deinit();
    {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        var changes: std.ArrayList(snapsource.Change) = .empty;
        f1.sweep(arena, io, .{}, 1_000_000, &events, &changes);
        try testing.expectEqual(@as(usize, 2), events.items.len); // pi fixture
        try testing.expectEqual(@as(usize, 2), changes.items.len); // cline sdk fixture
        for (events.items) |ev| try h1.ledger.add(ev, 0.001);
        for (changes.items) |change| try h1.ledger.add(change.current, 0.002);
    }
    f1.seedHighWater(.goose, 42);
    f1.seedHighWater(.kilo, 1_234);

    try save(testing.allocator, io, state_path, &h1.claude_tailer, &h1.codex_tailer, &h1.opencode_poller, &f1, &h1.ledger);

    // Fresh everything; restore.
    var h2 = Harness.init(0);
    defer h2.deinit();
    var f2 = try fleet_mod.Fleet.init(testing.allocator, fleet_env);
    defer f2.deinit();
    try testing.expectEqual(
        RestoreOutcome.restored,
        try restore(testing.allocator, io, state_path, &h2.claude_tailer, &h2.codex_tailer, &h2.opencode_poller, &f2, &h2.ledger),
    );

    // Fleet state survived: pi offsets sit at EOF with the dedup keys
    // back, the cline snapshot gate holds, high-water marks persist —
    // a post-restore sweep re-reads and re-emits nothing.
    try testing.expectEqual(f1.pi.seen.count(), f2.pi.seen.count());
    try testing.expect(f2.pi.seen.count() > 0);
    try testing.expectEqual(@as(?i64, 42), f2.highWater(.goose));
    try testing.expectEqual(@as(?i64, 1_234), f2.highWater(.kilo));
    {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        var changes: std.ArrayList(snapsource.Change) = .empty;
        f2.sweep(arena, io, .{}, 1_060_000, &events, &changes);
        try testing.expectEqual(@as(usize, 0), events.items.len);
        try testing.expectEqual(@as(usize, 0), changes.items.len);
    }
    // ledger.others round-trips the fleet agents' rollups bit-exactly.
    try expectTotalsEqual(h1.ledger.forAgent(.pi), h2.ledger.forAgent(.pi));
    try expectTotalsEqual(h1.ledger.forAgent(.cline), h2.ledger.forAgent(.cline));
    try testing.expectEqual(@as(u64, 2), h2.ledger.forAgent(.pi).events);
    try testing.expectEqual(@as(u64, 2), h2.ledger.forAgent(.cline).events);

    // Ledger rollups come back bit-identical (including the tz offset the
    // day buckets were computed with).
    try testing.expectEqual(@as(i32, -300), h2.ledger.tz_offset_min);
    try expectTotalsEqual(h1.ledger.all, h2.ledger.all);
    try expectTotalsEqual(h1.ledger.forAgent(.claude), h2.ledger.forAgent(.claude));
    try expectTotalsEqual(h1.ledger.forAgent(.codex), h2.ledger.forAgent(.codex));
    try expectTotalsEqual(h1.ledger.forAgent(.opencode), h2.ledger.forAgent(.opencode));
    try testing.expectEqual(@as(u32, 1), h2.opencode_poller.seen.count());
    try testing.expectEqual(h1.ledger.per_day.count(), h2.ledger.per_day.count());
    // covered_per_day (v4) round-trips bit-exactly.
    try testing.expectEqual(h1.ledger.covered_per_day.count(), h2.ledger.covered_per_day.count());
    for (h1.ledger.covered_per_day.keys(), h1.ledger.covered_per_day.values()) |day, cost| {
        try testing.expectEqual(cost, h2.ledger.covered_per_day.get(day).?);
    }
    for (h1.ledger.per_day.keys(), h1.ledger.per_day.values()) |day, totals| {
        try expectTotalsEqual(totals, h2.ledger.per_day.get(day).?);
    }
    try testing.expectEqual(h1.ledger.per_model.count(), h2.ledger.per_model.count());
    for (h1.ledger.per_model.keys(), h1.ledger.per_model.values()) |model, totals| {
        try expectTotalsEqual(totals, h2.ledger.per_model.get(model).?);
    }
    try testing.expectEqual(h1.ledger.per_project.count(), h2.ledger.per_project.count());
    for (h1.ledger.per_project.keys(), h1.ledger.per_project.values()) |project, totals| {
        try expectTotalsEqual(totals, h2.ledger.per_project.get(project).?);
    }
    // per_hour (v5): buckets AND their per-agent split, which is what a
    // windowed AGENT SHARE reads before the first live event lands.
    try testing.expect(h1.ledger.per_hour.count() > 0);
    try testing.expectEqual(h1.ledger.per_hour.count(), h2.ledger.per_hour.count());
    try testing.expectEqual(h1.ledger.newest_hour, h2.ledger.newest_hour);
    for (h1.ledger.per_hour.keys(), h1.ledger.per_hour.values()) |hour, bucket| {
        const got = h2.ledger.per_hour.get(hour).?;
        try expectTotalsEqual(bucket.totals, got.totals);
        for (std.enums.values(types.Agent)) |agent| {
            try expectTotalsEqual(bucket.per_agent.get(agent), got.per_agent.get(agent));
        }
    }
    // per_session (v5): rollups, agent attribution, and the recency
    // timestamps eviction sorts on.
    try testing.expect(h1.ledger.per_session.count() > 0);
    try testing.expectEqual(h1.ledger.per_session.count(), h2.ledger.per_session.count());
    for (h1.ledger.per_session.keys(), h1.ledger.per_session.values()) |id, rollup| {
        const got = h2.ledger.forSession(id).?;
        try expectTotalsEqual(rollup.totals, got.totals);
        try testing.expectEqual(rollup.agent, got.agent);
        try testing.expectEqual(rollup.first_seen_ms, got.first_seen_ms);
        try testing.expectEqual(rollup.last_seen_ms, got.last_seen_ms);
    }
    try testing.expect(h2.ledger.forSession("ses_state") != null);

    // The codex limits reading survives without any file re-read.
    const limits = h2.codex_tailer.lastLimits().?;
    try testing.expectEqualStrings("pro", limits.plan);
    try testing.expectEqual(@as(usize, 2), limits.windows.len);
    try testing.expectEqual(@as(f64, 14.0), limits.windows[0].used_percent);
    try testing.expectEqual(@as(f64, 3.5), limits.windows[1].used_percent);

    // A post-restore sweep re-reads nothing: offsets already sit at EOF.
    try testing.expectEqual(@as(usize, 0), try h2.sweepAndIngest(io, claude_root, codex_root));
    try expectTotalsEqual(h1.ledger.all, h2.ledger.all);

    // Append genuinely new data + a re-log of an already-counted message
    // (same message.id + requestId) in a NEW file: only new events count —
    // the persisted dedup set catches the cross-restart re-log.
    const new_claude_line =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:10:00.000Z\"," ++
        "\"requestId\":\"req_z0000000000000000000001\",\"sessionId\":\"" ++ claude_session_id ++ "\"," ++
        "\"cwd\":\"/home/dev/example-project\",\"message\":{\"model\":\"claude-fable-5\"," ++
        "\"id\":\"msg_z0000000000000000000001\",\"usage\":{\"input_tokens\":40,\"output_tokens\":4," ++
        "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n";
    try tmp.dir.writeFile(io, .{
        .sub_path = claude_session_rel,
        .data = claude_fixture ++ new_claude_line,
    });
    // Re-log of fixture message A5 into a fresh subagent-style file.
    const relog_line =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:11:00.000Z\"," ++
        "\"requestId\":\"req_a0000000000000000000005\",\"sessionId\":\"" ++ claude_session_id ++ "\"," ++
        "\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_a0000000000000000000005\"," ++
        "\"usage\":{\"input_tokens\":500,\"output_tokens\":50,\"cache_creation_input_tokens\":3000," ++
        "\"cache_read_input_tokens\":7000}}}\n";
    try tmp.dir.createDirPath(io, "claude/projects/slug/" ++ claude_session_id ++ "/subagents");
    try tmp.dir.writeFile(io, .{
        .sub_path = "claude/projects/slug/" ++ claude_session_id ++ "/subagents/agent-relog.jsonl",
        .data = relog_line,
    });
    // Codex: one appended token_count; the restored baseline must yield a
    // per-turn diff, not the whole cumulative again.
    const codex_appendix =
        \\{"timestamp":"2025-10-09T12:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60000,"cached_input_tokens":45000,"output_tokens":3000,"reasoning_output_tokens":1000,"total_tokens":63000},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":400,"reasoning_output_tokens":100,"total_tokens":5400},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":15.0,"window_minutes":300,"resets_at":1760014800},"secondary":{"used_percent":3.75,"window_minutes":10080,"resets_at":1760400000},"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        \\
    ;
    try tmp.dir.writeFile(io, .{
        .sub_path = codex_rollout_rel,
        .data = codex_fixture ++ codex_appendix,
    });

    var sink = claude.ListSink.init(testing.allocator);
    defer sink.deinit();
    try h2.claude_tailer.sweep(testing.allocator, io, &.{claude_root}, sink.sink());
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(@as(u64, 40), sink.events.items[0].input_tokens);

    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        codex.freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try h2.codex_tailer.sweep(io, testing.allocator, &.{codex_root}, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    // Δinput 5000 − Δcached 4000, against the RESTORED baseline.
    try testing.expectEqual(@as(u64, 1000), events.items[0].input_tokens);
    try testing.expectEqual(@as(u64, 4000), events.items[0].cache_read_tokens);
    try testing.expectEqual(@as(u64, 400), events.items[0].output_tokens);
    // Attribution strings came back through the restore too.
    try testing.expectEqualStrings("gpt-5.2-codex", events.items[0].model);
    try testing.expectEqualStrings("0199aaaa-1111-7222-8333-444455556666", events.items[0].session_id);
    try testing.expectEqualStrings("/Users/dev/example-project", events.items[0].cwd);
}

test "restore outcomes: absent, corrupted, and version mismatch leave state pristine" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = Harness.init(0);
    defer h.deinit();

    // Missing file.
    const missing = try std.fmt.allocPrint(arena, "{s}/nope.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.absent,
        try restore(testing.allocator, io, missing, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger),
    );

    // Corrupted JSON.
    try tmp.dir.writeFile(io, .{ .sub_path = "corrupt.json", .data = "{\"version\": 1, \"claude_files\": [{{{" });
    const corrupt = try std.fmt.allocPrint(arena, "{s}/corrupt.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.invalid,
        try restore(testing.allocator, io, corrupt, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger),
    );

    // Valid JSON, wrong version (with fields v1 has never heard of).
    try tmp.dir.writeFile(io, .{
        .sub_path = "future.json",
        .data = "{\"version\": 99, \"claude_files\": [{\"path\": \"/x\", \"offset\": 5}], \"hovercraft\": true}",
    });
    const future = try std.fmt.allocPrint(arena, "{s}/future.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.invalid,
        try restore(testing.allocator, io, future, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger),
    );

    // Pre-fleet v1 is below the supported floor.
    try tmp.dir.writeFile(io, .{
        .sub_path = "v1.json",
        .data = "{\"version\": 1, \"claude_files\": [{\"path\": \"/x\", \"offset\": 5}]}",
    });
    const v1 = try std.fmt.allocPrint(arena, "{s}/v1.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.invalid,
        try restore(testing.allocator, io, v1, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger),
    );

    // Nothing leaked into the state on any failed path.
    try testing.expectEqual(@as(u32, 0), h.claude_tailer.files.count());
    try testing.expectEqual(@as(u32, 0), h.claude_tailer.seen.count());
    try testing.expectEqual(@as(u32, 0), h.codex_tailer.files.count());
    try testing.expectEqual(@as(u64, 0), h.ledger.all.events);
    try testing.expectEqual(@as(usize, 0), h.ledger.per_day.count());
}

test "an older state file re-derives (invalid -> full catch-up), leaving state pristine" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A minimal pre-fleet save: legacy sections only.
    try tmp.dir.writeFile(io, .{
        .sub_path = "v2.json",
        .data = "{\"version\":2,\"claude_files\":[{\"path\":\"/x/s1.jsonl\",\"offset\":57}]," ++
            "\"claude_seen\":[\"msg_v2|req_v2\"]," ++
            "\"ledger\":{\"tz_offset_min\":-300,\"all\":{\"input\":10,\"output\":2,\"events\":1}," ++
            "\"claude\":{\"input\":10,\"output\":2,\"events\":1}}}",
    });
    // A well-formed v4 file — everything v4 knew how to write, nothing
    // wrong with it except that it predates per_hour/per_session and the
    // history gate. It must still be DECLINED: that refusal is the whole
    // upgrade path, and the full catch-up it forces is the one run that
    // seeds history.zig (see `Backfill`). If this ever starts restoring,
    // the backfill silently never happens.
    try tmp.dir.writeFile(io, .{
        .sub_path = "v4.json",
        .data = "{\"version\":4,\"claude_files\":[{\"path\":\"/x/s1.jsonl\",\"offset\":57}]," ++
            "\"claude_seen\":[\"msg_v4|req_v4\"]," ++
            "\"ledger\":{\"tz_offset_min\":-300,\"all\":{\"input\":10,\"output\":2,\"events\":1}," ++
            "\"claude\":{\"input\":10,\"output\":2,\"events\":1}," ++
            "\"per_day\":[{\"day\":20000,\"totals\":{\"input\":10,\"output\":2,\"events\":1}}]," ++
            "\"covered_per_day\":[{\"day\":20000,\"cost_usd_bits\":4591870180066957722}]}}",
    });
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    for ([_][]const u8{ "v2.json", "v4.json" }) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, name });

        var h = Harness.init(0);
        defer h.deinit();
        var fl = try fleet_mod.Fleet.init(testing.allocator, .{ .home = "/nonexistent/old-state-test" });
        defer fl.deinit();

        // A caller's gate starts "never backfilled" and must stay that
        // way across a declined restore.
        var gate: Backfill = .{};
        try testing.expectEqual(
            RestoreOutcome.invalid,
            try restoreWith(testing.allocator, io, path, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, &fl, &h.ledger, &gate),
        );
        // Nothing hydrated — the caller re-inits and does a full catch-up.
        try testing.expectEqual(@as(u32, 0), h.claude_tailer.files.count());
        try testing.expectEqual(@as(u64, 0), h.ledger.all.events);
        try testing.expectEqual(@as(usize, 0), h.ledger.per_day.count());
        try testing.expect(gate.needsRun(7));
    }
}

test "the history backfill gate round-trips and survives a dictionary rebuild" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "{s}/gate.json", .{base});

    var h1 = Harness.init(0);
    defer h1.deinit();
    const written: Backfill = .{
        .backfilled = true,
        .backfill_watermark_ms = 1_783_483_000_000,
        .dict_generation = 0xC0FFEE,
    };
    try saveWith(testing.allocator, io, path, &h1.claude_tailer, &h1.codex_tailer, &h1.opencode_poller, null, &h1.ledger, written);

    var h2 = Harness.init(0);
    defer h2.deinit();
    var got: Backfill = .{};
    try testing.expectEqual(
        RestoreOutcome.restored,
        try restoreWith(testing.allocator, io, path, &h2.claude_tailer, &h2.codex_tailer, &h2.opencode_poller, null, &h2.ledger, &got),
    );
    try testing.expectEqual(written.backfilled, got.backfilled);
    try testing.expectEqual(written.backfill_watermark_ms, got.backfill_watermark_ms);
    try testing.expectEqual(written.dict_generation, got.dict_generation);

    // Same generation: the pass already ran, do not run it again.
    try testing.expect(!got.needsRun(0xC0FFEE));
    // A quarantined/rebuilt dict.log mints a new generation, which
    // abandons every tier file the old backfill wrote. The flag is then
    // a claim about files that no longer exist, so it must not hold.
    try testing.expect(got.needsRun(0xC0FFEF));

    // `save` (no gate) is the read-only/test entry point: it writes a
    // default gate, so a caller that owns history must use `saveWith`.
    try save(testing.allocator, io, path, &h1.claude_tailer, &h1.codex_tailer, &h1.opencode_poller, null, &h1.ledger);
    var after: Backfill = .{ .backfilled = true, .dict_generation = 0xC0FFEE };
    try testing.expectEqual(
        RestoreOutcome.restored,
        try restoreWith(testing.allocator, io, path, &h2.claude_tailer, &h2.codex_tailer, &h2.opencode_poller, null, &h2.ledger, &after),
    );
    try testing.expect(!after.backfilled);
}

test "restored hour and session maps stay inside their retention bounds" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "{s}/bounds.json", .{base});

    // Hand-build a v5 file that claims far more hours and sessions than
    // the ledger's ceilings allow. The statefile never writes one (the
    // saved maps are already capped), but a stale or edited file must not
    // be able to smuggle an unbounded map into a process that runs for
    // weeks — putHour/putSession re-apply the bounds on the way in.
    const hour_span = ledger_mod.max_hour_buckets + 100;
    const session_span = ledger_mod.max_sessions + 100;
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(arena, "{\"version\":5,\"ledger\":{\"tz_offset_min\":0,\"per_hour\":[");
    for (0..hour_span) |i| {
        if (i != 0) try json.append(arena, ',');
        try json.print(arena, "{{\"hour\":{d},\"totals\":{{\"output\":1,\"events\":1}}," ++
            "\"per_agent\":[{{\"agent\":\"claude\",\"totals\":{{\"output\":1,\"events\":1}}}}]}}", .{i});
    }
    try json.appendSlice(arena, "],\"per_session\":[");
    for (0..session_span) |i| {
        if (i != 0) try json.append(arena, ',');
        try json.print(arena, "{{\"id\":\"s-{d}\",\"agent\":\"codex\",\"totals\":{{\"output\":1,\"events\":1}}," ++
            "\"first_seen_ms\":{d},\"last_seen_ms\":{d}}}", .{ i, i, i });
    }
    // One session whose agent left the build: dropped, never mis-attributed.
    try json.appendSlice(arena, ",{\"id\":\"s-ghost\",\"agent\":\"hovercraft\",\"totals\":{\"output\":9,\"events\":1}}");
    try json.appendSlice(arena, "]}}");
    try tmp.dir.writeFile(io, .{ .sub_path = "bounds.json", .data = json.items });

    var h = Harness.init(0);
    defer h.deinit();
    try testing.expectEqual(
        RestoreOutcome.restored,
        try restore(testing.allocator, io, path, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger),
    );

    // Both maps sit at their ceiling, holding the NEWEST entries.
    try testing.expectEqual(ledger_mod.max_hour_buckets, h.ledger.per_hour.count());
    try testing.expectEqual(@as(i64, @intCast(hour_span - 1)), h.ledger.newest_hour);
    try testing.expect(h.ledger.per_hour.get(h.ledger.newest_hour) != null);
    try testing.expectEqual(
        @as(?ledger_mod.HourBucket, null),
        h.ledger.per_hour.get(h.ledger.newest_hour - @as(i64, @intCast(ledger_mod.max_hour_buckets))),
    );
    // The per-agent split rode along with the buckets that survived.
    try testing.expectEqual(
        @as(u64, 1),
        h.ledger.per_hour.get(h.ledger.newest_hour).?.per_agent.get(.claude).totalTokens(),
    );

    try testing.expectEqual(ledger_mod.max_sessions, h.ledger.per_session.count());
    var newest_buf: [1]ledger_mod.SessionRef = undefined;
    try testing.expectEqual(@as(usize, 1), h.ledger.sessionsByRecency(&newest_buf));
    try testing.expectEqual(@as(i64, @intCast(session_span - 1)), newest_buf[0].rollup.last_seen_ms);
    try testing.expectEqual(@as(?ledger_mod.SessionRollup, null), h.ledger.forSession("s-0"));
    try testing.expectEqual(@as(?ledger_mod.SessionRollup, null), h.ledger.forSession("s-ghost"));
}

test "save writes atomically and creates parent directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_path = try std.fmt.allocPrint(arena, "{s}/deeply/nested/dirs/tailers.json", .{base});

    var h = Harness.init(0);
    defer h.deinit();
    try save(testing.allocator, io, state_path, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, null, &h.ledger);

    // The final file exists; the tmp staging file does not.
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "\"version\":5") != null);
    const state_stat = try std.Io.Dir.cwd().statFile(io, state_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), state_stat.permissions.toMode() & 0o777);
    const state_dir = std.fs.path.dirname(state_path).?;
    const dir_stat = try std.Io.Dir.cwd().statFile(io, state_dir, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{state_path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, tmp_path, .{}));
}
