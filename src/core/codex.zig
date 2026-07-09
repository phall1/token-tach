//! OpenAI Codex CLI rollout tailer: token usage AND embedded rate limits.
//!
//! Codex writes append-only NDJSON "rollout" ledgers at
//! `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` (default
//! `~/.codex`). Lines look like `{"timestamp":"...","type":...,"payload":{...}}`.
//! The lines we care about:
//!
//! - `session_meta`   — `payload.session_id`, `payload.cwd`.
//! - `turn_context`   — `payload.model` (e.g. "gpt-5.5"), `payload.cwd`.
//! - `event_msg` with `payload.type == "token_count"`:
//!   `payload.info.total_token_usage` is CUMULATIVE per session
//!   (`{input_tokens, cached_input_tokens, output_tokens,
//!   reasoning_output_tokens, total_tokens}`); the same line embeds
//!   `payload.rate_limits` (`primary` = 5 h window, `secondary` = weekly,
//!   each `{used_percent, window_minutes, resets_at (epoch SECONDS)}`,
//!   plus `plan_type`).
//!
//! Verified against real rollout files (codex_cli 0.142.x):
//! `cached_input_tokens` is a subset of `input_tokens`, and
//! `reasoning_output_tokens` is a subset of `output_tokens`
//! (`total_tokens == input_tokens + output_tokens` on every observed line).
//! So per-turn deltas map to `types.UsageEvent` as:
//!   input_tokens  = Δinput − Δcached   (uncached input)
//!   cache_read    = Δcached
//!   output_tokens = Δoutput            (reasoning already included)
//!
//! Malformed lines never error — they are skipped. A cumulative total that
//! goes DOWN (session restart / compaction) is treated as a fresh baseline:
//! the new cumulative is emitted as one event.

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

/// Model string used when no `turn_context`/`session_meta` model was seen.
pub const default_model = "codex";

// ---------------------------------------------------------------------------
// Session roots
// ---------------------------------------------------------------------------

/// Resolve the Codex sessions roots. `$CODEX_HOME` may be a comma-separated
/// list (ccusage convention); each entry yields `<entry>/sessions`. When
/// unset (or empty), falls back to `<home>/.codex/sessions`.
/// Caller owns the returned slice and every string in it; release with
/// `freeSessionsDirs`.
pub fn sessionsDirs(
    allocator: Allocator,
    env_codex_home: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (env_codex_home) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const p = try std.fs.path.join(allocator, &.{ trimmed, "sessions" });
            errdefer allocator.free(p);
            try list.append(allocator, p);
        }
    }
    if (list.items.len == 0) {
        const p = try std.fs.path.join(allocator, &.{ home, ".codex", "sessions" });
        errdefer allocator.free(p);
        try list.append(allocator, p);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeSessionsDirs(allocator: Allocator, dirs: []const []const u8) void {
    for (dirs) |p| allocator.free(p);
    allocator.free(dirs);
}

// ---------------------------------------------------------------------------
// Event / snapshot ownership helpers
// ---------------------------------------------------------------------------

/// Free the strings of events emitted by `Tailer.feed`/`poll`/`sweep`
/// (they are duped with the event allocator passed to those calls).
pub fn freeEvents(allocator: Allocator, events: []const types.UsageEvent) void {
    for (events) |ev| {
        allocator.free(ev.model);
        allocator.free(ev.session_id);
        allocator.free(ev.cwd);
    }
}

/// Free a snapshot returned by `latestLimits`.
pub fn freeLimitSnapshot(allocator: Allocator, snap: types.LimitSnapshot) void {
    allocator.free(snap.plan);
    allocator.free(snap.windows);
}

// ---------------------------------------------------------------------------
// Tailer
// ---------------------------------------------------------------------------

/// Cumulative token counters as logged in `total_token_usage`.
/// Pub so statefile.zig can persist/restore per-file baselines.
pub const Cum = struct { input: u64 = 0, cached: u64 = 0, output: u64 = 0 };

/// How long the incremental sweep may go without a full tree re-walk.
pub const full_walk_interval_ms: i64 = 30_000;
/// How many recently-modified rollouts the incremental sweep stats per tick.
pub const hot_files_max = 8;

/// Incremental rollout tailer. Per file it keeps the byte offset, a
/// partial-line carry buffer, the last-seen cumulative totals (per-turn =
/// diff; the first token_count of a session emits the full cumulative), and
/// the session metadata (session id, cwd, model) seen so far.
pub const Tailer = struct {
    allocator: Allocator,
    files: std.StringHashMapUnmanaged(FileState) = .empty,
    inc: Incremental = .{},
    /// Freshest rate_limits reading seen while parsing token_count lines
    /// (plan owned by the tailer allocator). Kept current by feed/poll/
    /// sweep so the caller never has to re-read rollout files for limits.
    limits: ?Limits = null,

    pub const Limits = struct {
        read_at_ms: i64,
        plan: []const u8 = "",
        windows: [2]types.LimitWindow = undefined,
        window_count: u8 = 0,
    };

    /// Change-detection state for `sweepIncremental` (see claude.zig's
    /// twin for the full rationale: dir mtimes catch adds/removals, the
    /// hot list catches appends, a periodic full walk catches the rest).
    const Incremental = struct {
        dir_mtimes: std.StringHashMapUnmanaged(i96) = .empty,
        hot: std.ArrayList(HotFile) = .empty,
        last_full_walk_ms: ?i64 = null,

        const HotFile = struct { path: []u8, mtime_ns: i96 };

        fn deinit(self: *Incremental, gpa: Allocator) void {
            var it = self.dir_mtimes.keyIterator();
            while (it.next()) |key| gpa.free(key.*);
            self.dir_mtimes.deinit(gpa);
            for (self.hot.items) |h| gpa.free(h.path);
            self.hot.deinit(gpa);
        }
    };

    const FileState = struct {
        offset: u64 = 0,
        carry: std.ArrayList(u8) = .empty,
        baseline: ?Cum = null,
        /// Owned by the tailer allocator; empty = not seen yet.
        session_id: []const u8 = "",
        cwd: []const u8 = "",
        model: []const u8 = "",

        fn deinit(self: *FileState, gpa: Allocator) void {
            self.carry.deinit(gpa);
            if (self.session_id.len > 0) gpa.free(self.session_id);
            if (self.cwd.len > 0) gpa.free(self.cwd);
            if (self.model.len > 0) gpa.free(self.model);
            self.* = undefined;
        }
    };

    pub fn init(allocator: Allocator) Tailer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tailer) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.inc.deinit(self.allocator);
        if (self.limits) |l| {
            if (l.plan.len > 0) self.allocator.free(l.plan);
        }
        self.* = undefined;
    }

    /// The stored byte offset for `path`, or null if never touched.
    /// `offset == file size` means fully caught up.
    pub fn offsetFor(self: *const Tailer, path: []const u8) ?u64 {
        const state = self.files.get(path) orelse return null;
        return state.offset;
    }

    /// Borrow the freshest limits reading as a snapshot. The plan string
    /// and windows point into tailer-owned memory — copy before the next
    /// feed/poll/sweep/restore if you need them to survive.
    pub fn lastLimits(self: *const Tailer) ?types.LimitSnapshot {
        if (self.limits) |*l| {
            return .{
                .agent = .codex,
                .read_at_ms = l.read_at_ms,
                .plan = l.plan,
                .windows = l.windows[0..l.window_count],
            };
        }
        return null;
    }

    /// Statefile restore: everything the diffing logic needs to continue
    /// a file mid-stream — parse offset (always on a line boundary), the
    /// last cumulative totals, and the session attribution strings.
    pub const RestoredFile = struct {
        offset: u64,
        baseline: ?Cum = null,
        session_id: []const u8 = "",
        cwd: []const u8 = "",
        model: []const u8 = "",
    };

    pub fn restoreFile(self: *Tailer, path: []const u8, restored: RestoredFile) !void {
        const state = try self.stateFor(path);
        state.offset = restored.offset;
        state.carry.clearAndFree(self.allocator);
        state.baseline = restored.baseline;
        if (restored.session_id.len > 0) try setOwned(self.allocator, &state.session_id, restored.session_id);
        if (restored.cwd.len > 0) try setOwned(self.allocator, &state.cwd, restored.cwd);
        if (restored.model.len > 0) try setOwned(self.allocator, &state.model, restored.model);
    }

    /// Statefile restore: re-seed the freshest limits reading. Ignored when
    /// `windows` is empty or the tailer already holds a newer reading.
    pub fn restoreLimits(
        self: *Tailer,
        read_at_ms: i64,
        plan: []const u8,
        windows: []const types.LimitWindow,
    ) !void {
        if (windows.len == 0 or windows.len > 2) return;
        if (self.limits) |l| {
            if (l.read_at_ms > read_at_ms) return;
        }
        var next = Limits{ .read_at_ms = read_at_ms, .window_count = @intCast(windows.len) };
        @memcpy(next.windows[0..windows.len], windows);
        if (plan.len > 0) next.plan = try self.allocator.dupe(u8, plan);
        if (self.limits) |l| {
            if (l.plan.len > 0) self.allocator.free(l.plan);
        }
        self.limits = next;
    }

    fn stateFor(self: *Tailer, path: []const u8) !*FileState {
        const gop = try self.files.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                self.files.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    /// Feed raw appended bytes for `path`. Complete lines are consumed; a
    /// trailing partial line is carried until the next feed. Every emitted
    /// event's strings are duped with `event_allocator` (free with
    /// `freeEvents`). Malformed lines are skipped, never an error.
    pub fn feed(
        self: *Tailer,
        event_allocator: Allocator,
        path: []const u8,
        bytes: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) Allocator.Error!void {
        const state = try self.stateFor(path);
        try state.carry.appendSlice(self.allocator, bytes);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, state.carry.items, start, '\n')) |nl| {
            const line = state.carry.items[start..nl];
            start = nl + 1;
            try self.processLine(arena_state.allocator(), event_allocator, state, path, line, out);
            _ = arena_state.reset(.retain_capacity);
        }
        if (start > 0) {
            const rem = state.carry.items.len - start;
            std.mem.copyForwards(u8, state.carry.items[0..rem], state.carry.items[start..]);
            state.carry.shrinkRetainingCapacity(rem);
        }
    }

    /// Open `path`, read everything past the stored offset, and feed it.
    /// A shrunken file (rotation/truncation) resets offset and baseline.
    /// Missing/unreadable files are silently skipped.
    pub fn poll(
        self: *Tailer,
        io: std.Io,
        event_allocator: Allocator,
        path: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) Allocator.Error!void {
        const state = try self.stateFor(path);

        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
        defer file.close(io);
        const stat = file.stat(io) catch return;

        if (stat.size < state.offset) {
            state.offset = 0;
            state.carry.clearRetainingCapacity();
            state.baseline = null;
        }
        if (stat.size == state.offset) return;

        var read_buf: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        reader.seekTo(state.offset) catch return;
        const data = reader.interface.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer self.allocator.free(data);

        state.offset += data.len;
        try self.feed(event_allocator, path, data, out);
    }

    /// Remember the freshest rate_limits reading (newest timestamp wins).
    fn captureLimits(self: *Tailer, limits_value: std.json.Value, ts_ms: i64) Allocator.Error!void {
        if (self.limits) |prev| {
            if (ts_ms < prev.read_at_ms) return;
        }
        var next = Limits{ .read_at_ms = ts_ms };
        if (limitWindow(limits_value, "primary", .five_hour)) |w| {
            next.windows[next.window_count] = w;
            next.window_count += 1;
        }
        if (limitWindow(limits_value, "secondary", .weekly)) |w| {
            next.windows[next.window_count] = w;
            next.window_count += 1;
        }
        if (next.window_count == 0) return;
        // Keep ownership of the previous plan string when the newer line
        // lacks one (same defensive stance as latestLimits).
        next.plan = if (self.limits) |prev| prev.plan else "";
        if (getString(limits_value, "plan_type")) |plan| {
            const dup = try self.allocator.dupe(u8, plan);
            if (next.plan.len > 0) self.allocator.free(next.plan);
            next.plan = dup;
        }
        self.limits = next;
    }

    /// Cheap steady-state sweep — the codex twin of claude.zig's
    /// `sweepIncremental` (same three-tier strategy: dir mtimes, hot
    /// files, periodic full walk; see that doc comment). Full walks poll
    /// changed rollouts in chronological order, matching `sweep`.
    /// Returns true when any new bytes were parsed.
    pub fn sweepIncremental(
        self: *Tailer,
        io: std.Io,
        event_allocator: Allocator,
        sessions_roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
        now_ms: i64,
    ) Allocator.Error!bool {
        const due = if (self.inc.last_full_walk_ms) |last|
            now_ms - last >= full_walk_interval_ms
        else
            true;
        if (due or self.dirsChanged(io)) return self.fullWalk(io, event_allocator, sessions_roots, out, now_ms);
        return self.hotPass(io, event_allocator, out);
    }

    fn dirsChanged(self: *Tailer, io: std.Io) bool {
        var cwd = std.Io.Dir.cwd();
        var it = self.inc.dir_mtimes.iterator();
        while (it.next()) |entry| {
            const stat = cwd.statFile(io, entry.key_ptr.*, .{}) catch return true;
            if (stat.mtime.nanoseconds != entry.value_ptr.*) return true;
        }
        return false;
    }

    fn hotPass(
        self: *Tailer,
        io: std.Io,
        event_allocator: Allocator,
        out: *std.ArrayList(types.UsageEvent),
    ) Allocator.Error!bool {
        var changed = false;
        var cwd = std.Io.Dir.cwd();
        for (self.inc.hot.items) |*h| {
            const stat = cwd.statFile(io, h.path, .{}) catch continue;
            const known = self.offsetFor(h.path) orelse 0;
            if (stat.size == known) continue;
            try self.poll(io, event_allocator, h.path, out);
            h.mtime_ns = stat.mtime.nanoseconds;
            changed = true;
        }
        return changed;
    }

    fn fullWalk(
        self: *Tailer,
        io: std.Io,
        event_allocator: Allocator,
        sessions_roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
        now_ms: i64,
    ) Allocator.Error!bool {
        var next: Incremental = .{ .last_full_walk_ms = now_ms };
        errdefer next.deinit(self.allocator);

        var entries: std.ArrayList(StatPathEntry) = .empty;
        defer freeStatPathEntries(self.allocator, &entries);
        var cwd = std.Io.Dir.cwd();
        for (sessions_roots) |root| {
            if (cwd.statFile(io, root, .{})) |stat| {
                try putDirMtime(self.allocator, &next.dir_mtimes, root, stat.mtime.nanoseconds);
            } else |_| continue;
            collectRolloutsStat(self.allocator, io, root, &entries, &next.dir_mtimes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
        }
        std.mem.sort(StatPathEntry, entries.items, {}, StatPathEntry.lessThan);

        var changed = false;
        for (entries.items) |entry| {
            if (entry.size != (self.offsetFor(entry.abs) orelse 0)) {
                try self.poll(io, event_allocator, entry.abs, out);
                changed = true;
            }
            try insertHot(self.allocator, &next.hot, entry.abs, entry.mtime_ns);
        }

        self.inc.deinit(self.allocator);
        self.inc = next;
        return changed;
    }

    /// Scan every rollout file under the given sessions roots (in
    /// chronological YYYY/MM/DD + filename order) and poll each one,
    /// appending new events to `out`. Missing roots are skipped.
    pub fn sweep(
        self: *Tailer,
        io: std.Io,
        event_allocator: Allocator,
        sessions_roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) Allocator.Error!void {
        var entries: std.ArrayList(PathEntry) = .empty;
        defer freePathEntries(self.allocator, &entries);
        for (sessions_roots) |root| {
            collectRollouts(self.allocator, io, root, &entries) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
        }
        std.mem.sort(PathEntry, entries.items, {}, PathEntry.lessThan);
        for (entries.items) |entry| {
            try self.poll(io, event_allocator, entry.abs, out);
        }
    }

    /// Parse one complete line. Only allocation failures propagate; any
    /// schema surprise just skips the line.
    fn processLine(
        self: *Tailer,
        arena: Allocator,
        event_allocator: Allocator,
        state: *FileState,
        path: []const u8,
        line: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) Allocator.Error!void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (root != .object) return;
        const line_type = getString(root, "type") orelse return;
        const payload = getObject(root, "payload") orelse return;

        if (std.mem.eql(u8, line_type, "session_meta")) {
            if (getString(payload, "session_id")) |sid| try setOwned(self.allocator, &state.session_id, sid);
            if (getString(payload, "cwd")) |c| try setOwned(self.allocator, &state.cwd, c);
            // Not observed in the wild, but harmless if it ever appears.
            if (getString(payload, "model")) |m| try setOwned(self.allocator, &state.model, m);
            return;
        }
        if (std.mem.eql(u8, line_type, "turn_context")) {
            if (getString(payload, "model")) |m| try setOwned(self.allocator, &state.model, m);
            if (getString(payload, "cwd")) |c| try setOwned(self.allocator, &state.cwd, c);
            return;
        }
        if (!std.mem.eql(u8, line_type, "event_msg")) return;
        const payload_type = getString(payload, "type") orelse return;
        if (!std.mem.eql(u8, payload_type, "token_count")) return;

        const ts_str = getString(root, "timestamp") orelse return;
        const ts_ms = parseIso8601Ms(ts_str) orelse return;

        // Every token_count line embeds the account's current rate_limits;
        // capture them here so limits never require a separate file read.
        if (payload.object.get("rate_limits")) |rl| try self.captureLimits(rl, ts_ms);

        const info = getObject(payload, "info") orelse return;
        const usage = getObject(info, "total_token_usage") orelse return;
        const input = getU64(usage, "input_tokens") orelse return;
        const output = getU64(usage, "output_tokens") orelse return;
        const cached = getU64(usage, "cached_input_tokens") orelse 0;

        const cum = Cum{ .input = input, .cached = cached, .output = output };
        const base: Cum = if (state.baseline) |b|
            // Cumulative went down: session restarted / totals compacted.
            // Fresh baseline — the new cumulative is one whole event.
            (if (cum.input < b.input or cum.output < b.output or cum.cached < b.cached) Cum{} else b)
        else
            Cum{};
        state.baseline = cum;

        const d_input = cum.input - base.input;
        const d_cached = cum.cached - base.cached;
        const d_output = cum.output - base.output;
        if (d_input == 0 and d_cached == 0 and d_output == 0) return;

        const session_id = if (state.session_id.len > 0) state.session_id else sessionIdFromPath(path);
        const model_name = if (state.model.len > 0) state.model else default_model;

        const model_dup = try event_allocator.dupe(u8, model_name);
        errdefer event_allocator.free(model_dup);
        const session_dup = try event_allocator.dupe(u8, session_id);
        errdefer event_allocator.free(session_dup);
        const cwd_dup = try event_allocator.dupe(u8, state.cwd);
        errdefer event_allocator.free(cwd_dup);

        try out.append(event_allocator, .{
            .agent = .codex,
            .timestamp_ms = ts_ms,
            .model = model_dup,
            .input_tokens = d_input -| d_cached,
            .output_tokens = d_output,
            .cache_read_tokens = d_cached,
            .session_id = session_dup,
            .cwd = cwd_dup,
        });
    }
};

/// Fallback session id when no session_meta line was seen: the trailing
/// UUID of `rollout-<ts>-<uuid>.jsonl`, or the bare stem if it is shorter.
fn sessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    const uuid_len = 36;
    if (stem.len >= uuid_len) return stem[stem.len - uuid_len ..];
    return stem;
}

// ---------------------------------------------------------------------------
// Rate limits
// ---------------------------------------------------------------------------

/// Read the current limit state: the last `token_count` line of the newest
/// rollout file (files sorted by YYYY/MM/DD dir + filename across all roots;
/// if the newest file carries no limits — e.g. brand new session — older
/// files are tried in descending order). `primary` maps to `.five_hour`,
/// `secondary` to `.weekly`; `resets_at` epoch seconds become milliseconds.
/// Free the result with `freeLimitSnapshot`. Returns null when nothing
/// usable exists.
pub fn latestLimits(
    allocator: Allocator,
    io: std.Io,
    sessions_roots: []const []const u8,
) !?types.LimitSnapshot {
    var entries: std.ArrayList(PathEntry) = .empty;
    defer freePathEntries(allocator, &entries);
    for (sessions_roots) |root| {
        collectRollouts(allocator, io, root, &entries) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
    }
    std.mem.sort(PathEntry, entries.items, {}, PathEntry.lessThan);

    var i = entries.items.len;
    while (i > 0) {
        i -= 1;
        if (try limitsFromFile(allocator, io, entries.items[i].abs)) |snap| return snap;
    }
    return null;
}

fn limitsFromFile(allocator: Allocator, io: std.Io, path: []const u8) !?types.LimitSnapshot {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(data);

    const Extracted = struct {
        read_at_ms: i64,
        plan: []const u8, // slice into `data` / arena; duped on return
        windows: [2]types.LimitWindow,
        window_count: usize,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var last: ?Extracted = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        defer _ = arena_state.reset(.retain_capacity);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (root != .object) continue;
        const line_type = getString(root, "type") orelse continue;
        if (!std.mem.eql(u8, line_type, "event_msg")) continue;
        const payload = getObject(root, "payload") orelse continue;
        const payload_type = getString(payload, "type") orelse continue;
        if (!std.mem.eql(u8, payload_type, "token_count")) continue;
        const limits = getObject(payload, "rate_limits") orelse continue;
        const ts_str = getString(root, "timestamp") orelse continue;
        const ts_ms = parseIso8601Ms(ts_str) orelse continue;

        var ext = Extracted{
            .read_at_ms = ts_ms,
            .plan = "",
            .windows = undefined,
            .window_count = 0,
        };
        if (limitWindow(limits, "primary", .five_hour)) |w| {
            ext.windows[ext.window_count] = w;
            ext.window_count += 1;
        }
        if (limitWindow(limits, "secondary", .weekly)) |w| {
            ext.windows[ext.window_count] = w;
            ext.window_count += 1;
        }
        if (ext.window_count == 0) continue;
        if (getString(limits, "plan_type")) |plan| {
            // `plan` points into arena memory that is reset next line; the
            // extracted copy must outlive it.
            if (last) |prev| {
                if (prev.plan.len > 0) allocator.free(prev.plan);
            }
            ext.plan = try allocator.dupe(u8, plan);
        } else if (last) |prev| {
            // Keep ownership of the previous plan string if the newer line
            // lacks one (not observed, but cheap to be correct about).
            ext.plan = prev.plan;
        }
        last = ext;
    }

    const ext = last orelse return null;
    errdefer if (ext.plan.len > 0) allocator.free(ext.plan);

    const windows = try allocator.dupe(types.LimitWindow, ext.windows[0..ext.window_count]);
    errdefer allocator.free(windows);
    const plan = if (ext.plan.len > 0) ext.plan else try allocator.dupe(u8, "");

    return .{
        .agent = .codex,
        .read_at_ms = ext.read_at_ms,
        .plan = plan,
        .windows = windows,
    };
}

fn limitWindow(limits: std.json.Value, key: []const u8, kind: types.LimitWindow.Kind) ?types.LimitWindow {
    const obj = getObject(limits, key) orelse return null;
    const used = getF64(obj, "used_percent") orelse return null;
    const resets_at_s = getI64(obj, "resets_at") orelse 0;
    return .{
        .kind = kind,
        .used_percent = used,
        .resets_at_ms = resets_at_s * 1000,
    };
}

// ---------------------------------------------------------------------------
// Directory scan
// ---------------------------------------------------------------------------

const PathEntry = struct {
    /// Path relative to its sessions root ("YYYY/MM/DD/rollout-...jsonl");
    /// lexicographic order == chronological order.
    rel: []u8,
    abs: []u8,

    fn lessThan(_: void, a: PathEntry, b: PathEntry) bool {
        return std.mem.order(u8, a.rel, b.rel) == .lt;
    }
};

fn freePathEntries(allocator: Allocator, entries: *std.ArrayList(PathEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.rel);
        allocator.free(entry.abs);
    }
    entries.deinit(allocator);
}

/// A rollout path plus the stat facts the incremental sweep needs.
const StatPathEntry = struct {
    rel: []u8,
    abs: []u8,
    size: u64,
    mtime_ns: i96,

    fn lessThan(_: void, a: StatPathEntry, b: StatPathEntry) bool {
        return std.mem.order(u8, a.rel, b.rel) == .lt;
    }
};

fn freeStatPathEntries(allocator: Allocator, entries: *std.ArrayList(StatPathEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.rel);
        allocator.free(entry.abs);
    }
    entries.deinit(allocator);
}

/// Like collectRollouts, but stats every rollout file (one syscall each)
/// and records every directory's mtime into `dir_mtimes`.
fn collectRolloutsStat(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    out: *std.ArrayList(StatPathEntry),
    dir_mtimes: *std.StringHashMapUnmanaged(i96),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const stat = dir.statFile(io, entry.path, .{}) catch continue;
                const path = try std.fs.path.join(allocator, &.{ root, entry.path });
                defer allocator.free(path);
                try putDirMtime(allocator, dir_mtimes, path, stat.mtime.nanoseconds);
            },
            .file => {
                if (!std.mem.startsWith(u8, entry.basename, "rollout-")) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
                const stat = dir.statFile(io, entry.path, .{}) catch continue;
                const rel = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(rel);
                const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
                errdefer allocator.free(abs);
                try out.append(allocator, .{
                    .rel = rel,
                    .abs = abs,
                    .size = stat.size,
                    .mtime_ns = stat.mtime.nanoseconds,
                });
            },
            else => {},
        }
    }
}

/// Insert (path duped) into a map of owned dir paths → mtime.
fn putDirMtime(
    gpa: Allocator,
    map: *std.StringHashMapUnmanaged(i96),
    path: []const u8,
    mtime_ns: i96,
) !void {
    const gop = try map.getOrPut(gpa, path);
    if (gop.found_existing) {
        gop.value_ptr.* = mtime_ns;
        return;
    }
    gop.key_ptr.* = gpa.dupe(u8, path) catch |err| {
        map.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = mtime_ns;
}

/// Keep a small list of the most recently modified files, newest first.
fn insertHot(
    gpa: Allocator,
    hot: *std.ArrayList(Tailer.Incremental.HotFile),
    path: []const u8,
    mtime_ns: i96,
) !void {
    var at: usize = hot.items.len;
    for (hot.items, 0..) |h, i| {
        if (mtime_ns > h.mtime_ns) {
            at = i;
            break;
        }
    }
    if (at >= hot_files_max) return;
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try hot.insert(gpa, at, .{ .path = owned, .mtime_ns = mtime_ns });
    if (hot.items.len > hot_files_max) {
        const evicted = hot.pop().?;
        gpa.free(evicted.path);
    }
}

fn collectRollouts(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    out: *std.ArrayList(PathEntry),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "rollout-")) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        const rel = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(rel);
        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        errdefer allocator.free(abs);
        try out.append(allocator, .{ .rel = rel, .abs = abs });
    }
}

// ---------------------------------------------------------------------------
// JSON helpers (all null-tolerant)
// ---------------------------------------------------------------------------

fn getObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    if (child != .object) return null;
    return child;
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    if (child != .string) return null;
    return child.string;
}

fn getU64(v: std.json.Value, key: []const u8) ?u64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    if (child != .integer) return null;
    if (child.integer < 0) return null;
    return @intCast(child.integer);
}

fn getI64(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    if (child != .integer) return null;
    return child.integer;
}

fn getF64(v: std.json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    const child = v.object.get(key) orelse return null;
    return switch (child) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn setOwned(gpa: Allocator, slot: *[]const u8, value: []const u8) Allocator.Error!void {
    const dup = try gpa.dupe(u8, value);
    if (slot.len > 0) gpa.free(slot.*);
    slot.* = dup;
}

// ---------------------------------------------------------------------------
// ISO 8601 → Unix milliseconds
// ---------------------------------------------------------------------------

/// Parse "YYYY-MM-DDTHH:MM:SS(.fraction)?(Z|±HH:MM|±HHMM)?" into Unix ms.
/// No timezone suffix is treated as UTC (rollout lines always carry "Z").
pub fn parseIso8601Ms(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const year = parseDigits(s[0..4]) orelse return null;
    const month = parseDigits(s[5..7]) orelse return null;
    const day = parseDigits(s[8..10]) orelse return null;
    const hour = parseDigits(s[11..13]) orelse return null;
    const minute = parseDigits(s[14..16]) orelse return null;
    const second = parseDigits(s[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var idx: usize = 19;
    var frac_ms: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        var digits: usize = 0;
        while (idx < s.len and std.ascii.isDigit(s[idx])) : (idx += 1) {
            if (digits < 3) {
                frac_ms = frac_ms * 10 + (s[idx] - '0');
                digits += 1;
            }
        }
        if (digits == 0) return null;
        while (digits < 3) : (digits += 1) frac_ms *= 10;
    }

    var offset_minutes: i64 = 0;
    if (idx < s.len) {
        switch (s[idx]) {
            'Z', 'z' => {
                idx += 1;
                if (idx != s.len) return null;
            },
            '+', '-' => {
                const sign: i64 = if (s[idx] == '-') -1 else 1;
                idx += 1;
                if (s.len < idx + 2) return null;
                const oh = parseDigits(s[idx .. idx + 2]) orelse return null;
                idx += 2;
                if (idx < s.len and s[idx] == ':') idx += 1;
                var om: i64 = 0;
                if (idx < s.len) {
                    if (s.len != idx + 2) return null;
                    om = parseDigits(s[idx .. idx + 2]) orelse return null;
                    idx += 2;
                }
                if (oh > 23 or om > 59) return null;
                offset_minutes = sign * (oh * 60 + om);
            },
            else => return null,
        }
    }

    const days = daysFromCivil(year, month, day);
    const secs = days * 86400 + hour * 3600 + minute * 60 + second - offset_minutes * 60;
    return secs * 1000 + frac_ms;
}

fn parseDigits(s: []const u8) ?i64 {
    var v: i64 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Howard Hinnant's days-from-civil: days since 1970-01-01 for a proleptic
/// Gregorian date.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(month + 9, 12); // Mar=0 .. Feb=11
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture_basic = @embedFile("fixtures/codex/rollout-basic.jsonl");
const fixture_reset = @embedFile("fixtures/codex/rollout-reset.jsonl");
const fixture_malformed = @embedFile("fixtures/codex/rollout-malformed.jsonl");

test "sessionsDirs falls back to <home>/.codex/sessions" {
    const dirs = try sessionsDirs(testing.allocator, null, "/Users/somebody");
    defer freeSessionsDirs(testing.allocator, dirs);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings("/Users/somebody/.codex/sessions", dirs[0]);

    // Whitespace-only CODEX_HOME behaves like unset.
    const dirs2 = try sessionsDirs(testing.allocator, " , ", "/Users/somebody");
    defer freeSessionsDirs(testing.allocator, dirs2);
    try testing.expectEqual(@as(usize, 1), dirs2.len);
    try testing.expectEqualStrings("/Users/somebody/.codex/sessions", dirs2[0]);
}

test "sessionsDirs splits comma-separated CODEX_HOME" {
    const dirs = try sessionsDirs(testing.allocator, "/a/codex, /b/codex ,,", "/home/x");
    defer freeSessionsDirs(testing.allocator, dirs);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings("/a/codex/sessions", dirs[0]);
    try testing.expectEqualStrings("/b/codex/sessions", dirs[1]);
}

test "parseIso8601Ms handles fractions, offsets, and junk" {
    try testing.expectEqual(@as(?i64, 1760011200500), parseIso8601Ms("2025-10-09T12:00:00.500Z"));
    try testing.expectEqual(@as(?i64, 1760011200000), parseIso8601Ms("2025-10-09T12:00:00Z"));
    try testing.expectEqual(@as(?i64, 1760011200250), parseIso8601Ms("2025-10-09T07:00:00.250-05:00"));
    try testing.expectEqual(@as(?i64, 0), parseIso8601Ms("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("not-a-timestamp"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("2025-13-09T12:00:00Z"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("2025-10-09T12:00:00X"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms(""));
}

test "feed emits full cumulative first, then per-turn diffs, skipping zero deltas" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, "2025/10/09/rollout-2025-10-09T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl", fixture_basic, &out);

    // 4 token_count lines, one of which repeats the totals → 3 events.
    try testing.expectEqual(@as(usize, 3), out.items.len);

    // First token_count of the session: the full cumulative as one event.
    const e1 = out.items[0];
    try testing.expectEqual(types.Agent.codex, e1.agent);
    try testing.expectEqual(@as(i64, 1760011210250), e1.timestamp_ms);
    try testing.expectEqual(@as(u64, 4000), e1.input_tokens); // 12000 - 8000 cached
    try testing.expectEqual(@as(u64, 8000), e1.cache_read_tokens);
    try testing.expectEqual(@as(u64, 500), e1.output_tokens);
    try testing.expectEqual(@as(u64, 0), e1.cache_creation_tokens);
    try testing.expectEqualStrings("gpt-5.2-codex", e1.model);
    try testing.expectEqualStrings("0199aaaa-1111-7222-8333-444455556666", e1.session_id);
    try testing.expectEqualStrings("/Users/dev/example-project", e1.cwd);

    // Second: diff against the first (Δin 18000, Δcached 12000, Δout 700).
    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1760011260000), e2.timestamp_ms);
    try testing.expectEqual(@as(u64, 6000), e2.input_tokens);
    try testing.expectEqual(@as(u64, 12000), e2.cache_read_tokens);
    try testing.expectEqual(@as(u64, 700), e2.output_tokens);

    // Third: the zero-delta line emitted nothing; diff vs line 2.
    const e3 = out.items[2];
    try testing.expectEqual(@as(i64, 1760011350999), e3.timestamp_ms);
    try testing.expectEqual(@as(u64, 4000), e3.input_tokens); // Δin 25000 - Δcached 21000
    try testing.expectEqual(@as(u64, 21000), e3.cache_read_tokens);
    try testing.expectEqual(@as(u64, 1400), e3.output_tokens);
}

test "cumulative reset starts a fresh baseline" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, "rollout-reset.jsonl", fixture_reset, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);

    // Normal growth.
    try testing.expectEqual(@as(u64, 6000), out.items[0].input_tokens);
    try testing.expectEqual(@as(u64, 4000), out.items[0].cache_read_tokens);
    try testing.expectEqual(@as(u64, 5000), out.items[1].input_tokens);
    try testing.expectEqual(@as(u64, 5000), out.items[1].cache_read_tokens);
    try testing.expectEqual(@as(u64, 500), out.items[1].output_tokens);

    // Line 3 drops below the baseline → its full cumulative is one event.
    try testing.expectEqual(@as(u64, 2000), out.items[2].input_tokens); // 3000 - 1000
    try testing.expectEqual(@as(u64, 1000), out.items[2].cache_read_tokens);
    try testing.expectEqual(@as(u64, 100), out.items[2].output_tokens);

    // And diffs continue from the new baseline.
    try testing.expectEqual(@as(u64, 1000), out.items[3].input_tokens); // Δ2000 - Δ1000
    try testing.expectEqual(@as(u64, 1000), out.items[3].cache_read_tokens);
    try testing.expectEqual(@as(u64, 100), out.items[3].output_tokens);

    // No turn_context in this fixture → default model, session from meta.
    try testing.expectEqualStrings(default_model, out.items[0].model);
    try testing.expectEqualStrings("0199bbbb-1111-7222-8333-444455556666", out.items[0].session_id);
    try testing.expectEqualStrings("/tmp/reset-project", out.items[0].cwd);
}

test "malformed lines are skipped without error" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    const path = "2025/10/09/rollout-2025-10-09T13-58-00-01997777-aaaa-4bbb-8ccc-333333333333.jsonl";
    try tailer.feed(testing.allocator, path, fixture_malformed, &out);

    // Only the one well-formed token_count line survives.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const ev = out.items[0];
    try testing.expectEqual(@as(i64, 1760018400000), ev.timestamp_ms);
    try testing.expectEqual(@as(u64, 300), ev.input_tokens); // 900 - 600 cached
    try testing.expectEqual(@as(u64, 600), ev.cache_read_tokens);
    try testing.expectEqual(@as(u64, 250), ev.output_tokens);
    // No session_meta/turn_context lines: model defaults, session id comes
    // from the rollout filename's trailing UUID.
    try testing.expectEqualStrings(default_model, ev.model);
    try testing.expectEqualStrings("01997777-aaaa-4bbb-8ccc-333333333333", ev.session_id);
    try testing.expectEqualStrings("", ev.cwd);
}

test "partial-line feeds carry across chunk boundaries" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    const path = "rollout-chunked.jsonl";
    var i: usize = 0;
    while (i < fixture_basic.len) {
        const end = @min(i + 7, fixture_basic.len);
        try tailer.feed(testing.allocator, path, fixture_basic[i..end], &out);
        i = end;
    }

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u64, 4000), out.items[0].input_tokens);
    try testing.expectEqual(@as(u64, 8000), out.items[0].cache_read_tokens);
    try testing.expectEqual(@as(u64, 6000), out.items[1].input_tokens);
    try testing.expectEqual(@as(u64, 4000), out.items[2].input_tokens);
    try testing.expectEqualStrings("gpt-5.2-codex", out.items[2].model);
}

/// Newest rollout content for the limits test: one token_count line with
/// distinctive limit values, dated newer than every fixture line.
const newest_rollout =
    \\{"timestamp":"2025-10-10T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1760016000},"secondary":{"used_percent":7.75,"window_minutes":10080,"resets_at":1760400000},"credits":null,"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}}
    \\
;

test "latestLimits reads the last token_count of the newest rollout across roots" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Root A holds two older files; root B holds the newest (by date dir).
    try tmp.dir.createDirPath(io, "root-a/2025/10/08");
    try tmp.dir.createDirPath(io, "root-a/2025/10/09");
    try tmp.dir.createDirPath(io, "root-b/2025/10/10");
    try tmp.dir.writeFile(io, .{
        .sub_path = "root-a/2025/10/08/rollout-2025-10-08T09-00-00-0199cccc-1111-7222-8333-444455556666.jsonl",
        .data = fixture_reset,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "root-a/2025/10/09/rollout-2025-10-09T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl",
        .data = fixture_basic,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "root-b/2025/10/10/rollout-2025-10-10T08-00-00-0199dddd-1111-7222-8333-444455556666.jsonl",
        .data = newest_rollout,
    });

    const base = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(base);
    const root_a = try std.fs.path.join(testing.allocator, &.{ base, "root-a" });
    defer testing.allocator.free(root_a);
    const root_b = try std.fs.path.join(testing.allocator, &.{ base, "root-b" });
    defer testing.allocator.free(root_b);
    const missing = try std.fs.path.join(testing.allocator, &.{ base, "does-not-exist" });
    defer testing.allocator.free(missing);

    const snap = (try latestLimits(testing.allocator, io, &.{ root_a, root_b, missing })).?;
    defer freeLimitSnapshot(testing.allocator, snap);

    try testing.expectEqual(types.Agent.codex, snap.agent);
    try testing.expectEqual(@as(i64, 1760083200000), snap.read_at_ms); // 2025-10-10T08:00:00Z
    try testing.expectEqualStrings("plus", snap.plan);
    try testing.expectEqual(@as(usize, 2), snap.windows.len);
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, snap.windows[0].kind);
    try testing.expectEqual(@as(f64, 42.5), snap.windows[0].used_percent);
    try testing.expectEqual(@as(i64, 1760016000000), snap.windows[0].resets_at_ms);
    try testing.expectEqual(types.LimitWindow.Kind.weekly, snap.windows[1].kind);
    try testing.expectEqual(@as(f64, 7.75), snap.windows[1].used_percent);
    try testing.expectEqual(@as(i64, 1760400000000), snap.windows[1].resets_at_ms);

    // Without root B, the newest file is the basic fixture: its LAST
    // token_count line carries primary 14.0 / secondary 3.5, plan "pro".
    const snap_a = (try latestLimits(testing.allocator, io, &.{root_a})).?;
    defer freeLimitSnapshot(testing.allocator, snap_a);
    try testing.expectEqualStrings("pro", snap_a.plan);
    try testing.expectEqual(@as(f64, 14.0), snap_a.windows[0].used_percent);
    try testing.expectEqual(@as(f64, 3.5), snap_a.windows[1].used_percent);
    try testing.expectEqual(@as(i64, 1760014800000), snap_a.windows[0].resets_at_ms);

    // No usable roots → null.
    try testing.expectEqual(@as(?types.LimitSnapshot, null), try latestLimits(testing.allocator, io, &.{missing}));
}

test "feed captures the freshest embedded rate limits" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(?types.LimitSnapshot, null), tailer.lastLimits());
    try tailer.feed(testing.allocator, "rollout-basic.jsonl", fixture_basic, &out);

    // The LAST token_count line of the fixture wins: primary 14.0,
    // secondary 3.5, plan "pro" (same truth latestLimits extracts).
    const snap = tailer.lastLimits().?;
    try testing.expectEqual(types.Agent.codex, snap.agent);
    try testing.expectEqualStrings("pro", snap.plan);
    try testing.expectEqual(@as(usize, 2), snap.windows.len);
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, snap.windows[0].kind);
    try testing.expectEqual(@as(f64, 14.0), snap.windows[0].used_percent);
    try testing.expectEqual(@as(i64, 1760014800000), snap.windows[0].resets_at_ms);
    try testing.expectEqual(types.LimitWindow.Kind.weekly, snap.windows[1].kind);
    try testing.expectEqual(@as(f64, 3.5), snap.windows[1].used_percent);

    // Older lines never regress the reading.
    const stale_line =
        \\{"timestamp":"2025-10-09T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2}},"rate_limits":{"primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1760000000},"plan_type":"free"}}}
        \\
    ;
    try tailer.feed(testing.allocator, "rollout-stale.jsonl", stale_line, &out);
    try testing.expectEqual(@as(f64, 14.0), tailer.lastLimits().?.windows[0].used_percent);
    try testing.expectEqualStrings("pro", tailer.lastLimits().?.plan);
}

test "restoreLimits seeds lastLimits and keeps newer readings" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();

    const windows = [_]types.LimitWindow{
        .{ .kind = .five_hour, .used_percent = 20.0, .resets_at_ms = 1_000 },
        .{ .kind = .weekly, .used_percent = 5.0, .resets_at_ms = 2_000 },
    };
    try tailer.restoreLimits(500, "plus", &windows);
    const snap = tailer.lastLimits().?;
    try testing.expectEqualStrings("plus", snap.plan);
    try testing.expectEqual(@as(f64, 20.0), snap.windows[0].used_percent);

    // An older restore does not clobber a newer reading.
    try tailer.restoreLimits(400, "free", windows[0..1]);
    try testing.expectEqualStrings("plus", tailer.lastLimits().?.plan);
    try testing.expectEqual(@as(usize, 2), tailer.lastLimits().?.windows.len);

    // Degenerate inputs are ignored.
    try tailer.restoreLimits(900, "x", &.{});
    try testing.expectEqualStrings("plus", tailer.lastLimits().?.plan);
}

test "sweepIncremental: hot appends, new rollouts via dir mtimes, safety net" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/2025/10/09");
    const basic_rel = "sessions/2025/10/09/rollout-2025-10-09T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl";
    try tmp.dir.writeFile(io, .{ .sub_path = basic_rel, .data = fixture_basic });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    var now: i64 = 1_000_000;
    // First call full-walks: 3 events, limits captured, tree mapped.
    try testing.expect(try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expect(tailer.lastLimits() != null);
    try testing.expectEqual(@as(usize, 1), tailer.inc.hot.items.len);
    try testing.expect(tailer.inc.dir_mtimes.count() >= 4); // root + 2025 + 10 + 09

    // Quiet fast tick.
    now += 2_000;
    try testing.expect(!try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 3), out.items.len);

    // Append to the hot rollout: caught on the next fast tick, diffed
    // against the running baseline.
    const appendix =
        \\{"timestamp":"2025-10-09T12:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60000,"cached_input_tokens":45000,"output_tokens":3000,"reasoning_output_tokens":1000,"total_tokens":63000},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":400,"reasoning_output_tokens":100,"total_tokens":5400},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":15.0,"window_minutes":300,"resets_at":1760014800},"secondary":{"used_percent":3.75,"window_minutes":10080,"resets_at":1760400000},"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        \\
    ;
    const grown = try std.mem.concat(testing.allocator, u8, &.{ fixture_basic, appendix });
    defer testing.allocator.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = basic_rel, .data = grown });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqual(@as(u64, 1000), out.items[3].input_tokens);
    try testing.expectEqual(@as(f64, 15.0), tailer.lastLimits().?.windows[0].used_percent);

    // A brand-new rollout in a NEW date dir: the parent dir's mtime moved,
    // so the next tick full-walks and finds it.
    try tmp.dir.createDirPath(io, "sessions/2025/10/10");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/2025/10/10/rollout-2025-10-10T09-00-00-0199bbbb-1111-7222-8333-444455556666.jsonl",
        .data = fixture_reset,
    });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 8), out.items.len); // +4 from the reset fixture

    // Cold-file growth (hot list emptied) waits for the periodic full walk.
    for (tailer.inc.hot.items) |h| testing.allocator.free(h.path);
    tailer.inc.hot.clearRetainingCapacity();
    const grown2 = try std.mem.concat(testing.allocator, u8, &.{
        grown,
        \\{"timestamp":"2025-10-09T12:07:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":61000,"cached_input_tokens":45500,"output_tokens":3100,"reasoning_output_tokens":1000,"total_tokens":64100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100},"model_context_window":258400}}}
        \\
    });
    defer testing.allocator.free(grown2);
    try tmp.dir.writeFile(io, .{ .sub_path = basic_rel, .data = grown2 });
    now += 2_000;
    try testing.expect(!try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 8), out.items.len);
    now += full_walk_interval_ms;
    try testing.expect(try tailer.sweepIncremental(io, testing.allocator, &roots, &out, now));
    try testing.expectEqual(@as(usize, 9), out.items.len);
    try testing.expectEqual(@as(u64, 500), out.items[8].input_tokens); // Δ1000 − Δ500 cached
}

test "sweep tails rollout files incrementally" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/2025/10/08");
    try tmp.dir.createDirPath(io, "sessions/2025/10/09");
    const basic_rel = "sessions/2025/10/08/rollout-2025-10-08T12-00-00-0199aaaa-1111-7222-8333-444455556666.jsonl";
    try tmp.dir.writeFile(io, .{ .sub_path = basic_rel, .data = fixture_basic });
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/2025/10/09/rollout-2025-10-09T13-00-00-0199bbbb-1111-7222-8333-444455556666.jsonl",
        .data = fixture_reset,
    });

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions" });
    defer testing.allocator.free(root);

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // First sweep: 3 events from the basic file (older date, so first),
    // then 4 from the reset file.
    try tailer.sweep(io, testing.allocator, &.{root}, &out);
    try testing.expectEqual(@as(usize, 7), out.items.len);
    try testing.expectEqualStrings("0199aaaa-1111-7222-8333-444455556666", out.items[0].session_id);
    try testing.expectEqualStrings("0199bbbb-1111-7222-8333-444455556666", out.items[6].session_id);

    // Second sweep with nothing appended: no new events.
    try tailer.sweep(io, testing.allocator, &.{root}, &out);
    try testing.expectEqual(@as(usize, 7), out.items.len);

    // Append one more token_count to the basic file (rewrite = same prefix
    // + appendix; the tailer resumes from its stored byte offset).
    const appendix =
        \\{"timestamp":"2025-10-09T12:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60000,"cached_input_tokens":45000,"output_tokens":3000,"reasoning_output_tokens":1000,"total_tokens":63000},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":4000,"output_tokens":400,"reasoning_output_tokens":100,"total_tokens":5400},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":15.0,"window_minutes":300,"resets_at":1760014800},"secondary":{"used_percent":3.75,"window_minutes":10080,"resets_at":1760400000},"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        \\
    ;
    const grown = try std.mem.concat(testing.allocator, u8, &.{ fixture_basic, appendix });
    defer testing.allocator.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = basic_rel, .data = grown });

    try tailer.sweep(io, testing.allocator, &.{root}, &out);
    try testing.expectEqual(@as(usize, 8), out.items.len);
    const ev = out.items[7];
    try testing.expectEqual(@as(u64, 1000), ev.input_tokens); // Δ5000 - Δ4000 cached
    try testing.expectEqual(@as(u64, 4000), ev.cache_read_tokens);
    try testing.expectEqual(@as(u64, 400), ev.output_tokens);
    try testing.expectEqual(@as(i64, 1760011500000), ev.timestamp_ms); // 12:05:00Z
    try testing.expectEqualStrings("gpt-5.2-codex", ev.model);
}
