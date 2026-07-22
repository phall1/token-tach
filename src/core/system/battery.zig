//! Battery sampler (macOS, IOKit power sources).
//!
//! Reads the internal battery's description via IOPSCopyPowerSourcesInfo /
//! IOPSCopyPowerSourcesList / IOPSGetPowerSourceDescription: charge level,
//! charging / on-AC flags, and time-to-empty / time-to-full estimates.
//! Machines without a battery (desktops, most VMs) yield null and the UI
//! hides the element entirely — no zeros, no dashes.
//!
//! Runs on the poll cadence (~2 s) for days: both Copy-rule objects (the
//! blob and the list) are released every call. Power-source descriptions
//! follow the Get rule — they belong to the blob and must NOT be released.

const std = @import("std");

const c = @cImport({
    // Apple's mach headers contain _Static_asserts over bitfield structs
    // that translate-c renders as opaque; sizing an opaque type is a
    // compile error, so neutralize the asserts before including.
    @cDefine("_Static_assert(c, m)", " ");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("IOKit/ps/IOPowerSources.h");
    @cInclude("IOKit/ps/IOPSKeys.h");
});

/// One battery reading (first present internal battery).
pub const Sample = struct {
    /// Charge level, 0..1.
    charge: f64,
    /// Actively charging (distinct from merely being on AC — a full
    /// battery on AC is not charging).
    charging: bool,
    /// Drawing from external power.
    on_ac: bool,
    /// Minutes until drained. Only populated while on battery power;
    /// null while the OS is still calculating (-1 in the API).
    minutes_to_empty: ?u32 = null,
    /// Minutes until fully charged. Only populated while charging;
    /// null while the OS is still calculating (-1 in the API).
    minutes_to_full: ?u32 = null,
};

/// No prior counters needed; kept for uniformity with the other samplers.
pub const State = struct {
    pub fn init() State {
        return .{};
    }
};

/// Snapshot the internal battery, or null when none exists / is present.
pub fn sample(state: *State) ?Sample {
    _ = state;
    const info = c.IOPSCopyPowerSourcesInfo();
    if (info == null) return null;
    defer c.CFRelease(info);
    const list = c.IOPSCopyPowerSourcesList(info);
    if (list == null) return null;
    defer c.CFRelease(list);

    const count = c.CFArrayGetCount(list);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const ps = c.CFArrayGetValueAtIndex(list, i);
        // Get rule: the description is owned by `info`; do not release.
        const desc = c.IOPSGetPowerSourceDescription(info, ps);
        if (desc == null) continue;
        if (!dictStringEquals(desc, c.kIOPSTypeKey, c.kIOPSInternalBatteryType)) continue;
        // A battery bay can exist with no battery in it.
        if (dictBool(desc, c.kIOPSIsPresentKey) == false) continue;

        const current = dictInt(desc, c.kIOPSCurrentCapacityKey) orelse continue;
        const max = dictInt(desc, c.kIOPSMaxCapacityKey) orelse continue;
        const charging = dictBool(desc, c.kIOPSIsChargingKey) orelse false;
        const on_ac = dictStringEquals(desc, c.kIOPSPowerSourceStateKey, c.kIOPSACPowerValue);
        return .{
            .charge = chargeFraction(current, max),
            .charging = charging,
            .on_ac = on_ac,
            .minutes_to_empty = if (!on_ac)
                minutesFromApi(dictInt(desc, c.kIOPSTimeToEmptyKey) orelse -1)
            else
                null,
            .minutes_to_full = if (charging)
                minutesFromApi(dictInt(desc, c.kIOPSTimeToFullChargeKey) orelse -1)
            else
                null,
        };
    }
    return null;
}

/// Charge fraction from IOPS capacity readings, clamped to 0..1.
/// Modern macOS reports Current/Max as 0..100 already; older reports use
/// raw mAh — the ratio is correct either way. Unusable max yields 0.
pub fn chargeFraction(current: i64, max: i64) f64 {
    if (max <= 0) return 0;
    const frac = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(max));
    return std.math.clamp(frac, 0, 1);
}

/// Map an IOPS minutes estimate to an optional: the API reports -1 while
/// the OS is still calculating (any negative value means unknown).
pub fn minutesFromApi(minutes: i64) ?u32 {
    if (minutes < 0) return null;
    return @intCast(@min(minutes, std.math.maxInt(u32)));
}

// --------------------------------------------------------- CF plumbing

/// True when `dict[key]` is a CFString equal to `expected`.
fn dictStringEquals(dict: c.CFDictionaryRef, key: [*:0]const u8, expected: [*:0]const u8) bool {
    const value = dictValue(dict, key) orelse return false;
    if (c.CFGetTypeID(value) != c.CFStringGetTypeID()) return false;
    const expected_cf = c.CFStringCreateWithCString(null, expected, c.kCFStringEncodingUTF8);
    if (expected_cf == null) return false;
    defer c.CFRelease(expected_cf);
    return c.CFEqual(value, expected_cf) != 0;
}

fn dictBool(dict: c.CFDictionaryRef, key: [*:0]const u8) ?bool {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return null;
    return c.CFBooleanGetValue(@ptrCast(value)) != 0;
}

fn dictInt(dict: c.CFDictionaryRef, key: [*:0]const u8) ?i64 {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &out) == 0) return null;
    return out;
}

/// Get rule — nothing to release on the returned value.
fn dictValue(dict: c.CFDictionaryRef, key: [*:0]const u8) ?*const anyopaque {
    const cf_key = c.CFStringCreateWithCString(null, key, c.kCFStringEncodingUTF8);
    if (cf_key == null) return null;
    defer c.CFRelease(cf_key);
    return c.CFDictionaryGetValue(dict, cf_key);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "charge fraction: ratio, clamping, and degenerate max" {
    try testing.expectEqual(@as(f64, 0.5), chargeFraction(50, 100));
    try testing.expectEqual(@as(f64, 1), chargeFraction(100, 100));
    try testing.expectEqual(@as(f64, 1), chargeFraction(120, 100)); // over-report
    try testing.expectEqual(@as(f64, 0), chargeFraction(-5, 100));
    try testing.expectEqual(@as(f64, 0), chargeFraction(50, 0));
    try testing.expectEqual(@as(f64, 0), chargeFraction(50, -1));
    // Raw-mAh style readings still ratio correctly.
    try testing.expectEqual(@as(f64, 0.5), chargeFraction(2200, 4400));
}

test "minutes from api: -1 means calculating" {
    try testing.expectEqual(@as(?u32, null), minutesFromApi(-1));
    try testing.expectEqual(@as(?u32, null), minutesFromApi(-99));
    try testing.expectEqual(@as(?u32, 0), minutesFromApi(0));
    try testing.expectEqual(@as(?u32, 137), minutesFromApi(137));
}

test "live: battery sample is coherent when a battery exists" {
    var state = State.init();
    // Null is valid truth: desktops and VMs report no internal battery
    // (this host's registry shows BatteryInstalled = No under
    // AppleSmartBattery even though it is nominally a MacBook Pro).
    const s = sample(&state) orelse return error.SkipZigTest;
    try testing.expect(s.charge >= 0 and s.charge <= 1);
    if (s.minutes_to_empty) |m| try testing.expect(m < 7 * 24 * 60);
    if (s.minutes_to_full) |m| try testing.expect(m < 7 * 24 * 60);
    // Charging implies external power.
    if (s.charging) try testing.expect(s.on_ac);
}
