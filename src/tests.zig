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
    _ = @import("core/statefile.zig");
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

    var out: [512]canvas.CanvasRenderAnimation = undefined;
    const count = view.animations(&model, &tree, 1_000, &out);
    // The three chrome needle commands (blade, edge, tip glow) sweep;
    // no redline pulse at these utilizations.
    try testing.expectEqual(view.needle_command_ids.len, count);
    try testing.expectEqual(view.needle_blade_id, out[0].id);
    try testing.expectEqual(@as(f32, -100), out[0].from_rotation.?);
    try testing.expectEqual(@as(f32, 0), out[0].to_rotation.?);
    try testing.expectEqual(view.gauge_cx, out[0].rotation_center.x);
    try testing.expectEqual(view.gauge_cy, out[0].rotation_center.y);

    // At rest (from == to) the needle declares no animation.
    model.needle_from_deg = model.needle_to_deg;
    try testing.expectEqual(@as(usize, 0), view.animations(&model, &tree, 1_000, &out));
}

test "the ignition sweep anchors both phases on the journaled key-on time" {
    var model = instrumentedModel();
    model.needle_from_deg = model.needle_to_deg; // at rest — ignition still sweeps
    model.ignition_phase = .up;
    model.ignition_t0_ms = 5_000;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);

    var out: [512]canvas.CanvasRenderAnimation = undefined;
    var count = view.animations(&model, &tree, 999_999, &out);
    // Needle (3 chrome commands) + every LED's dot+glow shadow/fill
    // opacity pops (56 x 4).
    try testing.expectEqual(@as(usize, 3 + 56 * 4), count);
    const t0_ns: u64 = 5_000 * std.time.ns_per_ms;
    // Phase up: 0-mark → full scale, anchored at key-on (NOT at the
    // frame timestamp passed in — idempotent re-declaration).
    try testing.expectEqual(t0_ns, out[0].start_ns);
    try testing.expectEqual(@as(f32, -120) - model.needle_to_deg, out[0].from_rotation.?);
    try testing.expectEqual(@as(f32, 120) - model.needle_to_deg, out[0].to_rotation.?);
    // The first LED pops in at key-on with the needle at the 0 mark.
    try testing.expectEqual(t0_ns, out[3].start_ns);
    try testing.expectEqual(@as(f32, 0), out[3].from_opacity.?);
    try testing.expectEqual(@as(f32, 1), out[3].to_opacity.?);

    // Phase settle: full scale → truth, anchored at key-on + up phase;
    // only the overshoot LEDs (above the true pose) fade back out.
    model.ignition_phase = .settle;
    count = view.animations(&model, &tree, 999_999, &out);
    try testing.expect(count >= 3);
    try testing.expectEqual(t0_ns + @as(u64, engine.ignition_up_ms) * std.time.ns_per_ms, out[0].start_ns);
    try testing.expectEqual(@as(f32, 120) - model.needle_to_deg, out[0].from_rotation.?);
    try testing.expectEqual(@as(f32, 0), out[0].to_rotation.?);
    if (count > 3) {
        try testing.expectEqual(@as(f32, 1), out[3].from_opacity.?);
        try testing.expectEqual(@as(f32, 0), out[3].to_opacity.?);
    }
}

test "the chrome display list emits exactly its declared command counts" {
    const model = instrumentedModel();
    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try view.buildChrome(&model, &builder, .{ .width = view.window_width, .height = view.window_height }, theme.tokens());
    try testing.expectEqual(
        view.chrome_prefix_commands + view.chrome_suffix_commands,
        builder.displayList().commandCount(),
    );
    // The needle blade command exists and is a real path (the
    // rotation-true primitive), not a rect.
    var found_blade = false;
    for (builder.displayList().commands) |command| {
        if (command == .fill_path and command.fill_path.id == view.needle_blade_id) found_blade = true;
    }
    try testing.expect(found_blade);
}
