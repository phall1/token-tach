//! Goose (block/goose) usage ingestion through one direct, read-only SQLite
//! connection.
//!
//! Goose maintains an append-only `usage_ledger` table inside its sessions
//! database (`~/Library/Application Support/Block/goose/sessions/sessions.db`,
//! WAL mode; `GOOSE_PATH_ROOT` overrides the root as
//! `<root>/data/sessions/sessions.db`). Rows are only ever INSERTed, so the
//! rowid is a monotonic high-water mark and incremental polling is
//! `WHERE rowid > ?`.
//!
//! The projection selects only session id, timestamp, model, and the four
//! token counters. Goose's own `cost` and `cost_source` columns are never
//! selected: token-tach prices tokens itself, so rows of every cost_source
//! ('provider', 'estimated', 'carried_forward') are ingested identically for
//! their token counts. Compaction rows (`is_compaction=1`) consume real
//! tokens and are ingested like any other row. Rows whose four token fields
//! are all zero are skipped (they carry no usage).
//!
//! The agent tag is injected by the integrator (`Poller.init(alloc, .goose)`)
//! because `types.Agent` gains its `goose` variant as part of engine wiring,
//! not here.

const std = @import("std");
const types = @import("types.zig");
const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
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
    pub extern fn sqlite3_exec(?*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) c_int;
};

const Allocator = std.mem.Allocator;

/// Environment inputs for database discovery. Null/blank fields fall through.
pub const Env = struct {
    /// $HOME. Null means the default path cannot be derived.
    home: ?[]const u8 = null,
    /// $GOOSE_PATH_ROOT — Goose's root override; the database then lives at
    /// `<root>/data/sessions/sessions.db`.
    goose_path_root: ?[]const u8 = null,
};

/// Resolve the default Goose sessions database path, or null when neither an
/// override nor a home directory is available. Allocates from `arena`; the
/// caller (or the arena) owns the result.
pub fn defaultDbPath(arena: Allocator, env: Env) !?[]const u8 {
    if (env.goose_path_root) |raw| {
        const root = std.mem.trim(u8, raw, " \t");
        if (root.len > 0)
            return try std.fs.path.join(arena, &.{ root, "data", "sessions", "sessions.db" });
    }
    const home_raw = env.home orelse return null;
    const home = std.mem.trim(u8, home_raw, " \t");
    if (home.len == 0) return null;
    return try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "Block", "goose", "sessions", "sessions.db" });
}

// The projection is intentionally explicit. Do not add cost/cost_source or
// any content-bearing columns.
const ledger_sql: [:0]const u8 =
    "SELECT rowid,session_id,created_timestamp,model," ++
    "max(coalesce(input_tokens,0),0),max(coalesce(output_tokens,0),0)," ++
    "max(coalesce(cache_read_tokens,0),0),max(coalesce(cache_write_tokens,0),0) " ++
    "FROM usage_ledger WHERE rowid>?1 ORDER BY rowid";

pub const Poller = struct {
    allocator: Allocator,
    agent: types.Agent,
    last_rowid: i64 = 0,

    pub fn init(allocator: Allocator, agent: types.Agent) Poller {
        return .{ .allocator = allocator, .agent = agent };
    }

    pub fn deinit(self: *Poller) void {
        _ = self;
    }

    /// Highest usage_ledger rowid ingested so far — persist this in the
    /// statefile between runs.
    pub fn highWater(self: *const Poller) i64 {
        return self.last_rowid;
    }

    /// Restore a persisted high-water rowid before the first poll.
    pub fn seedHighWater(self: *Poller, rowid: i64) void {
        self.last_rowid = rowid;
    }

    /// Read every ledger row past the high-water mark and append one
    /// UsageEvent per usage-bearing row. Missing/unopenable databases return
    /// cleanly with no events and no error. Event strings are owned by
    /// `event_allocator`; release with `freeEvents`.
    pub fn poll(self: *Poller, event_allocator: Allocator, path: []const u8, out: *std.ArrayList(types.UsageEvent)) !void {
        if (path.len == 0) return;
        const zpath = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(zpath);

        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(zpath.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return;
        }
        defer _ = c.sqlite3_close(db);
        _ = c.sqlite3_busy_timeout(db, 50);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, ledger_sql.ptr, @intCast(ledger_sql.len), &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, self.last_rowid);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const rowid = c.sqlite3_column_int64(stmt, 0);
            const session_id = columnText(stmt, 1) orelse {
                self.last_rowid = rowid;
                continue;
            };
            const created_s = c.sqlite3_column_int64(stmt, 2);
            const model = columnText(stmt, 3) orelse {
                self.last_rowid = rowid;
                continue;
            };
            const input: u64 = @intCast(c.sqlite3_column_int64(stmt, 4));
            const output: u64 = @intCast(c.sqlite3_column_int64(stmt, 5));
            const cache_read: u64 = @intCast(c.sqlite3_column_int64(stmt, 6));
            const cache_write: u64 = @intCast(c.sqlite3_column_int64(stmt, 7));
            if (input + output + cache_read + cache_write == 0) {
                self.last_rowid = rowid;
                continue;
            }

            const event = try dupeEvent(event_allocator, .{
                .agent = self.agent,
                .timestamp_ms = created_s *| 1000,
                .model = model,
                .input_tokens = input,
                .output_tokens = output,
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session_id,
            });
            errdefer freeEvent(event_allocator, event);
            try out.append(event_allocator, event);
            self.last_rowid = rowid;
        }
    }
};

pub fn freeEvents(allocator: Allocator, events: []const types.UsageEvent) void {
    for (events) |ev| freeEvent(allocator, ev);
}

fn columnText(stmt: ?*c.sqlite3_stmt, column: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return null;
    const len = c.sqlite3_column_bytes(stmt, column);
    return ptr[0..@intCast(len)];
}

fn dupeEvent(allocator: Allocator, ev: types.UsageEvent) !types.UsageEvent {
    const model = try allocator.dupe(u8, ev.model);
    errdefer allocator.free(model);
    const session_id = try allocator.dupe(u8, ev.session_id);
    var out = ev;
    out.model = model;
    out.session_id = session_id;
    return out;
}

fn freeEvent(allocator: Allocator, ev: types.UsageEvent) void {
    allocator.free(ev.model);
    allocator.free(ev.session_id);
}

const testing = std.testing;

test "defaultDbPath honors GOOSE_PATH_ROOT then falls back to home" {
    const arena = testing.allocator;
    const override = (try defaultDbPath(arena, .{ .home = "/home/u", .goose_path_root = "/custom/root" })).?;
    defer arena.free(override);
    try testing.expectEqualStrings("/custom/root/data/sessions/sessions.db", override);
    const default = (try defaultDbPath(arena, .{ .home = "/Users/u" })).?;
    defer arena.free(default);
    try testing.expectEqualStrings("/Users/u/Library/Application Support/Block/goose/sessions/sessions.db", default);
    try testing.expectEqual(@as(?[]const u8, null), try defaultDbPath(arena, .{}));
    try testing.expectEqual(@as(?[]const u8, null), try defaultDbPath(arena, .{ .home = "  " }));
}

test "query never selects cost or content columns" {
    try testing.expect(std.mem.indexOf(u8, ledger_sql, "cost") == null);
    try testing.expect(std.mem.indexOf(u8, ledger_sql, "data") == null);
    try testing.expect(std.mem.indexOf(u8, ledger_sql, "*") == null);
}

test "poll ingests all cost sources, skips zero rows, and tracks rowid high water" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "sessions.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    const fixture = @embedFile("fixtures/goose/sessions.sql");
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, fixture.ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 4), events.items.len);
    const first = events.items[0];
    try testing.expectEqual(types.Agent.opencode, first.agent);
    try testing.expectEqual(@as(i64, 1700000001000), first.timestamp_ms);
    try testing.expectEqualStrings("claude-sonnet-5", first.model);
    try testing.expectEqual(@as(u64, 100), first.input_tokens);
    try testing.expectEqual(@as(u64, 20), first.output_tokens);
    try testing.expectEqual(@as(u64, 40), first.cache_read_tokens);
    try testing.expectEqual(@as(u64, 8), first.cache_creation_tokens);
    try testing.expectEqualStrings("sess-a", first.session_id);
    // estimated + carried_forward rows are ingested for their tokens.
    try testing.expectEqual(@as(u64, 50), events.items[1].input_tokens);
    try testing.expectEqual(@as(u64, 30), events.items[2].input_tokens);
    // compaction row is real token consumption.
    try testing.expectEqual(@as(u64, 2000), events.items[3].input_tokens);
    try testing.expectEqual(@as(i64, 5), poller.highWater());

    // Re-poll: nothing new.
    freeEvents(testing.allocator, events.items);
    events.clearRetainingCapacity();
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);

    // Incremental append: one usage row + one zero row.
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE, null));
    const inserts =
        "INSERT INTO usage_ledger VALUES ('sess-c',1700000010,'claude-haiku-4.5',7,3,10,0,0,0.001,'provider',0);" ++
        "INSERT INTO usage_ledger VALUES ('sess-c',1700000011,'claude-haiku-4.5',0,0,0,0,0,0.0,'estimated',0);";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, inserts, null, null, null));
    _ = c.sqlite3_close(db);
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("sess-c", events.items[0].session_id);
    try testing.expectEqual(@as(u64, 7), events.items[0].input_tokens);
    try testing.expectEqual(@as(i64, 7), poller.highWater());
}

test "seedHighWater resumes past persisted rowid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "sessions.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/goose/sessions.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    poller.seedHighWater(3);
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &events);
    // Row 4 is all-zero (skipped); only the compaction row 5 remains.
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqual(@as(u64, 2000), events.items[0].input_tokens);
    try testing.expectEqual(@as(i64, 5), poller.highWater());
}

test "missing database returns cleanly" {
    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer events.deinit(testing.allocator);
    try poller.poll(testing.allocator, "/nonexistent/goose/sessions.db", &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
    try poller.poll(testing.allocator, "", &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}
