//! Kimi CLI (MoonshotAI/kimi-cli) JSONL session tailer adapter.
//!
//! Kimi writes append-only wire ledgers at
//! `$KIMI_SHARE_DIR/sessions/<md5(cwd)>/<session-id>/wire.jsonl` (default
//! share dir `~/.kimi`). The same session directory also holds
//! `context.jsonl` — compaction/context state, NOT an append-only usage
//! ledger — which must never be parsed. Two gates keep it out: the
//! adapter's `file_suffix` is `"/wire.jsonl"` (tailsource matches file
//! suffixes with a raw `endsWith` on the walker's root-relative path, so
//! this admits exactly files *named* wire.jsonl inside a subdirectory,
//! excluding `context.jsonl` and any `...wire.jsonl`-suffixed other name),
//! and `parseLine` additionally requires the basename of the file it is
//! fed to be exactly `wire.jsonl` — covering direct `feed`/`scanFile`
//! calls, which bypass the walker's suffix check.
//!
//! Record shape: line 1 is a `{"type":"metadata",...}` header (ignored —
//! it carries no cwd and the session id comes from the path). Every other
//! line is `{"timestamp": <unix float seconds>, "message": {"type":
//! "<ClassName>", "payload": {...}}}`. Usage lives only on
//! `message.type == "StatusUpdate"` records whose payload has a non-null
//! `token_usage`: `{input_other, output, input_cache_read,
//! input_cache_creation}`, mapped 1:1 onto `types.UsageEvent`
//! (input_tokens = input_other). `timestamp_ms = round(timestamp * 1000)`.
//!
//! Dedup: `payload.message_id` is the stable identity — a StatusUpdate
//! carrying `token_usage` but no `message_id` is SKIPPED, not emitted: a
//! usage blob without an id cannot be safely deduped (re-reads after
//! truncation resets or re-opened sessions would double count it).
//!
//! Model: Kimi does not persist the model on the record — it is
//! session-level config, not logged per call — so `model = ""`. Tokens are
//! counted but unpriced; the integrator surfaces that coverage gap.

const std = @import("std");
const types = @import("types.zig");
const tailsource = @import("tailsource.zig");
const Allocator = std.mem.Allocator;

/// The only file worth parsing in a Kimi session directory.
const wire_basename = "wire.jsonl";

/// Cheap pre-check: the only message class carrying usage.
const status_marker = "\"StatusUpdate\"";

/// Build the Kimi adapter. The agent tag is injected by the integrator
/// (`makeAdapter(.kimi)`) because `types.Agent` gains its `kimi` variant
/// as part of engine wiring, not here.
pub fn makeAdapter(agent_tag: types.Agent) tailsource.Adapter {
    return .{
        .agent = agent_tag,
        // Raw endsWith in tailsource: "/wire.jsonl" admits only files named
        // wire.jsonl below the root (Kimi always nests them two levels
        // down), never context.jsonl or "*wire.jsonl" lookalikes.
        .file_suffix = "/" ++ wire_basename,
        .parse = parseLine,
        .sessionIdFromPath = sessionIdFromPath,
    };
}

/// Convenience: a generic tailer preconfigured for Kimi.
pub fn makeTailer(allocator: Allocator, agent_tag: types.Agent) tailsource.Tailer {
    return tailsource.Tailer.init(allocator, makeAdapter(agent_tag));
}

// ---------------------------------------------------------------------------
// Session roots
// ---------------------------------------------------------------------------

/// Resolve the Kimi sessions root: `$KIMI_SHARE_DIR/sessions` when the
/// env var is set and non-blank, else `<home>/.kimi/sessions`. Caller owns
/// the returned slice and every string in it; release with `freeRoots`.
pub fn defaultRoots(
    allocator: Allocator,
    env_kimi_share_dir: ?[]const u8,
    home: []const u8,
) ![]const []const u8 {
    const roots = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(roots);
    const share = if (env_kimi_share_dir) |raw| std.mem.trim(u8, raw, " \t") else "";
    roots[0] = if (share.len != 0)
        try std.fs.path.join(allocator, &.{ share, "sessions" })
    else
        try std.fs.path.join(allocator, &.{ home, ".kimi", "sessions" });
    return roots;
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

/// The session id is the wire file's parent directory name:
/// `.../sessions/<md5(cwd)>/<session-id>/wire.jsonl` -> `<session-id>`.
pub fn sessionIdFromPath(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return "";
    return std.fs.path.basename(dir);
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

/// Parse one Kimi wire line: a StatusUpdate with non-null token_usage and
/// a message_id yields a usage event. Everything else — the metadata
/// header, other message classes, null token_usage, id-less usage,
/// malformed JSON, and any line from a non-wire file — returns null.
fn parseLine(event_allocator: Allocator, line: []const u8, ctx: tailsource.FileContext) ?tailsource.Parsed {
    // Second gate against context.jsonl (and anything else): only the wire
    // ledger is trusted, even when fed directly past the sweep filter.
    if (!std.mem.eql(u8, std.fs.path.basename(ctx.path), wire_basename)) return null;
    // Fast reject before spinning up a JSON parser: most wire records are
    // prompts, tool traffic, and text parts that never carry usage.
    if (std.mem.indexOf(u8, line, status_marker) == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, event_allocator, line, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    const message = getValue(root, "message") orelse return null;
    const msg_type = getString(message, "type") orelse return null;
    if (!std.mem.eql(u8, msg_type, "StatusUpdate")) return null;
    const payload = getValue(message, "payload") orelse return null;
    const usage = getValue(payload, "token_usage") orelse return null;
    if (usage != .object) return null; // token_usage: null — status tick without usage
    // No message_id => no safe dedup identity => skip (see module doc).
    const message_id = getString(payload, "message_id") orelse return null;

    const ts = getF64(root, "timestamp") orelse return null;
    if (!(ts >= 0 and ts < 1e12)) return null; // reject nonsense/NaN before @intFromFloat
    const ts_ms: i64 = @intFromFloat(@round(ts * 1000.0));

    const key = event_allocator.dupe(u8, message_id) catch return null;
    return .{
        .event = .{
            .usage = .{
                .agent = ctx.agent,
                .timestamp_ms = ts_ms,
                // Not logged per call (session-level config); "" = counted but
                // unpriced. Zero-length, so freeEvents' free is a no-op.
                .model = "",
                .input_tokens = getU64(usage, "input_other"),
                .output_tokens = getU64(usage, "output"),
                .cache_creation_tokens = getU64(usage, "input_cache_creation"),
                .cache_read_tokens = getU64(usage, "input_cache_read"),
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

/// Kimi timestamps are unix float seconds; tolerate whole-second values
/// the JSON parser surfaces as integers.
fn getF64(v: std.json.Value, key: []const u8) ?f64 {
    const child = getValue(v, key) orelse return null;
    return switch (child) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const wire_fixture = @embedFile("fixtures/kimi/wire.jsonl");

const fixture_sid = "0197aaaa-bbbb-7ccc-8ddd-eeeeffff0001";
const fixture_md5 = "d41d8cd98f00b204e9800998ecf8427e";
const fixture_path = "sessions/" ++ fixture_md5 ++ "/" ++ fixture_sid ++ "/wire.jsonl";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.kimi` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .claude;

test "defaultRoots falls back to <home>/.kimi/sessions" {
    const roots = try defaultRoots(testing.allocator, null, "/Users/somebody");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("/Users/somebody/.kimi/sessions", roots[0]);

    // Whitespace-only KIMI_SHARE_DIR behaves like unset.
    const roots2 = try defaultRoots(testing.allocator, "  \t", "/Users/somebody");
    defer freeRoots(testing.allocator, roots2);
    try testing.expectEqual(@as(usize, 1), roots2.len);
    try testing.expectEqualStrings("/Users/somebody/.kimi/sessions", roots2[0]);
}

test "defaultRoots honors KIMI_SHARE_DIR" {
    const roots = try defaultRoots(testing.allocator, "/srv/kimi-share", "/home/x");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("/srv/kimi-share/sessions", roots[0]);
}

test "sessionIdFromPath is the wire file's parent directory name" {
    try testing.expectEqualStrings(fixture_sid, sessionIdFromPath(fixture_path));
    try testing.expectEqualStrings("sid-1", sessionIdFromPath("/a/b/sid-1/wire.jsonl"));
    try testing.expectEqualStrings("", sessionIdFromPath("wire.jsonl"));
}

test "fixture parses through the generic tailer: one event, exact mapping" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, wire_fixture, &out);

    // 6 lines: metadata header, StatusUpdate with usage+id (the ONE event),
    // StatusUpdate with token_usage:null, StatusUpdate missing message_id,
    // an unrelated message class, malformed garbage.
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const e = out.items[0];
    try testing.expectEqual(test_agent, e.agent);
    try testing.expectEqual(@as(i64, 1783578505410), e.timestamp_ms); // round(1783578505.41 * 1000)
    try testing.expectEqualStrings("", e.model); // never logged per call
    try testing.expectEqual(@as(u64, 5369), e.input_tokens); // input_other
    try testing.expectEqual(@as(u64, 97), e.output_tokens); // output
    try testing.expectEqual(@as(u64, 128), e.cache_creation_tokens); // input_cache_creation
    try testing.expectEqual(@as(u64, 5120), e.cache_read_tokens); // input_cache_read
    try testing.expectEqualStrings(fixture_sid, e.session_id); // parent dir of wire.jsonl
    try testing.expectEqualStrings("", e.cwd); // no cwd meta in the wire format
}

test "message_id dedups globally across session files" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    try tailer.feed(testing.allocator, fixture_path, wire_fixture, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // The same records re-logged under a different session directory:
    // msg-0001 was already seen, so nothing new is emitted.
    const other_path = "sessions/" ++ fixture_md5 ++
        "/0197bbbb-cccc-7ddd-8eee-ffff00000002/wire.jsonl";
    try tailer.feed(testing.allocator, other_path, wire_fixture, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "non-wire files are ignored even when fed directly" {
    var tailer = makeTailer(testing.allocator, test_agent);
    defer tailer.deinit();
    var out: std.ArrayList(types.UsageEvent) = .empty;
    defer {
        tailsource.freeEvents(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // Identical bytes, but from the sibling context.jsonl: zero events.
    const context_path = "sessions/" ++ fixture_md5 ++ "/" ++ fixture_sid ++ "/context.jsonl";
    try tailer.feed(testing.allocator, context_path, wire_fixture, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "sweepIncremental over a real layout: wire.jsonl only, append caught" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = "sessions/" ++ fixture_md5 ++ "/" ++ fixture_sid;
    try tmp.dir.createDirPath(io, session_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = session_dir ++ "/wire.jsonl", .data = wire_fixture });
    // A sibling context.jsonl containing a well-formed StatusUpdate that
    // must NOT be picked up (excluded by the "/wire.jsonl" suffix).
    try tmp.dir.writeFile(io, .{
        .sub_path = session_dir ++ "/context.jsonl",
        .data = "{\"timestamp\":1783578509.0,\"message\":{\"type\":\"StatusUpdate\"," ++
            "\"payload\":{\"status\":\"idle\",\"message_id\":\"msg-ctx-0001\"," ++
            "\"token_usage\":{\"input_other\":9999,\"output\":9999," ++
            "\"input_cache_read\":0,\"input_cache_creation\":0}}}}\n",
    });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/sessions", .{base});
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
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 5369), out.items[0].input_tokens);
    try testing.expectEqualStrings(fixture_sid, out.items[0].session_id);

    // Quiet tick: nothing new.
    now += 2_000;
    try testing.expect(!try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // Append a new StatusUpdate to the (hot) wire file; the fast pass
    // catches it on the next tick.
    const appended =
        "{\"timestamp\":1783578600.0,\"message\":{\"type\":\"StatusUpdate\"," ++
        "\"payload\":{\"status\":\"idle\",\"message_id\":\"msg-0009\"," ++
        "\"token_usage\":{\"input_other\":200,\"output\":20," ++
        "\"input_cache_read\":1000,\"input_cache_creation\":50}}}}\n";
    try tmp.dir.writeFile(io, .{
        .sub_path = session_dir ++ "/wire.jsonl",
        .data = wire_fixture ++ appended,
    });
    now += 2_000;
    try testing.expect(try tailer.sweepIncremental(testing.allocator, io, &roots, &out, now));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const e2 = out.items[1];
    try testing.expectEqual(@as(i64, 1783578600000), e2.timestamp_ms);
    try testing.expectEqual(@as(u64, 200), e2.input_tokens);
    try testing.expectEqual(@as(u64, 20), e2.output_tokens);
    try testing.expectEqual(@as(u64, 50), e2.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 1000), e2.cache_read_tokens);
    try testing.expectEqualStrings(fixture_sid, e2.session_id);
}
