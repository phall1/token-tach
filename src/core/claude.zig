//! Claude Code JSONL transcript tailer.
//!
//! Reads token usage out of `~/.claude/projects/<slug>/<sessionId>.jsonl`
//! (and `<sessionId>/subagents/agent-*.jsonl`) append-only NDJSON ledgers.
//! Token-bearing lines have `"type":"assistant"` and carry
//! `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens,
//! cache_read_input_tokens}` plus `message.model`, `timestamp`, `sessionId`,
//! and `cwd`. Everything else (user / summary / file-history-snapshot / mode
//! / ...) is skipped with a cheap substring pre-check before JSON parsing.
//!
//! Dedup happens inside the `Tailer` on `message.id ++ ":" ++ requestId`
//! (message.id alone when requestId is absent): the same assistant message
//! reappears across resumed sessions and subagent re-logs, and must be
//! counted once. Synthetic API-error lines (`message.model == "<synthetic>"`,
//! all-zero usage) are skipped. `costUSD` is ignored per plan — cost is
//! always computed downstream from tokens and pricing tables.
//!
//! Ownership (two allocators, deliberately split — see `tailsource.zig`,
//! the generic engine this module is the ancestor of):
//! - The *event allocator* holds everything born and buried inside one
//!   sweep: the per-line JSON DOM and the strings duped into each emitted
//!   `types.UsageEvent`. Ownership of those strings transfers to the sink
//!   consumer — the tailer never frees them. Point it at the caller's
//!   per-sweep arena and the whole lot dies in one `deinit`; point it at a
//!   GPA and each event must be freed with `freeUsageEventStrings` (which
//!   `ListSink.deinit` does for you when the sink shares that allocator).
//! - The *tailer allocator* (the one `Tailer.init` takes) holds state that
//!   outlives the sweep by design and is serialized to the statefile: file
//!   offsets, carry buffers, dir mtimes, the hot list, and the dedup `seen`
//!   keys. Dedup keys are always re-duped onto it before entering `seen`,
//!   precisely so a caller-supplied arena can be destroyed without turning
//!   the dedup set into dangling pointers.
//!
//! The `feed`/`scanFile`/`sweep`/`sweepIncremental` entry points use the
//! tailer allocator for both roles (historical behavior, kept so existing
//! call sites are untouched); the `...With` variants take the event
//! allocator explicitly and are the ones new code should call. The free
//! function `parseLine` uses the allocator passed in.

const std = @import("std");
const types = @import("types.zig");
const timeutil = @import("timeutil.zig");

/// Cheap pre-checks: assistant lines always contain one of these. Claude Code
/// serializes without spaces; the spaced variant is accepted defensively.
const assistant_marker = "\"type\":\"assistant\"";
const assistant_marker_spaced = "\"type\": \"assistant\"";

/// API-error placeholder model on assistant lines; carries all-zero usage.
const synthetic_model = "<synthetic>";

const read_chunk_len = 64 * 1024;
/// Carry buffers above this capacity are released after the line completes
/// (file-history-snapshot lines can run to megabytes).
const carry_shrink_threshold = 1024 * 1024;

// ---------------------------------------------------------------------------
// Event sink
// ---------------------------------------------------------------------------

/// Where parsed events go. Dependency-free function-pointer + context pair so
/// the engine layer can plug in a ledger, a test list, or anything else.
pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: types.UsageEvent) anyerror!void,

    pub fn emit(self: EventSink, event: types.UsageEvent) anyerror!void {
        return self.emit_fn(self.context, event);
    }
};

/// EventSink adapter that appends into an owned ArrayList.
/// Initialize it with the SAME allocator the feeding tailer uses for events
/// — its own for `feed`/`sweep`, the one handed to a `...With` variant
/// otherwise: `deinit` frees the strings inside each collected event with
/// that allocator. (When that allocator is the caller's sweep arena, the
/// frees are redundant but harmless; the arena reclaims everything anyway.)
pub const ListSink = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(types.UsageEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) ListSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ListSink) void {
        for (self.events.items) |ev| freeUsageEventStrings(self.allocator, ev);
        self.events.deinit(self.allocator);
    }

    pub fn sink(self: *ListSink) EventSink {
        return .{ .context = self, .emit_fn = emitOpaque };
    }

    fn emitOpaque(context: *anyopaque, event: types.UsageEvent) anyerror!void {
        const self: *ListSink = @ptrCast(@alignCast(context));
        try self.events.append(self.allocator, event);
    }
};

/// Free the duped strings inside an event produced by this module.
pub fn freeUsageEventStrings(allocator: std.mem.Allocator, event: types.UsageEvent) void {
    allocator.free(event.model);
    allocator.free(event.session_id);
    allocator.free(event.cwd);
}

// ---------------------------------------------------------------------------
// Root discovery
// ---------------------------------------------------------------------------

/// Candidate `projects` directories, in precedence order: each entry of the
/// comma-separated CLAUDE_CONFIG_DIR value, then `<home>/.config/claude`,
/// then `<home>/.claude` — each with "/projects" appended, filtered to
/// directories that actually exist, exact-string deduplicated.
///
/// Caller owns the returned slice and every path in it (all allocated with
/// `allocator`).
pub fn discoverRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_claude_config_dir: ?[]const u8,
    home: []const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    if (env_claude_config_dir) |env_val| {
        var it = std.mem.splitScalar(u8, env_val, ',');
        while (it.next()) |raw| {
            const base = std.mem.trim(u8, raw, " \t");
            if (base.len == 0) continue;
            try appendRootIfDir(allocator, io, &out, base);
        }
    }
    for ([_][]const u8{ ".config/claude", ".claude" }) |suffix| {
        const base = try std.fs.path.join(allocator, &.{ home, suffix });
        defer allocator.free(base);
        try appendRootIfDir(allocator, io, &out, base);
    }
    return out.toOwnedSlice(allocator);
}

fn appendRootIfDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList([]const u8),
    base: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ base, "projects" });
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            allocator.free(path);
            return;
        }
    }
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{}) catch {
        allocator.free(path);
        return;
    };
    dir.close(io);
    try out.append(allocator, path);
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

/// Parse one transcript line into a usage event, or null for anything that
/// is not a token-bearing assistant line (wrong type, no usage, synthetic
/// error placeholder, bad timestamp, malformed JSON — garbage never errors).
///
/// Strings inside the returned event are duped with `allocator`; the caller
/// owns them (see `freeUsageEventStrings`). Note this free function does NOT
/// dedup — that is the Tailer's job.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) ?types.UsageEvent {
    const ex = extractLine(allocator, std.mem.trim(u8, line, " \t\r\n")) orelse return null;
    allocator.free(ex.message_id);
    if (ex.request_id) |rid| allocator.free(rid);
    return ex.event;
}

/// A parsed assistant line plus the identifiers the tailer dedups on.
/// All strings are owned by the extract caller.
const Extracted = struct {
    event: types.UsageEvent,
    message_id: []const u8,
    request_id: ?[]const u8,

    fn deinit(self: Extracted, allocator: std.mem.Allocator) void {
        freeUsageEventStrings(allocator, self.event);
        allocator.free(self.message_id);
        if (self.request_id) |rid| allocator.free(rid);
    }
};

fn extractLine(allocator: std.mem.Allocator, line: []const u8) ?Extracted {
    if (line.len == 0) return null;
    // Fast reject before spinning up a JSON parser: the overwhelming
    // majority of lines (user, snapshots, mode, ...) never match.
    if (std.mem.indexOf(u8, line, assistant_marker) == null and
        std.mem.indexOf(u8, line, assistant_marker_spaced) == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    return extractFromValue(allocator, parsed.value) catch null;
}

fn extractFromValue(allocator: std.mem.Allocator, root_value: std.json.Value) !?Extracted {
    const root = switch (root_value) {
        .object => |o| o,
        else => return null,
    };
    const type_str = getString(root, "type") orelse return null;
    if (!std.mem.eql(u8, type_str, "assistant")) return null;

    const message = getObject(root, "message") orelse return null;
    const model = getString(message, "model") orelse return null;
    if (std.mem.eql(u8, model, synthetic_model)) return null;
    const usage = getObject(message, "usage") orelse return null;
    const message_id = getString(message, "id") orelse return null;
    const ts_str = getString(root, "timestamp") orelse return null;
    const timestamp_ms = parseTimestamp(ts_str) orelse return null;
    // Main session files carry both "sessionId" and legacy "session_id";
    // subagent files carry only "sessionId".
    const session_id = getString(root, "sessionId") orelse
        (getString(root, "session_id") orelse "");
    const cwd = getString(root, "cwd") orelse "";
    const request_id = getString(root, "requestId");

    const model_owned = try allocator.dupe(u8, model);
    errdefer allocator.free(model_owned);
    const session_owned = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_owned);
    const cwd_owned = try allocator.dupe(u8, cwd);
    errdefer allocator.free(cwd_owned);
    const message_id_owned = try allocator.dupe(u8, message_id);
    errdefer allocator.free(message_id_owned);
    const request_id_owned: ?[]const u8 = if (request_id) |rid| try allocator.dupe(u8, rid) else null;

    return .{
        .event = .{
            .agent = .claude,
            .timestamp_ms = timestamp_ms,
            .model = model_owned,
            .input_tokens = getU64(usage, "input_tokens"),
            .output_tokens = getU64(usage, "output_tokens"),
            .cache_creation_tokens = getU64(usage, "cache_creation_input_tokens"),
            .cache_read_tokens = getU64(usage, "cache_read_input_tokens"),
            .session_id = session_owned,
            .cwd = cwd_owned,
        },
        .message_id = message_id_owned,
        .request_id = request_id_owned,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (obj.get(key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) u64 {
    return switch (obj.get(key) orelse return 0) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Timestamp parsing
// ---------------------------------------------------------------------------

/// ISO8601 -> unix milliseconds. Re-exported so this module's own call
/// sites, its tests and the CLI keep one name for it; the implementation
/// is shared with the other collectors in timeutil.zig.
pub const parseTimestamp = timeutil.parseTimestamp;

// ---------------------------------------------------------------------------
// Tailer
// ---------------------------------------------------------------------------

/// How long the incremental sweep may go without a full tree re-walk.
/// The safety net for changes invisible to dir mtimes + the hot list
/// (e.g. an old, cold transcript growing again).
///
/// 10 s, not 30: the fast tick is ~2 s, so this is the worst-case staleness
/// a user can see on a transcript that fell off the hot list, and 30 s of
/// a frozen needle reads as a broken app. A full walk is one stat per
/// *.jsonl plus one per directory — cheap next to the read+parse work it
/// gates — so paying it 3x as often buys a 3x tighter latency bound.
pub const full_walk_interval_ms: i64 = 10_000;
/// How many recently-modified files the incremental sweep stats every tick.
///
/// 32, not 8: a single Claude Code session with subagents running writes to
/// the main transcript plus one file per live subagent, and 8 slots are
/// exhausted by one busy session — pushing every other project's active
/// transcript onto the full-walk path, i.e. up to `full_walk_interval_ms`
/// of invisible growth. 32 stats per tick is still noise against the
/// syscall budget of one full walk; the hot list only costs stats.
pub const hot_files_max = 32;

/// Incremental NDJSON tailer with per-file byte offsets, per-file partial-line
/// carry buffers, and a global message dedup set.
///
/// Lifetime: init with a long-lived allocator; internal state (offsets map,
/// carry buffers, dir mtimes, hot list, dedup keys) is freed by `deinit` and
/// never borrows from a caller's arena. Strings inside emitted events are
/// allocated with the event allocator (the tailer's own, unless a `...With`
/// variant was handed a different one) and ownership passes to the sink
/// consumer — `deinit` does NOT free them.
pub const Tailer = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(FileState) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    inc: Incremental = .{},

    const FileState = struct {
        offset: u64 = 0,
        carry: std.ArrayList(u8) = .empty,
    };

    /// Change-detection state for `sweepIncremental`: every directory in the
    /// tree with its mtime (a dir's mtime moves when files are added/removed
    /// in it — NOT when a file inside grows), plus the `hot_files_max` most
    /// recently modified files, which are the ones that actually grow.
    const Incremental = struct {
        dir_mtimes: std.StringHashMapUnmanaged(i96) = .empty,
        hot: std.ArrayList(HotFile) = .empty,
        last_full_walk_ms: ?i64 = null,

        const HotFile = struct { path: []u8, mtime_ns: i96 };

        fn deinit(self: *Incremental, gpa: std.mem.Allocator) void {
            var it = self.dir_mtimes.keyIterator();
            while (it.next()) |key| gpa.free(key.*);
            self.dir_mtimes.deinit(gpa);
            for (self.hot.items) |h| gpa.free(h.path);
            self.hot.deinit(gpa);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Tailer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tailer) void {
        var fit = self.files.iterator();
        while (fit.next()) |entry| {
            entry.value_ptr.carry.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        var kit = self.seen.keyIterator();
        while (kit.next()) |key| self.allocator.free(key.*);
        self.seen.deinit(self.allocator);
        self.inc.deinit(self.allocator);
        self.* = undefined;
    }

    /// The stored byte offset for `path`, or null if the tailer has never
    /// touched it. `offset == file size` means fully caught up.
    pub fn offsetFor(self: *const Tailer, path: []const u8) ?u64 {
        const state = self.files.get(path) orelse return null;
        return state.offset;
    }

    /// Statefile restore: mark `path` as already parsed up to `offset`.
    /// Any carry is cleared — persisted offsets always sit on a line
    /// boundary (the saver subtracts the carry length).
    pub fn restoreFile(self: *Tailer, path: []const u8, offset: u64) !void {
        const state = try self.fileState(path);
        state.offset = offset;
        state.carry.clearAndFree(self.allocator);
    }

    /// Statefile restore: re-insert one persisted dedup key.
    pub fn restoreSeen(self: *Tailer, key: []const u8) !void {
        const gop = try self.seen.getOrPut(self.allocator, key);
        if (gop.found_existing) return;
        gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
            self.seen.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    /// Feed a raw byte chunk belonging to `file_key` (any stable identifier;
    /// scanFile uses the path). Splits on '\n', parses complete lines, and
    /// buffers a trailing partial line until the next feed for the same key.
    /// Deduplicated events are emitted to `sink` in file order.
    ///
    /// Events land on the tailer's own allocator; prefer `feedWith`.
    pub fn feed(self: *Tailer, file_key: []const u8, chunk: []const u8, sink: EventSink) !void {
        return self.feedWith(self.allocator, file_key, chunk, sink);
    }

    /// `feed`, with the event allocator named explicitly (the tailsource.zig
    /// idiom). Only the transient JSON DOM and the emitted events' strings
    /// come from `event_allocator` — carry buffers and dedup keys stay on
    /// the tailer's allocator, so passing a per-sweep arena here is safe
    /// even though `seen` must survive the arena's destruction.
    pub fn feedWith(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        file_key: []const u8,
        chunk: []const u8,
        sink: EventSink,
    ) !void {
        const state = try self.fileState(file_key);
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const segment = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (state.carry.items.len != 0) {
                try state.carry.appendSlice(self.allocator, segment);
                try self.processLine(event_allocator, state.carry.items, sink);
                if (state.carry.capacity > carry_shrink_threshold) {
                    state.carry.clearAndFree(self.allocator);
                } else {
                    state.carry.clearRetainingCapacity();
                }
            } else {
                try self.processLine(event_allocator, segment, sink);
            }
        }
        if (rest.len != 0) try state.carry.appendSlice(self.allocator, rest);
    }

    /// Open `path`, read everything past the stored byte offset, feed it, and
    /// advance the offset. A shrunken file (rotation/truncation) resets the
    /// offset and carry. A vanished file is silently skipped. `scratch` is
    /// only used for the transient read buffer (arena-friendly).
    ///
    /// Events land on the tailer's own allocator; prefer `scanFileWith`.
    pub fn scanFile(
        self: *Tailer,
        scratch: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        sink: EventSink,
    ) !void {
        return self.scanFileWith(self.allocator, scratch, io, path, sink);
    }

    /// `scanFile`, with the event allocator named explicitly. tailsource.zig
    /// folds the two into one arena parameter; this module keeps them apart
    /// only so the legacy entry points above can stay exact wrappers — new
    /// callers should pass the same per-sweep arena for both.
    pub fn scanFileWith(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        sink: EventSink,
    ) !void {
        var cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer file.close(io);
        const size = try file.length(io);

        var offset: u64 = blk: {
            const state = try self.fileState(path);
            if (size < state.offset) {
                state.offset = 0;
                state.carry.clearAndFree(self.allocator);
            }
            break :blk state.offset;
        };
        if (offset >= size) return;

        const buf = try scratch.alloc(u8, read_chunk_len);
        defer scratch.free(buf);
        while (offset < size) {
            const n = try file.readPositionalAll(io, buf, offset);
            if (n == 0) break;
            try self.feedWith(event_allocator, path, buf[0..n], sink);
            offset += n;
            // Re-fetch: feed may touch the files map (same key, but stay safe
            // against pointer invalidation across hash map operations).
            self.files.getPtr(path).?.offset = offset;
            if (n < buf.len) break;
        }
    }

    /// Recursively find every *.jsonl under each root (which covers the
    /// `<session>/subagents/agent-*.jsonl` trees) and scanFile it. Unreadable
    /// roots and files are skipped, not errors: sweeps race live writers.
    ///
    /// Events land on the tailer's own allocator; prefer `sweepWith`.
    pub fn sweep(
        self: *Tailer,
        scratch: std.mem.Allocator,
        io: std.Io,
        roots: []const []const u8,
        sink: EventSink,
    ) !void {
        return self.sweepWith(self.allocator, scratch, io, roots, sink);
    }

    /// `sweep`, with the event allocator named explicitly.
    pub fn sweepWith(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        io: std.Io,
        roots: []const []const u8,
        sink: EventSink,
    ) !void {
        var cwd = std.Io.Dir.cwd();
        for (roots) |root| {
            var dir = cwd.openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(scratch);
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
                const path = try std.fs.path.join(scratch, &.{ root, entry.path });
                defer scratch.free(path);
                self.scanFileWith(event_allocator, scratch, io, path, sink) catch continue;
            }
        }
    }

    /// Cheap steady-state sweep. Instead of re-walking + re-opening the
    /// whole tree every tick, it:
    ///
    /// 1. Full-walks (stat every file, scan grown ones, record every dir
    ///    mtime + the hottest files) on the first call, whenever any known
    ///    directory's mtime moved (= files added/removed anywhere), and at
    ///    least every `full_walk_interval_ms` as a safety net.
    /// 2. Otherwise stats only the known directories plus the
    ///    `hot_files_max` most recently modified files, scanning the ones
    ///    that grew — the active-transcript path, a handful of stats total.
    ///
    /// Worst-case detection latency for a change neither pass can see (a
    /// cold, not-hot file growing without any dir change) is one full-walk
    /// interval. Returns true when any new bytes were parsed.
    ///
    /// Events land on the tailer's own allocator; prefer
    /// `sweepIncrementalWith`.
    pub fn sweepIncremental(
        self: *Tailer,
        scratch: std.mem.Allocator,
        io: std.Io,
        roots: []const []const u8,
        sink: EventSink,
        now_ms: i64,
    ) !bool {
        return self.sweepIncrementalWith(self.allocator, scratch, io, roots, sink, now_ms);
    }

    /// `sweepIncremental`, with the event allocator named explicitly. This
    /// is the entry point a per-tick arena belongs on: a cold-start backfill
    /// parses thousands of lines, and every one of them otherwise charges a
    /// JSON arena create/destroy plus four string dupes to the long-lived
    /// allocator.
    pub fn sweepIncrementalWith(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        io: std.Io,
        roots: []const []const u8,
        sink: EventSink,
        now_ms: i64,
    ) !bool {
        const due = if (self.inc.last_full_walk_ms) |last|
            now_ms - last >= full_walk_interval_ms
        else
            true;
        if (due or self.dirsChanged(io)) return self.fullWalk(event_allocator, scratch, io, roots, sink, now_ms);
        return self.hotPass(event_allocator, scratch, io, sink);
    }

    /// Did any known directory's mtime move since the last full walk?
    /// A vanished directory also counts as changed.
    fn dirsChanged(self: *Tailer, io: std.Io) bool {
        var cwd = std.Io.Dir.cwd();
        var it = self.inc.dir_mtimes.iterator();
        while (it.next()) |entry| {
            const stat = cwd.statFile(io, entry.key_ptr.*, .{}) catch return true;
            if (stat.mtime.nanoseconds != entry.value_ptr.*) return true;
        }
        return false;
    }

    /// Stat only the hot files; scan the ones whose size left the stored
    /// offset. Unreadable files are skipped (sweeps race live writers).
    fn hotPass(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        io: std.Io,
        sink: EventSink,
    ) !bool {
        var changed = false;
        var cwd = std.Io.Dir.cwd();
        for (self.inc.hot.items) |*h| {
            const stat = cwd.statFile(io, h.path, .{}) catch continue;
            const known = self.offsetFor(h.path) orelse 0;
            if (stat.size == known) continue;
            self.scanFileWith(event_allocator, scratch, io, h.path, sink) catch continue;
            h.mtime_ns = stat.mtime.nanoseconds;
            changed = true;
        }
        return changed;
    }

    /// Walk everything: stat each *.jsonl (3× cheaper than the open +
    /// length + close of an unconditional scanFile), scan the changed
    /// ones, and rebuild the dir-mtime map + hot list for the fast path.
    fn fullWalk(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        io: std.Io,
        roots: []const []const u8,
        sink: EventSink,
        now_ms: i64,
    ) !bool {
        var next: Incremental = .{ .last_full_walk_ms = now_ms };
        errdefer next.deinit(self.allocator);
        var changed = false;

        var cwd = std.Io.Dir.cwd();
        for (roots) |root| {
            if (cwd.statFile(io, root, .{})) |stat| {
                try putDirMtime(self.allocator, &next.dir_mtimes, root, stat.mtime.nanoseconds);
            } else |_| continue;
            var dir = cwd.openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(scratch);
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                switch (entry.kind) {
                    .directory => {
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(scratch, &.{ root, entry.path });
                        defer scratch.free(path);
                        try putDirMtime(self.allocator, &next.dir_mtimes, path, stat.mtime.nanoseconds);
                    },
                    .file => {
                        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(scratch, &.{ root, entry.path });
                        defer scratch.free(path);
                        if (stat.size != (self.offsetFor(path) orelse 0)) {
                            self.scanFileWith(event_allocator, scratch, io, path, sink) catch {};
                            changed = true;
                        }
                        try insertHot(self.allocator, &next.hot, path, stat.mtime.nanoseconds);
                    },
                    else => {},
                }
            }
        }

        self.inc.deinit(self.allocator);
        self.inc = next;
        return changed;
    }

    fn fileState(self: *Tailer, file_key: []const u8) !*FileState {
        if (self.files.getPtr(file_key)) |state| return state;
        const owned = try self.allocator.dupe(u8, file_key);
        errdefer self.allocator.free(owned);
        try self.files.put(self.allocator, owned, .{});
        return self.files.getPtr(owned).?;
    }

    /// Parse one complete line and emit it if it survives dedup.
    ///
    /// Ownership split, and it is load-bearing: everything `extractLine`
    /// produces — the JSON DOM, the event's strings, the message/request ids,
    /// and the dedup key assembled from them — belongs to `event_allocator`
    /// and may be freed the moment the caller's sweep arena dies. The `seen`
    /// entry must outlive that (it is what the statefile serializes), so the
    /// key is re-duped onto `self.allocator` before it enters the map. That
    /// dupe is redundant when the two allocators coincide, which is exactly
    /// the case that used to be the only one — a wasted `strdup` per new
    /// message is the price of not owning a dangling `seen` set.
    fn processLine(
        self: *Tailer,
        event_allocator: std.mem.Allocator,
        line: []const u8,
        sink: EventSink,
    ) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const ex = extractLine(event_allocator, trimmed) orelse return;

        const key = blk: {
            if (ex.request_id) |rid| {
                break :blk std.fmt.allocPrint(event_allocator, "{s}:{s}", .{ ex.message_id, rid }) catch |err| {
                    ex.deinit(event_allocator);
                    return err;
                };
            }
            break :blk event_allocator.dupe(u8, ex.message_id) catch |err| {
                ex.deinit(event_allocator);
                return err;
            };
        };
        defer event_allocator.free(key);
        event_allocator.free(ex.message_id);
        if (ex.request_id) |rid| event_allocator.free(rid);

        const gop = self.seen.getOrPut(self.allocator, key) catch |err| {
            freeUsageEventStrings(event_allocator, ex.event);
            return err;
        };
        if (gop.found_existing) {
            freeUsageEventStrings(event_allocator, ex.event);
            return;
        }
        // getOrPut parked the borrowed key in the map; replace it with a
        // long-lived copy before anything can observe (or free) it.
        gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
            self.seen.removeByPtr(gop.key_ptr);
            freeUsageEventStrings(event_allocator, ex.event);
            return err;
        };
        // The dedup key is recorded before emitting: if the sink errors the
        // event is dropped rather than risked double-counted on retry.
        sink.emit(ex.event) catch |err| {
            freeUsageEventStrings(event_allocator, ex.event);
            return err;
        };
    }
};

/// Insert (path duped) into a map of owned dir paths → mtime.
fn putDirMtime(
    gpa: std.mem.Allocator,
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
    gpa: std.mem.Allocator,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const session1_fixture = @embedFile("fixtures/claude/session1.jsonl");
const sub1_fixture = @embedFile("fixtures/claude/agent-sub1.jsonl");
const garbage_fixture = @embedFile("fixtures/claude/garbage.jsonl");

const fixture_session_id = "11111111-2222-4333-8444-555555555555";
const fixture_cwd = "/home/dev/example-project";

fn countModel(events: []const types.UsageEvent, model: []const u8) usize {
    var n: usize = 0;
    for (events) |ev| {
        if (std.mem.eql(u8, ev.model, model)) n += 1;
    }
    return n;
}

fn sumField(events: []const types.UsageEvent, comptime field: []const u8) u64 {
    var total: u64 = 0;
    for (events) |ev| total += @field(ev, field);
    return total;
}

test "parseLine extracts a usage event from an assistant line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T02:58:00.100Z\"," ++
        "\"requestId\":\"req_a0000000000000000000001\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"cwd\":\"" ++ fixture_cwd ++ "\",\"message\":{\"model\":\"claude-fable-5\"," ++
        "\"id\":\"msg_a0000000000000000000001\",\"usage\":{\"input_tokens\":100,\"output_tokens\":10," ++
        "\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":5000}}}";
    const ev = parseLine(arena, line) orelse return error.TestExpectedEvent;
    try testing.expectEqual(types.Agent.claude, ev.agent);
    try testing.expectEqual(@as(i64, 1783479480100), ev.timestamp_ms);
    try testing.expectEqualStrings("claude-fable-5", ev.model);
    try testing.expectEqual(@as(u64, 100), ev.input_tokens);
    try testing.expectEqual(@as(u64, 10), ev.output_tokens);
    try testing.expectEqual(@as(u64, 1000), ev.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 5000), ev.cache_read_tokens);
    try testing.expectEqualStrings(fixture_session_id, ev.session_id);
    try testing.expectEqualStrings(fixture_cwd, ev.cwd);
    try testing.expectEqual(@as(u64, 6110), ev.totalTokens());
}

test "parseLine skips non-assistant lines from the session fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var events: usize = 0;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, session1_fixture, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        if (parseLine(arena, line) != null) events += 1;
    }
    try testing.expectEqual(@as(usize, 20), lines);
    // 10 usage-bearing assistant lines (8 unique + 2 duplicates; parseLine
    // does not dedup). The <synthetic> line and everything else is skipped.
    try testing.expectEqual(@as(usize, 10), events);
}

test "parseLine tolerates malformed and degenerate lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var events: usize = 0;
    var it = std.mem.splitScalar(u8, garbage_fixture, '\n');
    while (it.next()) |line| {
        if (parseLine(arena, line)) |ev| {
            events += 1;
            try testing.expectEqualStrings("claude-fable-5", ev.model);
            try testing.expectEqual(@as(u64, 7), ev.input_tokens);
            try testing.expectEqual(@as(u64, 3), ev.output_tokens);
            try testing.expectEqual(@as(u64, 2), ev.cache_creation_tokens);
            try testing.expectEqual(@as(u64, 1), ev.cache_read_tokens);
        }
    }
    // Only the final well-formed line survives.
    try testing.expectEqual(@as(usize, 1), events);
}

test "tailer parses the session fixture with in-file dedup" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    try tailer.feed("projects/slug/session1.jsonl", session1_fixture, sink.sink());

    const events = sink.events.items;
    try testing.expectEqual(@as(usize, 8), events.len);
    try testing.expectEqual(@as(usize, 5), countModel(events, "claude-fable-5"));
    try testing.expectEqual(@as(usize, 3), countModel(events, "claude-opus-4-8"));
    try testing.expectEqual(@as(u64, 3600), sumField(events, "input_tokens"));
    try testing.expectEqual(@as(u64, 360), sumField(events, "output_tokens"));
    try testing.expectEqual(@as(u64, 10000), sumField(events, "cache_creation_tokens"));
    try testing.expectEqual(@as(u64, 35000), sumField(events, "cache_read_tokens"));
    // Events come out in file order with attribution fields intact.
    try testing.expectEqual(@as(i64, 1783479480100), events[0].timestamp_ms);
    try testing.expectEqual(@as(i64, 1783479515800), events[7].timestamp_ms);
    for (events) |ev| {
        try testing.expectEqual(types.Agent.claude, ev.agent);
        try testing.expectEqualStrings(fixture_session_id, ev.session_id);
        try testing.expectEqualStrings(fixture_cwd, ev.cwd);
    }
}

test "dedup spans files: subagent re-log adds only new events" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    try tailer.feed("projects/slug/session1.jsonl", session1_fixture, sink.sink());
    try testing.expectEqual(@as(usize, 8), sink.events.items.len);

    // The subagent file re-logs two of the session's messages (same
    // message.id + requestId) plus two genuinely new haiku messages.
    try tailer.feed("projects/slug/session1/subagents/agent-sub1.jsonl", sub1_fixture, sink.sink());
    const events = sink.events.items;
    try testing.expectEqual(@as(usize, 10), events.len);
    try testing.expectEqual(@as(usize, 2), countModel(events, "claude-haiku-4-5"));
    try testing.expectEqual(@as(u64, 3600 + 1900), sumField(events, "input_tokens"));
}

test "a message missing requestId dedups on message.id alone" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    // Fixture line A7 (msg_...0008) has no requestId; feeding the whole
    // fixture twice must not duplicate it (or anything else).
    try tailer.feed("f1", session1_fixture, sink.sink());
    try tailer.feed("f1", session1_fixture, sink.sink());
    try testing.expectEqual(@as(usize, 8), sink.events.items.len);
    try testing.expect(tailer.seen.contains("msg_a0000000000000000000008"));
}

test "chunked feeds at awkward byte boundaries match a single feed" {
    for ([_]usize{ 7, 933, 4096 }) |chunk_len| {
        var tailer = Tailer.init(testing.allocator);
        defer tailer.deinit();
        var sink = ListSink.init(testing.allocator);
        defer sink.deinit();

        var offset: usize = 0;
        while (offset < session1_fixture.len) {
            const end = @min(offset + chunk_len, session1_fixture.len);
            try tailer.feed("f1", session1_fixture[offset..end], sink.sink());
            offset = end;
        }
        try testing.expectEqual(@as(usize, 8), sink.events.items.len);
        try testing.expectEqual(@as(u64, 3600), sumField(sink.events.items, "input_tokens"));
    }
}

test "carry buffers a partial line until its newline arrives" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    const line =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T02:58:00.100Z\"," ++
        "\"requestId\":\"req_x0000000000000000000001\",\"message\":{\"model\":\"claude-fable-5\"," ++
        "\"id\":\"msg_x0000000000000000000001\",\"usage\":{\"input_tokens\":11,\"output_tokens\":22," ++
        "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}";
    // Split inside the JSON — nothing complete yet.
    try tailer.feed("f1", line[0..40], sink.sink());
    try testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try tailer.feed("f1", line[40..], sink.sink());
    try testing.expectEqual(@as(usize, 0), sink.events.items.len);
    // The newline completes the carried line.
    try tailer.feed("f1", "\n", sink.sink());
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(@as(u64, 11), sink.events.items[0].input_tokens);
    // Missing sessionId / cwd default to empty strings.
    try testing.expectEqualStrings("", sink.events.items[0].session_id);
    try testing.expectEqualStrings("", sink.events.items[0].cwd);
}

test "tailer survives a garbage file and still emits the one valid event" {
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    try tailer.feed("garbage.jsonl", garbage_fixture, sink.sink());
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(@as(u64, 13), sink.events.items[0].totalTokens());
}

test "feedWith on an arena emits exactly what the legacy path emits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var legacy_tailer = Tailer.init(testing.allocator);
    defer legacy_tailer.deinit();
    var legacy = ListSink.init(testing.allocator);
    defer legacy.deinit();
    try legacy_tailer.feed("session1.jsonl", session1_fixture, legacy.sink());
    try legacy_tailer.feed("agent-sub1.jsonl", sub1_fixture, legacy.sink());

    var arena_tailer = Tailer.init(testing.allocator);
    defer arena_tailer.deinit();
    var arena_sink = ListSink.init(arena);
    try arena_tailer.feedWith(arena, "session1.jsonl", session1_fixture, arena_sink.sink());
    try arena_tailer.feedWith(arena, "agent-sub1.jsonl", sub1_fixture, arena_sink.sink());

    try testing.expectEqual(@as(usize, 10), legacy.events.items.len);
    try testing.expectEqual(legacy.events.items.len, arena_sink.events.items.len);
    for (legacy.events.items, arena_sink.events.items) |want, got| {
        try testing.expectEqual(want.agent, got.agent);
        try testing.expectEqual(want.timestamp_ms, got.timestamp_ms);
        try testing.expectEqualStrings(want.model, got.model);
        try testing.expectEqual(want.input_tokens, got.input_tokens);
        try testing.expectEqual(want.output_tokens, got.output_tokens);
        try testing.expectEqual(want.cache_creation_tokens, got.cache_creation_tokens);
        try testing.expectEqual(want.cache_read_tokens, got.cache_read_tokens);
        try testing.expectEqualStrings(want.session_id, got.session_id);
        try testing.expectEqualStrings(want.cwd, got.cwd);
    }
}

test "the dedup set outlives the event arena" {
    // The regression this module must never have again: parse onto a
    // per-sweep arena, destroy it, and the tailer's `seen` keys (which the
    // statefile serializes and the next sweep probes) must still be its own
    // memory. A borrowed key here reads as silently corrupted session data.
    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();

    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sink = ListSink.init(arena);
        try tailer.feedWith(arena, "session1.jsonl", session1_fixture, sink.sink());
        try testing.expectEqual(@as(usize, 8), sink.events.items.len);
    }

    // Touch every key: a dangling slice fails here, under the GPA's
    // freed-memory poisoning, rather than three sweeps later.
    try testing.expectEqual(@as(usize, 8), tailer.seen.count());
    var it = tailer.seen.keyIterator();
    while (it.next()) |key| try testing.expect(std.mem.startsWith(u8, key.*, "msg_"));
    try testing.expect(tailer.seen.contains("msg_a0000000000000000000008"));

    // And it still dedups: re-feeding the same bytes on a fresh arena
    // emits nothing.
    var arena2_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2_state.deinit();
    const arena2 = arena2_state.allocator();
    var sink2 = ListSink.init(arena2);
    try tailer.feedWith(arena2, "session1.jsonl", session1_fixture, sink2.sink());
    try testing.expectEqual(@as(usize, 0), sink2.events.items.len);
    try testing.expectEqual(@as(usize, 8), tailer.seen.count());
}

test "feedWith degrades gracefully on the garbage fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(arena);

    try tailer.feedWith(arena, "garbage.jsonl", garbage_fixture, sink.sink());
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(@as(u64, 13), sink.events.items[0].totalTokens());
}

test "sweepIncrementalWith threads the arena through scan and hot passes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const slug_dir = "projects/-home-dev-example-project";
    const session_rel = slug_dir ++ "/" ++ fixture_session_id ++ ".jsonl";
    try tmp.dir.createDirPath(io, slug_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/projects", .{base});
    const roots = [_][]const u8{root};

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();

    var now: i64 = 1_000_000;
    {
        // Sweep 1: full walk, everything parsed onto a sweep-scoped arena.
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sink = ListSink.init(arena);
        try testing.expect(try tailer.sweepIncrementalWith(arena, arena, io, &roots, sink.sink(), now));
        try testing.expectEqual(@as(usize, 8), sink.events.items.len);
    }
    try testing.expectEqual(@as(usize, 8), tailer.seen.count());

    const appended =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:05:00.000Z\"," ++
        "\"requestId\":\"req_inc0000000000000000001\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"message\":{\"model\":\"claude-fable-5\",\"id\":\"msg_inc0000000000000000001\"," ++
        "\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_creation_input_tokens\":0," ++
        "\"cache_read_input_tokens\":0}}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture ++ appended });

    // Sweep 2: hot pass, a second arena, offsets and dedup carried across
    // the first arena's grave.
    now += sweep_test_tick_ms;
    var arena2_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2_state.deinit();
    const arena2 = arena2_state.allocator();
    var sink2 = ListSink.init(arena2);
    try testing.expect(try tailer.sweepIncrementalWith(arena2, arena2, io, &roots, sink2.sink(), now));
    try testing.expectEqual(@as(usize, 1), sink2.events.items.len);
    try testing.expectEqual(@as(u64, 10), sink2.events.items[0].input_tokens);
    try testing.expectEqualStrings(fixture_session_id, sink2.events.items[0].session_id);
    try testing.expectEqual(@as(usize, 9), tailer.seen.count());
}

test "discoverRoots honors env order, trims entries, dedups, and skips missing dirs" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "cfg-a/projects");
    try tmp.dir.createDirPath(io, "home/.claude/projects");
    try tmp.dir.createDirPath(io, "home/.config"); // no claude/projects below it

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_len];

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env = try std.fmt.allocPrint(arena, " {s}/cfg-a , {s}/does-not-exist,", .{ base, base });
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});

    const roots = try discoverRoots(arena, io, env, home);
    try testing.expectEqual(@as(usize, 2), roots.len);
    const want_first = try std.fmt.allocPrint(arena, "{s}/cfg-a/projects", .{base});
    const want_second = try std.fmt.allocPrint(arena, "{s}/home/.claude/projects", .{base});
    try testing.expectEqualStrings(want_first, roots[0]);
    try testing.expectEqualStrings(want_second, roots[1]);

    // An env entry pointing at ~/.claude must not produce a duplicate root.
    const env_dup = try std.fmt.allocPrint(arena, "{s}/home/.claude", .{base});
    const roots_dup = try discoverRoots(arena, io, env_dup, home);
    try testing.expectEqual(@as(usize, 1), roots_dup.len);
    try testing.expectEqualStrings(want_second, roots_dup[0]);

    // No env var at all: only the existing home candidate remains.
    const roots_home = try discoverRoots(arena, io, null, home);
    try testing.expectEqual(@as(usize, 1), roots_home.len);
    try testing.expectEqualStrings(want_second, roots_home[0]);
}

test "sweep finds nested jsonl files and scanFile resumes at the stored offset" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const slug_dir = "projects/-home-dev-example-project";
    const session_rel = slug_dir ++ "/" ++ fixture_session_id ++ ".jsonl";
    try tmp.dir.createDirPath(io, slug_dir ++ "/" ++ fixture_session_id ++ "/subagents");
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });
    try tmp.dir.writeFile(io, .{
        .sub_path = slug_dir ++ "/" ++ fixture_session_id ++ "/subagents/agent-sub1.jsonl",
        .data = sub1_fixture,
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_len];

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/projects", .{base});
    const roots = [_][]const u8{root};

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    try tailer.sweep(testing.allocator, io, &roots, sink.sink());
    try testing.expectEqual(@as(usize, 10), sink.events.items.len);

    // Sweeping again with nothing new reads nothing and emits nothing.
    try tailer.sweep(testing.allocator, io, &roots, sink.sink());
    try testing.expectEqual(@as(usize, 10), sink.events.items.len);

    // Append one duplicate (A5's message.id + requestId again) and one new
    // message; only the new one comes out, from the stored offset onward.
    const appended =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T02:58:20.500Z\"," ++
        "\"requestId\":\"req_a0000000000000000000005\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_a0000000000000000000005\"," ++
        "\"usage\":{\"input_tokens\":500,\"output_tokens\":50,\"cache_creation_input_tokens\":3000," ++
        "\"cache_read_input_tokens\":7000}}}\n" ++
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:01:00.000Z\"," ++
        "\"requestId\":\"req_c0000000000000000000001\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"cwd\":\"" ++ fixture_cwd ++ "\",\"message\":{\"model\":\"claude-fable-5\"," ++
        "\"id\":\"msg_c0000000000000000000001\",\"usage\":{\"input_tokens\":50,\"output_tokens\":5," ++
        "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture ++ appended });

    try tailer.sweep(testing.allocator, io, &roots, sink.sink());
    const events = sink.events.items;
    try testing.expectEqual(@as(usize, 11), events.len);
    try testing.expectEqual(@as(u64, 50), events[10].input_tokens);
    try testing.expectEqualStrings("claude-fable-5", events[10].model);

    // A truncated (rotated) file resets the offset and re-reads cleanly —
    // dedup still keeps already-seen messages out.
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });
    try tailer.sweep(testing.allocator, io, &roots, sink.sink());
    try testing.expectEqual(@as(usize, 11), sink.events.items.len);
}

test "sweepIncremental: hot appends, dir changes, and the full-walk safety net" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const slug_dir = "projects/-home-dev-example-project";
    const session_rel = slug_dir ++ "/" ++ fixture_session_id ++ ".jsonl";
    try tmp.dir.createDirPath(io, slug_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/projects", .{base});
    const roots = [_][]const u8{root};

    var tailer = Tailer.init(testing.allocator);
    defer tailer.deinit();
    var sink = ListSink.init(testing.allocator);
    defer sink.deinit();

    var now: i64 = 1_000_000;
    // First call always full-walks and parses history.
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 8), sink.events.items.len);
    try testing.expectEqual(@as(usize, 1), tailer.inc.hot.items.len);
    try testing.expect(tailer.inc.dir_mtimes.count() >= 2); // root + slug dir

    // Quiet fast tick: nothing changed, nothing read.
    now += sweep_test_tick_ms;
    try testing.expect(!try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 8), sink.events.items.len);

    // Append to the (hot) active transcript: caught on the next fast tick.
    const appended =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:05:00.000Z\"," ++
        "\"requestId\":\"req_inc0000000000000000001\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"message\":{\"model\":\"claude-fable-5\",\"id\":\"msg_inc0000000000000000001\"," ++
        "\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_creation_input_tokens\":0," ++
        "\"cache_read_input_tokens\":0}}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture ++ appended });
    now += sweep_test_tick_ms;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 9), sink.events.items.len);
    try testing.expectEqual(@as(u64, 10), sink.events.items[8].input_tokens);

    // A NEW file (subagent) changes its parent dirs' mtimes → full walk
    // this tick picks it up: +2 events (2 of its 4 lines are re-logs).
    try tmp.dir.createDirPath(io, slug_dir ++ "/" ++ fixture_session_id ++ "/subagents");
    try tmp.dir.writeFile(io, .{
        .sub_path = slug_dir ++ "/" ++ fixture_session_id ++ "/subagents/agent-sub1.jsonl",
        .data = sub1_fixture,
    });
    now += sweep_test_tick_ms;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 11), sink.events.items.len);

    // A grown file that is neither hot nor announced by any dir change is
    // invisible to fast ticks — that's the documented trade — but the
    // periodic full walk catches it.
    for (tailer.inc.hot.items) |h| testing.allocator.free(h.path);
    tailer.inc.hot.clearRetainingCapacity(); // simulate "cold file"
    const appended2 =
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-08T03:06:00.000Z\"," ++
        "\"requestId\":\"req_inc0000000000000000002\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"message\":{\"model\":\"claude-fable-5\",\"id\":\"msg_inc0000000000000000002\"," ++
        "\"usage\":{\"input_tokens\":20,\"output_tokens\":2,\"cache_creation_input_tokens\":0," ++
        "\"cache_read_input_tokens\":0}}}\n";
    try tmp.dir.writeFile(io, .{
        .sub_path = session_rel,
        .data = session1_fixture ++ appended ++ appended2,
    });
    now += sweep_test_tick_ms;
    try testing.expect(!try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 11), sink.events.items.len);
    now += full_walk_interval_ms;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, sink.sink(), now));
    try testing.expectEqual(@as(usize, 12), sink.events.items.len);
    try testing.expectEqual(@as(u64, 20), sink.events.items[11].input_tokens);
}

/// A 2 s engine tick, well under `full_walk_interval_ms`.
const sweep_test_tick_ms: i64 = 2_000;
