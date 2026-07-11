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
