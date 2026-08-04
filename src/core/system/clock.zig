//! Monotonic clock shared by the system samplers.
//!
//! `mach_absolute_time` counts board ticks, not nanoseconds (Apple Silicon
//! runs it at 24 MHz), so every reading has to be scaled by the ratio
//! `mach_timebase_info` reports. That ratio is fixed at boot — but the
//! samplers used to re-query it on every reading, and the producer thread
//! takes a reading per module per second, forever. Probing a boot constant
//! 86,400 times a day per sampler is pure waste, so it is probed once per
//! process and cached here.
//!
//! Living in one module rather than on each sampler's `State` is deliberate:
//! the app runs two `Sampler`s (the producer thread's and the loop thread's
//! fallback), and the timebase is a property of the machine, not of a
//! sampler — one probe for the process is strictly fewer than one per state.
//! It also collapses three hand-rolled copies of these declarations into one.

const std = @import("std");

// <mach/mach_time.h> declarations, hand-rolled: the header drags in
// mach_msg types that translate-c cannot size. These are stable libSystem
// symbols with fixed ABI.
const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;
extern "c" fn mach_absolute_time() u64;

/// Cached timebase, packed `numer << 32 | denom`; 0 means "not probed yet"
/// (a real timebase has both halves non-zero, so 0 is an unambiguous
/// sentinel).
///
/// Relaxed atomics rather than a plain `var`: the producer thread and the
/// loop-thread fallback sampler can both land here, and a torn read would
/// mis-scale every rate in the UI. No lock is needed beyond that — the
/// probe is idempotent, so the worst a race can cost is one redundant
/// syscall while both threads write the same value.
var cached_timebase: std.atomic.Value(u64) = .init(0);

/// How many times the kernel was actually asked for the timebase. The
/// whole point of the cache is that this stops at 1; tests assert it.
var probe_count: std.atomic.Value(u32) = .init(0);

/// Monotonic nanoseconds since boot. Null only if the timebase query
/// fails, which on a real Mac it does not.
pub fn monotonicNs() ?u64 {
    const info = timebase() orelse return null;
    return ticksToNs(mach_absolute_time(), info.numer, info.denom);
}

/// Number of real `mach_timebase_info` calls made so far — 1 for the life
/// of a healthy process. Exposed so the caching invariant is testable
/// without hardware.
pub fn timebaseProbeCount() u32 {
    return probe_count.load(.monotonic);
}

/// Scale raw mach ticks to nanoseconds. Widened to u128 first: on a Mac
/// that has been up for months `ticks * numer` overflows u64 well before
/// the division brings it back down.
pub fn ticksToNs(ticks: u64, numer: u32, denom: u32) ?u64 {
    if (numer == 0 or denom == 0) return null;
    const scaled = @as(u128, ticks) * numer / denom;
    return std.math.cast(u64, scaled);
}

fn timebase() ?MachTimebaseInfo {
    const cached = cached_timebase.load(.monotonic);
    if (cached != 0) return .{
        .numer = @intCast(cached >> 32),
        .denom = @truncate(cached),
    };

    var info: MachTimebaseInfo = .{ .numer = 0, .denom = 0 };
    _ = probe_count.fetchAdd(1, .monotonic);
    if (mach_timebase_info(&info) != 0 or info.numer == 0 or info.denom == 0) return null;
    cached_timebase.store(@as(u64, info.numer) << 32 | info.denom, .monotonic);
    return info;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "ticks to ns: applies the timebase ratio and rejects a degenerate one" {
    // Apple Silicon's 125/3 ratio: 24 MHz ticks -> nanoseconds.
    try testing.expectEqual(@as(?u64, 1_000_000_000), ticksToNs(24_000_000, 125, 3));
    // Intel's identity timebase.
    try testing.expectEqual(@as(?u64, 12345), ticksToNs(12345, 1, 1));
    try testing.expectEqual(@as(?u64, null), ticksToNs(1, 1, 0));
    try testing.expectEqual(@as(?u64, null), ticksToNs(1, 0, 1));
}

test "ticks to ns: months of uptime do not overflow the multiply" {
    // ~90 days of 24 MHz ticks; ticks * numer exceeds u64 at this scale.
    const ticks: u64 = 90 * 24 * 60 * 60 * 24_000_000;
    const ns = ticksToNs(ticks, 125, 3) orelse return error.NoTimebase;
    try testing.expectEqual(@as(u64, 90 * 24 * 60 * 60 * 1_000_000_000), ns);
}

test "timebase is probed once no matter how many readings are taken" {
    _ = monotonicNs() orelse return error.NoTimebase;
    const after_first = timebaseProbeCount();
    try testing.expect(after_first >= 1);

    var prev: u64 = 0;
    for (0..1000) |_| {
        const now = monotonicNs() orelse return error.NoTimebase;
        // Monotonic in the literal sense: never runs backwards.
        try testing.expect(now >= prev);
        prev = now;
    }
    // A thousand more readings, zero more syscalls.
    try testing.expectEqual(after_first, timebaseProbeCount());
}
