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
//! Absolute does NOT mean hand-picked: every region whose height depends
//! on the data derives that height from one pure function of the model
//! (`rightLayout`), which both the chrome pass and the widget pass call.
//! The limits region used to flow while the rows under it sat on baked
//! constants, so a Claude account reporting four limit windows drew its
//! weekly bar straight through the aggregate row. Constants that encode
//! content height are the bug; deriving them is the fix.
//!
//! Layer order (automotive): chrome PREFIX paints the cabin — window
//! wash, gradient bezels, the shaded dial face with rim vignette and
//! bezel ring. Widgets paint the furniture — LED ticks, graduations,
//! numerals, readouts, bars, odometer, telltales, the MFD. Chrome
//! SUFFIX paints the metal and the glass — the machined needle blade (a
//! real tapered path polygon at its TRUE angle), counterweight, hub, and
//! a faint glass glare arc over everything.
//!
//! Rest pose is truth: the blade is rebuilt at `needle_to_deg` on every
//! model rebuild; render animations only replay rotation deltas back to
//! zero, so screenshots and static pipelines land on the honest frame.
//! The ignition sweep (boot + every popover open) anchors its two
//! chained tweens on the journaled wall-clock `ignition_t0_ms`, so
//! mid-sweep rebuilds re-declare the same animation instead of
//! restarting it.
//!
//! Every trace on this panel is anchored on `now_ms`, never on a ring's
//! head. A head-anchored read draws the last burst hard against the
//! right edge forever, so after half an hour of silence the chart said
//! "flat out" while the number beside it correctly said zero — and the
//! chart is the liar people believe. `nowAligned*` re-anchors each ring
//! read on the view's own clock, which makes that bug inexpressible even
//! if some future caller forgets to advance the ring.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const sessions = @import("core/sessions.zig");
const predict = @import("core/predict.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;
const PointF = geometry.PointF;

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const Ui = canvas.Ui(Msg);

// ------------------------------------------------------ window geometry

pub const window_width: f32 = 640;
pub const window_height: f32 = 500;

const header_y: f32 = 12;
const panel_y: f32 = 46;
const panel_h: f32 = 304;
const panel_bottom: f32 = panel_y + panel_h;
const strip_y: f32 = 358;
const strip_h: f32 = 42;
const system_y: f32 = 406;
const system_h: f32 = 62;
const footer_y: f32 = 474;

const gauge_panel = geometry.RectF.init(14, panel_y, 272, panel_h);
const right_x: f32 = 298;
const right_w: f32 = 328;
const strip_rect = geometry.RectF.init(14, strip_y, 612, strip_h);
const system_rect = geometry.RectF.init(14, system_y, 612, system_h);

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

/// The redline is PRINTED, not computed. It used to slide between 0.85
/// and 0.70 with `dangerState`, re-inking eight LEDs and two numerals as
/// the danger flag flipped — a dial whose scale markings move is the one
/// automotive lie the design cannot afford, because it makes the same
/// needle angle mean two different things a second apart. Danger now
/// speaks through the halo pulse and the RED telltale, which is how a
/// real cluster says it.
const red_start: f32 = 0.85;

// Global keys for animated widget parts (LED ignition, redline pulse,
// the live lamp, per-agent activity pips).
const led_key_base: u64 = 0xD1A1_1000;
const led_glow_key_base: u64 = 0xD1A1_2000;
const redline_halo_key: u64 = 0xD1A1_0004;
const live_lamp_key: u64 = 0xD1A1_0005;
const activity_key_base: u64 = 0xD1A1_3000;

// ------------------------------------------------------ chrome commands
// Raw display-list command ids — a namespace far away from small widget
// part slots and effectively disjoint from hashed structural ids.

const chrome_id_base: u64 = 0x7AC8_0000;
pub const needle_blade_id: canvas.ObjectId = chrome_id_base + 16;
pub const needle_edge_id: canvas.ObjectId = chrome_id_base + 17;
pub const needle_glow_id: canvas.ObjectId = chrome_id_base + 18;

/// Commands painted UNDER the widget tree (cabin + dial face).
pub const chrome_prefix_commands: usize = 11;
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
/// around the widget span by count. The two right-hand washes take their
/// frames from `rightLayout`, the same pure function the widget pass
/// uses, so a data-driven panel height can never leave a wash behind.
pub fn buildChrome(
    model: *const Model,
    builder: *canvas.Builder,
    size: geometry.SizeF,
    tokens: canvas.DesignTokens,
) anyerror!void {
    _ = tokens;
    const center = PointF.init(gauge_cx, gauge_cy);
    const layout = rightLayout(model);

    // ---- prefix: cabin + dial face (under every widget) ----
    try builder.fillRect(.{
        .id = chrome_id_base + 1,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = theme.bg },
    });
    try bezelWash(builder, chrome_id_base + 2, gauge_panel, 10);
    try bezelWash(builder, chrome_id_base + 3, layout.limits, 10);
    try bezelWash(builder, chrome_id_base + 11, layout.mfd, 10);
    try bezelWash(builder, chrome_id_base + 4, strip_rect, 7);
    try bezelWash(builder, chrome_id_base + 10, system_rect, 7);
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

// --------------------------------------------------- right-column layout

const right_pad: f32 = 12;
const bars_x: f32 = right_x + 14; // panel content left edge
const bars_right: f32 = right_x + right_w - 14; // panel content right edge
const col_gap: f32 = 16;
const col_w: f32 = (bars_right - bars_x - col_gap) / 2;
const col1_x: f32 = bars_x + col_w + col_gap;

const name_block_h: f32 = 32;
const win_row_h: f32 = 20;
const hint_h: f32 = 30;
const others_h: f32 = 18;
const region_gap: f32 = 10;

/// The two right-hand panels' frames, derived from the limits content.
pub const RightLayout = struct {
    /// Limit windows: claude and codex side by side, then the aggregate.
    limits: geometry.RectF,
    /// The multi-function display takes whatever the limits leave.
    mfd: geometry.RectF,
};

/// Where the right column's two panels start and stop, as a pure
/// function of the model.
///
/// This is the fix for the overlap that shipped: the limits rows flowed
/// while the aggregate row and the trace caption underneath sat on baked
/// y constants, so the moment `oauth.zig` reported four Claude windows
/// instead of two, the fourth bar and the OTHERS line drew on top of
/// each other. Both call sites (chrome wash, widget tree) read the same
/// derivation here, and the height is BOUNDED by construction: at most
/// four window rows per agent, so `limits` never exceeds
/// `right_pad*2 + name_block_h + 4*win_row_h + region_gap + others_h`
/// (164), leaving the MFD at least 130 points.
pub fn rightLayout(model: *const Model) RightLayout {
    const claude_h = agentColumnHeight(model, .claude, model.claude_limits);
    const codex_h = agentColumnHeight(model, .codex, model.codex_limits);
    const content = @max(claude_h, codex_h) + region_gap + others_h;
    const limits_h = right_pad * 2 + content;
    const mfd_y = panel_y + limits_h + region_gap;
    return .{
        .limits = geometry.RectF.init(right_x, panel_y, right_w, limits_h),
        .mfd = geometry.RectF.init(right_x, mfd_y, right_w, panel_bottom - mfd_y),
    };
}

/// Height one agent column needs: the name block, plus its limit rows,
/// its two-line "no limit data" remedy, or nothing at all when the
/// source is off or empty.
fn agentColumnHeight(model: *const Model, agent: types.Agent, limits: ?types.LimitSnapshot) f32 {
    if (!engine.sourceEnabled(model.cfg.sources, agent)) return name_block_h;
    if (engine.agentIsEmpty(model, agent)) return name_block_h;
    if (limits) |snap| {
        const shown: f32 = @floatFromInt(@min(snap.windows.len, 4));
        return name_block_h + shown * win_row_h;
    }
    return name_block_h + hint_h;
}

// ------------------------------------------------------------- the view

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    var nodes: std.ArrayList(Ui.Node) = .empty;
    const layout = rightLayout(model);
    header(ui, &nodes, model);
    gaugeCluster(ui, &nodes, model);
    limitsPanel(ui, &nodes, model, layout.limits);
    mfdPanel(ui, &nodes, model, layout.mfd);
    odometerStrip(ui, &nodes, model);
    systemStrip(ui, &nodes, model);
    // Footer: normally the engine status line; while a system cell is
    // hovered it reveals that cell's full-precision reading (SDK hover
    // Msgs). The reveal wins because it is what the pointer is asking for.
    const footer_text = if (model.hovered_system) |t|
        (systemHoverDetail(ui, model, t) orelse model.status_text)
    else
        model.status_text;
    push(ui, &nodes, ui.statusBar(.{
        .frame = rect(0, footer_y, window_width, window_height - footer_y),
    }, footer_text));
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
        .frame = rect(18, header_y, 150, 22),
        .semantics = .{ .label = "Token Tach" },
    }, &.{
        .{ .text = "TOKEN", .weight = .bold, .monospace = true, .scale = 1.2, .color = .text },
        .{ .text = " TACH", .weight = .bold, .monospace = true, .scale = 1.2, .color = .accent },
    }));

    telltales(ui, nodes, model, glance, danger);

    // Live LED: green while burning, red in danger, unlit when idle. The
    // glow is keyed so `animations` can breathe it while work is running
    // — the one always-visible proof the panel is live and not a frozen
    // screenshot.
    const led: Color = if (danger) theme.red else if (glance.idle) theme.track else theme.green;
    const led_word: []const u8 = if (danger) "REDLINE" else if (glance.idle) "IDLE" else "LIVE";
    if (!glance.idle or danger) {
        const glow = if (danger) theme.red_halo else theme.green_glow;
        push(ui, nodes, ui.panel(.{
            .global_key = canvas.uiKey(live_lamp_key),
            .frame = rect(432, header_y + 4, 16, 16),
            .style = .{ .background = glow, .radius = 8, .stroke_width = 0 },
        }, .{}));
    }
    push(ui, nodes, ui.panel(.{
        .frame = rect(436, header_y + 8, 8, 8),
        .style = .{ .background = led, .radius = 4, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.text(.{
        .frame = rect(452, header_y + 4, 96, 16),
        .size = .sm,
        .style = .{ .foreground = if (danger) theme.red else theme.cluster_colors.text_muted },
    }, led_word));

    push(ui, nodes, ui.button(.{
        .frame = rect(560, header_y + 1, 66, 22),
        .size = .sm,
        .on_press = .open_dashboard,
        .semantics = .{ .label = "Open dashboard" },
    }, "DASH"));
}

// ------------------------------------------------------------ telltales

/// One warning lamp. A cluster prints every lamp it owns and lights only
/// what applies, so the dark glyph is design rather than absence — and
/// the row reads the same way every time, which is what makes a lit lamp
/// noticeable at a glance.
const Telltale = struct {
    code: []const u8,
    label: []const u8,
    lit: bool,
    ink: Color,
    /// Lamps that are also controls (ALRT acknowledges).
    press: ?Msg = null,
};

const telltale_x: f32 = 172;
const telltale_pitch: f32 = 36;
const telltale_w: f32 = 32;

fn telltales(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, glance: trayfmt.GlanceState, danger: bool) void {
    const alert_pending = alertPending(model);
    const lamps = [_]Telltale{
        .{ .code = "RED", .label = "redline", .lit = danger, .ink = theme.red },
        .{ .code = "WALL", .label = "limit wall projected", .lit = glance.wall_at_ms != null, .ink = theme.amber },
        .{ .code = "STL", .label = "stale limit reading", .lit = engine.oauthStaleMin(model) != null, .ink = theme.amber },
        .{
            .code = "ALRT",
            .label = "unacknowledged alert",
            .lit = alert_pending,
            .ink = theme.amber,
            .press = if (alert_pending) Msg.alert_ack else null,
        },
        .{ .code = "SRC", .label = "source error", .lit = model.status_error, .ink = theme.red },
        .{ .code = "LOAD", .label = "machine load", .lit = loadWarn(model), .ink = theme.amber },
        .{ .code = "BAT", .label = "battery low", .lit = batteryWarn(model), .ink = theme.red },
    };

    for (lamps, 0..) |lamp, i| {
        const x = telltale_x + telltale_pitch * @as(f32, @floatFromInt(i));
        push(ui, nodes, ui.panel(.{
            .frame = rect(x, header_y + 3, telltale_w, 18),
            .style = .{
                .background = if (lamp.lit) withAlpha(lamp.ink, 0.16) else theme.telltale_plate,
                .radius = 3,
                .stroke_width = 0,
            },
            .on_press = lamp.press,
            .semantics = .{ .label = ui.fmt("{s} telltale {s}", .{ lamp.label, if (lamp.lit) "on" else "off" }) },
        }, .{}));
        push(ui, nodes, ui.paragraph(.{
            .frame = rect(x, header_y + 6, telltale_w, 13),
            .text_alignment = .center,
            .style = .{ .foreground = if (lamp.lit) lamp.ink else theme.telltale_off },
        }, &.{.{ .text = lamp.code, .weight = .bold, .monospace = true, .scale = 0.72 }}));
    }
}

/// Has an alert fired since the user last acknowledged? The alert engine
/// keeps a fire stamp per (agent, kind); the newest of those IS the
/// alert state, and `ux.alerts_acked_ms` is the line the user drew under
/// it by pressing the lamp.
fn alertPending(model: *const Model) bool {
    var newest: i64 = 0;
    for (model.alerts.last_fired_ms) |per_kind| {
        for (per_kind) |maybe| {
            if (maybe) |ms| newest = @max(newest, ms);
        }
    }
    return newest > 0 and newest > model.ux.alerts_acked_ms;
}

/// The LOAD lamp: the machine itself is the constraint right now. Kernel
/// memory pressure outranks any percentage — "critical" is the kernel
/// saying it, not us inferring it.
fn loadWarn(model: *const Model) bool {
    if (model.system_snap.mem) |m| {
        if (m.pressure == .critical) return true;
    }
    if (model.system_snap.cpu) |c| {
        if (c.total_frac >= 0.9) return true;
    }
    return false;
}

fn batteryWarn(model: *const Model) bool {
    const b = model.system_snap.battery orelse return false;
    return !b.charging and b.charge <= 0.15;
}

// ---------------------------------------------------------- tach gauge

fn gaugeCluster(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const glance = engine.glanceState(model);
    const danger = engine.dangerState(model);
    const scale = engine.gaugeScaleTpm(model.gauge_peak_tpm);
    const needle_frac = (model.needle_to_deg + engine.half_sweep_deg) / (2 * engine.half_sweep_deg);
    const igniting = model.ignition_phase != .off;

    // Gauge bezel border (fill is chrome; the widget carries the edge).
    push(ui, nodes, ui.panel(.{
        .frame = gauge_panel,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
    }, .{}));

    // Redline halo: a pulsing glow behind the red zone while danger holds.
    // With the redline printed at a fixed angle, this pulse and the RED
    // telltale carry the whole danger signal.
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
                .style = .{ .background = zoneColor(frac, false), .radius = 2.5, .stroke_width = 0 },
            }, .{}));
        }
        if (lit) {
            const ink = zoneColor(frac, true);
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

    dialReadout(ui, nodes, model, glance, danger);
    burnTrace(ui, nodes, model);
}

/// The in-dial readout well: one big number, one supporting line, and
/// the hottest agent.
///
/// The number CYCLES (press it — `readout_cycle`): rate, today, trip,
/// eta. A tach that can only show instantaneous rate makes you open the
/// dashboard to answer "what has this cost me", which is the question
/// people actually have at 4pm.
fn dialReadout(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, glance: trayfmt.GlanceState, danger: bool) void {
    const r = readout(ui, model, glance, danger);

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(gauge_cx - 70, gauge_cy + 18, 140, 36),
        .text_alignment = .center,
        .style = .{ .foreground = r.ink },
        .semantics = .{ .label = r.semantics },
    }, &.{.{ .text = r.value, .weight = .bold, .monospace = true, .scale = 2.2 }}));

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(gauge_cx - 80, gauge_cy + 54, 160, 16),
        .text_alignment = .center,
        .style = .{ .foreground = r.caption_ink },
    }, &.{.{ .text = r.caption, .monospace = true, .scale = 0.9 }}));

    hotAgentChip(ui, nodes, model);

    // The press target sits above the type so the whole well is the
    // control, not just the glyphs. Transparent: the readout IS the
    // affordance, and a wash over the dial would fight the vignette.
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 70, gauge_cy + 16, 140, 56),
        .style = .{ .background = theme.transparent, .radius = 6, .stroke_width = 0 },
        .on_press = .readout_cycle,
        .semantics = .{ .label = "cycle readout: rate, today, trip, eta" },
    }, .{}));
}

const Readout = struct {
    value: []const u8,
    ink: Color,
    caption: []const u8,
    caption_ink: Color,
    semantics: []const u8,
};

fn readout(ui: *Ui, model: *const Model, glance: trayfmt.GlanceState, danger: bool) Readout {
    // While history catch-up is chewing, the numbers aren't truth yet —
    // dim the readout and say "scanning" instead of asserting a
    // confident 0.
    if (model.catchup_active) {
        return .{
            .value = "—",
            .ink = theme.cluster_colors.text_muted,
            .caption = "scanning…",
            .caption_ink = theme.cluster_colors.text_muted,
            .semantics = "readout scanning history",
        };
    }
    switch (model.ux.readout) {
        .rate => {
            const burn_text = if (glance.idle)
                "0"
            else
                fmtTokens(ui, @intFromFloat(@max(glance.burn_tokens_per_min, 0)));
            const eta = etaLine(ui, glance, danger);
            return .{
                .value = burn_text,
                .ink = if (glance.idle) theme.cluster_colors.text_muted else if (danger) theme.red else theme.green,
                .caption = eta.text,
                .caption_ink = eta.ink,
                .semantics = ui.fmt("burn {s} tokens per minute", .{burn_text}),
            };
        },
        .today => return .{
            .value = fmtCost(ui, glance.today_cost_usd),
            .ink = theme.green,
            .caption = ui.fmt("today · {s} tok", .{fmtTokens(ui, glance.today_tokens)}),
            .caption_ink = theme.cluster_colors.text_muted,
            .semantics = ui.fmt("today {s}", .{fmtCost(ui, glance.today_cost_usd)}),
        },
        .trip => {
            const rate = engine.tripCostPerHour(model);
            const caption = if (rate) |per_hour|
                ui.fmt("trip · {s}/hr", .{fmtCost(ui, per_hour)})
            else
                "trip · since launch";
            return .{
                .value = fmtCost(ui, model.trip.cost_usd),
                .ink = theme.trip,
                .caption = caption,
                .caption_ink = theme.trip_dim,
                .semantics = ui.fmt("trip {s}", .{fmtCost(ui, model.trip.cost_usd)}),
            };
        },
        .eta => {
            if (glance.wall_at_ms) |wall| {
                return .{
                    .value = fmtClock(ui, wall, glance.tz_offset_min),
                    .ink = if (danger) theme.red else theme.amber,
                    .caption = "projected wall",
                    .caption_ink = theme.cluster_colors.text_muted,
                    .semantics = "projected limit wall",
                };
            }
            if (glance.next_reset_ms) |reset| {
                if (reset > glance.now_ms) {
                    return .{
                        .value = fmtCountdown(ui, reset - glance.now_ms),
                        .ink = theme.cluster_colors.text,
                        .caption = "to window reset",
                        .caption_ink = theme.cluster_colors.text_muted,
                        .semantics = "time to window reset",
                    };
                }
            }
            return .{
                .value = "—",
                .ink = theme.cluster_colors.text_muted,
                .caption = "no wall in sight",
                .caption_ink = theme.cluster_colors.text_muted,
                .semantics = "no projected wall",
            };
        },
    }
}

/// "Which agent is burning right now", printed on the dial itself. The
/// blended needle cannot answer it — that is the whole reason
/// `AgentBurn` exists — and it is the first thing anyone asks when the
/// needle is high.
fn hotAgentChip(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const hot = model.agent_burn.hottest(model.now_ms) orelse {
        push(ui, nodes, ui.text(.{
            .frame = rect(gauge_cx - 60, gauge_cy + 72, 120, 14),
            .size = .sm,
            .text_alignment = .center,
            .style = .{ .foreground = theme.text_faint },
        }, "fleet idle"));
        return;
    };
    const ink = agentInk(hot.agent);
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 58, gauge_cy + 77, 5, 5),
        .style = .{ .background = ink, .radius = 2.5, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(gauge_cx - 48, gauge_cy + 72, 110, 14),
        .style = .{ .foreground = ink },
    }, &.{
        .{ .text = agentUpper(ui, hot.agent), .weight = .bold, .monospace = true, .scale = 0.8 },
        .{ .text = ui.fmt("  {s}/m", .{fmtTokens(ui, @intFromFloat(@max(hot.tokens_per_min, 0)))}), .monospace = true, .scale = 0.8, .color = .text_muted },
    }));
}

// ------------------------------------------------------- the burn trace

/// Fleet burn at 10-second resolution across the last 20 minutes, at the
/// foot of the gauge panel where a tach's own history belongs.
///
/// Anchored on `now_ms` (see `nowAlignedAccumulator`): the trace this
/// replaced indexed raw ring slots, so after thirty idle minutes it
/// still drew the last burst hard against the right edge while the big
/// number beside it correctly read zero.
fn burnTrace(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    push(ui, nodes, ui.text(.{
        .frame = rect(24, 318, 120, 12),
        .size = .sm,
        .style = .{ .foreground = theme.text_faint },
    }, "BURN · 20 MIN"));
    push(ui, nodes, ui.text(.{
        .frame = rect(166, 318, 110, 12),
        .size = .sm,
        .text_alignment = .end,
        .style = .{ .foreground = theme.text_faint },
    }, ui.fmt("peak {s}/m", .{fmtTokens(ui, @intFromFloat(@max(model.gauge_peak_tpm, 0)))})));

    push(ui, nodes, ui.stack(.{
        .frame = rect(24, 330, 252, 18),
    }, .{
        ui.chart(.{
            .width = 252,
            .height = 18,
            .y_min = 0,
            .stroke_width = 1.5,
            .hover_details = true,
        }, &.{.{
            .kind = .line,
            .values = burnSpark(ui, model),
            .color = .accent,
            .fill = true,
            .label = "burn",
        }}),
    }));
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

fn limitsPanel(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, frame: geometry.RectF) void {
    push(ui, nodes, ui.panel(.{
        .frame = frame,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
        .semantics = .{ .label = "Limit windows" },
    }, .{}));

    // Side by side, not stacked: two independently flowed columns cost
    // the height of the TALLER one instead of the sum, which is what
    // makes room for the fleet display underneath at four windows each.
    const y0 = frame.y + right_pad;
    const claude_end = agentColumn(ui, nodes, model, .claude, model.claude_limits, bars_x, y0);
    const codex_end = agentColumn(ui, nodes, model, .codex, model.codex_limits, col1_x, y0);
    const columns_end = @max(claude_end, codex_end);

    push(ui, nodes, ui.panel(.{
        .frame = rect(col1_x - col_gap / 2, y0 + 2, 1, columns_end - y0 - 4),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(bars_x, columns_end + region_gap / 2, bars_right - bars_x, 1),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    compactOthersRow(ui, nodes, model, columns_end + region_gap);
}

fn agentColumn(
    ui: *Ui,
    nodes: *std.ArrayList(Ui.Node),
    model: *const Model,
    agent: types.Agent,
    limits: ?types.LimitSnapshot,
    x: f32,
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
        else => "OPENCODE",
    };

    var name_spans: [3]canvas.TextSpan = .{
        .{ .text = name, .weight = .bold, .monospace = true },
        .{ .text = "", .color = .text_muted, .monospace = true, .scale = 0.85 },
        .{ .text = "", .color = .warning, .monospace = true, .scale = 0.85 },
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
        .frame = rect(x, y, col_w, 16),
        .semantics = .{ .label = ui.fmt("{s} usage", .{name}) },
    }, &name_spans));

    // Second line of the name block: totals when there is anything to
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
        .frame = rect(x, y + 17, col_w, 13),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, right_text));
    y += name_block_h;

    // Disabled and empty agents get no bars and no limit-data hint —
    // empty tracks under a "0 tok" line would just be lies in green.
    if (!enabled or empty) return y;

    if (limits) |snap| {
        const shown = @min(snap.windows.len, 4);
        for (snap.windows[0..shown]) |window| {
            windowRow(ui, nodes, window, model.now_ms, x, y, stale_min != null);
            y += win_row_h;
        }
    } else {
        // Two short lines instead of one clipped one: the fact, then
        // the remedy.
        push(ui, nodes, ui.text(.{
            .frame = rect(x, y, col_w, 14),
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, "no limit data"));
        push(ui, nodes, ui.text(.{
            .frame = rect(x, y + 15, col_w, 14),
            .wrap = true,
            .size = .sm,
            .style = .{ .foreground = theme.text_faint },
        }, switch (agent) {
            .claude => "enable claude-oauth",
            .codex => "none in rollouts",
            else => "API-equivalent only",
        }));
        y += hint_h;
    }
    return y;
}

/// The aggregate row for every agent beyond the claude/codex limit
/// groups (tt-hr8): opencode plus whatever collectors found usage.
/// One quiet line — the label counts the contributors, the right side
/// sums their API-equivalent value. The MFD's AGENTS page itemizes them
/// live; this row is the all-time total.
fn compactOthersRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, y: f32) void {
    var combined: u64 = 0;
    var combined_cost: f64 = 0;
    var active_count: usize = 0;
    var any_enabled = false;
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        if (!agent.hasLimitsPanel()) {
            if (model.cfg.sources.enabled(agent)) any_enabled = true;
            const totals = model.ledger.forAgent(agent);
            if (totals.events > 0) {
                combined += totals.totalTokens();
                combined_cost += totals.cost_usd;
                active_count += 1;
            }
        }
    }

    var name_spans: [2]canvas.TextSpan = .{
        .{ .text = "OTHERS", .weight = .bold, .monospace = true },
        .{ .text = "", .color = .text_muted, .monospace = true, .scale = 0.85 },
    };
    if (active_count > 1) name_spans[1].text = ui.fmt(" ×{d}", .{active_count});
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_x, y, 120, 16),
        .semantics = .{ .label = "Other agents API-equivalent usage" },
    }, &name_spans));

    const value: []const u8 = if (!any_enabled)
        "disabled"
    else if (active_count == 0)
        "no usage found"
    else
        ui.fmt("{s} · {s}", .{ fmtTokens(ui, combined), fmtCost(ui, combined_cost) });
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_right - 140, y + 1, 140, 14),
        .size = .sm,
        .text_alignment = .end,
        .style_tokens = .{ .foreground = .text_muted },
    }, value));
}

fn windowRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), window: types.LimitWindow, now_ms: i64, x: f32, y: f32, stale: bool) void {
    const label: []const u8 = switch (window.kind) {
        .five_hour => "5h",
        .weekly => "wk",
        .weekly_opus => "opus",
        .weekly_sonnet => "son",
        .monthly => "mo",
    };
    push(ui, nodes, ui.text(.{
        .frame = rect(x, y, 28, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, label));

    const pct = std.math.clamp(window.used_percent, 0, 100);
    // Stale readings render at half strength, no tip glow — the bar is
    // the last known value, not the current one.
    const ink = if (stale) withAlpha(theme.windowZone(pct / 100), 0.45) else theme.windowZone(pct / 100);
    // Row budget inside `col_w` (142): label 0..28, track 30..70,
    // percent 72..96, reset 100..142. The track gave up 8pt so the reset
    // column could have 42 instead of 36 — at 36 a five-glyph countdown
    // ("4h40m", "5d11h") elided to "4h4…", and the percent column ended
    // at exactly the x the reset column started, so a full-width percent
    // printed "41%5d11h" with no space between two unrelated numbers.
    const track_x: f32 = x + 30;
    const track_w: f32 = 40;
    push(ui, nodes, ui.panel(.{
        .frame = rect(track_x, y + 5, track_w, 6),
        .style = .{ .background = theme.track, .radius = 3, .stroke_width = 0 },
    }, .{}));
    if (pct > 0) {
        const fill_w = @max(track_w * @as(f32, @floatCast(pct)) / 100.0, 3);
        push(ui, nodes, ui.panel(.{
            .frame = rect(track_x, y + 5, fill_w, 6),
            .style = .{ .background = ink, .radius = 3, .stroke_width = 0 },
        }, .{}));
        if (!stale) {
            // LED tip glow at the leading edge.
            push(ui, nodes, ui.panel(.{
                .frame = rect(track_x + fill_w - 4, y + 3, 10, 10),
                .style = .{ .background = withAlpha(ink, 0.35), .radius = 5, .stroke_width = 0 },
            }, .{}));
        }
    }

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(x + 72, y, 24, 14),
        .text_alignment = .end,
        .style = .{ .foreground = ink },
    }, &.{.{ .text = ui.fmt("{d}%", .{@as(u64, @intFromFloat(pct))}), .monospace = true, .scale = 0.9 }}));

    if (window.resets_at_ms > now_ms) {
        push(ui, nodes, ui.text(.{
            .frame = rect(x + col_w - 42, y, 42, 14),
            .size = .sm,
            .text_alignment = .end,
            .style_tokens = .{ .foreground = .text_muted },
        }, fmtReset(ui, window.resets_at_ms - now_ms)));
    }
}

// ------------------------------------------------- multi-function display

const mfd_tab_w: f32 = 74;
const mfd_tab_pitch: f32 = 78;
const mfd_tab_h: f32 = 18;
const fleet_row_h: f32 = 22;

/// The MFD's three pages and the tab that selects each.
///
/// `.burn` is the engine's default page and it renders the AGENTS
/// roster, which is not a pun: the roster IS the burn view — it answers
/// "who is burning" where the needle can only answer "how much". The
/// SESSIONS page is the same fleet at a finer grain (one row per live
/// session, so two Claude windows on two projects are two rows), and
/// SCOPE is the machine underneath.
const mfd_tabs = [_]struct { label: []const u8, page: engine.MfdPage }{
    .{ .label = "AGENTS", .page = .burn },
    .{ .label = "SESSIONS", .page = .sessions },
    .{ .label = "SCOPE", .page = .telemetry },
};

fn mfdPage(model: *const Model) engine.MfdPage {
    return switch (model.ux.mfd_page) {
        .sessions => .sessions,
        .telemetry => .telemetry,
        // `.windows` and `.ledger` have no page here — the limits panel
        // above is always visible and the dashboard owns the ledger.
        else => .burn,
    };
}

fn mfdPanel(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, frame: geometry.RectF) void {
    push(ui, nodes, ui.panel(.{
        .frame = frame,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 10 },
        .semantics = .{ .label = "Fleet display" },
    }, .{}));

    const page = mfdPage(model);
    const tabs_y = frame.y + 8;
    for (mfd_tabs, 0..) |tab, i| {
        const x = bars_x + mfd_tab_pitch * @as(f32, @floatFromInt(i));
        const selected = page == tab.page;
        push(ui, nodes, ui.panel(.{
            .frame = rect(x, tabs_y, mfd_tab_w, mfd_tab_h),
            .style = .{
                .background = if (selected) theme.cluster_colors.surface_subtle else theme.transparent,
                .radius = 3,
                .stroke_width = 0,
            },
            .on_press = .{ .mfd_page = tab.page },
            .semantics = .{ .label = ui.fmt("show {s}", .{tab.label}) },
        }, .{}));
        push(ui, nodes, ui.paragraph(.{
            .frame = rect(x, tabs_y + 3, mfd_tab_w, 14),
            .text_alignment = .center,
            .style = .{ .foreground = if (selected) theme.cluster_colors.text else theme.cluster_colors.text_muted },
        }, &.{.{ .text = tab.label, .weight = .bold, .monospace = true, .scale = 0.76 }}));
        if (selected) {
            push(ui, nodes, ui.panel(.{
                .frame = rect(x + 10, tabs_y + mfd_tab_h, mfd_tab_w - 20, 2),
                .style = .{ .background = theme.green, .radius = 1, .stroke_width = 0 },
            }, .{}));
        }
    }

    switch (page) {
        .telemetry => scopePage(ui, nodes, model, frame),
        .sessions => sessionsPage(ui, nodes, model, frame),
        else => agentsPage(ui, nodes, model, frame),
    }
}

/// How many fleet rows fit under the tabs and the detail line. Derived,
/// never assumed: the MFD's height is whatever the limits region left,
/// so the page shows as many rows as it honestly has room for — four
/// limit windows on both agents costs two rows here and nothing else.
fn fleetRowCapacity(frame: geometry.RectF) usize {
    const top = frame.y + 48;
    const space = frame.y + frame.height - 8 - top;
    if (space < fleet_row_h) return 0;
    return @intFromFloat(@floor(space / fleet_row_h));
}

/// One rendered fleet row, agent-grained or session-grained.
const FleetRow = struct {
    name: []const u8,
    ink: Color,
    activity: sessions.Activity,
    /// Limit-weighted tokens/min right now.
    burn: f64,
    /// Oldest-first burn samples for the row sparkline.
    spark: []const f32,
    /// Small qualifier printed after the name (session count, turns).
    qualifier: []const u8,
    /// The full line the row reveals when selected.
    detail: []const u8,
    /// Global key for the activity pip, so `animations` can pulse it.
    pip_key: u64,
};

fn agentsPage(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, frame: geometry.RectF) void {
    const now = model.now_ms;
    const by_agent = model.roster.byAgent(now);
    const agent_count = @typeInfo(types.Agent).@"enum".fields.len;

    var rows: [agent_count]FleetRow = undefined;
    var n: usize = 0;
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        const view = by_agent.get(agent);
        const burn = model.agent_burn.tokensPerMin(agent, now);
        // A row earns its place by being alive or hot; an agent that has
        // not run since the machine booted belongs in the ledger, not on
        // an instrument that answers "right now".
        if (burn > 0 or view.activity != .done) {
            rows[n] = .{
                .name = agentUpper(ui, agent),
                .ink = agentInk(agent),
                .activity = view.activity,
                .burn = burn,
                .spark = agentSpark(ui, model, agent),
                .qualifier = if (view.sessions > 1) ui.fmt("×{d}", .{view.sessions}) else "",
                .detail = ui.fmt("{s} · {d} session{s} · {s} · {s}", .{
                    agentUpper(ui, agent),
                    view.sessions,
                    if (view.sessions == 1) "" else "s",
                    fmtTokens(ui, view.totals.totalTokens()),
                    fmtCost(ui, view.totals.cost_usd),
                }),
                .pip_key = agentPipKey(agent),
            };
            n += 1;
        }
    }
    sortByBurn(rows[0..n]);
    fleetRows(ui, nodes, model, frame, rows[0..n], "no agent has run yet");
}

fn sessionsPage(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, frame: geometry.RectF) void {
    var slots: [sessions.max_sessions]*const sessions.Session = undefined;
    // `live` already orders running-first, then hottest — the roster's
    // own display contract, which is exactly what this page wants.
    const live = model.roster.live(&slots, model.now_ms);

    var rows: [sessions.max_sessions]FleetRow = undefined;
    for (live, 0..) |session, i| {
        const project = session.project();
        rows[i] = .{
            .name = if (project.len > 0) project else agentUpper(ui, session.agent),
            .ink = agentInk(session.agent),
            .activity = session.activityAt(model.now_ms),
            .burn = session.tokensPerMin(),
            .spark = sessionSpark(ui, session),
            // Mid-turn is the flagship signal: transcript bytes with no
            // completed turn behind them means this agent is thinking at
            // this instant, which no token count can tell you.
            .qualifier = if (session.mid_turn) "···" else ui.fmt("{d}t", .{session.turns()}),
            .detail = ui.fmt("{s} · {s} · {d} turns · {s}", .{
                agentUpper(ui, session.agent),
                if (session.modelName().len > 0) session.modelName() else "model unknown",
                session.turns(),
                fmtCost(ui, session.totals.cost_usd),
            }),
            .pip_key = sessionPipKey(i),
        };
    }
    fleetRows(ui, nodes, model, frame, rows[0..live.len], "no live sessions");
}

/// Burn-descending, liveliness breaking ties.
///
/// Deliberately NOT the roster's running-first order: this page answers
/// "who is burning right now", and an agent sitting at a prompt with a
/// live process outranking one that is actually consuming tokens would
/// answer a different question. The SESSIONS page keeps the roster's own
/// running-first contract, where "is it alive" is the point.
///
/// Insertion sort: stable, so equal rows keep enum order and a redraw
/// never shuffles them.
fn sortByBurn(rows: []FleetRow) void {
    var i: usize = 1;
    while (i < rows.len) : (i += 1) {
        const item = rows[i];
        var j = i;
        while (j > 0 and burnLess(item, rows[j - 1])) : (j -= 1) {
            rows[j] = rows[j - 1];
        }
        rows[j] = item;
    }
}

fn burnLess(a: FleetRow, b: FleetRow) bool {
    if (a.burn != b.burn) return a.burn > b.burn;
    return a.activity.rank() < b.activity.rank();
}

fn fleetRows(
    ui: *Ui,
    nodes: *std.ArrayList(Ui.Node),
    model: *const Model,
    frame: geometry.RectF,
    rows: []const FleetRow,
    empty_text: []const u8,
) void {
    const capacity = fleetRowCapacity(frame);
    var shown = @min(rows.len, capacity);
    // The overflow line needs a line's worth of room of its own, or it
    // prints over the panel edge on the one frame that needs it most.
    if (rows.len > shown and shown > 0) {
        const used = frame.y + 48 + fleet_row_h * @as(f32, @floatFromInt(shown));
        if (used + 14 > frame.y + frame.height - 4) shown -= 1;
    }

    if (shown == 0) {
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_x, frame.y + 40, bars_right - bars_x, 16),
            .style_tokens = .{ .foreground = .text_muted },
        }, empty_text));
        return;
    }

    // One row is always the selected one — row 0, the hottest, until the
    // pointer says otherwise — and its full line lives where a column
    // header would. A static "AGENT / TOK/MIN" header would spend the
    // same pixels restating what the columns already look like, and the
    // obvious alternative home for row detail (the footer) is already
    // spoken for by the telemetry hover.
    const selected: usize = @min(model.ux.selected_row, shown - 1);
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_x, frame.y + 32, bars_right - bars_x, 13),
        .size = .sm,
        .style = .{ .foreground = rows[selected].ink },
    }, rows[selected].detail));

    var y = frame.y + 48;
    for (rows[0..shown], 0..) |row, i| {
        fleetRow(ui, nodes, row, i, i == selected, y);
        y += fleet_row_h;
    }
    if (rows.len > shown) {
        push(ui, nodes, ui.text(.{
            .frame = rect(bars_x, y + 1, bars_right - bars_x, 13),
            .size = .sm,
            .text_alignment = .end,
            .style = .{ .foreground = theme.text_faint },
        }, ui.fmt("+{d} more", .{rows.len - shown})));
    }
}

fn fleetRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), row: FleetRow, index: usize, selected: bool, y: f32) void {
    if (selected) {
        push(ui, nodes, ui.panel(.{
            .frame = rect(bars_x - 6, y - 1, bars_right - bars_x + 12, fleet_row_h - 2),
            .style = .{ .background = withAlpha(row.ink, 0.10), .radius = 3, .stroke_width = 0 },
        }, .{}));
    }

    // The activity pip: lit and pulsing while running, a dim disc when
    // idle. Keyed so `animations` can find it.
    const running = row.activity == .running;
    push(ui, nodes, ui.panel(.{
        .global_key = canvas.uiKey(row.pip_key),
        .frame = rect(bars_x, y + 7, 6, 6),
        .style = .{
            .background = if (running) theme.activity_dot else theme.idle_dot,
            .radius = 3,
            .stroke_width = 0,
        },
    }, .{}));

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_x + 12, y + 2, 118, 14),
        .style = .{ .foreground = row.ink },
    }, &.{
        .{ .text = row.name, .weight = .bold, .monospace = true, .scale = 0.85 },
        .{ .text = if (row.qualifier.len > 0) ui.fmt("  {s}", .{row.qualifier}) else "", .monospace = true, .scale = 0.75, .color = .text_muted },
    }));

    push(ui, nodes, ui.stack(.{
        .frame = rect(bars_x + 136, y + 4, 84, 14),
    }, .{
        ui.chart(.{
            .width = 84,
            .height = 14,
            .y_min = 0,
            .stroke_width = 1,
            .semantics = .{ .label = ui.fmt("{s} burn trace", .{row.name}) },
        }, &.{.{ .kind = .line, .values = row.spark, .color = .accent, .fill = true }}),
    }));

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_right - 76, y + 2, 76, 14),
        .text_alignment = .end,
        .style = .{ .foreground = if (running) theme.cluster_colors.text else theme.cluster_colors.text_muted },
    }, &.{.{
        .text = if (row.burn >= 1) fmtTokens(ui, @intFromFloat(row.burn)) else "—",
        .weight = .bold,
        .monospace = true,
        .scale = 0.9,
    }}));

    push(ui, nodes, ui.panel(.{
        .frame = rect(bars_x - 6, y - 1, bars_right - bars_x + 12, fleet_row_h - 2),
        .style = .{ .background = theme.transparent, .radius = 3, .stroke_width = 0 },
        .on_press = .{ .row_press = @intCast(index) },
        .semantics = .{ .label = row.detail },
    }, .{}));
}

// ------------------------------------------------------------ scope page

/// Samples on the scope page's shared x axis: 10 s apart, 20 minutes
/// wide — the span the fleet burn trace covers, so both lanes are the
/// same window and one pointer position means one moment.
const scope_points: usize = 120;

/// The machine and the needle on ONE time axis.
///
/// Every system meter on this panel is otherwise a bar of NOW: nothing
/// answers "was it like this a minute ago", which is the question that
/// makes a system monitor a monitor. CPU renders as a min/max BAND (each
/// 10 s cell holds two 5 s samples, and averaging them would hide
/// exactly the spikes someone opens a scope to find) and the needle as
/// its own percentage of full scale, so both lanes share one honest
/// 0-100 domain.
fn scopePage(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, frame: geometry.RectF) void {
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_x, frame.y + 32, 160, 13),
        .size = .sm,
        .style = .{ .foreground = theme.text_faint },
    }, "MACHINE · 20 MIN"));
    // A CPU lane with no samples behind it would draw a confident flat
    // line along zero, which is a claim about the machine and not the
    // truth ("nothing recorded yet"). No samples, no lane.
    const has_cpu = !model.system_history.cpu.isEmpty();
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(bars_right - 150, frame.y + 32, 150, 13),
        .text_alignment = .end,
    }, &.{
        .{ .text = if (has_cpu) "cpu" else "", .monospace = true, .scale = 0.78, .color = .info },
        .{ .text = "  needle", .monospace = true, .scale = 0.78, .color = .accent },
    }));

    const plot_y = frame.y + 50;
    const plot_h = @max(frame.y + frame.height - 20 - plot_y, 24);
    const scale = engine.gaugeScaleTpm(model.gauge_peak_tpm);

    var series: [2]canvas.ChartSeries = undefined;
    var count: usize = 0;
    if (has_cpu) {
        const cpu = cpuBand(ui, model);
        series[count] = .{ .kind = .band, .values = cpu.high, .low = cpu.low, .color = .info, .label = "cpu %" };
        count += 1;
    }
    series[count] = .{ .kind = .line, .values = needleTrace(ui, model, scale), .color = .accent, .label = "needle %" };
    count += 1;

    push(ui, nodes, ui.stack(.{
        .frame = rect(bars_x, plot_y, bars_right - bars_x, plot_h),
    }, .{
        ui.chart(.{
            .width = bars_right - bars_x,
            .height = plot_h,
            .y_min = 0,
            .y_max = 100,
            .grid_lines = 2,
            .y_labels = true,
            .hover_details = true,
            .stroke_width = 1.2,
        }, series[0..count]),
    }));

    push(ui, nodes, ui.text(.{
        .frame = rect(bars_x, frame.y + frame.height - 17, 80, 12),
        .size = .sm,
        .style = .{ .foreground = theme.text_faint },
    }, "20 min ago"));
    push(ui, nodes, ui.text(.{
        .frame = rect(bars_right - 60, frame.y + frame.height - 17, 60, 12),
        .size = .sm,
        .text_alignment = .end,
        .style = .{ .foreground = theme.text_faint },
    }, "now"));
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
        .frame = rect(32, strip_y + 14, 52, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "TODAY"));

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(86, strip_y + 8, 140, 26),
        .style = .{ .foreground = theme.green },
    }, &.{.{ .text = fmtCost(ui, glance.today_cost_usd), .weight = .bold, .monospace = true, .scale = 1.5 }}));

    push(ui, nodes, ui.panel(.{
        .frame = rect(238, strip_y + 8, 1, 26),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));

    // The token odometer: fixed digit cells with a machined inset (top
    // shadow line, bottom glint line), leading zeros dimmed.
    const digits = ui.fmt("{d:0>9}", .{glance.today_tokens});
    const cell_w: f32 = 18;
    const cell_h: f32 = 26;
    const cell_gap: f32 = 2;
    var x: f32 = 262;
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
        .frame = rect(x + 4, strip_y + 14, 34, 14),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "tok"));

    tripMeter(ui, nodes, model);
}

/// The trip meter: what THIS launch has burned, in the trip ink so it
/// never reads as part of the permanent odometer beside it. Held (not
/// clicked) to zero — a stalk you can brush past is a stalk that loses
/// your session total.
fn tripMeter(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const x: f32 = 500;
    push(ui, nodes, ui.panel(.{
        .frame = rect(x - 14, strip_y + 8, 1, 26),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.text(.{
        .frame = rect(x, strip_y + 7, 50, 13),
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, "TRIP"));
    const rate_text = if (engine.tripCostPerHour(model)) |per_hour|
        ui.fmt("{s}/hr", .{fmtCost(ui, per_hour)})
    else
        // "hold to zero" needed ~70pt at `sm` and had exactly 70, so it
        // printed "hold to ze…" — an affordance hint that elides the
        // verb it exists to teach is worse than no hint. Terser string,
        // wider frame, and the frame no longer starts inside the "TRIP"
        // label's box at x+40.
        "hold to 0";
    push(ui, nodes, ui.text(.{
        .frame = rect(x + 34, strip_y + 7, 76, 13),
        .size = .sm,
        .text_alignment = .end,
        .style = .{ .foreground = theme.text_faint },
    }, rate_text));
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(x, strip_y + 20, 110, 18),
        .style = .{ .foreground = theme.trip },
    }, &.{.{ .text = fmtCost(ui, model.trip.cost_usd), .weight = .bold, .monospace = true, .scale = 1.15 }}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(x - 6, strip_y + 5, 122, 32),
        .style = .{ .background = theme.transparent, .radius = 4, .stroke_width = 0 },
        .on_hold = .trip_reset,
        .semantics = .{ .label = ui.fmt("trip {s} since launch, hold to reset", .{fmtCost(ui, model.trip.cost_usd)}) },
    }, .{}));
}

// -------------------------------------------------------- system strip

/// One cell of the system telemetry strip: a label, a monospace reading,
/// a windowRow-grammar meter, and five minutes of history under it.
const SysCell = struct {
    label: []const u8,
    value: []const u8,
    meter_frac: f64,
    ink: Color,
    /// The hover target this cell reports (drives the footer reveal).
    target: engine.HoverTarget,
    /// Oldest-first history samples, already scaled to 0..100.
    spark: []const f32,
    /// Meter ink when it differs from the value ink (the DISK cell inks
    /// its value by capacity but its meter by live I/O activity).
    meter_ink: ?Color = null,
    /// Width weight: NET carries a two-direction reading and gets a
    /// wider cell so the value never wraps.
    weight: f32 = 1,
};

/// The system telemetry strip: CPU / GPU / MEM / DISK / NET / BAT as
/// quiet micro-meters in the limits-bar grammar, each over its own
/// five-minute trace. Cells exist only for modules that are enabled AND
/// produced a reading — no zeros, no dashes; on a desktop the battery
/// cell simply is not there.
fn systemStrip(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    if (!model.cfg.system_stats.any()) return;
    const snap = model.system_snap;
    const hist = &model.system_history;
    const now = model.now_ms;

    var cells: [6]SysCell = undefined;
    var count: usize = 0;
    if (snap.cpu) |s| {
        cells[count] = .{
            .label = "CPU",
            .target = .cpu,
            .value = ui.fmt("{d}%", .{pctInt(s.total_frac)}),
            .meter_frac = s.total_frac,
            .ink = theme.loadZone(s.total_frac),
            .spark = seriesSpark(ui, &hist.cpu, now, .fraction),
        };
        count += 1;
    }
    if (snap.gpu) |s| {
        cells[count] = .{
            .label = "GPU",
            .target = .gpu,
            .value = ui.fmt("{d}%", .{pctInt(s.device_utilization)}),
            .meter_frac = s.device_utilization,
            .ink = theme.loadZone(s.device_utilization),
            .spark = seriesSpark(ui, &hist.gpu, now, .fraction),
        };
        count += 1;
    }
    if (snap.mem) |s| {
        // Memory pressure outranks the raw fraction: the kernel saying
        // "warn" is truer than any percentage cutoff.
        const ink = switch (s.pressure) {
            .critical => theme.red,
            .warn => theme.amber,
            .normal, .unknown => theme.loadZone(s.used_frac),
        };
        cells[count] = .{
            .label = "MEM",
            .target = .mem,
            .value = ui.fmt("{d}%", .{pctInt(s.used_frac)}),
            .meter_frac = s.used_frac,
            .ink = ink,
            .spark = seriesSpark(ui, &hist.mem, now, .fraction),
        };
        count += 1;
    }
    if (snap.disk) |s| {
        // Value: free space, inked by how full the volume is. Meter:
        // live read+write activity against the ratcheted peak — the
        // capacity fraction barely moves for months, but I/O makes this
        // a real instrument (tt-t7u). The trace is capacity, which is
        // the one of the two that HAS a history.
        cells[count] = .{
            .label = "DISK",
            .target = .disk,
            .value = fmtBytes(ui, s.free_bytes),
            .meter_frac = snap.disk_io_meter_frac orelse 0,
            .ink = theme.diskZone(s.used_fraction),
            .meter_ink = theme.green,
            .spark = seriesSpark(ui, &hist.disk, now, .fraction),
        };
        count += 1;
    }
    if (snap.net) |s| {
        // Throughput has no natural 100%; the meter runs against the
        // aggregator's ratcheted peak, and activity is never a warning.
        cells[count] = .{
            .label = "NET",
            .target = .net,
            .value = ui.fmt("↓{s} ↑{s}", .{
                fmtBytes(ui, @intFromFloat(@max(s.in_bytes_per_sec orelse 0, 0))),
                fmtBytes(ui, @intFromFloat(@max(s.out_bytes_per_sec orelse 0, 0))),
            }),
            .meter_frac = snap.net_meter_frac orelse 0,
            .ink = theme.green,
            .spark = netSpark(ui, hist, now),
            .weight = 1.7,
        };
        count += 1;
    }
    if (snap.battery) |s| {
        cells[count] = .{
            .label = if (s.charging) "BAT+" else "BAT",
            .target = .battery,
            .value = ui.fmt("{d}%", .{pctInt(s.charge)}),
            .meter_frac = s.charge,
            .ink = theme.chargeZone(s.charge),
            .spark = seriesSpark(ui, &hist.battery, now, .fraction),
        };
        count += 1;
    }
    if (count == 0) return;

    push(ui, nodes, ui.panel(.{
        .frame = system_rect,
        .style = .{ .background = theme.transparent, .border = theme.bezel_edge, .stroke_width = 1, .radius = 7 },
        .semantics = .{ .label = "System telemetry" },
    }, .{}));

    const inner_x: f32 = system_rect.x + 14;
    const inner_w: f32 = system_rect.width - 28;
    var total_weight: f32 = 0;
    for (cells[0..count]) |cell| total_weight += cell.weight;
    const unit_w = inner_w / total_weight;
    var x = inner_x;
    for (cells[0..count], 0..) |cell, i| {
        const cell_w = unit_w * cell.weight;
        defer x += cell_w;
        if (i > 0) {
            push(ui, nodes, ui.panel(.{
                .frame = rect(x - 8, system_y + 8, 1, system_h - 16),
                .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
            }, .{}));
        }
        push(ui, nodes, ui.text(.{
            .frame = rect(x, system_y + 7, 34, 13),
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, cell.label));
        push(ui, nodes, ui.paragraph(.{
            .frame = rect(x + 22, system_y + 6, cell_w - 38, 14),
            .text_alignment = .end,
            .style = .{ .foreground = cell.ink },
        }, &.{.{ .text = cell.value, .monospace = true, .scale = 0.9 }}));

        // The meter, in the windowRow grammar: track, fill, LED tip glow.
        const track_w = cell_w - 16;
        push(ui, nodes, ui.panel(.{
            .frame = rect(x, system_y + 24, track_w, 5),
            .style = .{ .background = theme.track, .radius = 2, .stroke_width = 0 },
        }, .{}));
        const frac: f32 = @floatCast(std.math.clamp(cell.meter_frac, 0, 1));
        if (frac > 0) {
            const meter_ink = cell.meter_ink orelse cell.ink;
            const fill_w = @max(track_w * frac, 2);
            push(ui, nodes, ui.panel(.{
                .frame = rect(x, system_y + 24, fill_w, 5),
                .style = .{ .background = meter_ink, .radius = 2, .stroke_width = 0 },
            }, .{}));
            push(ui, nodes, ui.panel(.{
                .frame = rect(x + fill_w - 3, system_y + 22, 8, 8),
                .style = .{ .background = withAlpha(meter_ink, 0.35), .radius = 4, .stroke_width = 0 },
            }, .{}));
        }

        // Five minutes of it. A meter says where the machine is; the
        // trace says where it is going, and the two together are what
        // separates an instrument from a status line.
        push(ui, nodes, ui.stack(.{
            .frame = rect(x, system_y + 34, track_w, 20),
        }, .{
            // No explicit semantics label: the generated series summary
            // ("chart: CPU 60 pts last 43.00") is both the a11y payload
            // and the seam a test asserts the DATA through — an empty
            // history reads "CPU empty" instead of a confident flat zero.
            ui.chart(.{
                .width = track_w,
                .height = 20,
                .y_min = 0,
                .y_max = 100,
                .stroke_width = 1,
            }, &.{.{ .kind = .line, .values = cell.spark, .color = .text_muted, .fill = true, .label = cell.label }}),
        }));

        // A transparent hover-hit region over the whole cell, pushed
        // last so it sits atop the readouts. Binding hover makes it
        // hover-hittable without painting a wash (SDK on_hover_*); the
        // enter/leave pair drives the footer reveal. When this cell is
        // the hovered one, a faint underline confirms the target.
        const hovered = model.hovered_system == cell.target;
        push(ui, nodes, ui.panel(.{
            .frame = rect(x - 8, system_y, cell_w + 8, system_h),
            .style = .{ .background = theme.transparent, .radius = 0, .stroke_width = 0 },
            .on_hover_enter = .{ .hover_system = cell.target },
            .on_hover_leave = .hover_clear,
            .semantics = .{ .label = ui.fmt("{s} telemetry", .{cell.label}) },
        }, .{}));
        if (hovered) {
            push(ui, nodes, ui.panel(.{
                .frame = rect(x, system_y + 56, track_w, 2),
                .style = .{ .background = withAlpha(cell.ink, 0.7), .radius = 1, .stroke_width = 0 },
            }, .{}));
        }
    }
}

/// The footer reading for a hovered system cell — the full precision the
/// compact strip cannot show at a glance. Null when the reading vanished
/// between hover and rebuild (the paired leave is still coming).
fn systemHoverDetail(ui: *Ui, model: *const Model, target: engine.HoverTarget) ?[]const u8 {
    const snap = model.system_snap;
    return switch (target) {
        .cpu => if (snap.cpu) |s| blk: {
            if (s.p_cluster_frac != null and s.e_cluster_frac != null) {
                break :blk ui.fmt("CPU {d}% · {d} cores · load {d:.2} · P {d}% E {d}%", .{
                    pctInt(s.total_frac),       s.core_count,               s.load_avg_1m,
                    pctInt(s.p_cluster_frac.?), pctInt(s.e_cluster_frac.?),
                });
            }
            break :blk ui.fmt("CPU {d}% · {d} cores · load {d:.2}", .{ pctInt(s.total_frac), s.core_count, s.load_avg_1m });
        } else null,
        .gpu => if (snap.gpu) |s| blk: {
            if (s.in_use_memory_bytes) |mem| {
                break :blk ui.fmt("GPU {d}% · {s} in use", .{ pctInt(s.device_utilization), fmtBytes(ui, mem) });
            }
            break :blk ui.fmt("GPU {d}% utilization", .{pctInt(s.device_utilization)});
        } else null,
        .mem => if (snap.mem) |s| ui.fmt("MEM {s} / {s} used ({d}%) · pressure {s}", .{
            fmtBytes(ui, s.used_bytes), fmtBytes(ui, s.total_bytes), pctInt(s.used_frac), @tagName(s.pressure),
        }) else null,
        .disk => if (snap.disk) |s| ui.fmt("DISK {s} free of {s} ({d}% used) · ↓{s}/s ↑{s}/s", .{
            fmtBytes(ui, s.free_bytes),                                          fmtBytes(ui, s.total_bytes),                                          pctInt(s.used_fraction),
            fmtBytes(ui, @intFromFloat(@max(s.read_bytes_per_sec orelse 0, 0))), fmtBytes(ui, @intFromFloat(@max(s.write_bytes_per_sec orelse 0, 0))),
        }) else null,
        .net => if (snap.net) |s| ui.fmt("NET ↓{s}/s ↑{s}/s", .{
            fmtBytes(ui, @intFromFloat(@max(s.in_bytes_per_sec orelse 0, 0))),
            fmtBytes(ui, @intFromFloat(@max(s.out_bytes_per_sec orelse 0, 0))),
        }) else null,
        .battery => if (snap.battery) |s| blk: {
            const state: []const u8 = if (s.charging) "charging" else if (s.on_ac) "on AC" else "on battery";
            if (s.minutes_to_empty) |m| break :blk ui.fmt("BATTERY {d}% · {s} · ~{d}h{d:0>2}m left", .{ pctInt(s.charge), state, m / 60, m % 60 });
            if (s.minutes_to_full) |m| break :blk ui.fmt("BATTERY {d}% · {s} · ~{d}h{d:0>2}m to full", .{ pctInt(s.charge), state, m / 60, m % 60 });
            break :blk ui.fmt("BATTERY {d}% · {s}", .{ pctInt(s.charge), state });
        } else null,
    };
}

fn pctInt(frac: f64) u64 {
    return @intFromFloat(std.math.clamp(frac, 0, 1) * 100 + 0.5);
}

fn fmtBytes(ui: *Ui, bytes: u64) []const u8 {
    const buf = ui.arena.alloc(u8, 16) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeHumanBytes(&w, bytes) catch {};
    return w.buffered();
}

// ----------------------------------------------------- render animation

/// The three chrome commands that ARE the needle (blade fill, blade
/// edge, tip glow) — every sweep rotates all three about the pivot.
pub const needle_command_ids = [_]canvas.ObjectId{ needle_blade_id, needle_edge_id, needle_glow_id };

/// Render animations: the ignition sweep (boot / popover open), the
/// steady needle sweep between poses, the redline pulse, and the live
/// pips.
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

    // Live pips: the header lamp and every running row's dot breathe
    // while work is in flight. Slower than the redline pulse on purpose
    // — a heartbeat, not an alarm. The keys must agree with the page the
    // view is drawing, so this asks the same `mfdPage` the tree did; a
    // key with no widget this frame simply matches no command, the same
    // harmless miss `ledFade` relies on.
    if (!engine.glanceState(model).idle and count < out.len) {
        out[count] = livePulse(partCommandId(live_lamp_key, 2), start_ns);
        count += 1;
        if (mfdPage(model) == .sessions) {
            var slots: [sessions.max_sessions]*const sessions.Session = undefined;
            for (model.roster.live(&slots, model.now_ms), 0..) |session, i| {
                if (count >= out.len) break;
                if (session.activityAt(model.now_ms) != .running) continue;
                out[count] = livePulse(partCommandId(sessionPipKey(i), 2), start_ns);
                count += 1;
            }
        } else {
            const by_agent = model.roster.byAgent(model.now_ms);
            inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
                const agent: types.Agent = @enumFromInt(field.value);
                if (by_agent.get(agent).activity == .running and count < out.len) {
                    out[count] = livePulse(partCommandId(agentPipKey(agent), 2), start_ns);
                    count += 1;
                }
            }
        }
    }
    return count;
}

/// Pip keys. Agents key by enum ordinal so a row keeps its identity as
/// the sort moves it; sessions key by display position, offset clear of
/// the agent block so the two pages can never collide.
fn agentPipKey(agent: types.Agent) u64 {
    return activity_key_base + @as(u64, @intCast(@intFromEnum(agent)));
}

fn sessionPipKey(index: usize) u64 {
    return activity_key_base + 64 + @as(u64, @intCast(index));
}

fn livePulse(id: canvas.ObjectId, start_ns: u64) canvas.CanvasRenderAnimation {
    return .{
        .id = id,
        .start_ns = start_ns,
        .duration_ms = 1_400,
        .easing = .standard,
        .from_opacity = 0.45,
        .to_opacity = 1,
        .loop = .ping_pong,
    };
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

// ---------------------------------------------------------- trace data
// Every ring in the model is HEAD-anchored: its newest bucket is
// wherever the last write left it. A renderer that maps slot to x
// therefore draws a burst that ended half an hour ago hard against the
// right edge, under a caption that says "now". These helpers re-anchor
// each read on `now_ms`, so a ring nobody advanced renders as the
// silence it represents.

/// Index of the source sample that belongs at output position 0, for a
/// head-anchored snapshot of `raw_len` buckets re-read as `span_len`
/// consecutive buckets ENDING at `end_bucket`.
///
/// `raw[j]` holds bucket `head - (raw_len-1) + j`; output `i` wants
/// bucket `end - (span_len-1) + i`; equate and the offset falls out. It
/// is deliberately signed: an offset below zero means the caller asked
/// for buckets older than the ring holds, and the per-index bounds check
/// renders those as the absence they are rather than wrapping into
/// somebody else's data.
fn ringOffset(window_start_ms: i64, period_ms: i64, raw_len: usize, span_len: usize, end_bucket: i64) i64 {
    const head_bucket = @divFloor(window_start_ms, period_ms) + @as(i64, @intCast(raw_len - 1));
    return end_bucket - head_bucket + @as(i64, @intCast(raw_len)) - @as(i64, @intCast(span_len));
}

/// `raw[offset + i]`, or null when that index falls outside the ring —
/// too old to still be held, or newer than anything recorded.
fn ringAt(comptime T: type, raw: []const T, offset: i64, i: usize) ?T {
    const src = offset + @as(i64, @intCast(i));
    if (src < 0 or src >= @as(i64, @intCast(raw.len))) return null;
    return raw[@intCast(src)];
}

/// The fleet burn trace: 10-second buckets over 20 minutes on a
/// square-root scale (0 stays 0, ordering preserved, spikes tamed so one
/// burst does not flatten the other nineteen minutes).
fn burnSpark(ui: *Ui, model: *const Model) []const f32 {
    const scope = &model.agent_burn.scope;
    var raw: [predict.ScopeTrace.bucket_count]u64 = undefined;
    _ = scope.snapshot(&raw);
    // Drop the in-progress bucket: a partial 10 seconds always sits
    // below trend, which used to make the trace dip at the right edge on
    // every frame mid-burn.
    const end_bucket = @divFloor(model.now_ms, predict.ScopeTrace.period_ms) - 1;
    const out = ui.arena.alloc(f32, raw.len - 1) catch {
        ui.failed = true;
        return &.{};
    };
    const offset = ringOffset(scope.windowStartMs(), predict.ScopeTrace.period_ms, raw.len, out.len, end_bucket);
    for (out, 0..) |*value, i| {
        const tokens = ringAt(u64, &raw, offset, i) orelse 0;
        value.* = @sqrt(@as(f32, @floatFromInt(tokens)));
    }
    return out;
}

/// One agent's minute buckets for a roster sparkline. `snapshotComplete`
/// is now-anchored by construction and drops the partial minute.
fn agentSpark(ui: *Ui, model: *const Model, agent: types.Agent) []const f32 {
    var raw: [predict.BurnRate.window_minutes]u64 = undefined;
    const window = model.agent_burn.burnFor(agent).snapshotComplete(model.now_ms, &raw);
    return sqrtScaled(ui, window);
}

fn sessionSpark(ui: *Ui, session: *const sessions.Session) []const f32 {
    var raw: [sessions.burn_buckets]u64 = undefined;
    return sqrtScaled(ui, session.sparkline(&raw));
}

fn sqrtScaled(ui: *Ui, values: []const u64) []const f32 {
    const out = ui.arena.alloc(f32, values.len) catch {
        ui.failed = true;
        return &.{};
    };
    for (out, values) |*slot, value| slot.* = @sqrt(@as(f32, @floatFromInt(value)));
    return out;
}

/// The needle's own history: fleet burn as a percentage of the dial's
/// full scale, so the scope page's two lanes share one 0-100 domain
/// instead of pretending tokens and percent are the same unit.
fn needleTrace(ui: *Ui, model: *const Model, scale_tpm: f64) []const f32 {
    const scope = &model.agent_burn.scope;
    var raw: [predict.ScopeTrace.bucket_count]u64 = undefined;
    _ = scope.snapshot(&raw);
    const end_bucket = @divFloor(model.now_ms, predict.ScopeTrace.period_ms) - 1;
    const out = ui.arena.alloc(f32, scope_points) catch {
        ui.failed = true;
        return &.{};
    };
    const offset = ringOffset(scope.windowStartMs(), predict.ScopeTrace.period_ms, raw.len, out.len, end_bucket);
    const per_min_factor: f64 = 60_000.0 / @as(f64, @floatFromInt(predict.ScopeTrace.period_ms));
    for (out, 0..) |*value, i| {
        const tokens: f64 = @floatFromInt(ringAt(u64, &raw, offset, i) orelse 0);
        const tpm = tokens * per_min_factor;
        value.* = @floatCast(std.math.clamp(tpm / @max(scale_tpm, 1) * 100, 0, 100));
    }
    return out;
}

const CpuBand = struct { low: []const f32, high: []const f32 };

/// CPU as a min/max envelope: each 10-second cell of the scope's axis
/// covers two 5-second samples, and averaging them would erase exactly
/// the spikes a scope exists to show. Gaps hold the last known level —
/// a stalled sampler is not the machine going to 0%.
fn cpuBand(ui: *Ui, model: *const Model) CpuBand {
    const series = &model.system_history.cpu;
    const low = ui.arena.alloc(f32, scope_points) catch {
        ui.failed = true;
        return .{ .low = &.{}, .high = &.{} };
    };
    const high = ui.arena.alloc(f32, scope_points) catch {
        ui.failed = true;
        return .{ .low = &.{}, .high = &.{} };
    };
    var raw: [engine.SystemHistory.buckets]?f32 = undefined;
    _ = series.snapshot(&raw);
    const period = engine.SystemHistory.period_ms;
    // Two 5 s source samples per 10 s output cell: the span consumed is
    // twice the plotted width.
    const offset = ringOffset(series.windowStartMs(), period, raw.len, scope_points * 2, @divFloor(model.now_ms, period));

    var held: f32 = 0;
    for (0..scope_points) |i| {
        var lo: f32 = 1e9;
        var hi: f32 = -1e9;
        for (0..2) |k| {
            if (ringAt(?f32, &raw, offset, i * 2 + k) orelse null) |value| {
                const pct = std.math.clamp(value, 0, 1) * 100;
                lo = @min(lo, pct);
                hi = @max(hi, pct);
                held = pct;
            }
        }
        if (hi < lo) {
            lo = held;
            hi = held;
        }
        low[i] = lo;
        high[i] = hi;
    }
    return .{ .low = low, .high = high };
}

/// Five minutes of one telemetry series, now-anchored, with gaps held at
/// the last known level — a stalled sampler is not the machine dropping
/// to zero, and a chart that says it is would be the worst kind of lie
/// on a panel like this.
const strip_spark_points: usize = 60;

/// What the stored samples MEAN, which decides how they map to the
/// chart's 0..100 domain. Utilization series are already fractions;
/// throughput is bytes per second and has no ceiling to divide by.
const SparkScale = enum { fraction, raw };

fn seriesSpark(ui: *Ui, series: *const engine.SystemHistory.Series, now_ms: i64, scaling: SparkScale) []const f32 {
    // Nothing recorded yet (the first seconds after launch, or a module
    // the sampler has never answered for): draw NOTHING. A flat line
    // along zero under a live "43%" reading is a contradiction the eye
    // resolves by trusting the picture.
    if (series.isEmpty()) return &.{};
    const out = ui.arena.alloc(f32, strip_spark_points) catch {
        ui.failed = true;
        return &.{};
    };
    var raw: [engine.SystemHistory.buckets]?f32 = undefined;
    _ = series.snapshot(&raw);
    const period = engine.SystemHistory.period_ms;
    const offset = ringOffset(series.windowStartMs(), period, raw.len, out.len, @divFloor(now_ms, period));
    var held: f32 = 0;
    for (out, 0..) |*slot, i| {
        if (ringAt(?f32, &raw, offset, i) orelse null) |value| {
            held = switch (scaling) {
                .fraction => std.math.clamp(value, 0, 1) * 100,
                .raw => @max(value, 0),
            };
        }
        slot.* = held;
    }
    return out;
}

/// The NET cell's trace: rx + tx against the window's own peak, because
/// throughput has no natural 100% and a fixed denominator would render
/// every home connection as a flat line at zero.
fn netSpark(ui: *Ui, hist: *const engine.SystemHistory, now_ms: i64) []const f32 {
    const rx = seriesSpark(ui, &hist.net_rx, now_ms, .raw);
    const tx = seriesSpark(ui, &hist.net_tx, now_ms, .raw);
    const out = ui.arena.alloc(f32, @min(rx.len, tx.len)) catch {
        ui.failed = true;
        return &.{};
    };
    var peak: f32 = 0;
    for (out, 0..) |*slot, i| {
        slot.* = rx[i] + tx[i];
        peak = @max(peak, slot.*);
    }
    if (peak > 0) {
        for (out) |*slot| slot.* = slot.* / peak * 100;
    }
    return out;
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

fn zoneColor(frac: f32, lit: bool) Color {
    if (frac >= red_start) return if (lit) theme.red else theme.red_dim;
    if (frac >= green_end) return if (lit) theme.amber else theme.amber_dim;
    return if (lit) theme.green else theme.green_dim;
}

fn agentInk(agent: types.Agent) Color {
    return theme.agentInk(@intFromEnum(agent));
}

fn agentUpper(ui: *Ui, agent: types.Agent) []const u8 {
    const label = agent.label();
    const out = ui.arena.alloc(u8, label.len) catch {
        ui.failed = true;
        return label;
    };
    return std.ascii.upperString(out, label);
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
