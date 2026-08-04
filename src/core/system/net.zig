//! Network sampler: machine-wide in/out throughput.
//!
//! Source of truth is the routing sysctl `{CTL_NET, PF_ROUTE, 0, 0,
//! NET_RT_IFLIST2, 0}`: one `if_msghdr2` record per interface, each
//! carrying `if_data64` with lifetime `ifi_ibytes` / `ifi_obytes` u64
//! octet counters — the same numbers `netstat -ib` prints, no root, no
//! subprocess. Loopback interfaces (IFF_LOOPBACK) are excluded so local
//! chatter does not read as network traffic; everything else is summed,
//! down interfaces included (their counters simply do not move).
//!
//! Rates come from differencing consecutive counter sums against a
//! monotonic clock. The first call after `init()` returns totals but
//! `null` rates — there is no baseline to difference yet. Callers render
//! rates only when present.
//!
//! The interface-list buffer lives on `State` and is reused: the sysctl
//! wants a scratch buffer of a few KiB, and allocating one per tick means
//! an mmap/munmap pair every second for the life of the process.

const std = @import("std");
const clock = @import("clock.zig");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/sysctl.h");
    @cInclude("net/if.h");
    @cInclude("net/if_var.h");
    @cInclude("net/route.h");
});

/// One network observation. Totals are lifetime octet counters summed
/// across non-loopback interfaces; rates are null until a second sample
/// provides a delta baseline.
pub const Sample = struct {
    /// Lifetime bytes received across non-loopback interfaces.
    total_bytes_in: u64,
    /// Lifetime bytes sent across non-loopback interfaces.
    total_bytes_out: u64,
    /// Receive throughput, bytes/sec. Null on the first sample.
    in_bytes_per_sec: ?f64 = null,
    /// Transmit throughput, bytes/sec. Null on the first sample.
    out_bytes_per_sec: ?f64 = null,
};

/// Prior counters + monotonic timestamp for rate derivation, plus the
/// reused sysctl scratch buffer.
///
/// The buffer makes `State` an owning type: it must not be copied by value
/// while live (two copies would each believe they own the same pages), and
/// long-lived owners should `deinit` it. Every sampler in the tree holds
/// its `State` in place and passes it by pointer.
pub const State = struct {
    prev_bytes_in: u64 = 0,
    prev_bytes_out: u64 = 0,
    /// mach_absolute_time converted to nanoseconds at the previous sample.
    prev_ns: u64 = 0,
    has_prev: bool = false,
    /// Interface-list scratch, grown to the high-water mark and kept.
    /// After the first tick or two the list stops growing and the steady
    /// state costs zero mmap/munmap pairs.
    buf: []u8 = &.{},
    /// Counts real allocations of `buf`. The reuse is the point, so the
    /// tests assert this stops growing.
    alloc_count: u32 = 0,

    /// Release the scratch buffer. The app never calls this — its samplers
    /// live as long as the process — but a test or a short-lived caller
    /// can, and having it makes the ownership explicit.
    pub fn deinit(self: *State) void {
        if (self.buf.len != 0) buf_allocator.free(self.buf);
        self.buf = &.{};
    }

    /// Ensure `buf` holds at least `needed` bytes. Grows only: the list
    /// size barely moves once interfaces have settled, so shrinking would
    /// just trade a smaller RSS for a fresh mmap on the next tick.
    fn ensureBuf(self: *State, needed: usize) ?[]u8 {
        if (self.buf.len >= needed) return self.buf;
        const grown = buf_allocator.alloc(u8, needed) catch return null;
        if (self.buf.len != 0) buf_allocator.free(self.buf);
        self.buf = grown;
        self.alloc_count += 1;
        return grown;
    }
};

/// The scratch buffer is page-sized-ish, lives for the process, and is
/// touched once a second — the page allocator is exactly right and keeps
/// `State` free of an allocator field it would otherwise have to be
/// constructed with.
const buf_allocator = std.heap.page_allocator;

pub fn init() State {
    return .{};
}

/// Take one sample. Returns null when the sysctl fails or the interface
/// list cannot be fetched (transient ENOMEM race included).
pub fn sample(state: *State) ?Sample {
    const totals = readIfTotals(state) orelse return null;

    var out = Sample{
        .total_bytes_in = totals.ibytes,
        .total_bytes_out = totals.obytes,
    };

    if (clock.monotonicNs()) |now_ns| {
        if (state.has_prev and now_ns > state.prev_ns) {
            const elapsed = now_ns - state.prev_ns;
            out.in_bytes_per_sec = rateBytesPerSec(state.prev_bytes_in, totals.ibytes, elapsed);
            out.out_bytes_per_sec = rateBytesPerSec(state.prev_bytes_out, totals.obytes, elapsed);
        }
        state.prev_bytes_in = totals.ibytes;
        state.prev_bytes_out = totals.obytes;
        state.prev_ns = now_ns;
        state.has_prev = true;
    }
    return out;
}

// ---------------------------------------------------------- pure helpers

/// Counter pair + elapsed nanoseconds -> bytes/sec. A counter sum that
/// went backwards (interface detached, counter reset) clamps the delta to
/// 0 rather than producing a huge bogus rate; zero elapsed yields 0.
pub fn rateBytesPerSec(prev: u64, cur: u64, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    const delta: u64 = if (cur >= prev) cur - prev else 0;
    return @as(f64, @floatFromInt(delta)) * std.time.ns_per_s /
        @as(f64, @floatFromInt(elapsed_ns));
}

pub const Totals = struct { ibytes: u64, obytes: u64 };

/// Common 4-byte prefix shared by every PF_ROUTE sysctl record: enough to
/// know a record's length and type without assuming its full shape.
const MsgPrefix = extern struct {
    msglen: u16,
    version: u8,
    kind: u8,
};

/// Walk a NET_RT_IFLIST2 buffer, summing ifi_ibytes/ifi_obytes over
/// RTM_IFINFO2 records whose interface is not loopback. Records are
/// copied out by prefix length, never pointer-cast — the kernel packs
/// them with 4-byte alignment and interleaves other record kinds
/// (address records) that are smaller than if_msghdr2.
pub fn sumIfList2(buf: []const u8) Totals {
    var totals = Totals{ .ibytes = 0, .obytes = 0 };
    var off: usize = 0;
    while (off + @sizeOf(MsgPrefix) <= buf.len) {
        var prefix: MsgPrefix = undefined;
        @memcpy(std.mem.asBytes(&prefix), buf[off..][0..@sizeOf(MsgPrefix)]);
        const msglen: usize = prefix.msglen;
        if (msglen < @sizeOf(MsgPrefix) or off + msglen > buf.len) break;
        if (prefix.kind == c.RTM_IFINFO2 and msglen >= @sizeOf(c.struct_if_msghdr2)) {
            var m: c.struct_if_msghdr2 = undefined;
            @memcpy(std.mem.asBytes(&m), buf[off..][0..@sizeOf(c.struct_if_msghdr2)]);
            if (m.ifm_flags & c.IFF_LOOPBACK == 0) {
                totals.ibytes +|= m.ifm_data.ifi_ibytes;
                totals.obytes +|= m.ifm_data.ifi_obytes;
            }
        }
        off += msglen;
    }
    return totals;
}

// ------------------------------------------------------- syscall wrappers

/// Fetch the interface list via sysctl and sum its byte counters, reusing
/// the buffer on `state`.
fn readIfTotals(state: *State) ?Totals {
    var mib = [6]c_int{ c.CTL_NET, c.PF_ROUTE, 0, 0, c.NET_RT_IFLIST2, 0 };

    var len: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &len, null, 0) != 0) return null;
    if (len == 0) return .{ .ibytes = 0, .obytes = 0 };

    // Slack absorbs interfaces appearing between the size probe and the
    // fetch; on overflow the second call fails and we skip this tick.
    const buf = state.ensureBuf(len + 1024) orelse return null;

    // In-out parameter: we offer the whole buffer and the kernel writes
    // back how much of it it actually filled. Summing past that would walk
    // whatever the previous tick left behind.
    var filled: usize = buf.len;
    if (c.sysctl(&mib, mib.len, buf.ptr, &filled, null, 0) != 0) return null;
    if (filled > buf.len) return null;
    return sumIfList2(buf[0..filled]);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

extern "c" fn usleep(microseconds: c_uint) c_int;

test "rate: exact bytes per second from a counter delta" {
    // 2 MiB over 250 ms -> 8 MiB/s.
    const rate = rateBytesPerSec(0, 2 << 20, 250 * std.time.ns_per_ms);
    try testing.expectApproxEqAbs(@as(f64, 8 << 20), rate, 0.001);
}

test "rate: counter wrap or reset clamps to zero" {
    try testing.expectEqual(@as(f64, 0), rateBytesPerSec(1 << 30, 5, std.time.ns_per_s));
}

test "rate: zero elapsed yields zero, not inf" {
    try testing.expectEqual(@as(f64, 0), rateBytesPerSec(0, 999, 0));
}

fn ifInfo2Record(flags: c_int, ibytes: u64, obytes: u64) [@sizeOf(c.struct_if_msghdr2)]u8 {
    var m = std.mem.zeroes(c.struct_if_msghdr2);
    m.ifm_msglen = @sizeOf(c.struct_if_msghdr2);
    m.ifm_type = c.RTM_IFINFO2;
    m.ifm_flags = flags;
    m.ifm_data.ifi_ibytes = ibytes;
    m.ifm_data.ifi_obytes = obytes;
    return std.mem.toBytes(m);
}

test "walk: sums non-loopback, skips loopback and foreign records" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // A non-IFINFO2 record (e.g. an address record) that must be stepped
    // over by msglen, not misread as an interface.
    const foreign = [8]u8{ 8, 0, 5, 0x14, 0xde, 0xad, 0xbe, 0xef };
    try buf.appendSlice(testing.allocator, &foreign);
    try buf.appendSlice(testing.allocator, &ifInfo2Record(0, 1000, 200));
    try buf.appendSlice(testing.allocator, &ifInfo2Record(c.IFF_LOOPBACK, 77777, 88888));
    try buf.appendSlice(testing.allocator, &ifInfo2Record(c.IFF_UP, 40, 2));

    const totals = sumIfList2(buf.items);
    try testing.expectEqual(@as(u64, 1040), totals.ibytes);
    try testing.expectEqual(@as(u64, 202), totals.obytes);
}

test "walk: zero-length and truncated records terminate cleanly" {
    // msglen 0 -> break, no infinite loop.
    const zeros = [4]u8{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), sumIfList2(&zeros).ibytes);
    // msglen claims more than the buffer holds -> break.
    const truncated = [4]u8{ 200, 0, 0, 0x12 };
    try testing.expectEqual(@as(u64, 0), sumIfList2(&truncated).ibytes);
    // Empty buffer.
    try testing.expectEqual(@as(u64, 0), sumIfList2(&.{}).obytes);
}

test "buffer: grows to the high-water mark, never shrinks, allocates once" {
    var state = init();
    defer state.deinit();

    const first = state.ensureBuf(4096) orelse return error.OutOfMemory;
    try testing.expectEqual(@as(u32, 1), state.alloc_count);
    try testing.expect(first.len >= 4096);

    // A request that already fits hands back the same pages.
    for (0..1000) |_| {
        const again = state.ensureBuf(4096) orelse return error.OutOfMemory;
        try testing.expectEqual(first.ptr, again.ptr);
    }
    try testing.expectEqual(@as(u32, 1), state.alloc_count);

    // A smaller request must not shrink (that would mean re-mmapping on
    // the very next tick).
    const smaller = state.ensureBuf(16) orelse return error.OutOfMemory;
    try testing.expectEqual(first.ptr, smaller.ptr);
    try testing.expectEqual(@as(u32, 1), state.alloc_count);

    // Growing past the mark reallocates exactly once.
    const bigger = state.ensureBuf(first.len + 1) orelse return error.OutOfMemory;
    try testing.expect(bigger.len > first.len);
    try testing.expectEqual(@as(u32, 2), state.alloc_count);
}

test "live: repeated samples reuse one buffer" {
    var state = init();
    defer state.deinit();

    _ = sample(&state) orelse return error.SysctlFailed;
    const after_first = state.alloc_count;
    try testing.expectEqual(@as(u32, 1), after_first);
    for (0..200) |_| _ = sample(&state) orelse return error.SysctlFailed;
    // Two hundred more ticks, zero more mmap/munmap pairs.
    try testing.expectEqual(after_first, state.alloc_count);
}

test "live smoke: two samples produce sane totals and rates" {
    var state = init();
    defer state.deinit();

    const first = sample(&state) orelse return error.SysctlFailed;
    // No baseline yet: rates must be null, never zero-filled.
    try testing.expectEqual(@as(?f64, null), first.in_bytes_per_sec);
    try testing.expectEqual(@as(?f64, null), first.out_bytes_per_sec);

    _ = usleep(150 * std.time.us_per_ms);

    const second = sample(&state) orelse return error.SysctlFailed;
    // Lifetime counters only grow between two closely spaced reads.
    try testing.expect(second.total_bytes_in >= first.total_bytes_in);
    try testing.expect(second.total_bytes_out >= first.total_bytes_out);
    const in_rate = second.in_bytes_per_sec orelse return error.NoRates;
    const out_rate = second.out_bytes_per_sec orelse return error.NoRates;
    // Sane band: non-negative, below 100 GB/s.
    try testing.expect(in_rate >= 0 and in_rate < 100e9);
    try testing.expect(out_rate >= 0 and out_rate < 100e9);
}
