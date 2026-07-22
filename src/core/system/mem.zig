//! Memory sampler (macOS, mach).
//!
//! Reads VM page counts via `host_statistics64` (HOST_VM_INFO64), total
//! physical memory via sysctl `hw.memsize`, and the kernel's memory
//! pressure level via `kern.memorystatus_vm_pressure_level`. "Used"
//! follows Activity Monitor's definition: active + wired + compressed
//! pages. One mach call + two sysctls per tick; no subprocesses, no
//! allocation.
//!
//! Unlike the delta-based samplers, every reading is instantaneous, so
//! the FIRST `sample()` call already yields a Sample; null only means a
//! mach/sysctl call failed. Pure math lives in standalone `pub fn`s so
//! tests need no syscalls.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h"); // usleep (live test only)
});

/// <mach/mach.h> cannot go through @cImport under Zig 0.16: translate-c
/// renders the mach_msg descriptor unions in <mach/message.h> as opaque
/// types, and the header's _Static_asserts on their sizes then fail to
/// compile. The few declarations needed here are stable kernel ABI, so
/// they are spelled out directly; ports and _host_page_size come from
/// std.c, which already binds them.
const mach = struct {
    const KERN_SUCCESS: c_int = 0;
    /// HOST_VM_INFO64 from <mach/host_info.h>.
    const HOST_VM_INFO64: c_int = 4;

    /// struct vm_statistics64 from <mach/vm_statistics.h>. Counts are in
    /// VM pages (host page size), a mix of 32- and 64-bit fields.
    const VmStatistics64 = extern struct {
        free_count: u32,
        active_count: u32,
        inactive_count: u32,
        wire_count: u32,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: u32,
        speculative_count: u32,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: u32,
        throttled_count: u32,
        external_page_count: u32,
        internal_page_count: u32,
        total_uncompressed_pages_in_compressor: u64,
    };

    comptime {
        // Guards the hand-written layout against drift: the C struct is
        // 152 bytes (HOST_VM_INFO64_COUNT = 38 natural_t words).
        std.debug.assert(@sizeOf(VmStatistics64) == 152);
    }

    /// HOST_VM_INFO64_COUNT: struct size in 32-bit words.
    const vm_info64_count: u32 = @sizeOf(VmStatistics64) / @sizeOf(u32);

    extern "c" fn host_statistics64(
        host: std.c.mach_port_t,
        flavor: c_int,
        info: *VmStatistics64,
        count: *u32,
    ) c_int;
};

/// Kernel memory-pressure level, from
/// `kern.memorystatus_vm_pressure_level` (raw: 1 / 2 / 4).
pub const Pressure = enum {
    normal,
    warn,
    critical,
    /// Sysctl absent (older kernels, sandboxes) or an unrecognized level.
    unknown,
};

pub const Sample = struct {
    /// Bytes in use, Activity Monitor style: active + wired + compressed.
    used_bytes: u64,
    /// Physical memory installed (sysctl hw.memsize).
    total_bytes: u64,
    /// used_bytes / total_bytes, 0..1.
    used_frac: f64,
    /// Current kernel memory-pressure level.
    pressure: Pressure,
};

/// Memory readings need no prior counters; the empty State keeps the
/// sampler contract uniform across src/core/system.
pub const State = struct {
    pub fn init() State {
        return .{};
    }
};

/// Take one reading. Null only on mach/sysctl failure — no baseline call
/// is needed.
pub fn sample(state: *State) ?Sample {
    _ = state;
    var stats: mach.VmStatistics64 = undefined;
    var count: u32 = mach.vm_info64_count;
    if (mach.host_statistics64(
        std.c.mach_host_self(),
        mach.HOST_VM_INFO64,
        &stats,
        &count,
    ) != mach.KERN_SUCCESS) return null;

    var page_size: std.c.vm_size_t = 0;
    if (std.c._host_page_size(std.c.mach_host_self(), &page_size) != mach.KERN_SUCCESS)
        return null;

    const total = sysctlScalar(u64, "hw.memsize") orelse return null;
    const used = usedBytes(
        stats.active_count,
        stats.wire_count,
        stats.compressor_page_count,
        page_size,
    );

    return .{
        .used_bytes = used,
        .total_bytes = total,
        .used_frac = usedFraction(used, total),
        .pressure = pressureFromRaw(sysctlScalar(u32, "kern.memorystatus_vm_pressure_level")),
    };
}

// --------------------------------------------------- pure helpers (no syscalls)

/// Activity Monitor's "Memory Used": active + wired + compressed pages,
/// scaled by the VM page size (16 KiB on Apple Silicon, 4 KiB on Intel).
pub fn usedBytes(active_pages: u64, wired_pages: u64, compressed_pages: u64, page_size: u64) u64 {
    return (active_pages + wired_pages + compressed_pages) * page_size;
}

/// used / total as a fraction; 0 when total is 0 (never on real hardware,
/// but keeps the math total).
pub fn usedFraction(used: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total));
}

/// Decode the raw pressure sysctl value; null input (sysctl absent) and
/// unrecognized values both map to .unknown.
pub fn pressureFromRaw(raw: ?u32) Pressure {
    const level = raw orelse return .unknown;
    return switch (level) {
        1 => .normal,
        2 => .warn,
        4 => .critical,
        else => .unknown,
    };
}

/// Fixed-size scalar sysctl read; null if the name is absent or sized
/// differently than expected.
fn sysctlScalar(comptime T: type, name: [*:0]const u8) ?T {
    var value: T = 0;
    var len: usize = @sizeOf(T);
    if (c.sysctlbyname(name, &value, &len, null, 0) != 0) return null;
    if (len != @sizeOf(T)) return null;
    return value;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "used bytes: pages scale by page size" {
    try testing.expectEqual(@as(u64, 0), usedBytes(0, 0, 0, 16384));
    try testing.expectEqual(@as(u64, 6 * 16384), usedBytes(1, 2, 3, 16384));
    try testing.expectEqual(@as(u64, 6 * 4096), usedBytes(3, 2, 1, 4096));
}

test "used fraction: bounds and zero-total" {
    try testing.expectEqual(@as(f64, 0), usedFraction(100, 0));
    try testing.expectEqual(@as(f64, 0), usedFraction(0, 100));
    try testing.expectEqual(@as(f64, 1), usedFraction(100, 100));
    try testing.expectApproxEqAbs(@as(f64, 0.5), usedFraction(8, 16), 1e-12);
}

test "pressure: raw levels decode, absence degrades to unknown" {
    try testing.expectEqual(Pressure.unknown, pressureFromRaw(null));
    try testing.expectEqual(Pressure.normal, pressureFromRaw(1));
    try testing.expectEqual(Pressure.warn, pressureFromRaw(2));
    try testing.expectEqual(Pressure.critical, pressureFromRaw(4));
    try testing.expectEqual(Pressure.unknown, pressureFromRaw(3));
    try testing.expectEqual(Pressure.unknown, pressureFromRaw(0));
}

test "live: two samples with sane ranges" {
    var state = State.init();
    const first = sample(&state) orelse return error.NoSample;
    _ = c.usleep(10 * 1000);
    const second = sample(&state) orelse return error.NoSample;
    for ([_]Sample{ first, second }) |s| {
        try testing.expect(s.total_bytes > 0);
        try testing.expect(s.used_bytes > 0);
        try testing.expect(s.used_bytes < s.total_bytes);
        try testing.expect(s.used_frac > 0 and s.used_frac < 1);
    }
}
