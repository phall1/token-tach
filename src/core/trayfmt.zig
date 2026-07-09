//! Tray title formatting: the one string the user reads all day.
//! Renders the config's `tray-format` template ("{burn} → {eta}") from a
//! GlanceState. Unknown tokens render verbatim so a typo'd config is
//! visible rather than silent.

const std = @import("std");

/// Everything the glance line can draw from. The app layer assembles this
/// from ledger + predict + limit snapshots each frame.
pub const GlanceState = struct {
    now_ms: i64,
    /// Minutes east of UTC for clock rendering.
    tz_offset_min: i32 = 0,
    burn_tokens_per_min: f64 = 0,
    idle: bool = true,
    /// Projected earliest wall (ms), if any.
    wall_at_ms: ?i64 = null,
    /// Highest current window utilization 0-100, if known.
    hot_percent: ?f64 = null,
    /// Next window reset (ms), if known — shown when idle.
    next_reset_ms: ?i64 = null,
    today_tokens: u64 = 0,
    today_cost_usd: f64 = 0,
};

/// Template tokens:
///   {burn}  "⚡ 4.2k/m" or "idle"
///   {eta}   "wall 3:40p" or "resets 2h14m" (idle) or ""
///   {pct}   "67%" hottest window, or ""
///   {tok}   "8.2M" today's tokens
///   {cost}  "$63.40" today's cost
pub fn render(buf: []u8, template: []const u8, state: GlanceState) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |end| {
                const token = template[i + 1 .. end];
                if (writeToken(&w, token, state)) {
                    i = end + 1;
                    continue;
                } else |_| {
                    // Fall through: unknown token renders verbatim below.
                }
            }
        }
        w.writeByte(template[i]) catch break;
        i += 1;
    }
    return w.buffered();
}

fn writeToken(w: *std.Io.Writer, token: []const u8, state: GlanceState) !void {
    if (std.mem.eql(u8, token, "burn")) {
        if (state.idle) {
            try w.writeAll("idle");
        } else {
            // Fixed-width form: the tray title re-renders every sweep and
            // the menu bar reflows on every width change — "4.2k" jumping
            // to "980" to "12k" makes the whole status area shiver.
            try w.writeAll("⚡ ");
            try writeHumanTokensFixed(w, @intFromFloat(@max(state.burn_tokens_per_min, 0)));
            try w.writeAll("/m");
        }
    } else if (std.mem.eql(u8, token, "eta")) {
        if (!state.idle) {
            if (state.wall_at_ms) |wall| {
                try w.writeAll("wall ");
                try writeClock(w, wall, state.tz_offset_min);
                return;
            }
        }
        if (state.next_reset_ms) |reset| {
            if (reset > state.now_ms) {
                try w.writeAll("resets ");
                try writeCountdown(w, reset - state.now_ms);
                return;
            }
        }
        // No signal: token contributes nothing.
    } else if (std.mem.eql(u8, token, "pct")) {
        if (state.hot_percent) |p| {
            try w.printInt(@as(u64, @intFromFloat(std.math.clamp(p, 0, 100))), 10, .lower, .{});
            try w.writeByte('%');
        }
    } else if (std.mem.eql(u8, token, "tok")) {
        try writeHumanTokens(w, state.today_tokens);
    } else if (std.mem.eql(u8, token, "cost")) {
        try writeCost(w, state.today_cost_usd);
    } else {
        return error.UnknownToken;
    }
}

/// 950 -> "950", 4230 -> "4.2k", 8_230_000 -> "8.2M".
pub fn writeHumanTokens(w: *std.Io.Writer, tokens: u64) !void {
    if (tokens >= 1_000_000) {
        try writeScaled(w, tokens, 1_000_000);
        try w.writeByte('M');
    } else if (tokens >= 1_000) {
        try writeScaled(w, tokens, 1_000);
        try w.writeByte('k');
    } else {
        try w.printInt(tokens, 10, .lower, .{});
    }
}

/// Width-stable variant for the tray burn figure: always one decimal and
/// a k/M unit — "0.9k", "4.2k", "812.3k", "8.2M" — so the rendered width
/// only moves when the burn rate genuinely changes decade, not on every
/// sweep. (writeHumanTokens drops the decimal and the unit situationally,
/// which is right for panels and wrong for a menu-bar title.)
pub fn writeHumanTokensFixed(w: *std.Io.Writer, tokens: u64) !void {
    // 999_950 rounds up to 1000.0k; hand it to the M branch instead.
    if (tokens < 999_950) {
        try writeTenths(w, tokens, 1_000);
        try w.writeByte('k');
    } else {
        try writeTenths(w, tokens, 1_000_000);
        try w.writeByte('M');
    }
}

/// "<whole>.<tenth>" of value/unit, rounded, decimal always present.
fn writeTenths(w: *std.Io.Writer, value: u64, unit: u64) !void {
    const tenths = (value * 10 + unit / 2) / unit;
    try w.printInt(tenths / 10, 10, .lower, .{});
    try w.writeByte('.');
    try w.printInt(tenths % 10, 10, .lower, .{});
}

fn writeScaled(w: *std.Io.Writer, value: u64, unit: u64) !void {
    const tenths = (value * 10 + unit / 2) / unit; // rounded
    const whole = tenths / 10;
    const frac = tenths % 10;
    try w.printInt(whole, 10, .lower, .{});
    if (whole < 100 and frac != 0) {
        try w.writeByte('.');
        try w.printInt(frac, 10, .lower, .{});
    }
}

/// "$63.40"; sub-cent spend shows as "$0.00" until it isn't.
pub fn writeCost(w: *std.Io.Writer, usd: f64) !void {
    const cents: u64 = @intFromFloat(@max(usd, 0) * 100 + 0.5);
    try w.writeByte('$');
    try w.printInt(cents / 100, 10, .lower, .{});
    try w.writeByte('.');
    if (cents % 100 < 10) try w.writeByte('0');
    try w.printInt(cents % 100, 10, .lower, .{});
}

/// Local 12-hour clock: "3:40p", "11:05a".
pub fn writeClock(w: *std.Io.Writer, ts_ms: i64, tz_offset_min: i32) !void {
    const local_ms = ts_ms + @as(i64, tz_offset_min) * 60_000;
    const minutes_of_day: u64 = @intCast(@mod(@divFloor(local_ms, 60_000), 1440));
    const h24 = minutes_of_day / 60;
    const m = minutes_of_day % 60;
    const h12 = if (h24 % 12 == 0) 12 else h24 % 12;
    try w.printInt(h12, 10, .lower, .{});
    try w.writeByte(':');
    if (m < 10) try w.writeByte('0');
    try w.printInt(m, 10, .lower, .{});
    try w.writeByte(if (h24 < 12) 'a' else 'p');
}

/// "2h14m", "45m", "8m".
pub fn writeCountdown(w: *std.Io.Writer, duration_ms: i64) !void {
    const total_min: u64 = @intCast(@max(@divFloor(duration_ms, 60_000), 0));
    const h = total_min / 60;
    const m = total_min % 60;
    if (h > 0) {
        try w.printInt(h, 10, .lower, .{});
        try w.writeByte('h');
    }
    try w.printInt(m, 10, .lower, .{});
    try w.writeByte('m');
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn renderTest(template: []const u8, state: GlanceState) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    return render(&S.buf, template, state);
}

test "active burn with wall renders the hero line" {
    const got = renderTest("{burn} → {eta}", .{
        .now_ms = 0,
        .burn_tokens_per_min = 4200,
        .idle = false,
        // 15:40 UTC
        .wall_at_ms = (15 * 60 + 40) * 60_000,
    });
    try testing.expectEqualStrings("⚡ 4.2k/m → wall 3:40p", got);
}

test "idle renders reset countdown" {
    const got = renderTest("{burn} · {eta}", .{
        .now_ms = 1_000_000,
        .idle = true,
        .next_reset_ms = 1_000_000 + (2 * 60 + 14) * 60_000,
    });
    try testing.expectEqualStrings("idle · resets 2h14m", got);
}

test "pct, tok, cost tokens" {
    const got = renderTest("{pct} {tok} {cost}", .{
        .now_ms = 0,
        .hot_percent = 67.4,
        .today_tokens = 8_230_000,
        .today_cost_usd = 63.401,
    });
    try testing.expectEqualStrings("67% 8.2M $63.40", got);
}

test "unknown token renders verbatim; empty eta collapses" {
    const got = renderTest("{nope} x {eta}", .{ .now_ms = 0, .idle = true });
    try testing.expectEqualStrings("{nope} x ", got);
}

test "fixed-width burn keeps one decimal and a unit at every magnitude" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { v: u64, want: []const u8 }{
        .{ .v = 0, .want = "0.0k" },
        .{ .v = 940, .want = "0.9k" },
        .{ .v = 950, .want = "1.0k" },
        .{ .v = 4_230, .want = "4.2k" },
        .{ .v = 12_400, .want = "12.4k" },
        .{ .v = 812_340, .want = "812.3k" },
        .{ .v = 999_949, .want = "999.9k" },
        .{ .v = 999_950, .want = "1.0M" },
        .{ .v = 8_230_000, .want = "8.2M" },
        .{ .v = 123_449_999, .want = "123.4M" },
    };
    for (cases) |case| {
        var w = std.Io.Writer.fixed(&buf);
        try writeHumanTokensFixed(&w, case.v);
        try testing.expectEqualStrings(case.want, w.buffered());
    }
}

test "tray burn token renders width-stable across sub-k rates" {
    // 900/m used to render "⚡ 900/m" (7 cols) next to "⚡ 4.2k/m" (8);
    // the fixed form pins both to the same shape.
    const low = renderTest("{burn}", .{ .now_ms = 0, .burn_tokens_per_min = 900, .idle = false });
    try testing.expectEqualStrings("⚡ 0.9k/m", low);
    const mid = renderTest("{burn}", .{ .now_ms = 0, .burn_tokens_per_min = 4_200, .idle = false });
    try testing.expectEqualStrings("⚡ 4.2k/m", mid);
    try testing.expectEqual(low.len, mid.len);
}

test "human token scaling" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { v: u64, want: []const u8 }{
        .{ .v = 0, .want = "0" },
        .{ .v = 950, .want = "950" },
        .{ .v = 1_000, .want = "1k" },
        .{ .v = 4_230, .want = "4.2k" },
        .{ .v = 999_950, .want = "1000k" },
        .{ .v = 1_000_000, .want = "1M" },
        .{ .v = 8_230_000, .want = "8.2M" },
        .{ .v = 123_400_000, .want = "123M" },
    };
    for (cases) |case| {
        var w = std.Io.Writer.fixed(&buf);
        try writeHumanTokens(&w, case.v);
        try testing.expectEqualStrings(case.want, w.buffered());
    }
}

test "clock rendering handles noon and midnight" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeClock(&w, 0, 0); // midnight UTC
    try testing.expectEqualStrings("12:00a", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try writeClock(&w, 12 * 3_600_000, 0);
    try testing.expectEqualStrings("12:00p", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try writeClock(&w, 12 * 3_600_000, -300); // UTC noon at UTC-5 = 7:00a
    try testing.expectEqualStrings("7:00a", w.buffered());
}

test "buffer overflow truncates instead of crashing" {
    var tiny: [8]u8 = undefined;
    const got = render(&tiny, "{burn} and much more text", .{ .now_ms = 0, .idle = true });
    try testing.expect(got.len <= tiny.len);
}
