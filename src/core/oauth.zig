//! Claude server-truth limits: client logic for the undocumented OAuth
//! usage endpoint. This file is transport-free — response parsing, backoff,
//! and staleness are pure and unit-tested; the actual HTTP call and the
//! Keychain read live in the app layer and inject bytes here.
//!
//! Endpoint contract (verified 2026-07-09, see PLAN.md):
//!   GET https://api.anthropic.com/api/oauth/usage
//!   Authorization: Bearer <claudeAiOauth.accessToken>
//!   anthropic-beta: oauth-2025-04-20
//!   User-Agent: claude-code/<version>   <- mandatory; wrong UA => sticky 429s

const std = @import("std");
const types = @import("types.zig");

pub const endpoint_url = "https://api.anthropic.com/api/oauth/usage";
pub const beta_header = "oauth-2025-04-20";
/// Impersonated client version for the User-Agent header. Keep plausibly
/// current; the endpoint 429s unknown agents.
pub const user_agent = "claude-code/2.1.205";

/// Poll cadence and staleness thresholds (ms).
pub const poll_interval_ms: i64 = 180_000;
pub const stale_after_ms: i64 = 300_000;

/// Credentials as stored in the macOS Keychain item
/// service="Claude Code-credentials" (JSON payload).
pub const Credentials = struct {
    access_token: []const u8,
    /// Unix ms; access token is short-lived (~60 min).
    expires_at_ms: i64,
    subscription_type: []const u8,

    pub fn expired(self: Credentials, now_ms: i64) bool {
        return now_ms >= self.expires_at_ms;
    }
};

/// Parse the Keychain JSON payload. Strings are duped with `allocator`.
pub fn parseCredentials(allocator: std.mem.Allocator, json: []const u8) !Credentials {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const oauth = parsed.value.object.get("claudeAiOauth") orelse return error.MissingOauth;
    if (oauth != .object) return error.MissingOauth;
    const token = oauth.object.get("accessToken") orelse return error.MissingToken;
    if (token != .string) return error.MissingToken;
    const expires: i64 = switch (oauth.object.get("expiresAt") orelse std.json.Value{ .integer = 0 }) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => 0,
    };
    const sub: []const u8 = switch (oauth.object.get("subscriptionType") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    return .{
        .access_token = try allocator.dupe(u8, token.string),
        .expires_at_ms = expires,
        .subscription_type = try allocator.dupe(u8, sub),
    };
}

/// Parse a usage-endpoint response body into a LimitSnapshot.
/// Windows with null bodies are omitted. Strings duped with `allocator`.
pub fn parseUsageResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
    now_ms: i64,
    plan: []const u8,
) !types.LimitSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const root = parsed.value.object;

    var windows: std.ArrayList(types.LimitWindow) = .empty;
    const mappings = [_]struct { key: []const u8, kind: types.LimitWindow.Kind }{
        .{ .key = "five_hour", .kind = .five_hour },
        .{ .key = "seven_day", .kind = .weekly },
        .{ .key = "seven_day_opus", .kind = .weekly_opus },
        .{ .key = "seven_day_sonnet", .kind = .weekly_sonnet },
    };
    for (mappings) |m| {
        const entry = root.get(m.key) orelse continue;
        if (entry != .object) continue; // null / absent windows
        const util: f64 = switch (entry.object.get("utilization") orelse continue) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            else => continue,
        };
        const resets_ms: i64 = blk: {
            const raw = entry.object.get("resets_at") orelse break :blk 0;
            if (raw != .string) break :blk 0;
            break :blk parseIso8601Ms(raw.string) orelse 0;
        };
        try windows.append(allocator, .{
            .kind = m.kind,
            .used_percent = util,
            .resets_at_ms = resets_ms,
        });
    }

    return .{
        .agent = .claude,
        .read_at_ms = now_ms,
        .plan = try allocator.dupe(u8, plan),
        .windows = try windows.toOwnedSlice(allocator),
    };
}

/// Exponential backoff for 429s: 3 -> 6 -> 12 -> 15 (cap) minutes,
/// reset on success. Values in ms.
pub const Backoff = struct {
    consecutive_failures: u32 = 0,

    const base_ms: i64 = 180_000;
    const cap_ms: i64 = 900_000;

    pub fn onFailure(self: *Backoff) void {
        self.consecutive_failures +|= 1;
    }

    pub fn onSuccess(self: *Backoff) void {
        self.consecutive_failures = 0;
    }

    /// Delay to wait before the next attempt.
    pub fn delayMs(self: Backoff) i64 {
        if (self.consecutive_failures == 0) return poll_interval_ms;
        const shift: u6 = @intCast(@min(self.consecutive_failures - 1, 8));
        const scaled = base_ms * (@as(i64, 1) << shift);
        return @min(scaled, cap_ms);
    }
};

/// Freshness tracking for the last good reading.
pub fn isStale(last_success_ms: i64, now_ms: i64) bool {
    if (last_success_ms == 0) return true;
    return now_ms - last_success_ms > stale_after_ms;
}

/// Parse ISO8601 / RFC3339 ("2026-04-11T07:00:00+00:00", trailing 'Z',
/// optional fractional seconds) to unix milliseconds. Null on any malformed
/// input — limit timestamps are decorative, never load-bearing enough to
/// crash over.
pub fn parseIso8601Ms(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < s.len and std.ascii.isDigit(s[idx])) idx += 1;
        const frac = s[frac_start..idx];
        if (frac.len == 0) return null;
        const digits = @min(frac.len, 3);
        millis = std.fmt.parseInt(i64, frac[0..digits], 10) catch return null;
        var d = digits;
        while (d < 3) : (d += 1) millis *= 10;
    }

    var offset_minutes: i64 = 0;
    if (idx < s.len) {
        switch (s[idx]) {
            'Z', 'z' => {},
            '+', '-' => {
                const sign: i64 = if (s[idx] == '-') -1 else 1;
                if (idx + 6 > s.len or s[idx + 3] != ':') return null;
                const oh = std.fmt.parseInt(i64, s[idx + 1 .. idx + 3], 10) catch return null;
                const om = std.fmt.parseInt(i64, s[idx + 4 .. idx + 6], 10) catch return null;
                offset_minutes = sign * (oh * 60 + om);
            },
            else => return null,
        }
    }

    const days = daysFromCivil(year, month, day);
    const secs = days * 86_400 + @as(i64, hour) * 3_600 + @as(i64, minute) * 60 + second - offset_minutes * 60;
    return secs * 1_000 + millis;
}

/// Howard Hinnant's days_from_civil: civil date -> days since 1970-01-01.
fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, m) + 9, 12); // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "parseUsageResponse maps windows and skips nulls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"five_hour":{"utilization":33.0,"resets_at":"2026-04-11T07:00:00+00:00"},
        \\ "seven_day":{"utilization":13.0,"resets_at":"2026-04-17T00:59:59+00:00"},
        \\ "seven_day_opus":null,
        \\ "seven_day_sonnet":{"utilization":1.0,"resets_at":"2026-04-16T03:00:00+00:00"},
        \\ "extra_usage":{"is_enabled":false}}
    ;
    const snap = try parseUsageResponse(arena, body, 1_000, "max");
    try testing.expectEqual(@as(usize, 3), snap.windows.len);
    try testing.expectEqual(types.LimitWindow.Kind.five_hour, snap.windows[0].kind);
    try testing.expectEqual(@as(f64, 33.0), snap.windows[0].used_percent);
    try testing.expectEqual(types.LimitWindow.Kind.weekly, snap.windows[1].kind);
    try testing.expectEqual(types.LimitWindow.Kind.weekly_sonnet, snap.windows[2].kind);
    try testing.expectEqualStrings("max", snap.plan);
    // 2026-04-11T07:00:00Z sanity: divisible by 1000, in 2026.
    try testing.expect(@mod(snap.windows[0].resets_at_ms, 1000) == 0);
    try testing.expect(snap.windows[0].resets_at_ms > 1_770_000_000_000);
}

test "parseCredentials extracts token, expiry, plan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"claudeAiOauth":{"accessToken":"sk-test-123","refreshToken":"rt",
        \\ "expiresAt":1783600000000,"scopes":["user:inference"],
        \\ "subscriptionType":"max","rateLimitTier":"t2"}}
    ;
    const creds = try parseCredentials(arena, json);
    try testing.expectEqualStrings("sk-test-123", creds.access_token);
    try testing.expectEqual(@as(i64, 1_783_600_000_000), creds.expires_at_ms);
    try testing.expectEqualStrings("max", creds.subscription_type);
    try testing.expect(creds.expired(1_783_600_000_001));
    try testing.expect(!creds.expired(1_783_599_999_999));
}

test "backoff ladder: 3, 6, 12, 15-cap minutes, resets on success" {
    var b = Backoff{};
    try testing.expectEqual(poll_interval_ms, b.delayMs());
    b.onFailure();
    try testing.expectEqual(@as(i64, 180_000), b.delayMs());
    b.onFailure();
    try testing.expectEqual(@as(i64, 360_000), b.delayMs());
    b.onFailure();
    try testing.expectEqual(@as(i64, 720_000), b.delayMs());
    b.onFailure();
    try testing.expectEqual(@as(i64, 900_000), b.delayMs());
    b.onFailure();
    try testing.expectEqual(@as(i64, 900_000), b.delayMs());
    b.onSuccess();
    try testing.expectEqual(poll_interval_ms, b.delayMs());
}

test "staleness" {
    try testing.expect(isStale(0, 1));
    try testing.expect(!isStale(1_000, 300_999));
    try testing.expect(isStale(1_000, 302_000));
}

test "parseIso8601Ms known values and malformed input" {
    // 1970-01-01T00:00:00Z == 0
    try testing.expectEqual(@as(i64, 0), parseIso8601Ms("1970-01-01T00:00:00Z").?);
    // 2000-01-01T00:00:00Z == 946684800s
    try testing.expectEqual(@as(i64, 946_684_800_000), parseIso8601Ms("2000-01-01T00:00:00Z").?);
    // fractional + Z
    try testing.expectEqual(@as(i64, 946_684_800_430), parseIso8601Ms("2000-01-01T00:00:00.430Z").?);
    // +02:00 offset shifts back two hours
    try testing.expectEqual(@as(i64, 946_684_800_000 - 7_200_000), parseIso8601Ms("2000-01-01T00:00:00+02:00").?);
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("not a date"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("2000-13-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms(""));
}
