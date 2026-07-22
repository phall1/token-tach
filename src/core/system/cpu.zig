//! CPU utilization sampler (macOS, mach).
//!
//! Reads cumulative per-core tick counters via `host_processor_info`
//! (PROCESSOR_CPU_LOAD_INFO) and turns the delta between two consecutive
//! calls into busy fractions: whole machine, plus — on Apple Silicon —
//! the efficiency and performance clusters separately. Load average comes
//! from `getloadavg`. One mach call + two sysctls per tick; no
//! subprocesses, no allocation beyond the kernel-owned info array (which
//! is vm_deallocated before returning).
//!
//! Delta-based: the FIRST `sample()` call only records a baseline and
//! returns null. Pure tick math lives in standalone `pub fn`s so tests
//! need no syscalls.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("stdlib.h"); // getloadavg
    @cInclude("unistd.h"); // usleep (live test only)
});

/// <mach/mach.h> cannot go through @cImport under Zig 0.16: translate-c
/// renders the mach_msg descriptor unions in <mach/message.h> as opaque
/// types, and the header's _Static_asserts on their sizes then fail to
/// compile. The few declarations needed here are stable kernel ABI, so
/// they are spelled out directly; ports and vm_deallocate come from
/// std.c, which already binds them.
const mach = struct {
    const KERN_SUCCESS: c_int = 0;
    /// PROCESSOR_CPU_LOAD_INFO from <mach/processor_info.h>.
    const PROCESSOR_CPU_LOAD_INFO: c_int = 2;
    // CPU_STATE_* tick indices from <mach/machine.h>.
    const CPU_STATE_USER: usize = 0;
    const CPU_STATE_SYSTEM: usize = 1;
    const CPU_STATE_IDLE: usize = 2;
    const CPU_STATE_NICE: usize = 3;

    extern "c" fn host_processor_info(
        host: std.c.mach_port_t,
        flavor: c_int,
        out_processor_count: *u32,
        out_processor_info: *[*]i32,
        out_processor_info_count: *u32,
    ) c_int;
};

/// Upper bound on tracked logical CPUs. Anything above this (no shipping
/// Mac comes close) makes `sample` return null rather than truncate.
const max_cpus = 128;

/// host_processor_info reports CPU_STATE_MAX (= 4) counters per core:
/// user, system, idle, nice.
const tick_states = 4;

pub const Sample = struct {
    /// Whole-machine busy fraction since the previous call, 0..1.
    total_frac: f64,
    /// Logical core count.
    core_count: u32,
    /// 1-minute load average (runnable threads); not bounded by 1.
    load_avg_1m: f64,
    /// Performance-cluster busy fraction 0..1; null when the E/P split
    /// cannot be determined (Intel Macs, missing sysctls).
    p_cluster_frac: ?f64,
    /// Efficiency-cluster busy fraction 0..1; null under the same
    /// conditions as `p_cluster_frac` (the two are all-or-nothing).
    e_cluster_frac: ?f64,
};

/// Prior cumulative tick counters, so the next call can take deltas.
pub const State = struct {
    prev_ticks: [max_cpus][tick_states]u32 = @splat(@splat(0)),
    prev_ncpu: u32 = 0,
    has_baseline: bool = false,

    pub fn init() State {
        return .{};
    }
};

/// Take one reading. Returns null on the first call (baseline only), if
/// the reported core count changed since the last call (re-baselines),
/// or if the mach call fails.
pub fn sample(state: *State) ?Sample {
    var ncpu: u32 = 0;
    var info: [*]i32 = undefined;
    var info_count: u32 = 0;
    if (mach.host_processor_info(
        std.c.mach_host_self(),
        mach.PROCESSOR_CPU_LOAD_INFO,
        &ncpu,
        &info,
        &info_count,
    ) != mach.KERN_SUCCESS) return null;
    // The info array is kernel-allocated in our address space; free it.
    defer _ = std.c.vm_deallocate(
        std.c.mach_task_self(),
        @intFromPtr(info),
        @as(std.c.vm_size_t, info_count) * @sizeOf(i32),
    );
    if (ncpu == 0 or ncpu > max_cpus) return null;
    const n: usize = ncpu;

    // processor_cpu_load_info_data_t is exactly [CPU_STATE_MAX]natural_t.
    const per_cpu: [*]const [tick_states]u32 = @ptrCast(@alignCast(info));

    var busy: [max_cpus]u64 = undefined;
    var idle: [max_cpus]u64 = undefined;
    const rebaseline = !state.has_baseline or state.prev_ncpu != ncpu;
    for (0..n) |i| {
        const ticks = per_cpu[i];
        if (!rebaseline) {
            const prev = state.prev_ticks[i];
            busy[i] = tickDelta(ticks[mach.CPU_STATE_USER], prev[mach.CPU_STATE_USER]) +
                tickDelta(ticks[mach.CPU_STATE_SYSTEM], prev[mach.CPU_STATE_SYSTEM]) +
                tickDelta(ticks[mach.CPU_STATE_NICE], prev[mach.CPU_STATE_NICE]);
            idle[i] = tickDelta(ticks[mach.CPU_STATE_IDLE], prev[mach.CPU_STATE_IDLE]);
        }
        state.prev_ticks[i] = ticks;
    }
    state.prev_ncpu = ncpu;
    state.has_baseline = true;
    if (rebaseline) return null;

    var e_frac: ?f64 = null;
    var p_frac: ?f64 = null;
    if (clusterLayout(
        ncpu,
        sysctlScalar(u32, "hw.perflevel0.logicalcpu"),
        sysctlScalar(u32, "hw.perflevel1.logicalcpu"),
    )) |layout| {
        const e: usize = layout.e_count;
        e_frac = groupFraction(busy[0..e], idle[0..e]);
        p_frac = groupFraction(busy[e..n], idle[e..n]);
    }

    var loads: [3]f64 = @splat(0);
    const load_1m: f64 = if (c.getloadavg(&loads, loads.len) >= 1) loads[0] else 0;

    return .{
        .total_frac = groupFraction(busy[0..n], idle[0..n]),
        .core_count = ncpu,
        .load_avg_1m = load_1m,
        .p_cluster_frac = p_frac,
        .e_cluster_frac = e_frac,
    };
}

// --------------------------------------------------- pure helpers (no syscalls)

/// Wrapping delta between two cumulative u32 tick counters. The kernel
/// counters are 32-bit and wrap after long uptimes; wrapping subtraction
/// keeps the delta correct across a single wrap.
pub fn tickDelta(now: u32, prev: u32) u64 {
    return now -% prev;
}

/// Busy fraction from summed busy/idle tick deltas; 0 when no ticks
/// elapsed (interval shorter than the 10ms tick, or a paused VM).
pub fn tickFraction(busy_ticks: u64, idle_ticks: u64) f64 {
    const total = busy_ticks + idle_ticks;
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(busy_ticks)) / @as(f64, @floatFromInt(total));
}

/// Busy fraction across a group of cores: ticks are summed BEFORE
/// dividing, so a saturated core and an idle core average to 0.5.
pub fn groupFraction(busy: []const u64, idle: []const u64) f64 {
    var b: u64 = 0;
    var i: u64 = 0;
    for (busy) |v| b += v;
    for (idle) |v| i += v;
    return tickFraction(b, i);
}

pub const ClusterLayout = struct {
    /// Efficiency cores occupy processor indices [0, e_count).
    e_count: u32,
    /// Performance cores occupy [e_count, e_count + p_count).
    p_count: u32,
};

/// Maps perflevel core counts onto host_processor_info's processor order.
///
/// Empirically verified on an M4 Pro (hw.perflevel0.logicalcpu = 10, named
/// "Performance"; hw.perflevel1.logicalcpu = 4, named "Efficiency"; 14
/// logical CPUs): spinner threads at QOS_CLASS_BACKGROUND — which macOS
/// restricts to the efficiency cluster — drove processors 0-3 to zero idle
/// ticks while 4-13 stayed mostly idle. So EFFICIENCY cores come FIRST in
/// processor order and the perflevel0 (performance) cores are listed after
/// them. Returns null unless both sysctls were readable, both non-zero,
/// and their sum matches the processor count exactly.
pub fn clusterLayout(ncpu: u32, p_cores: ?u32, e_cores: ?u32) ?ClusterLayout {
    const p = p_cores orelse return null;
    const e = e_cores orelse return null;
    if (p == 0 or e == 0) return null;
    if (p + e != ncpu) return null;
    return .{ .e_count = e, .p_count = p };
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

test "tick delta: wraps across counter overflow" {
    try testing.expectEqual(@as(u64, 0), tickDelta(7, 7));
    try testing.expectEqual(@as(u64, 100), tickDelta(150, 50));
    try testing.expectEqual(@as(u64, 6), tickDelta(5, std.math.maxInt(u32)));
}

test "tick fraction: bounds and zero-elapsed" {
    try testing.expectEqual(@as(f64, 0), tickFraction(0, 0));
    try testing.expectEqual(@as(f64, 0), tickFraction(0, 100));
    try testing.expectEqual(@as(f64, 1), tickFraction(100, 0));
    try testing.expectApproxEqAbs(@as(f64, 0.25), tickFraction(25, 75), 1e-12);
}

test "group fraction: sums ticks before dividing" {
    // One saturated core + one idle core = half busy overall.
    const busy = [_]u64{ 100, 0 };
    const idle = [_]u64{ 0, 100 };
    try testing.expectApproxEqAbs(@as(f64, 0.5), groupFraction(&busy, &idle), 1e-12);
    try testing.expectEqual(@as(f64, 0), groupFraction(&.{}, &.{}));
}

test "cluster layout: requires both sysctls and an exact core sum" {
    try testing.expectEqual(@as(?ClusterLayout, null), clusterLayout(14, null, 4));
    try testing.expectEqual(@as(?ClusterLayout, null), clusterLayout(14, 10, null));
    try testing.expectEqual(@as(?ClusterLayout, null), clusterLayout(14, 10, 0));
    try testing.expectEqual(@as(?ClusterLayout, null), clusterLayout(16, 10, 4));
    const layout = clusterLayout(14, 10, 4).?;
    try testing.expectEqual(@as(u32, 4), layout.e_count);
    try testing.expectEqual(@as(u32, 10), layout.p_count);
}

test "live: baseline then a sane second sample" {
    var state = State.init();
    try testing.expect(sample(&state) == null); // first call: baseline only
    _ = c.usleep(50 * 1000);
    const s = sample(&state) orelse return error.NoSample;
    try testing.expect(s.total_frac >= 0 and s.total_frac <= 1);
    try testing.expect(s.core_count > 0);
    try testing.expect(s.load_avg_1m >= 0);
    // Cluster fields are all-or-nothing, and in range when present.
    try testing.expectEqual(s.p_cluster_frac == null, s.e_cluster_frac == null);
    if (s.e_cluster_frac) |f| try testing.expect(f >= 0 and f <= 1);
    if (s.p_cluster_frac) |f| try testing.expect(f >= 0 and f <= 1);
}
