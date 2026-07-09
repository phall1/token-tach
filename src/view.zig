//! The instrument cluster: a Zig-built canvas view (the closed markup
//! grammar has no rotated primitives, so the dial is hand-placed).
//!
//! Precision layout, calculator-style: the whole cluster is absolute —
//! every element is a `.frame` child of one stacking root — because the
//! tach needle and its render animation rotate about an ABSOLUTE pivot
//! (`gauge_cx`, `gauge_cy`); a flow layout would move the pivot out
//! from under the rotation. The window opens at exactly
//! `window_width` x `window_height` and the cluster is top-left
//! anchored, so resizing never invalidates the pivot.
//!
//! Dial anatomy (automotive): a bezel, a circular dial face, 56 LED
//! ticks swept 240° (lit up to the needle, zone-colored
//! green→amber→red), 6 major graduations with numerals in thousands,
//! a glowing dot-chain needle with a counterweight tail and hub, and
//! an in-dial readout (burn + wall ETA).
//!
//! Everything on the dial is a CIRCLE (a panel whose radius is half its
//! box) placed by polar math, deliberately: the renderer rasterizes
//! rounded rects axis-aligned (a rotated rect paints as its bounding
//! box), and circles are the rotation-invariant primitive — so the
//! needle sweep animation (a rotation of each dot about the pivot)
//! renders exactly right. The needle's rest layout is its REAL pose;
//! the render animation only replays the delta from the previous sweep,
//! so screenshots and static pipelines land on truth.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const Ui = canvas.Ui(Msg);

// ------------------------------------------------------ window geometry

pub const window_width: f32 = 560;
pub const window_height: f32 = 420;

const header_y: f32 = 12;
const panel_y: f32 = 46;
const panel_h: f32 = 304;
const strip_y: f32 = 358;
const strip_h: f32 = 42;
const footer_y: f32 = 400;

// -------------------------------------------------------- dial geometry

/// Needle pivot in ABSOLUTE canvas coordinates — the rotation center
/// for the static needle pose and the sweep animation alike.
pub const gauge_cx: f32 = 150;
pub const gauge_cy: f32 = 198;

const dial_r: f32 = 120;
const tick_r: f32 = 101; // LED-ring radius (dot centers)
const minor_count: usize = 56;
const major_count: usize = 6; // five intervals, numerals 0..scale
const numeral_r: f32 = 76;

// The needle: a tapered chain of dots from the hub out to the ring,
// plus a counterweight tail and a translucent tip halo.
const needle_dots: usize = 24;
const needle_r0: f32 = 18;
const needle_r1: f32 = 88;
const tail_dots: usize = 3;
const halo_dots: usize = 3;
/// Total animated needle parts (chain + tail + halo).
pub const needle_part_total: usize = needle_dots + tail_dots + halo_dots;

const green_end: f32 = 0.60;
const red_start_calm: f32 = 0.85;
const red_start_danger: f32 = 0.70;

// Global keys for the animated parts (needle sweep, redline pulse).
const needle_key_base: u64 = 0xD1A1_0100;
const redline_halo_key: u64 = 0xD1A1_0004;

// ------------------------------------------------------------- the view

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    var nodes: std.ArrayList(Ui.Node) = .empty;
    header(ui, &nodes, model);
    gaugeCluster(ui, &nodes, model);
    limitsPanel(ui, &nodes, model);
    odometerStrip(ui, &nodes, model);
    push(ui, &nodes, ui.statusBar(.{
        .frame = rect(0, footer_y, window_width, window_height - footer_y),
    }, model.status_text));
    return ui.panel(.{
        .grow = 1,
        .style = .{ .background = theme.bg, .radius = 0, .stroke_width = 0 },
    }, .{nodes.items});
}

// -------------------------------------------------------------- header

fn header(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const glance = engine.glanceState(model);
    const danger = engine.dangerState(model);

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(18, header_y, 240, 22),
        .semantics = .{ .label = "Token Tach" },
    }, &.{
        .{ .text = "TOKEN", .weight = .bold, .monospace = true, .scale = 1.2, .color = .text },
        .{ .text = " TACH", .weight = .bold, .monospace = true, .scale = 1.2, .color = .accent },
    }));

    // Live LED: green while burning, red in danger, unlit when idle.
    const led: Color = if (danger) theme.red else if (glance.idle) theme.track else theme.green;
    const led_word: []const u8 = if (danger) "REDLINE" else if (glance.idle) "IDLE" else "LIVE";
    if (!glance.idle or danger) {
        const glow = if (danger) theme.red_halo else theme.green_glow;
        push(ui, nodes, ui.panel(.{
            .frame = rect(438, header_y + 4, 16, 16),
            .style = .{ .background = glow, .radius = 8, .stroke_width = 0 },
        }, .{}));
    }
    push(ui, nodes, ui.panel(.{
        .frame = rect(442, header_y + 8, 8, 8),
        .style = .{ .background = led, .radius = 4, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.text(.{
        .frame = rect(458, header_y + 4, 86, 16),
        .size = .sm,
        .style = .{ .foreground = if (danger) theme.red else theme.cluster_colors.text_muted },
    }, led_word));
}

// ---------------------------------------------------------- tach gauge

fn gaugeCluster(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const glance = engine.glanceState(model);
    const danger = engine.dangerState(model);
    const scale = engine.gaugeScaleTpm(model.gauge_peak_tpm);
    const needle_frac = (model.needle_to_deg + engine.half_sweep_deg) / (2 * engine.half_sweep_deg);
    const red_start: f32 = if (danger) red_start_danger else red_start_calm;

    // Bezel and dial face.
    push(ui, nodes, ui.panel(.{
        .frame = rect(14, panel_y, 272, panel_h),
        .style = .{ .background = theme.bezel, .border = theme.bezel_edge, .stroke_width = 1, .radius = 14 },
    }, .{}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - dial_r, gauge_cy - dial_r, dial_r * 2, dial_r * 2),
        .style = .{ .background = theme.dial, .border = theme.dial_edge, .stroke_width = 1, .radius = dial_r },
    }, .{}));

    // Redline halo: a pulsing glow behind the red zone while danger holds.
    if (danger) {
        const mid_deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * (red_start + 1) / 2;
        const p = pointAt(mid_deg, 88);
        push(ui, nodes, ui.panel(.{
            .global_key = canvas.uiKey(redline_halo_key),
            .frame = rect(p.x - 42, p.y - 42, 84, 84),
            .style = .{ .background = theme.red_halo, .radius = 42, .stroke_width = 0 },
        }, .{}));
    }

    // The LED ring: 56 dots swept 240°, lit up to the needle. Lit dots
    // in the green zone carry a soft under-glow so the ring reads
    // backlit rather than flat.
    for (0..minor_count) |i| {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(minor_count - 1));
        const deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * frac;
        const in_red = frac >= red_start;
        const lit = frac <= needle_frac + 0.001 or (danger and in_red);
        const p = pointAt(deg, tick_r);
        const ink = zoneColor(frac, red_start, lit);
        if (lit) {
            push(ui, nodes, ui.panel(.{
                .frame = rect(p.x - 5.5, p.y - 5.5, 11, 11),
                .style = .{ .background = withAlpha(ink, 0.22), .radius = 5.5, .stroke_width = 0 },
            }, .{}));
        }
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - 2.5, p.y - 2.5, 5, 5),
            .style = .{ .background = ink, .radius = 2.5, .stroke_width = 0 },
        }, .{}));
    }

    // Major graduations + numerals (thousands of tokens/min).
    for (0..major_count) |i| {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(major_count - 1));
        const deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * frac;
        const bright: Color = if (frac >= red_start) theme.red else Color.rgb8(196, 214, 205);
        const p = pointAt(deg, tick_r);
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - 3.5, p.y - 3.5, 7, 7),
            .style = .{ .background = bright, .radius = 3.5, .stroke_width = 0 },
        }, .{}));

        const n = pointAt(deg, numeral_r);
        const thousands = scale / 5.0 * @as(f64, @floatFromInt(i)) / 1000.0;
        push(ui, nodes, ui.paragraph(.{
            .frame = rect(n.x - 18, n.y - 8, 36, 16),
            .text_alignment = .center,
            .style = .{ .foreground = if (frac >= red_start) theme.red else theme.cluster_colors.text_muted },
        }, &.{.{
            .text = ui.fmt("{d}", .{@as(u64, @intFromFloat(thousands + 0.5))}),
            .monospace = true,
            .weight = .medium,
        }}));
    }

    // Dial fine print at the foot, clear of the needle's sweep.
    push(ui, nodes, ui.text(.{
        .frame = rect(gauge_cx - 60, gauge_cy + 88, 120, 14),
        .size = .sm,
        .text_alignment = .center,
        .style_tokens = .{ .foreground = .text_muted },
    }, "tok/min ×1000"));

    // Needle: a tapered dot chain laid out at its REAL pose (the sweep
    // animation rotates the delta from the previous pose — circles stay
    // circles under rotation, so every frame is honest).
    var part: usize = 0;
    for (0..needle_dots) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(needle_dots - 1));
        const radius = needle_r0 + (needle_r1 - needle_r0) * t;
        const d: f32 = 8 - 3.8 * t;
        needleDot(ui, nodes, model.needle_to_deg, radius, d, theme.needle, &part);
    }
    for (0..tail_dots) |i| {
        const radius = -7 - 4 * @as(f32, @floatFromInt(i));
        needleDot(ui, nodes, model.needle_to_deg, radius, 6, theme.needle, &part);
    }
    for (0..halo_dots) |i| {
        const radius = needle_r1 - 9 * @as(f32, @floatFromInt(i));
        needleDot(ui, nodes, model.needle_to_deg, radius, 14, theme.needle_halo, &part);
    }

    // Hub over the needle root.
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 11, gauge_cy - 11, 22, 22),
        .style = .{ .background = theme.hub, .border = theme.hub_ring, .stroke_width = 1, .radius = 11 },
    }, .{}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 3, gauge_cy - 3, 6, 6),
        .style = .{ .background = theme.needle, .radius = 3, .stroke_width = 0 },
    }, .{}));

    // In-dial readout: the burn number, then the wall/reset line. While
    // history catch-up is chewing, the numbers aren't truth yet — dim
    // the readout and say "scanning" instead of asserting a confident 0.
    const scanning = model.catchup_active;
    const burn_text = if (glance.idle and !scanning)
        "0"
    else
        fmtTokens(ui, @intFromFloat(@max(glance.burn_tokens_per_min, 0)));
    const burn_ink: Color = if (scanning or glance.idle)
        theme.cluster_colors.text_muted
    else if (danger)
        theme.red
    else
        theme.green;
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(gauge_cx - 60, gauge_cy + 24, 120, 36),
        .text_alignment = .center,
        .style = .{ .foreground = burn_ink },
        .semantics = .{ .label = ui.fmt("burn {s} tokens per minute", .{burn_text}) },
    }, &.{.{ .text = burn_text, .weight = .bold, .monospace = true, .scale = 2.2 }}));

    const eta = if (scanning)
        EtaLine{ .text = "scanning…", .ink = theme.cluster_colors.text_muted }
    else
        etaLine(ui, glance, danger);
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(gauge_cx - 80, gauge_cy + 64, 160, 16),
        .text_alignment = .center,
        .style = .{ .foreground = eta.ink },
    }, &.{.{ .text = eta.text, .monospace = true, .scale = 0.9 }}));
}

/// One needle part: a circle centered on the needle ray at `radius`
/// from the pivot (negative = the counterweight side), keyed for the
/// sweep animation.
fn needleDot(
    ui: *Ui,
    nodes: *std.ArrayList(Ui.Node),
    deg: f32,
    radius: f32,
    diameter: f32,
    ink: Color,
    part: *usize,
) void {
    const p = pointAt(deg, radius);
    push(ui, nodes, ui.panel(.{
        .global_key = canvas.uiKey(needle_key_base + @as(u64, @intCast(part.*))),
        .frame = rect(p.x - diameter / 2, p.y - diameter / 2, diameter, diameter),
        .style = .{ .background = ink, .radius = diameter / 2, .stroke_width = 0 },
    }, .{}));
    part.* += 1;
}

const EtaLine = struct { text: []const u8, ink: Color };

fn etaLine(ui: *Ui, glance: trayfmt.GlanceState, danger: bool) EtaLine {
    if (!glance.idle) {
        if (glance.wall_at_ms) |wall| {
            const clock = fmtClock(ui, wall, glance.tz_offset_min);
            if (danger) return .{ .text = ui.fmt("WALL {s}", .{clock}), .ink = theme.red };
            return .{ .text = ui.fmt("wall {s}", .{clock}), .ink = theme.amber };
        }
        if (danger) return .{ .text = "REDLINE", .ink = theme.red };
    }
    if (glance.next_reset_ms) |reset| {
        if (reset > glance.now_ms) {
            return .{
                .text = ui.fmt("resets {s}", .{fmtCountdown(ui, reset - glance.now_ms)}),
                .ink = theme.cluster_colors.text_muted,
            };
        }
    }
    return .{
        .text = if (glance.idle) "idle" else "no wall in sight",
        .ink = theme.cluster_colors.text_muted,
    };
}

// --------------------------------------------------------- window bars

const bars_x: f32 = 312; // panel content left edge
const bars_right: f32 = 530; // panel content right edge
const row_h: f32 = 24;

fn limitsPanel(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    push(ui, nodes, ui.panel(.{
        .frame = rect(298, panel_y, 246, panel_h),
        .style = .{ .background = theme.bezel, .border = theme.bezel_edge, .stroke_width = 1, .radius = 14 },
    }, .{}));

    var y: f32 = panel_y + 16;
    y = agentGroup(ui, nodes, model, .claude, model.claude_limits, y);
    push(ui, nodes, ui.panel(.{
        .frame = rect(bars_x, y, bars_right - bars_x, 1),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    _ = agentGroup(ui, nodes, model, .codex, model.codex_limits, y + 10);

    // Burn history sparkline pinned to the panel foot.
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_x, panel_y + 222, 140, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "burn · last 15 min"));
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_right - 110, panel_y + 222, 110, 14),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, ui.fmt("peak {s}/m", .{fmtTokens(ui, @intFromFloat(@max(model.gauge_peak_tpm, 0)))})));
    push(ui, nodes, ui.stack(.{
        .frame = rect(bars_x, panel_y + 240, bars_right - bars_x, 48),
    }, .{
        ui.chart(.{
            .width = bars_right - bars_x,
            .height = 48,
            .y_min = 0,
            .semantics = .{ .label = "Burn history" },
        }, &.{.{ .kind = .bar, .values = burnSpark(ui, model), .color = .accent, .label = "burn" }}),
    }));
}

fn agentGroup(
    ui: *Ui,
    nodes: *std.ArrayList(Ui.Node),
    model: *const Model,
    agent: types.Agent,
    limits: ?types.LimitSnapshot,
    y0: f32,
) f32 {
    var y = y0;
    const totals = model.ledger.forAgent(agent);
    const enabled = engine.sourceEnabled(model.cfg.sources, agent);
    const empty = enabled and engine.agentIsEmpty(model, agent);
    const stale_min: ?u64 = if (agent == .claude) engine.oauthStaleMin(model) else null;
    const name: []const u8 = switch (agent) {
        .claude => "CLAUDE",
        .codex => "CODEX",
    };

    var name_spans: [3]canvas.TextSpan = .{
        .{ .text = name, .weight = .bold, .monospace = true },
        .{ .text = "", .color = .text_muted, .monospace = true },
        .{ .text = "", .color = .warning, .monospace = true },
    };
    if (enabled and !empty) {
        if (stale_min) |mins| {
            // The staleness warning outranks the plan nicety — showing
            // both would crowd into the totals column.
            name_spans[2].text = ui.fmt("  stale {d}m", .{mins});
        } else if (limits) |snap| {
            if (snap.plan.len > 0) name_spans[1].text = ui.fmt("  {s}", .{snap.plan});
        }
    }
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_x, y, 170, 16),
        .semantics = .{ .label = ui.fmt("{s} usage", .{name}) },
    }, &name_spans));

    // Right column of the name row: totals when there is anything to
    // total, otherwise the honest one-liner ("disabled" for a source
    // switched off in config, "no sessions found" for an agent with no
    // history and no limits, "scanning…" while catch-up may yet find some).
    const right_text: []const u8 = if (!enabled)
        "disabled"
    else if (empty and model.catchup_active)
        "scanning…"
    else if (empty)
        "no sessions found"
    else
        ui.fmt("{s} · {s}", .{ fmtTokens(ui, totals.totalTokens()), fmtCost(ui, totals.cost_usd) });
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_right - 140, y + 1, 140, 14),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, right_text));
    y += row_h;

    // Disabled and empty agents get no bars and no limit-data hint —
    // empty tracks under a "0 tok" line would just be lies in green.
    if (!enabled or empty) return y + 4;

    if (limits) |snap| {
        const shown = @min(snap.windows.len, 4);
        for (snap.windows[0..shown]) |window| {
            windowRow(ui, nodes, window, model.now_ms, y, stale_min != null);
            y += row_h;
        }
    } else {
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_x, y, bars_right - bars_x, 14),
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, switch (agent) {
            .claude => "no limit data — set claude-oauth = true",
            .codex => "no limit data in recent rollouts",
        }));
        y += row_h;
    }
    return y + 4;
}

fn windowRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), window: types.LimitWindow, now_ms: i64, y: f32, stale: bool) void {
    const label: []const u8 = switch (window.kind) {
        .five_hour => "5h",
        .weekly => "wk",
        .weekly_opus => "opus",
        .weekly_sonnet => "sonnet",
        .monthly => "mo",
    };
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_x, y, 42, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, label));

    const pct = std.math.clamp(window.used_percent, 0, 100);
    // Stale readings render at half strength, no tip glow — the bar is
    // the last known value, not the current one.
    const ink = if (stale) withAlpha(barColor(pct), 0.45) else barColor(pct);
    const track_x: f32 = bars_x + 46;
    const track_w: f32 = 78;
    push(ui, nodes, ui.panel(.{
        .frame = rect(track_x, y + 4, track_w, 6),
        .style = .{ .background = theme.track, .radius = 3, .stroke_width = 0 },
    }, .{}));
    if (pct > 0) {
        const fill_w = @max(track_w * @as(f32, @floatCast(pct)) / 100.0, 3);
        push(ui, nodes, ui.panel(.{
            .frame = rect(track_x, y + 4, fill_w, 6),
            .style = .{ .background = ink, .radius = 3, .stroke_width = 0 },
        }, .{}));
        if (!stale) {
            // LED tip glow at the leading edge.
            push(ui, nodes, ui.panel(.{
                .frame = rect(track_x + fill_w - 4, y + 2, 10, 10),
                .style = .{ .background = withAlpha(ink, 0.35), .radius = 5, .stroke_width = 0 },
            }, .{}));
        }
    }

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(track_x + track_w + 6, y, 34, 14),
        .text_alignment = .end,
        .style = .{ .foreground = ink },
    }, &.{.{ .text = ui.fmt("{d}%", .{@as(u64, @intFromFloat(pct))}), .monospace = true, .scale = 0.9 }}));

    if (window.resets_at_ms > now_ms) {
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_right - 48, y, 48, 14),
            .size = .sm,
            .text_alignment = .end,
            .style_tokens = .{ .foreground = .text_muted },
        }, fmtReset(ui, window.resets_at_ms - now_ms)));
    }
}

fn barColor(pct: f64) Color {
    if (pct >= 80) return theme.red;
    if (pct >= 50) return theme.amber;
    return theme.green;
}

// ------------------------------------------------------ odometer strip

fn odometerStrip(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const glance = engine.glanceState(model);

    push(ui, nodes, ui.panel(.{
        .frame = rect(16, strip_y, 528, strip_h),
        .style = .{ .background = theme.bezel, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
        .semantics = .{ .label = model.today_text },
    }, .{}));

    push(ui, nodes, ui.text(.{
        .frame = rect(34, strip_y + 14, 52, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "TODAY"));

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(92, strip_y + 8, 140, 26),
        .style = .{ .foreground = theme.green },
    }, &.{.{ .text = fmtCost(ui, glance.today_cost_usd), .weight = .bold, .monospace = true, .scale = 1.5 }}));

    push(ui, nodes, ui.panel(.{
        .frame = rect(244, strip_y + 8, 1, 26),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));

    // The token odometer: fixed digit cells, leading zeros dimmed.
    const digits = ui.fmt("{d:0>9}", .{glance.today_tokens});
    const cell_w: f32 = 18;
    const cell_h: f32 = 26;
    const cell_gap: f32 = 2;
    const total = @as(f32, @floatFromInt(digits.len)) * (cell_w + cell_gap) - cell_gap;
    var x: f32 = 478 - total;
    var significant = false;
    for (digits, 0..) |d, i| {
        if (d != '0' or i == digits.len - 1) significant = true;
        push(ui, nodes, ui.panel(.{
            .frame = rect(x, strip_y + 8, cell_w, cell_h),
            .style = .{ .background = theme.cell, .border = theme.cell_edge, .stroke_width = 1, .radius = 3 },
        }, .{
            ui.paragraph(.{
                .frame = rect(0, 5, cell_w, 16),
                .text_alignment = .center,
                .style = .{ .foreground = if (significant) theme.cluster_colors.text else Color.rgb8(52, 64, 60) },
            }, &.{.{ .text = digits[i .. i + 1], .monospace = true, .weight = .medium }}),
        }));
        x += cell_w + cell_gap;
    }
    push(ui, nodes, ui.text(.{
        .frame = rect(484, strip_y + 14, 44, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "tok"));
}

// ----------------------------------------------------- render animation

/// Needle sweep + redline pulse. The needle's STATIC pose is already
/// the target; the animation rotates from the previous pose's delta to
/// zero about the pivot, so a finished (or absent) animation rests on
/// truth. The redline halo ping-pongs its opacity while danger holds.
pub fn animations(model: *const Model, tree: *const Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    _ = tree;
    var count: usize = 0;
    const delta = model.needle_from_deg - model.needle_to_deg;
    if (@abs(delta) > 0.05) {
        // Panel chrome emits shadow/fill on part slots 1/2 — rotate both
        // so an opaque dot's drop shadow sweeps with its fill.
        for (0..needle_part_total) |i| {
            for ([_]canvas.ObjectId{ 1, 2 }) |slot| {
                if (count >= out.len) break;
                out[count] = .{
                    .id = partCommandId(needle_key_base + @as(u64, @intCast(i)), slot),
                    .start_ns = start_ns,
                    .duration_ms = 850,
                    .easing = .emphasized,
                    .from_rotation = delta,
                    .to_rotation = 0,
                    .rotation_center = .{ .x = gauge_cx, .y = gauge_cy },
                };
                count += 1;
            }
        }
    }
    if (engine.dangerState(model) and count < out.len) {
        out[count] = .{
            .id = partCommandId(redline_halo_key, 2),
            .start_ns = start_ns,
            .duration_ms = 800,
            .easing = .standard,
            .from_opacity = 0.3,
            .to_opacity = 1,
            .loop = .ping_pong,
        };
        count += 1;
    }
    return count;
}

fn partCommandId(key: u64, slot: canvas.ObjectId) canvas.ObjectId {
    return canvas.widgetCommandPartId(.{
        .widget_id = canvas.globalWidgetId(.panel, canvas.uiKey(key)),
        .slot = slot,
    });
}

// -------------------------------------------------------------- helpers

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.RectF {
    return geometry.RectF.init(x, y, w, h);
}

fn push(ui: *Ui, nodes: *std.ArrayList(Ui.Node), node: Ui.Node) void {
    nodes.append(ui.arena, node) catch {
        ui.failed = true;
    };
}

/// A point on the dial at `deg` (clockwise from 12 o'clock) and radius.
fn pointAt(deg: f32, radius: f32) geometry.PointF {
    const r = std.math.degreesToRadians(deg);
    return .{ .x = gauge_cx + radius * @sin(r), .y = gauge_cy - radius * @cos(r) };
}

fn withAlpha(color: Color, alpha: f32) Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * alpha };
}

fn zoneColor(frac: f32, red_start: f32, lit: bool) Color {
    if (frac >= red_start) return if (lit) theme.red else theme.red_dim;
    if (frac >= green_end) return if (lit) theme.amber else theme.amber_dim;
    return if (lit) theme.green else theme.green_dim;
}

/// Oldest-first tokens-per-minute buckets for the sparkline.
fn burnSpark(ui: *Ui, model: *const Model) []const f32 {
    const len = model.burn.buckets.len;
    const out = ui.arena.alloc(f32, len) catch {
        ui.failed = true;
        return &.{};
    };
    for (out, 0..) |*value, i| {
        const back = len - 1 - i;
        const idx = (model.burn.head + len - back) % len;
        value.* = @floatFromInt(model.burn.buckets[idx]);
    }
    return out;
}

fn fmtTokens(ui: *Ui, tokens: u64) []const u8 {
    const buf = ui.arena.alloc(u8, 24) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeHumanTokens(&w, tokens) catch {};
    return w.buffered();
}

fn fmtCost(ui: *Ui, usd: f64) []const u8 {
    const buf = ui.arena.alloc(u8, 32) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeCost(&w, usd) catch {};
    return w.buffered();
}

fn fmtClock(ui: *Ui, ts_ms: i64, tz_offset_min: i32) []const u8 {
    const buf = ui.arena.alloc(u8, 16) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeClock(&w, ts_ms, tz_offset_min) catch {};
    return w.buffered();
}

fn fmtCountdown(ui: *Ui, duration_ms: i64) []const u8 {
    const buf = ui.arena.alloc(u8, 16) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeCountdown(&w, duration_ms) catch {};
    return w.buffered();
}

/// Reset-column countdown: weekly windows run to days, where the core
/// "89h16m" form wraps the column — roll hours past 48 into days.
fn fmtReset(ui: *Ui, duration_ms: i64) []const u8 {
    const total_min = @max(@divFloor(duration_ms, 60_000), 0);
    const hours = @divFloor(total_min, 60);
    const minutes = @mod(total_min, 60);
    if (hours >= 48) return ui.fmt("{d}d{d}h", .{ @divFloor(hours, 24), @mod(hours, 24) });
    if (hours > 0) return ui.fmt("{d}h{d}m", .{ hours, minutes });
    return ui.fmt("{d}m", .{minutes});
}
