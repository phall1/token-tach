//! Filesystem change gate for the SQLite-backed agent sources.
//!
//! opencode, goose and kilo all poll a SQLite database every 2 s, and all
//! three pay for it the same way: an open/prepare/step/close plus a full
//! scan (opencode's usage projection is not indexed by time; goose and kilo
//! re-read a `>=`/`>` tail window). An idle agent changes nothing, so two
//! `stat` calls replace the entire round trip.
//!
//! The gate stats the database AND its `-wal` sidecar, because in WAL mode
//! the newest rows live in the sidecar until a checkpoint and the main file's
//! mtime does not move. Missing the WAL would make a busy session look idle.
//!
//! TWO PROPERTIES MAKE THIS SAFE, and both are structural rather than
//! documentary — the API is shaped so you cannot get them wrong:
//!
//!  1. `beforeOpen` captures the fingerprint BEFORE the database is opened.
//!     A write that lands mid-scan therefore stamps a fingerprint NEWER than
//!     the one we are about to commit, so the next tick sees a mismatch and
//!     rescans. The failure mode that ordering avoids is the silent one: a
//!     row written between "scan" and "stat" would be sealed behind a
//!     fingerprint that claims we already read it, and would never be
//!     ingested at all. A redundant rescan costs microseconds; a dropped
//!     row is permanently missing spend.
//!
//!  2. `commit` is called ONLY after the scan reached `SQLITE_DONE`. A busy
//!     database, a prepare failure, or a mid-iteration bail leaves the gate
//!     holding the previous fingerprint, so the next tick retries even
//!     though nothing on disk moved. Caching a partial read is the same
//!     dropped-row bug wearing a different hat.

const std = @import("std");

/// Filesystem identity of one file. mtime alone is not enough: a same-second
/// rewrite of equal length is rare but real, and size alone misses in-place
/// updates. The pair is what callers compare.
///
/// `i96` matches `std.Io.File.Stat.mtime.nanoseconds` — do not narrow it.
pub const FileStamp = struct {
    mtime_ns: i96,
    size: u64,

    pub fn eql(self: FileStamp, other: FileStamp) bool {
        return self.mtime_ns == other.mtime_ns and self.size == other.size;
    }
};

/// Filesystem identity of a database: the main file plus its WAL sidecar,
/// where the newest rows live before a checkpoint.
pub const Fingerprint = struct {
    main: FileStamp,
    wal: ?FileStamp,

    /// A WAL that appeared or vanished (journal mode flipped, or a
    /// `wal_checkpoint(TRUNCATE)` removed it) is a change, not a match.
    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        if (!self.main.eql(other.main)) return false;
        if (self.wal == null or other.wal == null) return self.wal == null and other.wal == null;
        return self.wal.?.eql(other.wal.?);
    }
};

/// Two stats, no SQLite. Null means the database is gone or unreadable,
/// which callers treat as "nothing to poll" — never as "unchanged", so a
/// database that reappears is scanned rather than skipped.
pub fn fingerprint(path: []const u8) ?Fingerprint {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var cwd = std.Io.Dir.cwd();
    const main = cwd.statFile(io, path, .{}) catch return null;
    var wal_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return null;
    const wal = if (cwd.statFile(io, wal_path, .{})) |stat|
        FileStamp{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size }
    else |_|
        null;
    return .{
        .main = .{ .mtime_ns = main.mtime.nanoseconds, .size = main.size },
        .wal = wal,
    };
}

/// The gate itself: one field, two calls, embedded in a poller.
///
///     const fp = self.gate.beforeOpen(path) orelse return;  // nothing to do
///     ... open, prepare, step to SQLITE_DONE ...
///     if (step_result != c.SQLITE_DONE) return;             // no commit
///     self.gate.commit(fp);
///
/// The `orelse return` covers both "unreadable" and "unchanged"; neither is
/// an error and neither produces events.
pub const Gate = struct {
    /// Fingerprint of the last database this gate saw read to completion.
    /// Null until the first complete scan, which is why a fresh poller
    /// always scans once.
    last: ?Fingerprint = null,

    /// Fingerprint the caller must hold across the scan and hand back to
    /// `commit`, or null when there is nothing worth opening. Capturing here
    /// — before the open — is property (1) in the module doc.
    pub fn beforeOpen(self: *const Gate, path: []const u8) ?Fingerprint {
        const current = fingerprint(path) orelse return null;
        if (self.last) |last| {
            if (current.eql(last)) return null;
        }
        return current;
    }

    /// Record a completed scan. Call this ONLY on `SQLITE_DONE` — property
    /// (2) in the module doc.
    pub fn commit(self: *Gate, fp: Fingerprint) void {
        self.last = fp;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// A temp directory that hands out absolute paths, so the tests drive the
/// gate through the same `Io.Dir.cwd()` lookup the pollers use.
const Tmp = struct {
    dir: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    /// Length only, never a slice: `Tmp` is returned by value and a slice
    /// into the initializer's copy of `buf` would dangle.
    len: usize = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init() !Tmp {
        var self = Tmp{ .dir = testing.tmpDir(.{}) };
        self.len = try self.dir.dir.realPath(testing.io, &self.buf);
        return self;
    }

    fn deinit(self: *Tmp) void {
        self.dir.cleanup();
    }

    fn write(self: *Tmp, name: []const u8, bytes: []const u8) !void {
        try self.dir.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    }

    fn remove(self: *Tmp, name: []const u8) !void {
        try self.dir.dir.deleteFile(testing.io, name);
    }

    fn path(self: *Tmp, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.path_buf, "{s}/{s}", .{ self.buf[0..self.len], name });
    }
};

test "a missing database fingerprints as null, not as unchanged" {
    var tmp = try Tmp.init();
    defer tmp.deinit();

    const missing = try tmp.path("nope.db");
    try testing.expectEqual(@as(?Fingerprint, null), fingerprint(missing));

    // A gate that never saw the file must not report "unchanged" either:
    // both arms of beforeOpen return null, but only one of them may ever
    // be followed by a commit.
    var gate = Gate{};
    try testing.expectEqual(@as(?Fingerprint, null), gate.beforeOpen(missing));
    try testing.expectEqual(@as(?Fingerprint, null), gate.last);
}

test "the gate opens once per change and skips a quiet database" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    try tmp.write("agent.db", "one");
    const db = try tmp.path("agent.db");

    var gate = Gate{};
    // First look: nothing cached, so we scan.
    const first = gate.beforeOpen(db) orelse return error.NoFingerprint;
    // Until the scan completes, the gate still says "scan" — a poller that
    // bailed before SQLITE_DONE retries on the very next tick.
    try testing.expect(gate.beforeOpen(db) != null);
    gate.commit(first);
    // Committed and quiet: no open.
    try testing.expectEqual(@as(?Fingerprint, null), gate.beforeOpen(db));

    // A size change reopens even if the clock has not visibly ticked.
    try tmp.write("agent.db", "one more");
    const second = gate.beforeOpen(db) orelse return error.NoFingerprint;
    try testing.expect(!second.eql(first));
    gate.commit(second);
    try testing.expectEqual(@as(?Fingerprint, null), gate.beforeOpen(db));
}

test "a WAL that appears, grows, or is checkpointed away is a change" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    try tmp.write("agent.db", "main");
    const db = try tmp.path("agent.db");

    var gate = Gate{};
    gate.commit(gate.beforeOpen(db) orelse return error.NoFingerprint);
    try testing.expectEqual(@as(?Fingerprint, null), gate.beforeOpen(db));

    // Rows land in the sidecar; the main file never moves. Missing this is
    // how a busy WAL-mode session would look permanently idle.
    try tmp.write("agent.db-wal", "frame");
    const with_wal = gate.beforeOpen(db) orelse return error.NoFingerprint;
    gate.commit(with_wal);
    try testing.expectEqual(@as(?Fingerprint, null), gate.beforeOpen(db));

    // The sidecar grows.
    try tmp.write("agent.db-wal", "frame frame");
    const bigger_wal = gate.beforeOpen(db) orelse return error.NoFingerprint;
    try testing.expect(!bigger_wal.eql(with_wal));
    gate.commit(bigger_wal);

    // wal_checkpoint(TRUNCATE) removes it entirely: absent != unchanged.
    try tmp.remove("agent.db-wal");
    const no_wal = gate.beforeOpen(db) orelse return error.NoFingerprint;
    try testing.expectEqual(@as(?FileStamp, null), no_wal.wal);
    try testing.expect(!no_wal.eql(bigger_wal));
}

test "a write landing mid-scan is rescanned, never sealed behind a stamp" {
    var tmp = try Tmp.init();
    defer tmp.deinit();
    try tmp.write("agent.db", "row1");
    const db = try tmp.path("agent.db");

    var gate = Gate{};
    // Property (1): the caller captured this BEFORE opening…
    const captured = gate.beforeOpen(db) orelse return error.NoFingerprint;
    // …and a writer appended while the scan was in flight, so the row may or
    // may not be in the result set.
    try tmp.write("agent.db", "row1row2");
    // Committing the pre-open stamp is exactly what makes the next tick
    // rescan. Had the stamp been taken after the scan, this would report
    // "unchanged" and row2 would be lost forever.
    gate.commit(captured);
    try testing.expect(gate.beforeOpen(db) != null);
}

test "FileStamp compares both halves" {
    const a = FileStamp{ .mtime_ns = 100, .size = 10 };
    try testing.expect(a.eql(.{ .mtime_ns = 100, .size = 10 }));
    try testing.expect(!a.eql(.{ .mtime_ns = 101, .size = 10 }));
    // Same-nanosecond rewrite of a different length: size is what catches it.
    try testing.expect(!a.eql(.{ .mtime_ns = 100, .size = 11 }));
}
