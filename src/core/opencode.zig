//! OpenCode usage ingestion through one direct, read-only SQLite connection.
//!
//! Queries project only stable identifiers, token counters, model/timestamps,
//! and the joined session directory. Prompt/content/tool/auth columns and JSON
//! paths are never selected. New `session_message` assistant rows take
//! precedence when present; otherwise installed V1 `message` JSON rows are
//! used, so one database cannot be counted through both schema channels.

const std = @import("std");
const types = @import("types.zig");
const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
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

const Allocator = std.mem.Allocator;

pub const Change = struct {
    previous: ?types.UsageEvent = null,
    current: types.UsageEvent,
};

pub const Stored = struct {
    updated_ms: i64,
    event: types.UsageEvent,
};

pub const Poller = struct {
    allocator: Allocator,
    seen: std.StringHashMapUnmanaged(Stored) = .empty,
    cursor_updated_ms: i64 = 0,

    pub fn init(allocator: Allocator) Poller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Poller) void {
        var it = self.seen.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeEvent(self.allocator, entry.value_ptr.event);
        }
        self.seen.deinit(self.allocator);
    }

    pub fn restore(self: *Poller, id: []const u8, updated_ms: i64, event: types.UsageEvent) !void {
        try self.putStored(id, updated_ms, event);
        self.cursor_updated_ms = @max(self.cursor_updated_ms, updated_ms);
    }

    pub fn poll(self: *Poller, event_allocator: Allocator, path: []const u8, out: *std.ArrayList(Change)) !void {
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

        const use_next = tableHasAssistant(db);
        const sql = if (use_next) next_sql else v1_sql;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, self.cursor_updated_ms);

        var max_updated = self.cursor_updated_ms;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = columnText(stmt, 0) orelse continue;
            const updated_ms = c.sqlite3_column_int64(stmt, 1);
            const model = columnText(stmt, 2) orelse continue;
            const timestamp_ms = c.sqlite3_column_int64(stmt, 3);
            const input = nonnegativeColumn(stmt, 4) orelse continue;
            const output = nonnegativeColumn(stmt, 5) orelse continue;
            const reasoning = nonnegativeColumn(stmt, 6) orelse continue;
            const cache_read = nonnegativeColumn(stmt, 7) orelse continue;
            const cache_write = nonnegativeColumn(stmt, 8) orelse continue;
            const session_id = columnText(stmt, 9) orelse "";
            const directory = columnText(stmt, 10) orelse "";
            max_updated = @max(max_updated, updated_ms);

            if (self.seen.get(id)) |old| {
                if (old.updated_ms == updated_ms and eventEqual(old.event, .{
                    .agent = .opencode,
                    .timestamp_ms = timestamp_ms,
                    .model = model,
                    .input_tokens = input,
                    .output_tokens = output +| reasoning,
                    .cache_read_tokens = cache_read,
                    .cache_creation_tokens = cache_write,
                    .session_id = session_id,
                    .cwd = directory,
                })) continue;
            }

            const current = try dupeEvent(event_allocator, .{
                .agent = .opencode,
                .timestamp_ms = timestamp_ms,
                .model = model,
                .input_tokens = input,
                .output_tokens = output +| reasoning,
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session_id,
                .cwd = directory,
            });
            errdefer freeEvent(event_allocator, current);
            const previous = if (self.seen.get(id)) |old| try dupeEvent(event_allocator, old.event) else null;
            errdefer if (previous) |ev| freeEvent(event_allocator, ev);
            try out.append(event_allocator, .{ .previous = previous, .current = current });
            try self.putStored(id, updated_ms, current);
        }
        // Query with >= so rows sharing the cursor timestamp are revisited and
        // suppressed by the persisted identity+snapshot map.
        self.cursor_updated_ms = max_updated;
    }

    fn putStored(self: *Poller, id: []const u8, updated_ms: i64, event: types.UsageEvent) !void {
        const owned_event = try dupeEvent(self.allocator, event);
        errdefer freeEvent(self.allocator, owned_event);
        if (self.seen.getPtr(id)) |slot| {
            freeEvent(self.allocator, slot.event);
            slot.* = .{ .updated_ms = updated_ms, .event = owned_event };
            return;
        }
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        try self.seen.put(self.allocator, owned_id, .{ .updated_ms = updated_ms, .event = owned_event });
    }
};

pub fn resolvePath(allocator: Allocator, explicit: []const u8, env_db: ?[]const u8, env_xdg_data_home: ?[]const u8, home: []const u8) ![]u8 {
    if (std.mem.trim(u8, explicit, " \t").len > 0)
        return resolveCandidate(allocator, std.mem.trim(u8, explicit, " \t"), env_xdg_data_home, home);
    if (env_db) |raw| if (std.mem.trim(u8, raw, " \t").len > 0)
        return resolveCandidate(allocator, std.mem.trim(u8, raw, " \t"), env_xdg_data_home, home);
    const data_home = try dataHome(allocator, env_xdg_data_home, home);
    defer allocator.free(data_home);
    return std.fs.path.join(allocator, &.{ data_home, "opencode", "opencode.db" });
}

fn resolveCandidate(allocator: Allocator, candidate: []const u8, env_xdg_data_home: ?[]const u8, home: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(candidate)) return allocator.dupe(u8, candidate);
    if (std.mem.startsWith(u8, candidate, "~/")) return std.fs.path.join(allocator, &.{ home, candidate[2..] });
    const data_home = try dataHome(allocator, env_xdg_data_home, home);
    defer allocator.free(data_home);
    return std.fs.path.join(allocator, &.{ data_home, "opencode", candidate });
}

fn dataHome(allocator: Allocator, env_xdg_data_home: ?[]const u8, home: []const u8) ![]u8 {
    if (env_xdg_data_home) |raw| if (std.mem.trim(u8, raw, " \t").len > 0)
        return allocator.dupe(u8, std.mem.trim(u8, raw, " \t"));
    return std.fs.path.join(allocator, &.{ home, ".local", "share" });
}

pub fn freeChanges(allocator: Allocator, changes: []const Change) void {
    for (changes) |change| {
        if (change.previous) |ev| freeEvent(allocator, ev);
        freeEvent(allocator, change.current);
    }
}

fn tableHasAssistant(db: ?*c.sqlite3) bool {
    const sql: [:0]const u8 = "SELECT 1 FROM session_message WHERE type='assistant' LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

// These projections are intentionally explicit. Do not replace them with
// `SELECT data` or add prompt/content/tool/auth JSON paths.
const v1_sql: [:0]const u8 =
    "SELECT m.id,m.time_updated,json_extract(m.data,'$.modelID')," ++
    "coalesce(json_extract(m.data,'$.time.completed'),json_extract(m.data,'$.time.created'),m.time_created)," ++
    "coalesce(json_extract(m.data,'$.tokens.input'),0),coalesce(json_extract(m.data,'$.tokens.output'),0)," ++
    "coalesce(json_extract(m.data,'$.tokens.reasoning'),0),coalesce(json_extract(m.data,'$.tokens.cache.read'),0)," ++
    "coalesce(json_extract(m.data,'$.tokens.cache.write'),0),m.session_id,s.directory " ++
    "FROM message m JOIN session s ON s.id=m.session_id " ++
    "WHERE CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.role') ELSE NULL END='assistant' " ++
    "AND m.time_updated>=?1 ORDER BY m.time_updated,m.id";

const next_sql: [:0]const u8 =
    "SELECT m.id,m.time_updated,coalesce(json_extract(m.data,'$.model.id'),json_extract(m.data,'$.modelID'))," ++
    "coalesce(json_extract(m.data,'$.time.completed'),json_extract(m.data,'$.time.created'),m.time_created)," ++
    "coalesce(json_extract(m.data,'$.tokens.input'),0),coalesce(json_extract(m.data,'$.tokens.output'),0)," ++
    "coalesce(json_extract(m.data,'$.tokens.reasoning'),0),coalesce(json_extract(m.data,'$.tokens.cache.read'),0)," ++
    "coalesce(json_extract(m.data,'$.tokens.cache.write'),0),m.session_id,s.directory " ++
    "FROM session_message m JOIN session s ON s.id=m.session_id " ++
    "WHERE m.type='assistant' AND m.time_updated>=?1 ORDER BY m.time_updated,m.id";

fn columnText(stmt: ?*c.sqlite3_stmt, column: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return null;
    const len = c.sqlite3_column_bytes(stmt, column);
    return ptr[0..@intCast(len)];
}

fn nonnegativeColumn(stmt: ?*c.sqlite3_stmt, column: c_int) ?u64 {
    if (c.sqlite3_column_type(stmt, column) != c.SQLITE_INTEGER) return null;
    const value = c.sqlite3_column_int64(stmt, column);
    return if (value < 0) null else @intCast(value);
}

fn dupeEvent(allocator: Allocator, ev: types.UsageEvent) !types.UsageEvent {
    const model = try allocator.dupe(u8, ev.model);
    errdefer allocator.free(model);
    const session_id = try allocator.dupe(u8, ev.session_id);
    errdefer allocator.free(session_id);
    const cwd = try allocator.dupe(u8, ev.cwd);
    return .{ .agent = .opencode, .timestamp_ms = ev.timestamp_ms, .model = model, .input_tokens = ev.input_tokens, .output_tokens = ev.output_tokens, .cache_creation_tokens = ev.cache_creation_tokens, .cache_read_tokens = ev.cache_read_tokens, .session_id = session_id, .cwd = cwd };
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

const testing = std.testing;

test "resolvePath precedence chooses exactly one database" {
    const a = try resolvePath(testing.allocator, "/explicit.db", "/env.db", "/xdg", "/home/u");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/explicit.db", a);
    const b = try resolvePath(testing.allocator, "", "/env.db", "/xdg", "/home/u");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/env.db", b);
    const d = try resolvePath(testing.allocator, "", null, "/xdg", "/home/u");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/xdg/opencode/opencode.db", d);
    const relative = try resolvePath(testing.allocator, "", "opencode-next.db", "/xdg", "/home/u");
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/xdg/opencode/opencode-next.db", relative);
}

test "queries never select sensitive payload fields" {
    inline for (.{ v1_sql, next_sql }) |sql| {
        try testing.expect(std.mem.indexOf(u8, sql, "SELECT m.data") == null);
        inline for (.{ "prompt", "content", "tool", "auth" }) |forbidden|
            try testing.expect(std.mem.indexOf(u8, sql, forbidden) == null);
    }
}

test "V1 poll maps tokens, skips malformed rows, deduplicates, and replaces updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "opencode.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    const fixture = @embedFile("fixtures/opencode/v1.sql");
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, fixture.ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    const ev = changes.items[0].current;
    try testing.expectEqual(types.Agent.opencode, ev.agent);
    try testing.expectEqual(@as(i64, 1900), ev.timestamp_ms);
    try testing.expectEqual(@as(u64, 10), ev.input_tokens);
    try testing.expectEqual(@as(u64, 23), ev.output_tokens);
    try testing.expectEqual(@as(u64, 40), ev.cache_read_tokens);
    try testing.expectEqual(@as(u64, 5), ev.cache_creation_tokens);
    try testing.expectEqualStrings("gpt-5.4", ev.model);
    try testing.expectEqualStrings("/work/project", ev.cwd);

    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();
    try poller.poll(testing.allocator, path, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);

    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE, null));
    const update = "UPDATE message SET time_updated=3000,data='{\"role\":\"assistant\",\"modelID\":\"gpt-5.4\",\"time\":{\"created\":1100,\"completed\":2900},\"tokens\":{\"input\":12,\"output\":25,\"reasoning\":4,\"cache\":{\"read\":42,\"write\":6}}}' WHERE id='msg_valid'";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, update, null, null, null));
    _ = c.sqlite3_close(db);
    try poller.poll(testing.allocator, path, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expect(changes.items[0].previous != null);
    try testing.expectEqual(@as(u64, 29), changes.items[0].current.output_tokens);
    try testing.expectEqual(@as(i64, 2900), changes.items[0].current.timestamp_ms);
}

test "next session_message assistants take precedence over V1 rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(testing.io, &path_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "opencode.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/opencode/next.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    try poller.poll(testing.allocator, path, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    const ev = changes.items[0].current;
    try testing.expectEqualStrings("claude-sonnet-5", ev.model);
    try testing.expectEqual(@as(i64, 3900), ev.timestamp_ms);
    try testing.expectEqual(@as(u64, 7), ev.input_tokens);
    try testing.expectEqual(@as(u64, 13), ev.output_tokens);
    try testing.expectEqual(@as(u64, 13), ev.cache_read_tokens);
    try testing.expectEqual(@as(u64, 17), ev.cache_creation_tokens);
    try testing.expectEqualStrings("/work/next", ev.cwd);
}
