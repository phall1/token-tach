//! Generic append-only-JSONL usage tailer — the reusable machinery every
//! harness adapter shares. A harness adapter (see pisrc.zig) supplies a
//! small `Adapter` vtable: how to parse one line, how to derive a session
//! id from a file path, and which file suffix to tail. This module supplies
//! everything else: recursive root walking with directory-mtime gating,
//! per-file byte offsets, partial-last-line carry buffers, and a global
//! dedup set — the same steady-state-is-~free strategy as claude.zig's
//! Tailer (files only appear and grow; unchanged bytes are never re-read).
//!
//! Ownership contract (arena-friendly, GPA-correct):
//! - Every string the adapter's `parse` returns — event strings, dedup key,
//!   meta strings — must be allocated with the `event_allocator` it was
//!   handed. Event strings pass through to the caller inside the emitted
//!   `types.UsageEvent` (free with `freeEvents`); dedup keys and meta
//!   strings are consumed and freed by the tailer.
//! - Internal state (offsets, carries, per-file meta, dedup keys) lives on
//!   the allocator given to `init` and is released by `deinit`.

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

/// How long the incremental sweep may go without a full tree re-walk.
/// The safety net for changes invisible to dir mtimes + the hot list
/// (e.g. an old, cold session file growing again).
pub const full_walk_interval_ms: i64 = 30_000;
/// How many recently-modified files the incremental sweep stats every tick.
pub const hot_files_max = 8;

const read_chunk_len = 64 * 1024;
/// Carry buffers above this capacity are released after the line completes
/// (harness logs can contain multi-megabyte single lines).
const carry_shrink_threshold = 1024 * 1024;

// ---------------------------------------------------------------------------
// Adapter surface
// ---------------------------------------------------------------------------

/// What the tailer knows about the file a line came from, handed to the
/// adapter's `parse` so events can be attributed without re-deriving it.
pub const FileContext = struct {
    /// Path of the file being tailed (as passed to scan/sweep).
    path: []const u8,
    /// The agent tag the adapter was configured with — parse stamps it on
    /// the event (the tailer re-stamps defensively either way).
    agent: types.Agent,
    /// Session id: per-file meta if a parsed line set one, else the
    /// adapter's `sessionIdFromPath` derivation, else "".
    session_id: []const u8 = "",
    /// Working directory captured from an earlier meta line, or "".
    cwd: []const u8 = "",
};

/// What one parsed line yields.
pub const Parsed = union(enum) {
    /// A usage event. `usage.session_id`/`usage.cwd` left empty are filled
    /// in by the tailer from the file's context before emission.
    event: Event,
    /// File-scoped metadata to remember for subsequent lines (e.g. the cwd
    /// from a session header). The tailer copies these into its own state
    /// and frees the passed strings.
    meta: Meta,

    pub const Event = struct {
        usage: types.UsageEvent,
        /// Optional stable identity for global dedup (e.g. a message id):
        /// events whose key was already seen — in any file — are dropped.
        /// Null means no dedup for this event.
        dedup_key: ?[]const u8 = null,
    };

    pub const Meta = struct {
        session_id: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
    };
};

/// Parse one complete line (already trimmed, never empty). Returns null for
/// anything uninteresting or malformed — garbage must never error. All
/// returned strings must be allocated with `event_allocator` (see the
/// module ownership contract).
pub const ParseFn = *const fn (event_allocator: Allocator, line: []const u8, ctx: FileContext) ?Parsed;

/// Derive a session id from a file path (e.g. the filename's trailing
/// UUID). Must return a slice into `path` or a static string — the tailer
/// does not free it.
pub const SessionIdFn = *const fn (path: []const u8) []const u8;

/// Everything harness-specific about one JSONL usage source.
pub const Adapter = struct {
    /// Agent tag stamped on every emitted event.
    agent: types.Agent,
    /// Only files whose name ends with this are tailed.
    file_suffix: []const u8 = ".jsonl",
    parse: ParseFn,
    sessionIdFromPath: ?SessionIdFn = null,
};

/// Free the strings of events emitted by this module (they are duped with
/// the event allocator passed to feed/scanFile/sweep*).
pub fn freeEvents(allocator: Allocator, events: []const types.UsageEvent) void {
    for (events) |ev| freeEventStrings(allocator, ev);
}

fn freeEventStrings(allocator: Allocator, ev: types.UsageEvent) void {
    allocator.free(ev.model);
    allocator.free(ev.session_id);
    allocator.free(ev.cwd);
}

// ---------------------------------------------------------------------------
// Tailer
// ---------------------------------------------------------------------------

/// Incremental NDJSON tailer with per-file byte offsets, per-file
/// partial-line carry buffers and meta, and a global dedup set. Duck-typed
/// like claude.Tailer / codex.Tailer so the engine integrates identically.
pub const Tailer = struct {
    allocator: Allocator,
    adapter: Adapter,
    states: std.StringHashMapUnmanaged(FileState) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    inc: Incremental = .{},

    const FileState = struct {
        offset: u64 = 0,
        carry: std.ArrayList(u8) = .empty,
        /// Owned by the tailer allocator; empty = not seen yet.
        session_id: []const u8 = "",
        cwd: []const u8 = "",

        fn deinit(self: *FileState, gpa: Allocator) void {
            self.carry.deinit(gpa);
            if (self.session_id.len > 0) gpa.free(self.session_id);
            if (self.cwd.len > 0) gpa.free(self.cwd);
            self.* = undefined;
        }
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

    pub fn init(allocator: Allocator, adapter: Adapter) Tailer {
        return .{ .allocator = allocator, .adapter = adapter };
    }

    pub fn deinit(self: *Tailer) void {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.states.deinit(self.allocator);
        var kit = self.seen.keyIterator();
        while (kit.next()) |key| self.allocator.free(key.*);
        self.seen.deinit(self.allocator);
        self.inc.deinit(self.allocator);
        self.* = undefined;
    }

    /// The stored byte offset for `path`, or null if the tailer has never
    /// touched it. `offset == file size` means fully caught up.
    pub fn offsetFor(self: *const Tailer, path: []const u8) ?u64 {
        const state = self.states.get(path) orelse return null;
        return state.offset;
    }

    /// Statefile restore: mark `path` as already parsed up to `offset`.
    /// Any carry is cleared — persisted offsets always sit on a line
    /// boundary (`files()` yields them that way).
    pub fn seedOffset(self: *Tailer, path: []const u8, offset: u64) !void {
        const state = try self.stateFor(path);
        state.offset = offset;
        state.carry.clearAndFree(self.allocator);
    }

    /// Statefile restore: re-seed the per-file working directory captured
    /// from a meta line that now sits before the restored offset.
    pub fn seedCwd(self: *Tailer, path: []const u8, cwd: []const u8) !void {
        const state = try self.stateFor(path);
        try setOwned(self.allocator, &state.cwd, cwd);
    }

    /// Statefile restore: re-insert one persisted dedup key.
    pub fn seedSeen(self: *Tailer, key: []const u8) !void {
        const gop = try self.seen.getOrPut(self.allocator, key);
        if (gop.found_existing) return;
        gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
            self.seen.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    /// One tracked file, as the statefile saver wants it: `offset` is the
    /// line-boundary offset (raw offset minus any buffered partial line),
    /// so a later `seedOffset` resumes exactly where parsing left off.
    pub const FileEntry = struct {
        path: []const u8,
        offset: u64,
        cwd: []const u8,
    };

    pub const FileIterator = struct {
        inner: std.StringHashMapUnmanaged(FileState).Iterator,

        pub fn next(self: *FileIterator) ?FileEntry {
            const entry = self.inner.next() orelse return null;
            return .{
                .path = entry.key_ptr.*,
                .offset = entry.value_ptr.offset - entry.value_ptr.carry.items.len,
                .cwd = entry.value_ptr.cwd,
            };
        }
    };

    /// Iterate every tracked file for statefile save. Borrowed slices —
    /// valid until the next mutating call on the tailer.
    pub fn files(self: *const Tailer) FileIterator {
        return .{ .inner = self.states.iterator() };
    }

    fn stateFor(self: *Tailer, path: []const u8) !*FileState {
        const gop = try self.states.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                self.states.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    /// Feed raw appended bytes for `path`. Splits on '\n', parses complete
    /// lines, and buffers a trailing partial line until the next feed for
    /// the same path. Emitted events' strings are duped with
    /// `event_allocator` (free with `freeEvents`).
    pub fn feed(
        self: *Tailer,
        event_allocator: Allocator,
        path: []const u8,
        chunk: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) !void {
        const state = try self.stateFor(path);
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const segment = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (state.carry.items.len != 0) {
                try state.carry.appendSlice(self.allocator, segment);
                try self.processLine(event_allocator, state, path, state.carry.items, out);
                if (state.carry.capacity > carry_shrink_threshold) {
                    state.carry.clearAndFree(self.allocator);
                } else {
                    state.carry.clearRetainingCapacity();
                }
            } else {
                try self.processLine(event_allocator, state, path, segment, out);
            }
        }
        if (rest.len != 0) try state.carry.appendSlice(self.allocator, rest);
    }

    /// Open `path`, read everything past the stored byte offset, feed it,
    /// and advance the offset. A shrunken file (rotation/truncation) resets
    /// the offset and carry. A vanished file is silently skipped. `scratch`
    /// is only used for the transient read buffer (arena-friendly).
    pub fn scanFile(
        self: *Tailer,
        scratch: Allocator,
        io: std.Io,
        path: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) !void {
        var cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer file.close(io);
        const size = try file.length(io);

        var offset: u64 = blk: {
            const state = try self.stateFor(path);
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
            try self.feed(scratch, path, buf[0..n], out);
            offset += n;
            // Re-fetch: feed may touch the states map (same key, but stay
            // safe against pointer invalidation across hash map operations).
            self.states.getPtr(path).?.offset = offset;
            if (n < buf.len) break;
        }
    }

    /// Recursively find every matching file under each root and scanFile
    /// it. Unreadable roots and files are skipped, not errors: sweeps race
    /// live writers. `scratch` doubles as the event allocator.
    pub fn sweep(
        self: *Tailer,
        scratch: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
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
                if (!std.mem.endsWith(u8, entry.path, self.adapter.file_suffix)) continue;
                const path = try std.fs.path.join(scratch, &.{ root, entry.path });
                defer scratch.free(path);
                self.scanFile(scratch, io, path, out) catch continue;
            }
        }
    }

    /// Cheap steady-state sweep — same three-tier strategy as claude.zig's
    /// `sweepIncremental` (see that doc comment): full-walk on the first
    /// call, on any known directory mtime change, and at least every
    /// `full_walk_interval_ms`; otherwise stat only the known directories
    /// plus the `hot_files_max` most recently modified files. `arena` is
    /// the scratch AND event allocator. Returns true when any new bytes
    /// were parsed.
    pub fn sweepIncremental(
        self: *Tailer,
        arena: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
        now_ms: i64,
    ) !bool {
        const due = if (self.inc.last_full_walk_ms) |last|
            now_ms - last >= full_walk_interval_ms
        else
            true;
        if (due or self.dirsChanged(io)) return self.fullWalk(arena, io, roots, out, now_ms);
        return self.hotPass(arena, io, out);
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
        arena: Allocator,
        io: std.Io,
        out: *std.ArrayList(types.UsageEvent),
    ) !bool {
        var changed = false;
        var cwd = std.Io.Dir.cwd();
        for (self.inc.hot.items) |*h| {
            const stat = cwd.statFile(io, h.path, .{}) catch continue;
            const known = self.offsetFor(h.path) orelse 0;
            if (stat.size == known) continue;
            self.scanFile(arena, io, h.path, out) catch continue;
            h.mtime_ns = stat.mtime.nanoseconds;
            changed = true;
        }
        return changed;
    }

    /// Walk everything: stat each matching file (3x cheaper than the open
    /// + length + close of an unconditional scanFile), scan the changed
    /// ones, and rebuild the dir-mtime map + hot list for the fast path.
    fn fullWalk(
        self: *Tailer,
        arena: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(types.UsageEvent),
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
            var walker = try dir.walk(arena);
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                switch (entry.kind) {
                    .directory => {
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(arena, &.{ root, entry.path });
                        defer arena.free(path);
                        try putDirMtime(self.allocator, &next.dir_mtimes, path, stat.mtime.nanoseconds);
                    },
                    .file => {
                        if (!std.mem.endsWith(u8, entry.path, self.adapter.file_suffix)) continue;
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(arena, &.{ root, entry.path });
                        defer arena.free(path);
                        if (stat.size != (self.offsetFor(path) orelse 0)) {
                            self.scanFile(arena, io, path, out) catch {};
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

    fn processLine(
        self: *Tailer,
        event_allocator: Allocator,
        state: *FileState,
        path: []const u8,
        line: []const u8,
        out: *std.ArrayList(types.UsageEvent),
    ) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const ctx = FileContext{
            .path = path,
            .agent = self.adapter.agent,
            .session_id = self.sessionIdFor(state, path),
            .cwd = state.cwd,
        };
        const parsed = self.adapter.parse(event_allocator, trimmed, ctx) orelse return;
        switch (parsed) {
            .meta => |meta| {
                if (meta.session_id) |sid| {
                    try setOwned(self.allocator, &state.session_id, sid);
                    event_allocator.free(sid);
                }
                if (meta.cwd) |c| {
                    try setOwned(self.allocator, &state.cwd, c);
                    event_allocator.free(c);
                }
            },
            .event => |pe| {
                var ev = pe.usage;
                if (pe.dedup_key) |key| {
                    defer event_allocator.free(key);
                    const gop = self.seen.getOrPut(self.allocator, key) catch |err| {
                        freeEventStrings(event_allocator, ev);
                        return err;
                    };
                    if (gop.found_existing) {
                        freeEventStrings(event_allocator, ev);
                        return;
                    }
                    gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
                        self.seen.removeByPtr(gop.key_ptr);
                        freeEventStrings(event_allocator, ev);
                        return err;
                    };
                }
                ev.agent = self.adapter.agent;
                if (ev.session_id.len == 0 and ctx.session_id.len != 0) {
                    ev.session_id = try event_allocator.dupe(u8, ctx.session_id);
                }
                if (ev.cwd.len == 0 and state.cwd.len != 0) {
                    ev.cwd = try event_allocator.dupe(u8, state.cwd);
                }
                try out.append(event_allocator, ev);
            },
        }
    }

    fn sessionIdFor(self: *const Tailer, state: *const FileState, path: []const u8) []const u8 {
        if (state.session_id.len != 0) return state.session_id;
        if (self.adapter.sessionIdFromPath) |hook| return hook(path);
        return "";
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn setOwned(gpa: Allocator, slot: *[]const u8, value: []const u8) Allocator.Error!void {
    const dup = try gpa.dupe(u8, value);
    if (slot.len > 0) gpa.free(slot.*);
    slot.* = dup;
}

/// Insert (path duped) into a map of owned dir paths -> mtime.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Minimal line grammar for the test adapter, one record per line:
///   meta lines:  meta <cwd>
///   event lines: ev <key|-> <ts_ms> <in> <out> <model>
/// Anything else is garbage and must be skipped.
fn testParse(event_allocator: Allocator, line: []const u8, ctx: FileContext) ?Parsed {
    var it = std.mem.splitScalar(u8, line, ' ');
    const kind = it.next() orelse return null;
    if (std.mem.eql(u8, kind, "meta")) {
        const cwd = it.next() orelse return null;
        const owned = event_allocator.dupe(u8, cwd) catch return null;
        return .{ .meta = .{ .cwd = owned } };
    }
    if (!std.mem.eql(u8, kind, "ev")) return null;
    const key = it.next() orelse return null;
    const ts = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const in = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const out = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const model = it.next() orelse return null;
    if (it.next() != null) return null;

    const model_owned = event_allocator.dupe(u8, model) catch return null;
    const key_owned: ?[]const u8 = if (std.mem.eql(u8, key, "-"))
        null
    else
        event_allocator.dupe(u8, key) catch {
            event_allocator.free(model_owned);
            return null;
        };
    return .{ .event = .{
        .usage = .{
            .agent = ctx.agent,
            .timestamp_ms = ts,
            .model = model_owned,
            .input_tokens = in,
            .output_tokens = out,
        },
        .dedup_key = key_owned,
    } };
}

fn testSessionId(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) return base[0 .. base.len - ".jsonl".len];
    return base;
}

const test_adapter = Adapter{
    .agent = .claude,
    .parse = testParse,
    .sessionIdFromPath = testSessionId,
};

test "feed parses events, stamps context, dedups globally, skips garbage" {
    var tailer = Tailer.init(testing.allocator, test_adapter);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    const chunk =
        "meta /proj/alpha\n" ++
        "ev k1 1000 10 1 model-a\n" ++
        "total garbage, not a record\n" ++
        "ev k1 1000 10 1 model-a\n" ++ // duplicate key: dropped
        "ev - 2000 20 2 model-b\n"; // no key: never deduped
    try tailer.feed(testing.allocator, "root/s1.jsonl", chunk, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    const e1 = out.items[0];
    try testing.expectEqual(types.Agent.claude, e1.agent);
    try testing.expectEqual(@as(i64, 1000), e1.timestamp_ms);
    try testing.expectEqual(@as(u64, 10), e1.input_tokens);
    try testing.expectEqual(@as(u64, 1), e1.output_tokens);
    try testing.expectEqualStrings("model-a", e1.model);
    try testing.expectEqualStrings("s1", e1.session_id);
    try testing.expectEqualStrings("/proj/alpha", e1.cwd);
    try testing.expectEqualStrings("model-b", out.items[1].model);

    // Same keyed event re-logged in a DIFFERENT file: still dropped;
    // the keyless one comes through again (session id from the new path).
    try tailer.feed(testing.allocator, "root/s2.jsonl", "ev k1 1000 10 1 model-a\nev - 2000 20 2 model-b\n", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("s2", out.items[2].session_id);
    try testing.expectEqualStrings("", out.items[2].cwd); // no meta in s2
}

test "meta line only affects lines after it, within its own file" {
    var tailer = Tailer.init(testing.allocator, test_adapter);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, "a.jsonl", "ev - 1 1 1 m\nmeta /late\nev - 2 1 1 m\n", &out);
    try testing.expectEqualStrings("", out.items[0].cwd);
    try testing.expectEqualStrings("/late", out.items[1].cwd);
}

test "chunked feeds at awkward byte boundaries match a single feed" {
    const chunk =
        "meta /proj/alpha\n" ++
        "ev k1 1000 10 1 model-a\n" ++
        "ev k2 2000 20 2 model-b\n" ++
        "ev k3 3000 30 3 model-c\n";
    for ([_]usize{ 1, 7, 33 }) |chunk_len| {
        var tailer = Tailer.init(testing.allocator, test_adapter);
        defer tailer.deinit();
        var out: std.ArrayList(types.UsageEvent) = .empty;
        defer {
            freeEvents(testing.allocator, out.items);
            out.deinit(testing.allocator);
        }

        var offset: usize = 0;
        while (offset < chunk.len) {
            const end = @min(offset + chunk_len, chunk.len);
            try tailer.feed(testing.allocator, "f.jsonl", chunk[offset..end], &out);
            offset = end;
        }
        try testing.expectEqual(@as(usize, 3), out.items.len);
        try testing.expectEqual(@as(u64, 60), out.items[0].input_tokens + out.items[1].input_tokens + out.items[2].input_tokens);
        for (out.items) |ev| try testing.expectEqualStrings("/proj/alpha", ev.cwd);
    }
}

test "files() reports line-boundary offsets while a partial line is carried" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const complete = "ev k1 1000 10 1 model-a\n";
    const partial = "ev k2 2000 20 2"; // no newline yet
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.jsonl", .data = complete ++ partial });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.jsonl", .{base});

    var tailer = Tailer.init(testing.allocator, test_adapter);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(?u64, complete.len + partial.len), tailer.offsetFor(path));

    var it = tailer.files();
    const entry = it.next() orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings(path, entry.path);
    try testing.expectEqual(@as(u64, complete.len), entry.offset); // carry subtracted
    try testing.expect(it.next() == null);

    // Completing the line catches back up.
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.jsonl", .data = complete ++ partial ++ " model-b\n" });
    try tailer.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("model-b", out.items[1].model);
}

test "seedOffset restore skips already-parsed bytes; seedCwd restores attribution" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const history = "meta /proj/alpha\nev k1 1000 10 1 model-a\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.jsonl", .data = history });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.jsonl", .{base});

    // Fresh tailer restored from a statefile: offset at EOF, cwd re-seeded.
    var tailer = Tailer.init(testing.allocator, test_adapter);
    defer tailer.deinit();
    try tailer.seedOffset(path, history.len);
    try tailer.seedCwd(path, "/proj/alpha");
    try tailer.seedSeen("k1");

    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // Nothing new: nothing emitted, offset untouched.
    try tailer.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expectEqual(@as(?u64, history.len), tailer.offsetFor(path));

    // Append one duplicate (dropped via the seeded dedup key) and one new
    // event, which carries the seeded cwd.
    const appended = "ev k1 1000 10 1 model-a\nev k2 2000 20 2 model-b\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.jsonl", .data = history ++ appended });
    try tailer.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("model-b", out.items[0].model);
    try testing.expectEqualStrings("/proj/alpha", out.items[0].cwd);
    try testing.expectEqualStrings("s1", out.items[0].session_id);
}

test "sweepIncremental: full walk, quiet ticks, hot appends, new files" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/slug-a");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/slug-a/s1.jsonl",
        .data = "meta /proj/alpha\nev k1 1000 10 1 model-a\n",
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var tailer = Tailer.init(testing.allocator, test_adapter);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    var now: i64 = 1_000_000;
    // First call always full-walks and parses history.
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(usize, 1), tailer.inc.hot.items.len);
    try testing.expect(tailer.inc.dir_mtimes.count() >= 2); // root + slug dir

    // Quiet fast tick: nothing changed, nothing read.
    now += 2_000;
    try testing.expect(!try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // Append to the (hot) active file: caught on the next fast tick.
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/slug-a/s1.jsonl",
        .data = "meta /proj/alpha\nev k1 1000 10 1 model-a\nev k2 2000 20 2 model-b\n",
    });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("model-b", out.items[1].model);
    try testing.expectEqualStrings("/proj/alpha", out.items[1].cwd);

    // A NEW file changes its parent dir's mtime -> full walk this tick.
    try tmp.dir.createDirPath(io, "sessions/slug-b");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/slug-b/s2.jsonl",
        .data = "ev k3 3000 30 3 model-c\nev k1 1000 10 1 model-a\n", // k1 deduped
    });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("s2", out.items[2].session_id);

    // Non-matching files are invisible.
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/slug-a/notes.txt", .data = "ev k9 9 9 9 m\n" });
    now += full_walk_interval_ms;
    _ = try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}
