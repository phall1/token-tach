//! The SQLite C surface this app actually uses, declared once.
//!
//! Three collectors read a vendor's SQLite database directly — opencode,
//! goose and kilo — and `dbgate.zig` already exists because all three paid
//! for the *polling* the same way. But only the change gate was ever
//! extracted: the `extern fn` block itself stayed copied into all three,
//! byte-for-byte in goose and kilo and a two-declaration superset in
//! opencode, along with a third identical copy of `columnText`.
//!
//! Nothing about an `extern` declaration is collector-specific. A shim that
//! exists in triplicate is three places to get a signature wrong and two
//! places to forget when one of them is fixed, and a wrong `extern`
//! signature is not a compile error — it is a corrupt call at runtime.
//!
//! No wrapper types, no RAII, no error sets. The call sites read as SQLITE
//! C on purpose: `sqlite3_step` returning `SQLITE_ROW` is the vendors'
//! vocabulary and the collectors are transcriptions of their schemas.
//! Only the truly universal helper (`columnText`) is lifted alongside it.

const std = @import("std");

/// Linked against the system libsqlite3 (macOS ships one).
pub const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;
    pub const SQLITE_INTEGER: c_int = 1;
    pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
    pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
    pub const SQLITE_OPEN_URI: c_int = 0x00000040;
    pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;

    pub extern fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
    pub extern fn sqlite3_close(?*sqlite3) c_int;
    pub extern fn sqlite3_busy_timeout(?*sqlite3, c_int) c_int;
    pub extern fn sqlite3_prepare_v2(?*sqlite3, [*]const u8, c_int, *?*sqlite3_stmt, ?*?[*]const u8) c_int;
    pub extern fn sqlite3_finalize(?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_bind_int64(?*sqlite3_stmt, c_int, i64) c_int;
    pub extern fn sqlite3_step(?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_column_text(?*sqlite3_stmt, c_int) ?[*]const u8;
    pub extern fn sqlite3_column_bytes(?*sqlite3_stmt, c_int) c_int;
    pub extern fn sqlite3_column_int64(?*sqlite3_stmt, c_int) i64;
    pub extern fn sqlite3_column_type(?*sqlite3_stmt, c_int) c_int;
    pub extern fn sqlite3_exec(?*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) c_int;
};

/// A TEXT column as a Zig slice, or null for SQL NULL.
///
/// `sqlite3_column_bytes` must be read AFTER `sqlite3_column_text` for the
/// length to describe the same conversion — the reason this is a helper and
/// not two calls at each of the dozens of column reads.
///
/// The slice borrows SQLite's own buffer and is invalidated by the next
/// `sqlite3_step` or `sqlite3_finalize` on this statement; every caller
/// either consumes it before stepping or dupes it.
pub fn columnText(stmt: ?*c.sqlite3_stmt, column: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return null;
    const len = c.sqlite3_column_bytes(stmt, column);
    return ptr[0..@intCast(len)];
}

/// One-slot cache for the NUL-terminated form of a database path.
///
/// `sqlite3_open_v2` needs a sentinel-terminated string and the pollers hold
/// a plain slice, so every 2 s tick used to dupe the same bytes again. The
/// path never changes in practice, so the cache hits every time after the
/// first.
pub const PathCache = struct {
    zpath: ?[:0]const u8 = null,

    pub fn deinit(self: *PathCache, allocator: std.mem.Allocator) void {
        if (self.zpath) |z| allocator.free(z);
        self.zpath = null;
    }

    /// NUL-terminated `path`, re-duped only when it differs from the last.
    pub fn get(self: *PathCache, allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
        if (self.zpath) |cached| {
            if (std.mem.eql(u8, cached, path)) return cached;
            allocator.free(cached);
            self.zpath = null;
        }
        const owned = try allocator.dupeZ(u8, path);
        self.zpath = owned;
        return owned;
    }
};

const testing = std.testing;

test "the path cache re-duplicates only when the path changes" {
    var cache: PathCache = .{};
    defer cache.deinit(testing.allocator);

    const first = try cache.get(testing.allocator, "/tmp/a.db");
    try testing.expectEqualStrings("/tmp/a.db", first);
    // Same path: the same allocation, which is the whole point.
    const again = try cache.get(testing.allocator, "/tmp/a.db");
    try testing.expectEqual(first.ptr, again.ptr);

    const other = try cache.get(testing.allocator, "/tmp/b.db");
    try testing.expectEqualStrings("/tmp/b.db", other);
    try testing.expect(first.ptr != other.ptr);
}
