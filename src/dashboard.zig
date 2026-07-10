//! History dashboard window: month rollups, 30-day bars, and top
//! model/project attribution. The main popover stays an instrument;
//! this is the ledger workbench.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const ledger_mod = @import("core/ledger.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const Ui = canvas.Ui(Msg);

pub const window_label = "dashboard";
pub const canvas_label = "dashboard-canvas";
pub const window_width: f32 = 920;
pub const window_height: f32 = 640;

const pad: f32 = 24;
const gap: f32 = 14;

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    var nodes: std.ArrayList(Ui.Node) = .empty;

    panel(ui, &nodes, rect(0, 0, window_width, window_height), theme.bg, 0);
    header(ui, &nodes, model);
    hero(ui, &nodes, model);
    dailyBars(ui, &nodes, model);
    agentSplit(ui, &nodes, model);
    topTable(ui, &nodes, "MODELS", model.ledger.per_model.keys(), model.ledger.per_model.values(), rect(pad, 388, 424, 216));
    topTable(ui, &nodes, "PROJECTS", model.ledger.per_project.keys(), model.ledger.per_project.values(), rect(472, 388, 424, 216));

    return ui.panel(.{
        .grow = 1,
        .style = .{ .background = theme.transparent, .radius = 0, .stroke_width = 0 },
        .semantics = .{ .label = "Token Tach dashboard" },
    }, .{nodes.items});
}

fn header(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const rollup = engine.monthRollup(&model.ledger, model.now_ms);
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(pad, 18, 360, 30),
        .semantics = .{ .label = "Token Tach history dashboard" },
    }, &.{
        .{ .text = "TOKEN", .weight = .bold, .monospace = true, .scale = 1.35, .color = .text },
        .{ .text = " TACH", .weight = .bold, .monospace = true, .scale = 1.35, .color = .accent },
        .{ .text = " DASH", .weight = .bold, .monospace = true, .scale = 1.35, .color = .text_muted },
    }));
    push(ui, nodes, ui.text(.{
        .frame = rect(window_width - 260, 24, 236, 18),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, ui.fmt("{s} {d} · {d} active days", .{ monthName(rollup.month), rollup.year, rollup.active_days })));
}

fn hero(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const frame = rect(pad, 60, window_width - 2 * pad, 122);
    panel(ui, nodes, frame, Color.rgb8(10, 15, 18), 10);

    const rollup = engine.monthRollup(&model.ledger, model.now_ms);
    stat(ui, nodes, "MONTH API EQUIV", fmtCost(ui, rollup.totals.cost_usd), rect(48, 88, 210, 68), theme.green);
    stat(ui, nodes, "MONTH TOKENS", fmtTokens(ui, rollup.totals.totalTokens()), rect(276, 88, 190, 68), theme.cluster_colors.text);

    const value = engine.subscriptionValue(model);
    const multiple_text = if (value.multipleLowerBound(rollup.totals.cost_usd)) |m|
        ui.fmt("≥{d:.1}×", .{m})
    else if (value.incomplete)
        "plan unknown"
    else
        "no paid plan";
    stat(ui, nodes, "SUBSCRIPTION VALUE", multiple_text, rect(488, 88, 180, 68), if (value.incomplete) theme.amber else theme.needle);

    const plan_text = if (value.plan_hi_usd > 0)
        ui.fmt("{s} API-equivalent on {s}/mo plans{s}", .{
            fmtCost(ui, rollup.totals.cost_usd),
            planBand(ui, value),
            if (value.ambiguous()) " (Claude Max tier ambiguous)" else "",
        })
    else
        "No recognizable paid plan string yet";
    push(ui, nodes, ui.text(.{
        .frame = rect(684, 112, 188, 32),
        .wrap = true,
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, plan_text));
}

fn stat(ui: *Ui, nodes: *std.ArrayList(Ui.Node), label: []const u8, value: []const u8, frame: geometry.RectF, ink: Color) void {
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x, frame.y, frame.width, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, label));
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(frame.x, frame.y + 20, frame.width, 34),
        .style = .{ .foreground = ink },
    }, &.{.{ .text = value, .weight = .bold, .monospace = true, .scale = 1.8 }}));
}

fn dailyBars(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const frame = rect(pad, 196, 642, 170);
    panel(ui, nodes, frame, Color.rgb8(10, 15, 18), 10);
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x + 18, frame.y + 14, 180, 16),
        .style_tokens = .{ .foreground = .text_muted },
    }, "30-DAY API-EQUIVALENT COST"));

    var raw: [30]f64 = undefined;
    engine.trailingDailyCost(&model.ledger, model.now_ms, &raw);
    const values = ui.arena.alloc(f32, raw.len) catch {
        ui.failed = true;
        return;
    };
    var max_cost: f64 = 0;
    for (raw, values) |v, *slot| {
        max_cost = @max(max_cost, v);
        slot.* = @floatCast(v);
    }
    push(ui, nodes, ui.stack(.{
        .frame = rect(frame.x + 18, frame.y + 44, frame.width - 36, 96),
    }, .{
        ui.chart(.{
            .width = frame.width - 36,
            .height = 96,
            .y_min = 0,
            .y_max = @floatCast(@max(max_cost, 1)),
            .grid_lines = 3,
            .semantics = .{ .label = "30 day daily cost bars" },
        }, &.{.{ .kind = .bar, .values = values, .color = .accent, .label = "daily cost" }}),
    }));
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x + 18, frame.y + 146, 180, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "oldest → today"));
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x + frame.width - 180, frame.y + 146, 160, 14),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, ui.fmt("peak {s}", .{fmtCost(ui, max_cost)})));
}

fn agentSplit(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const frame = rect(690, 196, 206, 170);
    panel(ui, nodes, frame, Color.rgb8(10, 15, 18), 10);
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x + 16, frame.y + 14, 160, 16),
        .style_tokens = .{ .foreground = .text_muted },
    }, "AGENT SPLIT"));

    const claude_total = model.ledger.forAgent(.claude);
    const codex_total = model.ledger.forAgent(.codex);
    agentRow(ui, nodes, "Claude", claude_total, model.ledger.all.cost_usd, frame.y + 48);
    agentRow(ui, nodes, "Codex", codex_total, model.ledger.all.cost_usd, frame.y + 96);
}

fn agentRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), name: []const u8, totals: ledger_mod.Totals, all_cost: f64, y: f32) void {
    push(ui, nodes, ui.text(.{
        .frame = rect(706, y, 70, 16),
        .style_tokens = .{ .foreground = .text },
    }, name));
    push(ui, nodes, ui.text(.{
        .frame = rect(790, y, 86, 16),
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, fmtCost(ui, totals.cost_usd)));
    const track = rect(706, y + 24, 170, 7);
    panel(ui, nodes, track, theme.track, 3);
    if (all_cost > 0 and totals.cost_usd > 0) {
        panel(ui, nodes, rect(track.x, track.y, @max(3, track.width * @as(f32, @floatCast(totals.cost_usd / all_cost))), track.height), theme.green, 3);
    }
}

fn topTable(
    ui: *Ui,
    nodes: *std.ArrayList(Ui.Node),
    title: []const u8,
    keys: []const []const u8,
    values: []const ledger_mod.Totals,
    frame: geometry.RectF,
) void {
    panel(ui, nodes, frame, Color.rgb8(10, 15, 18), 10);
    push(ui, nodes, ui.text(.{
        .frame = rect(frame.x + 16, frame.y + 14, 180, 16),
        .style_tokens = .{ .foreground = .text_muted },
    }, title));

    const rows = sortedRows(ui, keys, values);
    const shown = @min(rows.len, 7);
    var y = frame.y + 44;
    for (rows[0..shown]) |row| {
        tableRow(ui, nodes, row.name, row.totals, rowsTotalCost(rows), frame.x + 16, y, frame.width - 32);
        y += 22;
    }
    if (shown == 0) {
        push(ui, nodes, ui.text(.{
            .frame = rect(frame.x + 16, frame.y + 58, frame.width - 32, 18),
            .style_tokens = .{ .foreground = .text_muted },
        }, "No usage data yet"));
    }
}

const Row = struct { name: []const u8, totals: ledger_mod.Totals };

fn sortedRows(ui: *Ui, keys: []const []const u8, values: []const ledger_mod.Totals) []Row {
    const rows = ui.arena.alloc(Row, keys.len) catch {
        ui.failed = true;
        return &.{};
    };
    for (keys, values, 0..) |key, totals, i| rows[i] = .{ .name = displayName(key), .totals = totals };
    std.mem.sort(Row, rows, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            if (a.totals.cost_usd != b.totals.cost_usd) return a.totals.cost_usd > b.totals.cost_usd;
            if (a.totals.totalTokens() != b.totals.totalTokens()) return a.totals.totalTokens() > b.totals.totalTokens();
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return rows;
}

fn rowsTotalCost(rows: []const Row) f64 {
    var total: f64 = 0;
    for (rows) |row| total += row.totals.cost_usd;
    return total;
}

fn tableRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), name: []const u8, totals: ledger_mod.Totals, total_cost: f64, x: f32, y: f32, width: f32) void {
    push(ui, nodes, ui.text(.{
        .frame = rect(x, y, width - 160, 15),
        .size = .sm,
        .style_tokens = .{ .foreground = .text },
    }, name));
    push(ui, nodes, ui.text(.{
        .frame = rect(x + width - 154, y, 72, 15),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, fmtTokens(ui, totals.totalTokens())));
    push(ui, nodes, ui.text(.{
        .frame = rect(x + width - 76, y, 76, 15),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, fmtCost(ui, totals.cost_usd)));
    const track = rect(x, y + 16, width, 3);
    panel(ui, nodes, track, theme.track, 2);
    if (total_cost > 0 and totals.cost_usd > 0) {
        panel(ui, nodes, rect(track.x, track.y, @max(2, track.width * @as(f32, @floatCast(totals.cost_usd / total_cost))), track.height), theme.green, 2);
    }
}

fn displayName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len > 0) base else path;
}

fn panel(ui: *Ui, nodes: *std.ArrayList(Ui.Node), frame: geometry.RectF, color: Color, radius: f32) void {
    push(ui, nodes, ui.panel(.{
        .frame = frame,
        .style = .{ .background = color, .border = theme.bezel_edge, .stroke_width = if (radius > 0) 1 else 0, .radius = radius },
    }, .{}));
}

fn push(ui: *Ui, nodes: *std.ArrayList(Ui.Node), node: Ui.Node) void {
    nodes.append(ui.arena, node) catch {
        ui.failed = true;
    };
}

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.RectF {
    return geometry.RectF.init(x, y, w, h);
}

fn fmtCost(ui: *Ui, cost: f64) []const u8 {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    trayfmt.writeCost(&w, cost) catch {};
    return ui.arena.dupe(u8, w.buffered()) catch {
        ui.failed = true;
        return "";
    };
}

fn fmtTokens(ui: *Ui, tokens: u64) []const u8 {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    trayfmt.writeHumanTokens(&w, tokens) catch {};
    return ui.arena.dupe(u8, w.buffered()) catch {
        ui.failed = true;
        return "";
    };
}

fn planBand(ui: *Ui, value: engine.SubscriptionValue) []const u8 {
    if (value.plan_lo_usd == value.plan_hi_usd) return fmtCost(ui, value.plan_hi_usd);
    return ui.fmt("{s}–{s}", .{ fmtCost(ui, value.plan_lo_usd), fmtCost(ui, value.plan_hi_usd) });
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Month",
    };
}
