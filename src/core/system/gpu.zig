//! GPU utilization sampler (macOS, IOKit registry).
//!
//! Reads the `PerformanceStatistics` dictionary that IOAccelerator services
//! (the AGX driver on Apple Silicon) publish in the IO registry:
//! `Device Utilization %`, `Renderer Utilization %`, `In use system memory`.
//! Point-in-time gauges — no prior-counter state is needed, but `State`
//! keeps the shared sampler shape.
//!
//! Runs on the poll cadence for days: every CF object and io_object created
//! here is released before return. Two deliberate non-releases: the
//! IOServiceMatching dictionary (IOServiceGetMatchingServices consumes that
//! reference, even on failure) and the cached key strings (see
//! `cachedString` — they are immortal by design).
//!
//! Because copying a service's property dictionary out of the kernel is the
//! expensive part, the aggregator samples this module on the slow cadence
//! (see system.zig) and carries the last reading forward between refreshes.

const std = @import("std");
const cfcache = @import("../cfcache.zig");

const c = @cImport({
    // Apple's mach headers contain _Static_asserts over bitfield structs
    // that translate-c renders as opaque; sizing an opaque type is a
    // compile error, so neutralize the asserts before including.
    @cDefine("_Static_assert(c, m)", " ");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("IOKit/IOKitLib.h");
});

/// One GPU reading. With multiple accelerators, the busiest one wins.
pub const Sample = struct {
    /// `Device Utilization %` as a 0..1 fraction.
    device_utilization: f64,
    /// `Renderer Utilization %` as a 0..1 fraction, when the driver
    /// reports it.
    renderer_utilization: ?f64 = null,
    /// `In use system memory` in bytes (unified-memory GPUs), when present.
    in_use_memory_bytes: ?u64 = null,
};

/// No prior counters needed; kept for uniformity with the other samplers.
pub const State = struct {
    pub fn init() State {
        return .{};
    }
};

/// Snapshot GPU utilization, or null when no accelerator publishes a
/// `Device Utilization %` (headless VMs, exotic drivers) — the UI hides
/// the element rather than showing zeros.
pub fn sample(state: *State) ?Sample {
    _ = state;
    const matching = c.IOServiceMatching("IOAccelerator");
    if (matching == null) return null;
    var iter: c.io_iterator_t = 0;
    // Port 0 == kIOMainPortDefault ("look up the default main port").
    // The matching dictionary reference is consumed by this call.
    if (c.IOServiceGetMatchingServices(0, matching, &iter) != c.KERN_SUCCESS) return null;
    defer _ = c.IOObjectRelease(iter);

    var best: ?Sample = null;
    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const stats = copyPerformanceStatistics(service);
        if (stats == null) continue;
        defer c.CFRelease(stats);

        const device_pct = dictNumberF64(stats, .device_utilization) orelse continue;
        const candidate = Sample{
            .device_utilization = percentToFraction(device_pct),
            .renderer_utilization = if (dictNumberF64(stats, .renderer_utilization)) |pct|
                percentToFraction(pct)
            else
                null,
            .in_use_memory_bytes = dictNumberU64(stats, .in_use_memory),
        };
        if (best == null or candidate.device_utilization > best.?.device_utilization) {
            best = candidate;
        }
    }
    return best;
}

/// Clamp a driver-reported percentage to a 0..1 fraction. Drivers
/// occasionally report transient values a hair outside 0..100.
pub fn percentToFraction(percent: f64) f64 {
    return std.math.clamp(percent, 0, 100) / 100.0;
}

// --------------------------------------------------------- CF plumbing

/// Every registry key this sampler names. An enum with one cache slot per
/// value, rather than a cache keyed on the literal itself — see cfcache.zig
/// for why a `comptime literal` generic silently shares one instantiation
/// across distinct literals and hands back the wrong string.
const Key = enum {
    performance_statistics,
    device_utilization,
    renderer_utilization,
    in_use_memory,

    /// `pub` because the shared cache in cfcache.zig calls it; that is the
    /// whole contract a `Key` owes the cache.
    pub fn literal(self: Key) [*:0]const u8 {
        return switch (self) {
            .performance_statistics => "PerformanceStatistics",
            .device_utilization => "Device Utilization %",
            .renderer_utilization => "Renderer Utilization %",
            .in_use_memory => "In use system memory",
        };
    }
};

/// This sampler's slice of the shared immortal-CFString cache.
///
/// Creating a CFString allocates and copies, and the old code paid for four
/// of them per reading — one for the property name, one per dictionary
/// lookup — forever, on a background thread. The keys are fixed, so each is
/// built at most once and kept.
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
/// distinct key for the life of the process; the tests assert it stops
/// growing.
pub fn cfStringCreateCount() usize {
    return key_strings.createCount();
}

/// Copy the service's `PerformanceStatistics` dictionary. Caller owns the
/// returned reference (Create rule) and must CFRelease a non-null result.
fn copyPerformanceStatistics(service: c.io_registry_entry_t) c.CFDictionaryRef {
    // Cached key: do not release.
    const key = cachedString(.performance_statistics);
    if (key == null) return null;
    const props = c.IORegistryEntryCreateCFProperty(service, key, null, 0);
    if (props == null) return null;
    if (c.CFGetTypeID(props) != c.CFDictionaryGetTypeID()) {
        c.CFRelease(props);
        return null;
    }
    return @ptrCast(props);
}

/// Look up `key` in `dict` (Get rule — nothing to release on the value)
/// and coerce a CFNumber to f64. Null when absent or not a number.
fn dictNumberF64(dict: c.CFDictionaryRef, key: Key) ?f64 {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;
    var out: f64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberFloat64Type, &out) == 0) return null;
    return out;
}

/// As dictNumberF64, but for non-negative integer quantities (bytes).
fn dictNumberU64(dict: c.CFDictionaryRef, key: Key) ?u64 {
    const value = dictValue(dict, key) orelse return null;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &out) == 0) return null;
    if (out < 0) return null;
    return @intCast(out);
}

fn dictValue(dict: c.CFDictionaryRef, key: Key) ?*const anyopaque {
    // Cached key: Get rule on the way out, and no release on the key.
    const cf_key = cachedString(key) orelse return null;
    return c.CFDictionaryGetValue(dict, cf_key);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "percent to fraction: nominal, clamped, and edge values" {
    try testing.expectEqual(@as(f64, 0.12), percentToFraction(12));
    try testing.expectEqual(@as(f64, 0), percentToFraction(0));
    try testing.expectEqual(@as(f64, 1), percentToFraction(100));
    try testing.expectEqual(@as(f64, 0), percentToFraction(-3));
    try testing.expectEqual(@as(f64, 1), percentToFraction(250));
}

test "cached key strings: created once, then handed back identically" {
    const first = cachedString(.device_utilization) orelse return error.NoCfString;
    const after_first = cfStringCreateCount();
    for (0..1000) |_| {
        const again = cachedString(.device_utilization) orelse return error.NoCfString;
        try testing.expectEqual(first, again);
    }
    // A thousand more lookups, zero more CFString allocations.
    try testing.expectEqual(after_first, cfStringCreateCount());

    // Every key gets its own slot: no two share a cached string, and the
    // cached string really is the key it claims to be.
    var seen: [@typeInfo(Key).@"enum".fields.len]c.CFStringRef = undefined;
    for (std.enums.values(Key), 0..) |key, i| {
        seen[i] = cachedString(key) orelse return error.NoCfString;
        try testing.expect(c.CFStringGetLength(seen[i]) == @as(c.CFIndex, @intCast(std.mem.len(key.literal()))));
        for (seen[0..i]) |prior| try testing.expect(prior != seen[i]);
    }
}

test "live: accelerator sample stays in range" {
    var state = State.init();
    const s = sample(&state) orelse {
        // An accelerator without PerformanceStatistics (or none at all) is
        // a valid null — but on Apple Silicon dev machines it should exist.
        return error.SkipZigTest;
    };
    try testing.expect(s.device_utilization >= 0 and s.device_utilization <= 1);
    if (s.renderer_utilization) |r| {
        try testing.expect(r >= 0 and r <= 1);
    }
    if (s.in_use_memory_bytes) |bytes| {
        // Sanity ceiling: 1 TiB of in-use GPU memory means we misread.
        try testing.expect(bytes < 1 << 40);
    }
}
