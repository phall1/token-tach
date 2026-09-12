//! Bounded seven-day read model of the durable archive. Owned values only:
//! a reader can close before a snapshot is handed to the UI.
const std = @import("std");
const history = @import("history.zig");
const types = @import("types.zig");
const ledger = @import("ledger.zig");

pub const day_count = 7;
pub const model_count = 4;

pub const Name = struct {
    bytes: [128]u8 = @splat(0),
    len: usize = 0,

    pub fn init(value: []const u8) Name {
        var result: Name = .{};
        var n = @min(value.len, result.bytes.len);
        if (n < value.len) {
            n -= 3;
            while (n > 0 and value[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(result.bytes[n..][0..3], "...");
            result.len = n + 3;
        } else result.len = n;
        @memcpy(result.bytes[0..n], value[0..n]);
        return result;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ModelRow = struct {
    name: Name = .{},
    tokens: u64 = 0,
};

pub const Source = struct {
    days: [day_count]ledger.Totals = @splat(.{}),
    models: [model_count]ModelRow = @splat(.{}),
    models_len: usize = 0,
    total: ledger.Totals = .{},
};

pub const Snapshot = struct {
    available: bool = false,
    updated_ms: i64 = 0,
    end_day: i64 = 0,
    tz_offset_min: i32 = 0,
    sources: std.EnumArray(types.Agent, Source) = .initFill(.{}),
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, now_ms: i64) !Snapshot {
    var reader = try history.Reader.open(allocator, io, dir);
    defer reader.deinit();
    const offset = reader.dayTzOffset() orelse return error.HistoryUnavailable;
    const end = history.dayBucket(now_ms, offset);
    const filter: history.Filter = .{ .from_bucket = end -| (day_count - 1), .to_bucket = end };
    var result: Snapshot = .{
        .available = true,
        .updated_ms = now_ms,
        .end_day = end,
        .tz_offset_min = offset,
    };
    const days = try reader.query(allocator, .day, filter, .{ .bucket = true, .agent = true });
    defer allocator.free(days);
    for (days) |row| addDay(&result, row);
    const models = try reader.query(allocator, .day, filter, .{ .agent = true, .model = true });
    defer allocator.free(models);
    std.mem.sort(history.Row, models, {}, mostTokensFirst);
    for (models) |row| addModel(&result, &reader, row);
    return result;
}

fn addDay(result: *Snapshot, row: history.Row) void {
    const agent = types.Agent.fromStorageId(row.agent) orelse return;
    const index = @as(i64, row.bucket) - (result.end_day - (day_count - 1));
    if (index < 0 or index >= day_count) return;
    const source = result.sources.getPtr(agent);
    source.days[@intCast(index)].merge(row.totals);
    source.total.merge(row.totals);
}

fn mostTokensFirst(_: void, a: history.Row, b: history.Row) bool {
    const at = a.totals.totalTokens();
    const bt = b.totals.totalTokens();
    if (at != bt) return at > bt;
    return a.model_id < b.model_id;
}

fn addModel(result: *Snapshot, reader: *const history.Reader, row: history.Row) void {
    const agent = types.Agent.fromStorageId(row.agent) orelse return;
    const source = result.sources.getPtr(agent);
    if (source.models_len == model_count) return;
    var buffer: [32]u8 = undefined;
    const name = if (row.model_id == 0) "Unknown model" else reader.name(row.model_id, &buffer);
    source.models[source.models_len] = .{ .name = Name.init(name), .tokens = row.totals.totalTokens() };
    source.models_len += 1;
}

test "summary reopens durable history with matching daily and model scopes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const now: i64 = 20_000 * 86_400_000;
    var writer = try history.Writer.open(testing.allocator, testing.io, dir, .{
        .now_ms = now,
        .tz_offset_min = 330,
        .compact_on_open = false,
    });
    writer.record(.{ .agent = .opencode, .model = "gpt-example", .timestamp_ms = now, .input_tokens = 100, .cache_read_tokens = 200 }, .{ .now_ms = now, .cost_usd = 1 });
    writer.record(.{ .agent = .claude, .model = "claude-example", .timestamp_ms = now - 86_400_000, .output_tokens = 50 }, .{ .now_ms = now });
    writer.record(.{ .agent = .opencode, .model = "old", .timestamp_ms = now - 8 * 86_400_000, .output_tokens = 9999 }, .{ .now_ms = now });
    writer.deinit();
    const result = try load(testing.allocator, testing.io, dir, now);
    const source = result.sources.get(.opencode);
    try testing.expect(result.available);
    try testing.expectEqual(@as(i32, 330), result.tz_offset_min);
    try testing.expectEqual(@as(u64, 300), source.total.totalTokens());
    try testing.expectEqual(@as(u64, 300), source.days[6].totalTokens());
    try testing.expectEqual(@as(u64, 300), source.models[0].tokens);
    try testing.expectEqualStrings("gpt-example", source.models[0].name.text());
    try testing.expectEqual(@as(u64, 50), result.sources.get(.claude).days[5].totalTokens());
}

test "missing archive is unavailable rather than zero usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try std.testing.expectError(error.HistoryUnavailable, load(std.testing.allocator, std.testing.io, dir, 0));
}
