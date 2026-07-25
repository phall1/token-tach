//! Pi coding agent JSONL session tailer adapter (agent name "pi").
//!
//! Pi writes append-only NDJSON session ledgers at
//! `$PI_HOME/agent/sessions/<slug>/<ISO-timestamp>_<uuid>.jsonl` (default
//! `~/.pi`). The first line is a `{"type":"session"}` header carrying the
//! session `id` (the filename's trailing UUID) and `cwd` — captured per
//! file and stamped on every event for project attribution. Usage lives on
//! `{"type":"message"}` lines whose `message.role == "assistant"`:
//! `message.model` (e.g. "gpt-5.5"), the outer ISO8601 `timestamp`, and
//! `message.usage.{input, output, cacheRead, cacheWrite}` — exact
//! per-message counts, mapped 1:1 onto `types.UsageEvent`.
//!
//! Verified against real session files (~7k assistant messages):
//! `usage.reasoning` is INCLUDED in `usage.output` — on every observed
//! line `totalTokens == input + output + cacheRead + cacheWrite` with
//! reasoning never added separately, and `usage.cost.output` equals
//! `output` alone times the per-token rate. So `output_tokens =
//! usage.output` unchanged and `reasoning` is ignored. `usage.cost` is
//! also ignored — cost is always computed downstream from tokens and
//! pricing tables.
//!
//! Forked/resumed Pi sessions re-log identical message lines (same outer
//! `id`, timestamp, and usage) into new session files — observed 12-way
//! re-logs in the wild — so events dedup globally on
//! `<outer id>:<timestamp_ms>` via the generic tailer's seen-set.

const std = @import("std");
const types = @import("types.zig");
const tailsource = @import("tailsource.zig");
const claude = @import("claude.zig"); // parseTimestamp: same ISO8601 shape
const Allocator = std.mem.Allocator;

/// Cheap pre-checks: the only two line shapes worth JSON-parsing.
const assistant_marker = "\"role\":\"assistant\"";
const header_marker = "\"type\":\"session\"";

/// Build the Pi adapter. The agent tag is injected by the integrator
/// (`makeAdapter(.pi)`) because `types.Agent` gains its `pi` variant as
/// part of engine wiring, not here.
pub fn makeAdapter(agent_tag: types.Agent) tailsource.Adapter {
    return .{
        .agent = agent_tag,
        .file_suffix = ".jsonl",
        .parse = parseLine,
        .sessionIdFromPath = sessionIdFromPath,
    };
}

/// Convenience: a generic tailer preconfigured for Pi.
pub fn makeTailer(allocator: Allocator, agent_tag: types.Agent) tailsource.Tailer {
    return tailsource.Tailer.init(allocator, makeAdapter(agent_tag));
}

// ---------------------------------------------------------------------------
// Session roots
// ---------------------------------------------------------------------------

/// Resolve the Pi sessions roots. `$PI_HOME` may be a comma-separated list
/// (same convention as CODEX_HOME); each entry yields `<entry>/agent/sessions`.
/// When unset (or empty), falls back to `<home>/.pi/agent/sessions`.
/// Caller owns the returned slice and every string in it; release with
/// `freeRoots`.
pub fn defaultRoots(
    allocator: Allocator,
    env_pi_home: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (env_pi_home) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const p = try std.fs.path.join(allocator, &.{ trimmed, "agent", "sessions" });
            errdefer allocator.free(p);
            try list.append(allocator, p);
        }
    }
    if (list.items.len == 0) {
        const p = try std.fs.path.join(allocator, &.{ home, ".pi", "agent", "sessions" });
        errdefer allocator.free(p);
        try list.append(allocator, p);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

/// The session id is the filename's trailing UUID:
/// `<ISO-timestamp>_<uuid>.jsonl` -> `<uuid>`. Falls back to the whole
/// stem when there is no underscore.
pub fn sessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    if (std.mem.lastIndexOfScalar(u8, stem, '_')) |us| return stem[us + 1 ..];
    return stem;
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

/// Parse one Pi session line: the `session` header yields per-file meta
/// (cwd); an assistant `message` line yields a usage event with a global
/// dedup key. Everything else — user messages, model_change, unknown
/// types, malformed JSON — returns null.
fn parseLine(event_allocator: Allocator, line: []const u8, ctx: tailsource.FileContext) ?tailsource.Parsed {
    // Fast reject before spinning up a JSON parser: the overwhelming
    // majority of lines (user messages, tool events, ...) never match.
    const maybe_assistant = std.mem.indexOf(u8, line, assistant_marker) != null;
    if (!maybe_assistant and std.mem.indexOf(u8, line, header_marker) == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, event_allocator, line, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const line_type = getString(root, "type") orelse return null;

    if (std.mem.eql(u8, line_type, "session")) {
        const cwd = getString(root, "cwd") orelse return null;
        const owned = event_allocator.dupe(u8, cwd) catch return null;
        return .{ .meta = .{ .cwd = owned } };
    }
    if (!std.mem.eql(u8, line_type, "message")) return null;

    const message = getValue(root, "message") orelse return null;
    const role = getString(message, "role") orelse return null;
    if (!std.mem.eql(u8, role, "assistant")) return null;
    const model = getString(message, "model") orelse return null;
    const usage = getValue(message, "usage") orelse return null;
    const ts_str = getString(root, "timestamp") orelse return null;
    const ts_ms = claude.parseTimestamp(ts_str) orelse return null;

    const model_owned = event_allocator.dupe(u8, model) catch return null;
    // Global dedup identity: forked sessions re-log the same message with
    // the same outer id AND timestamp; the pair is unique enough that the
    // short hex id alone never has to be.
    const key: ?[]const u8 = if (getString(root, "id")) |id|
        std.fmt.allocPrint(event_allocator, "{s}:{d}", .{ id, ts_ms }) catch {
            event_allocator.free(model_owned);
            return null;
        }
    else
        null;

    return .{
        .event = .{
            .usage = .{
                .agent = ctx.agent,
                .timestamp_ms = ts_ms,
                .model = model_owned,
                .input_tokens = getU64(usage, "input"),
                .output_tokens = getU64(usage, "output"), // reasoning already included
                .cache_creation_tokens = getU64(usage, "cacheWrite"),
                .cache_read_tokens = getU64(usage, "cacheRead"),
            },
            .dedup_key = key,
        },
    };
}

// ---------------------------------------------------------------------------
// JSON helpers (all null-tolerant)
// ---------------------------------------------------------------------------

fn getValue(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const child = getValue(v, key) orelse return null;
    if (child != .string) return null;
    return child.string;
}

fn getU64(v: std.json.Value, key: []const u8) u64 {
    const child = getValue(v, key) orelse return 0;
    if (child != .integer) return 0;
    if (child.integer < 0) return 0;
    return @intCast(child.integer);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const session1_fixture = @embedFile("fixtures/pi/session1.jsonl");

const fixture_uuid = "019faaaa-bbbb-7ccc-8ddd-eeeeffff0001";
const fixture_cwd = "/home/dev/example-project";
const fixture_path = "agent/sessions/--home-dev-example-project--/" ++
    "2026-07-09T06-27-51-352Z_" ++ fixture_uuid ++ ".jsonl";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.pi` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .claude;

test "defaultRoots falls back to <home>/.pi/agent/sessions" {
    const roots = try defaultRoots(testing.allocator, null, "/Users/somebody");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("/Users/somebody/.pi/agent/sessions", roots[0]);

    // Whitespace-only PI_HOME behaves like unset.
    const roots2 = try defaultRoots(testing.allocator, " , ", "/Users/somebody");
    defer freeRoots(testing.allocator, roots2);
    try testing.expectEqual(@as(usize, 1), roots2.len);
    try testing.expectEqualStrings("/Users/somebody/.pi/agent/sessions", roots2[0]);
}

test "defaultRoots splits comma-separated PI_HOME" {
    const roots = try defaultRoots(testing.allocator, "/a/pi, /b/pi ,,", "/home/x");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expectEqualStrings("/a/pi/agent/sessions", roots[0]);
    try testing.expectEqualStrings("/b/pi/agent/sessions", roots[1]);
}

test "sessionIdFromPath extracts the trailing uuid" {
    try testing.expectEqualStrings(fixture_uuid, sessionIdFromPath(fixture_path));
    try testing.expectEqualStrings("stem", sessionIdFromPath("/x/stem.jsonl"));
    try testing.expectEqualStrings("b", sessionIdFromPath("a_b.jsonl"));
}

test "fixture parses through the generic tailer: events, tokens, attribution" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);

    // 6 lines: header, model_change (unknown), user message, malformed
    // garbage, and exactly 2 assistant messages -> 2 events.
    try testing.expectEqual(@as(usize, 2), out.items.len);

    const e1 = out.items[0];
    try testing.expectEqual(test_agent, e1.agent);
    try testing.expectEqual(@as(i64, 1783578505410), e1.timestamp_ms);
    try testing.expectEqualStrings("gpt-5.5", e1.model);
    try testing.expectEqual(@as(u64, 5369), e1.input_tokens);
    try testing.expectEqual(@as(u64, 97), e1.output_tokens); // includes 44 reasoning
    try testing.expectEqual(@as(u64, 0), e1.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 0), e1.cache_read_tokens);
    try testing.expectEqualStrings(fixture_uuid, e1.session_id);
    try testing.expectEqualStrings(fixture_cwd, e1.cwd);
    try testing.expectEqual(@as(u64, 5466), e1.totalTokens()); // == logged totalTokens

    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1783578507039), e2.timestamp_ms);
    try testing.expectEqualStrings("gpt-5.5", e2.model);
    try testing.expectEqual(@as(u64, 508), e2.input_tokens);
    try testing.expectEqual(@as(u64, 46), e2.output_tokens);
    try testing.expectEqual(@as(u64, 128), e2.cache_creation_tokens); // cacheWrite
    try testing.expectEqual(@as(u64, 5120), e2.cache_read_tokens); // cacheRead
    try testing.expectEqualStrings(fixture_uuid, e2.session_id);
    try testing.expectEqualStrings(fixture_cwd, e2.cwd);
}

test "a forked session re-logging the same messages dedups to zero new events" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Pi forks copy history verbatim into a new session file: same outer
    // ids + timestamps, so the seen-set drops every re-logged message.
    const fork_path = "agent/sessions/--home-dev-example-project--/" ++
        "2026-07-09T07-00-00-000Z_019fbbbb-cccc-7ddd-8eee-ffff00000002.jsonl";
    try tailer.feed(testing.allocator, fork_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "sweepIncremental over a real directory layout, with append" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const slug_dir = "agent/sessions/--home-dev-example-project--";
    const session_rel = slug_dir ++ "/2026-07-09T06-27-51-352Z_" ++ fixture_uuid ++ ".jsonl";
    try tmp.dir.createDirPath(io, slug_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/agent/sessions", .{base});
    const roots = [_][]const u8{root};

    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    var now: i64 = 1_000_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Quiet tick: nothing new.
    now += 2_000;
    try testing.expect(!try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Append a third assistant message; the hot pass catches it.
    const appended =
        "{\"type\":\"message\",\"id\":\"aaaa0004\",\"parentId\":\"aaaa0003\"," ++
        "\"timestamp\":\"2026-07-09T06:30:00.000Z\",\"message\":{\"role\":\"assistant\"," ++
        "\"content\":[{\"type\":\"text\",\"text\":\"third\"}],\"model\":\"gpt-5.5\"," ++
        "\"usage\":{\"input\":100,\"output\":10,\"cacheRead\":2000,\"cacheWrite\":0," ++
        "\"reasoning\":4,\"totalTokens\":2110,\"cost\":{\"total\":0.001}},\"timestamp\":1783578600000}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture ++ appended });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 3), out.items.len);
    const e3 = out.items[2];
    try testing.expectEqual(@as(i64, 1783578600000), e3.timestamp_ms);
    try testing.expectEqual(@as(u64, 100), e3.input_tokens);
    try testing.expectEqual(@as(u64, 10), e3.output_tokens);
    try testing.expectEqual(@as(u64, 2000), e3.cache_read_tokens);
    try testing.expectEqualStrings(fixture_cwd, e3.cwd);
    try testing.expectEqualStrings(fixture_uuid, e3.session_id);
}
