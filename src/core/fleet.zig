//! The collector fleet: every tt-hr8 expansion agent behind one UI-free
//! aggregator. The engine (and the read-only CLI) own exactly one Fleet;
//! it owns the per-agent collectors and their resolved data locations:
//!
//! - JSONL tailers (tailsource.Tailer): pi, gemini, qwen, kimi.
//! - SQLite high-water pollers: goose, kilo.
//! - Rewritten-JSON snapshot pollers (snapsource.Poller): cline (two
//!   store generations) and roo.
//!
//! copilot/continue_cli/droid have no collectors yet — they are config-
//! recognized but dormant, and `detected` reports null for them (as it
//! does for claude/codex/opencode, which the engine drives directly).
//!
//! Contract: `sweep` never fails — a broken source logs a warning and
//! the rest of the fleet still reports. Missing directories/databases
//! are normal (most machines run a subset of these harnesses) and cost
//! one stat per tick at most. Event/Change strings are allocated with
//! the arena handed to `sweep`; internal collector state lives on the
//! init allocator and dies with `deinit`.

const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const tailsource = @import("tailsource.zig");
const snapsource = @import("snapsource.zig");
const pisrc = @import("pisrc.zig");
const geminisrc = @import("geminisrc.zig");
const qwensrc = @import("qwensrc.zig");
const kimisrc = @import("kimisrc.zig");
const goosesrc = @import("goosesrc.zig");
const kilosrc = @import("kilosrc.zig");
const clinesrc = @import("clinesrc.zig");
const roosrc = @import("roosrc.zig");

const Allocator = std.mem.Allocator;

/// Environment facts the fleet resolves data locations from. Null/blank
/// overrides fall through to each harness's home-relative default.
pub const Env = struct {
    home: []const u8 = "",
    pi_home: ?[]const u8 = null,
    gemini_cli_home: ?[]const u8 = null,
    qwen_runtime_dir: ?[]const u8 = null,
    qwen_home: ?[]const u8 = null,
    kimi_share_dir: ?[]const u8 = null,
    goose_path_root: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    kilo_db: ?[]const u8 = null,
    cline_dir: ?[]const u8 = null,
    cline_data_dir: ?[]const u8 = null,
};

/// Agents collected through a generic JSONL tailer (statefile: offsets,
/// cwd attribution, dedup keys).
pub const jsonl_agents = [_]types.Agent{ .pi, .gemini, .qwen, .kimi };

/// Agents collected through a SQLite high-water poller (statefile: one
/// i64 high-water mark each).
pub const sqlite_agents = [_]types.Agent{ .goose, .kilo };

/// The snapshot pollers, named stably for the statefile. Cline runs two:
/// the SDK/CLI session store and the legacy VS Code task store.
pub const SnapName = enum { cline_sdk, cline_legacy, roo };

pub const Fleet = struct {
    allocator: Allocator,

    pi: tailsource.Tailer,
    gemini: tailsource.Tailer,
    qwen: tailsource.Tailer,
    kimi: tailsource.Tailer,
    goose: goosesrc.Poller,
    kilo: kilosrc.Poller,
    cline_sdk: snapsource.Poller,
    cline_legacy: snapsource.Poller,
    roo: snapsource.Poller,

    pi_roots: []const []const u8 = &.{},
    gemini_roots: []const []const u8 = &.{},
    qwen_roots: []const []const u8 = &.{},
    kimi_roots: []const []const u8 = &.{},
    cline_sdk_roots: []const []const u8 = &.{},
    cline_legacy_roots: []const []const u8 = &.{},
    roo_roots: []const []const u8 = &.{},
    /// "" when no override and no usable home (poll("") is a no-op).
    goose_db: []const u8 = "",
    kilo_db: []const u8 = "",

    /// Construct the collectors and resolve every root/db path from the
    /// environment. Purely computational — nothing on disk is touched,
    /// so missing directories are fine (sweeps skip them).
    pub fn init(allocator: Allocator, env: Env) !Fleet {
        var self = Fleet{
            .allocator = allocator,
            .pi = pisrc.makeTailer(allocator, .pi),
            .gemini = geminisrc.makeTailer(allocator, .gemini),
            .qwen = qwensrc.makeTailer(allocator, .qwen),
            .kimi = kimisrc.makeTailer(allocator, .kimi),
            .goose = goosesrc.Poller.init(allocator, .goose),
            .kilo = kilosrc.Poller.init(allocator, .kilo),
            .cline_sdk = clinesrc.makeSdkPoller(allocator, .cline),
            .cline_legacy = clinesrc.makeLegacyPoller(allocator, .cline),
            .roo = roosrc.makePoller(allocator, .roo),
        };
        errdefer self.deinit();

        self.pi_roots = try pisrc.defaultRoots(allocator, env.pi_home, env.home);
        self.gemini_roots = try geminisrc.defaultRoots(allocator, env.gemini_cli_home, env.home);
        self.qwen_roots = try qwensrc.defaultRoots(allocator, env.qwen_runtime_dir, env.qwen_home, env.home);
        self.kimi_roots = try kimisrc.defaultRoots(allocator, env.kimi_share_dir, env.home);
        self.cline_sdk_roots = try clinesrc.sdkRoots(allocator, env.cline_dir, env.cline_data_dir, env.home);
        self.cline_legacy_roots = try clinesrc.legacyRoots(allocator, env.cline_dir, env.cline_data_dir, env.home);
        self.roo_roots = try roosrc.defaultRoots(allocator, env.home);
        self.goose_db = (try goosesrc.defaultDbPath(allocator, .{
            .home = env.home,
            .goose_path_root = env.goose_path_root,
        })) orelse "";
        self.kilo_db = (try kilosrc.defaultDbPath(allocator, .{
            .home = env.home,
            .xdg_data_home = env.xdg_data_home,
            .kilo_db = env.kilo_db,
        })) orelse "";
        return self;
    }

    pub fn deinit(self: *Fleet) void {
        self.pi.deinit();
        self.gemini.deinit();
        self.qwen.deinit();
        self.kimi.deinit();
        self.goose.deinit();
        self.kilo.deinit();
        self.cline_sdk.deinit();
        self.cline_legacy.deinit();
        self.roo.deinit();
        freeRoots(self.allocator, self.pi_roots);
        freeRoots(self.allocator, self.gemini_roots);
        freeRoots(self.allocator, self.qwen_roots);
        freeRoots(self.allocator, self.kimi_roots);
        freeRoots(self.allocator, self.cline_sdk_roots);
        freeRoots(self.allocator, self.cline_legacy_roots);
        freeRoots(self.allocator, self.roo_roots);
        if (self.goose_db.len > 0) self.allocator.free(self.goose_db);
        if (self.kilo_db.len > 0) self.allocator.free(self.kilo_db);
        self.* = undefined;
    }

    /// One pass over every ENABLED fleet source. JSONL tailers and the
    /// SQLite pollers append UsageEvents to `events_out`; the snapshot
    /// pollers append add/replace Changes to `changes_out`. All emitted
    /// strings are allocated with `arena` (arena-own them; nothing needs
    /// individual frees). Per-source failures log a warning and never
    /// fail the sweep.
    pub fn sweep(
        self: *Fleet,
        arena: Allocator,
        io: std.Io,
        sources: config.Sources,
        now_ms: i64,
        events_out: *std.ArrayList(types.UsageEvent),
        changes_out: *std.ArrayList(snapsource.Change),
    ) void {
        for (jsonl_agents) |agent| {
            if (!sources.enabled(agent)) continue;
            const t = self.tailer(agent).?;
            const roots = self.tailerRoots(agent);
            if (t.sweepIncremental(arena, io, roots, events_out, now_ms)) |_| {} else |err| {
                warnSource(agent, err);
            }
        }
        if (sources.enabled(.goose)) {
            self.goose.poll(arena, self.goose_db, events_out) catch |err| warnSource(.goose, err);
        }
        if (sources.enabled(.kilo)) {
            self.kilo.poll(arena, self.kilo_db, events_out) catch |err| warnSource(.kilo, err);
        }
        if (sources.enabled(.cline)) {
            self.cline_sdk.sweep(arena, io, self.cline_sdk_roots, changes_out) catch |err| warnSource(.cline, err);
            self.cline_legacy.sweep(arena, io, self.cline_legacy_roots, changes_out) catch |err| warnSource(.cline, err);
        }
        if (sources.enabled(.roo)) {
            self.roo.sweep(arena, io, self.roo_roots, changes_out) catch |err| warnSource(.roo, err);
        }
    }

    /// Does this agent's data location exist on disk right now? Null for
    /// agents the fleet does not own (claude/codex/opencode are engine-
    /// driven; copilot/continue_cli/droid are dormant).
    pub fn detected(self: *const Fleet, agent: types.Agent) ?bool {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        return switch (agent) {
            .pi => anyPathExists(io, self.pi_roots),
            .gemini => anyPathExists(io, self.gemini_roots),
            .qwen => anyPathExists(io, self.qwen_roots),
            .kimi => anyPathExists(io, self.kimi_roots),
            .goose => pathExists(io, self.goose_db),
            .kilo => pathExists(io, self.kilo_db),
            .cline => anyPathExists(io, self.cline_sdk_roots) or
                anyPathExists(io, self.cline_legacy_roots),
            .roo => anyPathExists(io, self.roo_roots),
            .claude, .codex, .opencode, .copilot, .continue_cli, .droid => null,
        };
    }

    // -----------------------------------------------------------------------
    // Persistence surface (statefile save/restore)
    // -----------------------------------------------------------------------

    /// The JSONL tailer for a `jsonl_agents` member (null otherwise).
    /// Exposes the tailsource persistence API: files() for save,
    /// seedOffset/seedCwd/seedSeen for restore.
    pub fn tailer(self: *Fleet, agent: types.Agent) ?*tailsource.Tailer {
        return switch (agent) {
            .pi => &self.pi,
            .gemini => &self.gemini,
            .qwen => &self.qwen,
            .kimi => &self.kimi,
            else => null,
        };
    }

    /// Read-only twin of `tailer` for the statefile saver.
    pub fn tailerConst(self: *const Fleet, agent: types.Agent) ?*const tailsource.Tailer {
        return switch (agent) {
            .pi => &self.pi,
            .gemini => &self.gemini,
            .qwen => &self.qwen,
            .kimi => &self.kimi,
            else => null,
        };
    }

    /// The SQLite poller's high-water mark for a `sqlite_agents` member
    /// (null otherwise).
    pub fn highWater(self: *const Fleet, agent: types.Agent) ?i64 {
        return switch (agent) {
            .goose => self.goose.highWater(),
            .kilo => self.kilo.highWater(),
            else => null,
        };
    }

    /// Statefile restore: re-seed one SQLite poller's high-water mark.
    /// Other agents are ignored (forward-compatible with unknown labels).
    pub fn seedHighWater(self: *Fleet, agent: types.Agent, value: i64) void {
        switch (agent) {
            .goose => self.goose.seedHighWater(value),
            .kilo => self.kilo.seedHighWater(value),
            else => {},
        }
    }

    /// The snapshot poller behind a stable statefile name. Exposes the
    /// snapsource persistence API: files() for save, seed() for restore.
    pub fn snapPoller(self: *Fleet, name: SnapName) *snapsource.Poller {
        return switch (name) {
            .cline_sdk => &self.cline_sdk,
            .cline_legacy => &self.cline_legacy,
            .roo => &self.roo,
        };
    }

    /// Read-only twin of `snapPoller` for the statefile saver.
    pub fn snapPollerConst(self: *const Fleet, name: SnapName) *const snapsource.Poller {
        return switch (name) {
            .cline_sdk => &self.cline_sdk,
            .cline_legacy => &self.cline_legacy,
            .roo => &self.roo,
        };
    }

    fn tailerRoots(self: *const Fleet, agent: types.Agent) []const []const u8 {
        return switch (agent) {
            .pi => self.pi_roots,
            .gemini => self.gemini_roots,
            .qwen => self.qwen_roots,
            .kimi => self.kimi_roots,
            else => &.{},
        };
    }
};

fn warnSource(agent: types.Agent, err: anyerror) void {
    std.log.warn("{s} sweep failed: {s}", .{ agent.label(), @errorName(err) });
}

fn freeRoots(allocator: Allocator, roots: []const []const u8) void {
    for (roots) |p| allocator.free(p);
    allocator.free(roots);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    var cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

fn anyPathExists(io: std.Io, paths: []const []const u8) bool {
    for (paths) |p| {
        if (pathExists(io, p)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const pi_fixture = @embedFile("fixtures/pi/session1.jsonl");
const cline_sdk_fixture = @embedFile("fixtures/cline/session1.messages.json");
const roo_fixture = @embedFile("fixtures/roo/ui_messages.json");

const roo_task_rel = "home/Library/Application Support/Code/User/globalStorage/" ++
    "rooveterinaryinc.roo-cline/tasks/1783601000000";

/// Tmp tree with pi + cline(sdk) + roo fixture data, and the Env that
/// points a fleet at it. Everything else stays absent on purpose.
const FixtureTree = struct {
    tmp: testing.TmpDir,
    base_buf: [std.fs.max_path_bytes]u8,

    fn init(io: std.Io) !FixtureTree {
        var self = FixtureTree{ .tmp = testing.tmpDir(.{}), .base_buf = undefined };
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, "home");
        try self.tmp.dir.createDirPath(io, "pihome/agent/sessions");
        try self.tmp.dir.writeFile(io, .{
            .sub_path = "pihome/agent/sessions/2026-01-05T00-00-00_019faaaa-bbbb-7ccc-8ddd-eeeeffff0001.jsonl",
            .data = pi_fixture,
        });
        try self.tmp.dir.createDirPath(io, "clinedata/sessions/s1");
        try self.tmp.dir.writeFile(io, .{
            .sub_path = "clinedata/sessions/s1/s1.messages.json",
            .data = cline_sdk_fixture,
        });
        try self.tmp.dir.createDirPath(io, roo_task_rel);
        try self.tmp.dir.writeFile(io, .{
            .sub_path = roo_task_rel ++ "/ui_messages.json",
            .data = roo_fixture,
        });
        return self;
    }

    fn deinit(self: *FixtureTree) void {
        self.tmp.cleanup();
    }

    fn env(self: *FixtureTree, arena: Allocator, io: std.Io) !Env {
        const base = self.base_buf[0..try self.tmp.dir.realPath(io, &self.base_buf)];
        return .{
            .home = try std.fmt.allocPrint(arena, "{s}/home", .{base}),
            .pi_home = try std.fmt.allocPrint(arena, "{s}/pihome", .{base}),
            .cline_data_dir = try std.fmt.allocPrint(arena, "{s}/clinedata", .{base}),
        };
    }
};

test "sweep aggregates all enabled fleet sources; steady state re-emits nothing" {
    const io = testing.io;
    var tree = try FixtureTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fl = try Fleet.init(testing.allocator, try tree.env(arena, io));
    defer fl.deinit();

    var events: std.ArrayList(types.UsageEvent) = .empty;
    var changes: std.ArrayList(snapsource.Change) = .empty;
    fl.sweep(arena, io, .{}, 1_000_000, &events, &changes);

    // pi fixture: 2 assistant events. cline sdk fixture: 2 usage-bearing
    // records; roo fixture: 2 api_req_started rows -> 4 adds.
    try testing.expectEqual(@as(usize, 2), events.items.len);
    for (events.items) |ev| try testing.expectEqual(types.Agent.pi, ev.agent);
    try testing.expectEqual(@as(usize, 4), changes.items.len);
    var cline_count: usize = 0;
    var roo_count: usize = 0;
    for (changes.items) |change| {
        try testing.expect(change.previous == null);
        switch (change.current.agent) {
            .cline => cline_count += 1,
            .roo => roo_count += 1,
            else => return error.TestUnexpectedAgent,
        }
    }
    try testing.expectEqual(@as(usize, 2), cline_count);
    try testing.expectEqual(@as(usize, 2), roo_count);

    // Quiet second tick: offsets at EOF, snapshot gates hold.
    fl.sweep(arena, io, .{}, 1_002_000, &events, &changes);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqual(@as(usize, 4), changes.items.len);
}

test "sweep honors disabled sources" {
    const io = testing.io;
    var tree = try FixtureTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fl = try Fleet.init(testing.allocator, try tree.env(arena, io));
    defer fl.deinit();

    var events: std.ArrayList(types.UsageEvent) = .empty;
    var changes: std.ArrayList(snapsource.Change) = .empty;
    fl.sweep(arena, io, config.Sources.none, 1_000_000, &events, &changes);
    try testing.expectEqual(@as(usize, 0), events.items.len);
    try testing.expectEqual(@as(usize, 0), changes.items.len);

    // Only roo enabled: only roo's changes arrive.
    var roo_only = config.Sources.none;
    roo_only.enable(.roo);
    fl.sweep(arena, io, roo_only, 1_000_000, &events, &changes);
    try testing.expectEqual(@as(usize, 0), events.items.len);
    try testing.expectEqual(@as(usize, 2), changes.items.len);
    for (changes.items) |change| try testing.expectEqual(types.Agent.roo, change.current.agent);
}

test "detected reflects on-disk presence, null for non-fleet agents" {
    const io = testing.io;
    var tree = try FixtureTree.init(io);
    defer tree.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fl = try Fleet.init(testing.allocator, try tree.env(arena, io));
    defer fl.deinit();

    try testing.expectEqual(@as(?bool, true), fl.detected(.pi));
    try testing.expectEqual(@as(?bool, true), fl.detected(.cline));
    try testing.expectEqual(@as(?bool, true), fl.detected(.roo));
    // Nothing on disk for these in the fixture tree.
    try testing.expectEqual(@as(?bool, false), fl.detected(.gemini));
    try testing.expectEqual(@as(?bool, false), fl.detected(.qwen));
    try testing.expectEqual(@as(?bool, false), fl.detected(.kimi));
    try testing.expectEqual(@as(?bool, false), fl.detected(.goose));
    try testing.expectEqual(@as(?bool, false), fl.detected(.kilo));
    // Engine-driven and dormant agents are not the fleet's to answer for.
    try testing.expectEqual(@as(?bool, null), fl.detected(.claude));
    try testing.expectEqual(@as(?bool, null), fl.detected(.codex));
    try testing.expectEqual(@as(?bool, null), fl.detected(.opencode));
    try testing.expectEqual(@as(?bool, null), fl.detected(.copilot));
    try testing.expectEqual(@as(?bool, null), fl.detected(.continue_cli));
    try testing.expectEqual(@as(?bool, null), fl.detected(.droid));
}

test "persistence hooks: tailers, high-water marks, snapshot pollers" {
    var fl = try Fleet.init(testing.allocator, .{ .home = "/nonexistent/fleet-test" });
    defer fl.deinit();

    for (jsonl_agents) |agent| {
        try testing.expect(fl.tailer(agent) != null);
        try testing.expect(fl.tailerConst(agent) != null);
        try testing.expect(fl.highWater(agent) == null);
    }
    try testing.expect(fl.tailer(.goose) == null);
    try testing.expect(fl.tailer(.claude) == null);

    for (sqlite_agents) |agent| {
        try testing.expectEqual(@as(?i64, 0), fl.highWater(agent));
    }
    fl.seedHighWater(.goose, 42);
    fl.seedHighWater(.kilo, 1_234);
    fl.seedHighWater(.claude, 999); // ignored, not a sqlite agent
    try testing.expectEqual(@as(?i64, 42), fl.highWater(.goose));
    try testing.expectEqual(@as(?i64, 1_234), fl.highWater(.kilo));

    inline for (comptime std.enums.values(SnapName)) |name| {
        var it = fl.snapPollerConst(name).files();
        try testing.expect(it.next() == null);
    }
}
