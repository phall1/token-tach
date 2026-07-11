//! The instrument cluster: a Zig-built canvas view plus a hand-built
//! chrome display list (the closed markup grammar has no rotated
//! primitives, but the chrome seam speaks raw `fillPath`/`strokePath`,
//! which DO transform point-by-point — the same pipeline the house
//! spinner rotates).
//!
//! Precision layout, calculator-style: the whole cluster is absolute —
//! every element is a `.frame` child of one stacking root — because the
//! tach needle and its render animation rotate about an ABSOLUTE pivot
//! (`gauge_cx`, `gauge_cy`); a flow layout would move the pivot out
//! from under the rotation. The window opens at exactly
//! `window_width` x `window_height` and the cluster is top-left
//! anchored, so resizing never invalidates the pivot.
//!
//! Layer order (automotive): chrome PREFIX paints the cabin — window
//! wash, gradient bezels, the shaded dial face with rim vignette and
//! bezel ring. Widgets paint the furniture — LED ticks, graduations,
//! numerals, readouts, bars, odometer. Chrome SUFFIX paints the metal
//! and the glass — the machined needle blade (a real tapered path
//! polygon at its TRUE angle), counterweight, hub, and a faint glass
//! glare arc over everything.
//!
//! Rest pose is truth: the blade is rebuilt at `needle_to_deg` on every
//! model rebuild; render animations only replay rotation deltas back to
//! zero, so screenshots and static pipelines land on the honest frame.
//! The ignition sweep (boot + every popover open) anchors its two
//! chained tweens on the journaled wall-clock `ignition_t0_ms`, so
//! mid-sweep rebuilds re-declare the same animation instead of
//! restarting it.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;
const PointF = geometry.PointF;

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

const gauge_panel = geometry.RectF.init(14, panel_y, 272, panel_h);
const limits_panel_rect = geometry.RectF.init(298, panel_y, 246, panel_h);
const strip_rect = geometry.RectF.init(16, strip_y, 528, strip_h);

// -------------------------------------------------------- dial geometry

/// Needle pivot in ABSOLUTE canvas coordinates — the rotation center
/// for the static needle pose and every sweep animation.
pub const gauge_cx: f32 = 150;
pub const gauge_cy: f32 = 198;

const dial_r: f32 = 120;
const tick_r: f32 = 101; // LED-ring radius (dot centers)
const minor_count: usize = 56;
const major_count: usize = 6; // five intervals, numerals 0..scale
const numeral_r: f32 = 74;

// The machined needle: a tapered blade polygon from hub to just short
// of the LED ring, a counterweight stub past the pivot, a tip glow.
const blade_tip_r: f32 = 93;
const blade_shoulder_r: f32 = 82;
const blade_base_r: f32 = 4;
const blade_base_hw: f32 = 3.4;
const blade_shoulder_hw: f32 = 1.3;
const tail_r0: f32 = -8;
const tail_r1: f32 = -22;
const tail_hw: f32 = 4.6;
const hub_r: f32 = 13;

const green_end: f32 = 0.60;
const red_start_calm: f32 = 0.85;
const red_start_danger: f32 = 0.70;

// Global keys for animated widget parts (LED ignition, redline pulse).
const led_key_base: u64 = 0xD1A1_1000;
const led_glow_key_base: u64 = 0xD1A1_2000;
const redline_halo_key: u64 = 0xD1A1_0004;

// ------------------------------------------------------ chrome commands
// Raw display-list command ids — a namespace far away from small widget
// part slots and effectively disjoint from hashed structural ids.

const chrome_id_base: u64 = 0x7AC8_0000;
pub const needle_blade_id: canvas.ObjectId = chrome_id_base + 16;
pub const needle_edge_id: canvas.ObjectId = chrome_id_base + 17;
pub const needle_glow_id: canvas.ObjectId = chrome_id_base + 18;

/// Commands painted UNDER the widget tree (cabin + dial face).
pub const chrome_prefix_commands: usize = 9;
/// Commands painted OVER the widget tree (needle metal + glass).
pub const chrome_suffix_commands: usize = 7;

// Static geometry the retained display list points into; rebuilt only
// inside `buildChrome` (which the runtime calls on every model
// rebuild), so content and retained commands never diverge.
var dial_face_elems: [6]canvas.PathElement = undefined;
var vignette_elems: [6]canvas.PathElement = undefined;
var bezel_ring_elems: [6]canvas.PathElement = undefined;
var dial_edge_elems: [6]canvas.PathElement = undefined;
var inner_ring_elems: [6]canvas.PathElement = undefined;
var blade_elems: [11]canvas.PathElement = undefined;
var tip_glow_elems: [6]canvas.PathElement = undefined;
var hub_elems: [6]canvas.PathElement = undefined;
var hub_cap_elems: [6]canvas.PathElement = undefined;
var glare_elems: [3]canvas.PathElement = undefined;

const bezel_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = theme.bezel_top },
    .{ .offset = 1, .color = theme.bezel_bottom },
};
const dial_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = theme.dial_top },
    .{ .offset = 1, .color = theme.dial_bottom },
};
const hub_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = theme.hub_top },
    .{ .offset = 1, .color = theme.hub_bottom },
};

/// The chrome display list: exactly `chrome_prefix_commands` commands,
/// then exactly `chrome_suffix_commands` — the runtime slices them
/// around the widget span by count.
pub fn buildChrome(
    model: *const Model,
    builder: *canvas.Builder,
    size: geometry.SizeF,
    tokens: canvas.DesignTokens,
) anyerror!void {
    _ = tokens;
    const center = PointF.init(gauge_cx, gauge_cy);

    // ---- prefix: cabin + dial face (under every widget) ----
    try builder.fillRect(.{
        .id = chrome_id_base + 1,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = theme.bg },
    });
    try bezelWash(builder, chrome_id_base + 2, gauge_panel, 10);
    try bezelWash(builder, chrome_id_base + 3, limits_panel_rect, 10);
    try bezelWash(builder, chrome_id_base + 4, strip_rect, 7);
    try builder.fillPath(.{
        .id = chrome_id_base + 5,
        .elements = circlePath(&dial_face_elems, center, dial_r),
        .fill = .{ .linear_gradient = .{
            .start = PointF.init(gauge_cx, gauge_cy - dial_r),
            .end = PointF.init(gauge_cx, gauge_cy + dial_r),
            .stops = &dial_stops,
        } },
    });
    // Rim vignette: a wide dark ring hugging the inside of the dial so
    // the face reads recessed, not printed.
    try builder.strokePath(.{
        .id = chrome_id_base + 6,
        .elements = circlePath(&vignette_elems, center, dial_r - 9),
        .stroke = .{ .fill = .{ .color = theme.dial_vignette }, .width = 18 },
    });
    // Machined bezel ring + the phosphor-tinted dial edge inside it.
    try builder.strokePath(.{
        .id = chrome_id_base + 7,
        .elements = circlePath(&bezel_ring_elems, center, dial_r + 0.5),
        .stroke = .{ .fill = .{ .color = theme.bezel_ring }, .width = 2 },
    });
    try builder.strokePath(.{
        .id = chrome_id_base + 8,
        .elements = circlePath(&dial_edge_elems, center, dial_r - 1.5),
        .stroke = .{ .fill = .{ .color = theme.dial_edge }, .width = 1 },
    });
    // Inner dial print: a faint circle framing the readout well.
    try builder.strokePath(.{
        .id = chrome_id_base + 9,
        .elements = circlePath(&inner_ring_elems, center, 58),
        .stroke = .{ .fill = .{ .color = withAlpha(theme.dial_edge, 0.7) }, .width = 1 },
    });

    // ---- suffix: needle metal + glass (over every widget) ----
    const deg = model.needle_to_deg;
    const blade = bladePath(deg);
    try builder.fillPath(.{
        .id = needle_blade_id,
        .elements = blade,
        .fill = .{ .color = theme.needle },
    });
    try builder.strokePath(.{
        .id = needle_edge_id,
        .elements = blade,
        .stroke = .{ .fill = .{ .color = theme.needle_edge }, .width = 1 },
    });
    const tip = dialPoint(deg, blade_tip_r - 3);
    try builder.fillPath(.{
        .id = needle_glow_id,
        .elements = circlePath(&tip_glow_elems, tip, 7),
        .fill = .{ .color = theme.needle_halo },
    });
    try builder.fillPath(.{
        .id = chrome_id_base + 19,
        .elements = circlePath(&hub_elems, center, hub_r),
        .fill = .{ .linear_gradient = .{
            .start = PointF.init(gauge_cx, gauge_cy - hub_r),
            .end = PointF.init(gauge_cx, gauge_cy + hub_r),
            .stops = &hub_stops,
        } },
    });
    try builder.strokePath(.{
        .id = chrome_id_base + 20,
        .elements = &hub_elems, // same circle, stroked as the hub rim
        .stroke = .{ .fill = .{ .color = theme.hub_ring }, .width = 1 },
    });
    try builder.fillPath(.{
        .id = chrome_id_base + 21,
        .elements = circlePath(&hub_cap_elems, center, 3.5),
        .fill = .{ .color = theme.needle },
    });
    // Glass glare: one faint arc across the upper face — the only hint
    // that there is a crystal over the dial.
    try builder.strokePath(.{
        .id = chrome_id_base + 22,
        .elements = arcPath(&glare_elems, dial_r - 18, -100, -18),
        .stroke = .{ .fill = .{ .color = theme.glass_glare }, .width = 9 },
        .cap = .round,
    });
}

fn bezelWash(builder: *canvas.Builder, id: canvas.ObjectId, frame: geometry.RectF, radius: f32) !void {
    try builder.fillRoundedRect(.{
        .id = id,
        .rect = frame,
        .radius = canvas.Radius.all(radius),
        .fill = .{ .linear_gradient = .{
            .start = frame.topLeft(),
            .end = PointF.init(frame.x, frame.y + frame.height),
            .stops = &bezel_stops,
        } },
    });
}

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
    // Transparent root: the chrome prefix owns the window wash, so the
    // gradient bezels and dial face painted under the widgets show.
    return ui.panel(.{
        .grow = 1,
        .style = .{ .background = theme.transparent, .radius = 0, .stroke_width = 0 },
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

    push(ui, nodes, ui.button(.{
        .frame = rect(354, header_y + 1, 66, 22),
        .size = .sm,
        .on_press = .open_dashboard,
        .semantics = .{ .label = "Open dashboard" },
    }, "DASH"));

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
    const igniting = model.ignition_phase != .off;

    // Gauge bezel border (fill is chrome; the widget carries the edge).
    push(ui, nodes, ui.panel(.{
        .frame = gauge_panel,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
    }, .{}));

    // Redline halo: a pulsing glow behind the red zone while danger holds.
    if (danger) {
        const mid_deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * (red_start + 1) / 2;
        const p = dialPoint(mid_deg, 88);
        push(ui, nodes, ui.panel(.{
            .global_key = canvas.uiKey(redline_halo_key),
            .frame = rect(p.x - 42, p.y - 42, 84, 84),
            .style = .{ .background = theme.red_halo, .radius = 42, .stroke_width = 0 },
        }, .{}));
    }

    // The LED ring: 56 dots swept 240°, lit up to the needle, each lit
    // dot over a soft under-glow so the ring reads backlit. During the
    // ignition sweep every LED is drawn lit (over its unlit base) and
    // keyed, so the render animations can pop them in behind the
    // needle and fade the overshoot back out.
    for (0..minor_count) |i| {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(minor_count - 1));
        const deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * frac;
        const in_red = frac >= red_start;
        const lit_static = frac <= needle_frac + 0.001 or (danger and in_red);
        const lit = lit_static or igniting;
        const p = dialPoint(deg, tick_r);
        if (!lit_static or igniting) {
            // The unlit skeleton dot (also the base under an
            // ignition-animated LED, so opacity 0 isn't a hole).
            push(ui, nodes, ui.panel(.{
                .frame = rect(p.x - 2.5, p.y - 2.5, 5, 5),
                .style = .{ .background = zoneColor(frac, red_start, false), .radius = 2.5, .stroke_width = 0 },
            }, .{}));
        }
        if (lit) {
            const ink = zoneColor(frac, red_start, true);
            push(ui, nodes, ui.panel(.{
                .global_key = canvas.uiKey(led_glow_key_base + @as(u64, @intCast(i))),
                .frame = rect(p.x - 5.5, p.y - 5.5, 11, 11),
                .style = .{ .background = withAlpha(ink, 0.17), .radius = 5.5, .stroke_width = 0 },
            }, .{}));
            push(ui, nodes, ui.panel(.{
                .global_key = canvas.uiKey(led_key_base + @as(u64, @intCast(i))),
                .frame = rect(p.x - 2.5, p.y - 2.5, 5, 5),
                .style = .{ .background = ink, .radius = 2.5, .stroke_width = 0 },
            }, .{}));
        }
    }

    // Major graduations + numerals (thousands of tokens/min).
    for (0..major_count) |i| {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(major_count - 1));
        const deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * frac;
        const bright: Color = if (frac >= red_start) theme.red else Color.rgb8(208, 226, 218);
        const p = dialPoint(deg, tick_r);
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - 3.5, p.y - 3.5, 7, 7),
            .style = .{ .background = bright, .radius = 3.5, .stroke_width = 0 },
        }, .{}));

        const n = dialPoint(deg, numeral_r);
        const thousands = scale / 5.0 * @as(f64, @floatFromInt(i)) / 1000.0;
        push(ui, nodes, ui.paragraph(.{
            .frame = rect(n.x - 18, n.y - 8, 36, 16),
            .text_alignment = .center,
            .style = .{ .foreground = if (frac >= red_start) theme.red else Color.rgb8(196, 214, 205) },
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
        .frame = limits_panel_rect,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
    }, .{}));

    var y: f32 = panel_y + 16;
    y = agentGroup(ui, nodes, model, .claude, model.claude_limits, y);
    push(ui, nodes, ui.panel(.{
        .frame = rect(bars_x, y, bars_right - bars_x, 1),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    _ = agentGroup(ui, nodes, model, .codex, model.codex_limits, y + 10);
    compactOpenCodeRow(ui, nodes, model);

    // Burn history trace pinned to the panel foot: an area-filled scope
    // line on a square-root scale, so one spike no longer flattens the
    // whole 15 minutes (the peak caption keeps the raw number honest).
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
            .stroke_width = 1.5,
            .semantics = .{ .label = "Burn history" },
        }, &.{.{ .kind = .line, .values = burnSpark(ui, model), .color = .accent, .fill = true, .label = "burn" }}),
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
        .opencode => "OPENCODE",
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
        // Two short lines instead of one clipped one: the fact, then
        // the remedy.
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_x, y, bars_right - bars_x, 14),
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, "no limit data"));
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_x, y + 15, bars_right - bars_x, 14),
            .size = .sm,
            .style = .{ .foreground = theme.text_faint },
        }, switch (agent) {
            .claude => "set claude-oauth = true in config",
            .codex => "none embedded in recent rollouts",
            .opencode => "API-equivalent usage only",
        }));
        y += row_h + 14;
    }
    return y + 4;
}

fn compactOpenCodeRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const y = panel_y + 194;
    const enabled = model.cfg.sources.opencode;
    const totals = model.ledger.forAgent(.opencode);
    const empty = enabled and engine.agentIsEmpty(model, .opencode);
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_x, y, 100, 16),
        .semantics = .{ .label = "OpenCode API-equivalent usage" },
    }, &.{.{ .text = "OPENCODE", .weight = .bold, .monospace = true }}));
    const value: []const u8 = if (!enabled)
        "disabled"
    else if (empty)
        "no messages found"
    else
        ui.fmt("{s} · {s}", .{ fmtTokens(ui, totals.totalTokens()), fmtCost(ui, totals.cost_usd) });
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_right - 140, y + 1, 140, 14),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, value));
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
        .frame = strip_rect,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 7 },
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

    // The token odometer: fixed digit cells with a machined inset (top
    // shadow line, bottom glint line), leading zeros dimmed.
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
            ui.panel(.{
                .frame = rect(1, 1, cell_w - 2, 2),
                .style = .{ .background = theme.cell_shadow, .radius = 0, .stroke_width = 0 },
            }, .{}),
            ui.panel(.{
                .frame = rect(1, cell_h - 2, cell_w - 2, 1),
                .style = .{ .background = theme.cell_glint, .radius = 0, .stroke_width = 0 },
            }, .{}),
            ui.paragraph(.{
                .frame = rect(0, 5, cell_w, 16),
                .text_alignment = .center,
                .style = .{ .foreground = if (significant) theme.cluster_colors.text else theme.text_faint },
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

/// The three chrome commands that ARE the needle (blade fill, blade
/// edge, tip glow) — every sweep rotates all three about the pivot.
pub const needle_command_ids = [_]canvas.ObjectId{ needle_blade_id, needle_edge_id, needle_glow_id };

/// Render animations: the ignition sweep (boot / popover open), the
/// steady needle sweep between poses, and the redline pulse.
///
/// The needle's STATIC pose is already the target; animations only
/// rotate a delta back to zero about the pivot, so a finished (or
/// absent) animation rests on truth. Ignition anchors on the journaled
/// wall-clock `ignition_t0_ms` (the frame clock is wall time on macOS),
/// which makes mid-sweep re-declarations idempotent: a 30 ms catch-up
/// tick re-declares the same tween rather than restarting it.
pub fn animations(model: *const Model, tree: *const Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    _ = tree;
    var count: usize = 0;
    const to_deg = model.needle_to_deg;

    if (model.ignition_phase != .off and model.ignition_t0_ms > 0) {
        const t0_ns: u64 = @intCast(model.ignition_t0_ms * std.time.ns_per_ms);
        const up_ns: u64 = @as(u64, engine.ignition_up_ms) * std.time.ns_per_ms;
        const full = engine.half_sweep_deg;

        // Needle: 0 → full scale (up), then full scale → truth (settle).
        for (needle_command_ids) |id| {
            if (count >= out.len) break;
            out[count] = switch (model.ignition_phase) {
                .up => .{
                    .id = id,
                    .start_ns = t0_ns,
                    .duration_ms = engine.ignition_up_ms,
                    .easing = .emphasized,
                    .from_rotation = -full - to_deg,
                    .to_rotation = full - to_deg,
                    .rotation_center = .{ .x = gauge_cx, .y = gauge_cy },
                },
                else => .{
                    .id = id,
                    .start_ns = t0_ns + up_ns,
                    .duration_ms = engine.ignition_settle_ms,
                    .easing = .emphasized,
                    .from_rotation = full - to_deg,
                    .to_rotation = 0,
                    .rotation_center = .{ .x = gauge_cx, .y = gauge_cy },
                },
            };
            count += 1;
        }

        // LED ring: each LED pops in the instant the needle passes it
        // on the way up, and the overshoot fades back out behind the
        // needle on the way down. The stagger inverts the sweep's
        // emphasized ease so light and needle stay locked.
        const final_frac = (to_deg + full) / (2 * full);
        for (0..minor_count) |i| {
            const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(minor_count - 1));
            const keys = [_]u64{
                led_key_base + @as(u64, @intCast(i)),
                led_glow_key_base + @as(u64, @intCast(i)),
            };
            switch (model.ignition_phase) {
                .up => {
                    const at_ns = t0_ns + @as(u64, @intFromFloat(@as(f64, @floatCast(invEmphasized(frac))) * @as(f64, @floatFromInt(up_ns))));
                    ledFade(&count, out, keys, at_ns, 0, 1);
                },
                else => {
                    if (frac <= final_frac + 0.001 or final_frac >= 0.999) continue;
                    const cross = (1 - frac) / (1 - final_frac);
                    const settle_ns = @as(u64, engine.ignition_settle_ms) * std.time.ns_per_ms;
                    const at_ns = t0_ns + up_ns + @as(u64, @intFromFloat(@as(f64, @floatCast(invEmphasized(cross))) * @as(f64, @floatFromInt(settle_ns))));
                    ledFade(&count, out, keys, at_ns, 1, 0);
                },
            }
        }
    } else {
        const delta = model.needle_from_deg - model.needle_to_deg;
        if (@abs(delta) > 0.05) {
            for (needle_command_ids) |id| {
                if (count >= out.len) break;
                out[count] = .{
                    .id = id,
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

/// One LED's ignition fade: opacity tweens on the dot and glow panels'
/// shadow + fill command slots (translucent fills emit no shadow — the
/// unmatched override id is simply never found, which is fine).
fn ledFade(count: *usize, out: []canvas.CanvasRenderAnimation, keys: [2]u64, at_ns: u64, from: f32, to: f32) void {
    for (keys) |key| {
        for ([_]canvas.ObjectId{ 1, 2 }) |slot| {
            if (count.* >= out.len) return;
            out[count.*] = .{
                .id = partCommandId(key, slot),
                .start_ns = at_ns,
                .duration_ms = 110,
                .easing = .standard,
                .from_opacity = from,
                .to_opacity = to,
            };
            count.* += 1;
        }
    }
}

/// Inverse of the `.emphasized` ease (1 - (1-t)^3): the sweep progress
/// at which the eased needle crosses eased-position `p`.
fn invEmphasized(p: f32) f32 {
    const clamped = std.math.clamp(p, 0, 1);
    return 1 - std.math.pow(f32, 1 - clamped, 1.0 / 3.0);
}

fn partCommandId(key: u64, slot: canvas.ObjectId) canvas.ObjectId {
    return canvas.widgetCommandPartId(.{
        .widget_id = canvas.globalWidgetId(.panel, canvas.uiKey(key)),
        .slot = slot,
    });
}

// ------------------------------------------------------- path geometry

/// A point on the dial at `deg` (clockwise from 12 o'clock) and radius.
fn dialPoint(deg: f32, radius: f32) PointF {
    const r = std.math.degreesToRadians(deg);
    return .{ .x = gauge_cx + radius * @sin(r), .y = gauge_cy - radius * @cos(r) };
}

/// The needle silhouette at its true angle: a tapered blade from hub to
/// tip plus a counterweight stub past the pivot, as two subpaths of one
/// fillable polygon. Positive offsets are clockwise of the needle ray.
fn bladePath(deg: f32) []const canvas.PathElement {
    const rad = std.math.degreesToRadians(deg);
    const frame = NeedleFrame{
        .ux = @sin(rad),
        .uy = -@cos(rad),
        .vx = @cos(rad),
        .vy = @sin(rad),
    };
    blade_elems[0] = moveTo(frame.at(blade_base_r, -blade_base_hw));
    blade_elems[1] = lineTo(frame.at(blade_shoulder_r, -blade_shoulder_hw));
    blade_elems[2] = lineTo(frame.at(blade_tip_r, 0));
    blade_elems[3] = lineTo(frame.at(blade_shoulder_r, blade_shoulder_hw));
    blade_elems[4] = lineTo(frame.at(blade_base_r, blade_base_hw));
    blade_elems[5] = closePath();
    blade_elems[6] = moveTo(frame.at(tail_r0, -tail_hw));
    blade_elems[7] = lineTo(frame.at(tail_r1, -tail_hw));
    blade_elems[8] = lineTo(frame.at(tail_r1, tail_hw));
    blade_elems[9] = lineTo(frame.at(tail_r0, tail_hw));
    blade_elems[10] = closePath();
    return &blade_elems;
}

const NeedleFrame = struct {
    ux: f32,
    uy: f32,
    vx: f32,
    vy: f32,

    fn at(self: NeedleFrame, r: f32, offset: f32) PointF {
        return .{
            .x = gauge_cx + self.ux * r + self.vx * offset,
            .y = gauge_cy + self.uy * r + self.vy * offset,
        };
    }
};

/// A full circle as four cubic segments (the classic kappa constant).
fn circlePath(buf: *[6]canvas.PathElement, c: PointF, r: f32) []const canvas.PathElement {
    const k = r * 0.5522847498307936;
    buf[0] = moveTo(.{ .x = c.x + r, .y = c.y });
    buf[1] = cubicTo(.{ .x = c.x + r, .y = c.y + k }, .{ .x = c.x + k, .y = c.y + r }, .{ .x = c.x, .y = c.y + r });
    buf[2] = cubicTo(.{ .x = c.x - k, .y = c.y + r }, .{ .x = c.x - r, .y = c.y + k }, .{ .x = c.x - r, .y = c.y });
    buf[3] = cubicTo(.{ .x = c.x - r, .y = c.y - k }, .{ .x = c.x - k, .y = c.y - r }, .{ .x = c.x, .y = c.y - r });
    buf[4] = cubicTo(.{ .x = c.x + k, .y = c.y - r }, .{ .x = c.x + r, .y = c.y - k }, .{ .x = c.x + r, .y = c.y });
    buf[5] = closePath();
    return buf;
}

/// An open dial-space arc from `a0` to `a1` degrees (12 o'clock = 0,
/// clockwise) at `radius`, as two cubic segments.
fn arcPath(buf: *[3]canvas.PathElement, radius: f32, a0: f32, a1: f32) []const canvas.PathElement {
    buf[0] = moveTo(dialPoint(a0, radius));
    const mid = (a0 + a1) / 2;
    buf[1] = arcSegment(radius, a0, mid);
    buf[2] = arcSegment(radius, mid, a1);
    return buf;
}

/// One <=90° cubic approximation of the dial-space arc from `a0` to
/// `a1` degrees; assumes the pen is already at `a0`.
fn arcSegment(radius: f32, a0: f32, a1: f32) canvas.PathElement {
    const r0 = std.math.degreesToRadians(a0);
    const r1 = std.math.degreesToRadians(a1);
    const k = (4.0 / 3.0) * @tan((r1 - r0) / 4) * radius;
    const from = dialPoint(a0, radius);
    const to = dialPoint(a1, radius);
    // Tangent of (sin a, -cos a) is (cos a, sin a) — clockwise travel.
    return cubicTo(
        .{ .x = from.x + k * @cos(r0), .y = from.y + k * @sin(r0) },
        .{ .x = to.x - k * @cos(r1), .y = to.y - k * @sin(r1) },
        to,
    );
}

fn moveTo(p: PointF) canvas.PathElement {
    return .{ .verb = .move_to, .points = .{ p, PointF.zero(), PointF.zero() } };
}

fn lineTo(p: PointF) canvas.PathElement {
    return .{ .verb = .line_to, .points = .{ p, PointF.zero(), PointF.zero() } };
}

fn cubicTo(c1: PointF, c2: PointF, end: PointF) canvas.PathElement {
    return .{ .verb = .cubic_to, .points = .{ c1, c2, end } };
}

fn closePath() canvas.PathElement {
    return .{ .verb = .close };
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

fn withAlpha(color: Color, alpha: f32) Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * alpha };
}

fn zoneColor(frac: f32, red_start: f32, lit: bool) Color {
    if (frac >= red_start) return if (lit) theme.red else theme.red_dim;
    if (frac >= green_end) return if (lit) theme.amber else theme.amber_dim;
    return if (lit) theme.green else theme.green_dim;
}

/// Oldest-first tokens-per-minute buckets for the burn trace, on a
/// square-root scale (0 stays 0, ordering preserved, spikes tamed).
fn burnSpark(ui: *Ui, model: *const Model) []const f32 {
    const len = model.burn.buckets.len;
    const out = ui.arena.alloc(f32, len) catch {
        ui.failed = true;
        return &.{};
    };
    for (out, 0..) |*value, i| {
        const back = len - 1 - i;
        const idx = (model.burn.head + len - back) % len;
        value.* = @sqrt(@as(f32, @floatFromInt(model.burn.buckets[idx])));
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
