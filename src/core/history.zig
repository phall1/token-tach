//! Durable append-only usage time series: the archive the statefile is not.
//!
//! `statefile.zig` persists the IDENTITY of every event forever (dedup
//! keys) and the CONTENT of none finer than a local calendar day —
//! `ledger.per_day` is six blended scalars per day, and `per_model` /
//! `per_project` are all-time cumulative with no time dimension at all.
//! "How many tokens did project X burn in June" is therefore not a query
//! the current store can answer badly; it is a query it cannot answer.
//! This module is the store that can, and it is written to be TRUTH —
//! unlike the statefile, nothing here is a cache that may be thrown away
//! and re-derived, because the source transcripts get rotated and
//! deleted out from under us.
//!
//! Layout under `$XDG_STATE_HOME/token-tach/history/` (dir 0700, files
//! 0600 — same resolution as `statefile.defaultPath`):
//!
//!     .lock       single-writer flock holder
//!     dict.log    append-only string dictionary (models, projects, sessions)
//!     hot.ring    minute buckets, fixed-size ring
//!     hours.log   hour buckets, append-only, forever
//!     days.log    day buckets, append-only, forever
//!
//! Every tier is a 64-byte header followed by 64-byte fixed records, so
//! a record's offset is arithmetic and a scan is a memcpy loop.
//!
//! # The load-bearing rule: records are ADDITIVE
//!
//! Multiple records sharing the same (bucket, dims) SUM. That single
//! rule is what makes this design cheap and correct at the same time:
//!
//! - A late arrival (a transcript re-scanned hours later) is just
//!   another record with an old bucket. No read-modify-write.
//! - A backfill batch (six months of cold catch-up on first launch) is
//!   a stream of appends. No sorting, no merging, no boot-time dedup.
//! - A crash mid-flush leaves a prefix of a batch on disk. A prefix of
//!   an additive set is a smaller — never a wrong — answer, and the
//!   re-flush after restart adds the rest.
//! - A partial flush and a full flush are the same operation.
//!
//! The cost is duplicate keys, which is a SIZE problem, not a
//! correctness problem. Compaction (below) therefore never has to run:
//! it is a space optimization we may skip forever without any reader
//! ever seeing a different number.
//!
//! Deduplication of *events* is emphatically not this module's job —
//! the tailers own that. Handing the same event to `record` twice
//! double-counts it, exactly as handing it to `Ledger.add` twice does.
//!
//! # Time
//!
//! Minute and hour buckets are UTC. A user flying to Tokyo must not
//! retroactively corrupt the hour series, and a UTC bucket is the only
//! key that survives a timezone move. `days.log` is the exception —
//! a "day" is a local concept ("what did I spend today"), so its header
//! carries the `tz_offset_min` its keys were computed with. A reader
//! running at a different offset REPORTS the pair (bucket, offset)
//! rather than silently re-bucketing: re-bucketing would require the
//! original timestamps, which a day bucket has already thrown away.
//!
//! # Durability ordering
//!
//! A dictionary entry is appended and fsync'd BEFORE any record that
//! references its id is written. Crash in the gap and the worst case is
//! a dangling id, rendered `?id:<n>` — a row you cannot name. The
//! reverse order would risk id reuse pointing an old record at a new
//! string, i.e. a confidently WRONG attribution. Unnameable beats wrong.
//!
//! # Failure policy
//!
//! `Writer.record` returns `void` and never propagates an error.
//! Telemetry recording must not be able to break token collection: any
//! I/O failure logs once, disables the writer for the session, and the
//! app runs exactly as it did before this module existed.
//!
//! Structurally broken files (bad magic, version, record size, header
//! CRC, or a dictionary generation that does not match `dict.log`) are
//! QUARANTINED — renamed to `<name>.bad.<ms>` and recreated — never
//! deleted. The statefile can be deleted because it is a cache; this
//! cannot, because a corrupt tail may still be surrounded by months of
//! readable history worth recovering by hand.

const std = @import("std");
const types = @import("types.zig");
const ledger_mod = @import("ledger.zig");

const Crc32 = std.hash.crc.Crc32;
const Allocator = std.mem.Allocator;

comptime {
    // Records are memcpy'd to disk as-is. A big-endian build would emit
    // a file this module could not read back, so refuse to build rather
    // than write an unreadable archive.
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError("history records are little-endian on disk; port encode/decode before building big-endian");
    }
}

// ---------------------------------------------------------------------------
// Format constants
// ---------------------------------------------------------------------------

pub const format_version: u32 = 1;
pub const record_size: usize = 64;
pub const header_size: usize = 64;

const tier_magic = "TTHIST01".*;
const dict_magic = "TTDICT01".*;
const dict_format_version: u32 = 1;
const dict_header_size: usize = 32;
const dict_entry_header_size: usize = 12;

/// Ring slots. 65536 * 64 B = 4 MiB, and at a realistic handful of
/// distinct (agent, model, project, session) rows per minute it holds
/// well past the 48 h the hot tier promises.
pub const default_hot_capacity: u32 = 65_536;

/// Hot-tier age gate. A cold catch-up of six months would otherwise
/// scroll the entire ring out and leave "recent burn" empty; those old
/// minutes still land in `hours.log`/`days.log`, which is where anyone
/// asking about six months ago should be looking anyway.
pub const hot_max_age_ms: i64 = 48 * 60 * 60 * 1000;

/// Read ceilings. Anything past these is corruption, not data.
const max_tier_bytes: usize = 512 * 1024 * 1024;
const max_dict_bytes: usize = 64 * 1024 * 1024;

/// Compaction triggers (see `maybeCompact`).
const compact_dup_ratio: f64 = 0.25;
const compact_size_bytes: u64 = 32 * 1024 * 1024;

pub const flag_covered: u8 = 1 << 0;
pub const flag_delta: u8 = 1 << 1;
pub const flag_synthetic: u8 = 1 << 2;

/// Reserved agent id for rows this app synthesized rather than observed
/// (imports, manual corrections). Never assigned to a real agent.
pub const synthetic_agent_id: u8 = 255;

const dict_kind_model: u8 = 0;
const dict_kind_project: u8 = 1;
const dict_kind_session: u8 = 2;

/// Longest string `agentName` / `Reader.name` can produce.
pub const name_buf_len: usize = 24;

// ---------------------------------------------------------------------------
// Stable identities
// ---------------------------------------------------------------------------

// The agent <-> on-disk-id mapping lives on `types.Agent` as `storageId()`
// / `fromStorageId()`, next to `label()` — the statefile's equivalent frozen
// identity. It is a wire format: append only, never reorder. See types.zig
// for the exhaustive switch that makes a new `Agent` member a compile error
// until someone numbers it.

/// Display name for an on-disk agent id. Unknown ids render as
/// `agent-<n>` rather than being dropped or coerced to some neighbor —
/// a row nobody can name still belongs in the totals.
pub fn agentName(id: u8, buf: []u8) []const u8 {
    if (id == synthetic_agent_id) return "synthetic";
    if (types.Agent.fromStorageId(id)) |agent| return agent.label();
    return std.fmt.bufPrint(buf, "agent-{d}", .{id}) catch "agent-?";
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

pub const Tier = enum(u8) {
    minute = 0,
    hour = 1,
    day = 2,

    pub fn fileName(self: Tier) []const u8 {
        return switch (self) {
            .minute => "hot.ring",
            .hour => "hours.log",
            .day => "days.log",
        };
    }

    pub fn fileKind(self: Tier) FileKind {
        return switch (self) {
            .minute => .ring,
            .hour, .day => .append,
        };
    }
};

pub const FileKind = enum(u8) { ring = 0, append = 1 };

/// `$XDG_STATE_HOME/token-tach/history`, or
/// `<home>/.local/state/token-tach/history` when the env var is
/// unset/blank — the same resolution `statefile.defaultPath` uses, so
/// history sits beside `tailers.json`. Caller owns the returned path.
pub fn defaultDir(
    allocator: Allocator,
    env_xdg_state_home: ?[]const u8,
    home: []const u8,
) ![]u8 {
    if (env_xdg_state_home) |raw| {
        const base = std.mem.trim(u8, raw, " \t");
        if (base.len > 0) {
            return std.fs.path.join(allocator, &.{ base, "token-tach", "history" });
        }
    }
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "token-tach", "history" });
}

// ---------------------------------------------------------------------------
// Bucket arithmetic
// ---------------------------------------------------------------------------

/// UTC minutes since the epoch. Pre-epoch timestamps clamp to 0 rather
/// than wrapping: a bogus 1969 timestamp should land in a visibly wrong
/// bucket, not in a random one 4 billion minutes away.
pub fn minuteBucket(ts_ms: i64) u32 {
    return clampBucket(@divFloor(ts_ms, 60_000));
}

/// UTC hours since the epoch.
pub fn hourBucket(ts_ms: i64) u32 {
    return clampBucket(@divFloor(ts_ms, 3_600_000));
}

/// LOCAL days since the epoch, using the same key function the ledger's
/// `per_day` uses so the two agree bucket-for-bucket.
pub fn dayBucket(ts_ms: i64, tz_offset_min: i32) u32 {
    return clampBucket(ledger_mod.dayKey(ts_ms, tz_offset_min));
}

fn clampBucket(v: i64) u32 {
    if (v <= 0) return 0;
    if (v >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

fn bucketStartMs(tier: Tier, bucket: u32, tz_offset_min: i32) i64 {
    const b: i64 = bucket;
    return switch (tier) {
        .minute => b * 60_000,
        .hour => b * 3_600_000,
        .day => b * 86_400_000 - @as(i64, tz_offset_min) * 60_000,
    };
}

fn hourOfMinute(minute: u32) u32 {
    return minute / 60;
}

fn dayOfMinute(minute: u32, tz_offset_min: i32) u32 {
    return dayBucket(@as(i64, minute) * 60_000, tz_offset_min);
}

// ---------------------------------------------------------------------------
// On-disk structures
// ---------------------------------------------------------------------------

/// One 64-byte row. `extern` so the field order IS the byte layout; the
/// comptime block below is the contract test that keeps it that way.
pub const Record = extern struct {
    /// Index in the file's unit (UTC minute/hour, local day).
    bucket: u32 = 0,
    /// `types.Agent.storageId()` value, or `synthetic_agent_id`.
    agent: u8 = 0,
    /// `flag_covered` | `flag_delta` | `flag_synthetic`.
    flags: u8 = 0,
    /// Low 16 bits of crc32 over the record with this field zeroed.
    check: u16 = 0,
    model_id: u32 = 0,
    project_id: u32 = 0,
    session_id: u32 = 0,
    events: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    /// `@bitCast` of the f64 — an exact round-trip, not a
    /// shortest-round-trip one. `statefile` stores costs the same way.
    /// May be negative when `flag_delta` is set (a correction).
    cost_usd_bits: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Record) == record_size);
        std.debug.assert(@offsetOf(Record, "bucket") == 0);
        std.debug.assert(@offsetOf(Record, "agent") == 4);
        std.debug.assert(@offsetOf(Record, "flags") == 5);
        std.debug.assert(@offsetOf(Record, "check") == 6);
        std.debug.assert(@offsetOf(Record, "model_id") == 8);
        std.debug.assert(@offsetOf(Record, "project_id") == 12);
        std.debug.assert(@offsetOf(Record, "session_id") == 16);
        std.debug.assert(@offsetOf(Record, "events") == 20);
        std.debug.assert(@offsetOf(Record, "input_tokens") == 24);
        std.debug.assert(@offsetOf(Record, "output_tokens") == 32);
        std.debug.assert(@offsetOf(Record, "cache_creation_tokens") == 40);
        std.debug.assert(@offsetOf(Record, "cache_read_tokens") == 48);
        std.debug.assert(@offsetOf(Record, "cost_usd_bits") == 56);
    }

    pub fn costUsd(self: Record) f64 {
        return @bitCast(self.cost_usd_bits);
    }

    pub fn covered(self: Record) bool {
        return self.flags & flag_covered != 0;
    }

    fn computeCheck(self: Record) u16 {
        var copy = self;
        copy.check = 0;
        return @truncate(Crc32.hash(std.mem.asBytes(&copy)));
    }

    pub fn valid(self: Record) bool {
        return self.computeCheck() == self.check;
    }

    /// Serialize with the checksum filled in.
    fn sealed(self: Record) [record_size]u8 {
        var copy = self;
        copy.check = 0;
        copy.check = copy.computeCheck();
        return std.mem.toBytes(copy);
    }

    /// Decode 64 bytes, returning null when the checksum fails. Uses
    /// `bytesToValue` (align-1) rather than an `@alignCast` of a file
    /// buffer, so a torn or misaligned file can never fault us — the
    /// worst outcome is a rejected record. Note that an all-zero slot
    /// fails this check naturally (crc32 of 64 zeros is not 0), which is
    /// how never-written ring slots get skipped for free.
    fn decode(bytes: []const u8) ?Record {
        if (bytes.len < record_size) return null;
        const rec = std.mem.bytesToValue(Record, bytes[0..record_size]);
        if (!rec.valid()) return null;
        return rec;
    }
};

/// 64-byte file header. `header_crc32` covers bytes [0, 60).
pub const Header = extern struct {
    magic: [8]u8 = tier_magic,
    format_version: u32 = format_version,
    /// `Tier` as an integer.
    bucket_unit: u8 = 0,
    record_size: u8 = @intCast(record_size),
    /// `FileKind` as an integer.
    file_kind: u8 = 0,
    /// Which dimensions this file carries: bit0 model, bit1 project,
    /// bit2 session, bit3 agent. Present so a future slimmer tier can
    /// declare it drops a dimension instead of silently zeroing it.
    dim_mask: u8 = 0b1111,
    /// Ring slot count; 0 for append tiers.
    capacity_records: u32 = 0,
    /// `dict.log`'s generation. A mismatch means the ids in this file
    /// refer to a dictionary that no longer exists.
    dict_generation: u32 = 0,
    /// ADVISORY. A crash between a ring slot write and this field's
    /// update leaves it low; readers must not trust it. See `Reader`.
    records_written: u64 = 0,
    created_ms: i64 = 0,
    /// Only meaningful for `days.log` (see the module doc on time).
    tz_offset_min: i32 = 0,
    reserved: [16]u8 = @splat(0),
    header_crc32: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Header) == header_size);
        std.debug.assert(@offsetOf(Header, "capacity_records") == 16);
        std.debug.assert(@offsetOf(Header, "records_written") == 24);
        std.debug.assert(@offsetOf(Header, "created_ms") == 32);
        std.debug.assert(@offsetOf(Header, "tz_offset_min") == 40);
        std.debug.assert(@offsetOf(Header, "header_crc32") == 60);
    }

    fn computeCrc(self: Header) u32 {
        var copy = self;
        copy.header_crc32 = 0;
        return Crc32.hash(std.mem.asBytes(&copy)[0..60]);
    }

    fn sealed(self: Header) [header_size]u8 {
        var copy = self;
        copy.header_crc32 = copy.computeCrc();
        return std.mem.toBytes(copy);
    }

    /// Structural validation. `dict_generation` is checked separately by
    /// the caller because a reader with no dictionary at all deliberately
    /// tolerates any generation (see `Reader.open`).
    fn ok(self: Header, tier: Tier) bool {
        if (!std.mem.eql(u8, &self.magic, &tier_magic)) return false;
        if (self.format_version != format_version) return false;
        if (self.record_size != record_size) return false;
        if (self.bucket_unit != @intFromEnum(tier)) return false;
        if (self.file_kind != @intFromEnum(tier.fileKind())) return false;
        if (self.computeCrc() != self.header_crc32) return false;
        if (tier.fileKind() == .ring and self.capacity_records == 0) return false;
        return true;
    }

    fn parse(bytes: []const u8) ?Header {
        if (bytes.len < header_size) return null;
        return std.mem.bytesToValue(Header, bytes[0..header_size]);
    }
};

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

extern fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

fn setMode(path: []const u8, mode: c_uint) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = chmod(@ptrCast(&buf), mode);
}

const PathBuf = struct {
    bytes: [std.fs.max_path_bytes]u8 = undefined,

    fn join(self: *PathBuf, dir: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.bytes, "{s}/{s}", .{ dir, name });
    }
};

/// Rename a structurally broken file aside instead of deleting it. This
/// store is truth: a corrupt header may sit in front of months of
/// perfectly readable records that a human (or a later recovery tool)
/// can still salvage.
fn quarantine(io: std.Io, dir: []const u8, name: []const u8, now_ms: i64) void {
    var from: PathBuf = .{};
    var to: PathBuf = .{};
    const src = from.join(dir, name) catch return;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bad = std.fmt.bufPrint(&name_buf, "{s}.bad.{d}", .{ name, now_ms }) catch return;
    const dst = to.join(dir, bad) catch return;
    var cwd = std.Io.Dir.cwd();
    cwd.rename(src, cwd, dst, io) catch |err| {
        std.log.warn("history: could not quarantine {s}: {s}", .{ name, @errorName(err) });
    };
}

fn openOrCreate(io: std.Io, path: []const u8) !std.Io.File {
    var cwd = std.Io.Dir.cwd();
    if (cwd.openFile(io, path, .{ .mode = .read_write })) |file| {
        return file;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    const file = try cwd.createFile(io, path, .{
        .read = true,
        .truncate = false,
        .permissions = .fromMode(0o600),
    });
    setMode(path, 0o600);
    return file;
}

// ---------------------------------------------------------------------------
// Dictionary
// ---------------------------------------------------------------------------

/// Append-only string table shared by every tier.
///
/// Ids start at 1 (0 means "none" in a record) and are NEVER reassigned:
/// an id in a five-year-old record must still name the same project.
/// The tail is self-healing — a truncated or bad-CRC entry ends the walk
/// and (writer only) truncates the file back to the last good entry, so
/// a crash mid-append costs at most one string, never the table.
const Dict = struct {
    arena: std.heap.ArenaAllocator,
    /// Key is a one-byte kind tag followed by the string, so a model and
    /// a project may share a name without sharing an id.
    map: std.StringHashMapUnmanaged(u32) = .empty,
    /// id -> string, indexed by `id - 1`. Sparse ids never happen (we
    /// hand them out densely), but a gap would only cost a dangling name.
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    generation: u32 = 0,
    next_id: u32 = 1,
    file: ?std.Io.File = null,
    end_offset: u64 = 0,
    dirty: bool = false,

    fn init(allocator: Allocator) Dict {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *Dict, io: std.Io) void {
        if (self.file) |f| f.close(io);
        self.file = null;
        const gpa = self.arena.child_allocator;
        self.map.deinit(gpa);
        self.names.deinit(gpa);
        self.arena.deinit();
    }

    fn lookup(self: *const Dict, id: u32) ?[]const u8 {
        if (id == 0 or id > self.names.items.len) return null;
        const s = self.names.items[id - 1];
        return if (s.len == 0) null else s;
    }

    fn remember(self: *Dict, kind: u8, id: u32, payload: []const u8) !void {
        const gpa = self.arena.child_allocator;
        const a = self.arena.allocator();
        const key = try a.alloc(u8, payload.len + 1);
        key[0] = kind;
        @memcpy(key[1..], payload);
        const value = key[1..];
        try self.map.put(gpa, key, id);
        while (self.names.items.len < id) try self.names.append(gpa, "");
        self.names.items[id - 1] = value;
        if (id >= self.next_id) self.next_id = id + 1;
    }

    /// Walk `bytes` (a whole `dict.log`), returning the offset just past
    /// the last good entry, or null when the header itself is unusable.
    fn load(self: *Dict, bytes: []const u8) !?u64 {
        const head = bytes;
        if (head.len < dict_header_size) return null;
        if (!std.mem.eql(u8, head[0..8], &dict_magic)) return null;
        if (std.mem.bytesToValue(u32, head[8..12]) != dict_format_version) return null;
        var crc_copy: [dict_header_size]u8 = undefined;
        @memcpy(&crc_copy, head[0..dict_header_size]);
        @memset(crc_copy[28..32], 0);
        if (Crc32.hash(crc_copy[0..28]) != std.mem.bytesToValue(u32, head[28..32])) return null;

        self.generation = std.mem.bytesToValue(u32, head[12..16]);

        var off: usize = dict_header_size;
        while (off + dict_entry_header_size <= bytes.len) {
            const id = std.mem.bytesToValue(u32, bytes[off..][0..4]);
            const len = std.mem.bytesToValue(u16, bytes[off + 4 ..][0..2]);
            const kind = bytes[off + 6];
            const crc = std.mem.bytesToValue(u32, bytes[off + 8 ..][0..4]);
            const padded = std.mem.alignForward(usize, len, 4);
            const total = dict_entry_header_size + padded;
            if (off + total > bytes.len) break; // torn tail
            if (id == 0) break;
            const payload = bytes[off + dict_entry_header_size ..][0..len];
            if (Crc32.hash(payload) != crc) break; // bad-CRC tail
            try self.remember(kind, id, payload);
            off += total;
        }
        return off;
    }

    /// Intern `s`, appending it to `dict.log` if new. Returns 0 for the
    /// empty string ("none"). The append is written immediately but
    /// fsync'd by `sync`, which every flush path calls BEFORE writing any
    /// record — see the module doc on durability ordering.
    fn intern(self: *Dict, io: std.Io, kind: u8, s: []const u8) !u32 {
        if (s.len == 0) return 0;
        // A string longer than u16 is not a real model/project/session
        // name; store a prefix rather than refusing the whole record.
        const payload = s[0..@min(s.len, std.math.maxInt(u16))];

        var key_buf: [512]u8 = undefined;
        var key_heap: ?[]u8 = null;
        defer if (key_heap) |k| self.arena.child_allocator.free(k);
        const key = blk: {
            if (payload.len + 1 <= key_buf.len) {
                key_buf[0] = kind;
                @memcpy(key_buf[1 .. payload.len + 1], payload);
                break :blk key_buf[0 .. payload.len + 1];
            }
            const k = try self.arena.child_allocator.alloc(u8, payload.len + 1);
            key_heap = k;
            k[0] = kind;
            @memcpy(k[1..], payload);
            break :blk k;
        };
        if (self.map.get(key)) |id| return id;

        const id = self.next_id;
        const file = self.file orelse {
            // Read-only dictionary: never mint ids we cannot persist.
            return 0;
        };

        const padded = std.mem.alignForward(usize, payload.len, 4);
        var head: [dict_entry_header_size]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], id, .little);
        std.mem.writeInt(u16, head[4..6], @intCast(payload.len), .little);
        head[6] = kind;
        head[7] = 0;
        std.mem.writeInt(u32, head[8..12], Crc32.hash(payload), .little);

        try file.writePositionalAll(io, &head, self.end_offset);
        try file.writePositionalAll(io, payload, self.end_offset + dict_entry_header_size);
        if (padded > payload.len) {
            const pad = [_]u8{0} ** 4;
            try file.writePositionalAll(
                io,
                pad[0 .. padded - payload.len],
                self.end_offset + dict_entry_header_size + payload.len,
            );
        }
        self.end_offset += dict_entry_header_size + padded;
        self.dirty = true;

        try self.remember(kind, id, payload);
        return id;
    }

    fn sync(self: *Dict, io: std.Io) !void {
        if (!self.dirty) return;
        if (self.file) |f| try f.sync(io);
        self.dirty = false;
    }
};

fn freshDictHeader(generation: u32) [dict_header_size]u8 {
    var buf: [dict_header_size]u8 = @splat(0);
    @memcpy(buf[0..8], &dict_magic);
    std.mem.writeInt(u32, buf[8..12], dict_format_version, .little);
    std.mem.writeInt(u32, buf[12..16], generation, .little);
    std.mem.writeInt(u32, buf[16..20], 1, .little); // next_id: advisory only
    std.mem.writeInt(u32, buf[28..32], Crc32.hash(buf[0..28]), .little);
    return buf;
}

/// A fresh dictionary gets a generation derived from its creation time,
/// so a REBUILT dictionary never collides with the one it replaced.
/// Tier files stamped with the old generation then fail their header
/// check and are quarantined instead of being read with ids that now
/// mean something else.
fn newGeneration(now_ms: i64) u32 {
    const g: u32 = @truncate(@as(u64, @bitCast(now_ms)));
    return if (g == 0) 1 else g;
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

/// Staging key. Every dimension the record carries participates, so two
/// events differing only in session stay separate rows.
const Key = struct {
    bucket: u32,
    agent: u8,
    flags: u8,
    model_id: u32,
    project_id: u32,
    session_id: u32,
};

const Acc = struct {
    events: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cost_usd: f64 = 0,

    fn addRecord(self: *Acc, rec: Record) void {
        self.events += rec.events;
        self.input_tokens += rec.input_tokens;
        self.output_tokens += rec.output_tokens;
        self.cache_creation_tokens += rec.cache_creation_tokens;
        self.cache_read_tokens += rec.cache_read_tokens;
        self.cost_usd += rec.costUsd();
    }

    fn toRecord(self: Acc, key: Key) Record {
        return .{
            .bucket = key.bucket,
            .agent = key.agent,
            .flags = key.flags,
            .model_id = key.model_id,
            .project_id = key.project_id,
            .session_id = key.session_id,
            .events = @intCast(@min(self.events, std.math.maxInt(u32))),
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_creation_tokens = self.cache_creation_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cost_usd_bits = @bitCast(self.cost_usd),
        };
    }
};

/// One tier's open accumulator. `open_bucket` is the bucket currently
/// receiving writes; crossing it is what triggers a flush.
const Stage = struct {
    open_bucket: ?u32 = null,
    rows: std.AutoArrayHashMapUnmanaged(Key, Acc) = .empty,

    fn deinit(self: *Stage, allocator: Allocator) void {
        self.rows.deinit(allocator);
        self.rows = .empty;
    }

    fn add(self: *Stage, allocator: Allocator, key: Key, rec: Record) !void {
        const gop = try self.rows.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.addRecord(rec);
    }
};

const TierFile = struct {
    file: ?std.Io.File = null,
    header: Header = .{},
    /// Append tiers: byte offset of the next record.
    end_offset: u64 = 0,
    /// Ring: monotonically increasing write counter; `% capacity` is the slot.
    records_written: u64 = 0,
    capacity: u32 = 0,
    dirty: bool = false,
};

pub const RecordOptions = struct {
    cost_usd: ?f64 = null,
    /// Subscription-covered spend. Null derives it from the agent
    /// (`Agent.hasLimitsPanel`), matching `ledger.covered_per_day`.
    covered: ?bool = null,
    /// The cost may be negative: this row corrects an earlier one.
    delta: bool = false,
    /// Not observed from a transcript (import, manual entry).
    synthetic: bool = false,
    /// Override the stored agent id — pass `synthetic_agent_id` for rows
    /// with no real producer.
    agent_storage_id: ?u8 = null,
    /// Wall clock, for the hot-tier age gate. Required rather than read
    /// from the system here: `src/core` modules take their clock from the
    /// caller so every one of them stays deterministic under test.
    now_ms: i64,
};

pub const OpenOptions = struct {
    /// The offset `days.log` keys are computed with; stamped into its
    /// header so a later reader at a different offset can say so.
    tz_offset_min: i32 = 0,
    hot_capacity: u32 = default_hot_capacity,
    /// Wall clock; see `RecordOptions.now_ms`.
    now_ms: i64,
    /// Run the (at most one per launch) compaction check on hours/days.
    compact_on_open: bool = true,
};

/// The single-writer front end. Construct one per process; a second one
/// finds `.lock` held and comes up inert.
pub const Writer = struct {
    allocator: Allocator,
    io: std.Io,
    dir: []u8,
    /// False means every `record` call is a no-op. Set at open (lock
    /// contention, unusable directory) or on the first I/O failure.
    enabled: bool = false,
    lock_file: ?std.Io.File = null,
    dict: Dict,
    tz_offset_min: i32,
    tiers: [3]TierFile = .{ .{}, .{}, .{} },
    stages: [3]Stage = .{ .{}, .{}, .{} },
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    last_now_ms: i64 = 0,
    /// `open` may shut itself down before returning a disabled writer;
    /// the caller's `defer deinit()` must then be a no-op, not a
    /// double free.
    closed: bool = false,

    /// Open (creating as needed) the history directory and every tier.
    ///
    /// Never fails for I/O reasons — an unusable store yields a disabled
    /// writer, which is the whole point of the failure policy. Only
    /// allocation failure escapes.
    pub fn open(
        allocator: Allocator,
        io: std.Io,
        dir: []const u8,
        opts: OpenOptions,
    ) error{OutOfMemory}!Writer {
        var self = Writer{
            .allocator = allocator,
            .io = io,
            .dir = try allocator.dupe(u8, dir),
            .dict = Dict.init(allocator),
            .tz_offset_min = opts.tz_offset_min,
            .last_now_ms = opts.now_ms,
        };
        self.bringUp(opts) catch |err| {
            if (err == error.OutOfMemory) {
                self.shutdown();
                return error.OutOfMemory;
            }
            std.log.warn("history: disabled ({s})", .{@errorName(err)});
            self.shutdown();
            return self;
        };
        return self;
    }

    fn bringUp(self: *Writer, opts: OpenOptions) !void {
        var cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, self.dir) catch {};
        setMode(self.dir, 0o700);

        // The ring is a pwrite at a computed offset, not an append, so
        // two writers do not interleave harmlessly — they overwrite each
        // other's slots. The lock is not optional.
        var lock_path: PathBuf = .{};
        const lp = try lock_path.join(self.dir, ".lock");
        const lock_file = try openOrCreate(self.io, lp);
        errdefer lock_file.close(self.io);
        if (!try lock_file.tryLock(self.io, .exclusive)) return error.WouldBlock;
        self.lock_file = lock_file;

        try self.openDict(opts);
        if (opts.compact_on_open) {
            _ = maybeCompact(self.allocator, self.io, self.dir, .hour, self.dict.generation);
            _ = maybeCompact(self.allocator, self.io, self.dir, .day, self.dict.generation);
        }
        for ([_]Tier{ .minute, .hour, .day }) |tier| try self.openTier(tier, opts);
        self.enabled = true;
    }

    fn openDict(self: *Writer, opts: OpenOptions) !void {
        var pb: PathBuf = .{};
        const path = try pb.join(self.dir, "dict.log");
        var cwd = std.Io.Dir.cwd();

        const existing: ?[]u8 = cwd.readFileAlloc(self.io, path, self.allocator, .limited(max_dict_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (existing) |b| self.allocator.free(b);

        var end: ?u64 = null;
        if (existing) |bytes| end = try self.dict.load(bytes);
        if (end == null and existing != null) {
            quarantine(self.io, self.dir, "dict.log", self.last_now_ms);
        }

        const file = try openOrCreate(self.io, path);
        self.dict.file = file;
        if (end) |e| {
            self.dict.end_offset = e;
            // Drop any torn tail so the next append lands on a clean
            // boundary; the strings it named are simply re-interned.
            if (e != try file.length(self.io)) try file.setLength(self.io, e);
        } else {
            self.dict.generation = newGeneration(self.last_now_ms);
            const head = freshDictHeader(self.dict.generation);
            try file.setLength(self.io, 0);
            try file.writePositionalAll(self.io, &head, 0);
            try file.sync(self.io);
            self.dict.end_offset = dict_header_size;
        }
        _ = opts;
    }

    fn openTier(self: *Writer, tier: Tier, opts: OpenOptions) !void {
        const idx = @intFromEnum(tier);
        var pb: PathBuf = .{};
        const path = try pb.join(self.dir, tier.fileName());
        var file = try openOrCreate(self.io, path);
        errdefer file.close(self.io);

        var head_buf: [header_size]u8 = undefined;
        const len = try file.length(self.io);
        var header: ?Header = null;
        if (len >= header_size) {
            const n = try file.readPositionalAll(self.io, &head_buf, 0);
            if (n == header_size) {
                if (Header.parse(&head_buf)) |h| {
                    if (h.ok(tier) and h.dict_generation == self.dict.generation) header = h;
                }
            }
        }

        if (header == null and len != 0) {
            file.close(self.io);
            quarantine(self.io, self.dir, tier.fileName(), self.last_now_ms);
            file = try openOrCreate(self.io, path);
        }

        var t = &self.tiers[idx];
        if (header) |h| {
            t.header = h;
            t.capacity = h.capacity_records;
            t.records_written = h.records_written;
            // Append tiers: snap past any torn tail. A partial record is
            // meaningless and would misalign every record after it.
            const cur_len = try file.length(self.io);
            const body = cur_len -| header_size;
            const aligned = header_size + (body / record_size) * record_size;
            t.end_offset = aligned;
            if (tier.fileKind() == .append and aligned != cur_len) {
                try file.setLength(self.io, aligned);
            }
        } else {
            t.header = .{
                .bucket_unit = @intFromEnum(tier),
                .file_kind = @intFromEnum(tier.fileKind()),
                .capacity_records = if (tier.fileKind() == .ring) opts.hot_capacity else 0,
                .dict_generation = self.dict.generation,
                .created_ms = self.last_now_ms,
                .tz_offset_min = if (tier == .day) self.tz_offset_min else 0,
            };
            t.capacity = t.header.capacity_records;
            t.records_written = 0;
            t.end_offset = header_size;
            try file.setLength(self.io, 0);
            const sealed = t.header.sealed();
            try file.writePositionalAll(self.io, &sealed, 0);
            try file.sync(self.io);
        }
        t.file = file;
        // days.log keys are only interpretable with the offset they were
        // written at; adopt the file's rather than re-keying history.
        if (tier == .day) self.tz_offset_min = t.header.tz_offset_min;
    }

    pub fn deinit(self: *Writer) void {
        if (self.enabled) self.flush();
        self.shutdown();
    }

    fn shutdown(self: *Writer) void {
        if (self.closed) return;
        self.closed = true;
        self.enabled = false;
        for (&self.tiers) |*t| {
            if (t.file) |f| f.close(self.io);
            t.file = null;
        }
        for (&self.stages) |*s| s.deinit(self.allocator);
        self.dict.deinit(self.io);
        if (self.lock_file) |f| {
            f.unlock(self.io);
            f.close(self.io);
            self.lock_file = null;
        }
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.dir = &.{};
    }

    fn disable(self: *Writer, err: anyerror) void {
        if (!self.enabled) return;
        std.log.warn("history: writer disabled after {s}; collection continues", .{@errorName(err)});
        self.enabled = false;
        for (&self.tiers) |*t| {
            if (t.file) |f| f.close(self.io);
            t.file = null;
        }
        if (self.dict.file) |f| f.close(self.io);
        self.dict.file = null;
    }

    /// Stage one priced event. Zero I/O in the common case: the event
    /// folds into the open minute accumulator and reaches disk only when
    /// the minute rolls over.
    ///
    /// Never returns an error, by design — see the module doc.
    pub fn record(self: *Writer, ev: types.UsageEvent, opts: RecordOptions) void {
        if (!self.enabled) return;
        self.recordInner(ev, opts) catch |err| self.disable(err);
    }

    fn recordInner(self: *Writer, ev: types.UsageEvent, opts: RecordOptions) !void {
        const now = opts.now_ms;
        if (now > self.last_now_ms) self.last_now_ms = now;

        var flags: u8 = 0;
        if (opts.covered orelse ev.agent.hasLimitsPanel()) flags |= flag_covered;
        if (opts.delta) flags |= flag_delta;
        if (opts.synthetic) flags |= flag_synthetic;

        const model_id = try self.dict.intern(self.io, dict_kind_model, ev.model);
        // The repository root, not the raw cwd: `--group project` and
        // `--project` are meant to answer "what did this repo cost", and a
        // worktree is the same repo. Rows written before this existed keep
        // their per-worktree ids — the dictionary is append-only and ids
        // are never reassigned (see the invariant above), so history from
        // before the change stays split and is not rewritten.
        const project_id = try self.dict.intern(self.io, dict_kind_project, ev.projectKey());
        const session_id = try self.dict.intern(self.io, dict_kind_session, ev.session_id);

        const rec = Record{
            .agent = opts.agent_storage_id orelse ev.agent.storageId(),
            .flags = flags,
            .model_id = model_id,
            .project_id = project_id,
            .session_id = session_id,
            .events = 1,
            .input_tokens = ev.input_tokens,
            .output_tokens = ev.output_tokens,
            .cache_creation_tokens = ev.cache_creation_tokens,
            .cache_read_tokens = ev.cache_read_tokens,
            .cost_usd_bits = @bitCast(opts.cost_usd orelse 0),
        };

        const minute = minuteBucket(ev.timestamp_ms);
        if (self.stages[0].open_bucket) |open_minute| {
            if (minute < open_minute) {
                // Backfill: an event older than the open bucket. Writing
                // it straight through with its TRUE bucket is correct
                // precisely because records are additive — no reopening,
                // no merge, no reordering.
                try self.writeBackfill(rec, minute);
                return;
            }
            if (minute > open_minute) try self.roll(minute);
        } else {
            self.stages[0].open_bucket = minute;
            self.stages[1].open_bucket = hourOfMinute(minute);
            self.stages[2].open_bucket = dayOfMinute(minute, self.tz_offset_min);
        }

        var key = keyOf(rec);
        key.bucket = minute;
        try self.stages[0].add(self.allocator, key, rec);
    }

    fn keyOf(rec: Record) Key {
        return .{
            .bucket = rec.bucket,
            .agent = rec.agent,
            .flags = rec.flags,
            .model_id = rec.model_id,
            .project_id = rec.project_id,
            .session_id = rec.session_id,
        };
    }

    /// Close the open minute (and, if they changed too, the open hour
    /// and day) and reopen at `minute`.
    fn roll(self: *Writer, minute: u32) !void {
        try self.flushMinute();
        self.stages[0].open_bucket = minute;

        const hour = hourOfMinute(minute);
        if (self.stages[1].open_bucket) |open_hour| {
            if (hour > open_hour) try self.flushTier(.hour);
        }
        self.stages[1].open_bucket = hour;

        const day = dayOfMinute(minute, self.tz_offset_min);
        if (self.stages[2].open_bucket) |open_day| {
            if (day > open_day) try self.flushTier(.day);
        }
        self.stages[2].open_bucket = day;
    }

    /// Push everything staged to disk. Safe to call at any time (a
    /// timer, quit, or before a statefile save); an early flush only
    /// creates more additive records, never a different answer.
    pub fn flush(self: *Writer) void {
        if (!self.enabled) return;
        self.flushAll() catch |err| self.disable(err);
    }

    fn flushAll(self: *Writer) !void {
        try self.flushMinute();
        try self.flushTier(.hour);
        try self.flushTier(.day);
    }

    /// Close the minute accumulator: its rows go to the ring (subject to
    /// the age gate) AND fold into the hour and day accumulators. Events
    /// only ever enter the minute stage, so folding here is the sole path
    /// into the coarser tiers and cannot double-count.
    fn flushMinute(self: *Writer) !void {
        const stage = &self.stages[0];
        if (stage.rows.count() == 0) return;
        try self.dict.sync(self.io);

        const t = &self.tiers[0];
        const gate_ms = self.last_now_ms - hot_max_age_ms;
        var wrote_ring = false;
        for (stage.rows.keys(), stage.rows.values()) |key, acc| {
            const rec = acc.toRecord(key);

            if (t.file != null and bucketStartMs(.minute, key.bucket, 0) >= gate_ms) {
                const bytes = rec.sealed();
                const slot = t.records_written % t.capacity;
                try t.file.?.writePositionalAll(
                    self.io,
                    &bytes,
                    header_size + slot * record_size,
                );
                t.records_written += 1;
                wrote_ring = true;
            }

            var hour_key = key;
            hour_key.bucket = hourOfMinute(key.bucket);
            try self.stages[1].add(self.allocator, hour_key, rec);

            var day_key = key;
            day_key.bucket = dayOfMinute(key.bucket, self.tz_offset_min);
            try self.stages[2].add(self.allocator, day_key, rec);
        }
        stage.rows.clearRetainingCapacity();

        if (wrote_ring) {
            // Header last, once per batch. A crash in between leaves
            // records_written LOW, which would make a trusting reader
            // miss slots it already has — so the reader does not trust
            // it (see `Reader`). The real blast radius of a crash here
            // is at most re-using slots for minutes already folded into
            // hours/days, i.e. the hot tier loses a little recent detail
            // that the durable tiers still hold.
            t.header.records_written = t.records_written;
            const head = t.header.sealed();
            try t.file.?.writePositionalAll(self.io, &head, 0);
            try t.file.?.sync(self.io);
        }
    }

    fn flushTier(self: *Writer, tier: Tier) !void {
        const idx = @intFromEnum(tier);
        const stage = &self.stages[idx];
        if (stage.rows.count() == 0) return;
        const t = &self.tiers[idx];
        const file = t.file orelse {
            stage.rows.clearRetainingCapacity();
            return;
        };
        try self.dict.sync(self.io);

        self.scratch.clearRetainingCapacity();
        for (stage.rows.keys(), stage.rows.values()) |key, acc| {
            const bytes = acc.toRecord(key).sealed();
            try self.scratch.appendSlice(self.allocator, &bytes);
        }
        stage.rows.clearRetainingCapacity();

        try file.writePositionalAll(self.io, self.scratch.items, t.end_offset);
        t.end_offset += self.scratch.items.len;
        t.records_written += self.scratch.items.len / record_size;
        t.header.records_written = t.records_written;
        const head = t.header.sealed();
        try file.writePositionalAll(self.io, &head, 0);
        // One fsync per flush batch, never per record.
        try file.sync(self.io);
    }

    /// A single out-of-order event, written straight through at its true
    /// buckets without disturbing the open accumulators.
    fn writeBackfill(self: *Writer, rec: Record, minute: u32) !void {
        try self.dict.sync(self.io);

        const gate_ms = self.last_now_ms - hot_max_age_ms;
        if (self.tiers[0].file) |file| {
            if (bucketStartMs(.minute, minute, 0) >= gate_ms) {
                var hot = rec;
                hot.bucket = minute;
                const bytes = hot.sealed();
                const t = &self.tiers[0];
                const slot = t.records_written % t.capacity;
                try file.writePositionalAll(self.io, &bytes, header_size + slot * record_size);
                t.records_written += 1;
                t.header.records_written = t.records_written;
                const head = t.header.sealed();
                try file.writePositionalAll(self.io, &head, 0);
                try file.sync(self.io);
            }
        }

        try self.appendOne(.hour, rec, hourOfMinute(minute));
        try self.appendOne(.day, rec, dayOfMinute(minute, self.tz_offset_min));
    }

    fn appendOne(self: *Writer, tier: Tier, rec: Record, bucket: u32) !void {
        const t = &self.tiers[@intFromEnum(tier)];
        const file = t.file orelse return;
        var out = rec;
        out.bucket = bucket;
        const bytes = out.sealed();
        try file.writePositionalAll(self.io, &bytes, t.end_offset);
        t.end_offset += record_size;
        t.records_written += 1;
        t.header.records_written = t.records_written;
        const head = t.header.sealed();
        try file.writePositionalAll(self.io, &head, 0);
        try file.sync(self.io);
    }

    /// The dictionary generation this writer's files are stamped with.
    pub fn dictGeneration(self: *const Writer) u32 {
        return self.dict.generation;
    }
};

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

pub const GroupBy = packed struct {
    bucket: bool = false,
    agent: bool = false,
    model: bool = false,
    project: bool = false,
    session: bool = false,

    pub const none: GroupBy = .{};
    pub const by_bucket: GroupBy = .{ .bucket = true };
};

pub const Filter = struct {
    /// Inclusive bucket range in the tier's own unit.
    from_bucket: u32 = 0,
    to_bucket: u32 = std.math.maxInt(u32),
    /// Null means every agent, including ids this build cannot name.
    /// A non-null set can only select KNOWN agents, so unknown-id rows
    /// are excluded — say so in any UI that offers the filter.
    agents: ?std.EnumSet(types.Agent) = null,
    /// 0 means "any"; there is deliberately no way to select rows whose
    /// dimension is absent, because "no model" is not a useful cohort.
    model_id: u32 = 0,
    project_id: u32 = 0,
    session_id: u32 = 0,
    covered_only: bool = false,
};

pub const Row = struct {
    /// Zero unless grouped by bucket.
    bucket: u32 = 0,
    /// Storage id (see `agentName`); zero unless grouped by agent.
    agent: u8 = 0,
    model_id: u32 = 0,
    project_id: u32 = 0,
    session_id: u32 = 0,
    /// The offset the DAY tier's buckets were keyed with (0 for the
    /// minute/hour tiers, which are UTC). A caller running at a
    /// different offset must display this, not re-bucket by it.
    tz_offset_min: i32 = 0,
    totals: ledger_mod.Totals = .{},
    /// Subscription-covered slice of `totals.cost_usd`.
    covered_cost_usd: f64 = 0,
    /// How many physical records fed this row — the duplicate-key
    /// pressure that compaction relieves.
    records: u64 = 0,
};

pub const Extent = struct {
    first_bucket: ?u32 = null,
    last_bucket: ?u32 = null,
    records: u64 = 0,
    bytes: u64 = 0,
    tz_offset_min: i32 = 0,
    present: bool = false,
};

pub const Extents = struct {
    minute: Extent = .{},
    hour: Extent = .{},
    day: Extent = .{},

    pub fn get(self: Extents, tier: Tier) Extent {
        return switch (tier) {
            .minute => self.minute,
            .hour => self.hour,
            .day => self.day,
        };
    }
};

pub const Dim = enum { agent, model, project, session };

pub const Burn = struct {
    window_min: u32,
    totals: ledger_mod.Totals = .{},
    tokens_per_min: f64 = 0,
    cost_per_min: f64 = 0,
};

/// Read-only view of a history directory.
///
/// Opens WITHOUT the writer lock — a CLI or dashboard query must never
/// be able to stall or displace the collecting process.
///
/// # Scanning
///
/// Every query is ONE bounded read of the tier plus a linear scan
/// decoding 64 bytes at a time. There is no binary search and there must
/// never be one: records are ordered by FLUSH time, which is only
/// quasi-monotonic in bucket — a backfill batch or a late transcript
/// scan appends old buckets after new ones. Any future optimizer that
/// assumes sortedness will silently return partial answers.
///
/// The ring is scanned slot-by-slot over its full capacity and every
/// slot is CRC-validated; `records_written` in the header is IGNORED
/// because a crash between a slot write and the header update leaves it
/// stale. Never-written slots fail the CRC and drop out for free, and
/// the wrap point needs no detection at all: an additive reader does not
/// care what order the surviving slots are in.
pub const Reader = struct {
    allocator: Allocator,
    io: std.Io,
    dir: []u8,
    dict: Dict,

    pub fn open(allocator: Allocator, io: std.Io, dir: []const u8) error{OutOfMemory}!Reader {
        var self = Reader{
            .allocator = allocator,
            .io = io,
            .dir = try allocator.dupe(u8, dir),
            .dict = Dict.init(allocator),
        };
        var pb: PathBuf = .{};
        const path = pb.join(dir, "dict.log") catch return self;
        var cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(io, path, allocator, .limited(max_dict_bytes)) catch |err| switch (err) {
            error.OutOfMemory => {
                self.deinit();
                return error.OutOfMemory;
            },
            // No dictionary: every id reads back as `?id:<n>`. Rows are
            // still returned — unnameable spend is still spend.
            else => return self,
        };
        defer allocator.free(bytes);
        _ = self.dict.load(bytes) catch |err| switch (err) {
            error.OutOfMemory => {
                self.deinit();
                return error.OutOfMemory;
            },
        };
        return self;
    }

    pub fn deinit(self: *Reader) void {
        self.dict.deinit(self.io);
        self.allocator.free(self.dir);
        self.dir = &.{};
    }

    /// Resolve a dictionary id. A dangling id — one whose dictionary
    /// entry was lost to a crash before the record referencing it —
    /// renders `?id:<n>`, never a guess and never a dropped row.
    pub fn name(self: *const Reader, id: u32, buf: []u8) []const u8 {
        if (id == 0) return "";
        if (self.dict.lookup(id)) |s| return s;
        return std.fmt.bufPrint(buf, "?id:{d}", .{id}) catch "?id";
    }

    /// Look up a dictionary id by string, or 0 when this store has never
    /// seen it (which, as a `Filter` field, means "no constraint" — check
    /// for 0 before filtering on it).
    pub fn modelId(self: *const Reader, s: []const u8) u32 {
        return self.dictId(dict_kind_model, s);
    }

    pub fn projectId(self: *const Reader, s: []const u8) u32 {
        return self.dictId(dict_kind_project, s);
    }

    pub fn sessionId(self: *const Reader, s: []const u8) u32 {
        return self.dictId(dict_kind_session, s);
    }

    fn dictId(self: *const Reader, kind: u8, s: []const u8) u32 {
        if (s.len == 0) return 0;
        // Sized for the longest thing that can be interned (a cwd); a
        // string past it is not a path this store ever wrote.
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (s.len + 1 > buf.len) return 0;
        buf[0] = kind;
        @memcpy(buf[1 .. s.len + 1], s);
        return self.dict.map.get(buf[0 .. s.len + 1]) orelse 0;
    }

    /// The offset `days.log` was keyed with, or null when there is no
    /// day tier yet. A caller whose current offset differs must report
    /// the pair (bucket, offset) rather than re-bucketing: the day
    /// records no longer carry the timestamps a re-bucket would need.
    pub fn dayTzOffset(self: *Reader) ?i32 {
        const loaded = self.loadTier(.day) catch return null;
        defer if (loaded) |l| self.allocator.free(l.bytes);
        const l = loaded orelse return null;
        return l.header.tz_offset_min;
    }

    /// True when `days.log`'s keys were computed at a different UTC
    /// offset than the caller is running at now.
    pub fn dayTzMismatch(self: *Reader, current_offset_min: i32) bool {
        const stored = self.dayTzOffset() orelse return false;
        return stored != current_offset_min;
    }

    const Loaded = struct {
        bytes: []u8,
        header: Header,
        tier: Tier,
    };

    /// One bounded read of a tier, header-validated. Returns null for a
    /// missing or structurally broken file — a reader never quarantines
    /// (it holds no lock); the next writer launch does that.
    fn loadTier(self: *Reader, tier: Tier) !?Loaded {
        var pb: PathBuf = .{};
        const path = try pb.join(self.dir, tier.fileName());
        var cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(self.io, path, self.allocator, .limited(max_tier_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        errdefer self.allocator.free(bytes);
        const header = Header.parse(bytes) orelse {
            self.allocator.free(bytes);
            return null;
        };
        if (!header.ok(tier)) {
            self.allocator.free(bytes);
            return null;
        }
        // Generation is only enforced when we actually HAVE a dictionary
        // to be wrong about. With no dictionary every id is already
        // dangling, so there is no attribution left to get wrong and the
        // numbers are worth more than the names.
        if (self.dict.generation != 0 and header.dict_generation != self.dict.generation) {
            self.allocator.free(bytes);
            return null;
        }
        return Loaded{ .bytes = bytes, .header = header, .tier = tier };
    }

    fn matches(rec: Record, filter: Filter) bool {
        if (rec.bucket < filter.from_bucket or rec.bucket > filter.to_bucket) return false;
        if (filter.covered_only and !rec.covered()) return false;
        if (filter.model_id != 0 and rec.model_id != filter.model_id) return false;
        if (filter.project_id != 0 and rec.project_id != filter.project_id) return false;
        if (filter.session_id != 0 and rec.session_id != filter.session_id) return false;
        if (filter.agents) |set| {
            const agent = types.Agent.fromStorageId(rec.agent) orelse return false;
            if (!set.contains(agent)) return false;
        }
        return true;
    }

    /// Iterate the record region of a loaded tier. For the ring this is
    /// the full capacity (invalid slots simply fail the CRC).
    fn recordSpan(l: Loaded) struct { start: usize, count: usize } {
        const body = l.bytes.len -| header_size;
        var count = body / record_size;
        if (l.tier.fileKind() == .ring) count = @min(count, l.header.capacity_records);
        return .{ .start = header_size, .count = count };
    }

    /// Sum a tier into rows grouped by the requested dimensions. Caller
    /// owns the returned slice.
    pub fn query(
        self: *Reader,
        allocator: Allocator,
        tier: Tier,
        filter: Filter,
        group_by: GroupBy,
    ) ![]Row {
        const loaded = try self.loadTier(tier);
        const l = loaded orelse return allocator.alloc(Row, 0);
        defer self.allocator.free(l.bytes);

        var map: std.AutoArrayHashMapUnmanaged(Key, Row) = .empty;
        defer map.deinit(allocator);

        const span = recordSpan(l);
        var i: usize = 0;
        while (i < span.count) : (i += 1) {
            const at = span.start + i * record_size;
            const rec = Record.decode(l.bytes[at..][0..record_size]) orelse continue;
            if (!matches(rec, filter)) continue;

            const key = Key{
                .bucket = if (group_by.bucket) rec.bucket else 0,
                .agent = if (group_by.agent) rec.agent else 0,
                .flags = 0,
                .model_id = if (group_by.model) rec.model_id else 0,
                .project_id = if (group_by.project) rec.project_id else 0,
                .session_id = if (group_by.session) rec.session_id else 0,
            };
            const gop = try map.getOrPut(allocator, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .bucket = key.bucket,
                    .agent = key.agent,
                    .model_id = key.model_id,
                    .project_id = key.project_id,
                    .session_id = key.session_id,
                    .tz_offset_min = l.header.tz_offset_min,
                };
            }
            const row = gop.value_ptr;
            row.totals.input_tokens += rec.input_tokens;
            row.totals.output_tokens += rec.output_tokens;
            row.totals.cache_creation_tokens += rec.cache_creation_tokens;
            row.totals.cache_read_tokens += rec.cache_read_tokens;
            row.totals.cost_usd += rec.costUsd();
            row.totals.events += rec.events;
            if (rec.covered()) row.covered_cost_usd += rec.costUsd();
            row.records += 1;
        }

        const rows = try allocator.dupe(Row, map.values());
        std.mem.sort(Row, rows, {}, rowLessThan);
        return rows;
    }

    fn rowLessThan(_: void, a: Row, b: Row) bool {
        if (a.bucket != b.bucket) return a.bucket < b.bucket;
        if (a.agent != b.agent) return a.agent < b.agent;
        if (a.model_id != b.model_id) return a.model_id < b.model_id;
        if (a.project_id != b.project_id) return a.project_id < b.project_id;
        return a.session_id < b.session_id;
    }

    /// One row per bucket in `[from, to]`, ascending. Buckets with no
    /// records are absent, not zero-filled — a gap is data ("nothing ran
    /// here"), and the caller knows the axis it wants to draw.
    pub fn series(
        self: *Reader,
        allocator: Allocator,
        tier: Tier,
        from_bucket: u32,
        to_bucket: u32,
        group_by: GroupBy,
    ) ![]Row {
        var gb = group_by;
        gb.bucket = true;
        return self.query(allocator, tier, .{
            .from_bucket = from_bucket,
            .to_bucket = to_bucket,
        }, gb);
    }

    /// The `n` heaviest values of one dimension over a bucket range,
    /// by total tokens. Caller owns the slice.
    pub fn topBy(
        self: *Reader,
        allocator: Allocator,
        tier: Tier,
        dim: Dim,
        from_bucket: u32,
        to_bucket: u32,
        n: usize,
    ) ![]Row {
        const gb = GroupBy{
            .agent = dim == .agent,
            .model = dim == .model,
            .project = dim == .project,
            .session = dim == .session,
        };
        const rows = try self.query(allocator, tier, .{
            .from_bucket = from_bucket,
            .to_bucket = to_bucket,
        }, gb);
        std.mem.sort(Row, rows, {}, topLessThan);
        if (rows.len <= n) return rows;
        // Copy rather than shrink in place: handing back a sub-slice of
        // a larger allocation would make the caller's `free` wrong.
        const out = try allocator.alloc(Row, n);
        @memcpy(out, rows[0..n]);
        allocator.free(rows);
        return out;
    }

    fn topLessThan(_: void, a: Row, b: Row) bool {
        const at = a.totals.totalTokens();
        const bt = b.totals.totalTokens();
        if (at != bt) return at > bt;
        return a.totals.cost_usd > b.totals.cost_usd;
    }

    /// Token/cost rate over the `window_min` minutes ending at `ts_ms`,
    /// read from the hot tier. Windows longer than the hot tier's 48 h
    /// reach will under-report; use `series(.hour, ...)` for those.
    pub fn burnAt(self: *Reader, ts_ms: i64, window_min: u32) !Burn {
        const end = minuteBucket(ts_ms);
        const win = @max(window_min, 1);
        const start = if (end >= win - 1) end - (win - 1) else 0;
        const rows = try self.query(self.allocator, .minute, .{
            .from_bucket = start,
            .to_bucket = end,
        }, .none);
        defer self.allocator.free(rows);

        var burn = Burn{ .window_min = win };
        if (rows.len > 0) burn.totals = rows[0].totals;
        const minutes: f64 = @floatFromInt(win);
        burn.tokens_per_min = @as(f64, @floatFromInt(burn.totals.totalTokens())) / minutes;
        burn.cost_per_min = burn.totals.cost_usd / minutes;
        return burn;
    }

    /// First/last bucket, record count, and byte size for every tier.
    /// Counts VALID records, not the header's advisory counter.
    pub fn extent(self: *Reader) !Extents {
        return .{
            .minute = try self.tierExtent(.minute),
            .hour = try self.tierExtent(.hour),
            .day = try self.tierExtent(.day),
        };
    }

    fn tierExtent(self: *Reader, tier: Tier) !Extent {
        const loaded = try self.loadTier(tier);
        const l = loaded orelse return .{};
        defer self.allocator.free(l.bytes);

        var out = Extent{
            .bytes = l.bytes.len,
            .tz_offset_min = l.header.tz_offset_min,
            .present = true,
        };
        const span = recordSpan(l);
        var i: usize = 0;
        while (i < span.count) : (i += 1) {
            const at = span.start + i * record_size;
            const rec = Record.decode(l.bytes[at..][0..record_size]) orelse continue;
            out.records += 1;
            if (out.first_bucket == null or rec.bucket < out.first_bucket.?) out.first_bucket = rec.bucket;
            if (out.last_bucket == null or rec.bucket > out.last_bucket.?) out.last_bucket = rec.bucket;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Compaction
// ---------------------------------------------------------------------------

pub const CompactStats = struct {
    ran: bool = false,
    records_before: u64 = 0,
    records_after: u64 = 0,
    bytes_before: u64 = 0,
    bytes_after: u64 = 0,
};

/// Compact `hours.log`/`days.log` when duplicate-key pressure or size
/// justifies it. Purely a space optimization: because records are
/// additive, summing duplicates changes nothing any reader can observe.
/// Called at most once per launch, from `Writer.open`, under the lock.
pub fn maybeCompact(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    tier: Tier,
    dict_generation: u32,
) CompactStats {
    return compactInner(allocator, io, dir, tier, dict_generation, false) catch |err| blk: {
        std.log.warn("history: compaction of {s} skipped: {s}", .{ tier.fileName(), @errorName(err) });
        break :blk .{};
    };
}

/// Compact unconditionally (tests, an explicit maintenance command).
pub fn compact(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    tier: Tier,
    dict_generation: u32,
) !CompactStats {
    return compactInner(allocator, io, dir, tier, dict_generation, true);
}

fn compactInner(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    tier: Tier,
    dict_generation: u32,
    force: bool,
) !CompactStats {
    // The ring is already bounded; compacting it would mean rewriting
    // slots under a live reader for no space win.
    if (tier.fileKind() == .ring) return .{};

    var pb: PathBuf = .{};
    const path = try pb.join(dir, tier.fileName());
    var cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, allocator, .limited(max_tier_bytes)) catch return .{};
    defer allocator.free(bytes);

    const header = Header.parse(bytes) orelse return .{};
    if (!header.ok(tier)) return .{};
    if (dict_generation != 0 and header.dict_generation != dict_generation) return .{};

    var map: std.AutoArrayHashMapUnmanaged(Key, Acc) = .empty;
    defer map.deinit(allocator);

    var total: u64 = 0;
    const count = (bytes.len -| header_size) / record_size;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = Record.decode(bytes[header_size + i * record_size ..][0..record_size]) orelse continue;
        total += 1;
        const key = Key{
            .bucket = rec.bucket,
            .agent = rec.agent,
            .flags = rec.flags,
            .model_id = rec.model_id,
            .project_id = rec.project_id,
            .session_id = rec.session_id,
        };
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.addRecord(rec);
    }

    const distinct: u64 = map.count();
    const duplicates = total - distinct;
    const dup_ratio: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(duplicates)) / @as(f64, @floatFromInt(total));
    if (!force and dup_ratio <= compact_dup_ratio and bytes.len < compact_size_bytes) return .{};
    if (total == 0) return .{};

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var new_header = header;
    new_header.records_written = distinct;
    try out.appendSlice(allocator, &new_header.sealed());

    // Bucket-ascending output: not required (readers never assume it)
    // but it makes a compacted file pleasant to inspect and gives the
    // page cache a fighting chance on range scans.
    const Sorter = struct {
        keys: []const Key,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ka = ctx.keys[a];
            const kb = ctx.keys[b];
            if (ka.bucket != kb.bucket) return ka.bucket < kb.bucket;
            if (ka.agent != kb.agent) return ka.agent < kb.agent;
            if (ka.model_id != kb.model_id) return ka.model_id < kb.model_id;
            if (ka.project_id != kb.project_id) return ka.project_id < kb.project_id;
            return ka.session_id < kb.session_id;
        }
    };
    map.sort(Sorter{ .keys = map.keys() });

    for (map.keys(), map.values()) |key, acc| {
        try out.appendSlice(allocator, &acc.toRecord(key).sealed());
    }

    // The exact atomic idiom statefile.save uses: tmp file, 0600, rename.
    var tmp_pb: PathBuf = .{};
    var tmp_name: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_rel = try std.fmt.bufPrint(&tmp_name, "{s}.tmp", .{tier.fileName()});
    const tmp_path = try tmp_pb.join(dir, tmp_rel);
    try cwd.writeFile(io, .{
        .sub_path = tmp_path,
        .data = out.items,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    setMode(tmp_path, 0o600);
    try cwd.rename(tmp_path, cwd, path, io);
    setMode(path, 0o600);

    return .{
        .ran = true,
        .records_before = total,
        .records_after = distinct,
        .bytes_before = bytes.len,
        .bytes_after = out.items.len,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A tmp history directory plus the absolute path to it.
const Tmp = struct {
    dir: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    /// Length only, never a slice: `Tmp` is returned by value, and a
    /// slice into the initializer's copy of `buf` would dangle.
    len: usize = 0,

    fn init(io: std.Io) !Tmp {
        var self = Tmp{ .dir = testing.tmpDir(.{}) };
        self.len = try self.dir.dir.realPath(io, &self.buf);
        return self;
    }

    fn deinit(self: *Tmp) void {
        self.dir.cleanup();
    }

    fn abs(self: *const Tmp) []const u8 {
        return self.buf[0..self.len];
    }

    fn sub(self: *const Tmp, out: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(out, "{s}/{s}", .{ self.abs(), name });
    }
};

/// Suppress an EXPECTED `std.log.warn` for the body of one test.
///
/// The warns themselves are correct runtime behavior and stay exactly as
/// they are: a second writer that cannot take the flock, or a reader that
/// meets a corrupt header, must say so in a real app's log. The problem is
/// downstream. Zig's build runner treats any stderr from the test Run step
/// as failure-shaped output and prints a red `failed command: …` line
/// directly above `Build Summary: 11/11 steps succeeded`. Exit code 0, the
/// step genuinely passed — and every reader, human or CI, sees red and
/// concludes something broke. A gate that cries wolf gets ignored, which is
/// the actual failure mode this avoids.
///
/// The mechanism is `std.testing.log_level`, not a root `std_options`
/// declaration: in a test build the compilation root is Zig's own
/// `test_runner.zig`, which already owns `std_options` and gates printing
/// on this variable. A `pub const std_options` in the app's test file is
/// never consulted.
///
/// Scoped by construction — restore on the way out, so a test that does NOT
/// expect a warning still surfaces one.
const QuietWarnings = struct {
    prior: std.log.Level,

    fn begin() QuietWarnings {
        const self = QuietWarnings{ .prior = testing.log_level };
        testing.log_level = .err;
        return self;
    }

    fn end(self: QuietWarnings) void {
        testing.log_level = self.prior;
    }
};

/// 2026-07-09T12:00:00Z — a round instant to build buckets from.
const t0: i64 = 1_783_598_400_000;

fn mkEv(agent: types.Agent, ts: i64, model: []const u8, project: []const u8, out: u64) types.UsageEvent {
    return .{
        .agent = agent,
        .timestamp_ms = ts,
        .model = model,
        .input_tokens = out * 2,
        .output_tokens = out,
        .cache_creation_tokens = 3,
        .cache_read_tokens = 4,
        .session_id = "ses-1",
        .cwd = project,
    };
}

fn sumTotals(rows: []const Row) ledger_mod.Totals {
    var acc = ledger_mod.Totals{};
    for (rows) |row| {
        acc.input_tokens += row.totals.input_tokens;
        acc.output_tokens += row.totals.output_tokens;
        acc.cache_creation_tokens += row.totals.cache_creation_tokens;
        acc.cache_read_tokens += row.totals.cache_read_tokens;
        acc.cost_usd += row.totals.cost_usd;
        acc.events += row.totals.events;
    }
    return acc;
}

test "defaultDir honors XDG_STATE_HOME and falls back to ~/.local/state" {
    const xdg = try defaultDir(testing.allocator, "/x/state", "/home/u");
    defer testing.allocator.free(xdg);
    try testing.expectEqualStrings("/x/state/token-tach/history", xdg);

    const blank = try defaultDir(testing.allocator, "  ", "/home/u");
    defer testing.allocator.free(blank);
    try testing.expectEqualStrings("/home/u/.local/state/token-tach/history", blank);

    const unset = try defaultDir(testing.allocator, null, "/home/u");
    defer testing.allocator.free(unset);
    try testing.expectEqualStrings("/home/u/.local/state/token-tach/history", unset);
}

test "every on-disk agent id has a name, including ids from newer builds" {
    // The numbering itself is types.zig's wire format and is asserted
    // there; what history owns is that no stored byte can come back
    // nameless. `synthetic_agent_id` must stay outside the agent range or
    // it would rename a real tool.
    inline for (@typeInfo(types.Agent).@"enum".fields) |field| {
        const agent: types.Agent = @enumFromInt(field.value);
        const id = agent.storageId();
        try testing.expect(id != synthetic_agent_id);
        var buf: [name_buf_len]u8 = undefined;
        try testing.expectEqualStrings(agent.label(), agentName(id, &buf));
    }

    var buf: [name_buf_len]u8 = undefined;
    // An id from a newer build is named, not dropped and not coerced to a
    // neighbor: a row nobody can name still belongs in the totals.
    try testing.expectEqualStrings("agent-200", agentName(200, &buf));
    try testing.expectEqualStrings("synthetic", agentName(synthetic_agent_id, &buf));
    try testing.expectEqualStrings("claude", agentName(1, &buf));
}

test "record checksum rejects any single-bit corruption" {
    var rec = Record{ .bucket = 7, .agent = 1, .events = 2, .input_tokens = 99 };
    const bytes = rec.sealed();
    const decoded = Record.decode(&bytes).?;
    try testing.expectEqual(@as(u32, 7), decoded.bucket);

    var torn = bytes;
    torn[24] ^= 0x01;
    try testing.expectEqual(@as(?Record, null), Record.decode(&torn));

    // An unwritten (all-zero) slot is rejected for free.
    const zeros: [record_size]u8 = @splat(0);
    try testing.expectEqual(@as(?Record, null), Record.decode(&zeros));
    rec.check = 0;
}

test "writer -> reader round-trip recovers costs bit-exactly across all three tiers" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    // Distinctive costs that no float-formatting round-trip would keep.
    const cost_a: f64 = 0.000123456789012345;
    const cost_b: f64 = 0.987654321098765;

    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .tz_offset_min = -300, .now_ms = t0 });
    defer w.deinit();
    try testing.expect(w.enabled);

    // Three minutes, two agents, two projects.
    w.record(mkEv(.claude, t0, "claude-fable-5", "/w/alpha", 10), .{ .cost_usd = cost_a, .now_ms = t0 });
    w.record(mkEv(.claude, t0 + 5_000, "claude-fable-5", "/w/alpha", 20), .{ .cost_usd = cost_a, .now_ms = t0 });
    w.record(mkEv(.codex, t0 + 61_000, "gpt-5.2-codex", "/w/beta", 30), .{ .cost_usd = cost_b, .now_ms = t0 });
    w.record(mkEv(.codex, t0 + 121_000, "gpt-5.2-codex", "/w/beta", 40), .{ .cost_usd = cost_b, .now_ms = t0 });
    w.flush();

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    const want_cost = cost_a * 2 + cost_b * 2;
    const want_out: u64 = 100;

    for ([_]Tier{ .minute, .hour, .day }) |tier| {
        const rows = try r.query(testing.allocator, tier, .{}, .none);
        defer testing.allocator.free(rows);
        try testing.expectEqual(@as(usize, 1), rows.len);
        try testing.expectEqual(@as(u64, 4), rows[0].totals.events);
        try testing.expectEqual(want_out, rows[0].totals.output_tokens);
        try testing.expectEqual(want_out * 2, rows[0].totals.input_tokens);
        // Bit-exact, not approximately equal: the point of cost_usd_bits.
        try testing.expectEqual(
            @as(u64, @bitCast(want_cost)),
            @as(u64, @bitCast(rows[0].totals.cost_usd)),
        );
        // claude + codex both have limit panels, so all spend is covered.
        try testing.expectEqual(
            @as(u64, @bitCast(want_cost)),
            @as(u64, @bitCast(rows[0].covered_cost_usd)),
        );
    }

    // Minute buckets are UTC and distinct; the day tier collapses to one.
    const minutes = try r.series(testing.allocator, .minute, 0, std.math.maxInt(u32), .none);
    defer testing.allocator.free(minutes);
    try testing.expectEqual(@as(usize, 3), minutes.len);
    try testing.expectEqual(minuteBucket(t0), minutes[0].bucket);

    const days = try r.query(testing.allocator, .day, .{}, .by_bucket);
    defer testing.allocator.free(days);
    try testing.expectEqual(@as(usize, 1), days.len);

    // Grouping resolves through the dictionary.
    const by_project = try r.topBy(testing.allocator, .hour, .project, 0, std.math.maxInt(u32), 10);
    defer testing.allocator.free(by_project);
    try testing.expectEqual(@as(usize, 2), by_project.len);
    var nbuf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("/w/beta", r.name(by_project[0].project_id, &nbuf));
    try testing.expectEqualStrings("/w/alpha", r.name(by_project[1].project_id, &nbuf));

    // Filters: one agent, one project.
    var only_claude = std.EnumSet(types.Agent).initEmpty();
    only_claude.insert(.claude);
    const claude_rows = try r.query(testing.allocator, .hour, .{ .agents = only_claude }, .none);
    defer testing.allocator.free(claude_rows);
    try testing.expectEqual(@as(u64, 2), claude_rows[0].totals.events);
    try testing.expectEqual(@as(u64, 30), claude_rows[0].totals.output_tokens);

    const beta = r.projectId("/w/beta");
    try testing.expect(beta != 0);
    const beta_rows = try r.query(testing.allocator, .hour, .{ .project_id = beta }, .none);
    defer testing.allocator.free(beta_rows);
    try testing.expectEqual(@as(u64, 70), beta_rows[0].totals.output_tokens);

    // extent() reports all three tiers.
    const ext = try r.extent();
    try testing.expect(ext.minute.present and ext.hour.present and ext.day.present);
    try testing.expectEqual(@as(u64, 3), ext.minute.records);
    try testing.expectEqual(minuteBucket(t0), ext.minute.first_bucket.?);
    try testing.expectEqual(minuteBucket(t0 + 121_000), ext.minute.last_bucket.?);
    try testing.expectEqual(@as(i32, -300), ext.day.tz_offset_min);

    // burnAt over a 5-minute window covering everything.
    const burn = try r.burnAt(t0 + 121_000, 5);
    try testing.expectEqual(@as(u64, 4), burn.totals.events);
    try testing.expect(burn.tokens_per_min > 0);
}

test "records are additive: the same key flushed three times sums" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
    defer w.deinit();

    // Three explicit flushes of the SAME (bucket, dims) key. This is the
    // crash-resume / partial-flush shape, and it must sum, not conflict.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        w.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .cost_usd = 0.25, .now_ms = t0 });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    const rows = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u64, 3), rows[0].totals.events);
    try testing.expectEqual(@as(u64, 30), rows[0].totals.output_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.75), rows[0].totals.cost_usd, 1e-12);
    // Three physical records behind one logical row — the duplicate-key
    // pressure that compaction (and only compaction) removes.
    try testing.expectEqual(@as(u64, 3), rows[0].records);
}

test "ring wraps in place and old minutes are clipped out of the hot tier" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{
        .hot_capacity = 4,
        .now_ms = t0 + 20 * 60_000,
    });
    defer w.deinit();

    // Ten distinct minutes into a four-slot ring.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const ts = t0 + @as(i64, i) * 60_000;
        w.record(mkEv(.claude, ts, "m", "/w/p", 1), .{ .now_ms = t0 + 20 * 60_000 });
    }
    w.flush();

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    const hot = try r.series(testing.allocator, .minute, 0, std.math.maxInt(u32), .none);
    defer testing.allocator.free(hot);
    try testing.expectEqual(@as(usize, 4), hot.len);
    try testing.expectEqual(minuteBucket(t0 + 6 * 60_000), hot[0].bucket);
    try testing.expectEqual(minuteBucket(t0 + 9 * 60_000), hot[3].bucket);

    // The durable tiers kept every one of the ten.
    const hours = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(hours);
    try testing.expectEqual(@as(u64, 10), hours[0].totals.events);
}

test "hot-tier age gate keeps a cold catch-up from scrolling the ring out" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    const now = t0 + 10 * 60_000;
    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .hot_capacity = 64, .now_ms = now });
    defer w.deinit();

    // A six-month backfill batch, then one live event.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const ts = t0 - 180 * 86_400_000 + @as(i64, i) * 60_000;
        w.record(mkEv(.claude, ts, "m", "/w/p", 1), .{ .now_ms = now });
    }
    w.record(mkEv(.claude, now, "m", "/w/p", 1), .{ .now_ms = now });
    w.flush();

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    // Only the live minute reached the ring...
    const hot = try r.query(testing.allocator, .minute, .{}, .none);
    defer testing.allocator.free(hot);
    try testing.expectEqual(@as(usize, 1), hot.len);
    try testing.expectEqual(@as(u64, 1), hot[0].totals.events);

    // ...but nothing was lost: all 21 are in hours and days.
    const hours = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(hours);
    try testing.expectEqual(@as(u64, 21), hours[0].totals.events);
    const days = try r.query(testing.allocator, .day, .{}, .none);
    defer testing.allocator.free(days);
    try testing.expectEqual(@as(u64, 21), days[0].totals.events);
}

test "a torn append tail is recovered cleanly and never shifts later records" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        w.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .cost_usd = 1.5, .now_ms = t0 });
        w.flush();
    }

    // Simulate a crash mid-append: half a record on the end of hours.log.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hours_path = try tmp.sub(&path_buf, "hours.log");
    {
        var f = try std.Io.Dir.cwd().openFile(io, hours_path, .{ .mode = .read_write });
        defer f.close(io);
        const half: [32]u8 = @splat(0xAB);
        try f.writePositionalAll(io, &half, try f.length(io));
    }

    // A reader tolerates the stub (it is not a whole record)...
    {
        var r = try Reader.open(testing.allocator, io, tmp.abs());
        defer r.deinit();
        const rows = try r.query(testing.allocator, .hour, .{}, .none);
        defer testing.allocator.free(rows);
        try testing.expectEqual(@as(u64, 10), rows[0].totals.output_tokens);
    }

    // ...and the next writer truncates it away, so the record it appends
    // lands on a 64-byte boundary instead of being permanently shifted.
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        try testing.expect(w.enabled);
        w.record(mkEv(.claude, t0 + 3_600_000, "m", "/w/p", 7), .{ .cost_usd = 0.5, .now_ms = t0 + 3_600_000 });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .by_bucket);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u64, 17), sumTotals(rows).output_tokens);
    const stat = try std.Io.Dir.cwd().statFile(io, hours_path, .{});
    try testing.expectEqual(@as(u64, header_size + 2 * record_size), stat.size);
}

test "a torn ring slot costs exactly one minute, not the tier" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .hot_capacity = 16, .now_ms = t0 });
        defer w.deinit();
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            w.record(mkEv(.claude, t0 + @as(i64, i) * 60_000, "m", "/w/p", 10), .{ .now_ms = t0 + 5 * 60_000 });
        }
        w.flush();
    }

    // Flip a bit inside slot 2's payload.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ring_path = try tmp.sub(&path_buf, "hot.ring");
    {
        var f = try std.Io.Dir.cwd().openFile(io, ring_path, .{ .mode = .read_write });
        defer f.close(io);
        const at = header_size + 2 * record_size + 32;
        var byte: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &byte, at);
        byte[0] ^= 0x40;
        try f.writePositionalAll(io, &byte, at);
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const hot = try r.series(testing.allocator, .minute, 0, std.math.maxInt(u32), .none);
    defer testing.allocator.free(hot);
    // Four of five minutes survive, and the missing one is minute 2.
    try testing.expectEqual(@as(usize, 4), hot.len);
    for (hot) |row| {
        try testing.expect(row.bucket != minuteBucket(t0 + 2 * 60_000));
    }
    try testing.expectEqual(@as(u64, 40), sumTotals(hot).output_tokens);
    // The durable tier never noticed.
    const hours = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(hours);
    try testing.expectEqual(@as(u64, 50), hours[0].totals.output_tokens);
}

test "a dangling dictionary id renders ?id:n instead of vanishing" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        w.record(mkEv(.claude, t0, "claude-fable-5", "/w/secret", 10), .{ .now_ms = t0 });
        w.flush();
    }

    // Crash before the dictionary entries were durable: keep the header,
    // lose the entries. The records that reference them stay.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dict_path = try tmp.sub(&path_buf, "dict.log");
    {
        var f = try std.Io.Dir.cwd().openFile(io, dict_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, dict_header_size);
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .{ .model = true, .project = true });
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    // The spend is intact; only the names are gone.
    try testing.expectEqual(@as(u64, 10), rows[0].totals.output_tokens);
    var nbuf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("?id:1", r.name(rows[0].model_id, &nbuf));
    try testing.expectEqualStrings("?id:2", r.name(rows[0].project_id, &nbuf));
    try testing.expectEqualStrings("", r.name(0, &nbuf));
}

test "compaction is value-preserving and only shrinks the file" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var generation: u32 = 0;
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        generation = w.dictGeneration();
        // Eight flushes of the same key: 8 records, 1 logical row.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            w.record(mkEv(.claude, t0, "m", "/w/p", 5), .{ .cost_usd = 0.125, .now_ms = t0 });
            w.flush();
        }
    }

    var before_rows: []Row = undefined;
    {
        var r = try Reader.open(testing.allocator, io, tmp.abs());
        defer r.deinit();
        before_rows = try r.query(testing.allocator, .hour, .{}, .{ .bucket = true, .agent = true, .model = true, .project = true, .session = true });
    }
    defer testing.allocator.free(before_rows);
    try testing.expectEqual(@as(u64, 8), before_rows[0].records);

    const stats = try compact(testing.allocator, io, tmp.abs(), .hour, generation);
    try testing.expect(stats.ran);
    try testing.expectEqual(@as(u64, 8), stats.records_before);
    try testing.expectEqual(@as(u64, 1), stats.records_after);
    try testing.expect(stats.bytes_after < stats.bytes_before);

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const after = try r.query(testing.allocator, .hour, .{}, .{ .bucket = true, .agent = true, .model = true, .project = true, .session = true });
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(before_rows[0].totals.events, after[0].totals.events);
    try testing.expectEqual(before_rows[0].totals.output_tokens, after[0].totals.output_tokens);
    try testing.expectEqual(before_rows[0].totals.input_tokens, after[0].totals.input_tokens);
    try testing.expectEqual(
        @as(u64, @bitCast(before_rows[0].totals.cost_usd)),
        @as(u64, @bitCast(after[0].totals.cost_usd)),
    );
    // One physical record now backs the same numbers.
    try testing.expectEqual(@as(u64, 1), after[0].records);

    // A compacted file still appends: the writer picks up after it.
    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0, .compact_on_open = false });
    defer w.deinit();
    try testing.expect(w.enabled);
    w.record(mkEv(.claude, t0, "m", "/w/p", 5), .{ .cost_usd = 0.125, .now_ms = t0 });
    w.flush();
    const grown = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(grown);
    try testing.expectEqual(@as(u64, 9), grown[0].totals.events);
}

test "days.log reports the offset it was keyed with instead of re-bucketing" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    // 2026-07-09T02:00:00Z: still 2026-07-08 at UTC-5, already the 9th at UTC.
    const ts: i64 = 1_783_562_400_000;
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .tz_offset_min = -300, .now_ms = ts });
        defer w.deinit();
        w.record(mkEv(.claude, ts, "m", "/w/p", 10), .{ .now_ms = ts });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    const rows = try r.query(testing.allocator, .day, .{}, .by_bucket);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    // The key is the WRITER's local day, and the row carries the offset
    // that makes it interpretable...
    try testing.expectEqual(dayBucket(ts, -300), rows[0].bucket);
    try testing.expect(rows[0].bucket != dayBucket(ts, 0));
    try testing.expectEqual(@as(i32, -300), rows[0].tz_offset_min);
    // ...and a reader running at a different offset is told so rather
    // than being handed a silently re-keyed series.
    try testing.expectEqual(@as(?i32, -300), r.dayTzOffset());
    try testing.expect(r.dayTzMismatch(0));
    try testing.expect(!r.dayTzMismatch(-300));

    // A writer reopening after a timezone move adopts the file's offset
    // rather than splitting the day series across two keyings.
    var w2 = try Writer.open(testing.allocator, io, tmp.abs(), .{ .tz_offset_min = 540, .now_ms = ts });
    defer w2.deinit();
    try testing.expectEqual(@as(i32, -300), w2.tz_offset_min);
}

test "flock contention makes the second writer inert, not corrupting" {
    // The losing writer logs `history: disabled (…)` — expected, and the
    // whole point of the test. See QuietWarnings for why it must not reach
    // the build runner's stderr.
    const quiet = QuietWarnings.begin();
    defer quiet.end();

    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var first = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
    defer first.deinit();
    try testing.expect(first.enabled);

    var second = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
    defer second.deinit();
    try testing.expect(!second.enabled);

    // The inert writer accepts calls and drops them on the floor: the
    // app must behave exactly as it did before history existed.
    second.record(mkEv(.claude, t0, "m", "/w/p", 999), .{ .now_ms = t0 });
    second.flush();

    first.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .now_ms = t0 });
    first.flush();

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(u64, 1), rows[0].totals.events);
    try testing.expectEqual(@as(u64, 10), rows[0].totals.output_tokens);
}

test "a corrupt header quarantines the file aside and reads as empty" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        w.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .now_ms = t0 });
        w.flush();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hours_path = try tmp.sub(&path_buf, "hours.log");
    {
        var f = try std.Io.Dir.cwd().openFile(io, hours_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, "XXXXXXXX", 0);
    }

    // A reader treats the broken file as absent without touching it.
    {
        var r = try Reader.open(testing.allocator, io, tmp.abs());
        defer r.deinit();
        const rows = try r.query(testing.allocator, .hour, .{}, .none);
        defer testing.allocator.free(rows);
        try testing.expectEqual(@as(usize, 0), rows.len);
        // The day tier is untouched, so history is not "gone".
        const days = try r.query(testing.allocator, .day, .{}, .none);
        defer testing.allocator.free(days);
        try testing.expectEqual(@as(u64, 10), days[0].totals.output_tokens);
    }

    // The next writer renames it aside — quarantined, never deleted.
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        try testing.expect(w.enabled);
        w.record(mkEv(.claude, t0, "m", "/w/p", 3), .{ .now_ms = t0 });
        w.flush();
    }

    var found_bad = false;
    {
        var dir = try std.Io.Dir.cwd().openDir(io, tmp.abs(), .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "hours.log.bad.")) found_bad = true;
        }
    }
    try testing.expect(found_bad);

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .none);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(u64, 3), rows[0].totals.output_tokens);
}

test "a rebuilt dictionary invalidates tier files that reference the old ids" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        w.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .now_ms = t0 });
        w.flush();
    }

    // Destroy the dictionary outright. Its replacement gets a new
    // generation, so the surviving tier files no longer describe a
    // dictionary that exists — reading them would attribute real spend
    // to whatever string happens to hold id 1 next.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dict_path = try tmp.sub(&path_buf, "dict.log");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dict_path, .data = "not a dictionary" });

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 + 1 });
        defer w.deinit();
        try testing.expect(w.enabled);
        w.record(mkEv(.claude, t0, "m2", "/w/p2", 4), .{ .now_ms = t0 });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .{ .model = true });
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u64, 4), rows[0].totals.output_tokens);
    var nbuf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("m2", r.name(rows[0].model_id, &nbuf));

    // Both the old dictionary and the stale tier files are on disk, not
    // in the trash.
    var bad_files: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io, tmp.abs(), .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".bad.") != null) bad_files += 1;
    }
    try testing.expect(bad_files >= 2);
}

test "backfill lands in its true bucket without disturbing the open one" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    const now = t0 + 3_600_000;
    var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .hot_capacity = 64, .now_ms = now });
    defer w.deinit();

    // Open the current minute, then hand over a late arrival from an
    // hour ago, then keep feeding the open minute.
    w.record(mkEv(.claude, now, "m", "/w/p", 10), .{ .now_ms = now });
    w.record(mkEv(.claude, t0, "m", "/w/p", 5), .{ .now_ms = now });
    w.record(mkEv(.claude, now + 1_000, "m", "/w/p", 10), .{ .now_ms = now });
    w.flush();

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const hours = try r.series(testing.allocator, .hour, 0, std.math.maxInt(u32), .none);
    defer testing.allocator.free(hours);
    try testing.expectEqual(@as(usize, 2), hours.len);
    try testing.expectEqual(hourBucket(t0), hours[0].bucket);
    try testing.expectEqual(@as(u64, 5), hours[0].totals.output_tokens);
    try testing.expectEqual(hourBucket(now), hours[1].bucket);
    try testing.expectEqual(@as(u64, 20), hours[1].totals.output_tokens);

    // The late arrival is inside the 48 h window, so it made the ring
    // too — at its own minute, not folded into the open one.
    const hot = try r.series(testing.allocator, .minute, 0, std.math.maxInt(u32), .none);
    defer testing.allocator.free(hot);
    try testing.expectEqual(@as(usize, 2), hot.len);
    try testing.expectEqual(minuteBucket(t0), hot[0].bucket);
    try testing.expectEqual(@as(u64, 5), hot[0].totals.output_tokens);
    try testing.expectEqual(minuteBucket(now), hot[1].bucket);
    try testing.expectEqual(@as(u64, 20), hot[1].totals.output_tokens);
    try testing.expectEqual(@as(u64, 25), sumTotals(hot).output_tokens);
}

test "an empty or missing store reads as empty rather than failing" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try tmp.sub(&path_buf, "no-such-history");

    var r = try Reader.open(testing.allocator, io, missing);
    defer r.deinit();
    for ([_]Tier{ .minute, .hour, .day }) |tier| {
        const rows = try r.query(testing.allocator, tier, .{}, .none);
        defer testing.allocator.free(rows);
        try testing.expectEqual(@as(usize, 0), rows.len);
    }
    const ext = try r.extent();
    try testing.expect(!ext.minute.present);
    try testing.expectEqual(@as(?i32, null), r.dayTzOffset());
    const burn = try r.burnAt(t0, 15);
    try testing.expectEqual(@as(u64, 0), burn.totals.events);
    try testing.expectEqual(@as(f64, 0), burn.tokens_per_min);
}

test "unknown agent ids survive a round trip and stay out of agent filters" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        w.record(mkEv(.claude, t0, "m", "/w/p", 10), .{ .now_ms = t0 });
        // A row from a build that knows an agent this one does not, plus
        // a synthetic import.
        w.record(mkEv(.claude, t0, "m", "/w/p", 20), .{ .agent_storage_id = 201, .now_ms = t0 });
        w.record(mkEv(.claude, t0, "m", "/w/p", 30), .{
            .agent_storage_id = synthetic_agent_id,
            .synthetic = true,
            .covered = false,
            .now_ms = t0,
        });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();

    // Unfiltered: every row counts, named or not.
    const all = try r.query(testing.allocator, .hour, .{}, .{ .agent = true });
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(u64, 60), sumTotals(all).output_tokens);
    var nbuf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("claude", agentName(all[0].agent, &nbuf));
    try testing.expectEqualStrings("agent-201", agentName(all[1].agent, &nbuf));
    try testing.expectEqualStrings("synthetic", agentName(all[2].agent, &nbuf));

    // An agent-set filter can only name agents this build knows, so the
    // unknown and synthetic rows fall out — documented on Filter.agents.
    var set = std.EnumSet(types.Agent).initEmpty();
    set.insert(.claude);
    const filtered = try r.query(testing.allocator, .hour, .{ .agents = set }, .none);
    defer testing.allocator.free(filtered);
    try testing.expectEqual(@as(u64, 10), filtered[0].totals.output_tokens);

    // covered_only sees the two claude-flagged rows, not the synthetic.
    const covered = try r.query(testing.allocator, .hour, .{ .covered_only = true }, .none);
    defer testing.allocator.free(covered);
    try testing.expectEqual(@as(u64, 30), covered[0].totals.output_tokens);
}

test "a writer reopening an existing store appends instead of restarting" {
    const io = testing.io;
    var tmp = try Tmp.init(io);
    defer tmp.deinit();

    var generation: u32 = 0;
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 });
        defer w.deinit();
        generation = w.dictGeneration();
        w.record(mkEv(.claude, t0, "claude-fable-5", "/w/p", 10), .{ .now_ms = t0 });
        w.flush();
    }
    {
        var w = try Writer.open(testing.allocator, io, tmp.abs(), .{ .now_ms = t0 + 60_000 });
        defer w.deinit();
        // Same strings: the dictionary must reuse the ids, not mint new
        // ones, or a project's history would fragment across restarts.
        try testing.expectEqual(generation, w.dictGeneration());
        w.record(mkEv(.claude, t0 + 60_000, "claude-fable-5", "/w/p", 20), .{ .now_ms = t0 + 60_000 });
        w.flush();
    }

    var r = try Reader.open(testing.allocator, io, tmp.abs());
    defer r.deinit();
    const rows = try r.query(testing.allocator, .hour, .{}, .{ .model = true, .project = true });
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u64, 30), rows[0].totals.output_tokens);
    try testing.expectEqual(@as(u64, 2), rows[0].totals.events);
    var nbuf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("claude-fable-5", r.name(rows[0].model_id, &nbuf));
}
