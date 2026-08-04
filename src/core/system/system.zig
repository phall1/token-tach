//! System telemetry aggregator: one call per sweep fans out to the six
//! samplers (each ~microseconds of syscalls, no subprocesses, no root)
//! and folds the results into a single value-type `Snapshot` the model
//! can hold and the view can read.
//!
//! Not every sampler is worth its cost every sweep. `sample` splits them
//! into a fast group (cpu, mem, net, disk I/O — quantities that are
//! either rates, and so only as good as the interval they are measured
//! over, or free to read) and a slow group (gpu, battery, disk capacity),
//! each of which copies a property dictionary out of the kernel to learn
//! something that moves on a 30-second-to-hourly scale. Slow readings are
//! refreshed every `slow_group_every` sweeps and carried forward in
//! between, so the `Snapshot` shape and its consumers are untouched — the
//! value is simply a few seconds old instead of one second old.
//!
//! The aggregator also owns the activity peaks the UI needs for meters
//! over unbounded quantities (network and disk throughput have no
//! natural 100%): a ratcheted, slowly decaying peak — the same trick the
//! tach dial uses for its burn scale — turns "bytes per second" into a
//! stable 0..1 meter fraction.

const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
});

pub const clock = @import("clock.zig");
pub const cpu = @import("cpu.zig");
pub const mem = @import("mem.zig");
pub const gpu = @import("gpu.zig");
pub const battery = @import("battery.zig");
pub const disk = @import("disk.zig");
pub const net = @import("net.zig");

/// Peak decay per second: the meter's range halves in about 4.6 minutes,
/// so a burst re-ranges the meter instantly but the range relaxes slowly
/// once the burst is over.
///
/// Time-based rather than per-call on purpose. The old per-sweep constant
/// was documented as "per 2 s sweep" while the producer thread actually
/// runs at 1000 ms (engine.system_sample_interval_ms), so every meter
/// decayed twice as fast as its documentation claimed — and the same code
/// also serves the CLI, which samples on a 150 ms window. Anchoring the
/// decay to elapsed wall time makes the behavior a property of the meter
/// instead of a property of whoever happens to be calling it, and it
/// degrades correctly when a sweep is late or the machine slept.
///
/// The value is the per-second equivalent of the originally intended
/// 0.995-per-2-s: sqrt(0.995).
pub const peak_decay_per_second: f64 = 0.9974968671630002;

/// Per-call decay retained for callers that tick on a fixed cadence.
/// Prefer `ratchetOver`: this one silently means different things at
/// different sweep intervals, which is what made the meters decay 2x fast.
pub const peak_decay_per_sweep: f64 = 0.995;

/// How many sweeps between refreshes of the slow group (gpu, battery,
/// disk capacity). At the producer's 1 Hz cadence that is a refresh every
/// four seconds, which drops three quarters of the kernel dictionary
/// copies this module makes.
///
/// Four rather than something larger because GPU utilization is the
/// fastest-moving member of the group and a reading much staler than that
/// starts to look frozen next to a live CPU meter; battery charge (~30 s
/// scale) and volume capacity (~hourly) have orders of magnitude more
/// headroom than this.
pub const slow_group_every: u64 = 4;

/// Meter floors keep a quiet machine from rendering noise as a full bar:
/// the network meter never ranges below 1 MB/s, disk below 10 MB/s.
pub const net_peak_floor_bps: f64 = 1_000_000;
pub const disk_peak_floor_bps: f64 = 10_000_000;

/// Which modules to sample. Mirrors `config.SystemStats` field-for-field
/// but stays decoupled — the engine converts explicitly, and this file
/// (like every sampler) imports nothing outside std.
pub const Enabled = packed struct {
    cpu: bool = true,
    gpu: bool = true,
    mem: bool = true,
    disk: bool = true,
    net: bool = true,
    battery: bool = true,

    pub const none: Enabled = .{ .cpu = false, .gpu = false, .mem = false, .disk = false, .net = false, .battery = false };
};

/// Everything one sweep learned about the machine. Plain values —
/// copyable, no ownership. A null module means unavailable (no battery,
/// no accelerator, first-tick rates) or disabled in config; the UI hides
/// it rather than showing zeros.
pub const Snapshot = struct {
    cpu: ?cpu.Sample = null,
    gpu: ?gpu.Sample = null,
    mem: ?mem.Sample = null,
    disk: ?disk.Sample = null,
    net: ?net.Sample = null,
    battery: ?battery.Sample = null,
    /// Combined net throughput (rx+tx) against the ratcheted peak, 0..1.
    net_meter_frac: ?f64 = null,
    /// Combined disk throughput (read+write) against the ratcheted peak, 0..1.
    disk_io_meter_frac: ?f64 = null,

    pub fn any(self: Snapshot) bool {
        return self.cpu != null or self.gpu != null or self.mem != null or
            self.disk != null or self.net != null or self.battery != null;
    }
};

/// Per-sampler counter state, the slow group's carried-forward readings,
/// and the meter peaks. Lives on the model for the life of the process.
///
/// Owns heap memory (net's scratch buffer), so it is passed by pointer and
/// never copied by value.
pub const Sampler = struct {
    cpu_state: cpu.State,
    mem_state: mem.State,
    gpu_state: gpu.State,
    battery_state: battery.State,
    disk_state: disk.State,
    net_state: net.State,
    net_peak_bps: f64 = net_peak_floor_bps,
    disk_peak_bps: f64 = disk_peak_floor_bps,

    /// Sweeps taken. Drives the slow group's cadence; wrapping is
    /// irrelevant (it takes 500 billion years at 1 Hz) but harmless.
    sweeps: u64 = 0,
    /// Monotonic timestamp of the previous sweep, for time-based decay.
    prev_sweep_ns: u64 = 0,
    has_prev_sweep: bool = false,

    /// Last readings from the slow group, held between refreshes. A null
    /// here plus its `_fresh` flag set means "asked, and this machine has
    /// none" — a desktop with no battery must not be re-probed every
    /// sweep just because the answer was null.
    last_gpu: ?gpu.Sample = null,
    gpu_fresh: bool = false,
    last_battery: ?battery.Sample = null,
    battery_fresh: bool = false,
    last_disk_capacity: ?disk.Capacity = null,
    disk_capacity_fresh: bool = false,

    pub fn init() Sampler {
        return .{
            .cpu_state = cpu.State.init(),
            .mem_state = mem.State.init(),
            .gpu_state = gpu.State.init(),
            .battery_state = battery.State.init(),
            .disk_state = disk.init(),
            .net_state = net.init(),
        };
    }

    /// Release what the samplers own. The app never calls this (its
    /// samplers outlive everything else), but it keeps the ownership
    /// honest for short-lived callers and tests.
    pub fn deinit(self: *Sampler) void {
        self.net_state.deinit();
    }

    /// One sweep: sample every module enabled in config. Disabled
    /// modules are not sampled at all (their syscalls are skipped and
    /// their delta baselines go stale, which is fine — re-enabling just
    /// spends one tick re-baselining).
    ///
    /// The slow group refreshes on the first sweep, on every
    /// `slow_group_every`-th sweep after that, and immediately whenever a
    /// module is re-enabled — a user who ticks the GPU box back on should
    /// not stare at an empty cell waiting for the cadence to come around.
    pub fn sample(self: *Sampler, enabled: Enabled) Snapshot {
        const slow_due = self.sweeps % slow_group_every == 0;
        self.sweeps +%= 1;

        var snap = Snapshot{};
        if (enabled.cpu) snap.cpu = cpu.sample(&self.cpu_state);
        if (enabled.mem) snap.mem = mem.sample(&self.mem_state);
        if (enabled.net) snap.net = net.sample(&self.net_state);

        if (enabled.gpu) {
            if (slow_due or !self.gpu_fresh) {
                self.last_gpu = gpu.sample(&self.gpu_state);
                self.gpu_fresh = true;
            }
            snap.gpu = self.last_gpu;
        } else self.gpu_fresh = false;

        if (enabled.battery) {
            if (slow_due or !self.battery_fresh) {
                self.last_battery = battery.sample(&self.battery_state);
                self.battery_fresh = true;
            }
            snap.battery = self.last_battery;
        } else self.battery_fresh = false;

        if (enabled.disk) {
            if (slow_due or !self.disk_capacity_fresh) {
                self.last_disk_capacity = disk.sampleCapacity();
                self.disk_capacity_fresh = true;
            }
            // The I/O counters are a rate: they must be read every sweep
            // whether or not the capacity half was refreshed, or the
            // interval they are differenced over stretches to match the
            // slow cadence and the reading smears.
            const io = disk.sampleIo(&self.disk_state);
            if (self.last_disk_capacity) |cap| snap.disk = .{
                .total_bytes = cap.total_bytes,
                .free_bytes = cap.free_bytes,
                .used_fraction = cap.used_fraction,
                .read_bytes_per_sec = if (io) |r| r.read_bytes_per_sec else null,
                .write_bytes_per_sec = if (io) |r| r.write_bytes_per_sec else null,
            };
        } else self.disk_capacity_fresh = false;

        const elapsed_ns = self.sweepElapsedNs();
        if (snap.net) |n| {
            if (n.in_bytes_per_sec != null or n.out_bytes_per_sec != null) {
                const total = (n.in_bytes_per_sec orelse 0) + (n.out_bytes_per_sec orelse 0);
                self.net_peak_bps = ratchetOver(self.net_peak_bps, total, net_peak_floor_bps, elapsed_ns);
                snap.net_meter_frac = meterFraction(total, self.net_peak_bps);
            }
        }
        if (snap.disk) |d| {
            if (d.read_bytes_per_sec != null or d.write_bytes_per_sec != null) {
                const total = (d.read_bytes_per_sec orelse 0) + (d.write_bytes_per_sec orelse 0);
                self.disk_peak_bps = ratchetOver(self.disk_peak_bps, total, disk_peak_floor_bps, elapsed_ns);
                snap.disk_io_meter_frac = meterFraction(total, self.disk_peak_bps);
            }
        }
        return snap;
    }

    /// Nanoseconds since the previous sweep; 0 on the first sweep and if
    /// the clock is unreadable, which decays nothing rather than guessing
    /// an interval.
    fn sweepElapsedNs(self: *Sampler) u64 {
        const now_ns = clock.monotonicNs() orelse return 0;
        defer {
            self.prev_sweep_ns = now_ns;
            self.has_prev_sweep = true;
        }
        if (!self.has_prev_sweep or now_ns <= self.prev_sweep_ns) return 0;
        return now_ns - self.prev_sweep_ns;
    }
};

/// One-shot sampling for short-lived processes (the CLI): take a
/// baseline, hold a small real-time window, sample again so the
/// delta-based readings (CPU ticks, disk/net rates) exist. The app never
/// needs this — its sweep IS the window.
///
/// The slow group is read on the first of the two calls (sweep 0 always
/// refreshes it) and carried into the second, so a one-shot caller gets a
/// complete snapshot for one set of the expensive kernel copies rather
/// than two.
pub fn sampleOnce(sampler: *Sampler, enabled: Enabled, window_us: u32) Snapshot {
    _ = sampler.sample(enabled);
    _ = c.usleep(window_us);
    return sampler.sample(enabled);
}

/// Ratcheted peak over a fixed cadence: jumps to a new maximum instantly,
/// decays toward the floor otherwise. Retained for fixed-tick callers;
/// `ratchetOver` is the one the sampler uses, because "per call" means
/// different things to the 1 Hz producer and the 150 ms CLI window.
pub fn ratchet(peak: f64, value: f64, floor: f64) f64 {
    return @max(@max(value, floor), peak * peak_decay_per_sweep);
}

/// Ratcheted peak over a measured interval: identical to `ratchet`, but
/// the decay is what `peak_decay_per_second` compounds to over
/// `elapsed_ns`. A late sweep decays proportionally more, a rapid one
/// less, and a sweep that spans a laptop's sleep drops straight to the
/// floor — all of which is what a viewer reading the meter expects.
pub fn ratchetOver(peak: f64, value: f64, floor: f64, elapsed_ns: u64) f64 {
    return @max(@max(value, floor), peak * decayFactor(elapsed_ns));
}

/// The decay multiplier for an elapsed interval: `peak_decay_per_second`
/// raised to the interval in seconds. Zero elapsed decays nothing (factor
/// 1), which is what makes a duplicate or clock-less sweep harmless.
pub fn decayFactor(elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 1;
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    return std.math.pow(f64, peak_decay_per_second, seconds);
}

/// Value against peak as a 0..1 meter fraction.
pub fn meterFraction(value: f64, peak: f64) f64 {
    if (peak <= 0) return 0;
    return std.math.clamp(value / peak, 0, 1);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "ratchet: rises instantly, decays slowly, floors" {
    const floor: f64 = 100;
    var peak: f64 = floor;
    peak = ratchet(peak, 1000, floor);
    try testing.expectEqual(@as(f64, 1000), peak);
    peak = ratchet(peak, 0, floor);
    try testing.expectEqual(@as(f64, 995), peak);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) peak = ratchet(peak, 0, floor);
    try testing.expectEqual(floor, peak);
}

test "meter fraction clamps and survives zero peak" {
    try testing.expectEqual(@as(f64, 0.5), meterFraction(50, 100));
    try testing.expectEqual(@as(f64, 1), meterFraction(200, 100));
    try testing.expectEqual(@as(f64, 0), meterFraction(1, 0));
}

test "decay factor: compounds with elapsed time, not with call count" {
    // Two half-intervals decay exactly as much as one whole one — the
    // property the old per-call constant did not have.
    const half = decayFactor(std.time.ns_per_s / 2);
    try testing.expectApproxEqAbs(decayFactor(std.time.ns_per_s), half * half, 1e-12);

    // One second of decay is the constant itself; no elapsed time is a no-op.
    try testing.expectApproxEqAbs(peak_decay_per_second, decayFactor(std.time.ns_per_s), 1e-12);
    try testing.expectEqual(@as(f64, 1), decayFactor(0));

    // The documented intent: 0.995 per two seconds, halving in ~4.6 min.
    try testing.expectApproxEqAbs(@as(f64, 0.995), decayFactor(2 * std.time.ns_per_s), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), decayFactor(277 * std.time.ns_per_s), 1e-3);

    // A long sleep decays essentially everything rather than overflowing.
    try testing.expect(decayFactor(3600 * std.time.ns_per_s) < 1e-3);
}

test "ratchet over elapsed time: rises instantly, relaxes to the floor" {
    const floor: f64 = 100;
    const second = std.time.ns_per_s;

    var peak = ratchetOver(floor, 1000, floor, second);
    try testing.expectEqual(@as(f64, 1000), peak);

    // Same wall time, different call counts, same answer: this is the
    // whole point of anchoring the decay to elapsed time.
    const one_call = ratchetOver(peak, 0, floor, 4 * second);
    var four_calls = peak;
    for (0..4) |_| four_calls = ratchetOver(four_calls, 0, floor, second);
    try testing.expectApproxEqAbs(one_call, four_calls, 1e-9);

    // Quiet for an hour: pinned to the floor, never below it.
    peak = ratchetOver(peak, 0, floor, 3600 * second);
    try testing.expectEqual(floor, peak);
}

test "slow group fires on the first sweep and every slow_group_every after" {
    // The scheduler is a pure function of the sweep counter; assert it
    // against a synthetic count so no hardware is involved.
    var sampler = Sampler.init();
    defer sampler.deinit();

    var fired: usize = 0;
    for (0..4 * slow_group_every) |i| {
        const due = sampler.sweeps % slow_group_every == 0;
        if (i == 0) try testing.expect(due); // first sweep always refreshes
        try testing.expectEqual(i % slow_group_every == 0, due);
        if (due) fired += 1;
        sampler.sweeps +%= 1;
    }
    try testing.expectEqual(@as(usize, 4), fired);
}

test "slow readings carry forward between refreshes and refresh on re-enable" {
    var sampler = Sampler.init();
    defer sampler.deinit();

    const disk_only = Enabled{ .cpu = false, .gpu = false, .mem = false, .disk = true, .net = false, .battery = false };
    const first = sampler.sample(disk_only);
    const capacity = first.disk orelse return error.StatfsFailed;

    // Sweeps in between reuse the cached capacity rather than re-statfs'ing,
    // while the I/O half keeps advancing every sweep.
    for (1..slow_group_every) |_| {
        const mid = sampler.sample(disk_only);
        const d = mid.disk orelse return error.NoCarriedCapacity;
        try testing.expectEqual(capacity.total_bytes, d.total_bytes);
    }

    // Disabling drops the reading; re-enabling refreshes immediately
    // instead of waiting for the cadence to come back around.
    const off = sampler.sample(Enabled.none);
    try testing.expect(off.disk == null);
    try testing.expect(!sampler.disk_capacity_fresh);
    const back = sampler.sample(disk_only);
    try testing.expect(back.disk != null);
    try testing.expect(sampler.disk_capacity_fresh);
}

test "disabled modules stay null; live sample fills enabled ones" {
    var sampler = Sampler.init();
    defer sampler.deinit();
    const none = sampler.sample(Enabled.none);
    try testing.expect(!none.any());

    // mem is instantaneous — one live call must produce a reading.
    const only_mem = sampler.sample(.{ .cpu = false, .gpu = false, .mem = true, .disk = false, .net = false, .battery = false });
    try testing.expect(only_mem.mem != null);
    try testing.expect(only_mem.cpu == null);
}
