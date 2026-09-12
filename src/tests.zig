const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const cli = @import("cli.zig");
const engine = @import("engine.zig");
const view = @import("view.zig");
const dashboard = @import("dashboard.zig");
const presentation = @import("presentation.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const ledger = @import("core/ledger.zig");
const summary = @import("core/usage_summary.zig");
const canvas = native_sdk.canvas;
const testing = std.testing;

// Core, history, dashboard and HUD regression coverage remains independent
// of the retired instrument canvas. View tests cross the new snapshot seam.
test {
    _ = @import("core/types.zig");
    _ = @import("core/config.zig");
    _ = @import("core/cfcache.zig");
    _ = @import("core/dbgate.zig");
    _ = @import("core/sqlite.zig");
    _ = @import("core/jsonget.zig");
    _ = @import("core/timeutil.zig");
    _ = @import("core/claude.zig");
    _ = @import("core/codex.zig");
    _ = @import("core/opencode.zig");
    _ = @import("core/tailsource.zig");
    _ = @import("core/snapsource.zig");
    _ = @import("core/pisrc.zig");
    _ = @import("core/geminisrc.zig");
    _ = @import("core/qwensrc.zig");
    _ = @import("core/kimisrc.zig");
    _ = @import("core/goosesrc.zig");
    _ = @import("core/kilosrc.zig");
    _ = @import("core/clinesrc.zig");
    _ = @import("core/roosrc.zig");
    _ = @import("core/fleet.zig");
    _ = @import("core/pricing.zig");
    _ = @import("core/oauth.zig");
    _ = @import("core/keychain.zig");
    _ = @import("core/ledger.zig");
    _ = @import("core/statefile.zig");
    _ = @import("core/ring.zig");
    _ = @import("core/history.zig");
    _ = @import("core/sessions.zig");
    _ = @import("core/project.zig");
    _ = @import("core/predict.zig");
    _ = @import("core/alerts.zig");
    _ = @import("core/trayfmt.zig");
    _ = @import("core/system/system.zig");
    _ = @import("core/usage_summary.zig");
    _ = @import("presentation.zig");
    _ = @import("cli.zig");
    _ = @import("dashboard.zig");
    _ = @import("hud.zig");
    _ = @import("engine.zig");
}

const windows = [_]types.LimitWindow{
    .{ .kind = .five_hour, .used_percent = 67, .resets_at_ms = 6_000_000 },
    .{ .kind = .weekly, .used_percent = 34, .resets_at_ms = 9_000_000 },
};

fn modelFixture() engine.Model {
    var model: engine.Model = .{
        .ready = true,
        .now_ms = 1_000_000,
        .ledger = ledger.Ledger.init(testing.allocator, 0),
        .claude_limits = .{ .agent = .claude, .read_at_ms = 990_000, .plan = "Max", .windows = &windows },
    };
    model.cfg.claude_oauth = true;
    model.usage_summary = .{ .available = true, .updated_ms = model.now_ms, .end_day = 20_000 };
    const source = model.usage_summary.sources.getPtr(.claude);
    source.days[6] = .{ .output_tokens = 1234, .cost_usd = 1.25, .events = 1 };
    source.total = source.days[6];
    source.models[0] = .{ .name = summary.Name.init("claude-example"), .tokens = 1234 };
    source.models_len = 1;
    return model;
}

fn treeFor(arena: std.mem.Allocator, model: *const engine.Model) !view.Ui.Tree {
    var ui = view.Ui.init(arena);
    const snapshot = presentation.snapshot(engine.presentationInput(model));
    const root = view.rootView(&ui, &snapshot);
    try testing.expect(!ui.failed);
    return ui.finalizeWithTokens(root, theme.tokens());
}

fn containsText(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (containsText(child, needle)) return true;
    }
    return false;
}

fn named(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (named(child, text)) |found| return found;
    }
    return null;
}

fn press(tree: view.Ui.Tree, text: []const u8) !engine.Msg {
    const widget = named(tree.root, text) orelse return error.MissingButton;
    return tree.msgForPointer(widget.id, .up) orelse error.NoMessage;
}

test "popover puts allowance and consistent recent history on the first page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    const tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "67% used"));
    try testing.expect(containsText(tree.root, "LAST 7 DAYS"));
    try testing.expect(containsText(tree.root, "claude-example"));
    try testing.expect(containsText(tree.root, "API-equivalent"));
    try testing.expect(!containsText(tree.root, "TRIP"));
    try testing.expect(named(tree.root, "Change") == null);
    try testing.expectEqual(engine.Msg.open_dashboard, try press(tree, "History"));
    try testing.expectEqual(engine.Msg.open_config, try press(tree, "Settings"));
}

test "source chooser and back route real messages without attributing OpenCode to a plan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    try model.ledger.add(.{ .agent = .opencode, .timestamp_ms = model.now_ms, .model = "claude-example", .output_tokens = 10 }, 0.1);
    var tree = try treeFor(arena.allocator(), &model);
    engine.applyUxMsg(&model, try press(tree, "Change"));
    tree = try treeFor(arena.allocator(), &model);
    engine.applyUxMsg(&model, try press(tree, "OpenCode"));
    tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "Subscription attribution is unknown"));
    try testing.expect(!containsText(tree.root, "67%"));
    engine.applyUxMsg(&model, try press(tree, "Sessions"));
    tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "No recent sessions"));
    engine.applyUxMsg(&model, try press(tree, "Back"));
    try testing.expectEqual(types.Agent.opencode, model.ux.selected_source.?);
}

test "stale allowance is readable but cannot drive the default tray" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    model.now_ms += presentation.stale_after_ms;
    const tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "Stale"));
    try testing.expect(containsText(tree.root, "67% used"));
    try testing.expect(presentation.glance(engine.presentationInput(&model)) == null);
    var buf: [128]u8 = undefined;
    const title = @import("core/trayfmt.zig").render(&buf, "{status}", engine.glanceState(&model));
    try testing.expectEqualStrings("0 tok today", title);
}

test "all popover pages fit the node budget and retain visible footer actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    for (std.enums.values(types.Agent)) |agent| {
        try model.ledger.add(.{ .agent = agent, .timestamp_ms = model.now_ms, .model = "example", .output_tokens = 1 }, 0);
    }
    for (0..32) |i| {
        var buf: [32]u8 = undefined;
        model.roster.record(.{ .agent = .opencode, .model = "example", .timestamp_ms = model.now_ms, .session_id = try std.fmt.bufPrint(&buf, "session-{d}", .{i}), .cwd = "/work/project", .output_tokens = 100 }, 0);
    }
    for (std.enums.values(presentation.Page)) |page| {
        model.ux.popover_page = page;
        const tree = try treeFor(arena.allocator(), &model);
        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(tree.root, .{ .x = 0, .y = 0, .width = view.window_width, .height = view.window_height }, &nodes);
        try testing.expect(layout.nodes.len < 512);
        var commands: [2048]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try canvas.emitWidgetLayout(&builder, layout, theme.tokens());
        try testing.expect(builder.displayList().commandCount() < 2048);
        const settings = named(tree.root, "Settings").?;
        for (layout.nodes) |node| {
            if (node.widget.id != settings.id) continue;
            try testing.expect(node.frame.y >= 0);
            try testing.expect(node.frame.y + node.frame.height <= view.window_height);
        }
    }
}

test "loading and empty states remain discoverable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model: engine.Model = .{};
    var tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "Reading local usage"));
    model.ready = true;
    model.ledger = ledger.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "Your usage, in one place"));
    try testing.expectEqual(engine.Msg.open_dashboard, try press(tree, "History"));
}

test "CLI, JSON, and menu versions use the app manifest" {
    const version = @import("app_version").version;
    try testing.expectEqualStrings(version, cli.version);
    try testing.expectEqualStrings(version, main.app_version);
}

test "dashboard view exposes hero stats and attribution sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    model.now_ms = 20_643 * 86_400_000 + 12 * 3_600_000;
    try model.ledger.add(.{ .agent = .claude, .timestamp_ms = model.now_ms, .model = "claude-fable-5", .output_tokens = 1000, .cwd = "/tmp/token-tach" }, 42);
    try model.ledger.add(.{ .agent = .opencode, .timestamp_ms = model.now_ms, .model = "gpt-5.4", .output_tokens = 500 }, 3);
    @memcpy(model.claude_plan_buf[0..3], "max");
    model.claude_plan = model.claude_plan_buf[0..3];
    var ui = view.Ui.init(arena.allocator());
    const root = dashboard.rootView(&ui, &model);
    try testing.expect(!ui.failed);
    const tree = try ui.finalizeWithTokens(root, theme.tokens());
    for ([_][]const u8{ "TOKEN TACH / LEDGER", "API EQUIV", "PLAN VALUE", "30-DAY API-EQUIVALENT COST", "MODELS", "PROJECTS", "OPENCODE", "claude-fable-5", "token-tach" }) |text|
        try testing.expect(containsText(tree.root, text));
}

test "gauge scale ladder and needle pose" {
    try testing.expectEqual(@as(f64, 10_000), engine.gaugeScaleTpm(0));
    try testing.expectEqual(@as(f64, 10_000), engine.gaugeScaleTpm(8_000));
    try testing.expectEqual(@as(f64, 20_000), engine.gaugeScaleTpm(15_000));
    try testing.expectEqual(@as(f64, 50_000), engine.gaugeScaleTpm(40_000));
    try testing.expectEqual(@as(f64, 100_000), engine.gaugeScaleTpm(85_000));
    try testing.expectEqual(@as(f32, -120), engine.needleDeg(0, 10_000));
    try testing.expectEqual(@as(f32, 120), engine.needleDeg(10_000, 10_000));
    try testing.expectEqual(@as(f32, 120), engine.needleDeg(25_000, 10_000));
    try testing.expectEqual(@as(f32, 0), engine.needleDeg(5_000, 10_000));
}

test "fresh default tray names allowance and excludes disabled or expired observations" {
    var model = modelFixture();
    defer model.ledger.deinit();
    var buf: [128]u8 = undefined;
    const tray = @import("core/trayfmt.zig");
    try testing.expectEqualStrings("Claude Code 67%", tray.render(&buf, "{status}", engine.glanceState(&model)));
    model.cfg.sources = @import("core/config.zig").Sources.none;
    try testing.expect(presentation.glance(engine.presentationInput(&model)) == null);
    model.cfg.sources.enable(.claude);
    model.cfg.claude_oauth = false;
    try testing.expect(presentation.glance(engine.presentationInput(&model)) == null);
    model.cfg.claude_oauth = true;
    model.now_ms = 10_000_000;
    model.claude_limits.?.read_at_ms = model.now_ms;
    try testing.expect(presentation.glance(engine.presentationInput(&model)) == null);
}

test "archive-only source survives loss of statefile and daily totals preserve integers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    model.claude_limits = null;
    model.usage_summary.sources.getPtr(.claude).days[6].output_tokens = 16_777_217;
    var snapshot = presentation.snapshot(engine.presentationInput(&model));
    try testing.expectEqual(types.Agent.claude, snapshot.selected().?.harness);
    model.ux.popover_page = .days;
    const tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "16777217 tokens"));
}

test "session drill-down retains completed rows but hides disabled harnesses" {
    var model = modelFixture();
    defer model.ledger.deinit();
    model.now_ms = 2 * 86_400_000;
    for ([_]types.Agent{ .claude, .opencode }) |agent| {
        model.roster.record(.{ .agent = agent, .model = "example", .timestamp_ms = 1_000, .session_id = "old", .output_tokens = 1 }, 0);
    }
    model.cfg.sources = @import("core/config.zig").Sources.none;
    model.cfg.sources.enable(.claude);
    const snapshot = presentation.snapshot(engine.presentationInput(&model));
    var buffer: [32]*const @import("core/sessions.zig").Session = undefined;
    const rows = presentation.sessionRows(&snapshot, &buffer);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(types.Agent.claude, rows[0].agent);
    try testing.expectEqualStrings("No recent activity", presentation.activityLabel(rows[0], model.now_ms));
}

test "failed cached history still discloses its timezone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = modelFixture();
    defer model.ledger.deinit();
    model.summary_error = true;
    model.usage_summary.tz_offset_min = 330;
    const tree = try treeFor(arena.allocator(), &model);
    try testing.expect(containsText(tree.root, "Restart to retry"));
    try testing.expect(containsText(tree.root, "UTC offset 330"));
}
