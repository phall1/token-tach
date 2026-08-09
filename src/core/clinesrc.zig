//! Cline rewritten-JSON usage adapters (agent name "cline"), both store
//! generations, each an Adapter for the generic snapsource engine.
//!
//! New SDK/CLI store (cline messages-contract-v1):
//! `<data>/sessions/<sessionId>/<sessionId>.messages.json`, where `<data>`
//! is `$CLINE_DATA_DIR`, else `$CLINE_DIR/data`, else `~/.cline/data`. The
//! file is one JSON object `{version:1, sessionId, messages:[...]}`
//! rewritten whole as the session progresses. Usage-bearing messages carry
//! `metrics:{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
//! cost}`, `modelInfo:{id}`, `ts` (epoch ms), and a stable `id` — the
//! record key. `metrics.cost` is ignored: cost is computed downstream from
//! tokens and pricing tables.
//!
//! Legacy VS Code task store:
//! `<globalStorage>/saoudrizwan.claude-dev/tasks/<taskId>/ui_messages.json`
//! (and `<data>/tasks/...`). The file is one JSON ARRAY of messages; usage
//! rows are `{type:"say", say:"api_req_started"|"deleted_api_reqs", ts,
//! text:"<stringified JSON>"}` whose inner JSON has `tokensIn, tokensOut,
//! cacheWrites, cacheReads, cost`. Cline rewrites the `api_req_started`
//! row IN PLACE once the response lands (first pass has no token fields:
//! total 0, skipped; the rewrite makes it appear as an add) — exactly the
//! mutation snapsource's replace Changes exist for. Record key = `ts` as a
//! decimal string; session id = the task directory name; model is left ""
//! (not present in the blob — unpriced is honest).
//!
//! Message content is never stored: parsing extracts only ids, usage
//! numbers, model ids, and timestamps.

const std = @import("std");
const types = @import("types.zig");
const snapsource = @import("snapsource.zig");
const Allocator = std.mem.Allocator;

/// Suffix of new-generation SDK/CLI session stores.
pub const sdk_file_suffix = ".messages.json";
/// Exact basename of legacy task stores (used as a path suffix).
pub const legacy_file_suffix = "ui_messages.json";

/// The new SDK/CLI store adapter.
pub fn makeSdkAdapter() snapsource.Adapter {
    return .{ .file_suffix = sdk_file_suffix, .parseFile = parseSdkFile };
}

/// The legacy VS Code task store adapter.
pub fn makeLegacyAdapter() snapsource.Adapter {
    return .{ .file_suffix = legacy_file_suffix, .parseFile = parseLegacyUiMessages };
}

/// Convenience: pollers preconfigured for each generation. The agent tag
/// is injected by the integrator (`makeSdkPoller(gpa, .cline)`) because
/// `types.Agent` gains its `cline` variant with engine wiring, not here.
pub fn makeSdkPoller(allocator: Allocator, agent_tag: types.Agent) snapsource.Poller {
    return snapsource.Poller.init(allocator, agent_tag, makeSdkAdapter());
}

pub fn makeLegacyPoller(allocator: Allocator, agent_tag: types.Agent) snapsource.Poller {
    return snapsource.Poller.init(allocator, agent_tag, makeLegacyAdapter());
}

// ---------------------------------------------------------------------------
// Roots
// ---------------------------------------------------------------------------

/// The Cline data directory: `$CLINE_DATA_DIR` (replaces `~/.cline/data`),
/// else `$CLINE_DIR/data` (`$CLINE_DIR` replaces `~/.cline`), else
/// `<home>/.cline/data`. Caller owns the returned path.
fn dataDir(
    allocator: Allocator,
    env_cline_dir: ?[]const u8,
    env_cline_data_dir: ?[]const u8,
    home: []const u8,
) ![]u8 {
    if (env_cline_data_dir) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (env_cline_dir) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 0) return std.fs.path.join(allocator, &.{ trimmed, "data" });
    }
    return std.fs.path.join(allocator, &.{ home, ".cline", "data" });
}

/// Roots for the SDK/CLI generation: `<data>/sessions`. Caller owns the
/// returned slice and every string in it; release with `freeRoots`.
pub fn sdkRoots(
    allocator: Allocator,
    env_cline_dir: ?[]const u8,
    env_cline_data_dir: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    const data = try dataDir(allocator, env_cline_dir, env_cline_data_dir, home);
    defer allocator.free(data);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeRootsList(allocator, &list);
    const sessions = try std.fs.path.join(allocator, &.{ data, "sessions" });
    errdefer allocator.free(sessions);
    try list.append(allocator, sessions);
    return try list.toOwnedSlice(allocator);
}

/// Roots for the legacy generation: the VS Code extension's globalStorage
/// task tree plus `<data>/tasks`. Caller owns; release with `freeRoots`.
pub fn legacyRoots(
    allocator: Allocator,
    env_cline_dir: ?[]const u8,
    env_cline_data_dir: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeRootsList(allocator, &list);

    const vscode = try std.fs.path.join(allocator, &.{
        home,            "Library",                "Application Support", "Code", "User",
        "globalStorage", "saoudrizwan.claude-dev", "tasks",
    });
    errdefer allocator.free(vscode);
    try list.append(allocator, vscode);

    const data = try dataDir(allocator, env_cline_dir, env_cline_data_dir, home);
    defer allocator.free(data);
    const tasks = try std.fs.path.join(allocator, &.{ data, "tasks" });
    errdefer allocator.free(tasks);
    try list.append(allocator, tasks);

    return try list.toOwnedSlice(allocator);
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

fn freeRootsList(allocator: Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |p| allocator.free(p);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Path-derived identifiers
// ---------------------------------------------------------------------------

/// `<sessionId>.messages.json` -> `<sessionId>` (fallback when the file's
/// own `sessionId` field is missing).
pub fn sdkSessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, sdk_file_suffix)) return base[0 .. base.len - sdk_file_suffix.len];
    return base;
}

/// `<taskId>/ui_messages.json` -> `<taskId>` (the parent directory name).
pub fn legacyTaskIdFromPath(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return "";
    return std.fs.path.basename(dir);
}

// ---------------------------------------------------------------------------
// SDK/CLI store parsing (messages-contract-v1)
// ---------------------------------------------------------------------------

/// Tolerant mirror of the v1 messages file: only identity/usage/model/time
/// fields are declared; everything else (content, tool calls, ...) is
/// ignored and never retained.
const SdkFile = struct {
    version: i64 = 0,
    sessionId: []const u8 = "",
    messages: []const SdkMessage = &.{},
};

const SdkMessage = struct {
    id: []const u8 = "",
    ts: i64 = 0,
    modelInfo: ?SdkModelInfo = null,
    metrics: ?SdkMetrics = null,
};

const SdkModelInfo = struct {
    id: []const u8 = "",
};

const SdkMetrics = struct {
    inputTokens: i64 = 0,
    outputTokens: i64 = 0,
    cacheReadTokens: i64 = 0,
    cacheWriteTokens: i64 = 0,
};

fn parseSdkFile(arena: Allocator, bytes: []const u8, ctx: snapsource.FileContext) anyerror![]snapsource.Record {
    const empty: []snapsource.Record = &.{};
    const file = std.json.parseFromSliceLeaky(SdkFile, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return empty;

    const session_id = if (file.sessionId.len > 0) file.sessionId else sdkSessionIdFromPath(ctx.path);
    var list: std.ArrayList(snapsource.Record) = .empty;
    for (file.messages) |m| {
        const metrics = m.metrics orelse continue;
        if (m.id.len == 0) continue;
        const input = tok(metrics.inputTokens);
        const output = tok(metrics.outputTokens);
        const cache_read = tok(metrics.cacheReadTokens);
        const cache_write = tok(metrics.cacheWriteTokens);
        if (input + output + cache_read + cache_write == 0) continue;
        try list.append(arena, .{
            .key = m.id,
            .event = .{
                .agent = ctx.agent,
                .timestamp_ms = m.ts,
                .model = if (m.modelInfo) |mi| mi.id else "",
                .input_tokens = input,
                .output_tokens = output,
                .cache_creation_tokens = cache_write,
                .cache_read_tokens = cache_read,
                .session_id = session_id,
            },
        });
    }
    return list.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Legacy task store parsing (shared with roosrc.zig — Roo Code forked the
// exact same ui_messages.json shape and field names)
// ---------------------------------------------------------------------------

/// Inner `text` blob of a usage row. Only token counters are declared;
/// `request`, `cost`, and everything else is ignored and never retained.
const ApiReqInfo = struct {
    tokensIn: i64 = 0,
    tokensOut: i64 = 0,
    cacheWrites: i64 = 0,
    cacheReads: i64 = 0,
};

/// Parse a legacy `ui_messages.json` array: `api_req_started` and
/// `deleted_api_reqs` say-rows yield records keyed by their `ts` (decimal
/// string). Rows without token totals yet — or with malformed inner JSON —
/// are skipped; a later rewrite that fills them in surfaces as an add.
pub fn parseLegacyUiMessages(arena: Allocator, bytes: []const u8, ctx: snapsource.FileContext) anyerror![]snapsource.Record {
    const empty: []snapsource.Record = &.{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return empty;
    if (root != .array) return empty;

    const task_id = legacyTaskIdFromPath(ctx.path);
    var list: std.ArrayList(snapsource.Record) = .empty;
    for (root.array.items) |item| {
        if (item != .object) continue;
        const kind = getString(item, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "say")) continue;
        const say = getString(item, "say") orelse continue;
        if (!std.mem.eql(u8, say, "api_req_started") and
            !std.mem.eql(u8, say, "deleted_api_reqs")) continue;
        const ts = getI64(item, "ts") orelse continue;
        const text = getString(item, "text") orelse continue;
        const info = std.json.parseFromSliceLeaky(ApiReqInfo, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        const input = tok(info.tokensIn);
        const output = tok(info.tokensOut);
        const cache_write = tok(info.cacheWrites);
        const cache_read = tok(info.cacheReads);
        if (input + output + cache_write + cache_read == 0) continue;
        try list.append(arena, .{
            .key = try std.fmt.allocPrint(arena, "{d}", .{ts}),
            .event = .{
                .agent = ctx.agent,
                .timestamp_ms = ts,
                .model = "", // not in the blob; unpriced is honest
                .input_tokens = input,
                .output_tokens = output,
                .cache_creation_tokens = cache_write,
                .cache_read_tokens = cache_read,
                .session_id = task_id,
            },
        });
    }
    return list.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn tok(v: i64) u64 {
    return if (v < 0) 0 else @intCast(v);
}

const jsonget = @import("jsonget.zig");
const getString = jsonget.getString;
const getI64 = jsonget.getI64;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sdk_fixture = @embedFile("fixtures/cline/session1.messages.json");
const legacy_fixture = @embedFile("fixtures/cline/ui_messages.json");

const sdk_session_id = "0197a1b2-3456-7890-abcd-ef0123456789";
const legacy_task_id = "1783600300000";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.cline` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .opencode;

test "sdkRoots: env precedence CLINE_DATA_DIR > CLINE_DIR > ~/.cline" {
    const a = try sdkRoots(testing.allocator, null, null, "/Users/u");
    defer freeRoots(testing.allocator, a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("/Users/u/.cline/data/sessions", a[0]);

    const b = try sdkRoots(testing.allocator, "/custom/cline", null, "/Users/u");
    defer freeRoots(testing.allocator, b);
    try testing.expectEqualStrings("/custom/cline/data/sessions", b[0]);

    const c = try sdkRoots(testing.allocator, "/custom/cline", "/elsewhere/data", "/Users/u");
    defer freeRoots(testing.allocator, c);
    try testing.expectEqualStrings("/elsewhere/data/sessions", c[0]);

    // Whitespace-only env values behave like unset.
    const d = try sdkRoots(testing.allocator, " ", "\t", "/Users/u");
    defer freeRoots(testing.allocator, d);
    try testing.expectEqualStrings("/Users/u/.cline/data/sessions", d[0]);
}

test "legacyRoots: VS Code globalStorage tasks plus <data>/tasks" {
    const roots = try legacyRoots(testing.allocator, null, null, "/Users/u");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expectEqualStrings(
        "/Users/u/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
        roots[0],
    );
    try testing.expectEqualStrings("/Users/u/.cline/data/tasks", roots[1]);
}

test "path-derived identifiers" {
    try testing.expectEqualStrings("sess-1", sdkSessionIdFromPath("/d/sessions/sess-1/sess-1.messages.json"));
    try testing.expectEqualStrings(legacy_task_id, legacyTaskIdFromPath("/t/" ++ legacy_task_id ++ "/ui_messages.json"));
    try testing.expectEqualStrings("", legacyTaskIdFromPath("ui_messages.json"));
}

test "SDK store through snapsource: parse, mtime-gated re-poll, grown metric replaces" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_rel = "sessions/" ++ sdk_session_id ++ "/" ++ sdk_session_id ++ ".messages.json";
    try tmp.dir.createDirPath(io, "sessions/" ++ sdk_session_id);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = sdk_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
    const roots = [_][]const u8{root};

    var poller = makeSdkPoller(testing.allocator, test_agent);
    defer poller.deinit();
    var out: std.ArrayList(snapsource.Change) = .empty;
    defer {
        snapsource.freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // 4 messages: user (no metrics) and all-zero metrics skipped -> 2 adds.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const e1 = out.items[0];
    try testing.expect(e1.previous == null);
    try testing.expectEqual(test_agent, e1.current.agent);
    try testing.expectEqual(@as(i64, 1783600004200), e1.current.timestamp_ms);
    try testing.expectEqualStrings("claude-sonnet-5", e1.current.model);
    try testing.expectEqual(@as(u64, 1200), e1.current.input_tokens);
    try testing.expectEqual(@as(u64, 340), e1.current.output_tokens);
    try testing.expectEqual(@as(u64, 800), e1.current.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 5600), e1.current.cache_read_tokens);
    try testing.expectEqualStrings(sdk_session_id, e1.current.session_id);
    const e2 = out.items[1];
    try testing.expect(e2.previous == null);
    try testing.expectEqual(@as(u64, 74), e2.current.input_tokens);
    try testing.expectEqual(@as(u64, 6400), e2.current.cache_read_tokens);

    // Quiet re-poll: unchanged file, nothing emitted.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Rewrite with msg-asst-002's outputTokens grown -> one replace Change.
    const grown = try std.mem.replaceOwned(u8, testing.allocator, sdk_fixture, "\"outputTokens\": 340", "\"outputTokens\": 1340");
    defer testing.allocator.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = session_rel, .data = grown });
    snapsource.freeChanges(testing.allocator, out.items);
    out.clearRetainingCapacity();
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const repl = out.items[0];
    try testing.expect(repl.previous != null);
    try testing.expectEqual(@as(u64, 340), repl.previous.?.output_tokens);
    try testing.expectEqual(@as(u64, 1340), repl.current.output_tokens);
    try testing.expectEqual(@as(u64, 1200), repl.current.input_tokens);
    try testing.expectEqualStrings(sdk_session_id, repl.current.session_id);
}

test "legacy task store through snapsource: usage rows, malformed blob, grown row replaces" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const task_rel = "tasks/" ++ legacy_task_id ++ "/ui_messages.json";
    try tmp.dir.createDirPath(io, "tasks/" ++ legacy_task_id);
    try tmp.dir.writeFile(io, .{ .sub_path = task_rel, .data = legacy_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/tasks", .{base});
    const roots = [_][]const u8{root};

    var poller = makeLegacyPoller(testing.allocator, test_agent);
    defer poller.deinit();
    var out: std.ArrayList(snapsource.Change) = .empty;
    defer {
        snapsource.freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // 6 rows: api_req_started + deleted_api_reqs count; the malformed
    // usage blob and every non-usage row are skipped.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const e1 = out.items[0];
    try testing.expect(e1.previous == null);
    try testing.expectEqual(@as(i64, 1783600301500), e1.current.timestamp_ms);
    try testing.expectEqualStrings("", e1.current.model);
    try testing.expectEqual(@as(u64, 2100), e1.current.input_tokens);
    try testing.expectEqual(@as(u64, 180), e1.current.output_tokens);
    try testing.expectEqual(@as(u64, 650), e1.current.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 4300), e1.current.cache_read_tokens);
    try testing.expectEqualStrings(legacy_task_id, e1.current.session_id);
    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1783600304750), e2.current.timestamp_ms);
    try testing.expectEqual(@as(u64, 900), e2.current.input_tokens);
    try testing.expectEqual(@as(u64, 75), e2.current.output_tokens);
    try testing.expectEqual(@as(u64, 1200), e2.current.cache_read_tokens);

    // Cline rewrote the api_req_started row with more output tokens.
    const grown = try std.mem.replaceOwned(u8, testing.allocator, legacy_fixture, "tokensOut\\\":180", "tokensOut\\\":1180");
    defer testing.allocator.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = task_rel, .data = grown });
    snapsource.freeChanges(testing.allocator, out.items);
    out.clearRetainingCapacity();
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].previous != null);
    try testing.expectEqual(@as(u64, 180), out.items[0].previous.?.output_tokens);
    try testing.expectEqual(@as(u64, 1180), out.items[0].current.output_tokens);
    try testing.expectEqualStrings(legacy_task_id, out.items[0].current.session_id);
}
