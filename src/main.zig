//! token-tach: a menu-bar tachometer for AI coding-agent token usage.
//! The engine (Model/Msg/boot/update) lives in `engine.zig`; the
//! instrument-cluster canvas view in `view.zig` (theme in `theme.zig`);
//! the UI-free core under `core/`. This file is shell wiring: window
//! scene, permissions, the status-item glance, and the runtime entry
//! point.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const engine = @import("engine.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const trayfmt = @import("core/trayfmt.zig");

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const update = engine.update;
pub const boot = engine.boot;

const canvas_label = "main-canvas";
const window_width: f32 = view.window_width;
const window_height: f32 = view.window_height;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_network,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Token usage dashboard", .accessibility_label = "Token Tach", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Token Tach",
    .width = window_width,
    .height = window_height,
    // Popover-hosted instrument: fixed size, no chrome, no dead resize
    // handles. Kept in lockstep with app.zon.
    .titlebar = .chromeless,
    .resizable = false,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);

const TachApp = native_sdk.UiApp(Model, Msg);

/// The menu-bar glance: title is the trayfmt-rendered hero line, the
/// dropdown mirrors the dashboard's per-agent and today lines. Rendered
/// from the model after every dispatch; the runtime patches only what
/// changed.
fn statusItem(model: *const Model, scratch: *TachApp.StatusItemScratch) TachApp.StatusItemState {
    const title = trayfmt.render(&scratch.title_buffer, model.cfg.tray_format, engine.glanceState(model));
    scratch.items[0] = .{ .id = 1, .label = model.claude_text, .enabled = false };
    scratch.items[1] = .{ .id = 2, .label = model.codex_text, .enabled = false };
    scratch.items[2] = .{ .id = 3, .separator = true };
    scratch.items[3] = .{ .id = 4, .label = model.today_text, .enabled = false };
    return .{ .title = title, .items = scratch.items[0..4] };
}

/// Shell commands → display Msgs: the popover-open notification keys
/// the ignition sweep (the rest of the tray traffic stays unmapped).
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "tray.popover_opened")) return .popover_opened;
    return null;
}

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try TachApp.create(std.heap.page_allocator, .{
        .name = "token-tach",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        // Static options carry the popover binding (tray click toggles an
        // NSPopover hosting the "main" window); the fn derives title+menu.
        .status_item = .{ .popover_window = "main" },
        .status_item_fn = statusItem,
        .view = view.rootView,
        .tokens = theme.tokens(),
        .animations = view.animations,
        // Raw display-list chrome around the widget span: gradient
        // bezels + shaded dial face under the widgets, the machined
        // needle blade + glass glare over them (real vector paths — the
        // rotation-true primitive the widget grammar lacks).
        .chrome = .{
            .prefix_commands = view.chrome_prefix_commands,
            .suffix_commands = view.chrome_suffix_commands,
            .build = view.buildChrome,
        },
        .on_command = onCommand,
    });
    defer app_state.destroy();

    engine.setup(&app_state.model, std.heap.page_allocator, .{
        .home = init.environ_map.get("HOME") orelse "",
        .claude_config_dir = init.environ_map.get("CLAUDE_CONFIG_DIR"),
        .codex_home = init.environ_map.get("CODEX_HOME"),
        .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
    }) catch |err| {
        std.log.err("engine setup failed: {s} — running with empty state", .{@errorName(err)});
    };

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "token-tach",
        .window_title = "Token Tach",
        .bundle_id = "dev.native_sdk.token-tach",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
