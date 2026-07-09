//! token-tach theme: a fixed dark "instrument cluster" token set.
//! The brief is automotive — near-black cabin, phosphor-green primary
//! illumination, amber caution, red warning, a hot tangerine needle.
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
    out.radius = .{ .sm = 3, .md = 5, .lg = 8, .xl = 12 };
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    return out;
}

/// Token palette: cool near-black neutrals, instrument green as accent,
/// the status trio tuned for glow on a dark dial.
pub const cluster_colors = canvas.ColorTokens{
    .background = Color.rgb8(6, 9, 11),
    .surface = Color.rgb8(12, 17, 20),
    .surface_subtle = Color.rgb8(16, 22, 26),
    .surface_pressed = Color.rgba8(255, 255, 255, 30),
    .text = Color.rgb8(222, 236, 229),
    .text_muted = Color.rgb8(118, 136, 130),
    .border = Color.rgba8(255, 255, 255, 20),
    .accent = Color.rgb8(52, 224, 141),
    .accent_text = Color.rgb8(6, 9, 11),
    .destructive = Color.rgb8(255, 73, 89),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(52, 224, 141),
    .success_text = Color.rgb8(6, 9, 11),
    .warning = Color.rgb8(255, 179, 36),
    .warning_text = Color.rgb8(6, 9, 11),
    .info = Color.rgb8(167, 139, 250),
    .info_text = Color.rgb8(6, 9, 11),
    .focus_ring = Color.rgb8(74, 96, 88),
    .shadow = Color.rgba8(0, 0, 0, 180),
    .disabled = Color.rgb8(26, 34, 38),
};

// ------------------------------------------------------- instrument inks
// Raw colors for the hand-drawn dial (Zig views may use raw style colors;
// everything text-like stays on the tokens above).

pub const bg = cluster_colors.background;
pub const bezel = Color.rgb8(12, 17, 20);
pub const bezel_edge = Color.rgba8(255, 255, 255, 16);
pub const dial = Color.rgb8(8, 12, 14);
pub const dial_edge = Color.rgba8(110, 235, 180, 26);
pub const hub = Color.rgb8(17, 24, 27);
pub const hub_ring = Color.rgba8(255, 255, 255, 40);

// Chrome-layer machining: gradients and glass for the hand-built
// display-list commands (panel washes, dial shading, needle metal).
pub const transparent = Color.rgba8(0, 0, 0, 0);
pub const bezel_top = Color.rgb8(16, 22, 26);
pub const bezel_bottom = Color.rgb8(9, 13, 16);
pub const dial_top = Color.rgb8(12, 17, 20);
pub const dial_bottom = Color.rgb8(4, 7, 9);
pub const dial_vignette = Color.rgba8(0, 0, 0, 96);
pub const bezel_ring = Color.rgba8(255, 255, 255, 26);
pub const glass_glare = Color.rgba8(255, 255, 255, 17);
pub const needle_edge = Color.rgb8(255, 170, 126);
pub const hub_top = Color.rgb8(46, 58, 65);
pub const hub_bottom = Color.rgb8(10, 14, 17);
pub const cell_shadow = Color.rgba8(0, 0, 0, 150);
pub const cell_glint = Color.rgba8(255, 255, 255, 12);

pub const green = cluster_colors.accent;
pub const amber = cluster_colors.warning;
pub const red = cluster_colors.destructive;
pub const green_dim = Color.rgba8(52, 224, 141, 52);
pub const amber_dim = Color.rgba8(255, 179, 36, 52);
pub const red_dim = Color.rgba8(255, 73, 89, 62);
pub const green_glow = Color.rgba8(52, 224, 141, 46);
pub const red_halo = Color.rgba8(255, 73, 89, 38);

pub const needle = Color.rgb8(255, 110, 64);
pub const needle_glow = Color.rgba8(255, 110, 64, 72);
pub const needle_halo = Color.rgba8(255, 110, 64, 34);

pub const track = Color.rgb8(22, 30, 34);
pub const cell = Color.rgb8(4, 7, 8);
pub const cell_edge = Color.rgba8(255, 255, 255, 14);
pub const hairline = Color.rgba8(255, 255, 255, 14);
