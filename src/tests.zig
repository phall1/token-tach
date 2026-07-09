const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const engine = @import("engine.zig");

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

const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        // Name the app.native position instead of leaving a bare error
        // trace: the usual causes are a binding without a matching
        // Model field or an on-* message without a Msg arm.
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

test "the dashboard view binds every engine display string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{
        .glance_text = "⚡ 4.2k/m → wall 3:40p",
        .claude_text = "claude  8.2M tok · $63.40 · 5h 67%",
        .codex_text = "codex  1.1M tok · $0.00 · 5h 9%",
        .today_text = "today $63.40 · 9.3M tok",
        .status_text = "142 events · 3 models priced",
    };

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, model.glance_text);
    _ = try expectByText(tree.root, .text, model.claude_text);
    _ = try expectByText(tree.root, .text, model.codex_text);
    _ = try expectByText(tree.root, .text, model.today_text);
    _ = try expectByText(tree.root, .status_bar, model.status_text);
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{ .glance_text = "idle" };
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 520, 340), &nodes);
    try testing.expect(layout.nodes.len > 0);
}
