//! Kilo Code (Kilo-Org/kilocode, opencode-derived generation) usage ingestion
//! through one direct, read-only SQLite connection.
//!
//! Database: `${XDG_DATA_HOME:-~/.local/share}/kilo/kilo.db` (WAL mode);
//! `$KILO_DB` overrides with a full path. Table `message` holds one row per
//! message keyed by TEXT id with `time_created`/`time_updated` in unix
//! MILLISECONDS (assumption: kilo is opencode-derived, and opencode stores
//! epoch-ms in these columns; the fixture is authored to match). Rows are
//! treated as append-only inserts.
//!
//! Assistant rows carry a `data` JSON payload with
//! `tokens: {input, output, reasoning, cache: {read, write}}`, `cost`, and a
//! model reference. Model resolution: `data.model.id`, else `data.modelID`,
//! else the joined `session.model` JSON's `id`. `reasoning` folds into
//! output_tokens. Kilo's `cost` is ignored — token-tach prices tokens itself.
//!
//! The `data` JSON is parsed with std.json and only role/tokens/model fields
//! are ever read or copied out — message content text is NEVER extracted.
//!
//! Incremental polling keeps a high-water mark on `time_updated` plus an
//! in-memory id set for the tail window (rows sharing the newest
//! `time_updated`), so same-millisecond inserts are neither missed nor
//! double-counted within a process lifetime.
//!
//! The agent tag is injected by the integrator (`Poller.init(alloc, .kilo)`)
//! because `types.Agent` gains its `kilo` variant as part of engine wiring,
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
    /// $HOME. Null means the XDG fallback cannot be derived.
    home: ?[]const u8 = null,
    /// $XDG_DATA_HOME.
    xdg_data_home: ?[]const u8 = null,
    /// $KILO_DB — full path override to the database file.
    kilo_db: ?[]const u8 = null,
};

/// Resolve the default Kilo database path, or null when neither an override
/// nor a home directory is available. Allocates from `arena`; the caller (or
/// the arena) owns the result.
pub fn defaultDbPath(arena: Allocator, env: Env) !?[]const u8 {
    if (env.kilo_db) |raw| {
        const override = std.mem.trim(u8, raw, " \t");
        if (override.len > 0) return try arena.dupe(u8, override);
    }
    if (env.xdg_data_home) |raw| {
        const data_home = std.mem.trim(u8, raw, " \t");
        if (data_home.len > 0)
            return try std.fs.path.join(arena, &.{ data_home, "kilo", "kilo.db" });
    }
    const home_raw = env.home orelse return null;
    const home = std.mem.trim(u8, home_raw, " \t");
    if (home.len == 0) return null;
    return try std.fs.path.join(arena, &.{ home, ".local", "share", "kilo", "kilo.db" });
}

// Usage-bearing columns only. `m.data` is parsed in Zig for role/tokens/model
// fields exclusively; content text is never extracted or copied.
const message_sql: [:0]const u8 =
    "SELECT m.id,m.session_id,m.time_created,m.time_updated,m.data,s.model " ++
    "FROM message m LEFT JOIN session s ON s.id=m.session_id " ++
    "WHERE m.time_updated>=?1 ORDER BY m.time_updated,m.id";

pub const Poller = struct {
    allocator: Allocator,
    agent: types.Agent,
    cursor_ms: i64 = 0,
    /// Ids already ingested (or classified non-usage) whose time_updated
    /// equals cursor_ms — the ">=" tail window revisits them each poll.
    tail: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator, agent: types.Agent) Poller {
        return .{ .allocator = allocator, .agent = agent };
    }

    pub fn deinit(self: *Poller) void {
        self.clearTail();
        self.tail.deinit(self.allocator);
    }

    /// Highest message.time_updated scanned so far — persist this in the
    /// statefile between runs. After a restart, rows sharing exactly this
    /// millisecond may be re-emitted once (the id tail set is in-memory only).
    pub fn highWater(self: *const Poller) i64 {
        return self.cursor_ms;
    }

    /// Restore a persisted high-water time_updated before the first poll.
    pub fn seedHighWater(self: *Poller, time_updated_ms: i64) void {
        self.clearTail();
        self.cursor_ms = time_updated_ms;
    }

    /// Read every message row at/past the high-water mark and append one
    /// UsageEvent per new assistant row with usage. Missing/unopenable
    /// databases return cleanly with no events and no error. Event strings
    /// are owned by `event_allocator`; release with `freeEvents`.
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
        if (c.sqlite3_prepare_v2(db, message_sql.ptr, @intCast(message_sql.len), &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, self.cursor_ms);

        // Ids sharing the running-max time_updated; becomes the new tail set.
        var new_tail: std.ArrayList([]u8) = .empty;
        defer {
            for (new_tail.items) |id| self.allocator.free(id);
            new_tail.deinit(self.allocator);
        }
        var max_ms = self.cursor_ms;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = columnText(stmt, 0) orelse continue;
            const time_updated = c.sqlite3_column_int64(stmt, 3);
            if (time_updated > max_ms) {
                for (new_tail.items) |old| self.allocator.free(old);
                new_tail.clearRetainingCapacity();
                max_ms = time_updated;
            }
            if (time_updated == max_ms) {
                const owned = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(owned);
                try new_tail.append(self.allocator, owned);
            }
            if (time_updated == self.cursor_ms and self.tail.contains(id)) continue;

            const session_id = columnText(stmt, 1) orelse "";
            const time_created = c.sqlite3_column_int64(stmt, 2);
            const data = columnText(stmt, 4) orelse continue;
            const session_model_json = columnText(stmt, 5);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const role = getString(obj, "role") orelse continue;
            if (!std.mem.eql(u8, role, "assistant")) continue;
            const tokens = getObject(obj, "tokens") orelse continue;
            const input = getU64(tokens, "input");
            const output = getU64(tokens, "output");
            const reasoning = getU64(tokens, "reasoning");
            var cache_read: u64 = 0;
            var cache_write: u64 = 0;
            if (getObject(tokens, "cache")) |cache| {
                cache_read = getU64(cache, "read");
                cache_write = getU64(cache, "write");
            }
            if (input + output + reasoning + cache_read + cache_write == 0) continue;

            var model: []const u8 = "";
            if (getObject(obj, "model")) |m| {
                if (getString(m, "id")) |mid| model = mid;
            }
            if (model.len == 0) {
                if (getString(obj, "modelID")) |mid| model = mid;
            }
            var session_parsed: ?std.json.Parsed(std.json.Value) = null;
            defer if (session_parsed) |*p| p.deinit();
            if (model.len == 0) {
                if (session_model_json) |raw| {
                    session_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch null;
                    if (session_parsed) |p| if (p.value == .object) {
                        if (getString(p.value.object, "id")) |mid| model = mid;
                    };
                }
            }
            if (model.len == 0) continue;

            const event = try dupeEvent(event_allocator, .{
                .agent = self.agent,
                .timestamp_ms = time_created,
                .model = model,
                .input_tokens = input,
                .output_tokens = output +| reasoning,
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session_id,
            });
            errdefer freeEvent(event_allocator, event);
            try out.append(event_allocator, event);
        }

        // Commit the tail window: ids that share the new high-water mark.
        if (max_ms > self.cursor_ms) self.clearTail();
        while (new_tail.pop()) |id| {
            const gop = self.tail.getOrPut(self.allocator, id) catch |err| {
                self.allocator.free(id);
                return err;
            };
            if (gop.found_existing) self.allocator.free(id);
        }
        self.cursor_ms = max_ms;
    }

    fn clearTail(self: *Poller) void {
        var it = self.tail.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.tail.clearRetainingCapacity();
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

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) u64 {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0 or f != f) 0 else @intFromFloat(f),
        else => 0,
    };
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

test "defaultDbPath honors KILO_DB then XDG_DATA_HOME then home" {
    const arena = testing.allocator;
    const override = (try defaultDbPath(arena, .{ .home = "/home/u", .xdg_data_home = "/xdg", .kilo_db = "/somewhere/kilo.db" })).?;
    defer arena.free(override);
    try testing.expectEqualStrings("/somewhere/kilo.db", override);
    const xdg = (try defaultDbPath(arena, .{ .home = "/home/u", .xdg_data_home = "/xdg" })).?;
    defer arena.free(xdg);
    try testing.expectEqualStrings("/xdg/kilo/kilo.db", xdg);
    const home = (try defaultDbPath(arena, .{ .home = "/home/u" })).?;
    defer arena.free(home);
    try testing.expectEqualStrings("/home/u/.local/share/kilo/kilo.db", home);
    try testing.expectEqual(@as(?[]const u8, null), try defaultDbPath(arena, .{}));
}

test "poll maps assistant rows, resolves model via session join, skips non-usage rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "kilo.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/kilo/kilo.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    const first = events.items[0];
    try testing.expectEqual(types.Agent.opencode, first.agent);
    try testing.expectEqual(@as(i64, 1700000001000), first.timestamp_ms);
    try testing.expectEqualStrings("claude-opus-5", first.model);
    try testing.expectEqual(@as(u64, 100), first.input_tokens);
    try testing.expectEqual(@as(u64, 27), first.output_tokens); // 20 output + 7 reasoning
    try testing.expectEqual(@as(u64, 30), first.cache_read_tokens);
    try testing.expectEqual(@as(u64, 4), first.cache_creation_tokens);
    try testing.expectEqualStrings("ks_1", first.session_id);
    const second = events.items[1];
    try testing.expectEqualStrings("claude-sonnet-5", second.model); // from session.model join
    try testing.expectEqual(@as(u64, 50), second.input_tokens);
    try testing.expectEqual(@as(u64, 10), second.output_tokens);
    // High water covers user + malformed rows too.
    try testing.expectEqual(@as(i64, 1700000004000), poller.highWater());

    // Re-poll: the boundary row (kmsg_bad) is revisited but suppressed.
    freeEvents(testing.allocator, events.items);
    events.clearRetainingCapacity();
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "incremental poll picks up new rows including same-millisecond inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "kilo.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/kilo/kilo.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    freeEvents(testing.allocator, events.items);
    events.clearRetainingCapacity();

    // New row past the mark.
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE, null));
    const insert_a = "INSERT INTO message VALUES ('kmsg_3','ks_1',1700000005000,1700000005000,'{\"role\":\"assistant\",\"model\":{\"id\":\"claude-opus-5\"},\"tokens\":{\"input\":9,\"output\":2}}')";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, insert_a, null, null, null));
    _ = c.sqlite3_close(db);
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqual(@as(u64, 9), events.items[0].input_tokens);
    try testing.expectEqual(@as(i64, 1700000005000), poller.highWater());
    freeEvents(testing.allocator, events.items);
    events.clearRetainingCapacity();

    // Same-millisecond insert at the high-water boundary: emitted exactly once.
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE, null));
    const insert_b = "INSERT INTO message VALUES ('kmsg_4','ks_1',1700000005000,1700000005000,'{\"role\":\"assistant\",\"model\":{\"id\":\"claude-opus-5\"},\"tokens\":{\"input\":3,\"output\":1}}')";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, insert_b, null, null, null));
    _ = c.sqlite3_close(db);
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqual(@as(u64, 3), events.items[0].input_tokens);
    freeEvents(testing.allocator, events.items);
    events.clearRetainingCapacity();
    try poller.poll(testing.allocator, path, &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "seedHighWater resumes from persisted mark" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "kilo.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/kilo/kilo.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    poller.seedHighWater(1700000002000);
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        freeEvents(testing.allocator, events.items);
        events.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &events);
    // kmsg_1 is before the mark; kmsg_2 sits exactly on it and re-emits once
    // (documented restart behavior); user/malformed rows never emit.
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqual(@as(u64, 50), events.items[0].input_tokens);
    try testing.expectEqual(@as(i64, 1700000004000), poller.highWater());
}

test "missing database returns cleanly" {
    var poller = Poller.init(testing.allocator, .opencode);
    defer poller.deinit();
    var events: std.ArrayList(types.UsageEvent) = .empty;
    defer events.deinit(testing.allocator);
    try poller.poll(testing.allocator, "/nonexistent/kilo/kilo.db", &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
    try poller.poll(testing.allocator, "", &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}
