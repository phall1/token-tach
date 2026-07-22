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
//! This runs on the poll cadence (~2 s) for days: every CF and IOKit object
//! created here is released before returning.

const std = @import("std");
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

// <mach/mach_time.h> declarations, hand-rolled: the header drags in
// mach_msg types that translate-c cannot size. These are stable libSystem
// symbols with fixed ABI.
const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;
extern "c" fn mach_absolute_time() u64;

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

/// Take one sample. Returns null only when `statfs("/")` itself fails
/// (capacity is the load-bearing half); IOKit trouble degrades to null
/// rates instead.
pub fn sample(state: *State) ?Sample {
    var st: c.struct_statfs = undefined;
    if (c.statfs("/", &st) != 0) return null;

    const bsize: u64 = st.f_bsize;
    const total = st.f_blocks * bsize;
    const avail = st.f_bavail * bsize;
    const used = (st.f_blocks -| st.f_bfree) * bsize;

    var out = Sample{
        .total_bytes = total,
        .free_bytes = avail,
        .used_fraction = usedFraction(used, avail),
    };

    if (readIoTotals()) |totals| {
        if (monotonicNs()) |now_ns| {
            if (state.has_prev and now_ns > state.prev_ns) {
                const elapsed = now_ns - state.prev_ns;
                out.read_bytes_per_sec =
                    rateBytesPerSec(state.prev_read_bytes, totals.read, elapsed);
                out.write_bytes_per_sec =
                    rateBytesPerSec(state.prev_write_bytes, totals.write, elapsed);
            }
            state.prev_read_bytes = totals.read;
            state.prev_write_bytes = totals.write;
            state.prev_ns = now_ns;
            state.has_prev = true;
        }
    }
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

/// Monotonic nanoseconds since boot from mach_absolute_time, timebase
/// corrected (Apple Silicon ticks at 24 MHz, not 1 ns). Null only if the
/// timebase query fails.
fn monotonicNs() ?u64 {
    var info: MachTimebaseInfo = .{ .numer = 0, .denom = 0 };
    if (mach_timebase_info(&info) != 0 or info.denom == 0) return null;
    const ticks: u128 = mach_absolute_time();
    return @intCast(ticks * info.numer / info.denom);
}

const IoTotals = struct { read: u64, write: u64 };

/// Sum lifetime read/write byte counters across every IOBlockStorageDriver.
/// Null when IOKit matching fails or the key CFStrings cannot be built.
fn readIoTotals() ?IoTotals {
    const stats_key = cfStr(c.kIOBlockStorageDriverStatisticsKey) orelse return null;
    defer c.CFRelease(stats_key);
    const read_key = cfStr(c.kIOBlockStorageDriverStatisticsBytesReadKey) orelse return null;
    defer c.CFRelease(read_key);
    const write_key = cfStr(c.kIOBlockStorageDriverStatisticsBytesWrittenKey) orelse return null;
    defer c.CFRelease(write_key);

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

/// Owned CFString from a NUL-terminated C string; caller releases.
fn cfStr(bytes: [*c]const u8) ?c.CFStringRef {
    const s = c.CFStringCreateWithCString(c.kCFAllocatorDefault, bytes, c.kCFStringEncodingUTF8);
    if (s == null) return null;
    return s;
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
