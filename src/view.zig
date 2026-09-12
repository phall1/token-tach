//! Allowance-first popover. Only presentation snapshots cross this interface.
const std = @import("std");
const native_sdk = @import("native_sdk");
const presentation = @import("presentation.zig");
const summary = @import("core/usage_summary.zig");
const sessions = @import("core/sessions.zig");
const types = @import("core/types.zig");
const format = @import("core/trayfmt.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;
pub const Ui = canvas.Ui(@import("engine.zig").Msg);
pub const window_width: f32 = 400;
pub const window_height: f32 = 600;
const Snapshot = presentation.Snapshot;
const Source = presentation.Source;

pub fn rootView(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    return ui.panel(.{
        // Namespace retained drawing and scroll state by page and source.
        .key = .{ .str = ui.fmt("popover:{t}:{s}", .{ snapshot.page, if (snapshot.selected()) |source| source.name else "empty" }) },
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Token Tach usage overview" },
    }, .{
        ui.column(.{ .frame = .{ .x = 20, .y = 20, .width = window_width - 40, .height = 30 } }, .{header(ui, snapshot)}),
        ui.column(.{ .frame = .{ .x = 20, .y = window_height - 50, .width = window_width - 40, .height = 30 } }, .{footer(ui, snapshot)}),
        // Paint the independently clipped scrolling body last; navigation
        // stays outside its clip and retains a fixed place on every page.
        ui.scroll(.{ .frame = .{ .x = 20, .y = 66, .width = window_width - 40, .height = window_height - 132 }, .key = .{ .int = @intFromEnum(snapshot.page) }, .semantics = .{ .label = "Usage details" } }, content(ui, snapshot)),
    });
}

fn header(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    const title = switch (snapshot.page) {
        .overview => "Token Tach",
        .sources => "Usage sources",
        .sessions => "Recent sessions",
        .days => "Daily totals",
    };
    return ui.row(.{ .height = 30, .gap = 10, .cross = .center }, .{
        ui.text(.{ .grow = 1, .size = .lg }, title),
        if (snapshot.page == .overview)
            ui.button(.{ .size = .sm, .on_press = .refresh_usage, .semantics = .{ .label = "Refresh usage" } }, "Refresh")
        else
            ui.button(.{ .size = .sm, .on_press = .{ .popover_page = .overview } }, "Back"),
    });
}

fn content(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    return switch (snapshot.page) {
        .sources => sourceChooser(ui, snapshot),
        .sessions => sessionList(ui, snapshot),
        .days => dailyTotals(ui, snapshot),
        .overview => if (snapshot.selected()) |source| overview(ui, snapshot, source) else empty(ui, snapshot),
    };
}

fn empty(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    const loading = !snapshot.ready or snapshot.scanning;
    return ui.column(.{ .gap = 12, .padding = 12 }, .{
        ui.text(.{ .size = .lg }, if (loading) "Reading local usage..." else "Your usage, in one place"),
        note(ui, if (loading) "Finding the usage your coding agents have already recorded." else "Use a supported coding agent and its recorded usage will appear here automatically."),
        note(ui, "Local files. No proxy or tracking account."),
    });
}

fn overview(ui: *Ui, snapshot: *const Snapshot, source: *const Source) Ui.Node {
    return ui.column(.{ .gap = 12 }, .{
        identity(ui, snapshot, source),
        allowanceSection(ui, snapshot, source),
        usageSection(ui, snapshot, source),
    });
}

fn identity(ui: *Ui, snapshot: *const Snapshot, source: *const Source) Ui.Node {
    return ui.column(.{ .gap = 6 }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1, .size = .lg }, source.name),
            if (snapshot.len > 1)
                ui.button(.{ .size = .sm, .on_press = .{ .popover_page = .sources }, .semantics = .{ .label = "Choose usage source" } }, "Change")
            else
                ui.spacer(0),
        }),
        note(ui, if (source.allowance) |allowance| ui.fmt("{s} / {s}", .{ allowance.provenance, if (allowance.plan.len > 0) allowance.plan else "plan unknown" }) else "Local harness usage"),
    });
}

fn allowanceSection(ui: *Ui, snapshot: *const Snapshot, source: *const Source) Ui.Node {
    const allowance = source.allowance orelse return ui.column(.{ .gap = 8 }, .{
        sectionTitle(ui, "ALLOWANCE"),
        ui.text(.{}, "Not available"),
        note(ui, source.help),
    });
    const rows = ui.arena.alloc(Ui.Node, allowance.windows.len) catch return allocationFailed(ui);
    for (allowance.windows, 0..) |window, i| rows[i] = limitRow(ui, snapshot.now_ms, allowance.read_ms, window);
    return ui.column(.{ .gap = 10 }, .{
        sectionTitle(ui, "ALLOWANCE"),
        ui.column(.{ .gap = 12 }, rows),
        note(ui, source.help),
    });
}

fn limitRow(ui: *Ui, now_ms: i64, read_ms: i64, window: types.LimitWindow) Ui.Node {
    const valid = presentation.validPercent(window.used_percent);
    const state = presentation.freshness(read_ms, window.resets_at_ms, now_ms);
    const fraction: f32 = if (valid) @floatCast(window.used_percent / 100) else 0;
    const color: canvas.Color = if (state != .fresh) theme.cluster_colors.text_muted else allowanceInk(fraction);
    const label = presentation.windowName(window.kind);
    return ui.column(.{ .gap = 5, .semantics = .{ .label = ui.fmt("{s}: {s}", .{ label, @tagName(state) }) } }, .{
        ui.row(.{ .cross = .center }, .{
            ui.text(.{ .grow = 1 }, label),
            ui.text(.{ .style = .{ .foreground = color } }, if (valid) ui.fmt("{d:.0}% used", .{window.used_percent}) else "Unavailable"),
        }),
        meter(ui, fraction, color),
        note(ui, resetText(ui, now_ms, read_ms, window.resets_at_ms)),
    });
}

fn allowanceInk(fraction: f32) canvas.Color {
    if (fraction >= 0.9) return theme.red;
    if (fraction >= 0.7) return theme.amber;
    return theme.green;
}

fn resetText(ui: *Ui, now_ms: i64, read_ms: i64, reset_ms: i64) []const u8 {
    const state = presentation.freshness(read_ms, reset_ms, now_ms);
    if (state == .reset_passed) return "Reset passed / awaiting a new reading";
    const reset = if (reset_ms > now_ms) ui.fmt("Resets in {s}", .{duration(ui, reset_ms - now_ms)}) else "Reset time unknown";
    if (state == .stale) {
        if (read_ms <= 0 or read_ms > now_ms) return ui.fmt("Stale / observation time unknown / {s}", .{reset});
        return ui.fmt("Stale / read {s} ago / {s}", .{ duration(ui, now_ms - read_ms), reset });
    }
    return reset;
}

fn meter(ui: *Ui, fraction: f32, color: canvas.Color) Ui.Node {
    return ui.el(.progress, .{
        .height = 5,
        .value = std.math.clamp(fraction, 0, 1),
        .style = .{ .accent = color, .background = theme.track, .radius = 3 },
    }, .{});
}

fn usageSection(ui: *Ui, snapshot: *const Snapshot, source: *const Source) Ui.Node {
    if (snapshot.scanning) return note(ui, "Reading history... totals are still filling in.");
    if (!snapshot.usage.available) return note(ui, if (snapshot.history_blocked) "History collection unavailable. Restart Token Tach to retry." else "History unavailable. Will retry reading the archive.");
    return ui.column(.{ .gap = 10 }, .{
        ui.row(.{ .cross = .center }, .{
            sectionTitle(ui, "LAST 7 DAYS"),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .on_press = .{ .popover_page = .days }, .semantics = .{ .label = "Daily totals" } }, ui.fmt("{s} tokens", .{tokens(ui, source.usage.total.totalTokens())})),
        }),
        dayChart(ui, snapshot, source.usage),
        note(ui, summaryCaption(ui, snapshot)),
        modelList(ui, source.usage),
        note(ui, ui.fmt("{s} API-equivalent / local {s} usage", .{ cost(ui, source.usage.total.cost_usd), source.name })),
    });
}

fn summaryCaption(ui: *Ui, snapshot: *const Snapshot) []const u8 {
    const age = @max(0, snapshot.now_ms - snapshot.usage.updated_ms);
    const status = historyStatus(ui, snapshot, age);
    const timezone = if (snapshot.usage.tz_offset_min != snapshot.tz_offset_min)
        ui.fmt(" Archive timezone UTC offset {d} min.", .{snapshot.usage.tz_offset_min})
    else
        "";
    return ui.fmt("{s}{s}", .{ status, timezone });
}

fn historyStatus(ui: *Ui, snapshot: *const Snapshot, age: i64) []const u8 {
    if (snapshot.history_blocked) return "Cached history / collection stopped. Restart to retry.";
    if (snapshot.history_error) return "Cached history / refresh failed. Will retry.";
    return ui.fmt("Updated {s} ago. Today is partial.", .{duration(ui, age)});
}

fn dayChart(ui: *Ui, snapshot: *const Snapshot, usage: *const summary.Source) Ui.Node {
    const values = ui.arena.alloc(f32, summary.day_count) catch return allocationFailed(ui);
    const labels = ui.arena.alloc([]const u8, summary.day_count) catch return allocationFailed(ui);
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    for (usage.days, 0..) |day, i| {
        values[i] = @floatFromInt(day.totalTokens());
        const key = snapshot.usage.end_day - @as(i64, @intCast(summary.day_count - 1 - i));
        const today = @divFloor(snapshot.now_ms + @as(i64, snapshot.usage.tz_offset_min) * 60_000, 86_400_000);
        labels[i] = if (key == today) "Today" else weekdays[@intCast(@mod(key + 4, 7))];
    }
    return ui.chart(.{
        .height = 80,
        .y_min = 0,
        .x_labels = labels,
        .hover_details = true,
        .semantics = .{ .label = "Seven days of recorded tokens" },
    }, &.{.{ .kind = .bar, .values = values, .color = .accent, .label = "Tokens" }});
}

fn modelList(ui: *Ui, usage: *const summary.Source) Ui.Node {
    if (usage.models_len == 0) return note(ui, "No model usage recorded in this period.");
    const rows = ui.arena.alloc(Ui.Node, usage.models_len) catch return allocationFailed(ui);
    for (usage.models[0..usage.models_len], 0..) |*model, i| {
        rows[i] = ui.row(.{ .height = 24, .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1, .overflow = .ellipsis }, model.name.text()),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d}", .{model.tokens})),
        });
    }
    return ui.column(.{ .gap = 6 }, .{ sectionTitle(ui, "TOP MODELS / 7 DAYS"), ui.column(.{ .gap = 2 }, rows) });
}

fn sourceChooser(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    const rows = ui.arena.alloc(Ui.Node, snapshot.len) catch return allocationFailed(ui);
    for (snapshot.sources[0..snapshot.len], 0..) |source, i| {
        rows[i] = ui.button(.{
            .key = .{ .int = source.harness.storageId() },
            .height = 38,
            .selected = i == snapshot.selected_index,
            .on_press = .{ .select_source = source.harness },
        }, source.name);
    }
    return ui.column(.{ .gap = 8 }, .{
        note(ui, "Choose a harness. Usage stays separate from account-wide allowance."),
        ui.column(.{ .gap = 6 }, rows),
    });
}

fn sessionList(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    var buffer: [sessions.max_sessions]*const sessions.Session = undefined;
    const live = presentation.sessionRows(snapshot, &buffer);
    if (live.len == 0) return note(ui, "No recent sessions. Activity appears as local transcripts change.");
    const rows = ui.arena.alloc(Ui.Node, live.len) catch return allocationFailed(ui);
    for (live, 0..) |session, i| rows[i] = sessionRow(ui, session, snapshot.now_ms);
    return ui.column(.{ .gap = 14 }, .{
        note(ui, "Activity is inferred from local records, not process status."),
        ui.column(.{ .gap = 16 }, rows),
    });
}

fn dailyTotals(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    const source = snapshot.selected() orelse return empty(ui, snapshot);
    if (!snapshot.usage.available) return note(ui, "History unavailable.");
    const rows = ui.arena.alloc(Ui.Node, summary.day_count) catch return allocationFailed(ui);
    for (source.usage.days, 0..) |day, i| {
        const key = snapshot.usage.end_day - @as(i64, @intCast(summary.day_count - 1 - i));
        const epoch_day: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, key) * 86400) };
        const year = epoch_day.getEpochDay().calculateYearDay();
        const date = year.calculateMonthDay();
        rows[i] = ui.row(.{ .height = 34, .gap = 8 }, .{
            ui.text(.{ .grow = 1 }, ui.fmt("{d}-{d:0>2}-{d:0>2}", .{ year.year, date.month.numeric(), date.day_index + 1 })),
            ui.text(.{}, ui.fmt("{d} tokens", .{day.totalTokens()})),
        });
    }
    return ui.column(.{ .gap = 12 }, .{
        note(ui, source.name),
        note(ui, "Exact recorded tokens, including cache."),
        ui.column(.{ .gap = 4 }, rows),
        note(ui, summaryCaption(ui, snapshot)),
    });
}

fn sessionRow(ui: *Ui, session: *const sessions.Session, now_ms: i64) Ui.Node {
    const project = if (session.project().len > 0) session.project() else "Unknown project";
    return ui.column(.{
        .key = .{ .str = ui.fmt("{s}:{s}", .{ session.agent.label(), session.sessionId() }) },
        .gap = 5,
    }, .{
        ui.row(.{ .gap = 8 }, .{
            ui.text(.{ .grow = 1, .overflow = .ellipsis }, project),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, presentation.activityLabel(session, now_ms)),
        }),
        note(ui, ui.fmt("{s} / {s}", .{ presentation.sourceName(session.agent), session.modelName() })),
        note(ui, ui.fmt("{s} tokens / {s} API-equivalent", .{ tokens(ui, session.totals.totalTokens()), cost(ui, session.totals.cost_usd) })),
    });
}

fn footer(ui: *Ui, snapshot: *const Snapshot) Ui.Node {
    return ui.row(.{ .height = 30, .gap = 8, .cross = .center }, .{
        ui.button(.{ .size = .sm, .on_press = .{ .popover_page = .sessions }, .selected = snapshot.page == .sessions }, "Sessions"),
        ui.button(.{ .size = .sm, .on_press = .open_dashboard }, "History"),
        ui.spacer(1),
        ui.button(.{ .size = .sm, .on_press = .open_config }, "Settings"),
    });
}

fn sectionTitle(ui: *Ui, text: []const u8) Ui.Node {
    return ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, text);
}

fn note(ui: *Ui, text: []const u8) Ui.Node {
    return ui.text(.{ .size = .sm, .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, text);
}

fn allocationFailed(ui: *Ui) Ui.Node {
    ui.failed = true;
    return ui.spacer(0);
}

fn tokens(ui: *Ui, value: u64) []const u8 {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    format.writeHumanTokens(&writer, value) catch {};
    return ui.fmt("{s}", .{writer.buffered()});
}

fn cost(ui: *Ui, value: f64) []const u8 {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    format.writeCost(&writer, value) catch {};
    return ui.fmt("{s}", .{writer.buffered()});
}

fn duration(ui: *Ui, ms: i64) []const u8 {
    if (ms >= 86_400_000) return ui.fmt("{d}d {d}h", .{ @divFloor(ms, 86_400_000), @mod(@divFloor(ms, 3_600_000), 24) });
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    format.writeCountdown(&writer, ms) catch {};
    return ui.fmt("{s}", .{writer.buffered()});
}
