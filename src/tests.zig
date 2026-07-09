const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const engine = @import("engine.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const ledger_mod = @import("core/ledger.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

// Pull in core-engine module tests (import-based discovery).
test {
    _ = @import("core/types.zig");
    _ = @import("core/config.zig");
    _ = @import("core/claude.zig");
    _ = @import("core/codex.zig");
    _ = @import("core/pricing.zig");
    _ = @import("core/oauth.zig");
    _ = @import("core/keychain.zig");
    _ = @import("core/ledger.zig");
    _ = @import("core/predict.zig");
    _ = @import("core/trayfmt.zig");
    _ = @import("engine.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var ui = AppUi.init(arena);
    const node = view.rootView(&ui, model);
    try testing.expect(!ui.failed);
    return ui.finalizeWithTokens(node, theme.tokens());
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findBySemanticsLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findBySemanticsLabel(child, label)) |found| return found;
    }
    return null;
}

fn containsText(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (containsText(child, needle)) return true;
    }
    return false;
}

const test_claude_windows = [_]types.LimitWindow{
    .{ .kind = .five_hour, .used_percent = 67, .resets_at_ms = 90 * 60_000 },
    .{ .kind = .weekly, .used_percent = 34, .resets_at_ms = 3 * 24 * 3_600_000 },
};
const test_codex_windows = [_]types.LimitWindow{
    .{ .kind = .five_hour, .used_percent = 9, .resets_at_ms = 60 * 60_000 },
};

fn instrumentedModel() Model {
    var model = Model{
        .today_text = "today $63.40 · 9.3M tok",
        .status_text = "142 events · 3 models priced",
        .now_ms = 10 * 60_000,
        .gauge_peak_tpm = 4_200,
        .needle_from_deg = -120,
        .needle_to_deg = engine.needleDeg(4_200, engine.gaugeScaleTpm(4_200)),
        // An initialized-but-empty ledger never allocates, so no deinit
        // is owed; the view reads real zeros instead of undefined memory.
        .ledger = ledger_mod.Ledger.init(testing.allocator, 0),
    };
    model.claude_limits = .{
        .agent = .claude,
        .read_at_ms = 0,
        .plan = "max",
        .windows = &test_claude_windows,
    };
    model.codex_limits = .{
        .agent = .codex,
        .read_at_ms = 0,
        .plan = "plus",
        .windows = &test_codex_windows,
    };
    return model;
}

test "the instrument cluster binds the engine's structured state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = instrumentedModel();
    const tree = try buildTree(arena, &model);

    // Status footer carries the engine status line verbatim.
    try testing.expect(findByText(tree.root, .status_bar, model.status_text) != null);
    // The odometer strip announces today's rollup (the a11y-snapshot
    // seam scripts/verify greps for "today $").
    try testing.expect(findBySemanticsLabel(tree.root, model.today_text) != null);
    // Both agent groups render with their limit windows.
    try testing.expect(containsText(tree.root, "CLAUDE"));
    try testing.expect(containsText(tree.root, "CODEX"));
    try testing.expect(containsText(tree.root, "67%"));
    try testing.expect(containsText(tree.root, "9%"));
    try testing.expect(containsText(tree.root, "5h"));
    try testing.expect(containsText(tree.root, "wk"));
    // Reset countdown for the 5h window (90 min from now_ms=10min).
    try testing.expect(containsText(tree.root, "1h20m"));
    // Dial furniture: unit caption and the sparkline caption.
    try testing.expect(containsText(tree.root, "tok/min ×1000"));
    try testing.expect(containsText(tree.root, "burn · last 15 min"));
}

test "a disabled source says so instead of showing dead bars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = instrumentedModel();
    model.cfg.sources = .{ .claude = false, .codex = true };
    const tree = try buildTree(arena_state.allocator(), &model);

    try testing.expect(containsText(tree.root, "disabled"));
    // Claude's limit rows are suppressed along with the fake totals…
    try testing.expect(!containsText(tree.root, "67%"));
    // …while the still-enabled codex group renders normally.
    try testing.expect(containsText(tree.root, "9%"));
}

test "an agent with no history and no limits says no sessions found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = instrumentedModel();
    model.claude_limits = null;
    model.codex_limits = null;
    const tree = try buildTree(arena_state.allocator(), &model);

    try testing.expect(containsText(tree.root, "no sessions found"));
    // No zero-totals line and no limit-data hint for an absent agent.
    try testing.expect(!containsText(tree.root, "0 · $0.00"));
    try testing.expect(!containsText(tree.root, "no limit data"));
}

test "catch-up renders a scanning treatment instead of confident zeros" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = instrumentedModel();
    model.claude_limits = null;
    model.codex_limits = null;
    model.catchup_active = true;
    model.status_text = "scanning history… 3/12 files";
    const tree = try buildTree(arena_state.allocator(), &model);

    // Both the dial readout and the empty agent rows say "scanning…".
    try testing.expect(containsText(tree.root, "scanning…"));
    try testing.expect(!containsText(tree.root, "no sessions found"));
}

test "stale oauth tags the claude group and mutes its bars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = instrumentedModel();
    // Last successful poll 7 minutes ago; threshold is 5.
    model.oauth_last_success_ms = model.now_ms - 7 * 60_000;
    const tree = try buildTree(arena_state.allocator(), &model);

    try testing.expect(containsText(tree.root, "stale 7m"));
    // The staleness warning replaces the plan nicety on the name row.
    try testing.expect(!containsText(tree.root, "max"));
    // The (dimmed) window rows still show the last known utilization.
    try testing.expect(containsText(tree.root, "67%"));
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const model = instrumentedModel();
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, view.window_width, view.window_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
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

test "the needle sweep animation replays the pose delta" {
    var model = instrumentedModel();
    model.needle_from_deg = -120;
    model.needle_to_deg = -20;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);

    var out: [96]canvas.CanvasRenderAnimation = undefined;
    const count = view.animations(&model, &tree, 1_000, &out);
    // Every needle part sweeps its shadow + fill command; no redline
    // pulse at these utilizations.
    try testing.expectEqual(view.needle_part_total * 2, count);
    try testing.expectEqual(@as(f32, -100), out[0].from_rotation.?);
    try testing.expectEqual(@as(f32, 0), out[0].to_rotation.?);
    try testing.expectEqual(view.gauge_cx, out[0].rotation_center.x);
    try testing.expectEqual(view.gauge_cy, out[0].rotation_center.y);

    // At rest (from == to) the needle declares no animation.
    model.needle_from_deg = model.needle_to_deg;
    try testing.expectEqual(@as(usize, 0), view.animations(&model, &tree, 1_000, &out));
}
