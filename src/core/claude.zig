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
//! Ownership: every string inside an emitted `types.UsageEvent` is duped
//! with the allocator the `Tailer` was initialized with (or, for the free
//! function `parseLine`, the allocator passed in) and ownership transfers
//! to the sink consumer — the tailer never frees them. Arena allocators make
//! this trivial; with a general-purpose allocator, free each event's strings
//! via `freeUsageEventStrings` (which `ListSink.deinit` does for you when it
//! shares the tailer's allocator).

const std = @import("std");
const types = @import("types.zig");

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
/// Initialize it with the SAME allocator as the Tailer feeding it: `deinit`
/// frees the strings inside each collected event with that allocator.
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

/// Parse an ISO8601 timestamp of the shape Claude Code logs
/// ("2026-07-08T02:57:59.430Z") into unix milliseconds. Fractional seconds
/// are optional and of any length (truncated to ms); the zone must be 'Z' or
/// a numeric offset (+HH:MM / +HHMM). Returns null on anything malformed.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    const year = fixedDigits(s[0..4]) orelse return null;
    if (s[4] != '-') return null;
    const month = fixedDigits(s[5..7]) orelse return null;
    if (s[7] != '-') return null;
    const day = fixedDigits(s[8..10]) orelse return null;
    if (s[10] != 'T') return null;
    const hour = fixedDigits(s[11..13]) orelse return null;
    if (s[13] != ':') return null;
    const minute = fixedDigits(s[14..16]) orelse return null;
    if (s[16] != ':') return null;
    const second = fixedDigits(s[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') idx += 1;
        if (idx == frac_start) return null;
        var scale: i64 = 100;
        var i = frac_start;
        while (i < idx and i < frac_start + 3) : (i += 1) {
            millis += scale * (s[i] - '0');
            scale = @divTrunc(scale, 10);
        }
    }

    if (idx >= s.len) return null;
    var tz_offset_min: i64 = 0;
    switch (s[idx]) {
        'Z' => if (idx + 1 != s.len) return null,
        '+', '-' => {
            const sign: i64 = if (s[idx] == '-') -1 else 1;
            const rest = s[idx + 1 ..];
            var off_hour: i64 = 0;
            var off_min: i64 = 0;
            if (rest.len == 5 and rest[2] == ':') {
                off_hour = fixedDigits(rest[0..2]) orelse return null;
                off_min = fixedDigits(rest[3..5]) orelse return null;
            } else if (rest.len == 4) {
                off_hour = fixedDigits(rest[0..2]) orelse return null;
                off_min = fixedDigits(rest[2..4]) orelse return null;
            } else return null;
            if (off_hour > 23 or off_min > 59) return null;
            tz_offset_min = sign * (off_hour * 60 + off_min);
        },
        else => return null,
    }

    const days = daysFromCivil(year, month, day);
    const secs = ((days * 24 + hour) * 60 + minute - tz_offset_min) * 60 + second;
    return secs * 1000 + millis;
}

/// Strict fixed-width decimal (rejects signs, spaces, underscores).
fn fixedDigits(s: []const u8) ?i64 {
    var value: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(i64, 29) else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(month + 9, 12); // Mar=0 ... Feb=11
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ---------------------------------------------------------------------------
// Tailer
// ---------------------------------------------------------------------------

/// Incremental NDJSON tailer with per-file byte offsets, per-file partial-line
/// carry buffers, and a global message dedup set.
///
/// Lifetime: init with a long-lived allocator; internal state (offsets map,
/// carry buffers, dedup keys) is freed by `deinit`. Strings inside emitted
/// events are allocated with the same allocator, but ownership passes to the
/// sink consumer — `deinit` does NOT free them.
pub const Tailer = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(FileState) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    const FileState = struct {
        offset: u64 = 0,
        carry: std.ArrayList(u8) = .empty,
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
        self.* = undefined;
    }

    /// Feed a raw byte chunk belonging to `file_key` (any stable identifier;
    /// scanFile uses the path). Splits on '\n', parses complete lines, and
    /// buffers a trailing partial line until the next feed for the same key.
    /// Deduplicated events are emitted to `sink` in file order.
    pub fn feed(self: *Tailer, file_key: []const u8, chunk: []const u8, sink: EventSink) !void {
        const state = try self.fileState(file_key);
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const segment = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (state.carry.items.len != 0) {
                try state.carry.appendSlice(self.allocator, segment);
                try self.processLine(state.carry.items, sink);
                if (state.carry.capacity > carry_shrink_threshold) {
                    state.carry.clearAndFree(self.allocator);
                } else {
                    state.carry.clearRetainingCapacity();
                }
            } else {
                try self.processLine(segment, sink);
            }
        }
        if (rest.len != 0) try state.carry.appendSlice(self.allocator, rest);
    }

    /// Open `path`, read everything past the stored byte offset, feed it, and
    /// advance the offset. A shrunken file (rotation/truncation) resets the
    /// offset and carry. A vanished file is silently skipped. `scratch` is
    /// only used for the transient read buffer (arena-friendly).
    pub fn scanFile(
        self: *Tailer,
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
            try self.feed(path, buf[0..n], sink);
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
    pub fn sweep(
        self: *Tailer,
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
                self.scanFile(scratch, io, path, sink) catch continue;
            }
        }
    }

    fn fileState(self: *Tailer, file_key: []const u8) !*FileState {
        if (self.files.getPtr(file_key)) |state| return state;
        const owned = try self.allocator.dupe(u8, file_key);
        errdefer self.allocator.free(owned);
        try self.files.put(self.allocator, owned, .{});
        return self.files.getPtr(owned).?;
    }

    fn processLine(self: *Tailer, line: []const u8, sink: EventSink) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const ex = extractLine(self.allocator, trimmed) orelse return;

        const key = blk: {
            if (ex.request_id) |rid| {
                break :blk std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ ex.message_id, rid }) catch |err| {
                    ex.deinit(self.allocator);
                    return err;
                };
            }
            break :blk self.allocator.dupe(u8, ex.message_id) catch |err| {
                ex.deinit(self.allocator);
                return err;
            };
        };
        self.allocator.free(ex.message_id);
        if (ex.request_id) |rid| self.allocator.free(rid);

        const gop = self.seen.getOrPut(self.allocator, key) catch |err| {
            self.allocator.free(key);
            freeUsageEventStrings(self.allocator, ex.event);
            return err;
        };
        if (gop.found_existing) {
            self.allocator.free(key);
            freeUsageEventStrings(self.allocator, ex.event);
            return;
        }
        // The dedup key is recorded before emitting: if the sink errors the
        // event is dropped rather than risked double-counted on retry.
        sink.emit(ex.event) catch |err| {
            freeUsageEventStrings(self.allocator, ex.event);
            return err;
        };
    }
};

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

test "parseTimestamp handles epoch, fractions, offsets, and leap days" {
    try testing.expectEqual(@as(?i64, 0), parseTimestamp("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1), parseTimestamp("1970-01-01T00:00:00.001Z"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.430Z"));
    // Short and long fractions normalize to milliseconds.
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.43Z"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.430999Z"));
    try testing.expectEqual(@as(?i64, 1783479479000), parseTimestamp("2026-07-08T02:57:59Z"));
    // Leap day and end-of-millennium.
    try testing.expectEqual(@as(?i64, 951825600000), parseTimestamp("2000-02-29T12:00:00Z"));
    try testing.expectEqual(@as(?i64, 946684799999), parseTimestamp("1999-12-31T23:59:59.999Z"));
    // Numeric zone offsets, both separators.
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T04:57:59.430+02:00"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T00:57:59.430-0200"));
}

test "parseTimestamp rejects malformed input" {
    const bad = [_][]const u8{
        "",
        "2026-07-08",
        "2026-07-08T02:57:59.430", // no zone designator
        "2026-07-08T02:57:59.Z", // dot with no digits
        "2026-13-01T00:00:00Z", // month out of range
        "2026-02-30T00:00:00Z", // day out of range
        "2026-07-08T24:00:00Z", // hour out of range
        "2026-07-08 02:57:59Z", // space separator
        "2026-07-08T02:57:59+2:00", // malformed offset
        "2026-07-08T02:57:59Zjunk", // trailing garbage
        "not a timestamp, not even close",
    };
    for (bad) |s| {
        try testing.expectEqual(@as(?i64, null), parseTimestamp(s));
    }
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
