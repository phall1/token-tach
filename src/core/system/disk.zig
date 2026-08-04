//! Disk sampler: root-volume capacity plus whole-machine I/O throughput.
//!
//! Two independent sources, deliberately:
//! - Capacity comes from `statfs("/")`. `f_bavail` (user-available blocks)
//!   is what Finder and `df -h` report as free; `f_bfree` includes blocks
//!   reserved for root and would overstate what the user can actually use.
//! - Throughput comes from IOKit: every `IOBlockStorageDriver` service
//!   publishes a `Statistics` dictionary with lifetime byte counters.
//!   Summing "Bytes (Read)" / "Bytes (Write)" across all drivers and
//!   differencing consecutive sums against a monotonic clock yields
//!   machine-wide read/write bytes per second.
//!
//! The first call after `init()` returns capacity but `null` rates — there
//! is no prior counter pair to difference yet. Callers render rates only
//! when present (no zeros, no dashes).
//!
//! The two halves move on wildly different scales, so they are separately
//! callable: `sampleIo` must run every tick (a rate is only as good as its
//! interval) while `sampleCapacity` is a `statfs` of a number that changes
//! on an hourly scale and runs on the aggregator's slow cadence. `sample`
//! does both, for callers that just want a reading.
//!
//! This runs on the poll cadence for days: every CF and IOKit object created
//! here is released before returning, except the cached statistics keys,
//! which are immortal by design (see `cachedString`).

const std = @import("std");
const clock = @import("clock.zig");
const c = @cImport({
    // IOKitLib.h pulls in <mach/message.h>, whose packed unions translate-c
    // renders opaque; the header's _Static_asserts on their sizes then fail
    // at Zig compile time. Masking the keyword with a benign macro drops the
    // asserts (they check the C ABI, which we do not re-declare) while
    // leaving every type we actually use intact.
    @cDefine("_Static_assert(cond, msg)", "extern int _zig_static_assert_disabled");
    @cInclude("sys/mount.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/storage/IOBlockStorageDriver.h");
});

/// One disk observation. Capacity fields are always valid; rate fields are
/// null until a second sample provides a delta baseline.
pub const Sample = struct {
    /// Total size of the root volume, bytes.
    total_bytes: u64,
    /// Bytes available to the user on the root volume (statfs f_bavail).
    free_bytes: u64,
    /// Used fraction 0..1, df-style: used / (used + user-available).
    used_fraction: f64,
    /// Machine-wide read throughput, bytes/sec. Null on the first sample
    /// or when IOKit statistics are unavailable.
    read_bytes_per_sec: ?f64 = null,
    /// Machine-wide write throughput, bytes/sec. Null like above.
    write_bytes_per_sec: ?f64 = null,
};

/// Prior counters + monotonic timestamp for rate derivation.
pub const State = struct {
    prev_read_bytes: u64 = 0,
    prev_write_bytes: u64 = 0,
    /// mach_absolute_time converted to nanoseconds at the previous sample.
    prev_ns: u64 = 0,
    has_prev: bool = false,
};

pub fn init() State {
    return .{};
}

/// Root-volume capacity, the slow-moving half of a reading.
pub const Capacity = struct {
    total_bytes: u64,
    free_bytes: u64,
    used_fraction: f64,
};

/// Machine-wide throughput, the fast-moving half.
pub const IoRates = struct {
    read_bytes_per_sec: f64,
    write_bytes_per_sec: f64,
};

/// Take one sample: capacity plus, once a baseline exists, I/O rates.
/// Returns null only when `statfs("/")` itself fails (capacity is the
/// load-bearing half); IOKit trouble degrades to null rates instead.
pub fn sample(state: *State) ?Sample {
    const cap = sampleCapacity() orelse return null;
    const io = sampleIo(state);
    return .{
        .total_bytes = cap.total_bytes,
        .free_bytes = cap.free_bytes,
        .used_fraction = cap.used_fraction,
        .read_bytes_per_sec = if (io) |r| r.read_bytes_per_sec else null,
        .write_bytes_per_sec = if (io) |r| r.write_bytes_per_sec else null,
    };
}

/// Root-volume capacity via a single `statfs("/")`. Null when that fails.
/// Split out so the aggregator can ask for it on a slow cadence — a disk
/// does not change size between two ticks of a 1 Hz clock.
pub fn sampleCapacity() ?Capacity {
    var st: c.struct_statfs = undefined;
    if (c.statfs("/", &st) != 0) return null;

    const bsize: u64 = st.f_bsize;
    const avail = st.f_bavail * bsize;
    const used = (st.f_blocks -| st.f_bfree) * bsize;
    return .{
        .total_bytes = st.f_blocks * bsize,
        .free_bytes = avail,
        .used_fraction = usedFraction(used, avail),
    };
}

/// Advance the I/O counter baseline and return the rates over the interval
/// since the previous call. Null on the first call (nothing to difference)
/// or when IOKit statistics are unavailable.
///
/// Must be called every tick even when the caller ignores the result: the
/// rate is measured against the time between calls, so skipping one widens
/// the window and smears the reading.
pub fn sampleIo(state: *State) ?IoRates {
    const totals = readIoTotals() orelse return null;
    const now_ns = clock.monotonicNs() orelse return null;

    var out: ?IoRates = null;
    if (state.has_prev and now_ns > state.prev_ns) {
        const elapsed = now_ns - state.prev_ns;
        out = .{
            .read_bytes_per_sec = rateBytesPerSec(state.prev_read_bytes, totals.read, elapsed),
            .write_bytes_per_sec = rateBytesPerSec(state.prev_write_bytes, totals.write, elapsed),
        };
    }
    state.prev_read_bytes = totals.read;
    state.prev_write_bytes = totals.write;
    state.prev_ns = now_ns;
    state.has_prev = true;
    return out;
}

// ---------------------------------------------------------- pure helpers

/// Counter pair + elapsed nanoseconds -> bytes/sec. A counter that went
/// backwards (drive detached mid-interval, driver reset) clamps the delta
/// to 0 rather than producing a huge bogus rate; zero elapsed yields 0.
pub fn rateBytesPerSec(prev: u64, cur: u64, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    const delta: u64 = if (cur >= prev) cur - prev else 0;
    return @as(f64, @floatFromInt(delta)) * std.time.ns_per_s /
        @as(f64, @floatFromInt(elapsed_ns));
}

/// df-style used fraction: used / (used + available-to-user). Root-reserved
/// blocks fall out of the denominator, matching what `df -h` prints.
pub fn usedFraction(used_bytes: u64, avail_bytes: u64) f64 {
    const denom = used_bytes +| avail_bytes;
    if (denom == 0) return 0;
    return @as(f64, @floatFromInt(used_bytes)) / @as(f64, @floatFromInt(denom));
}

// ------------------------------------------------------- syscall wrappers

const IoTotals = struct { read: u64, write: u64 };

/// Sum lifetime read/write byte counters across every IOBlockStorageDriver.
/// Null when IOKit matching fails or the key CFStrings cannot be built.
fn readIoTotals() ?IoTotals {
    // Cached keys: hoisted out of the loop AND out of the tick — none of
    // these three is ours to release.
    const stats_key = cachedString(.statistics) orelse return null;
    const read_key = cachedString(.bytes_read) orelse return null;
    const write_key = cachedString(.bytes_written) orelse return null;

    // IOServiceGetMatchingServices consumes one reference to `matching`
    // regardless of outcome — no release on our side.
    const matching = c.IOServiceMatching("IOBlockStorageDriver");
    if (matching == null) return null;

    var iter: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS)
        return null;
    defer _ = c.IOObjectRelease(iter);

    var totals = IoTotals{ .read = 0, .write = 0 };
    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const props = c.IORegistryEntryCreateCFProperty(service, stats_key, c.kCFAllocatorDefault, 0);
        if (props == null) continue;
        defer c.CFRelease(props);
        if (c.CFGetTypeID(props) != c.CFDictionaryGetTypeID()) continue;

        const dict: c.CFDictionaryRef = @ptrCast(props);
        totals.read +|= dictCounter(dict, read_key);
        totals.write +|= dictCounter(dict, write_key);
    }
    return totals;
}

/// The `Statistics` dictionary keys this sampler names. An enum with one
/// cache slot per value, rather than a cache keyed on the literal itself: a
/// generic keyed on a `[*:0]const u8` comptime argument silently shares one
/// instantiation across distinct literals, which would hand back the wrong
/// string — and reading the write counter under the read key is exactly the
/// kind of bug that looks plausible on a dashboard.
const Key = enum {
    statistics,
    bytes_read,
    bytes_written,

    fn literal(self: Key) [*:0]const u8 {
        return switch (self) {
            .statistics => c.kIOBlockStorageDriverStatisticsKey,
            .bytes_read => c.kIOBlockStorageDriverStatisticsBytesReadKey,
            .bytes_written => c.kIOBlockStorageDriverStatisticsBytesWrittenKey,
        };
    }
};

/// Real `CFStringCreateWithCString` calls made by `cachedString`. One per
/// `Key` for the life of the process; the tests assert it stops growing.
var cf_string_creates: std.atomic.Value(usize) = .init(0);

pub fn cfStringCreateCount() usize {
    return cf_string_creates.load(.monotonic);
}

/// One immortal CFString per `Key`, 0 until first use.
///
/// Relaxed atomics rather than plain vars: the app samples from a dedicated
/// producer thread while the loop thread keeps a fallback sampler. The
/// create is idempotent, so the worst a race can do is build one duplicate
/// immortal string — never hand back a dangling one.
var key_cache: [@typeInfo(Key).@"enum".fields.len]std.atomic.Value(usize) = @splat(.init(0));

/// The immortal CFString for `key`.
///
/// The keys were already hoisted out of the per-service loop; this hoists
/// them out of the tick as well, which is the loop that actually runs
/// 86,400 times a day.
///
/// OWNERSHIP: the returned reference is deliberately never released, and
/// callers must NEVER `CFRelease` it or attach a `defer` to it. That is what
/// makes reuse safe — nothing else holds a claim on the object, so it cannot
/// be freed out from under the next sample. The cost is three small objects
/// for the process lifetime.
fn cachedString(key: Key) c.CFStringRef {
    const slot = &key_cache[@intFromEnum(key)];
    const cached = slot.load(.monotonic);
    if (cached != 0) return @ptrFromInt(cached);

    const created = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key.literal(), c.kCFStringEncodingUTF8);
    if (created == null) return null;
    _ = cf_string_creates.fetchAdd(1, .monotonic);
    slot.store(@intFromPtr(created), .monotonic);
    return created;
}

/// Read a u64 counter out of a Statistics dictionary; 0 when the entry is
/// missing or not a number. Values are get-rules — nothing to release.
fn dictCounter(dict: c.CFDictionaryRef, key: c.CFStringRef) u64 {
    const value = c.CFDictionaryGetValue(dict, key);
    if (value == null) return 0;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return 0;
    var raw: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &raw) == 0) return 0;
    return if (raw < 0) 0 else @intCast(raw);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

extern "c" fn usleep(microseconds: c_uint) c_int;

test "rate: exact bytes per second from a counter delta" {
    // 1 MiB over 500 ms -> 2 MiB/s.
    const rate = rateBytesPerSec(1000, 1000 + (1 << 20), 500 * std.time.ns_per_ms);
    try testing.expectApproxEqAbs(@as(f64, 2 << 20), rate, 0.001);
}

test "rate: counter wrap or reset clamps to zero" {
    try testing.expectEqual(@as(f64, 0), rateBytesPerSec(5000, 10, std.time.ns_per_s));
}

test "rate: zero elapsed yields zero, not inf" {
    try testing.expectEqual(@as(f64, 0), rateBytesPerSec(0, 12345, 0));
}

test "used fraction: df semantics and empty denominator" {
    try testing.expectApproxEqAbs(@as(f64, 0.75), usedFraction(300, 100), 1e-12);
    try testing.expectEqual(@as(f64, 0), usedFraction(0, 0));
    try testing.expectEqual(@as(f64, 1), usedFraction(500, 0));
}

test "cached statistics keys: one per key, built once, never re-created" {
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
    try testing.expectEqual(after_priming, cfStringCreateCount());
}

test "live: capacity alone needs no baseline and is stable across calls" {
    const first = sampleCapacity() orelse return error.StatfsFailed;
    try testing.expect(first.total_bytes > 0);
    try testing.expect(first.free_bytes < first.total_bytes);
    try testing.expect(first.used_fraction > 0 and first.used_fraction < 1);
    // Slow-moving by nature: two back-to-back reads see the same volume.
    const second = sampleCapacity() orelse return error.StatfsFailed;
    try testing.expectEqual(first.total_bytes, second.total_bytes);
}

test "live: io rates need a baseline, then stand alone from capacity" {
    var state = init();
    // No baseline yet: null, never a zero-filled reading.
    try testing.expectEqual(@as(?IoRates, null), sampleIo(&state));
    _ = usleep(50 * std.time.us_per_ms);
    const rates = sampleIo(&state) orelse return error.NoIoRates;
    try testing.expect(rates.read_bytes_per_sec >= 0 and rates.read_bytes_per_sec < 100e9);
    try testing.expect(rates.write_bytes_per_sec >= 0 and rates.write_bytes_per_sec < 100e9);
}

test "live smoke: two samples produce sane capacity and rates" {
    var state = init();

    const first = sample(&state) orelse return error.StatfsFailed;
    try testing.expect(first.total_bytes > 0);
    try testing.expect(first.free_bytes < first.total_bytes);
    try testing.expect(first.used_fraction > 0 and first.used_fraction < 1);
    // No baseline yet: rates must be null, never zero-filled.
    try testing.expectEqual(@as(?f64, null), first.read_bytes_per_sec);
    try testing.expectEqual(@as(?f64, null), first.write_bytes_per_sec);

    _ = usleep(150 * std.time.us_per_ms);

    const second = sample(&state) orelse return error.StatfsFailed;
    try testing.expect(second.total_bytes == first.total_bytes);
    const read_rate = second.read_bytes_per_sec orelse return error.NoIoRates;
    const write_rate = second.write_bytes_per_sec orelse return error.NoIoRates;
    // Sane band: non-negative, below 100 GB/s even for NVMe bursts.
    try testing.expect(read_rate >= 0 and read_rate < 100e9);
    try testing.expect(write_rate >= 0 and write_rate < 100e9);
}
