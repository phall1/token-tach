const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const cli = @import("cli.zig");
const engine = @import("engine.zig");
const view = @import("view.zig");
const dashboard = @import("dashboard.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const ledger_mod = @import("core/ledger.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

// Pull in core-engine module tests (import-based discovery).
test {
    _ = @import("core/types.zig");
    _ = @import("core/config.zig");
    _ = @import("core/cfcache.zig");
    _ = @import("core/dbgate.zig");
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
    _ = @import("core/predict.zig");
    _ = @import("core/alerts.zig");
    _ = @import("core/trayfmt.zig");
    _ = @import("core/system/system.zig");
    _ = @import("cli.zig");
    _ = @import("dashboard.zig");
    _ = @import("hud.zig");
    _ = @import("engine.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

/// Widget-node headroom for tests: `canvas_limits
/// .max_canvas_widget_nodes_per_view`, restated because the limits
/// module is runtime-internal and not reachable from the SDK's public
/// canvas namespace. A fixed 512 here used to make a tree the RUNTIME
/// would happily render overflow in-test, which is the wrong failure to
/// teach.
const max_nodes: usize = 1024;

/// `canvas_limits.max_canvas_commands_per_view`, restated for the same
/// reason.
const max_commands: usize = 2048;

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var ui = AppUi.init(arena);
    const node = view.rootView(&ui, model);
    try testing.expect(!ui.failed);
    return ui.finalizeWithTokens(node, theme.tokens());
}

fn buildDashboardTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var ui = AppUi.init(arena);
    const node = dashboard.rootView(&ui, model);
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

/// Charts carry their data in a generated semantics summary ("chart:
/// burn 119 pts last 0.00"), which is how a test asserts on what a trace
/// SAYS without reading pixels.
fn containsSemantics(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.semantics.label, needle) != null) return true;
    for (widget.children) |child| {
        if (containsSemantics(child, needle)) return true;
    }
    return false;
}

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var n: usize = if (widget.kind == kind) 1 else 0;
    for (widget.children) |child| n += countKind(child, kind);
    return n;
}

const Layout = struct {
    tree: canvas.WidgetLayoutTree,

    fn nodes(self: Layout) []const canvas.WidgetLayoutNode {
        return self.tree.nodes;
    }

    /// Resolved frame of the first widget whose semantics label starts
    /// with `prefix`. Semantics are the stable handle: they survive the
    /// text-formatting churn that would break a literal string match.
    fn frameOfSemanticsPrefix(self: Layout, prefix: []const u8) ?geometry.RectF {
        for (self.nodes()) |node| {
            if (std.mem.startsWith(u8, node.widget.semantics.label, prefix)) return node.frame;
        }
        return null;
    }

    fn frameOfText(self: Layout, text: []const u8) ?geometry.RectF {
        for (self.nodes()) |node| {
            if (std.mem.eql(u8, node.widget.text, text)) return node.frame;
        }
        return null;
    }
};

fn layoutTree(nodes: []canvas.WidgetLayoutNode, tree: AppUi.Tree) !Layout {
    const result = try canvas.layoutWidgetTree(
        tree.root,
        geometry.RectF.init(0, 0, view.window_width, view.window_height),
        nodes,
    );
    return .{ .tree = result };
}

const test_claude_windows = [_]types.LimitWindow{
    .{ .kind = .five_hour, .used_percent = 67, .resets_at_ms = 90 * 60_000 },
    .{ .kind = .weekly, .used_percent = 34, .resets_at_ms = 3 * 24 * 3_600_000 },
};
/// The four-window Claude account: `oauth.zig` maps five_hour, weekly,
/// weekly_opus and weekly_sonnet, and the shipped panel only ever looked
/// clean because the day it was screenshotted the server reported two.
const test_claude_windows_full = [_]types.LimitWindow{
    .{ .kind = .five_hour, .used_percent = 67, .resets_at_ms = 90 * 60_000 },
    .{ .kind = .weekly, .used_percent = 34, .resets_at_ms = 3 * 24 * 3_600_000 },
    .{ .kind = .weekly_opus, .used_percent = 12, .resets_at_ms = 3 * 24 * 3_600_000 },
    .{ .kind = .weekly_sonnet, .used_percent = 51, .resets_at_ms = 3 * 24 * 3_600_000 },
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
    try testing.expect(containsText(tree.root, "OTHERS"));
    try testing.expect(containsText(tree.root, "67%"));
    try testing.expect(containsText(tree.root, "9%"));
    try testing.expect(containsText(tree.root, "5h"));
    try testing.expect(containsText(tree.root, "wk"));
    // Reset countdown for the 5h window (90 min from now_ms=10min).
    try testing.expect(containsText(tree.root, "1h20m"));
    // Dial furniture: the scale legend (which carries BOTH endpoints,
    // since the extreme numerals are not printed) and the trace caption.
    try testing.expect(containsText(tree.root, "0–10k tok/min"));
    try testing.expect(containsText(tree.root, "BURN · 20 MIN"));
    // The trip meter shares the odometer strip with the all-time count.
    try testing.expect(containsText(tree.root, "TRIP"));
    // The MFD offers its three pages, and the default is the fleet.
    try testing.expect(containsText(tree.root, "AGENTS"));
    try testing.expect(containsText(tree.root, "SESSIONS"));
    try testing.expect(containsText(tree.root, "SCOPE"));
}

test "the telltale row prints the lamps that qualify the panel and hides the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    const calm = try buildTree(arena, &model);
    // Three lamps are printed dark always — they are the ones that
    // qualify what the rest of the panel is claiming.
    try testing.expect(containsText(calm.root, "WALL"));
    try testing.expect(containsText(calm.root, "STL"));
    try testing.expect(containsText(calm.root, "SRC"));
    try testing.expect(findBySemanticsLabel(calm.root, "source error telltale off") != null);
    try testing.expect(findBySemanticsLabel(calm.root, "limit wall projected telltale off") != null);
    // The conditional lamps are absent entirely at rest: seven cryptic
    // acronyms competing with the wordmark bought a row of noise to say
    // nothing, and each of these is already reported elsewhere (the live
    // lamp for redline, the telemetry strip for load and battery).
    try testing.expect(findBySemanticsLabel(calm.root, "redline telltale off") == null);
    try testing.expect(findBySemanticsLabel(calm.root, "machine load telltale off") == null);
    try testing.expect(findBySemanticsLabel(calm.root, "battery low telltale off") == null);
    try testing.expect(!containsText(calm.root, "ALRT"));

    // A failing source lights SRC; a stale OAuth reading lights STL.
    model.status_error = true;
    model.oauth_last_success_ms = model.now_ms - 7 * 60_000;
    const lit = try buildTree(arena, &model);
    try testing.expect(findBySemanticsLabel(lit.root, "source error telltale on") != null);
    try testing.expect(findBySemanticsLabel(lit.root, "stale limit reading telltale on") != null);

    // A lamp that fires appears; it does not merely change colour.
    model.system_snap = .{ .mem = .{ .used_bytes = 50, .total_bytes = 51, .used_frac = 0.98, .pressure = .critical } };
    const loaded = try buildTree(arena, &model);
    try testing.expect(findBySemanticsLabel(loaded.root, "machine load telltale on") != null);
    try testing.expect(containsText(loaded.root, "LOAD"));
}

test "the limits region cannot overlap at four claude windows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.claude_limits = .{
        .agent = .claude,
        .read_at_ms = 0,
        .plan = "max",
        .windows = &test_claude_windows_full,
    };

    // The two right-hand panels are derived, so they cannot collide and
    // the fleet display always keeps usable height.
    const layout = view.rightLayout(&model);
    try testing.expect(layout.limits.y + layout.limits.height <= layout.mfd.y);
    try testing.expect(layout.mfd.height >= 120);

    const tree = try buildTree(arena, &model);
    // All four windows render...
    try testing.expect(containsText(tree.root, "opus"));
    try testing.expect(containsText(tree.root, "son"));
    try testing.expect(containsText(tree.root, "51%"));

    var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
    const laid = try layoutTree(&nodes, tree);
    // ...and the aggregate row sits strictly BELOW the last of them,
    // which is the bug this replaces: a hardcoded y drew OTHERS through
    // the fourth bar the moment a fourth window existed.
    const others = laid.frameOfSemanticsPrefix("Other agents").?;
    const sonnet = laid.frameOfText("son").?;
    try testing.expect(others.y >= sonnet.y + sonnet.height);
    // The fleet display starts below the aggregate row, never over it.
    const fleet = laid.frameOfSemanticsPrefix("Fleet display").?;
    try testing.expect(fleet.y >= others.y + others.height);
}

test "no dial numeral can reach the burn readout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.gauge_peak_tpm = 27_500;
    model.needle_to_deg = engine.needleDeg(27_500, engine.gaugeScaleTpm(27_500));
    model.needle_from_deg = model.needle_to_deg;

    const tree = try buildTree(arena, &model);
    var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
    const laid = try layoutTree(&nodes, tree);

    // At a 240° sweep the two extreme graduations land BELOW the pivot,
    // which is where the readout lives — the shipped panel drew "0
    // 27.5k 50" as one line of three numbers, with the red full-scale
    // glyph reading as a redline annotation on the burn rate. Four
    // numerals are printed, all of them clear above the window.
    var printed: usize = 0;
    for (laid.nodes()) |node| {
        if (!std.mem.startsWith(u8, node.widget.semantics.label, "graduation ")) continue;
        printed += 1;
        try testing.expect(node.frame.y + node.frame.height <= view.readout_window.y);
    }
    try testing.expectEqual(@as(usize, 4), printed);

    // The endpoints the numerals no longer carry come back as words,
    // below the window where nothing can be read into the burn number.
    const legend = laid.frameOfSemanticsPrefix("dial scale").?;
    try testing.expect(legend.y >= view.readout_window.y + view.readout_window.height);
    try testing.expect(containsText(tree.root, "0–50k tok/min"));
}

test "the fleet display fills its panel with one agent burning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The common case, not the four-agent case: one agent, one session.
    var model = instrumentedModel();
    model.now_ms = 60 * 60_000;
    model.roster.record(.{
        .agent = .claude,
        .timestamp_ms = model.now_ms - 30_000,
        .model = "claude-fable-5",
        .session_id = "s-alpha",
        .cwd = "/w/token-tach",
        .output_tokens = 1_000,
    }, 0.5);
    model.agent_burn.addTokens(.claude, model.now_ms - 60_000, 10_000);

    const tree = try buildTree(arena, &model);
    // The leftover height breaks the selected row down instead of
    // rendering 190pt of black: its live sessions over a wider trace.
    try testing.expect(containsText(tree.root, "LIVE SESSIONS"));
    try testing.expect(containsText(tree.root, "token-tach"));
    try testing.expect(containsText(tree.root, "claude-fable-5"));
    try testing.expect(containsText(tree.root, "BURN · 15 MIN"));

    var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
    const laid = try layoutTree(&nodes, tree);
    const panel = laid.frameOfSemanticsPrefix("Fleet display").?;
    // Whatever the block drew, it stayed inside the panel.
    var lowest: f32 = panel.y;
    for (laid.nodes()) |node| {
        if (node.frame.x < panel.x or node.frame.x > panel.x + panel.width) continue;
        if (node.frame.y < panel.y or node.frame.y + node.frame.height > panel.y + panel.height) continue;
        lowest = @max(lowest, node.frame.y + node.frame.height);
    }
    // ...and it reached most of the way down: an MFD that is mostly
    // black on the common case is worse than a smaller MFD.
    try testing.expect(lowest >= panel.y + panel.height * 0.85);

    // Four agents leave nothing over, and the block simply is not there.
    var busy = instrumentedModel();
    busy.now_ms = 60 * 60_000;
    for ([_]types.Agent{ .claude, .codex, .opencode, .gemini }, 0..) |agent, i| {
        busy.roster.record(.{
            .agent = agent,
            .timestamp_ms = busy.now_ms - 30_000,
            .model = "m",
            .session_id = &[_]u8{ 's', @intCast('a' + i) },
            .cwd = "/w/p",
            .output_tokens = 1_000,
        }, 0.5);
        busy.agent_burn.addTokens(agent, busy.now_ms - 60_000, 10_000);
    }
    const busy_tree = try buildTree(arena, &busy);
    try testing.expect(!containsText(busy_tree.root, "BURN · 15 MIN"));
}

test "the burn trace reads empty after a long idle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    const burst_ms: i64 = 60 * 60_000;
    model.agent_burn.addTokens(.claude, burst_ms, 50_000);

    // Fifteen seconds later the burst is the newest complete bucket.
    model.now_ms = burst_ms + 15_000;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(!containsSemantics(tree.root, "burn 119 pts last 0.00"));
    }

    // Forty-five minutes later NOTHING has happened, and the trace must
    // say so even though nobody advanced the ring: the view anchors the
    // read on its own clock, so the last burst cannot stay pinned to the
    // right edge under a "20 min" caption while the number reads zero.
    model.now_ms = burst_ms + 45 * 60_000;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(containsSemantics(tree.root, "burn 119 pts last 0.00"));
    }
}

test "the fleet display lists running sessions before idle ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.now_ms = 60 * 60_000;
    model.ux.mfd_page = .sessions;
    // "beta" landed a turn twenty minutes ago: alive, but idle.
    model.roster.record(.{
        .agent = .codex,
        .timestamp_ms = model.now_ms - 20 * 60_000,
        .model = "gpt-5.2-codex",
        .session_id = "s-beta",
        .cwd = "/w/beta",
        .output_tokens = 100,
    }, 0.10);
    // "alpha" landed one thirty seconds ago: running.
    model.roster.record(.{
        .agent = .claude,
        .timestamp_ms = model.now_ms - 30_000,
        .model = "claude-fable-5",
        .session_id = "s-alpha",
        .cwd = "/w/alpha",
        .output_tokens = 1_000,
    }, 0.50);

    const tree = try buildTree(arena, &model);
    try testing.expect(containsText(tree.root, "alpha"));
    try testing.expect(containsText(tree.root, "beta"));

    var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
    const laid = try layoutTree(&nodes, tree);
    const running = laid.frameOfSemanticsPrefix("CLAUDE · claude-fable-5").?;
    const idle = laid.frameOfSemanticsPrefix("CODEX · gpt-5.2-codex").?;
    try testing.expect(running.y < idle.y);

    // The agents page rolls the same fleet up per agent.
    model.ux.mfd_page = .burn;
    const agents = try buildTree(arena, &model);
    try testing.expect(containsText(agents.root, "CLAUDE"));
    try testing.expect(containsText(agents.root, "CODEX"));
}

test "the dial readout cycles through rate, today, trip and eta" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.trip_start_ms = model.now_ms - 9 * 60_000;
    model.trip.cost_usd = 12.5;

    // Rate: the burn number and the reset/wall line under it.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findBySemanticsLabel(tree.root, "cycle readout: rate, today, trip, eta") != null);
        try testing.expect(containsText(tree.root, "resets 50m"));
    }

    // Trip: the since-launch spend and its hourly rate.
    engine.applyUxMsg(&model, .readout_cycle); // → today
    engine.applyUxMsg(&model, .readout_cycle); // → trip
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(containsText(tree.root, "$12.50"));
        try testing.expect(containsText(tree.root, "/hr"));
    }
}

test "system strip renders enabled readings and hides absent modules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.system_snap = .{
        .cpu = .{ .total_frac = 0.43, .core_count = 14, .load_avg_1m = 3.2, .p_cluster_frac = null, .e_cluster_frac = null },
        .gpu = .{ .device_utilization = 0.12 },
        .mem = .{ .used_bytes = 40_000_000_000, .total_bytes = 51_500_000_000, .used_frac = 0.777, .pressure = .warn },
        .disk = .{ .total_bytes = 994_000_000_000, .free_bytes = 186_000_000_000, .used_fraction = 0.81 },
        .net = .{ .total_bytes_in = 0, .total_bytes_out = 0, .in_bytes_per_sec = 1_230_000, .out_bytes_per_sec = 88_000 },
        // battery deliberately null: the cell must not exist.
        .net_meter_frac = 0.4,
    };
    const tree = try buildTree(arena, &model);

    try testing.expect(findBySemanticsLabel(tree.root, "System telemetry") != null);
    try testing.expect(containsText(tree.root, "CPU"));
    try testing.expect(containsText(tree.root, "43%"));
    try testing.expect(containsText(tree.root, "GPU"));
    try testing.expect(containsText(tree.root, "12%"));
    try testing.expect(containsText(tree.root, "MEM"));
    try testing.expect(containsText(tree.root, "78%"));
    try testing.expect(containsText(tree.root, "DISK"));
    try testing.expect(containsText(tree.root, "186G"));
    try testing.expect(containsText(tree.root, "NET"));
    try testing.expect(containsText(tree.root, "↓1.2M ↑88k"));
    // Nothing has been recorded yet, so the traces draw nothing rather
    // than a flat line along zero under a live "43%".
    try testing.expect(containsSemantics(tree.root, "CPU empty"));
    // The absent battery cell exists nowhere (the BAT TELLTALE in
    // the header is a different thing and always renders).
    try testing.expect(findBySemanticsLabel(tree.root, "BAT telemetry") == null);
    try testing.expect(findBySemanticsLabel(tree.root, "CPU telemetry") != null);
}

test "telemetry cells trace their own five-minute history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.now_ms = 30 * 60_000;
    model.system_snap = .{
        .cpu = .{ .total_frac = 0.43, .core_count = 14, .load_avg_1m = 3.2, .p_cluster_frac = null, .e_cluster_frac = null },
    };
    // Five minutes of samples on the wall clock the strip reads from.
    var t: i64 = model.now_ms - 5 * 60_000;
    while (t <= model.now_ms) : (t += engine.SystemHistory.period_ms) {
        model.system_history.record(t, .{ .cpu = .{
            .total_frac = 0.5,
            .core_count = 14,
            .load_avg_1m = 3.2,
            .p_cluster_frac = null,
            .e_cluster_frac = null,
        } });
    }

    const tree = try buildTree(arena, &model);
    try testing.expect(containsSemantics(tree.root, "CPU 60 pts"));
    try testing.expect(!containsSemantics(tree.root, "CPU empty"));

    // The same history, half an hour of silence later: the ring was
    // never advanced, and the trace must still scroll to nothing instead
    // of pinning the last sample under the reading.
    //
    // "Nothing" is now drawn as nothing. This used to assert
    // "CPU 60 pts last 0.00" — 60 points of flat zero, because the
    // sample-and-hold seeded its accumulator at 0 and no bucket in the
    // window ever overwrote it. A flat line along 0% is not the absence
    // of a reading, it is a reading of zero, and it is the one claim this
    // strip must never make about a machine it has not looked at. Same
    // route as a module the sampler has never answered for.
    model.now_ms += 40 * 60_000;
    const stale = try buildTree(arena, &model);
    try testing.expect(containsSemantics(stale.root, "CPU empty"));
    try testing.expect(!containsSemantics(stale.root, "CPU 60 pts"));
}

test "hovering a system cell reveals its full reading in the footer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.system_snap = .{
        .cpu = .{ .total_frac = 0.43, .core_count = 14, .load_avg_1m = 3.25, .p_cluster_frac = 0.64, .e_cluster_frac = 1.0 },
    };

    // Not hovering: the footer shows the engine status line.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByText(tree.root, .status_bar, model.status_text) != null);
    }

    // Hovering CPU: the footer becomes the full CPU readout (cores, load,
    // P/E cluster split) that the compact strip can't show at a glance.
    model.hovered_system = .cpu;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(containsText(tree.root, "14 cores"));
        try testing.expect(containsText(tree.root, "load 3.25"));
        try testing.expect(containsText(tree.root, "P 64% E 100%"));
    }

    // Hovering a cell whose reading has vanished falls back to the status
    // line rather than rendering nothing.
    model.hovered_system = .battery;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByText(tree.root, .status_bar, model.status_text) != null);
    }
}

test "battery cell renders charge, charging label, and low-charge ink" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Charging on AC: the label carries the + and the value the charge.
    var model = instrumentedModel();
    model.system_snap = .{
        .battery = .{ .charge = 0.87, .charging = true, .on_ac = true, .minutes_to_full = 42 },
    };
    const tree = try buildTree(arena, &model);
    try testing.expect(containsText(tree.root, "BAT+"));
    try testing.expect(containsText(tree.root, "87%"));

    // Discharging at 12%: plain label, and the reading still renders
    // (ink thresholds are style, not structure — presence is the test).
    var low = instrumentedModel();
    low.system_snap = .{
        .battery = .{ .charge = 0.12, .charging = false, .on_ac = false, .minutes_to_empty = 95 },
    };
    const low_tree = try buildTree(arena, &low);
    try testing.expect(!containsText(low_tree.root, "BAT+"));
    try testing.expect(containsText(low_tree.root, "12%"));
    // A low battery on battery power also lights the header telltale.
    try testing.expect(findBySemanticsLabel(low_tree.root, "battery low telltale on") != null);
}

test "system strip disappears entirely when config disables it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    model.cfg.system_stats = @import("core/config.zig").SystemStats.none;
    model.system_snap = .{ .gpu = .{ .device_utilization = 0.5 } };
    const tree = try buildTree(arena, &model);
    try testing.expect(findBySemanticsLabel(tree.root, "System telemetry") == null);
}

test "dashboard view exposes hero stats and attribution sections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = instrumentedModel();
    defer model.ledger.deinit();
    model.now_ms = 20_643 * 86_400_000 + 12 * 3_600_000;
    try model.ledger.add(.{
        .agent = .claude,
        .timestamp_ms = model.now_ms,
        .model = "claude-fable-5",
        .output_tokens = 1_000,
        .cwd = "/tmp/token-tach",
    }, 42.0);
    // A second agent so the dynamic AGENT/SHARE card renders >1 row.
    try model.ledger.add(.{
        .agent = .opencode,
        .timestamp_ms = model.now_ms,
        .model = "gpt-5.4",
        .output_tokens = 500,
    }, 3.0);
    @memcpy(model.claude_plan_buf[0..3], "max");
    model.claude_plan = model.claude_plan_buf[0..3];

    const tree = try buildDashboardTree(arena, &model);
    try testing.expect(containsText(tree.root, "TOKEN TACH / LEDGER"));
    // Both KPI labels were shortened ("API EQUIVALENT", "SUBSCRIPTION
    // VALUE") because neither fit its own card at the 820pt window
    // floor; dashboard.zig now holds every label and caption on this
    // row to the narrowest card the floor can produce.
    try testing.expect(containsText(tree.root, "API EQUIV"));
    try testing.expect(containsText(tree.root, "PLAN VALUE"));
    try testing.expect(containsText(tree.root, "30-DAY API-EQUIVALENT COST"));
    try testing.expect(containsText(tree.root, "MODELS"));
    try testing.expect(containsText(tree.root, "PROJECTS"));
    try testing.expect(containsText(tree.root, "OPENCODE"));
    try testing.expect(containsText(tree.root, "claude-fable-5"));
    try testing.expect(containsText(tree.root, "token-tach"));
}

test "a disabled source says so instead of showing dead bars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = instrumentedModel();
    model.cfg.sources = blk: {
        var s = @import("core/config.zig").Sources.none;
        s.enable(.codex);
        break :blk s;
    };
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

    const arena = arena_state.allocator();
    var model = instrumentedModel();
    model.claude_limits = null;
    model.codex_limits = null;
    model.catchup_active = true;
    model.catchup_queue = &.{};
    model.catchup_next = 0;
    model.status_text = "scanning history… 3/12 files";
    const tree = try buildTree(arena, &model);

    // Both the dial readout and the empty agent rows say "scanning…".
    try testing.expect(containsText(tree.root, "scanning…"));
    try testing.expect(!containsText(tree.root, "no sessions found"));
    // The fleet display says the same thing in its own words rather than
    // stranding one muted line at the top of a black rectangle.
    try testing.expect(containsText(tree.root, "reading history"));
    try testing.expect(containsText(tree.root, "0 of 0 files"));

    var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
    const laid = try layoutTree(&nodes, tree);
    // The scanning treatment lives INSIDE the readout window — the frame
    // that makes the burn number an instrument has to hold the "not yet"
    // state too, or catch-up reads as a rendering failure.
    // A live spinner is part of that treatment: an indeterminate mark
    // over a determinate bar is what makes catch-up read as busy rather
    // than as broken, and a widget kind that silently renders nothing
    // would leave the well emptier than the dash it replaced.
    try testing.expect(countKind(tree.root, .spinner) == 1);
    const scanning = laid.frameOfSemanticsPrefix("readout scanning").?;
    const window = view.readout_window;
    try testing.expect(scanning.y >= window.y);
    try testing.expect(scanning.y + scanning.height <= window.y + window.height);
    // A frame with no burn recorded must not draw a confident accent
    // rule across the trace band: the lane goes muted.
    try testing.expect(containsSemantics(tree.root, "burn 119 pts last 0.00"));
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

test "the view lays out inside the runtime's widget-node budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The worst frame the popover can build: mid-ignition (every LED
    // drawn lit OVER its unlit base), four limit windows per agent, and
    // a full telemetry strip.
    var model = instrumentedModel();
    model.ignition_phase = .up;
    model.ignition_t0_ms = 5_000;
    model.claude_limits = .{
        .agent = .claude,
        .read_at_ms = 0,
        .plan = "max",
        .windows = &test_claude_windows_full,
    };
    model.codex_limits = .{
        .agent = .codex,
        .read_at_ms = 0,
        .plan = "plus",
        .windows = &test_claude_windows_full,
    };
    model.system_snap = .{
        .cpu = .{ .total_frac = 0.43, .core_count = 14, .load_avg_1m = 3.2, .p_cluster_frac = null, .e_cluster_frac = null },
        .gpu = .{ .device_utilization = 0.12 },
        .mem = .{ .used_bytes = 40_000_000_000, .total_bytes = 51_500_000_000, .used_frac = 0.777, .pressure = .warn },
        .disk = .{ .total_bytes = 994_000_000_000, .free_bytes = 186_000_000_000, .used_fraction = 0.81 },
        .net = .{ .total_bytes_in = 0, .total_bytes_out = 0, .in_bytes_per_sec = 1_230_000, .out_bytes_per_sec = 88_000 },
        .battery = .{ .charge = 0.87, .charging = true, .on_ac = true },
    };

    // ...with a busy fleet behind whichever MFD page is showing.
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        model.roster.record(.{
            .agent = if (i % 2 == 0) .claude else .codex,
            .timestamp_ms = model.now_ms - @as(i64, @intCast(i)) * 1_000,
            .model = "claude-fable-5",
            .session_id = &[_]u8{ 's', @intCast('a' + i) },
            .cwd = "/w/project",
            .output_tokens = 1_000,
        }, 0.5);
        model.agent_burn.addTokens(if (i % 2 == 0) .claude else .codex, model.now_ms - 30_000, 10_000);
    }

    for ([_]engine.MfdPage{ .burn, .sessions, .telemetry }) |page| {
        model.ux.mfd_page = page;
        const tree = try buildTree(arena, &model);
        var nodes: [max_nodes]canvas.WidgetLayoutNode = undefined;
        const laid = try layoutTree(&nodes, tree);
        try testing.expect(laid.nodes().len > 0);
        // Exceeding either cap fails the frame at RUNTIME, not at
        // compile time, so the budget is a test or it is nothing.
        try testing.expect(laid.nodes().len <= max_nodes);

        // The same frame's DRAW commands, chrome included.
        var commands: [max_commands]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try view.buildChrome(&model, &builder, .{ .width = view.window_width, .height = view.window_height }, theme.tokens());
        try canvas.emitWidgetLayout(&builder, laid.tree, theme.tokens());
        try testing.expect(builder.displayList().commandCount() <= max_commands);
    }
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

/// Rotation animations are the needle; opacity animations are lamps.
/// Counting them by channel keeps these tests honest about STRUCTURE
/// while leaving the view free to add lamps.
fn countRotations(out: []const canvas.CanvasRenderAnimation) usize {
    var n: usize = 0;
    for (out) |anim| {
        if (anim.from_rotation != null) n += 1;
    }
    return n;
}

fn countOpacity(out: []const canvas.CanvasRenderAnimation) usize {
    var n: usize = 0;
    for (out) |anim| {
        if (anim.from_opacity != null) n += 1;
    }
    return n;
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
    // no redline pulse and no live pips at these (idle) readings.
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
    try testing.expectEqual(@as(usize, 3), countRotations(out[0..count]));
    try testing.expect(countOpacity(out[0..count]) >= 56 * 4);
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

test "CLI, JSON, and menu versions use the app manifest" {
    const version = @import("app_version").version;
    try testing.expectEqualStrings(version, cli.version);
    try testing.expectEqualStrings(version, main.app_version);
}
