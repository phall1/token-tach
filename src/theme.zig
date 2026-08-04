//! token-tach theme: a fixed dark precision-instrument token set.
//! The brief is automotive without cosplay: graphite cabin materials,
//! restrained phosphor telemetry, amber caution, and a signal-orange needle.
//! The cluster is always dark (a backlit dial has no light mode), so
//! this opts out of system-appearance following deliberately.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

pub fn tokens() canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        .color_scheme = .dark,
        .contrast = .standard,
        .reduce_motion = false,
    });
    out.colors = cluster_colors;
    out.radius = .{ .sm = 2, .md = 4, .lg = 7, .xl = 10 };
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    return out;
}

/// Token palette: cool near-black neutrals, instrument green as accent,
/// the status trio tuned for glow on a dark dial.
pub const cluster_colors = canvas.ColorTokens{
    .background = Color.rgb8(7, 9, 10),
    .surface = Color.rgb8(13, 17, 18),
    .surface_subtle = Color.rgb8(18, 23, 24),
    .surface_pressed = Color.rgba8(255, 255, 255, 24),
    .text = Color.rgb8(231, 235, 232),
    .text_muted = Color.rgb8(128, 141, 136),
    .border = Color.rgba8(220, 232, 226, 24),
    .accent = Color.rgb8(62, 224, 154),
    .accent_text = Color.rgb8(7, 9, 10),
    .destructive = Color.rgb8(255, 77, 91),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(62, 224, 154),
    .success_text = Color.rgb8(7, 9, 10),
    .warning = Color.rgb8(240, 174, 55),
    .warning_text = Color.rgb8(7, 9, 10),
    .info = Color.rgb8(139, 166, 255),
    .info_text = Color.rgb8(7, 9, 10),
    .focus_ring = Color.rgb8(76, 104, 94),
    .shadow = Color.rgba8(0, 0, 0, 180),
    .disabled = Color.rgb8(26, 34, 38),
};

// ------------------------------------------------------- instrument inks
// Raw colors for the hand-drawn dial (Zig views may use raw style colors;
// everything text-like stays on the tokens above).

pub const bg = cluster_colors.background;
pub const bezel = Color.rgb8(13, 17, 18);
pub const bezel_edge = Color.rgba8(220, 232, 226, 25);
pub const panel = Color.rgb8(11, 15, 16);
pub const panel_raised = Color.rgb8(15, 20, 21);
pub const panel_topline = Color.rgba8(209, 224, 217, 34);
pub const dial = Color.rgb8(8, 11, 12);
pub const dial_edge = Color.rgba8(104, 232, 177, 24);
pub const hub = Color.rgb8(18, 23, 24);
pub const hub_ring = Color.rgba8(255, 255, 255, 46);

// Chrome-layer machining: gradients and glass for the hand-built
// display-list commands (panel washes, dial shading, needle metal).
pub const transparent = Color.rgba8(0, 0, 0, 0);
pub const bezel_top = Color.rgb8(17, 22, 23);
pub const bezel_bottom = Color.rgb8(10, 13, 14);
pub const dial_top = Color.rgb8(13, 17, 18);
pub const dial_bottom = Color.rgb8(5, 7, 8);
pub const dial_vignette = Color.rgba8(0, 0, 0, 96);
pub const bezel_ring = Color.rgba8(255, 255, 255, 26);
pub const glass_glare = Color.rgba8(255, 255, 255, 17);
pub const needle_edge = Color.rgb8(255, 184, 145);
pub const hub_top = Color.rgb8(49, 57, 58);
pub const hub_bottom = Color.rgb8(11, 14, 15);
pub const cell_shadow = Color.rgba8(0, 0, 0, 150);
pub const cell_glint = Color.rgba8(255, 255, 255, 12);

pub const green = cluster_colors.accent;
pub const amber = cluster_colors.warning;
pub const red = cluster_colors.destructive;
pub const green_dim = Color.rgba8(62, 224, 154, 46);
pub const amber_dim = Color.rgba8(240, 174, 55, 48);
pub const red_dim = Color.rgba8(255, 73, 89, 62);
pub const green_glow = Color.rgba8(62, 224, 154, 38);
pub const red_halo = Color.rgba8(255, 73, 89, 38);

pub const needle = Color.rgb8(255, 103, 56);
pub const needle_glow = Color.rgba8(255, 103, 56, 62);
pub const needle_halo = Color.rgba8(255, 103, 56, 28);

pub const track = Color.rgb8(25, 31, 31);
pub const cell = Color.rgb8(5, 7, 8);
pub const cell_edge = Color.rgba8(220, 232, 226, 20);
pub const hairline = Color.rgba8(220, 232, 226, 18);
pub const text_faint = Color.rgb8(79, 91, 87);

// ------------------------------------------------------------ telltales
// Real clusters print every warning lamp on the dial face and light only
// the ones that apply, so the dark glyph is part of the design rather
// than an absence. `telltale_off` is the unlit ink: visible enough to
// read as a lamp, dim enough never to compete with live data.

pub const telltale_off = Color.rgba8(220, 232, 226, 30);
pub const telltale_plate = Color.rgba8(255, 255, 255, 10);

/// A live-activity pip. Distinct from `green` so a burning agent reads
/// differently from a healthy threshold.
pub const activity_dot = Color.rgb8(120, 240, 186);
pub const activity_dot_glow = Color.rgba8(120, 240, 186, 54);
pub const idle_dot = Color.rgba8(128, 141, 136, 90);

// ------------------------------------------------------------- the scope
// The multi-lane trace band. Lanes are deliberately NOT the status trio:
// these encode identity (which quantity), not severity, and reusing
// red/amber/green here would make an ordinary CPU trace read as an alarm.

pub const scope_grid = Color.rgba8(220, 232, 226, 14);
pub const scope_axis = Color.rgba8(220, 232, 226, 26);
pub const scope_burn = Color.rgb8(62, 224, 154);
pub const scope_burn_fill = Color.rgba8(62, 224, 154, 40);
pub const scope_cpu = Color.rgb8(139, 166, 255);
pub const scope_gpu = Color.rgb8(196, 148, 255);
pub const scope_events = Color.rgba8(220, 232, 226, 64);

/// Trip-computer ink. Amber separates "since launch" from the permanent
/// odometer's green, the same way a car's trip meter is visually distinct
/// from total mileage.
pub const trip = Color.rgb8(240, 190, 110);
pub const trip_dim = Color.rgba8(240, 190, 110, 60);

// ------------------------------------------------------------- HUD glass
// The always-on-top desktop overlay renders on a transparent window, so
// it carries its own scrim: no opaque panel exists behind it.

pub const hud_wash = Color.rgba8(7, 9, 10, 214);
pub const hud_edge = Color.rgba8(220, 232, 226, 34);

// -------------------------------------------------------- source health
pub const badge_ok = Color.rgba8(62, 224, 154, 40);
pub const badge_warn = Color.rgba8(240, 174, 55, 46);
pub const badge_down = Color.rgba8(255, 77, 91, 46);

// ------------------------------------------------------- agent identity
/// One ink per agent, indexed by `types.Agent`. A stacked chart, a roster
/// row and a share bar must agree on what colour "codex" is, and that
/// agreement has to live somewhere shared or it silently drifts.
///
/// Ordered to match `types.Agent`. Claude keeps the signal orange it
/// already owns through the needle; codex takes the accent green; the
/// rest are spaced around the wheel for separability at 6pt, not chosen
/// for brand fidelity. Hues stay above ~55% saturation so they survive
/// the dial's vignette.
pub const agent_ink = [_]Color{
    Color.rgb8(255, 133, 92), // claude
    Color.rgb8(62, 224, 154), // codex
    Color.rgb8(139, 166, 255), // opencode
    Color.rgb8(240, 174, 55), // pi
    Color.rgb8(120, 214, 255), // gemini
    Color.rgb8(196, 148, 255), // qwen
    Color.rgb8(255, 138, 196), // kimi
    Color.rgb8(148, 222, 128), // goose
    Color.rgb8(255, 196, 108), // kilo
    Color.rgb8(108, 214, 214), // cline
    Color.rgb8(186, 186, 140), // roo
    Color.rgb8(160, 176, 200), // copilot
    Color.rgb8(200, 160, 140), // continue_cli
    Color.rgb8(140, 200, 176), // droid
};

/// Ink for an agent by enum ordinal, saturating on the last entry so a
/// newly-added `Agent` renders in a real colour instead of crashing.
pub fn agentInk(ordinal: usize) Color {
    return agent_ink[@min(ordinal, agent_ink.len - 1)];
}

// ------------------------------------------------------- zone thresholds
// Five different threshold ladders grew across the view, and they are NOT
// interchangeable — a limit-window utilization, an instantaneous machine
// load, and a battery charge mean different things and legitimately break
// at different points. They are gathered here so the numbers are declared
// with their reasoning in one place rather than buried as literals at
// five call sites, and so a change is a change everywhere it should be.

/// Limit-window utilization (5h / weekly bars). Caution at half the
/// window because that is when pacing still helps; danger at 80% because
/// the remaining fifth is where a wall becomes plausible within a session.
pub fn windowZone(fraction: f64) Color {
    if (fraction >= 0.80) return red;
    if (fraction >= 0.50) return amber;
    return green;
}

/// Machine load (CPU/GPU/memory). Higher breakpoints than a quota: a
/// busy machine is normal and colouring it amber at half load would make
/// the strip cry wolf during every build.
pub fn loadZone(fraction: f64) Color {
    if (fraction >= 0.90) return red;
    if (fraction >= 0.70) return amber;
    return green;
}

/// Disk capacity. Tighter than load because the failure is a cliff, not
/// a slowdown, and the warning has to arrive early enough to act on.
pub fn diskZone(used_fraction: f64) Color {
    if (used_fraction >= 0.92) return red;
    if (used_fraction >= 0.80) return amber;
    return green;
}

/// Battery charge — inverted: LOW is the alarming end.
pub fn chargeZone(fraction: f64) Color {
    if (fraction <= 0.15) return red;
    if (fraction <= 0.35) return amber;
    return green;
}
