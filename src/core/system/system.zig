//! System telemetry aggregator: one call per sweep fans out to the six
//! samplers (each ~microseconds of syscalls, no subprocesses, no root)
//! and folds the results into a single value-type `Snapshot` the model
//! can hold and the view can read.
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

pub const cpu = @import("cpu.zig");
pub const mem = @import("mem.zig");
pub const gpu = @import("gpu.zig");
pub const battery = @import("battery.zig");
pub const disk = @import("disk.zig");
pub const net = @import("net.zig");

/// Peak decay per 2 s sweep: ~0.5%/tick, halving in about five minutes,
/// so a burst re-ranges the meter quickly but the range relaxes once the
/// burst is over.
pub const peak_decay_per_sweep: f64 = 0.995;

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

/// Per-sampler counter state plus meter peaks. Lives on the model for
/// the life of the process.
pub const Sampler = struct {
    cpu_state: cpu.State,
    mem_state: mem.State,
    gpu_state: gpu.State,
    battery_state: battery.State,
    disk_state: disk.State,
    net_state: net.State,
    net_peak_bps: f64 = net_peak_floor_bps,
    disk_peak_bps: f64 = disk_peak_floor_bps,

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

    /// One sweep: sample every module enabled in config. Disabled
    /// modules are not sampled at all (their syscalls are skipped and
    /// their delta baselines go stale, which is fine — re-enabling just
    /// spends one tick re-baselining).
    pub fn sample(self: *Sampler, enabled: Enabled) Snapshot {
        var snap = Snapshot{};
        if (enabled.cpu) snap.cpu = cpu.sample(&self.cpu_state);
        if (enabled.mem) snap.mem = mem.sample(&self.mem_state);
        if (enabled.gpu) snap.gpu = gpu.sample(&self.gpu_state);
        if (enabled.battery) snap.battery = battery.sample(&self.battery_state);
        if (enabled.disk) snap.disk = disk.sample(&self.disk_state);
        if (enabled.net) snap.net = net.sample(&self.net_state);

        if (snap.net) |n| {
            if (n.in_bytes_per_sec != null or n.out_bytes_per_sec != null) {
                const total = (n.in_bytes_per_sec orelse 0) + (n.out_bytes_per_sec orelse 0);
                self.net_peak_bps = ratchet(self.net_peak_bps, total, net_peak_floor_bps);
                snap.net_meter_frac = meterFraction(total, self.net_peak_bps);
            }
        }
        if (snap.disk) |d| {
            if (d.read_bytes_per_sec != null or d.write_bytes_per_sec != null) {
                const total = (d.read_bytes_per_sec orelse 0) + (d.write_bytes_per_sec orelse 0);
                self.disk_peak_bps = ratchet(self.disk_peak_bps, total, disk_peak_floor_bps);
                snap.disk_io_meter_frac = meterFraction(total, self.disk_peak_bps);
            }
        }
        return snap;
    }
};

/// One-shot sampling for short-lived processes (the CLI): take a
/// baseline, hold a small real-time window, sample again so the
/// delta-based readings (CPU ticks, disk/net rates) exist. The app never
/// needs this — its 2 s sweep IS the window.
pub fn sampleOnce(sampler: *Sampler, enabled: Enabled, window_us: u32) Snapshot {
    _ = sampler.sample(enabled);
    _ = c.usleep(window_us);
    return sampler.sample(enabled);
}

/// Ratcheted peak: jumps to a new maximum instantly, decays toward the
/// floor otherwise — the dial re-ranges up fast and relaxes slowly.
pub fn ratchet(peak: f64, value: f64, floor: f64) f64 {
    return @max(@max(value, floor), peak * peak_decay_per_sweep);
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

test "disabled modules stay null; live sample fills enabled ones" {
    var sampler = Sampler.init();
    const none = sampler.sample(Enabled.none);
    try testing.expect(!none.any());

    // mem is instantaneous — one live call must produce a reading.
    const only_mem = sampler.sample(.{ .cpu = false, .gpu = false, .mem = true, .disk = false, .net = false, .battery = false });
    try testing.expect(only_mem.mem != null);
    try testing.expect(only_mem.cpu == null);
}
