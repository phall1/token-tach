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
//! Format: a single JSON object, `{"version": 2, ...}`, written atomically
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
const ledger_mod = @import("ledger.zig");

pub const format_version: u32 = 2;

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
const WireKeyed = struct { key: []const u8, totals: WireTotals };

const WireLedger = struct {
    tz_offset_min: i32 = 0,
    all: WireTotals = .{},
    claude: WireTotals = .{},
    codex: WireTotals = .{},
    opencode: WireTotals = .{},
    per_day: []const WireDay = &.{},
    per_model: []const WireKeyed = &.{},
    per_project: []const WireKeyed = &.{},
};

const WireState = struct {
    version: u32 = 0,
    claude_files: []const WireClaudeFile = &.{},
    claude_seen: []const []const u8 = &.{},
    codex_files: []const WireCodexFile = &.{},
    codex_limits: ?WireLimits = null,
    opencode_rows: []const WireOpenCodeRow = &.{},
    ledger: WireLedger = .{},
};

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

/// Snapshot both tailers and the ledger to `path` (atomic: `<path>.tmp` +
/// rename). Parent directories are created as needed. Call only from the
/// engine thread — the tailers must not be mid-feed.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *const claude.Tailer,
    codex_tailer: *const codex.Tailer,
    opencode_poller: *const opencode.Poller,
    ledger: *const ledger_mod.Ledger,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state = try toWire(arena, claude_tailer, codex_tailer, opencode_poller, ledger);
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
    ledger: *const ledger_mod.Ledger,
) !WireState {
    var state = WireState{ .version = format_version };

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

    // Ledger rollups.
    {
        var days: std.ArrayList(WireDay) = .empty;
        var dit = ledger.per_day.iterator();
        while (dit.next()) |entry| {
            try days.append(arena, .{ .day = entry.key_ptr.*, .totals = wireTotals(entry.value_ptr.*) });
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
        state.ledger = .{
            .tz_offset_min = ledger.tz_offset_min,
            .all = wireTotals(ledger.all),
            .claude = wireTotals(ledger.per_agent.get(.claude)),
            .codex = wireTotals(ledger.per_agent.get(.codex)),
            .opencode = wireTotals(ledger.per_agent.get(.opencode)),
            .per_day = try days.toOwnedSlice(arena),
            .per_model = try models.toOwnedSlice(arena),
            .per_project = try projects.toOwnedSlice(arena),
        };
    }

    return state;
}

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

/// Re-hydrate freshly-initialized tailers and ledger from `path`. Never
/// touches the arguments unless the file parsed cleanly at the right
/// version (so `.absent`/`.invalid` leave them pristine for a full
/// catch-up). Only OutOfMemory propagates — and can leave the arguments
/// partially hydrated; treat it as fatal or reinit everything.
pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    claude_tailer: *claude.Tailer,
    codex_tailer: *codex.Tailer,
    opencode_poller: *opencode.Poller,
    ledger: *ledger_mod.Ledger,
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

    ledger.tz_offset_min = state.ledger.tz_offset_min;
    ledger.all = unwireTotals(state.ledger.all);
    ledger.per_agent.set(.claude, unwireTotals(state.ledger.claude));
    ledger.per_agent.set(.codex, unwireTotals(state.ledger.codex));
    ledger.per_agent.set(.opencode, unwireTotals(state.ledger.opencode));
    for (state.ledger.per_day) |d| try ledger.putDay(d.day, unwireTotals(d.totals));
    for (state.ledger.per_model) |m| try ledger.putModel(m.key, unwireTotals(m.totals));
    for (state.ledger.per_project) |p| try ledger.putProject(p.key, unwireTotals(p.totals));

    return .restored;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const claude_fixture = @embedFile("fixtures/claude/session1.jsonl");
const codex_fixture = @embedFile("fixtures/codex/rollout-basic.jsonl");

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
    try save(testing.allocator, io, state_path, &h1.claude_tailer, &h1.codex_tailer, &h1.opencode_poller, &h1.ledger);

    // Fresh everything; restore.
    var h2 = Harness.init(0);
    defer h2.deinit();
    try testing.expectEqual(
        RestoreOutcome.restored,
        try restore(testing.allocator, io, state_path, &h2.claude_tailer, &h2.codex_tailer, &h2.opencode_poller, &h2.ledger),
    );

    // Ledger rollups come back bit-identical (including the tz offset the
    // day buckets were computed with).
    try testing.expectEqual(@as(i32, -300), h2.ledger.tz_offset_min);
    try expectTotalsEqual(h1.ledger.all, h2.ledger.all);
    try expectTotalsEqual(h1.ledger.forAgent(.claude), h2.ledger.forAgent(.claude));
    try expectTotalsEqual(h1.ledger.forAgent(.codex), h2.ledger.forAgent(.codex));
    try expectTotalsEqual(h1.ledger.forAgent(.opencode), h2.ledger.forAgent(.opencode));
    try testing.expectEqual(@as(u32, 1), h2.opencode_poller.seen.count());
    try testing.expectEqual(h1.ledger.per_day.count(), h2.ledger.per_day.count());
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
        try restore(testing.allocator, io, missing, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, &h.ledger),
    );

    // Corrupted JSON.
    try tmp.dir.writeFile(io, .{ .sub_path = "corrupt.json", .data = "{\"version\": 1, \"claude_files\": [{{{" });
    const corrupt = try std.fmt.allocPrint(arena, "{s}/corrupt.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.invalid,
        try restore(testing.allocator, io, corrupt, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, &h.ledger),
    );

    // Valid JSON, wrong version (with fields v1 has never heard of).
    try tmp.dir.writeFile(io, .{
        .sub_path = "future.json",
        .data = "{\"version\": 99, \"claude_files\": [{\"path\": \"/x\", \"offset\": 5}], \"hovercraft\": true}",
    });
    const future = try std.fmt.allocPrint(arena, "{s}/future.json", .{base});
    try testing.expectEqual(
        RestoreOutcome.invalid,
        try restore(testing.allocator, io, future, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, &h.ledger),
    );

    // Nothing leaked into the state on any failed path.
    try testing.expectEqual(@as(u32, 0), h.claude_tailer.files.count());
    try testing.expectEqual(@as(u32, 0), h.claude_tailer.seen.count());
    try testing.expectEqual(@as(u32, 0), h.codex_tailer.files.count());
    try testing.expectEqual(@as(u64, 0), h.ledger.all.events);
    try testing.expectEqual(@as(usize, 0), h.ledger.per_day.count());
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
    try save(testing.allocator, io, state_path, &h.claude_tailer, &h.codex_tailer, &h.opencode_poller, &h.ledger);

    // The final file exists; the tmp staging file does not.
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "\"version\":2") != null);
    const state_stat = try std.Io.Dir.cwd().statFile(io, state_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), state_stat.permissions.toMode() & 0o777);
    const state_dir = std.fs.path.dirname(state_path).?;
    const dir_stat = try std.Io.Dir.cwd().statFile(io, state_dir, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{state_path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, tmp_path, .{}));
}
