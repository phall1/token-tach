//! Qwen Code JSONL session tailer adapter (QwenLM/qwen-code).
//!
//! Qwen Code forked from Gemini CLI but its session format DIVERGED:
//! append-only JSONL where EVERY line is a self-contained record
//! `{uuid, sessionId, timestamp (ISO8601), type, cwd, model?,
//! usageMetadata?}` — no header line; session id and cwd ride on each
//! record, so events are attributed per record (a single file can even
//! span cwd changes). Sessions live at
//! `<root>/projects/<slug>/chats/<sessionId>.jsonl` plus the legacy
//! `<root>/tmp/<hash>/chats/` layout; `defaultRoots` yields both
//! `<root>/projects` and `<root>/tmp`, with the root resolved from
//! `$QWEN_RUNTIME_DIR` orelse `$QWEN_HOME` orelse `~/.qwen`.
//!
//! Usage rides on `type == "assistant"` records with a `usageMetadata`
//! object — the API's GenerateContentResponseUsageMetadata verbatim:
//! `{promptTokenCount, candidatesTokenCount, cachedContentTokenCount,
//! thoughtsTokenCount, toolUsePromptTokenCount}`.
//!
//! Token mapping (source-verified; MUST stay consistent with
//! geminisrc.zig, which reads the same upstream metadata shape):
//! - `toolUsePromptTokenCount` is a SUBSET breakdown of
//!   `promptTokenCount`, NOT additive: the API defines totalTokenCount
//!   as "prompt + thoughts + response candidates" with tool-use tokens
//!   absent from the formula, and gemini-cli's own uiTelemetry never
//!   adds tool to prompt. It is therefore NOT added.
//! - `cachedContentTokenCount` is a SUBSET of `promptTokenCount`: the
//!   API docs state promptTokenCount "includes the number of tokens in
//!   the cached content", and uiTelemetry computes `input = max(0,
//!   prompt - cached)`. So `input_tokens = promptTokenCount -|
//!   cachedContentTokenCount` and `cache_read_tokens =
//!   cachedContentTokenCount` (no double count).
//! - `thoughtsTokenCount` is ADDITIVE billed output, not included in
//!   `candidatesTokenCount` — the total formula enumerates it
//!   separately. So `output_tokens = candidatesTokenCount +
//!   thoughtsTokenCount`.
//! - No cache-write accounting exists here: `cache_creation = 0`.
//! With this mapping `UsageEvent.totalTokens()` reproduces the logged
//! `totalTokenCount` exactly (same convention as pisrc.zig).
//!
//! Records are dedup-keyed on their `uuid` — globally unique per
//! record — so replays (truncation resets, resumed-session re-logs)
//! can never double count.

const std = @import("std");
const types = @import("types.zig");
const tailsource = @import("tailsource.zig");
const claude = @import("claude.zig"); // parseTimestamp: same ISO8601 shape
const Allocator = std.mem.Allocator;

/// Cheap pre-check: only assistant records carrying usage are worth
/// JSON-parsing, and only they contain this key.
const usage_marker = "\"usageMetadata\"";

/// Build the Qwen Code adapter. The agent tag is injected by the
/// integrator (`makeAdapter(.qwen)`) because `types.Agent` gains its
/// `qwen` variant as part of engine wiring, not here.
pub fn makeAdapter(agent_tag: types.Agent) tailsource.Adapter {
    return .{
        .agent = agent_tag,
        .file_suffix = ".jsonl",
        .parse = parseLine,
        .sessionIdFromPath = sessionIdFromPath,
    };
}

/// Convenience: a generic tailer preconfigured for Qwen Code.
pub fn makeTailer(allocator: Allocator, agent_tag: types.Agent) tailsource.Tailer {
    return tailsource.Tailer.init(allocator, makeAdapter(agent_tag));
}

// ---------------------------------------------------------------------------
// Session roots
// ---------------------------------------------------------------------------

/// Resolve the Qwen Code sessions roots. The base directory is
/// `$QWEN_RUNTIME_DIR` orelse `$QWEN_HOME` orelse `<home>/.qwen`
/// (whitespace-only env values behave like unset); the result is both
/// `<base>/projects` (current `projects/<slug>/chats/` layout) and
/// `<base>/tmp` (legacy `tmp/<hash>/chats/` layout). Caller owns the
/// returned slice and every string in it; release with `freeRoots`.
pub fn defaultRoots(
    allocator: Allocator,
    env_qwen_runtime_dir: ?[]const u8,
    env_qwen_home: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (nonEmpty(env_qwen_runtime_dir) orelse nonEmpty(env_qwen_home)) |base| {
        try appendRootPair(allocator, &list, &.{base});
    } else {
        try appendRootPair(allocator, &list, &.{ home, ".qwen" });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn appendRootPair(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    base_parts: []const []const u8,
) !void {
    for ([_][]const u8{ "projects", "tmp" }) |leaf| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        try parts.appendSlice(allocator, base_parts);
        try parts.append(allocator, leaf);
        const p = try std.fs.path.join(allocator, parts.items);
        errdefer allocator.free(p);
        try list.append(allocator, p);
    }
}

/// Fallback session id from the file path (each record's own `sessionId`
/// field wins): sessions are stored as `chats/<sessionId>.jsonl`, so the
/// id is simply the filename stem.
pub fn sessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) return base[0 .. base.len - ".jsonl".len];
    return base;
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

/// Parse one Qwen Code session line: a `type == "assistant"` record WITH
/// a `usageMetadata` object yields a usage event carrying its own
/// session id and cwd (per-record attribution), dedup-keyed on `uuid`.
/// Everything else — user records, tool_result records, assistant
/// records without usage, malformed JSON — returns null.
fn parseLine(event_allocator: Allocator, line: []const u8, ctx: tailsource.FileContext) ?tailsource.Parsed {
    // Fast reject before spinning up a JSON parser: only usage-bearing
    // assistant records contain "usageMetadata".
    if (std.mem.indexOf(u8, line, usage_marker) == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, event_allocator, line, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    const rec_type = getString(root, "type") orelse return null;
    if (!std.mem.eql(u8, rec_type, "assistant")) return null;
    const usage = getValue(root, "usageMetadata") orelse return null;
    if (usage != .object) return null;
    const ts_str = getString(root, "timestamp") orelse return null;
    const ts_ms = claude.parseTimestamp(ts_str) orelse return null;

    const prompt = getU64(usage, "promptTokenCount");
    const cached = getU64(usage, "cachedContentTokenCount");

    const model_owned = event_allocator.dupe(u8, getString(root, "model") orelse "") catch return null;
    // Per-record attribution: session id and cwd come off the record
    // itself, not the file context. Empty stays "" (never allocated) so
    // the tailer's path/meta fallback can still apply.
    const session_owned: []const u8 = blk: {
        const sid = getString(root, "sessionId") orelse "";
        if (sid.len == 0) break :blk "";
        break :blk event_allocator.dupe(u8, sid) catch {
            event_allocator.free(model_owned);
            return null;
        };
    };
    const cwd_owned: []const u8 = blk: {
        const cwd = getString(root, "cwd") orelse "";
        if (cwd.len == 0) break :blk "";
        break :blk event_allocator.dupe(u8, cwd) catch {
            event_allocator.free(model_owned);
            event_allocator.free(session_owned);
            return null;
        };
    };
    const key: ?[]const u8 = if (getString(root, "uuid")) |uuid|
        event_allocator.dupe(u8, uuid) catch {
            event_allocator.free(model_owned);
            event_allocator.free(session_owned);
            event_allocator.free(cwd_owned);
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
                // cached is a subset of prompt; toolUsePromptTokenCount is a
                // subset of prompt and NOT added; thoughts are additive
                // output. See module doc.
                .input_tokens = prompt -| cached,
                .output_tokens = getU64(usage, "candidatesTokenCount") + getU64(usage, "thoughtsTokenCount"),
                .cache_creation_tokens = 0,
                .cache_read_tokens = cached,
                .session_id = session_owned,
                .cwd = cwd_owned,
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

const session1_fixture = @embedFile("fixtures/qwen/session1.jsonl");

const fixture_session_id = "qsess-7777-8888";
const fixture_path = "projects/-home-dev-qwen-proj/chats/" ++ fixture_session_id ++ ".jsonl";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.qwen` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .claude;

test "defaultRoots resolves runtime dir, home dir, and ~/.qwen in order" {
    const roots = try defaultRoots(testing.allocator, null, null, "/Users/somebody");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expectEqualStrings("/Users/somebody/.qwen/projects", roots[0]);
    try testing.expectEqualStrings("/Users/somebody/.qwen/tmp", roots[1]);

    const roots2 = try defaultRoots(testing.allocator, "/run/qwen", "/opt/qwen", "/Users/somebody");
    defer freeRoots(testing.allocator, roots2);
    try testing.expectEqual(@as(usize, 2), roots2.len);
    try testing.expectEqualStrings("/run/qwen/projects", roots2[0]);
    try testing.expectEqualStrings("/run/qwen/tmp", roots2[1]);

    // Whitespace-only QWEN_RUNTIME_DIR falls through to QWEN_HOME.
    const roots3 = try defaultRoots(testing.allocator, " ", "/opt/qwen", "/Users/somebody");
    defer freeRoots(testing.allocator, roots3);
    try testing.expectEqualStrings("/opt/qwen/projects", roots3[0]);
    try testing.expectEqualStrings("/opt/qwen/tmp", roots3[1]);
}

test "sessionIdFromPath is the filename stem" {
    try testing.expectEqualStrings(fixture_session_id, sessionIdFromPath(fixture_path));
    try testing.expectEqualStrings("abc", sessionIdFromPath("tmp/hash/chats/abc.jsonl"));
}

test "fixture parses through the generic tailer: count, mapping, per-record cwd" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);

    // 5 lines: user record, assistant WITH usage, tool_result, a second
    // assistant WITH usage (different cwd), malformed garbage -> 2 events.
    try testing.expectEqual(@as(usize, 2), out.items.len);

    const e1 = out.items[0];
    try testing.expectEqual(test_agent, e1.agent);
    try testing.expectEqual(@as(i64, 1783578505410), e1.timestamp_ms);
    try testing.expectEqualStrings("qwen3-coder-plus", e1.model);
    try testing.expectEqual(@as(u64, 4345), e1.input_tokens); // 5369 prompt - 1024 cached
    try testing.expectEqual(@as(u64, 141), e1.output_tokens); // 97 candidates + 44 thoughts
    try testing.expectEqual(@as(u64, 0), e1.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 1024), e1.cache_read_tokens);
    // toolUsePromptTokenCount=128 is a subset of prompt and must NOT be
    // added anywhere: totalTokens() reproduces logged totalTokenCount.
    try testing.expectEqual(@as(u64, 5510), e1.totalTokens());
    try testing.expectEqualStrings(fixture_session_id, e1.session_id);
    try testing.expectEqualStrings("/home/dev/qwen-proj", e1.cwd);

    // The second record carries a DIFFERENT cwd — attribution is
    // per record, not per file.
    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1783578507039), e2.timestamp_ms);
    try testing.expectEqual(@as(u64, 800), e2.input_tokens);
    try testing.expectEqual(@as(u64, 60), e2.output_tokens); // 50 + 10 thoughts
    try testing.expectEqual(@as(u64, 0), e2.cache_read_tokens);
    try testing.expectEqual(@as(u64, 860), e2.totalTokens());
    try testing.expectEqualStrings(fixture_session_id, e2.session_id);
    try testing.expectEqualStrings("/home/dev/other-proj", e2.cwd);
}

test "replayed records dedup on uuid, even from a different file" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Same ledger replayed into the legacy tmp/ layout: every uuid is
    // already in the seen-set, nothing new is emitted.
    const legacy_path = "tmp/3f7a1b2c/chats/" ++ fixture_session_id ++ ".jsonl";
    try tailer.feed(testing.allocator, legacy_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "sweepIncremental over a real directory layout, with append" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const chats_dir = "projects/-home-dev-qwen-proj/chats";
    const session_rel = chats_dir ++ "/" ++ fixture_session_id ++ ".jsonl";
    try tmp.dir.createDirPath(io, chats_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var projects_buf: [std.fs.max_path_bytes]u8 = undefined;
    const projects_root = try std.fmt.bufPrint(&projects_buf, "{s}/projects", .{base});
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = try std.fmt.bufPrint(&tmp_buf, "{s}/tmp", .{base});
    const roots = [_][]const u8{ projects_root, tmp_root };

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

    // Append a third assistant record; the hot pass catches it.
    const appended =
        "{\"uuid\":\"0f1e2d3c-0005-4a5b-8c9d-000000000005\",\"sessionId\":\"" ++ fixture_session_id ++ "\"," ++
        "\"timestamp\":\"2026-07-09T06:30:00.000Z\",\"type\":\"assistant\",\"cwd\":\"/home/dev/qwen-proj\"," ++
        "\"model\":\"qwen3-coder-plus\",\"message\":{\"role\":\"assistant\",\"content\":\"third\"}," ++
        "\"usageMetadata\":{\"promptTokenCount\":2100,\"candidatesTokenCount\":10," ++
        "\"cachedContentTokenCount\":2000,\"thoughtsTokenCount\":4,\"toolUsePromptTokenCount\":0," ++
        "\"totalTokenCount\":2114}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = session1_fixture ++ appended });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 3), out.items.len);
    const e3 = out.items[2];
    try testing.expectEqual(@as(i64, 1783578600000), e3.timestamp_ms);
    try testing.expectEqual(@as(u64, 100), e3.input_tokens); // 2100 - 2000 cached
    try testing.expectEqual(@as(u64, 14), e3.output_tokens); // 10 + 4 thoughts
    try testing.expectEqual(@as(u64, 2000), e3.cache_read_tokens);
    try testing.expectEqual(@as(u64, 2114), e3.totalTokens());
    try testing.expectEqualStrings("/home/dev/qwen-proj", e3.cwd);
    try testing.expectEqualStrings(fixture_session_id, e3.session_id);
}
