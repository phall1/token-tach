//! Roo Code rewritten-JSON usage adapter (agent name "roo").
//!
//! Roo Code forked Cline and kept the legacy task store byte-for-byte
//! compatible: `<globalStorage>/rooveterinaryinc.roo-cline/tasks/<taskId>/
//! ui_messages.json` — a JSON ARRAY rewritten whole, with usage on
//! `{type:"say", say:"api_req_started"|"deleted_api_reqs"}` rows whose
//! stringified `text` blob carries `tokensIn, tokensOut, cacheWrites,
//! cacheReads` (source-verified identical field names). Parsing is shared
//! with clinesrc.zig; this module only supplies the Roo roots and wiring.
//!
//! Roo lets users move storage via its "custom storage path" setting; the
//! integrator passes any such directories as extra roots (append
//! `<custom>/tasks` alongside `defaultRoots`).

const std = @import("std");
const types = @import("types.zig");
const snapsource = @import("snapsource.zig");
const clinesrc = @import("clinesrc.zig");
const Allocator = std.mem.Allocator;

/// The Roo Code task store adapter (legacy ui_messages.json shape).
pub fn makeAdapter() snapsource.Adapter {
    return .{
        .file_suffix = clinesrc.legacy_file_suffix,
        .parseFile = clinesrc.parseLegacyUiMessages,
    };
}

/// Convenience: a snapshot poller preconfigured for Roo Code. The agent
/// tag is injected by the integrator (`makePoller(gpa, .roo)`) because
/// `types.Agent` gains its `roo` variant with engine wiring, not here.
pub fn makePoller(allocator: Allocator, agent_tag: types.Agent) snapsource.Poller {
    return snapsource.Poller.init(allocator, agent_tag, makeAdapter());
}

/// The default Roo Code task root:
/// `~/Library/Application Support/Code/User/globalStorage/`
/// `rooveterinaryinc.roo-cline/tasks`. Custom storage paths configured in
/// Roo are appended by the integrator as extra roots. Caller owns the
/// returned slice and every string in it; release with `freeRoots`.
pub fn defaultRoots(allocator: Allocator, home: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    const tasks = try std.fs.path.join(allocator, &.{
        home,            "Library",                    "Application Support", "Code", "User",
        "globalStorage", "rooveterinaryinc.roo-cline", "tasks",
    });
    errdefer allocator.free(tasks);
    try list.append(allocator, tasks);
    return try list.toOwnedSlice(allocator);
}

pub fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

/// `<taskId>/ui_messages.json` -> `<taskId>` (re-export for integrators).
pub const taskIdFromPath = clinesrc.legacyTaskIdFromPath;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const roo_fixture = @embedFile("fixtures/roo/ui_messages.json");

const fixture_task_id = "1783601000000";

/// Stand-in agent tag: tests exercise the adapter mechanics; the real
/// `.roo` variant of types.Agent arrives with engine wiring.
const test_agent: types.Agent = .opencode;

test "defaultRoots points at the Roo globalStorage task tree" {
    const roots = try defaultRoots(testing.allocator, "/Users/u");
    defer freeRoots(testing.allocator, roots);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings(
        "/Users/u/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks",
        roots[0],
    );
}

test "Roo task store through snapsource: usage rows, extras ignored, grown row replaces" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const task_rel = "tasks/" ++ fixture_task_id ++ "/ui_messages.json";
    try tmp.dir.createDirPath(io, "tasks/" ++ fixture_task_id);
    try tmp.dir.writeFile(io, .{ .sub_path = task_rel, .data = roo_fixture });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/tasks", .{base});
    const roots = [_][]const u8{root};

    var poller = makePoller(testing.allocator, test_agent);
    defer poller.deinit();
    var out: std.ArrayList(snapsource.Change) = .empty;
    defer {
        snapsource.freeChanges(testing.allocator, out.items);
        out.deinit(testing.allocator);
    }

    // 6 rows: two well-formed api_req_started rows count; the malformed
    // blob and every non-usage row are skipped. Extra blob fields
    // (apiProtocol, cancelReason) are tolerated and ignored.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    const e1 = out.items[0];
    try testing.expect(e1.previous == null);
    try testing.expectEqual(test_agent, e1.current.agent);
    try testing.expectEqual(@as(i64, 1783601002500), e1.current.timestamp_ms);
    try testing.expectEqualStrings("", e1.current.model);
    try testing.expectEqual(@as(u64, 3200), e1.current.input_tokens);
    try testing.expectEqual(@as(u64, 410), e1.current.output_tokens);
    try testing.expectEqual(@as(u64, 128), e1.current.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 7600), e1.current.cache_read_tokens);
    try testing.expectEqualStrings(fixture_task_id, e1.current.session_id);
    const e2 = out.items[1];
    try testing.expect(e2.previous == null);
    try testing.expectEqual(@as(i64, 1783601006000), e2.current.timestamp_ms);
    try testing.expectEqual(@as(u64, 55), e2.current.input_tokens);
    try testing.expectEqual(@as(u64, 12), e2.current.output_tokens);
    try testing.expectEqual(@as(u64, 8100), e2.current.cache_read_tokens);

    // Quiet re-poll: unchanged file, nothing emitted.
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Roo rewrote the first api_req_started row with more output tokens.
    const grown = try std.mem.replaceOwned(u8, testing.allocator, roo_fixture, "tokensOut\\\":410", "tokensOut\\\":2410");
    defer testing.allocator.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = task_rel, .data = grown });
    snapsource.freeChanges(testing.allocator, out.items);
    out.clearRetainingCapacity();
    try poller.sweep(testing.allocator, io, &roots, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].previous != null);
    try testing.expectEqual(@as(u64, 410), out.items[0].previous.?.output_tokens);
    try testing.expectEqual(@as(u64, 2410), out.items[0].current.output_tokens);
    try testing.expectEqualStrings(fixture_task_id, out.items[0].current.session_id);
}
