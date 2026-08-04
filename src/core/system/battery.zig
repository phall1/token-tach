//! Battery sampler (macOS, IOKit power sources).
//!
//! Reads the internal battery's description via IOPSCopyPowerSourcesInfo /
//! IOPSCopyPowerSourcesList / IOPSGetPowerSourceDescription: charge level,
//! charging / on-AC flags, and time-to-empty / time-to-full estimates.
//! Machines without a battery (desktops, most VMs) yield null and the UI
//! hides the element entirely — no zeros, no dashes.
//!
//! Runs on the poll cadence for days: both Copy-rule objects (the blob and
//! the list) are released every call. Power-source descriptions follow the
//! Get rule — they belong to the blob and must NOT be released. The key and
//! value strings the lookups need are cached and immortal (see
//! `cachedString`).
//!
//! Charge moves on a ~30 s scale, so the aggregator samples this module on
//! the slow cadence (see system.zig) and carries the last reading forward
//! between refreshes — the power-sources blob is copied out of the kernel,
//! and there is nothing to learn from copying it every second.

const std = @import("std");
const cfcache = @import("../cfcache.zig");

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
        if (!dictStringEquals(desc, .type, .internal_battery_type)) continue;
        // A battery bay can exist with no battery in it.
        if (dictBool(desc, .is_present) == false) continue;

        const current = dictInt(desc, .current_capacity) orelse continue;
        const max = dictInt(desc, .max_capacity) orelse continue;
        const charging = dictBool(desc, .is_charging) orelse false;
        const on_ac = dictStringEquals(desc, .power_source_state, .ac_power_value);
        return .{
            .charge = chargeFraction(current, max),
            .charging = charging,
            .on_ac = on_ac,
            .minutes_to_empty = if (!on_ac)
                minutesFromApi(dictInt(desc, .time_to_empty) orelse -1)
            else
                null,
            .minutes_to_full = if (charging)
                minutesFromApi(dictInt(desc, .time_to_full_charge) orelse -1)
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

/// Every IOPS string this sampler names — dictionary keys and the two
/// values it compares against. An enum with one cache slot per value,
/// rather than a cache keyed on the literal itself — see cfcache.zig for why
/// a `comptime literal` generic silently shares one instantiation across
/// distinct literals and hands back the wrong string.
const Key = enum {
    type,
    internal_battery_type,
    is_present,
    current_capacity,
    max_capacity,
    is_charging,
    power_source_state,
    ac_power_value,
    time_to_empty,
    time_to_full_charge,

    /// `pub` because the shared cache in cfcache.zig calls it; that is the
    /// whole contract a `Key` owes the cache.
    pub fn literal(self: Key) [*:0]const u8 {
        return switch (self) {
            .type => c.kIOPSTypeKey,
            .internal_battery_type => c.kIOPSInternalBatteryType,
            .is_present => c.kIOPSIsPresentKey,
            .current_capacity => c.kIOPSCurrentCapacityKey,
            .max_capacity => c.kIOPSMaxCapacityKey,
            .is_charging => c.kIOPSIsChargingKey,
            .power_source_state => c.kIOPSPowerSourceStateKey,
            .ac_power_value => c.kIOPSACPowerValue,
            .time_to_empty => c.kIOPSTimeToEmptyKey,
            .time_to_full_charge => c.kIOPSTimeToFullChargeKey,
        };
    }
};

/// This sampler's slice of the shared immortal-CFString cache.
///
/// A reading touches up to nine of these, and the old code rebuilt every
/// one of them — allocating and copying — on every tick, forever, on a
/// background thread. The strings are fixed, so each is built at most once
/// and kept.
///
/// OWNERSHIP: the returned reference is deliberately never released, and
/// callers must NEVER `CFRelease` it or attach a `defer` to it. That is what
/// makes reuse safe — nothing else holds a claim on the object, so it cannot
/// be freed out from under the next sample. The cost is one small object per
/// key for the process lifetime.
const key_strings = cfcache.Cache(Key, c.CFStringRef);

/// The immortal CFString for `key`. Never release the result.
const cachedString = key_strings.get;

/// Real `CFStringCreateWithCString` calls made by `cachedString`. One per
/// `Key` for the life of the process; the tests assert it stops growing.
pub fn cfStringCreateCount() usize {
    return key_strings.createCount();
}

/// True when `dict[key]` is a CFString equal to `expected`.
fn dictStringEquals(dict: c.CFDictionaryRef, key: Key, expected: Key) bool {
    const value = dictValue(dict, key) orelse return false;
    if (c.CFGetTypeID(value) != c.CFStringGetTypeID()) return false;
    // Cached comparand: do not release.
    const expected_cf = cachedString(expected) orelse return false;
    return c.CFEqual(value, expected_cf) != 0;
}

fn dictBool(dict: c.CFDictionaryRef, key: Key) ?bool {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return null;
    return c.CFBooleanGetValue(@ptrCast(value)) != 0;
}

fn dictInt(dict: c.CFDictionaryRef, key: Key) ?i64 {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &out) == 0) return null;
    return out;
}

/// Get rule — nothing to release on the returned value, and the cached key
/// is not ours to release either.
fn dictValue(dict: c.CFDictionaryRef, key: Key) ?*const anyopaque {
    const cf_key = cachedString(key) orelse return null;
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

test "cached IOPS strings: one per key, built once, never re-created" {
    // Prime every key, then assert the cache is closed: same pointers, no
    // further allocations, and no two keys sharing a slot.
    var seen: [@typeInfo(Key).@"enum".fields.len]c.CFStringRef = undefined;
    for (std.enums.values(Key), 0..) |key, i| {
        seen[i] = cachedString(key) orelse return error.NoCfString;
        try testing.expect(c.CFStringGetLength(seen[i]) == @as(c.CFIndex, @intCast(std.mem.len(key.literal()))));
        for (seen[0..i]) |prior| try testing.expect(prior != seen[i]);
    }

    const after_priming = cfStringCreateCount();
    for (0..100) |_| {
        for (std.enums.values(Key), 0..) |key, i| {
            try testing.expectEqual(seen[i], cachedString(key) orelse return error.NoCfString);
        }
    }
    // A hundred more sweeps' worth of lookups, zero more CFStrings.
    try testing.expectEqual(after_priming, cfStringCreateCount());
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
