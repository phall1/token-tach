//! Civil-date and ISO8601 arithmetic, shared by the collectors.
//!
//! Two independent ISO8601 parsers grew here — one in claude.zig for the
//! shape Claude Code logs, one in codex.zig for the shape Codex logs — and
//! they had independently written out the same `daysFromCivil`, character
//! for character. Three more adapters (pi, gemini, qwen) each imported the
//! whole 64 KB claude.zig module for the single function.
//!
//! No libc, no `std.time` calendar helpers: the collectors run over months
//! of transcripts at startup, and these are pure integer arithmetic on
//! bytes already in memory.

const std = @import("std");

/// Parse an ISO8601 timestamp of the shape Claude Code logs
/// ("2026-07-08T02:57:59.430Z") into unix milliseconds. Fractional seconds
/// are optional and of any length (truncated to ms); the zone must be 'Z' or
/// a numeric offset (+HH:MM / +HHMM). Returns null on anything malformed.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    const year = fixedDigits(s[0..4]) orelse return null;
    if (s[4] != '-') return null;
    const month = fixedDigits(s[5..7]) orelse return null;
    if (s[7] != '-') return null;
    const day = fixedDigits(s[8..10]) orelse return null;
    if (s[10] != 'T') return null;
    const hour = fixedDigits(s[11..13]) orelse return null;
    if (s[13] != ':') return null;
    const minute = fixedDigits(s[14..16]) orelse return null;
    if (s[16] != ':') return null;
    const second = fixedDigits(s[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') idx += 1;
        if (idx == frac_start) return null;
        var scale: i64 = 100;
        var i = frac_start;
        while (i < idx and i < frac_start + 3) : (i += 1) {
            millis += scale * (s[i] - '0');
            scale = @divTrunc(scale, 10);
        }
    }

    if (idx >= s.len) return null;
    var tz_offset_min: i64 = 0;
    switch (s[idx]) {
        'Z' => if (idx + 1 != s.len) return null,
        '+', '-' => {
            const sign: i64 = if (s[idx] == '-') -1 else 1;
            const rest = s[idx + 1 ..];
            var off_hour: i64 = 0;
            var off_min: i64 = 0;
            if (rest.len == 5 and rest[2] == ':') {
                off_hour = fixedDigits(rest[0..2]) orelse return null;
                off_min = fixedDigits(rest[3..5]) orelse return null;
            } else if (rest.len == 4) {
                off_hour = fixedDigits(rest[0..2]) orelse return null;
                off_min = fixedDigits(rest[2..4]) orelse return null;
            } else return null;
            if (off_hour > 23 or off_min > 59) return null;
            tz_offset_min = sign * (off_hour * 60 + off_min);
        },
        else => return null,
    }

    const days = daysFromCivil(year, month, day);
    const secs = ((days * 24 + hour) * 60 + minute - tz_offset_min) * 60 + second;
    return secs * 1000 + millis;
}

/// Strict fixed-width decimal (rejects signs, spaces, underscores).
fn fixedDigits(s: []const u8) ?i64 {
    var value: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(i64, 29) else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(month + 9, 12); // Mar=0 ... Feb=11
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const testing = std.testing;

test "parseTimestamp handles epoch, fractions, offsets, and leap days" {
    try testing.expectEqual(@as(?i64, 0), parseTimestamp("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1), parseTimestamp("1970-01-01T00:00:00.001Z"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.430Z"));
    // Short and long fractions normalize to milliseconds.
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.43Z"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T02:57:59.430999Z"));
    try testing.expectEqual(@as(?i64, 1783479479000), parseTimestamp("2026-07-08T02:57:59Z"));
    // Leap day and end-of-millennium.
    try testing.expectEqual(@as(?i64, 951825600000), parseTimestamp("2000-02-29T12:00:00Z"));
    try testing.expectEqual(@as(?i64, 946684799999), parseTimestamp("1999-12-31T23:59:59.999Z"));
    // Numeric zone offsets, both separators.
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T04:57:59.430+02:00"));
    try testing.expectEqual(@as(?i64, 1783479479430), parseTimestamp("2026-07-08T00:57:59.430-0200"));
}

test "parseTimestamp rejects malformed input" {
    const bad = [_][]const u8{
        "",
        "2026-07-08",
        "2026-07-08T02:57:59.430", // no zone designator
        "2026-07-08T02:57:59.Z", // dot with no digits
        "2026-13-01T00:00:00Z", // month out of range
        "2026-02-30T00:00:00Z", // day out of range
        "2026-07-08T24:00:00Z", // hour out of range
        "2026-07-08 02:57:59Z", // space separator
        "2026-07-08T02:57:59+2:00", // malformed offset
        "2026-07-08T02:57:59Zjunk", // trailing garbage
        "not a timestamp, not even close",
    };
    for (bad) |s| {
        try testing.expectEqual(@as(?i64, null), parseTimestamp(s));
    }
}
