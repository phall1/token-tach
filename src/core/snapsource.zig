//! Generic rewritten-whole-JSON usage poller ("stable record snapshots").
//!
//! Several harnesses (Cline, Roo Code, Continue CLI, Factory Droid) persist
//! usage in JSON files that are REWRITTEN in full on every mutation, not
//! appended — so byte-offset tailing (tailsource.zig) cannot work. Instead,
//! a harness adapter parses the whole file into records with STABLE per-
//! record keys, and this module keeps a per-file snapshot of the last-seen
//! usage numbers per key. On re-parse it emits opencode-style Changes:
//!
//! - new key                       -> `.{ .previous = null, .current = ev }`
//! - existing key, numbers moved   -> `.{ .previous = old,  .current = ev }`
//!   (so the ledger's replace() keeps totals exact)
//! - unchanged key                 -> nothing
//!
//! Records that DISAPPEAR from a file (truncated/cleared/deleted history)
//! are intentionally NOT retracted: the spend happened, so the ledger keeps
//! it, and the snapshot keeps the record so a later rewrite that re-lists
//! it does not double-count. If two records in one file share a key (e.g. a
//! millisecond-timestamp collision), the later one replaces the earlier via
//! a replace Change — the net ledger effect is the last record's numbers.
//!
//! Steady-state cost is ~zero: each poll re-reads/re-parses only files
//! whose mtime OR size moved, and `sweep` does not even look at most files
//! most of the time — it walks the tree on a schedule and otherwise stats
//! only a handful of fingerprints (see `sweepIncremental`). That gate is
//! not a micro-optimization: these roots are VS Code globalStorage task
//! trees with ONE DIRECTORY PER TASK, so an ungated recursive walk every
//! two seconds costs a heavy user tens of thousands of syscalls a minute
//! per poller — for three pollers that usually have nothing new.
//!
//! Ownership: emitted Change events are duped with the allocator passed to
//! scanFile/sweep (free with `freeChanges`; arenas make it free). Internal
//! snapshots live on the allocator given to `init` and die with `deinit`.
//! Record slices returned by an adapter's `parseFile` must be allocated in
//! (or outlive) the arena it is handed — the engine copies what it keeps.

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

/// How long a sweep may go without a full tree re-walk. The safety net for
/// every change the cheap fingerprints cannot see: a file REWRITTEN in
/// place does not move its parent directory's mtime (that is what these
/// sources do on every mutation), so a cold task the hot list has evicted
/// is invisible until this fires. 30s of latency on a stale task, against
/// a walk of thousands of directories every 2s, is the right trade.
pub const full_walk_interval_ms: i64 = 30_000;

/// How many recently-modified files the fast path stats every tick.
/// Deliberately larger than tailsource's 8: one Cline/Roo user commonly
/// has several tasks warm at once (multiple VS Code windows, a task plus
/// its subagent transcripts), and a file that falls off this list goes
/// unnoticed for up to `full_walk_interval_ms`. 32 stats per tick is
/// noise next to the walk this whole mechanism exists to avoid.
pub const hot_files_max = 32;

/// How many subdirectories carry an mtime fingerprint between full walks.
/// Directory mtimes are how a NEW task's file gets noticed promptly, but
/// the roots already catch new task directories with one stat each — the
/// per-task entries only add "a second file appeared inside an existing
/// task directory". Tracking every task directory would put the per-tick
/// cost back in the thousands, so only the most recently modified ones
/// hold a slot; the rest fall to the full-walk safety net.
pub const tracked_dirs_max = 64;

/// One ledger mutation. `previous == null` means add; otherwise the ledger
/// must replace `previous`'s contribution with `current`'s.
pub const Change = struct {
    previous: ?types.UsageEvent = null,
    current: types.UsageEvent,
};

/// What the poller knows about the file being parsed, handed to the
/// adapter's `parseFile` (e.g. to derive a session id from the path).
pub const FileContext = struct {
    /// Path of the file being parsed (as passed to scan/sweep).
    path: []const u8,
    /// The agent tag the poller was configured with.
    agent: types.Agent,
};

/// One usage-bearing record extracted from a file: a per-file-stable key
/// (message id, timestamp string, ...) plus the usage event it maps to.
/// Keys are compared per file — the same key in two files is two records.
pub const Record = struct {
    key: []const u8,
    event: types.UsageEvent,
};

/// Parse one whole file. Must tolerate garbage: malformed input returns an
/// empty slice (or any error — both are treated as "no records", and the
/// file's mtime/size are still recorded so a permanently-bad file costs one
/// stat per poll, never a re-read). Everything returned must be allocated
/// in `arena` (or be static / a slice of `bytes`/`ctx.path`).
pub const ParseFileFn = *const fn (arena: Allocator, bytes: []const u8, ctx: FileContext) anyerror![]Record;

/// Everything harness-specific about one rewritten-JSON usage source.
pub const Adapter = struct {
    /// Only files whose path ends with this are parsed
    /// (e.g. ".messages.json", "ui_messages.json").
    file_suffix: []const u8,
    parseFile: ParseFileFn,
};

/// Free the events of Changes emitted by scanFile/sweep (they are duped
/// with the allocator passed to those calls).
pub fn freeChanges(allocator: Allocator, changes: []const Change) void {
    for (changes) |change| {
        if (change.previous) |ev| freeEvent(allocator, ev);
        freeEvent(allocator, change.current);
    }
}

/// Rewritten-JSON usage poller: per-file {key -> last-seen usage} snapshots
/// with mtime/size gating. One Poller per (agent, adapter) pair.
pub const Poller = struct {
    allocator: Allocator,
    agent: types.Agent,
    adapter: Adapter,
    snapshots: std.StringHashMapUnmanaged(FileSnapshot) = .empty,
    inc: Incremental = .{},
    stats: Stats = .{},

    /// Sweep telemetry. Cheap counters, and the only way to answer "is this
    /// poller actually quiet on a tree with thousands of tasks?" without a
    /// syscall trace — `full_walks` should stay near `elapsed /
    /// full_walk_interval_ms` while a session is merely being appended to.
    pub const Stats = struct {
        /// Full recursive walks performed (the expensive tier).
        full_walks: u64 = 0,
        /// Ticks that skipped the walk and only stat'd fingerprints.
        fast_ticks: u64 = 0,
        /// Files that got past the mtime/size gate and were re-parsed.
        files_scanned: u64 = 0,
    };

    /// Change-detection state for `sweepIncremental`: root + directory
    /// mtimes catch files appearing, the hot list catches rewrites of the
    /// files someone is actively using, and the clock catches everything
    /// else. Same three tiers as tailsource.Tailer.Incremental, with the
    /// directory tier capped (see `tracked_dirs_max`).
    const Incremental = struct {
        /// Sweep roots. Always fingerprinted, never evicted: a brand-new
        /// task directory moves its root's mtime and nothing else's.
        roots: std.ArrayList(Fingerprint) = .empty,
        /// Most recently modified subdirectories, capped.
        dirs: std.ArrayList(Fingerprint) = .empty,
        /// Most recently modified matching files, capped.
        hot: std.ArrayList(Fingerprint) = .empty,
        last_full_walk_ms: ?i64 = null,

        fn deinit(self: *Incremental, gpa: Allocator) void {
            freeFingerprints(gpa, &self.roots);
            freeFingerprints(gpa, &self.dirs);
            freeFingerprints(gpa, &self.hot);
        }
    };

    const FileSnapshot = struct {
        mtime_ns: i96 = 0,
        size: u64 = 0,
        /// key (owned) -> last-seen event (strings owned).
        records: std.StringHashMapUnmanaged(types.UsageEvent) = .empty,

        fn deinit(self: *FileSnapshot, gpa: Allocator) void {
            var it = self.records.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                freeEvent(gpa, entry.value_ptr.*);
            }
            self.records.deinit(gpa);
            self.* = undefined;
        }
    };

    pub fn init(allocator: Allocator, agent: types.Agent, adapter: Adapter) Poller {
        return .{ .allocator = allocator, .agent = agent, .adapter = adapter };
    }

    pub fn deinit(self: *Poller) void {
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.snapshots.deinit(self.allocator);
        self.inc.deinit(self.allocator);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Persistence surface (statefile save/restore)
    // -----------------------------------------------------------------------

    /// One snapshotted record, as the statefile saver wants it — exactly
    /// the fields the ledger needs to reconstruct a replace() baseline
    /// (mirrors what statefile persists for opencode rows).
    pub const WireRecord = struct {
        key: []const u8,
        timestamp_ms: i64,
        model: []const u8 = "",
        input: u64 = 0,
        output: u64 = 0,
        cache_creation: u64 = 0,
        cache_read: u64 = 0,
        session_id: []const u8 = "",
        cwd: []const u8 = "",
    };

    pub const RecordIterator = struct {
        inner: std.StringHashMapUnmanaged(types.UsageEvent).Iterator,

        pub fn next(self: *RecordIterator) ?WireRecord {
            const entry = self.inner.next() orelse return null;
            const ev = entry.value_ptr.*;
            return .{
                .key = entry.key_ptr.*,
                .timestamp_ms = ev.timestamp_ms,
                .model = ev.model,
                .input = ev.input_tokens,
                .output = ev.output_tokens,
                .cache_creation = ev.cache_creation_tokens,
                .cache_read = ev.cache_read_tokens,
                .session_id = ev.session_id,
                .cwd = ev.cwd,
            };
        }
    };

    /// One tracked file with its change-gate fingerprint and records.
    pub const FileEntry = struct {
        path: []const u8,
        mtime_ns: i96,
        size: u64,
        records: RecordIterator,
    };

    pub const FileIterator = struct {
        inner: std.StringHashMapUnmanaged(FileSnapshot).Iterator,

        pub fn next(self: *FileIterator) ?FileEntry {
            const entry = self.inner.next() orelse return null;
            return .{
                .path = entry.key_ptr.*,
                .mtime_ns = entry.value_ptr.mtime_ns,
                .size = entry.value_ptr.size,
                .records = .{ .inner = entry.value_ptr.records.iterator() },
            };
        }
    };

    /// Iterate every tracked file for statefile save. Borrowed slices —
    /// valid until the next mutating call on the poller.
    pub fn files(self: *const Poller) FileIterator {
        return .{ .inner = self.snapshots.iterator() };
    }

    /// Statefile restore: re-seed one file's snapshot. Restored records
    /// suppress re-emission of already-ledgered history; the mtime/size
    /// pair suppresses the initial re-read entirely when the file has not
    /// changed since the save. All strings are duped; caller keeps theirs.
    pub fn seed(self: *Poller, path: []const u8, mtime_ns: i96, size: u64, records: []const WireRecord) !void {
        const snap = try self.snapFor(path);
        snap.mtime_ns = mtime_ns;
        snap.size = size;
        for (records) |w| {
            try self.putStored(snap, w.key, .{
                .agent = self.agent,
                .timestamp_ms = w.timestamp_ms,
                .model = w.model,
                .input_tokens = w.input,
                .output_tokens = w.output,
                .cache_creation_tokens = w.cache_creation,
                .cache_read_tokens = w.cache_read,
                .session_id = w.session_id,
                .cwd = w.cwd,
            });
        }
    }

    // -----------------------------------------------------------------------
    // Polling
    // -----------------------------------------------------------------------

    /// Stat `path` and, only when its mtime or size moved, re-read and
    /// re-parse it, appending add/replace Changes to `out`. Emitted event
    /// strings are duped with `event_allocator` (free with `freeChanges`),
    /// which is also used for transient read/parse scratch via an arena.
    /// A vanished or unreadable file is silently skipped.
    pub fn scanFile(
        self: *Poller,
        event_allocator: Allocator,
        io: std.Io,
        path: []const u8,
        out: *std.ArrayList(Change),
    ) !void {
        var cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(io, path, .{}) catch return;
        if (self.snapshots.getPtr(path)) |snap| {
            if (snap.mtime_ns == stat.mtime.nanoseconds and snap.size == stat.size) return;
        }

        var file = cwd.openFile(io, path, .{}) catch return;
        defer file.close(io);
        const size = file.length(io) catch return;

        var arena_state = std.heap.ArenaAllocator.init(event_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const buf = try arena.alloc(u8, @intCast(size));
        const n = file.readPositionalAll(io, buf, 0) catch return;

        const empty: []Record = &.{};
        const records: []const Record = self.adapter.parseFile(arena, buf[0..n], .{
            .path = path,
            .agent = self.agent,
        }) catch empty;

        const snap = try self.snapFor(path);
        for (records) |rec| {
            if (rec.key.len == 0) continue;
            var current = rec.event;
            current.agent = self.agent;

            if (snap.records.getPtr(rec.key)) |old| {
                if (eventEqual(old.*, current)) continue;
                const cur_owned = try dupeEvent(event_allocator, current);
                errdefer freeEvent(event_allocator, cur_owned);
                const prev_owned = try dupeEvent(event_allocator, old.*);
                errdefer freeEvent(event_allocator, prev_owned);
                try out.append(event_allocator, .{ .previous = prev_owned, .current = cur_owned });
            } else {
                const cur_owned = try dupeEvent(event_allocator, current);
                errdefer freeEvent(event_allocator, cur_owned);
                try out.append(event_allocator, .{ .previous = null, .current = cur_owned });
            }
            try self.putStored(snap, rec.key, current);
        }
        // Disappeared keys stay in the snapshot on purpose (see module doc).
        snap.mtime_ns = stat.mtime.nanoseconds;
        snap.size = stat.size;
        self.stats.files_scanned += 1;
    }

    /// Find every file matching the adapter's suffix under each root and
    /// scanFile it — but only walk the tree when the cheap fingerprints say
    /// it is worth walking (see `sweepIncremental`, which this defers to
    /// with a monotonic clock). Unreadable roots and files are skipped, not
    /// errors: polls race live writers. `event_allocator` doubles as walk
    /// scratch (arena-friendly).
    pub fn sweep(
        self: *Poller,
        event_allocator: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(Change),
    ) !void {
        // `.awake` and not wall time: an NTP step or a manual clock change
        // must not strand the full-walk safety net minutes into the future.
        const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
        _ = try self.sweepIncremental(event_allocator, io, roots, out, now_ms);
    }

    /// Cheap steady-state sweep, three tiers — same strategy as
    /// tailsource's twin. Full-walk on the first call, whenever a tracked
    /// directory's mtime moved (a file appeared or vanished), and at least
    /// every `full_walk_interval_ms`; otherwise stat only the root and
    /// directory fingerprints plus the `hot_files_max` most recently
    /// modified files. Returns true when any file was re-parsed.
    ///
    /// Exposed with an explicit `now_ms` so callers with a clock of their
    /// own (and tests) can drive the schedule deterministically.
    pub fn sweepIncremental(
        self: *Poller,
        event_allocator: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(Change),
        now_ms: i64,
    ) !bool {
        const due = if (self.inc.last_full_walk_ms) |last|
            now_ms - last >= full_walk_interval_ms
        else
            true;
        if (due or self.dirsChanged(io)) {
            self.stats.full_walks += 1;
            return self.fullWalk(event_allocator, io, roots, out, now_ms);
        }
        self.stats.fast_ticks += 1;
        return self.hotPass(event_allocator, io, out);
    }

    /// Did any tracked directory's mtime move since the last full walk?
    /// A vanished (or newly appeared, hence unstattable-before) directory
    /// counts as changed — the walk re-derives the truth either way.
    fn dirsChanged(self: *Poller, io: std.Io) bool {
        var cwd = std.Io.Dir.cwd();
        for ([_][]const Fingerprint{ self.inc.roots.items, self.inc.dirs.items }) |list| {
            for (list) |f| {
                const stat = cwd.statFile(io, f.path, .{}) catch return true;
                if (stat.mtime.nanoseconds != f.mtime_ns) return true;
            }
        }
        return false;
    }

    /// Stat only the hot files and re-parse the ones whose mtime or size
    /// moved. Unreadable files are skipped rather than dropped from the
    /// list: a file being rewritten non-atomically is momentarily absent,
    /// and it must stay hot so the next tick sees it again.
    fn hotPass(
        self: *Poller,
        event_allocator: Allocator,
        io: std.Io,
        out: *std.ArrayList(Change),
    ) !bool {
        var changed = false;
        var cwd = std.Io.Dir.cwd();
        for (self.inc.hot.items) |*h| {
            const stat = cwd.statFile(io, h.path, .{}) catch continue;
            if (self.snapshots.getPtr(h.path)) |snap| {
                if (snap.mtime_ns == stat.mtime.nanoseconds and snap.size == stat.size) continue;
            }
            self.scanFile(event_allocator, io, h.path, out) catch continue;
            h.mtime_ns = stat.mtime.nanoseconds;
            changed = true;
        }
        return changed;
    }

    /// Walk everything: stat each matching file (the mtime is needed for
    /// the hot list anyway, and it spares scanFile's open on the ~all of
    /// them that did not move), re-parse the changed ones, and rebuild the
    /// fingerprints the fast path runs on.
    fn fullWalk(
        self: *Poller,
        event_allocator: Allocator,
        io: std.Io,
        roots: []const []const u8,
        out: *std.ArrayList(Change),
        now_ms: i64,
    ) !bool {
        var next: Incremental = .{ .last_full_walk_ms = now_ms };
        errdefer next.deinit(self.allocator);
        var changed = false;

        var cwd = std.Io.Dir.cwd();
        for (roots) |root| {
            if (cwd.statFile(io, root, .{})) |stat| {
                try appendFingerprint(self.allocator, &next.roots, root, stat.mtime.nanoseconds);
            } else |_| continue;
            var dir = cwd.openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(event_allocator);
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                switch (entry.kind) {
                    .directory => {
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(event_allocator, &.{ root, entry.path });
                        defer event_allocator.free(path);
                        try insertRecent(self.allocator, &next.dirs, path, stat.mtime.nanoseconds, tracked_dirs_max);
                    },
                    .file => {
                        if (!std.mem.endsWith(u8, entry.path, self.adapter.file_suffix)) continue;
                        const stat = dir.statFile(io, entry.path, .{}) catch continue;
                        const path = try std.fs.path.join(event_allocator, &.{ root, entry.path });
                        defer event_allocator.free(path);
                        const fresh = if (self.snapshots.getPtr(path)) |snap|
                            snap.mtime_ns != stat.mtime.nanoseconds or snap.size != stat.size
                        else
                            true;
                        if (fresh) {
                            self.scanFile(event_allocator, io, path, out) catch {};
                            changed = true;
                        }
                        try insertRecent(self.allocator, &next.hot, path, stat.mtime.nanoseconds, hot_files_max);
                    },
                    else => {},
                }
            }
        }

        self.inc.deinit(self.allocator);
        self.inc = next;
        return changed;
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    fn snapFor(self: *Poller, path: []const u8) !*FileSnapshot {
        const gop = try self.snapshots.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                self.snapshots.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn putStored(self: *Poller, snap: *FileSnapshot, key: []const u8, event: types.UsageEvent) !void {
        const owned_event = try dupeEvent(self.allocator, event);
        errdefer freeEvent(self.allocator, owned_event);
        if (snap.records.getPtr(key)) |slot| {
            freeEvent(self.allocator, slot.*);
            slot.* = owned_event;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try snap.records.put(self.allocator, owned_key, owned_event);
    }
};

// ---------------------------------------------------------------------------
// Fingerprint helpers (incremental sweep)
// ---------------------------------------------------------------------------

/// An owned path plus the mtime it had at the last full walk.
const Fingerprint = struct { path: []u8, mtime_ns: i96 };

fn appendFingerprint(
    gpa: Allocator,
    list: *std.ArrayList(Fingerprint),
    path: []const u8,
    mtime_ns: i96,
) !void {
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try list.append(gpa, .{ .path = owned, .mtime_ns = mtime_ns });
}

/// Keep a bounded list of the most recently modified paths, newest first.
/// Anything older than the whole list when it is already full is dropped
/// without allocating — the walk hands these in directory order, not time
/// order, so most candidates lose.
fn insertRecent(
    gpa: Allocator,
    list: *std.ArrayList(Fingerprint),
    path: []const u8,
    mtime_ns: i96,
    max: usize,
) !void {
    var at: usize = list.items.len;
    for (list.items, 0..) |f, i| {
        if (mtime_ns > f.mtime_ns) {
            at = i;
            break;
        }
    }
    if (at >= max) return;
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try list.insert(gpa, at, .{ .path = owned, .mtime_ns = mtime_ns });
    if (list.items.len > max) {
        const evicted = list.pop().?;
        gpa.free(evicted.path);
    }
}

fn freeFingerprints(gpa: Allocator, list: *std.ArrayList(Fingerprint)) void {
    for (list.items) |f| gpa.free(f.path);
    list.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Event helpers
// ---------------------------------------------------------------------------

fn dupeEvent(allocator: Allocator, ev: types.UsageEvent) !types.UsageEvent {
    const model = try allocator.dupe(u8, ev.model);
    errdefer allocator.free(model);
    const session_id = try allocator.dupe(u8, ev.session_id);
    errdefer allocator.free(session_id);
    const cwd = try allocator.dupe(u8, ev.cwd);
    return .{
        .agent = ev.agent,
        .timestamp_ms = ev.timestamp_ms,
        .model = model,
        .input_tokens = ev.input_tokens,
        .output_tokens = ev.output_tokens,
        .cache_creation_tokens = ev.cache_creation_tokens,
        .cache_read_tokens = ev.cache_read_tokens,
        .session_id = session_id,
        .cwd = cwd,
    };
}

fn freeEvent(allocator: Allocator, ev: types.UsageEvent) void {
    allocator.free(ev.model);
    allocator.free(ev.session_id);
    allocator.free(ev.cwd);
}

fn eventEqual(a: types.UsageEvent, b: types.UsageEvent) bool {
    return a.timestamp_ms == b.timestamp_ms and a.input_tokens == b.input_tokens and
        a.output_tokens == b.output_tokens and a.cache_creation_tokens == b.cache_creation_tokens and
        a.cache_read_tokens == b.cache_read_tokens and std.mem.eql(u8, a.model, b.model) and
        std.mem.eql(u8, a.session_id, b.session_id) and std.mem.eql(u8, a.cwd, b.cwd);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Trivial test format, one record per line:
///   `<key> <ts_ms> <input> <output> <model> <session_id>`
/// Malformed lines are skipped. Counts invocations so the mtime gate is
/// observable ("unchanged file -> zero work").
var test_parse_calls: usize = 0;

fn testParseFile(arena: Allocator, bytes: []const u8, ctx: FileContext) anyerror![]Record {
    test_parse_calls += 1;
    var list: std.ArrayList(Record) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r"), ' ');
        const key = it.next() orelse continue;
        if (key.len == 0) continue;
        const ts = std.fmt.parseInt(i64, it.next() orelse continue, 10) catch continue;
        const input = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
        const output = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
        const model = it.next() orelse continue;
        const session_id = it.next() orelse continue;
        try list.append(arena, .{
            .key = key,
            .event = .{
                .agent = ctx.agent,
                .timestamp_ms = ts,
                .model = model,
                .input_tokens = input,
                .output_tokens = output,
                .session_id = session_id,
            },
        });
    }
    return list.toOwnedSlice(arena);
}

const test_adapter = Adapter{
    .file_suffix = ".snap",
    .parseFile = testParseFile,
};

/// Stand-in agent tag: tests exercise the engine mechanics; real adapters
/// get their variant of types.Agent with engine wiring.
const test_agent: types.Agent = .opencode;

test "initial parse adds, rewrite replaces and adds, disappearance keeps history" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k1 1000 10 1 model-a sess-1\nnot a record\n",
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.snap", .{base});

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].previous == null);
    const e1 = out.items[0].current;
    try testing.expectEqual(test_agent, e1.agent);
    try testing.expectEqual(@as(i64, 1000), e1.timestamp_ms);
    try testing.expectEqual(@as(u64, 10), e1.input_tokens);
    try testing.expectEqual(@as(u64, 1), e1.output_tokens);
    try testing.expectEqualStrings("model-a", e1.model);
    try testing.expectEqualStrings("sess-1", e1.session_id);

    // Rewrite: k1 grew, k2 is new -> one replace Change + one add Change.
    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k1 1000 25 3 model-a sess-1\nk2 2000 5 1 model-b sess-1\n",
    });
    freeChanges(testing.allocator, out.items);
    out.clearRetainingCapacity();
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const replaced = out.items[0];
    try testing.expect(replaced.previous != null);
    try testing.expectEqual(@as(u64, 10), replaced.previous.?.input_tokens);
    try testing.expectEqual(@as(u64, 1), replaced.previous.?.output_tokens);
    try testing.expectEqual(@as(u64, 25), replaced.current.input_tokens);
    try testing.expectEqual(@as(u64, 3), replaced.current.output_tokens);
    const added = out.items[1];
    try testing.expect(added.previous == null);
    try testing.expectEqualStrings("model-b", added.current.model);

    // Truncation: k1 vanishes. No retraction; snapshot still remembers it,
    // and the unchanged k2 record emits nothing.
    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k2 2000 5 1 model-b sess-1\n",
    });
    freeChanges(testing.allocator, out.items);
    out.clearRetainingCapacity();
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    var fit = poller.files();
    const entry = fit.next() orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings(path, entry.path);
    var keys_seen: usize = 0;
    var rit = entry.records;
    while (rit.next()) |_| keys_seen += 1;
    try testing.expectEqual(@as(usize, 2), keys_seen); // k1 kept, k2
    try testing.expect(fit.next() == null);

    // A re-listed k1 with the old numbers is already snapshotted: no
    // double count when history reappears (size changed -> re-parse).
    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k1 1000 25 3 model-a sess-1\nk2 2000 5 1 model-b sess-1\n",
    });
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "unchanged file is zero work: the mtime/size gate skips the parse" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k1 1000 10 1 model-a sess-1\n",
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.snap", .{base});

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    const calls_before = test_parse_calls;
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(calls_before + 1, test_parse_calls);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // No rewrite: the gate short-circuits before open/read/parse.
    try poller.scanFile(testing.allocator, io, path, &out);
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(calls_before + 1, test_parse_calls);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "sweep walks roots, matches the suffix, and skips other files" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/aa");
    try tmp.dir.createDirPath(io, "sessions/bb");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/aa/s1.snap", .data = "k1 1000 10 1 m sess-a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/bb/s2.snap", .data = "k1 2000 20 2 m sess-b\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/bb/notes.txt", .data = "k9 9 9 9 m s\n" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // Same key "k1" in two files stays two independent records.
    var input_sum: u64 = 0;
    for (out.items) |ch| input_sum += ch.current.input_tokens;
    try testing.expectEqual(@as(u64, 30), input_sum);

    // Quiet second sweep: nothing re-emitted.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "sweepIncremental: quiet ticks skip the walk, hot rewrites and new dirs do not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/aa");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/aa/s1.snap", .data = "k1 1000 10 1 m sess-a\n" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // First tick always walks: history parsed, fingerprints built.
    var now: i64 = 1_000_000;
    try testing.expect(try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 1), poller.stats.full_walks);
    try testing.expectEqual(@as(u64, 1), poller.stats.files_scanned);
    try testing.expectEqual(@as(usize, 1), poller.inc.roots.items.len);
    try testing.expectEqual(@as(usize, 1), poller.inc.dirs.items.len); // sessions/aa
    try testing.expectEqual(@as(usize, 1), poller.inc.hot.items.len);

    // Quiet tick: no walk at all, and the per-file gate holds too.
    now += 2_000;
    try testing.expect(!try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(u64, 1), poller.stats.full_walks);
    try testing.expectEqual(@as(u64, 1), poller.stats.fast_ticks);
    try testing.expectEqual(@as(u64, 1), poller.stats.files_scanned);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // The active task's file is rewritten in place: caught on a fast tick,
    // still without walking (this is the steady state we are optimizing).
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/aa/s1.snap", .data = "k1 1000 100 12 m sess-a\n" });
    now += 2_000;
    try testing.expect(try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(u64, 1), poller.stats.full_walks);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[1].previous != null);
    try testing.expectEqual(@as(u64, 10), out.items[1].previous.?.input_tokens);
    try testing.expectEqual(@as(u64, 100), out.items[1].current.input_tokens);

    // A NEW task directory moves the root's mtime -> walk this tick.
    try tmp.dir.createDirPath(io, "sessions/bb");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/bb/s2.snap", .data = "k1 2000 20 2 m sess-b\n" });
    now += 2_000;
    try testing.expect(try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(u64, 2), poller.stats.full_walks);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expect(out.items[2].previous == null);
    try testing.expectEqualStrings("sess-b", out.items[2].current.session_id);
    try testing.expectEqual(@as(usize, 2), poller.inc.hot.items.len);
}

test "sweepIncremental: the full-walk interval rescues a file that fell off the hot list" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions/aa");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/aa/s1.snap", .data = "k1 1000 10 1 m sess-a\n" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    var now: i64 = 1_000_000;
    try testing.expect(try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // Stand in for a heavy tree evicting this task from the hot list, then
    // rewrite the file in place: rewriting does NOT move the directory's
    // mtime, so both cheap tiers are blind to it by construction.
    for (poller.inc.hot.items) |h| testing.allocator.free(h.path);
    poller.inc.hot.clearRetainingCapacity();
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/aa/s1.snap", .data = "k1 1000 100 12 m sess-a\n" });

    now += 2_000;
    try testing.expect(!try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(u64, 1), poller.stats.full_walks);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // The safety net fires and the spend lands, at most one interval late.
    now += full_walk_interval_ms;
    try testing.expect(try poller.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(u64, 2), poller.stats.full_walks);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u64, 100), out.items[1].current.input_tokens);
    try testing.expectEqual(@as(usize, 1), poller.inc.hot.items.len); // rebuilt
}

test "seed restores snapshots: no re-emission, replaces carry the seeded previous" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const history = "k1 1000 10 1 model-a sess-1\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.snap", .data = history });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.snap", .{base});
    var cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});

    // Fresh poller restored from a statefile save.
    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    try poller.seed(path, stat.mtime.nanoseconds, stat.size, &.{.{
        .key = "k1",
        .timestamp_ms = 1000,
        .model = "model-a",
        .input = 10,
        .output = 1,
        .session_id = "sess-1",
    }});

    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // Unchanged since the save: the gate holds, nothing parsed or emitted.
    const calls_before = test_parse_calls;
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(calls_before, test_parse_calls);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // Grown record after restore: replace Change with the SEEDED previous.
    try tmp.dir.writeFile(io, .{ .sub_path = "s1.snap", .data = "k1 1000 100 12 model-a sess-1\n" });
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].previous != null);
    try testing.expectEqual(@as(u64, 10), out.items[0].previous.?.input_tokens);
    try testing.expectEqual(@as(u64, 100), out.items[0].current.input_tokens);
    try testing.expectEqualStrings("sess-1", out.items[0].previous.?.session_id);
}

test "files() round-trips through seed()" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "s1.snap",
        .data = "k1 1000 10 1 model-a sess-1\nk2 2000 20 2 model-b sess-1\n",
    });
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s1.snap", .{base});

    var poller = Poller.init(testing.allocator, test_agent, test_adapter);
    defer poller.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }
    try poller.scanFile(testing.allocator, io, path, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Save: copy what files() yields, restore into a second poller.
    var restored = Poller.init(testing.allocator, test_agent, test_adapter);
    defer restored.deinit();
    var fit = poller.files();
    while (fit.next()) |entry| {
        var recs: std.ArrayList(Poller.WireRecord) = .empty;
        defer recs.deinit(testing.allocator);
        var rit = entry.records;
        while (rit.next()) |w| try recs.append(testing.allocator, w);
        try restored.seed(entry.path, entry.mtime_ns, entry.size, recs.items);
    }

    // The restored poller sees the same on-disk state as already known.
    var out2: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, out2.items);
        out2.deinit(testing.allocator);
    }
    try restored.scanFile(testing.allocator, io, path, &out2);
    try testing.expectEqual(@as(usize, 0), out2.items.len);
}
