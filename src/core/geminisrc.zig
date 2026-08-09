//! Gemini CLI JSONL session tailer adapter (google-gemini/gemini-cli).
//!
//! Gemini CLI's ChatRecordingService writes append-only JSONL session
//! ledgers under `$GEMINI_CLI_HOME/tmp/<project-id>/chats/` (default
//! `~/.gemini`). Files are named `session-<timestamp>-<sessionId8>.jsonl`;
//! subagent sessions nest as `chats/<parentSessionId>/<sessionId>.jsonl`
//! — the tailer's recursive walk covers both, so `defaultRoots` yields
//! just `<root>/tmp`. (Older Gemini CLI versions rewrote a single
//! `.json` session file in place; those are out of scope — this adapter
//! tails only the append-only `.jsonl` format.)
//!
//! Line 1 is a metadata record `{sessionId, projectHash, startTime,
//! kind}` -> per-file meta carrying the session id (no cwd is available
//! in Gemini session files, so it stays unset). Subsequent lines are
//! `MessageRecord`s `{id, timestamp (ISO8601), type, model?, tokens?}`;
//! only records with `type == "gemini"` AND a `tokens` object are usage:
//! `tokens = {input, output, cached, thoughts, tool, total}`, a verbatim
//! copy of the API's GenerateContentResponseUsageMetadata (see
//! chatRecordingService.ts `recordMessageTokens`). `{$set: ...}` /
//! `{$rewindTo: ...}` state lines and everything else are ignored.
//!
//! Token mapping (source-verified; MUST stay consistent with
//! qwensrc.zig, which reads the same upstream metadata shape):
//! - `tokens.tool` (toolUsePromptTokenCount) is a SUBSET breakdown of
//!   `tokens.input` (promptTokenCount), NOT additive: the API defines
//!   totalTokenCount as "prompt + thoughts + response candidates" with
//!   tool-use tokens absent from the formula, and gemini-cli's own
//!   uiTelemetry never adds tool to prompt. It is therefore NOT added.
//! - `tokens.cached` (cachedContentTokenCount) is a SUBSET of
//!   `tokens.input`: the API docs state promptTokenCount "includes the
//!   number of tokens in the cached content", and uiTelemetry computes
//!   `input = max(0, prompt - cached)`. So `input_tokens = input -|
//!   cached` and `cache_read_tokens = cached` (no double count).
//! - `tokens.thoughts` (thoughtsTokenCount) is ADDITIVE billed output,
//!   not included in `tokens.output` (candidatesTokenCount) — the total
//!   formula enumerates it separately. So `output_tokens = output +
//!   thoughts`.
//! - Gemini has no cache-write accounting here: `cache_creation = 0`.
//! With this mapping `UsageEvent.totalTokens()` reproduces the logged
//! `tokens.total` exactly (same convention as pisrc.zig).
//!
//! QUIRK (verified upstream): the same message `id` may be appended
//! twice — first WITHOUT `tokens` (skipped by the filter above), then
//! re-appended WITH `tokens` once usage metadata arrives. Every emitted
//! event therefore carries `dedup_key = "<sessionId>:<id>"` so a double
//! token-bearing append can never double count.

const std = @import("std");
const types = @import("types.zig");
const tailsource = @import("tailsource.zig");
const timeutil = @import("timeutil.zig"); // parseTimestamp: same ISO8601 shape
const Allocator = std.mem.Allocator;

/// Cheap pre-checks: the only two line shapes worth JSON-parsing. Usage
/// lines carry a "tokens" object; the metadata header carries "sessionId".
const tokens_marker = "\"tokens\"";
const meta_marker = "\"sessionId\"";

/// Build the Gemini CLI adapter. The agent tag is injected by the
/// integrator (`makeAdapter(.gemini)`) because `types.Agent` gains its
/// `gemini` variant as part of engine wiring, not here.
pub fn makeAdapter(agent_tag: types.Agent) tailsource.Adapter {
    return .{
        .agent = agent_tag,
        .file_suffix = ".jsonl",
        .parse = parseLine,
        .sessionIdFromPath = sessionIdFromPath,
    };
}

/// Convenience: a generic tailer preconfigured for Gemini CLI.
pub fn makeTailer(allocator: Allocator, agent_tag: types.Agent) tailsource.Tailer {
    return tailsource.Tailer.init(allocator, makeAdapter(agent_tag));
}

// ---------------------------------------------------------------------------
// Session roots
// ---------------------------------------------------------------------------

/// Resolve the Gemini CLI sessions root: `$GEMINI_CLI_HOME/tmp` when the
/// env var is set (whitespace-only behaves like unset), else
/// `<home>/.gemini/tmp`. Sessions live at `tmp/<project-id>/chats/*.jsonl`
/// (subagents one level deeper); the tailer walks recursively, so the
/// single `tmp` root suffices. Caller owns the returned slice and every
/// string in it; release with `freeRoots`.
pub fn defaultRoots(
    allocator: Allocator,
    env_gemini_home: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    const root = blk: {
        if (env_gemini_home) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len != 0) {
                break :blk try std.fs.path.join(allocator, &.{ trimmed, "tmp" });
            }
        }
        break :blk try std.fs.path.join(allocator, &.{ home, ".gemini", "tmp" });
    };
    errdefer allocator.free(root);
    const roots = try allocator.alloc([]const u8, 1);
    roots[0] = root;
    return roots;
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

/// Fallback session id from the file path (the metadata line's
/// `sessionId` wins once seen): the filename stem, with the standard
/// `session-` prefix stripped when present. Subagent files
/// (`chats/<parent>/<sessionId>.jsonl`) have the bare id as their stem.
pub fn sessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    if (std.mem.startsWith(u8, stem, "session-")) return stem["session-".len..];
    return stem;
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

/// Parse one Gemini CLI session line: the metadata header yields per-file
/// meta (session id); a `type == "gemini"` message WITH a `tokens` object
/// yields a usage event keyed `<sessionId>:<id>`. Everything else — user
/// messages, token-less gemini messages, `$set`/`$rewindTo` state lines,
/// malformed JSON — returns null.
fn parseLine(event_allocator: Allocator, line: []const u8, ctx: tailsource.FileContext) ?tailsource.Parsed {
    // Fast reject before spinning up a JSON parser: most lines (user
    // messages, token-less appends, state updates) never match.
    if (std.mem.indexOf(u8, line, tokens_marker) == null and
        std.mem.indexOf(u8, line, meta_marker) == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, event_allocator, line, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    // Line 1 metadata: {sessionId, projectHash, startTime, kind}.
    // MessageRecords never carry a top-level sessionId.
    if (getString(root, "sessionId")) |sid| {
        const owned = event_allocator.dupe(u8, sid) catch return null;
        return .{ .meta = .{ .session_id = owned } };
    }

    const rec_type = getString(root, "type") orelse return null;
    if (!std.mem.eql(u8, rec_type, "gemini")) return null;
    const tokens = getValue(root, "tokens") orelse return null;
    if (tokens != .object) return null;
    const ts_str = getString(root, "timestamp") orelse return null;
    const ts_ms = timeutil.parseTimestamp(ts_str) orelse return null;

    const input = getU64(tokens, "input");
    const cached = getU64(tokens, "cached");

    const model_owned = event_allocator.dupe(u8, getString(root, "model") orelse "") catch return null;
    // Dedup identity for the double-append quirk (see module doc). The
    // session id comes from the file context (metadata line or path).
    const key: ?[]const u8 = if (getString(root, "id")) |id|
        std.fmt.allocPrint(event_allocator, "{s}:{s}", .{ ctx.session_id, id }) catch {
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
                // cached is a subset of input; tool is a subset of input and
                // NOT added; thoughts are additive output. See module doc.
                .input_tokens = input -| cached,
                .output_tokens = getU64(tokens, "output") + getU64(tokens, "thoughts"),
                .cache_creation_tokens = 0,
                .cache_read_tokens = cached,
            },
            .dedup_key = key,
        },
    };
}

// ---------------------------------------------------------------------------
// JSON helpers (all null-tolerant)
// ---------------------------------------------------------------------------

const jsonget = @import("jsonget.zig");
const getValue = jsonget.getValue;
const getString = jsonget.getString;
const getU64 = jsonget.getU64;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const session1_fixture = @embedFile("fixtures/gemini/session1.jsonl");

const fixture_session_id = "f00dfeed-1111-2222-3333-444455556666";
const fixture_path = "tmp/3f7a1b2c4d5e6f70/chats/" ++
    "session-2026-07-09T06-27-f00dfeed.jsonl";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.gemini` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .claude;

test "defaultRoots resolves GEMINI_CLI_HOME with ~/.gemini fallback" {
    const roots = try defaultRoots(testing.allocator, null, "/Users/somebody");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("/Users/somebody/.gemini/tmp", roots[0]);

    const roots2 = try defaultRoots(testing.allocator, "/opt/gem", "/Users/somebody");
    defer freeRoots(testing.allocator, roots2);
    try testing.expectEqual(@as(usize, 1), roots2.len);
    try testing.expectEqualStrings("/opt/gem/tmp", roots2[0]);

    // Whitespace-only GEMINI_CLI_HOME behaves like unset.
    const roots3 = try defaultRoots(testing.allocator, "  ", "/Users/somebody");
    defer freeRoots(testing.allocator, roots3);
    try testing.expectEqualStrings("/Users/somebody/.gemini/tmp", roots3[0]);
}

test "sessionIdFromPath strips the session- prefix when present" {
    try testing.expectEqualStrings("2026-07-09T06-27-f00dfeed", sessionIdFromPath(fixture_path));
    try testing.expectEqualStrings("beadfeed-0000-1111", sessionIdFromPath("chats/parent/beadfeed-0000-1111.jsonl"));
    try testing.expectEqualStrings("stem", sessionIdFromPath("/x/stem.jsonl"));
}

test "fixture parses through the generic tailer: count, mapping, session from meta" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);

    // 7 lines: metadata, user, gemini WITHOUT tokens (skipped), the SAME
    // id re-appended WITH tokens, a second tokened gemini record, a $set
    // state line, malformed garbage -> exactly 2 events.
    try testing.expectEqual(@as(usize, 2), out.items.len);

    const e1 = out.items[0];
    try testing.expectEqual(test_agent, e1.agent);
    try testing.expectEqual(@as(i64, 1783578505410), e1.timestamp_ms);
    try testing.expectEqualStrings("gemini-2.5-pro", e1.model);
    try testing.expectEqual(@as(u64, 4345), e1.input_tokens); // 5369 input - 1024 cached
    try testing.expectEqual(@as(u64, 141), e1.output_tokens); // 97 output + 44 thoughts
    try testing.expectEqual(@as(u64, 0), e1.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 1024), e1.cache_read_tokens);
    // tool=128 is a subset of input and must NOT be added anywhere:
    // totalTokens() reproduces the logged tokens.total exactly.
    try testing.expectEqual(@as(u64, 5510), e1.totalTokens());
    try testing.expectEqualStrings(fixture_session_id, e1.session_id); // from meta, not path
    try testing.expectEqualStrings("", e1.cwd); // gemini logs carry no cwd

    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1783578507039), e2.timestamp_ms);
    try testing.expectEqual(@as(u64, 800), e2.input_tokens);
    try testing.expectEqual(@as(u64, 60), e2.output_tokens); // 50 + 10 thoughts
    try testing.expectEqual(@as(u64, 0), e2.cache_read_tokens);
    try testing.expectEqual(@as(u64, 860), e2.totalTokens());
    try testing.expectEqualStrings(fixture_session_id, e2.session_id);
}

test "double token-bearing append of the same message id dedups to one event" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // The quirk, one step worse: the token-bearing line for msg-0002 is
    // appended AGAIN. dedup_key "<sessionId>:msg-0002" drops it.
    const again =
        "{\"id\":\"msg-0002\",\"timestamp\":\"2026-07-09T06:28:25.410Z\",\"type\":\"gemini\"," ++
        "\"content\":\"first reply\",\"model\":\"gemini-2.5-pro\",\"tokens\":{\"input\":5369," ++
        "\"output\":97,\"cached\":1024,\"thoughts\":44,\"tool\":128,\"total\":5510}}\n";
    try tailer.feed(testing.allocator, fixture_path, again, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Re-feeding the whole ledger (e.g. after a truncation reset) adds
    // nothing either.
    try tailer.feed(testing.allocator, fixture_path, session1_fixture, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "sweep covers nested subagent session files under chats/<parent>/" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const chats_dir = "tmp/3f7a1b2c4d5e6f70/chats";
    try tmp.dir.createDirPath(io, chats_dir ++ "/" ++ fixture_session_id);
    try tmp.dir.writeFile(io, .{
        .sub_path = chats_dir ++ "/session-2026-07-09T06-27-f00dfeed.jsonl",
        .data = session1_fixture,
    });
    // Subagent session: bare-id filename, its own metadata line.
    try tmp.dir.writeFile(io, .{
        .sub_path = chats_dir ++ "/" ++ fixture_session_id ++ "/beadfeed-0000-1111-2222-333344445555.jsonl",
        .data = "{\"sessionId\":\"beadfeed-0000-1111-2222-333344445555\",\"projectHash\":\"3f7a\"," ++
            "\"startTime\":\"2026-07-09T06:29:00.000Z\",\"kind\":\"metadata\"}\n" ++
            "{\"id\":\"msg-9001\",\"timestamp\":\"2026-07-09T06:30:00.000Z\",\"type\":\"gemini\"," ++
            "\"content\":\"sub\",\"model\":\"gemini-2.5-flash\",\"tokens\":{\"input\":300," ++
            "\"output\":30,\"cached\":0,\"thoughts\":0,\"tool\":0,\"total\":330}}\n",
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/tmp", .{base});
    const roots = [_][]const u8{root};

    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    var subagent_events: usize = 0;
    for (out.items) |ev| {
        if (std.mem.eql(u8, ev.session_id, "beadfeed-0000-1111-2222-333344445555")) {
            subagent_events += 1;
            try testing.expectEqual(@as(u64, 330), ev.totalTokens());
            try testing.expectEqualStrings("gemini-2.5-flash", ev.model);
        }
    }
    try testing.expectEqual(@as(usize, 1), subagent_events);
}
