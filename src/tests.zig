const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

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
}

const canvas = native_sdk.canvas;
const testing = std.testing;

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

/// A miss fails the test with the mismatch spelled out instead of a
/// null-unwrap panic: the usual cause is app.native and this test
/// drifting apart after an edit.
fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

test "clicking the buttons drives the model through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();

    var tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "0");
    _ = try expectByText(tree.root, .status_bar, "count: 0");

    // Click "+": the count increments and the view rebuilds with the
    // new value, keeping widget ids stable.
    const plus = try expectByText(tree.root, .button, "+");
    main.update(&model, tree.msgForPointer(plus.id, .up).?);
    try testing.expectEqual(@as(i64, 1), model.count);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "1");
    _ = try expectByText(tree.root, .status_bar, "count: 1");
    try testing.expectEqual(plus.id, (try expectByText(tree.root, .button, "+")).id);

    // Click "-" twice: the count goes negative.
    const minus = try expectByText(tree.root, .button, "-");
    main.update(&model, tree.msgForPointer(minus.id, .up).?);
    main.update(&model, tree.msgForPointer(minus.id, .up).?);
    try testing.expectEqual(@as(i64, -1), model.count);

    // Click "Reset": back to zero.
    tree = try buildTree(arena, &model);
    const reset = try expectByText(tree.root, .button, "Reset");
    main.update(&model, tree.msgForPointer(reset.id, .up).?);
    try testing.expectEqual(@as(i64, 0), model.count);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .status_bar, "count: 0");
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 480, 320), &nodes);
    try testing.expect(layout.nodes.len > 0);

    const plus = try expectByText(tree.root, .button, "+");
    var saw_button = false;
    for (layout.nodes) |node| {
        if (node.widget.id == plus.id) saw_button = true;
    }
    try testing.expect(saw_button);
}
