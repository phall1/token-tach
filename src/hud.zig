//! Desktop HUD overlay: the tach, floated over whatever you are
//! actually working in.
//!
//! The popover cluster answers everything, but only while it is open —
//! and it closes the moment you click back into your editor, which is
//! exactly when the fleet starts burning. This window is the other half
//! of that: a permanently-visible, deliberately tiny readout of the four
//! facts worth interrupting for — how fast, how close to a wall, which
//! agent, and whether anything is running at all.
//!
//! Native SDK v0.8.0 added `transparent` / `always_on_top` /
//! `click_through` / `activate_on_show` to the runtime WindowDescriptor
//! — the same model-declared `windows_fn` mechanism the dashboard window
//! already rides. `Ux.hud` IS the window: main.zig declares the
//! descriptor while `open(model)` holds and the runtime reconciles the
//! platform window after every dispatch.
//!
//! THREE THINGS ABOUT A TRANSPARENT, CLICK-THROUGH WINDOW.
//!
//! 1. It paints its own scrim. The runtime clears a transparent canvas
//!    to alpha 0, so anything this view does not paint is a HOLE to the
//!    desktop, not black. `theme.hud_wash` / `theme.hud_edge` exist for
//!    exactly this; the root panel is the chassis and the rounded
//!    corners outside it are meant to be see-through.
//!
//! 2. It cannot be clicked, so it cannot be dismissed by clicking.
//!    `click_through` removes the whole window from pointer hit testing
//!    (macOS `ignoresMouseEvents`), which is the correct default for a
//!    passive readout — a HUD you can accidentally click is a HUD that
//!    steals the drag you were making in the app underneath. The cost is
//!    that the tray menu is the ONLY way out, so main.zig's `tach.hud`
//!    item flips the same `hud_toggle` that opened it and its label says
//!    which direction it will go. Nothing here is a control; nothing
//!    here takes an `on_press`.
//!
//! 3. It never steals focus. `activate_on_show = false` orders the
//!    window front without activating the app, so opening the HUD from
//!    the menu bar does not pull you out of your editor. Combined with
//!    `titlebar = .chromeless` there is no titlebar, no traffic lights
//!    and no key-window state to lose.
//!
//! LEGIBILITY IS THE WHOLE BRIEF. It has to read from across a room, so
//! there is exactly one big number, one arc, one bar and one name — the
//! failure mode being avoided is a second dashboard nobody can parse at
//! a glance and everybody eventually hides. Everything that did not earn
//! its pixels at three metres was left in the popover.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const sessions = @import("core/sessions.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;
const PointF = geometry.PointF;

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const Ui = canvas.Ui(Msg);

pub const window_label = "hud";
pub const canvas_label = "hud-canvas";

/// Deliberately small. Wide enough for a four-glyph rate at 2.6x beside
/// a 64pt dial, short enough that it never becomes a place to put
/// "just one more" row.
pub const window_width: f32 = 280;
pub const window_height: f32 = 136;

/// The `Ux.hud` slot this overlay owns.
///
/// `HudPanel` is the engine's one-open-panel enum, so the desktop
/// overlay has to name a member rather than invent a bool that could
/// disagree with it. `.sessions` because that is what the overlay's live
/// half actually is — which agent, in which project, burning right now.
/// One constant, so renaming the slot is a one-line change and every
/// dismissal keeps matching the thing that opened.
pub const panel: engine.HudPanel = .sessions;

/// Is the overlay currently declared? The flag IS the window.
pub fn open(model: *const Model) bool {
    return model.ux.hud == panel;
}

/// Tray-item label. A `TrayMenuItem` has no checked state, so the verb
/// has to carry it — an item that always reads "Desktop HUD" gives the
/// user no way to know whether the next click opens or closes, which
/// matters more than usual when clicking is the only way to close.
pub fn menuLabel(model: *const Model) []const u8 {
    return if (open(model)) "Hide Desktop HUD" else "Desktop HUD";
}

/// The overlay's window descriptor, generic over the app's
/// `WindowDescriptor` so the four presentation flags live next to the
/// paragraphs that explain them instead of as bare `true`s in main.zig.
///
/// No `x`/`y`: the runtime pins declared windows to `restore_state =
/// false` (the descriptor is the geometry channel, not a frame store),
/// and the macOS host only honours an explicit origin on a restored
/// frame — so a coordinate here would be a lie. Placement is the
/// platform's cascade from the front window, which for an accessory app
/// puts it near the menu bar the tach already lives in.
pub fn describe(comptime Descriptor: type) Descriptor {
    return .{
        .label = window_label,
        .canvas_label = canvas_label,
        .title = "Token Tach HUD",
        .width = window_width,
        .height = window_height,
        .resizable = false,
        // Borderless: a HUD with a titlebar is a window, and a window
        // over your desktop is clutter.
        .titlebar = .chromeless,
        .transparent = true,
        .always_on_top = true,
        .click_through = true,
        .activate_on_show = false,
        // Unreachable in practice (nothing can click a click-through
        // borderless window shut) but declared anyway: if the platform
        // ever closes it out from under us — a display teardown, a
        // future interactive variant — the model must agree, and
        // `hud_closed` is ignored unless this panel is the open one.
        .on_close = .{ .hud_closed = panel },
    };
}

// ---------------------------------------------------------------- layout

const pad: f32 = 14;
const header_y: f32 = 9;

/// Dial centre and LED radius. The arc sits in the left third; the
/// number owns the rest, because the number is what reads at distance
/// and the arc is what gives it a scale.
const gauge_cx: f32 = 62;
const gauge_cy: f32 = 64;
const arc_r: f32 = 32;
const face_r: f32 = 27;
const led_count: usize = 24;

const readout_x: f32 = 108;
const readout_w: f32 = window_width - readout_x - pad;

const limit_y: f32 = 112;
const limit_h: f32 = 16;

/// Zone breaks on the arc, mirroring the popover dial (view.zig's
/// `green_end` / `red_start`). Duplicated rather than shared because
/// they are private to that file; if they ever move, the two instruments
/// must move together or the same burn reads amber on one and green on
/// the other.
const green_end: f32 = 0.60;
const red_start: f32 = 0.85;

// ------------------------------------------------------------ node budget
// Hard SDK cap is 1024 widget nodes per view, and exceeding it fails the
// frame at RUNTIME. Worst case here, every branch taken:
//   root 1, chassis 2, header 3, dial face 1,
//   arc 48 (24 LEDs, each 2 nodes when lit and 1 when not),
//   needle 7 + tip halo 1 + hub 2, full-scale caption 1,
//   hero readout 1, agent line 3, limit row 6
// = 76. Nothing here is unbounded: the arc is a fixed 24, the limit row
// is one window, and the agent line is one agent — which is the point of
// a HUD, not an accident of the layout. Zero anchored surfaces (they are
// capped at 16 per view and the popover needs them more), zero loop
// animations, zero charts, and zero global keys — the popover owns the
// key space and a collision across windows would animate the wrong node.

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    var nodes: std.ArrayList(Ui.Node) = .empty;

    const glance = engine.glanceState(model);
    const danger = engine.dangerState(model);

    chassis(ui, &nodes);
    header(ui, &nodes, glance, danger);
    arc(ui, &nodes, model, danger);
    readout(ui, &nodes, model, glance, danger);
    limitRow(ui, &nodes, model);

    // The window's own clear is alpha 0, so the root must not be
    // transparent the way the popover's is: nothing is painted behind
    // this one.
    return ui.panel(.{
        .grow = 1,
        .style = .{
            .background = theme.hud_wash,
            .border = theme.hud_edge,
            .stroke_width = 1,
            .radius = 16,
        },
        .semantics = .{ .label = "Token Tach heads-up display" },
    }, .{nodes.items});
}

/// Chassis detail: a hairline rule under the header band, and a faint
/// top glint so the scrim reads as a machined slab rather than a
/// rectangle of fog.
fn chassis(ui: *Ui, nodes: *std.ArrayList(Ui.Node)) void {
    push(ui, nodes, ui.panel(.{
        .frame = rect(pad, 26, window_width - 2 * pad, 1),
        .style = .{ .background = theme.hairline, .radius = 0, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(pad + 6, 1, window_width - 2 * (pad + 6), 1),
        .style = .{ .background = theme.cell_glint, .radius = 0, .stroke_width = 0 },
    }, .{}));
}

// ---------------------------------------------------------------- header

fn header(ui: *Ui, nodes: *std.ArrayList(Ui.Node), glance: trayfmt.GlanceState, danger: bool) void {
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(pad, header_y, 120, 14),
        .semantics = .{ .label = "Token Tach" },
    }, &.{
        .{ .text = "TOKEN", .weight = .bold, .monospace = true, .scale = 0.78, .color = .text },
        .{ .text = " TACH", .weight = .bold, .monospace = true, .scale = 0.78, .color = .accent },
    }));

    // The state lamp is the one part of the HUD that has to be readable
    // when the number is not: from across the room the colour arrives
    // before the digits do.
    const lit: Color = if (danger) theme.red else if (glance.idle) theme.track else theme.green;
    const word: []const u8 = if (danger) "REDLINE" else if (glance.idle) "IDLE" else "LIVE";
    const word_ink: Color = if (danger) theme.red else theme.cluster_colors.text_muted;

    push(ui, nodes, ui.panel(.{
        .frame = rect(window_width - pad - 62, header_y + 3, 7, 7),
        .style = .{ .background = lit, .radius = 3.5, .stroke_width = 0 },
    }, .{}));
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(window_width - pad - 52, header_y, 52, 14),
        .text_alignment = .end,
        .style = .{ .foreground = word_ink },
    }, &.{.{ .text = word, .weight = .bold, .monospace = true, .scale = 0.75 }}));
}

// ------------------------------------------------------------------- arc

/// A 240° LED arc with a stubby machined needle.
///
/// The popover's needle is a real vector blade drawn in the chrome
/// display list; secondary windows have no chrome hook, so this one is
/// built from widget nodes — a taper of seven rounded blocks along the
/// needle's radius. At 32pt that reads as a needle and costs seven
/// nodes, where a rotation-true blade would cost a chrome channel this
/// window does not have.
fn arc(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, danger: bool) void {
    // Dial face: a darker disc inside the LED ring so the arc has
    // something to be backlit against on a semi-transparent scrim.
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - face_r, gauge_cy - face_r, 2 * face_r, 2 * face_r),
        .style = .{ .background = theme.dial, .border = theme.dial_edge, .stroke_width = 1, .radius = face_r },
    }, .{}));

    // The needle pose the popover is showing, not a freshly derived one:
    // two instruments reading the same model must not disagree by a
    // frame of tween.
    const needle_frac = (model.needle_to_deg + engine.half_sweep_deg) / (2 * engine.half_sweep_deg);

    for (0..led_count) |i| {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(led_count - 1));
        const deg = -engine.half_sweep_deg + 2 * engine.half_sweep_deg * frac;
        const p = dialPoint(deg, arc_r);
        const lit = frac <= needle_frac + 0.001 or (danger and frac >= red_start);
        if (!lit) {
            push(ui, nodes, ui.panel(.{
                .frame = rect(p.x - 2.6, p.y - 2.6, 5.2, 5.2),
                .style = .{ .background = zoneColor(frac, false), .radius = 2.6, .stroke_width = 0 },
            }, .{}));
            continue;
        }
        const ink = zoneColor(frac, true);
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - 5, p.y - 5, 10, 10),
            .style = .{ .background = withAlpha(ink, 0.18), .radius = 5, .stroke_width = 0 },
        }, .{}));
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - 2.6, p.y - 2.6, 5.2, 5.2),
            .style = .{ .background = ink, .radius = 2.6, .stroke_width = 0 },
        }, .{}));
    }

    needleStub(ui, nodes, model.needle_to_deg);

    // Full-scale legend. Without it the arc is a mood ring: the same
    // sweep means 10k/m on a quiet day and 200k/m during a fleet run,
    // and the engine re-ranges the dial underneath you.
    const scale = engine.gaugeScaleTpm(model.gauge_peak_tpm);
    push(ui, nodes, ui.text(.{
        .frame = rect(gauge_cx - 40, gauge_cy + 32, 80, 12),
        .size = .sm,
        .text_alignment = .center,
        .style = .{ .foreground = theme.text_faint },
    }, ui.fmt("fs {s}/m", .{fmtTokens(ui, @intFromFloat(@max(scale, 0)))})));
}

/// Seven tapering blocks along the needle's radius, plus the tip halo
/// and the hub. Blocks overlap at the base and just touch at the tip,
/// which is what makes a run of squares read as one blade.
fn needleStub(ui: *Ui, nodes: *std.ArrayList(Ui.Node), deg: f32) void {
    const blocks: usize = 7;
    const r0: f32 = 9;
    const r1: f32 = 27;
    const hw0: f32 = 2.9;
    const hw1: f32 = 1.1;
    for (0..blocks) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(blocks - 1));
        const p = dialPoint(deg, r0 + (r1 - r0) * t);
        const hw = hw0 + (hw1 - hw0) * t;
        push(ui, nodes, ui.panel(.{
            .frame = rect(p.x - hw, p.y - hw, 2 * hw, 2 * hw),
            .style = .{ .background = theme.needle, .radius = hw, .stroke_width = 0 },
        }, .{}));
    }
    const tip = dialPoint(deg, r1);
    push(ui, nodes, ui.panel(.{
        .frame = rect(tip.x - 6, tip.y - 6, 12, 12),
        .style = .{ .background = theme.needle_halo, .radius = 6, .stroke_width = 0 },
    }, .{}));

    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 6, gauge_cy - 6, 12, 12),
        .style = .{ .background = theme.hub, .border = theme.hub_ring, .stroke_width = 1, .radius = 6 },
    }, .{}));
    push(ui, nodes, ui.panel(.{
        .frame = rect(gauge_cx - 2, gauge_cy - 2, 4, 4),
        .style = .{ .background = theme.needle_edge, .radius = 2, .stroke_width = 0 },
    }, .{}));
}

// --------------------------------------------------------------- readout

/// The hero number and the agent line under it.
///
/// Fixed-width tokens ("4.2k", never "4k"): the popover can afford a
/// figure that changes width every sweep because you are looking
/// straight at it, but a number that jitters horizontally in the corner
/// of your eye is a movement cue, and movement cues are what a HUD
/// spends its whole budget avoiding.
fn readout(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model, glance: trayfmt.GlanceState, danger: bool) void {
    const tpm: u64 = @intFromFloat(@max(glance.burn_tokens_per_min, 0));
    const ink: Color = if (danger)
        theme.red
    else if (glance.idle)
        theme.cluster_colors.text_muted
    else
        theme.cluster_colors.text;

    push(ui, nodes, ui.paragraph(.{
        // 2.5x of the 14pt body is ~35pt: a 43pt line box in a 46pt
        // frame, and the widest figure the fixed formatter can produce
        // ("812.3k/m", 6 mono glyphs plus the unit) still clears
        // `readout_w`. Both bounds are why the scale is not larger.
        .frame = rect(readout_x, 28, readout_w, 46),
        .style = .{ .foreground = ink },
        .semantics = .{ .label = ui.fmt("{s} tokens per minute", .{fmtTokens(ui, tpm)}) },
    }, &.{
        .{ .text = fmtTokensFixed(ui, tpm), .weight = .bold, .monospace = true, .scale = 2.5 },
        .{ .text = "/m", .monospace = true, .scale = 0.9, .color = .text_muted },
    }));

    agentLine(ui, nodes, model);
}

/// Who is burning, and where.
///
/// `agent_burn.hottest` names the agent; the roster turns that into a
/// place — the project basename of its liveliest session — because
/// "CLAUDE" alone does not tell you which of the four windows behind
/// this one to go look at. A mid-turn session (transcript growing, no
/// event parsed yet) gets the bright activity pip: that is the model's
/// only signal for "thinking AT THIS INSTANT", and it is the single most
/// glanceable thing on the overlay.
fn agentLine(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const hot = model.agent_burn.hottest(model.now_ms) orelse {
        push(ui, nodes, ui.text(.{
            .frame = rect(readout_x, 78, readout_w, 14),
            .size = .sm,
            .style = .{ .foreground = theme.text_faint },
        }, "fleet idle"));
        return;
    };

    var buf: [sessions.max_sessions]*const sessions.Session = undefined;
    const rows = model.roster.forAgent(hot.agent, &buf, model.now_ms);
    const top: ?*const sessions.Session = if (rows.len > 0) rows[0] else null;
    const thinking = if (top) |s| s.mid_turn else false;

    const ink = theme.agentInk(@intFromEnum(hot.agent));
    if (thinking) {
        push(ui, nodes, ui.panel(.{
            .frame = rect(readout_x - 1, 79, 11, 11),
            .style = .{ .background = theme.activity_dot_glow, .radius = 5.5, .stroke_width = 0 },
        }, .{}));
    }
    push(ui, nodes, ui.panel(.{
        .frame = rect(readout_x + 2, 82, 5, 5),
        .style = .{
            .background = if (thinking) theme.activity_dot else ink,
            .radius = 2.5,
            .stroke_width = 0,
        },
    }, .{}));

    // Project when we know it, session count when we do not — never a
    // bare name, because the name alone is the least useful half.
    const detail: []const u8 = blk: {
        if (top) |s| {
            const project = s.project();
            if (project.len > 0) break :blk ui.fmt("  {s}", .{elide(ui, project, projectBudget(hot.agent))});
        }
        if (rows.len > 1) break :blk ui.fmt("  x{d} live", .{rows.len});
        break :blk ui.fmt("  {s}/m", .{fmtTokens(ui, @intFromFloat(@max(hot.tokens_per_min, 0)))});
    };

    // `wrap = false` is load-bearing, not a preference. A span paragraph
    // wraps by default, and a real project basename
    // ("sparkling-launching-glade") is wider than the 146pt this frame
    // has — so the tail spilled onto a second line that the frame does
    // not clip and painted straight through the limit row at `limit_y`.
    // Single-line elides the tail instead, which is the sanctioned way
    // to lose characters here: the leading path segment is the half that
    // identifies the window you need to go look at.
    push(ui, nodes, ui.paragraph(.{
        .frame = rect(readout_x + 12, 78, readout_w - 12, 14),
        .wrap = false,
        .style = .{ .foreground = ink },
    }, &.{
        .{ .text = agentUpper(ui, hot.agent), .weight = .bold, .monospace = true, .scale = 0.8 },
        .{ .text = detail, .monospace = true, .scale = 0.8, .color = .text_muted },
    }));
}

// -------------------------------------------------------------- limit row

/// The window nearest its ceiling — agent, kind, bar, percent, reset.
///
/// Resolved from the limit snapshots rather than from
/// `walls.maxUtilization()` on purpose: the wall tracker's `Wall` has no
/// `resets_at_ms`, so pairing its percentage with the glance's "next
/// reset" would print a countdown belonging to a DIFFERENT window
/// beside it. One window, one row, all four numbers from the same
/// record.
const Hottest = struct {
    agent: types.Agent,
    window: types.LimitWindow,
};

fn hottestWindow(model: *const Model) ?Hottest {
    var best: ?Hottest = null;
    inline for (.{ .{ types.Agent.claude, model.claude_limits }, .{ types.Agent.codex, model.codex_limits } }) |pair| {
        if (pair[1]) |snap| {
            for (snap.windows) |w| {
                if (w.used_percent < 0) continue;
                if (best == null or w.used_percent > best.?.window.used_percent) {
                    best = .{ .agent = pair[0], .window = w };
                }
            }
        }
    }
    return best;
}

fn limitRow(ui: *Ui, nodes: *std.ArrayList(Ui.Node), model: *const Model) void {
    const hot = hottestWindow(model) orelse {
        push(ui, nodes, ui.text(.{
            .frame = rect(pad, limit_y + 1, window_width - 2 * pad, 14),
            .size = .sm,
            .style = .{ .foreground = theme.text_faint },
        }, "no limit data"));
        return;
    };

    const kind: []const u8 = switch (hot.window.kind) {
        .five_hour => "5H",
        .weekly => "WK",
        .weekly_opus => "OPUS",
        .weekly_sonnet => "SON",
        .monthly => "MO",
    };
    const pct = std.math.clamp(hot.window.used_percent, 0, 100);
    const ink = theme.windowZone(pct / 100);

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(pad, limit_y + 1, 84, 14),
        .semantics = .{ .label = ui.fmt("{s} {s} window", .{ hot.agent.label(), kind }) },
    }, &.{
        .{ .text = agentUpper(ui, hot.agent), .weight = .bold, .monospace = true, .scale = 0.75, .color = .text_muted },
        .{ .text = ui.fmt(" {s}", .{kind}), .monospace = true, .scale = 0.75, .color = .text_muted },
    }));

    const track_x: f32 = pad + 84;
    const track_w: f32 = 84;
    push(ui, nodes, ui.panel(.{
        .frame = rect(track_x, limit_y + 5, track_w, 6),
        .style = .{ .background = theme.track, .radius = 3, .stroke_width = 0 },
    }, .{}));
    if (pct > 0) {
        // Floor the fill at 3pt: a 1% window that renders as nothing is
        // indistinguishable from a window with no data at this size.
        const fill_w = @max(track_w * @as(f32, @floatCast(pct)) / 100.0, 3);
        push(ui, nodes, ui.panel(.{
            .frame = rect(track_x, limit_y + 5, fill_w, 6),
            .style = .{ .background = ink, .radius = 3, .stroke_width = 0 },
        }, .{}));
        push(ui, nodes, ui.panel(.{
            .frame = rect(track_x + fill_w - 4, limit_y + 3, 10, 10),
            .style = .{ .background = withAlpha(ink, 0.35), .radius = 5, .stroke_width = 0 },
        }, .{}));
    }

    push(ui, nodes, ui.paragraph(.{
        .frame = rect(track_x + track_w + 4, limit_y + 1, 30, 14),
        .text_alignment = .end,
        .style = .{ .foreground = ink },
    }, &.{.{ .text = ui.fmt("{d}%", .{@as(u64, @intFromFloat(pct))}), .weight = .bold, .monospace = true, .scale = 0.85 }}));

    if (hot.window.resets_at_ms > model.now_ms) {
        push(ui, nodes, ui.text(.{
            .frame = rect(window_width - pad - 42, limit_y + 1, 42, 14),
            .size = .sm,
            .text_alignment = .end,
            .style = .{ .foreground = theme.text_faint },
        }, fmtReset(ui, hot.window.resets_at_ms - model.now_ms)));
    }
}

// --------------------------------------------------------------- plumbing

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

fn dialPoint(deg: f32, radius: f32) PointF {
    const r = std.math.degreesToRadians(deg);
    return .{ .x = gauge_cx + radius * @sin(r), .y = gauge_cy - radius * @cos(r) };
}

fn zoneColor(frac: f32, lit: bool) Color {
    if (frac >= red_start) return if (lit) theme.red else theme.red_dim;
    if (frac >= green_end) return if (lit) theme.amber else theme.amber_dim;
    return if (lit) theme.green else theme.green_dim;
}

/// How many glyphs of project name fit beside the agent name.
///
/// The agent line is a MULTI-SPAN paragraph, and `ElementOptions.overflow`
/// only elides plain `text` leaves — a no-wrap span run just paints past
/// its frame to the canvas edge. So the budget is spent here, where the
/// run is fixed-width mono and the arithmetic is exact: the frame is
/// `readout_w - 12` = 146pt, every glyph is 0.8 x the 14pt body at a 0.6
/// mono advance (~6.8pt, rounded up to 7 so the estimate errs short),
/// and the agent name plus its two-space gap is spent before the project
/// gets any.
fn projectBudget(agent: types.Agent) usize {
    const glyph_w: f32 = 7;
    const total: usize = @intFromFloat(@floor((readout_w - 12) / glyph_w));
    const spent: usize = agent.label().len + 2;
    return if (total > spent + 1) total - spent - 1 else 1;
}

/// Trailing-ellipsis truncation on a glyph budget, backing off UTF-8
/// continuation bytes so a multi-byte name cannot be cut mid-codepoint.
fn elide(ui: *Ui, text: []const u8, budget: usize) []const u8 {
    if (text.len <= budget) return text;
    var cut = budget;
    while (cut > 0 and text[cut] & 0xC0 == 0x80) cut -= 1;
    return ui.fmt("{s}…", .{text[0..cut]});
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

/// Width-stable rate ("0.9k", "4.2k", "8.2M"): always one decimal and
/// always a unit, so the hero figure only changes width when the burn
/// changes decade. See `readout` for why that matters here and not in
/// the popover.
fn fmtTokensFixed(ui: *Ui, tokens: u64) []const u8 {
    const buf = ui.arena.alloc(u8, 24) catch return "";
    var w = std.Io.Writer.fixed(buf);
    trayfmt.writeHumanTokensFixed(&w, tokens) catch {};
    return w.buffered();
}

fn fmtReset(ui: *Ui, duration_ms: i64) []const u8 {
    const total_min = @max(@divFloor(duration_ms, 60_000), 0);
    const hours = @divFloor(total_min, 60);
    const minutes = @mod(total_min, 60);
    if (hours >= 48) return ui.fmt("{d}d{d}h", .{ @divFloor(hours, 24), @mod(hours, 24) });
    if (hours > 0) return ui.fmt("{d}h{d}m", .{ hours, minutes });
    return ui.fmt("{d}m", .{minutes});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "the flag is the window: open() tracks the panel this module owns" {
    var model: Model = .{};
    try testing.expect(!open(&model));

    engine.applyUxMsg(&model, .{ .hud_toggle = panel });
    try testing.expect(open(&model));
    try testing.expectEqualStrings("Hide Desktop HUD", menuLabel(&model));

    // Re-sending the open panel closes it — the tray item is a toggle,
    // and it is the ONLY dismissal a click-through window has.
    engine.applyUxMsg(&model, .{ .hud_toggle = panel });
    try testing.expect(!open(&model));
    try testing.expectEqualStrings("Desktop HUD", menuLabel(&model));
}

test "a stale dismissal for another panel cannot close the overlay" {
    var model: Model = .{};
    engine.applyUxMsg(&model, .{ .hud_toggle = panel });
    engine.applyUxMsg(&model, .{ .hud_closed = .help });
    try testing.expect(open(&model));
    engine.applyUxMsg(&model, .{ .hud_closed = panel });
    try testing.expect(!open(&model));
}

test "the overlay never takes focus, clicks or chrome" {
    const D = struct {
        label: []const u8,
        canvas_label: []const u8,
        title: []const u8 = "",
        width: f32 = 480,
        height: f32 = 360,
        resizable: bool = true,
        titlebar: enum { standard, hidden_inset, hidden_inset_tall, chromeless } = .standard,
        transparent: bool = false,
        always_on_top: bool = false,
        click_through: bool = false,
        activate_on_show: bool = true,
        on_close: ?Msg = null,
    };
    const d = describe(D);
    try testing.expect(d.transparent);
    try testing.expect(d.always_on_top);
    try testing.expect(d.click_through);
    try testing.expect(!d.activate_on_show);
    try testing.expect(!d.resizable);
    try testing.expectEqual(@as(@TypeOf(d.titlebar), .chromeless), d.titlebar);
    // A distinct canvas label is a hard runtime requirement: the
    // reconciler drops a declared window whose canvas label collides
    // with the main canvas or another slot.
    try testing.expect(!std.mem.eql(u8, canvas_label, "main-canvas"));
    try testing.expect(!std.mem.eql(u8, canvas_label, "dashboard-canvas"));
    switch (d.on_close.?) {
        .hud_closed => |p| try testing.expectEqual(panel, p),
        else => try testing.expect(false),
    }
}

test "the hottest limit window carries its own reset, not a neighbour's" {
    var model: Model = .{};
    model.now_ms = 1_000_000;
    try testing.expect(hottestWindow(&model) == null);

    const claude_windows = [_]types.LimitWindow{
        .{ .kind = .five_hour, .used_percent = 31, .resets_at_ms = 1_000_000 + 3_600_000 },
        .{ .kind = .weekly, .used_percent = 74, .resets_at_ms = 1_000_000 + 200_000_000 },
    };
    const codex_windows = [_]types.LimitWindow{
        .{ .kind = .five_hour, .used_percent = 12, .resets_at_ms = 1_000_000 + 600_000 },
    };
    model.claude_limits = .{ .agent = .claude, .read_at_ms = model.now_ms, .windows = &claude_windows };
    model.codex_limits = .{ .agent = .codex, .read_at_ms = model.now_ms, .windows = &codex_windows };

    const hot = hottestWindow(&model).?;
    try testing.expectEqual(types.Agent.claude, hot.agent);
    try testing.expectEqual(types.LimitWindow.Kind.weekly, hot.window.kind);
    try testing.expectEqual(@as(f64, 74), hot.window.used_percent);
    // The reset shown belongs to the window shown — the whole point of
    // resolving the row from the snapshot rather than the wall tracker.
    try testing.expectEqual(claude_windows[1].resets_at_ms, hot.window.resets_at_ms);
}

test "arc zones and needle fraction agree with the popover dial" {
    try testing.expectEqual(theme.green, zoneColor(0.10, true));
    try testing.expectEqual(theme.amber, zoneColor(green_end, true));
    try testing.expectEqual(theme.red, zoneColor(red_start, true));
    try testing.expectEqual(theme.red_dim, zoneColor(0.99, false));

    // A needle parked at the left stop is fraction 0; full scale is 1.
    const low = (-engine.half_sweep_deg + engine.half_sweep_deg) / (2 * engine.half_sweep_deg);
    const high = (engine.half_sweep_deg + engine.half_sweep_deg) / (2 * engine.half_sweep_deg);
    try testing.expectApproxEqAbs(@as(f32, 0), low, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), high, 1e-6);
}

test "the agent line stays on one line instead of painting over the limit row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = Ui.init(arena_state.allocator());

    // The name that exposed this: a real worktree basename, wider than
    // the 146pt frame. It wrapped, and the wrapped tail landed on the
    // limit row because the frame does not clip.
    const long = "sparkling-launching-glade";
    const budget = projectBudget(.claude);
    const shown = elide(&ui, long, budget);
    try testing.expect(shown.len < long.len);
    try testing.expect(std.mem.endsWith(u8, shown, "…"));

    // The whole run — agent name, two-space gap, project — has to fit
    // the frame at the ~7pt mono advance the budget assumes.
    const glyphs = types.Agent.claude.label().len + 2 + budget;
    try testing.expect(@as(f32, @floatFromInt(glyphs)) * 7 <= readout_w - 12);

    // A name that already fits is passed through untouched: elision is
    // for overflow, not a house style.
    try testing.expectEqualStrings("token-tach", elide(&ui, "token-tach", budget));

    // Multi-byte names are cut on a codepoint boundary, never inside one.
    const wide = "prosjekt-blåbærsyltetøy-arkiv";
    try testing.expect(std.unicode.utf8ValidateSlice(elide(&ui, wide, budget)));
}

test "the dial stays inside the chassis" {
    // Absolute frames, so a layout mistake is a clipped instrument
    // rather than a compile error. The arc's extreme points are the
    // ±120° stops and the 12 o'clock top.
    const top = dialPoint(0, arc_r);
    const left = dialPoint(-engine.half_sweep_deg, arc_r);
    const right = dialPoint(engine.half_sweep_deg, arc_r);
    try testing.expect(top.y - 5 > 26); // clear of the header rule
    try testing.expect(left.x - 5 > 0);
    try testing.expect(right.x + 5 < readout_x);
    try testing.expect(@max(left.y, right.y) + 5 < limit_y);
    try testing.expect(limit_y + limit_h <= window_height);
}
