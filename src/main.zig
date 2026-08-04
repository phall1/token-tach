//! token-tach: a menu-bar tachometer for AI coding-agent token usage.
//! The engine (Model/Msg/boot/update) lives in `engine.zig`; the
//! instrument-cluster canvas view in `view.zig` (theme in `theme.zig`);
//! the UI-free core under `core/`. This file is shell wiring: window
//! scene, permissions, the status-item glance, and the runtime entry
//! point.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const updater_options = @import("updater_options");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const engine = @import("engine.zig");
const view = @import("view.zig");
const dashboard = @import("dashboard.zig");
const cli = @import("cli.zig");
const theme = @import("theme.zig");
const trayfmt = @import("core/trayfmt.zig");

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const update = engine.update;
pub const boot = engine.boot;

const canvas_label = "main-canvas";
const window_width: f32 = view.window_width;
const window_height: f32 = view.window_height;

// The engine retains tens of thousands of small paths, dedup keys, and
// rollup entries. page_allocator maps each allocation separately on macOS;
// the pooled SMP allocator keeps that long-lived state compact.
const app_allocator = std.heap.smp_allocator;

extern fn token_tach_updater_start() void;
extern fn token_tach_updater_check() void;

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
    // The engine already rendered this exact template into `glance_text`
    // on the refresh that produced the model we are looking at, so
    // re-rendering it here would repeat a `ledger.today` lookup, a
    // `nearestWall` scan and a `maxUtilization` scan for a string we
    // already have. Returned slices may point at the model (the SDK
    // copies what it keeps).
    //
    // The length guard is not decoration: the runtime REJECTS a tray
    // title over `max_tray_title_bytes`, and rendering into the scratch
    // buffer was what silently clamped a long `tray-format` to that
    // bound. `glance_buf` is wider (the popover shows the same line
    // untruncated), so a long template falls back to the scratch render
    // and gets exactly the truncation it always got. The other branch is
    // the pre-first-refresh window, where `glance_text` is still empty.
    const title = if (model.glance_text.len > 0 and model.glance_text.len <= scratch.title_buffer.len)
        model.glance_text
    else
        trayfmt.render(&scratch.title_buffer, model.cfg.tray_format, engine.glanceState(model));
    scratch.items[0] = .{ .id = 1, .label = model.claude_text, .enabled = false };
    scratch.items[1] = .{ .id = 2, .label = model.codex_text, .enabled = false };
    scratch.items[2] = .{ .id = 3, .label = model.opencode_text, .enabled = false };
    scratch.items[3] = .{ .id = 4, .label = model.today_text, .enabled = false };
    scratch.items[4] = .{ .id = 5, .separator = true };
    // The reserved toggle command is intercepted by the runtime, so this
    // menu item opens the popover cluster without any app wiring.
    scratch.items[5] = .{ .id = 6, .label = "Open Tach", .command = "native-sdk.tray.toggle-popover" };
    scratch.items[6] = .{ .id = 7, .label = "Dashboard", .command = "tach.dashboard" };
    scratch.items[7] = .{ .id = 8, .label = "Settings (config file)", .command = "tach.config" };
    scratch.items[8] = .{ .id = 9, .separator = true };
    var count: usize = 9;
    if (updater_options.enabled) {
        scratch.items[count] = .{ .id = 10, .label = "Check for Updates...", .command = "tach.check-updates" };
        count += 1;
    }
    scratch.items[count] = .{ .id = 11, .label = "Token Tach v" ++ app_version, .enabled = false };
    count += 1;
    scratch.items[count] = .{ .id = 12, .label = "Quit", .command = "tach.quit" };
    count += 1;
    return .{ .title = title, .items = scratch.items[0..count] };
}

pub const app_version: []const u8 = @import("app_version").version;

/// Shell commands → display Msgs: the popover-open notification keys
/// the ignition sweep (the rest of the tray traffic stays unmapped).
fn onCommand(name: []const u8) ?Msg {
    if (updater_options.enabled and std.mem.eql(u8, name, "tach.check-updates")) {
        token_tach_updater_check();
        return null;
    }
    if (std.mem.eql(u8, name, "tray.popover_opened")) return .popover_opened;
    if (std.mem.eql(u8, name, "tach.dashboard")) return .open_dashboard;
    if (std.mem.eql(u8, name, "tach.config")) return .open_config;
    if (std.mem.eql(u8, name, "tach.quit")) return .quit;
    return null;
}

fn tachWindows(model: *const Model, scratch: *TachApp.WindowsScratch) []const TachApp.WindowDescriptor {
    var count: usize = 0;
    if (model.dashboard_open) {
        scratch.windows[count] = .{
            .label = dashboard.window_label,
            .canvas_label = dashboard.canvas_label,
            .title = "Token Tach Dashboard",
            .width = dashboard.window_width,
            .height = dashboard.window_height,
            .min_width = 820,
            .min_height = 560,
            .resizable = true,
            .on_close = .dashboard_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn tachWindowView(ui: *AppUi, model: *const Model, window_label: []const u8) AppUi.Node {
    if (std.mem.eql(u8, window_label, dashboard.window_label)) {
        return dashboard.rootView(ui, model);
    }
    return ui.panel(.{}, .{});
}

pub fn main(init: std.process.Init) !void {
    if (try cli.maybeRunCli(init)) return;

    const app_state = try TachApp.create(app_allocator, .{
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
        .windows_fn = tachWindows,
        .window_view = tachWindowView,
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
    // Runs before `destroy` (defers unwind LIFO): flush the history store
    // and release its flock on every way out of here EXCEPT the tray Quit
    // item, which exits the process from inside `update` and does its own.
    defer engine.deinit(&app_state.model);

    engine.setup(&app_state.model, app_allocator, .{
        .home = init.environ_map.get("HOME") orelse "",
        .claude_config_dir = init.environ_map.get("CLAUDE_CONFIG_DIR"),
        .codex_home = init.environ_map.get("CODEX_HOME"),
        .opencode_db = init.environ_map.get("OPENCODE_DB"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .xdg_state_home = init.environ_map.get("XDG_STATE_HOME"),
        .pi_home = init.environ_map.get("PI_HOME"),
        .gemini_cli_home = init.environ_map.get("GEMINI_CLI_HOME"),
        .qwen_runtime_dir = init.environ_map.get("QWEN_RUNTIME_DIR"),
        .qwen_home = init.environ_map.get("QWEN_HOME"),
        .kimi_share_dir = init.environ_map.get("KIMI_SHARE_DIR"),
        .goose_path_root = init.environ_map.get("GOOSE_PATH_ROOT"),
        .kilo_db = init.environ_map.get("KILO_DB"),
        .cline_dir = init.environ_map.get("CLINE_DIR"),
        .cline_data_dir = init.environ_map.get("CLINE_DATA_DIR"),
    }) catch |err| {
        std.log.err("engine setup failed: {s} — running with empty state", .{@errorName(err)});
    };

    if (updater_options.enabled) token_tach_updater_start();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "token-tach",
        .window_title = "Token Tach",
        .bundle_id = "com.phall.token-tach",
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
