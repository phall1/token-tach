//! UI-free usage collection for coding harnesses with local usage ledgers.
//!
//! Only token counters and attribution metadata leave a source parser. JSON
//! ledgers can contain conversation content, but that data remains ephemeral
//! and is never copied into Token Tach state. SQLite sources use fixed,
//! read-only projections that never select prompt/content/auth columns.

const std = @import("std");
const ledger_mod = @import("ledger.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const max_file_bytes = 64 * 1024 * 1024;
const max_jsonl_line_bytes = 16 * 1024 * 1024;

const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;
    pub const SQLITE_INTEGER: c_int = 1;
    pub const SQLITE_FLOAT: c_int = 2;
    pub const SQLITE_TEXT: c_int = 3;
    pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
    pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
    pub const SQLITE_OPEN_URI: c_int = 0x00000040;
    pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;

    pub extern fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
    pub extern fn sqlite3_close(?*sqlite3) c_int;
    pub extern fn sqlite3_busy_timeout(?*sqlite3, c_int) c_int;
    pub extern fn sqlite3_prepare_v2(?*sqlite3, [*]const u8, c_int, *?*sqlite3_stmt, ?*?[*]const u8) c_int;
    pub extern fn sqlite3_finalize(?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_step(?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_column_text(?*sqlite3_stmt, c_int) ?[*]const u8;
    pub extern fn sqlite3_column_bytes(?*sqlite3_stmt, c_int) c_int;
    pub extern fn sqlite3_column_int64(?*sqlite3_stmt, c_int) i64;
    pub extern fn sqlite3_column_double(?*sqlite3_stmt, c_int) f64;
    pub extern fn sqlite3_column_type(?*sqlite3_stmt, c_int) c_int;
    pub extern fn sqlite3_exec(?*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) c_int;
};

pub const Env = struct {
    home: []const u8,
    xdg_data_home: ?[]const u8 = null,
    gemini_cli_home: ?[]const u8 = null,
    qwen_home: ?[]const u8 = null,
    qwen_runtime_dir: ?[]const u8 = null,
    pi_agent_dir: ?[]const u8 = null,
    pi_session_dir: ?[]const u8 = null,
    kimi_share_dir: ?[]const u8 = null,
    grok_home: ?[]const u8 = null,
    copilot_home: ?[]const u8 = null,
    cline_dir: ?[]const u8 = null,
    cline_data_dir: ?[]const u8 = null,
    continue_global_dir: ?[]const u8 = null,
    kilo_db: ?[]const u8 = null,
    goose_path_root: ?[]const u8 = null,
    factory_home: ?[]const u8 = null,
};

pub const Change = struct {
    previous: ?types.UsageEvent = null,
    current: types.UsageEvent,
    remove: bool = false,
};

pub const Changes = std.ArrayList(Change);

pub const Stored = struct {
    event: types.UsageEvent,
};

pub const Fidelity = enum { exact, limited, needs_setup, unsupported };

pub const Coverage = struct {
    id: []const u8,
    agent: ?types.Agent,
    label: []const u8,
    fidelity: Fidelity,
    reason: []const u8,
};

pub const Source = enum {
    gemini,
    qwen,
    pi,
    kimi,
    grok,
    copilot,
    cline,
    roo,
    continue_cli,
    kilo,
    goose,
    droid,
};

fn integratedAgent(comptime name: []const u8) ?types.Agent {
    if (@hasField(types.Agent, name)) return @field(types.Agent, name);
    return null;
}

fn collectorAgent(comptime name: []const u8) types.Agent {
    // The fallback only lets this isolated module's parser tests run before
    // the shared enum lands. poll() rejects that integration state.
    return integratedAgent(name) orelse .opencode;
}

const agent_enum_ready = integratedAgent("gemini") != null and
    integratedAgent("qwen") != null and integratedAgent("pi") != null and
    integratedAgent("kimi") != null and integratedAgent("grok") != null and
    integratedAgent("copilot") != null and integratedAgent("cline") != null and
    integratedAgent("roo") != null and integratedAgent("continue_cli") != null and
    integratedAgent("kilo") != null and integratedAgent("goose") != null and
    integratedAgent("droid") != null;

pub const coverage_registry = [_]Coverage{
    .{ .id = "gemini", .agent = integratedAgent("gemini"), .label = "Gemini CLI", .fidelity = .exact, .reason = "Per-call token records in the Gemini chat ledger." },
    .{ .id = "qwen", .agent = integratedAgent("qwen"), .label = "Qwen Code", .fidelity = .exact, .reason = "Dedicated schema-versioned token usage ledger." },
    .{ .id = "pi", .agent = integratedAgent("pi"), .label = "Pi", .fidelity = .exact, .reason = "Assistant response usage in session JSONL." },
    .{ .id = "kimi", .agent = integratedAgent("kimi"), .label = "Kimi CLI", .fidelity = .limited, .reason = "Status updates are exact when message ids are present; older records use deterministic fingerprints." },
    .{ .id = "grok", .agent = integratedAgent("grok"), .label = "Grok CLI", .fidelity = .exact, .reason = "Completed-turn usage, split by model when available." },
    .{ .id = "copilot", .agent = integratedAgent("copilot"), .label = "GitHub Copilot CLI", .fidelity = .exact, .reason = "Dedicated assistant usage rows in the local session store." },
    .{ .id = "cline", .agent = integratedAgent("cline"), .label = "Cline", .fidelity = .limited, .reason = "Mutable cumulative session snapshots; legacy task summaries are fallback-only." },
    .{ .id = "roo", .agent = integratedAgent("roo"), .label = "Roo Code", .fidelity = .limited, .reason = "Mutable cumulative task summaries from editor global storage." },
    .{ .id = "continue_cli", .agent = integratedAgent("continue_cli"), .label = "Continue CLI", .fidelity = .limited, .reason = "Mutable cumulative session snapshots." },
    .{ .id = "kilo", .agent = integratedAgent("kilo"), .label = "Kilo Code", .fidelity = .limited, .reason = "Mutable cumulative session aggregates in SQLite." },
    .{ .id = "goose", .agent = integratedAgent("goose"), .label = "Goose", .fidelity = .exact, .reason = "Per-entry usage ledger rows." },
    .{ .id = "droid", .agent = integratedAgent("droid"), .label = "Factory Droid", .fidelity = .limited, .reason = "Mutable cumulative settings snapshots." },
};

/// Known coding surfaces that Token Tach can detect or document but cannot
/// honestly turn into exact historical token usage without prior telemetry
/// setup or reading prompt-bearing blobs.
pub const unavailable_registry = [_]Coverage{
    .{ .id = "cursor", .agent = null, .label = "Cursor", .fidelity = .unsupported, .reason = "No durable local exact-token ledger is exposed." },
    .{ .id = "windsurf", .agent = null, .label = "Windsurf", .fidelity = .unsupported, .reason = "No durable local exact-token ledger is exposed." },
    .{ .id = "aider", .agent = null, .label = "Aider", .fidelity = .needs_setup, .reason = "Exact response usage is not persisted by default." },
    .{ .id = "amp", .agent = null, .label = "Amp", .fidelity = .needs_setup, .reason = "Usage is available at runtime but no default durable ledger is documented." },
    .{ .id = "copilot-vscode", .agent = null, .label = "Copilot VS Code", .fidelity = .needs_setup, .reason = "Exact local history requires the OTel database exporter to be enabled first." },
    .{ .id = "zed", .agent = null, .label = "Zed", .fidelity = .unsupported, .reason = "Usage is embedded in a compressed prompt-bearing conversation blob." },
    .{ .id = "amazon-q", .agent = null, .label = "Amazon Q", .fidelity = .unsupported, .reason = "Local history does not contain exact provider token counters." },
    .{ .id = "crush", .agent = null, .label = "Crush", .fidelity = .unsupported, .reason = "Persisted counters are mutable context estimates, not lifetime usage." },
};

pub fn unavailableDetected(allocator: Allocator, io: std.Io, env: Env, id: []const u8) bool {
    const relative: ?[]const []const u8 = if (std.mem.eql(u8, id, "cursor"))
        &.{ env.home, "Library", "Application Support", "Cursor" }
    else if (std.mem.eql(u8, id, "windsurf"))
        &.{ env.home, "Library", "Application Support", "Windsurf" }
    else if (std.mem.eql(u8, id, "aider"))
        &.{ env.home, ".aider.conf.yml" }
    else if (std.mem.eql(u8, id, "copilot-vscode"))
        &.{ env.home, "Library", "Application Support", "Code", "User", "globalStorage", "github.copilot-chat" }
    else if (std.mem.eql(u8, id, "zed"))
        &.{ env.home, "Library", "Application Support", "Zed", "threads", "threads.db" }
    else if (std.mem.eql(u8, id, "amazon-q"))
        &.{ env.home, ".aws", "amazonq" }
    else if (std.mem.eql(u8, id, "crush")) blk: {
        const data = nonempty(env.xdg_data_home) orelse return false;
        break :blk &.{ data, "crush", "projects.json" };
    } else return false;
    const path = std.fs.path.join(allocator, relative.?) catch return false;
    defer allocator.free(path);
    return pathExists(io, path);
}

pub const SourceStatus = struct {
    source: Source,
    id: []const u8,
    active: bool,
    detected: bool = false,
};

fn initialStatuses() [coverage_registry.len]SourceStatus {
    var result: [coverage_registry.len]SourceStatus = undefined;
    inline for (coverage_registry, 0..) |item, i| {
        result[i] = .{ .source = @enumFromInt(i), .id = item.id, .active = true };
    }
    return result;
}

pub const Poller = struct {
    allocator: Allocator,
    /// Keys and events are allocator-owned and stable until replacement or deinit.
    seen: std.StringHashMapUnmanaged(Stored) = .empty,
    file_signatures: std.StringHashMapUnmanaged(FileSignature) = .empty,
    cline_database_sessions: std.StringHashMapUnmanaged(void) = .empty,
    droid_snapshot_sessions: std.StringHashMapUnmanaged(void) = .empty,
    sources: [coverage_registry.len]SourceStatus = initialStatuses(),
    dirty: bool = false,

    pub const FileSignature = struct { size: u64, mtime_ns: i96 };

    pub fn init(allocator: Allocator) Poller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Poller) void {
        var it = self.seen.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeEvent(self.allocator, entry.value_ptr.event);
        }
        self.seen.deinit(self.allocator);
        var files = self.file_signatures.keyIterator();
        while (files.next()) |path| self.allocator.free(path.*);
        self.file_signatures.deinit(self.allocator);
        clearSessionSet(self.allocator, &self.cline_database_sessions);
        self.cline_database_sessions.deinit(self.allocator);
        clearSessionSet(self.allocator, &self.droid_snapshot_sessions);
        self.droid_snapshot_sessions.deinit(self.allocator);
    }

    /// Restore one persisted source-native key and its last normalized value.
    pub fn restore(self: *Poller, key: []const u8, event: types.UsageEvent) !void {
        try self.putStored(key, event);
        self.dirty = false;
    }

    /// Public stable-state iteration for persistence. Iteration order is not stable.
    pub fn iterator(self: *Poller) std.StringHashMapUnmanaged(Stored).Iterator {
        return self.seen.iterator();
    }

    pub fn signatureIterator(self: *Poller) std.StringHashMapUnmanaged(FileSignature).Iterator {
        return self.file_signatures.iterator();
    }

    pub fn restoreFileSignature(self: *Poller, path: []const u8, signature: FileSignature) !void {
        if (self.file_signatures.getPtr(path)) |known| {
            known.* = signature;
        } else {
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.file_signatures.put(self.allocator, owned, signature);
        }
        self.dirty = false;
    }

    pub fn takeDirty(self: *Poller) bool {
        const dirty = self.dirty;
        self.dirty = false;
        return dirty;
    }

    pub fn sourceStatus(self: *const Poller, source: Source) SourceStatus {
        return self.sources[@intFromEnum(source)];
    }

    pub fn setActive(self: *Poller, source: Source, active: bool) void {
        self.sources[@intFromEnum(source)].active = active;
    }

    pub fn activeDetectedCount(self: *const Poller) usize {
        var count: usize = 0;
        for (self.sources) |status| if (status.active and status.detected) {
            count += 1;
        };
        return count;
    }

    pub fn poll(self: *Poller, event_allocator: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        if (!agent_enum_ready) return error.AgentEnumNotIntegrated;
        try self.detectSources(io, env);

        if (self.sourceStatus(.gemini).active) self.collectGemini(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.qwen).active) self.collectQwen(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.pi).active) self.collectPi(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.kimi).active) self.collectKimi(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.grok).active) self.collectGrok(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.copilot).active) self.collectCopilot(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.cline).active) self.collectCline(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.roo).active) self.collectRoo(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.continue_cli).active) self.collectContinue(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.kilo).active) self.collectKilo(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.goose).active) self.collectGoose(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
        if (self.sourceStatus(.droid).active) self.collectDroid(event_allocator, io, env, out) catch |err| if (err == error.OutOfMemory) return err;
    }

    pub fn detectSources(self: *Poller, io: std.Io, env: Env) !void {
        for (&self.sources) |*status| status.detected = false;
        inline for (std.meta.tags(Source)) |source| {
            const path = try resolvePrimaryPath(self.allocator, source, env);
            defer self.allocator.free(path);
            if (pathExists(io, path)) self.markDetected(source);
        }
    }

    fn reconcile(self: *Poller, event_allocator: Allocator, source: Source, native_key: []const u8, event: types.UsageEvent, out: *Changes) !void {
        if (event.totalTokens() == 0) return;
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(source), native_key });
        defer self.allocator.free(key);
        if (self.seen.get(key)) |old| if (eventEqual(old.event, event)) return;

        try out.ensureUnusedCapacity(event_allocator, 1);
        const current = try dupeEvent(event_allocator, event);
        errdefer freeEvent(event_allocator, current);
        const previous = if (self.seen.get(key)) |old| try dupeEvent(event_allocator, old.event) else null;
        errdefer if (previous) |old| freeEvent(event_allocator, old);
        try self.putStored(key, event);
        out.appendAssumeCapacity(.{ .previous = previous, .current = current });
    }

    /// Mutable session summaries expose lifetime counters, not immutable
    /// calls. The first observation establishes history; later monotonic
    /// updates emit only their positive delta so a whole session is not moved
    /// into the latest day every time its snapshot is rewritten.
    fn reconcileCumulative(self: *Poller, event_allocator: Allocator, source: Source, native_key: []const u8, event: types.UsageEvent, out: *Changes) !void {
        if (event.totalTokens() == 0) return;
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(source), native_key });
        defer self.allocator.free(key);
        const previous = self.seen.get(key);
        if (previous) |old| {
            if (eventEqual(old.event, event)) return;
            const delta = types.UsageEvent{
                .agent = event.agent,
                .timestamp_ms = event.timestamp_ms,
                .model = event.model,
                .input_tokens = cumulativeDelta(old.event.input_tokens, event.input_tokens),
                .output_tokens = cumulativeDelta(old.event.output_tokens, event.output_tokens),
                .cache_creation_tokens = cumulativeDelta(old.event.cache_creation_tokens, event.cache_creation_tokens),
                .cache_read_tokens = cumulativeDelta(old.event.cache_read_tokens, event.cache_read_tokens),
                .session_id = event.session_id,
                .cwd = event.cwd,
            };
            if (delta.totalTokens() > 0) {
                try out.ensureUnusedCapacity(event_allocator, 1);
                const current = try dupeEvent(event_allocator, delta);
                errdefer freeEvent(event_allocator, current);
                try self.putStored(key, event);
                out.appendAssumeCapacity(.{ .current = current });
            } else {
                try self.putStored(key, event);
            }
            return;
        }

        try out.ensureUnusedCapacity(event_allocator, 1);
        const current = try dupeEvent(event_allocator, event);
        errdefer freeEvent(event_allocator, current);
        try self.putStored(key, event);
        out.appendAssumeCapacity(.{ .current = current });
    }

    fn putStored(self: *Poller, key: []const u8, event: types.UsageEvent) !void {
        const owned_event = try dupeEvent(self.allocator, event);
        errdefer freeEvent(self.allocator, owned_event);
        if (self.seen.getPtr(key)) |slot| {
            freeEvent(self.allocator, slot.event);
            slot.* = .{ .event = owned_event };
            self.dirty = true;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.seen.put(self.allocator, owned_key, .{ .event = owned_event });
        self.dirty = true;
    }

    fn removeOtherSessionRecords(self: *Poller, ea: Allocator, source: Source, native_key: []const u8, session_id: []const u8, out: *Changes) !void {
        if (session_id.len == 0) return;
        const keep = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(source), native_key });
        defer self.allocator.free(keep);
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}:", .{@tagName(source)});
        defer self.allocator.free(prefix);
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.seen.iterator();
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix) or std.mem.eql(u8, entry.key_ptr.*, keep)) continue;
            if (std.mem.eql(u8, entry.value_ptr.event.session_id, session_id)) try stale.append(self.allocator, entry.key_ptr.*);
        }
        try out.ensureUnusedCapacity(ea, stale.items.len);
        for (stale.items) |key| {
            const stored = self.seen.get(key) orelse continue;
            const previous = try dupeEvent(ea, stored.event);
            errdefer freeEvent(ea, previous);
            var zero = stored.event;
            zero.input_tokens = 0;
            zero.output_tokens = 0;
            zero.cache_creation_tokens = 0;
            zero.cache_read_tokens = 0;
            const current = try dupeEvent(ea, zero);
            errdefer freeEvent(ea, current);
            const removed = self.seen.fetchRemove(key) orelse unreachable;
            out.appendAssumeCapacity(.{ .previous = previous, .current = current, .remove = true });
            self.allocator.free(removed.key);
            freeEvent(self.allocator, removed.value.event);
            self.dirty = true;
        }
    }

    fn removeRecordsWithPrefix(self: *Poller, ea: Allocator, prefix: []const u8, out: *Changes) !void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |key| if (std.mem.startsWith(u8, key.*, prefix)) try stale.append(self.allocator, key.*);
        try out.ensureUnusedCapacity(ea, stale.items.len);
        for (stale.items) |key| {
            const stored = self.seen.get(key) orelse continue;
            const previous = try dupeEvent(ea, stored.event);
            errdefer freeEvent(ea, previous);
            var zero = stored.event;
            zero.input_tokens = 0;
            zero.output_tokens = 0;
            zero.cache_creation_tokens = 0;
            zero.cache_read_tokens = 0;
            const current = try dupeEvent(ea, zero);
            errdefer freeEvent(ea, current);
            const removed = self.seen.fetchRemove(key) orelse unreachable;
            out.appendAssumeCapacity(.{ .previous = previous, .current = current, .remove = true });
            self.allocator.free(removed.key);
            freeEvent(self.allocator, removed.value.event);
            self.dirty = true;
        }
    }

    fn markDetected(self: *Poller, source: Source) void {
        self.sources[@intFromEnum(source)].detected = true;
    }

    fn collectGemini(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .gemini, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .gemini, .gemini, ea, out);
    }

    fn collectQwen(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .qwen, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .qwen, .qwen, ea, out);
    }

    fn collectPi(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .pi, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .pi, .pi, ea, out);
    }

    fn collectKimi(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .kimi, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .kimi, .kimi, ea, out);
    }

    fn collectGrok(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .grok, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .grok, .grok, ea, out);
    }

    fn collectCopilot(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const path = try resolvePrimaryPath(self.allocator, .copilot, env);
        defer self.allocator.free(path);
        _ = try self.scanDatabase(ea, io, .copilot, path, &copilot_queries, .copilot, out);
    }

    fn collectCline(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        clearSessionSet(self.allocator, &self.cline_database_sessions);
        var stored = self.seen.iterator();
        while (stored.next()) |entry| {
            const database_prefix = "cline:database:";
            const snapshot_prefix = "cline:snapshot:";
            const prefix = if (std.mem.startsWith(u8, entry.key_ptr.*, database_prefix))
                database_prefix
            else if (std.mem.startsWith(u8, entry.key_ptr.*, snapshot_prefix))
                snapshot_prefix
            else
                continue;
            try putSession(self.allocator, &self.cline_database_sessions, entry.key_ptr.*[prefix.len..]);
            try putSession(self.allocator, &self.cline_database_sessions, entry.value_ptr.event.session_id);
        }
        const data = try resolveClineData(self.allocator, env);
        defer self.allocator.free(data);
        const db_path = try std.fs.path.join(self.allocator, &.{ data, "db", "sessions.db" });
        defer self.allocator.free(db_path);
        if (pathExists(io, db_path)) {
            _ = try self.scanDatabase(ea, io, .cline, db_path, &cline_queries, .cline, out);
        }
        const tasks = try std.fs.path.join(self.allocator, &.{ data, "tasks" });
        defer self.allocator.free(tasks);
        try self.walk(tasks, io, .cline, .cline_legacy, ea, out);
        const app_support = [_][]const u8{ "Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf" };
        for (app_support) |app| {
            const root = try std.fs.path.join(self.allocator, &.{ env.home, "Library", "Application Support", app, "User", "globalStorage", "saoudrizwan.claude-dev", "tasks" });
            defer self.allocator.free(root);
            self.walk(root, io, .cline, .cline_ui, ea, out) catch |err| if (err == error.OutOfMemory) return err;
            self.walk(root, io, .cline, .cline_messages, ea, out) catch |err| if (err == error.OutOfMemory) return err;
        }
    }

    fn collectRoo(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const app_support = [_][]const u8{ "Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf" };
        for (app_support) |app| {
            const root = try std.fs.path.join(self.allocator, &.{ env.home, "Library", "Application Support", app, "User", "globalStorage", "rooveterinaryinc.roo-cline", "tasks" });
            defer self.allocator.free(root);
            self.walk(root, io, .roo, .roo, ea, out) catch |err| if (err == error.OutOfMemory) return err;
        }
        const mock = try std.fs.path.join(self.allocator, &.{ env.home, ".vscode-mock", "global-storage", "rooveterinaryinc.roo-cline", "tasks" });
        defer self.allocator.free(mock);
        try self.walk(mock, io, .roo, .roo, ea, out);
    }

    fn collectContinue(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const root = try resolvePrimaryPath(self.allocator, .continue_cli, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .continue_cli, .continue_cli, ea, out);
    }

    fn collectKilo(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const path = try resolvePrimaryPath(self.allocator, .kilo, env);
        defer self.allocator.free(path);
        _ = try self.scanDatabase(ea, io, .kilo, path, &kilo_queries, .kilo, out);
    }

    fn collectGoose(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        const path = try resolvePrimaryPath(self.allocator, .goose, env);
        defer self.allocator.free(path);
        _ = try self.scanDatabase(ea, io, .goose, path, &goose_queries, .goose, out);
        if (nonempty(env.goose_path_root) == null) {
            const xdg = if (nonempty(env.xdg_data_home)) |data|
                try std.fs.path.join(self.allocator, &.{ data, "goose", "sessions", "sessions.db" })
            else
                try std.fs.path.join(self.allocator, &.{ env.home, ".local", "share", "goose", "sessions", "sessions.db" });
            defer self.allocator.free(xdg);
            _ = try self.scanDatabase(ea, io, .goose, xdg, &goose_queries, .goose, out);

            // Some packaged Goose builds have used an explicit data segment
            // beneath the macOS application-support root.
            const mac_data = try std.fs.path.join(self.allocator, &.{ env.home, "Library", "Application Support", "Block", "goose", "data", "sessions", "sessions.db" });
            defer self.allocator.free(mac_data);
            _ = try self.scanDatabase(ea, io, .goose, mac_data, &goose_queries, .goose, out);
        }
    }

    fn collectDroid(self: *Poller, ea: Allocator, io: std.Io, env: Env, out: *Changes) !void {
        clearSessionSet(self.allocator, &self.droid_snapshot_sessions);
        var stored = self.seen.iterator();
        while (stored.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, "droid:snapshot-settings:") and !std.mem.startsWith(u8, entry.key_ptr.*, "droid:snapshot-metadata:")) continue;
            try putSession(self.allocator, &self.droid_snapshot_sessions, entry.value_ptr.event.session_id);
            try putSession(self.allocator, &self.droid_snapshot_sessions, droidSnapshotSession(entry.key_ptr.*));
        }
        const root = try resolvePrimaryPath(self.allocator, .droid, env);
        defer self.allocator.free(root);
        try self.walk(root, io, .droid, .droid, ea, out);
        try self.walk(root, io, .droid, .droid_metadata, ea, out);
        try self.walk(root, io, .droid, .droid_jsonl, ea, out);
    }

    const FileKind = enum { gemini, qwen, pi, kimi, grok, cline_legacy, cline_ui, cline_messages, roo, continue_cli, droid, droid_metadata, droid_jsonl };

    const PiContext = struct {
        session: []const u8,
        cwd: []const u8 = "",
        model: []const u8 = "pi",
        owned_session: ?[]u8 = null,
        owned_cwd: ?[]u8 = null,
        owned_model: ?[]u8 = null,

        fn deinit(self: *PiContext, allocator: Allocator) void {
            if (self.owned_session) |value| allocator.free(value);
            if (self.owned_cwd) |value| allocator.free(value);
            if (self.owned_model) |value| allocator.free(value);
        }
    };

    fn walk(self: *Poller, root: []const u8, io: std.Io, source: Source, kind: FileKind, ea: Allocator, out: *Changes) !void {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        self.markDetected(source);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while ((walker.next(io) catch null)) |entry| {
            if (entry.kind != .file or !matchesFile(kind, entry.path, entry.basename)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ root, entry.path });
            defer self.allocator.free(path);
            if (kind == .droid_jsonl) {
                if (self.droid_snapshot_sessions.contains(droidSessionId(path))) continue;
            }
            if (kind == .cline_ui) {
                const messages = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(path) orelse root, "api_conversation_history.json" });
                defer self.allocator.free(messages);
                if (pathExists(io, messages)) continue;
            }
            const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
            const signature = FileSignature{ .size = stat.size, .mtime_ns = stat.mtime.nanoseconds };
            const droid_snapshot = kind == .droid or kind == .droid_metadata;
            const file_session = if (droid_snapshot) droidSessionId(path) else "";
            var snapshot_key: ?[]u8 = null;
            defer if (snapshot_key) |key| self.allocator.free(key);
            if (droid_snapshot) {
                const native_key = try droidSnapshotNativeKey(self.allocator, path);
                defer self.allocator.free(native_key);
                snapshot_key = try std.fmt.allocPrint(self.allocator, "droid:{s}", .{native_key});
                if (self.seen.get(snapshot_key.?) == null and self.droid_snapshot_sessions.contains(file_session)) continue;
            }
            if (self.file_signatures.get(path)) |known| {
                if (known.size == signature.size and known.mtime_ns == signature.mtime_ns) {
                    if (!droid_snapshot) continue;
                    if (self.seen.get(snapshot_key.?)) |stored_snapshot| {
                        try putSession(self.allocator, &self.droid_snapshot_sessions, file_session);
                        try putSession(self.allocator, &self.droid_snapshot_sessions, stored_snapshot.event.session_id);
                        continue;
                    }
                }
            }
            self.scanFile(ea, io, source, kind, path, out) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            if (self.file_signatures.getPtr(path)) |known| {
                known.* = signature;
            } else {
                const owned = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(owned);
                try self.file_signatures.put(self.allocator, owned, signature);
            }
            self.dirty = true;
        }
    }

    fn scanFile(self: *Poller, ea: Allocator, io: std.Io, source: Source, kind: FileKind, path: []const u8, out: *Changes) !void {
        if (isLineFile(kind) and !(kind == .gemini and std.mem.endsWith(u8, path, ".json"))) {
            return self.scanLineFile(ea, io, kind, path, out);
        }
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_file_bytes)) catch |err| return err;
        defer self.allocator.free(data);
        const fallback_ms = fileMtimeMs(io, path) orelse 0;
        if (kind == .gemini and std.mem.endsWith(u8, path, ".json")) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
            defer parsed.deinit();
            try self.parseGemini(ea, path, parsed.value, out);
            return;
        }
        switch (kind) {
            .gemini, .qwen, .kimi, .grok => {
                var lines = std.mem.splitScalar(u8, data, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch continue;
                    defer parsed.deinit();
                    switch (kind) {
                        .gemini => try self.parseGemini(ea, path, parsed.value, out),
                        .qwen => try self.parseQwen(ea, parsed.value, out),
                        .kimi => try self.parseKimi(ea, path, parsed.value, null, 0, out),
                        .grok => try self.parseGrok(ea, path, parsed.value, out),
                        else => unreachable,
                    }
                }
            },
            .pi => try self.scanPi(ea, data, path, out),
            .cline_legacy, .cline_ui, .cline_messages, .roo, .continue_cli, .droid, .droid_metadata => {
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
                defer parsed.deinit();
                switch (kind) {
                    .cline_legacy => try self.parseTaskSnapshot(ea, .cline, path, fallback_ms, parsed.value, out),
                    .cline_ui => try self.parseClineUi(ea, path, parsed.value, out),
                    .cline_messages => try self.parseClineMessages(ea, path, parsed.value, out),
                    .roo => try self.parseTaskSnapshot(ea, .roo, path, fallback_ms, parsed.value, out),
                    .continue_cli => try self.parseContinue(ea, path, fallback_ms, parsed.value, out),
                    .droid, .droid_metadata => _ = try self.parseDroid(ea, path, fallback_ms, parsed.value, out),
                    else => unreachable,
                }
            },
            .droid_jsonl => {
                var lines = std.mem.splitScalar(u8, data, '\n');
                var line_no: usize = 0;
                while (lines.next()) |line| : (line_no += 1) {
                    if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
                    defer parsed.deinit();
                    try self.parseDroidCall(ea, path, line_no, parsed.value, out);
                }
            },
        }
        _ = source;
    }

    fn scanLineFile(self: *Poller, ea: Allocator, io: std.Io, kind: FileKind, path: []const u8, out: *Changes) !void {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        var line = std.Io.Writer.Allocating.init(self.allocator);
        defer line.deinit();
        var pi_context = PiContext{ .session = path };
        defer pi_context.deinit(self.allocator);
        var line_no: usize = 0;

        while (true) : (line_no += 1) {
            line.clearRetainingCapacity();
            _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(max_jsonl_line_bytes)) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => return error.StreamTooLong,
            };
            const raw = std.mem.trim(u8, line.written(), " \t\r");
            const next = reader.interface.peek(1) catch |err| switch (err) {
                error.EndOfStream => null,
                error.ReadFailed => return error.ReadFailed,
            };
            if (next) |byte| if (byte[0] == '\n') reader.interface.toss(1);
            if (raw.len > 0) {
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
                    if (next == null) break;
                    continue;
                };
                defer parsed.deinit();
                switch (kind) {
                    .gemini => try self.parseGemini(ea, path, parsed.value, out),
                    .qwen => try self.parseQwen(ea, parsed.value, out),
                    .pi => try self.parsePiValue(ea, &pi_context, parsed.value, out),
                    .kimi => try self.parseKimi(ea, path, parsed.value, null, 0, out),
                    .grok => try self.parseGrok(ea, path, parsed.value, out),
                    .droid_jsonl => try self.parseDroidCall(ea, path, line_no, parsed.value, out),
                    else => unreachable,
                }
            }
            if (next == null) break;
        }
    }

    fn parseGemini(self: *Poller, ea: Allocator, path: []const u8, value: std.json.Value, out: *Changes) !void {
        if (!stringEquals(value, "type", "gemini")) {
            if (arrayAny(value, &.{"messages"})) |messages| {
                for (messages.array.items) |message| try self.parseGemini(ea, path, message, out);
            }
            if (objectAny(value, &.{"$set"})) |set| {
                if (arrayAny(set, &.{"messages"})) |messages| {
                    for (messages.array.items) |message| try self.parseGemini(ea, path, message, out);
                }
            }
            return;
        }
        const usage = objectAny(value, &.{ "tokens", "usage" }) orelse return;
        const id = stringAny(value, &.{ "id", "messageId", "message_id" }) orelse return;
        const timestamp_ms = timestampAny(value, &.{ "timestamp", "createdAt", "created_at" }) orelse return;
        const input = u64Any(usage, &.{ "input", "inputTokens", "input_tokens", "promptTokenCount" });
        const cache = u64Any(usage, &.{ "cached", "cachedTokens", "cached_tokens", "cacheReadTokens" });
        const output = u64Any(usage, &.{ "output", "outputTokens", "output_tokens", "candidatesTokenCount" });
        const thoughts = u64Any(usage, &.{ "thoughts", "thoughtsTokens", "thoughts_tokens" });
        const model = stringAny(value, &.{ "model", "modelId", "model_id" }) orelse "gemini";
        const session = stringAny(value, &.{ "sessionId", "session_id" }) orelse path;
        // Gemini message IDs are UUIDs and survive legacy .json -> .jsonl
        // migration. Keying on the ID prevents the retained legacy file and
        // its migrated copy from being counted twice.
        try self.reconcile(ea, .gemini, id, .{
            .agent = collectorAgent("gemini"),
            .timestamp_ms = timestamp_ms,
            .model = model,
            .input_tokens = input -| cache,
            .output_tokens = output +| thoughts,
            .cache_read_tokens = cache,
            .session_id = session,
        }, out);
    }

    fn parseQwen(self: *Poller, ea: Allocator, value: std.json.Value, out: *Changes) !void {
        if (u64Any(value, &.{"schemaVersion"}) != 1) return;
        const id = stringAny(value, &.{ "id", "eventId", "event_id" }) orelse return;
        const usage = objectAny(value, &.{ "usage", "tokens" }) orelse value;
        const timestamp_ms = timestampAny(value, &.{ "timestamp", "createdAt", "created_at" }) orelse return;
        const input = u64Any(usage, &.{ "inputTokens", "input_tokens", "input" });
        const cache = u64Any(usage, &.{ "cachedTokens", "cached_tokens", "cacheReadTokens" });
        const output = u64Any(usage, &.{ "outputTokens", "output_tokens", "output" });
        const thoughts = u64Any(usage, &.{ "thoughtsTokens", "thoughts_tokens", "thoughts" });
        try self.reconcile(ea, .qwen, id, .{
            .agent = collectorAgent("qwen"),
            .timestamp_ms = timestamp_ms,
            .model = stringAny(value, &.{ "model", "modelId", "model_id" }) orelse "qwen",
            .input_tokens = input -| cache,
            .output_tokens = output +| thoughts,
            .cache_read_tokens = cache,
            .session_id = stringAny(value, &.{ "sessionId", "session_id" }) orelse "",
            .cwd = stringAny(value, &.{ "cwd", "workspace" }) orelse "",
        }, out);
    }

    fn scanPi(self: *Poller, ea: Allocator, data: []const u8, path: []const u8, out: *Changes) !void {
        var context = PiContext{ .session = path };
        defer context.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch continue;
            defer parsed.deinit();
            try self.parsePiValue(ea, &context, parsed.value, out);
        }
    }

    fn parsePiValue(self: *Poller, ea: Allocator, context: *PiContext, root: std.json.Value, out: *Changes) !void {
        if (stringEquals(root, "type", "session") or stringEquals(root, "type", "session_header")) {
            if (stringAny(root, &.{ "id", "sessionId", "session_id" })) |value| try replaceOwned(self.allocator, &context.owned_session, &context.session, value);
            if (stringAny(root, &.{ "cwd", "workspace" })) |value| try replaceOwned(self.allocator, &context.owned_cwd, &context.cwd, value);
            return;
        }
        if (stringEquals(root, "type", "model_change")) {
            if (stringAny(root, &.{ "modelId", "model_id", "model" })) |value| try replaceOwned(self.allocator, &context.owned_model, &context.model, value);
            return;
        }
        const message = objectAny(root, &.{"message"}) orelse root;
        const assistant = stringEquals(message, "role", "assistant") or stringEquals(root, "type", "assistant");
        const tool_result = stringEquals(message, "role", "toolResult");
        const summary_call = stringEquals(root, "type", "compaction") or stringEquals(root, "type", "branch_summary");
        if (!assistant and !tool_result and !summary_call) return;
        const usage = objectAny(message, &.{ "usage", "tokens" }) orelse objectAny(root, &.{ "usage", "tokens" }) orelse return;
        const entry_id = stringAny(root, &.{ "id", "entryId", "entry_id" }) orelse return;
        const timestamp_ms = timestampAny(root, &.{ "timestamp", "createdAt", "created_at" }) orelse timestampAny(message, &.{ "timestamp", "createdAt", "created_at" }) orelse return;
        const event_model = stringAny(message, &.{ "model", "modelId", "model_id" }) orelse context.model;
        const response_id = stringAny(message, &.{ "responseId", "response_id" }) orelse stringAny(root, &.{ "responseId", "response_id" });
        const key = if (response_id) |id|
            try self.allocator.dupe(u8, id)
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{d}:{s}:{d}:{d}:{d}:{d}", .{
                entry_id,
                timestamp_ms,
                event_model,
                u64Any(usage, &.{ "input", "inputTokens", "input_tokens" }),
                u64Any(usage, &.{ "output", "outputTokens", "output_tokens" }),
                u64Any(usage, &.{ "cacheRead", "cache_read", "cacheReadTokens" }),
                u64Any(usage, &.{ "cacheWrite", "cache_write", "cacheWriteTokens" }),
            });
        defer self.allocator.free(key);
        if (assistant and !std.mem.eql(u8, event_model, context.model)) try replaceOwned(self.allocator, &context.owned_model, &context.model, event_model);
        try self.reconcile(ea, .pi, key, .{
            .agent = collectorAgent("pi"),
            .timestamp_ms = timestamp_ms,
            .model = event_model,
            .input_tokens = u64Any(usage, &.{ "input", "inputTokens", "input_tokens" }),
            .output_tokens = u64Any(usage, &.{ "output", "outputTokens", "output_tokens" }),
            .cache_read_tokens = u64Any(usage, &.{ "cacheRead", "cache_read", "cacheReadTokens" }),
            .cache_creation_tokens = u64Any(usage, &.{ "cacheWrite", "cache_write", "cacheWriteTokens" }),
            .session_id = context.session,
            .cwd = context.cwd,
        }, out);
    }

    fn parseKimi(self: *Poller, ea: Allocator, path: []const u8, value: std.json.Value, inherited: ?std.json.Value, depth: u8, out: *Changes) !void {
        if (depth > 8 or value != .object) return;
        if (value.object.get("message")) |message| {
            try self.parseKimi(ea, path, message, inherited orelse value, depth + 1, out);
            return;
        }
        if (stringEquals(value, "type", "StatusUpdate")) {
            const usage = objectAny(value, &.{ "token_usage", "tokenUsage" }) orelse blk: {
                const payload = objectAny(value, &.{ "payload", "data" }) orelse return;
                break :blk objectAny(payload, &.{ "token_usage", "tokenUsage" }) orelse return;
            };
            const context = objectAny(value, &.{ "payload", "data" }) orelse value;
            const outer = inherited orelse value;
            const timestamp_ms = timestampSecondsAny(context, &.{ "timestamp", "created_at", "createdAt" }) orelse
                timestampSecondsAny(value, &.{ "timestamp", "created_at", "createdAt" }) orelse
                timestampSecondsAny(outer, &.{ "timestamp", "created_at", "createdAt" }) orelse return;
            const model = stringAny(context, &.{ "model", "model_id", "modelId" }) orelse stringAny(outer, &.{ "model", "model_id", "modelId" }) orelse "kimi";
            const message_id = stringAny(context, &.{ "message_id", "messageId" }) orelse stringAny(value, &.{ "message_id", "messageId" });
            const native = if (message_id) |id|
                try self.allocator.dupe(u8, id)
            else
                try std.fmt.allocPrint(self.allocator, "{s}:{d}:{s}:{d}:{d}:{d}:{d}", .{ path, timestamp_ms, model, u64Any(usage, &.{ "input_other", "inputOther" }), u64Any(usage, &.{ "output", "output_tokens" }), u64Any(usage, &.{ "input_cache_read", "cache_read" }), u64Any(usage, &.{ "input_cache_creation", "cache_creation" }) });
            defer self.allocator.free(native);
            try self.reconcile(ea, .kimi, native, .{
                .agent = collectorAgent("kimi"),
                .timestamp_ms = timestamp_ms,
                .model = model,
                .input_tokens = u64Any(usage, &.{ "input_other", "inputOther", "input" }),
                .output_tokens = u64Any(usage, &.{ "output", "output_tokens", "outputTokens" }),
                .cache_read_tokens = u64Any(usage, &.{ "input_cache_read", "cache_read", "cacheReadTokens" }),
                .cache_creation_tokens = u64Any(usage, &.{ "input_cache_creation", "cache_creation", "cacheWriteTokens" }),
                .session_id = stringAny(context, &.{ "session_id", "sessionId" }) orelse path,
                .cwd = stringAny(context, &.{ "cwd", "workspace" }) orelse "",
            }, out);
            return;
        }
        if (stringEquals(value, "type", "SubagentEvent")) {
            if (objectAny(value, &.{ "payload", "data" })) |payload| {
                if (payload.object.get("event")) |event| {
                    try self.parseKimi(ea, path, event, inherited orelse value, depth + 1, out);
                    return;
                }
            }
            if (value.object.get("event")) |event| try self.parseKimi(ea, path, event, inherited orelse value, depth + 1, out);
        }
    }

    fn parseGrok(self: *Poller, ea: Allocator, path: []const u8, value: std.json.Value, out: *Changes) !void {
        if (value != .object) return;
        const params = objectAny(value, &.{"params"}) orelse return;
        const update = objectAny(params, &.{"update"}) orelse return;
        if (!stringEquals(update, "sessionUpdate", "turn_completed")) return;
        const meta = objectAny(params, &.{"_meta"}) orelse objectAny(value, &.{"_meta"});
        const timestamp_ms = (if (meta) |m| timestampMillisecondsAny(m, &.{"agentTimestampMs"}) else null) orelse
            timestampSecondsAny(value, &.{ "timestamp", "createdAt", "created_at" }) orelse return;
        const session = stringAny(params, &.{ "sessionId", "session_id" }) orelse path;
        const turn = stringAny(update, &.{ "promptId", "prompt_id", "id", "turnId" }) orelse return;
        const usage = objectAny(update, &.{ "usage", "tokenUsage", "token_usage" }) orelse return;
        if (objectAny(usage, &.{ "modelUsage", "model_usage" })) |models| {
            var it = models.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                try self.emitGrokUsage(ea, session, turn, timestamp_ms, entry.key_ptr.*, entry.value_ptr.*, out);
            }
            return;
        }
        try self.emitGrokUsage(ea, session, turn, timestamp_ms, stringAny(update, &.{ "model", "modelId", "model_id" }) orelse "grok", usage, out);
    }

    fn emitGrokUsage(self: *Poller, ea: Allocator, session: []const u8, turn: []const u8, timestamp_ms: i64, model: []const u8, usage: std.json.Value, out: *Changes) !void {
        const input = u64Any(usage, &.{ "inputTokens", "input_tokens", "input" });
        const cache_read = u64Any(usage, &.{ "cachedTokens", "cachedReadTokens", "cacheReadTokens", "cache_read_tokens" });
        const cache_write = u64Any(usage, &.{ "cacheWriteTokens", "cache_creation_tokens" });
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{ session, turn, model });
        defer self.allocator.free(key);
        try self.reconcile(ea, .grok, key, .{
            .agent = collectorAgent("grok"),
            .timestamp_ms = timestamp_ms,
            .model = model,
            .input_tokens = input -| (cache_read +| cache_write),
            .output_tokens = u64Any(usage, &.{ "outputTokens", "output_tokens", "output" }),
            .cache_read_tokens = cache_read,
            .cache_creation_tokens = cache_write,
            .session_id = session,
        }, out);
    }

    fn parseTaskSnapshot(self: *Poller, ea: Allocator, source: Source, path: []const u8, fallback_ms: i64, value: std.json.Value, out: *Changes) !void {
        if (value != .object) return;
        if (boolAny(value, &.{ "isSubagent", "is_subagent" }) orelse false) return;
        if (stringAny(value, &.{ "parentTaskId", "parent_task_id" }) != null) return;
        const id = stringAny(value, &.{ "id", "taskId", "task_id", "sessionId" }) orelse path;
        const native_key = if (source == .cline) try std.fmt.allocPrint(self.allocator, "snapshot:{s}", .{id}) else try self.allocator.dupe(u8, id);
        defer self.allocator.free(native_key);
        if (source == .cline) {
            const stored_key = try std.fmt.allocPrint(self.allocator, "cline:{s}", .{native_key});
            defer self.allocator.free(stored_key);
            if (self.cline_database_sessions.contains(id) and !self.seen.contains(stored_key)) return;
            try putSession(self.allocator, &self.cline_database_sessions, id);
            try self.removeOtherSessionRecords(ea, source, native_key, id, out);
        }
        const input = u64Any(value, &.{ "tokensIn", "inputTokens", "input_tokens" });
        const read = u64Any(value, &.{ "cacheReads", "cacheReadTokens", "cache_read_tokens" });
        const write = u64Any(value, &.{ "cacheWrites", "cacheWriteTokens", "cache_write_tokens" });
        const fallback = if (source == .roo) "roo" else "cline";
        try self.reconcileCumulative(ea, source, native_key, .{
            .agent = if (source == .roo) collectorAgent("roo") else collectorAgent("cline"),
            .timestamp_ms = timestampAny(value, &.{ "ts", "updatedAt", "updated_at", "createdAt", "created_at" }) orelse fallback_ms,
            .model = stringAny(value, &.{ "model", "modelId", "model_id" }) orelse fallback,
            .input_tokens = input -| (read +| write),
            .output_tokens = u64Any(value, &.{ "tokensOut", "outputTokens", "output_tokens" }),
            .cache_read_tokens = read,
            .cache_creation_tokens = write,
            .session_id = id,
            .cwd = stringAny(value, &.{ "workspace", "workspaceDirectory", "cwd" }) orelse "",
        }, out);
    }

    fn parseClineUi(self: *Poller, ea: Allocator, path: []const u8, value: std.json.Value, out: *Changes) !void {
        if (value != .array) return;
        for (value.array.items) |entry| {
            if (!stringEquals(entry, "type", "say") or !stringEquals(entry, "say", "api_req_started")) continue;
            const encoded = stringAny(entry, &.{"text"}) orelse continue;
            var usage = std.json.parseFromSlice(std.json.Value, self.allocator, encoded, .{}) catch continue;
            defer usage.deinit();
            const timestamp_ms = timestampAny(entry, &.{ "ts", "timestamp" }) orelse continue;
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ path, timestamp_ms });
            defer self.allocator.free(key);
            const input = u64Any(usage.value, &.{ "tokensIn", "inputTokens" });
            const cache_read = u64Any(usage.value, &.{ "cacheReads", "cacheReadTokens" });
            const cache_write = u64Any(usage.value, &.{ "cacheWrites", "cacheWriteTokens" });
            const session_id = std.fs.path.basename(std.fs.path.dirname(path) orelse path);
            if (self.cline_database_sessions.contains(session_id)) continue;
            try self.reconcile(ea, .cline, key, .{
                .agent = collectorAgent("cline"),
                .timestamp_ms = timestamp_ms,
                .model = stringAny(usage.value, &.{ "model", "modelId" }) orelse "cline",
                .input_tokens = input -| (cache_read +| cache_write),
                .output_tokens = u64Any(usage.value, &.{ "tokensOut", "outputTokens" }),
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session_id,
            }, out);
        }
    }

    fn parseClineMessages(self: *Poller, ea: Allocator, path: []const u8, value: std.json.Value, out: *Changes) !void {
        const messages = if (value == .array) value else arrayAny(value, &.{"messages"}) orelse return;
        const ui_path = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(path) orelse path, "ui_messages.json" });
        defer self.allocator.free(ui_path);
        const ui_prefix = try std.fmt.allocPrint(self.allocator, "cline:{s}:", .{ui_path});
        defer self.allocator.free(ui_prefix);
        try self.removeRecordsWithPrefix(ea, ui_prefix, out);
        for (messages.array.items, 0..) |message, index| {
            if (!stringEquals(message, "role", "assistant")) continue;
            const usage = objectAny(message, &.{"metrics"}) orelse continue;
            const timestamp_ms = timestampAny(message, &.{ "ts", "timestamp" }) orelse continue;
            const session_id = stringAny(message, &.{"sessionId"}) orelse std.fs.path.basename(std.fs.path.dirname(path) orelse path);
            if (self.cline_database_sessions.contains(session_id)) continue;
            const id = stringAny(message, &.{"id"});
            const key = if (id) |stable| try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ path, stable }) else try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}", .{ path, timestamp_ms, index });
            defer self.allocator.free(key);
            const model_info = objectAny(message, &.{"modelInfo"});
            const input = u64Any(usage, &.{"inputTokens"});
            const cache_read = u64Any(usage, &.{"cacheReadTokens"});
            const cache_write = u64Any(usage, &.{"cacheWriteTokens"});
            try self.reconcile(ea, .cline, key, .{
                .agent = collectorAgent("cline"),
                .timestamp_ms = timestamp_ms,
                .model = if (model_info) |info| stringAny(info, &.{"id"}) orelse "cline" else "cline",
                .input_tokens = input -| (cache_read +| cache_write),
                .output_tokens = u64Any(usage, &.{"outputTokens"}),
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session_id,
            }, out);
        }
    }

    fn parseContinue(self: *Poller, ea: Allocator, path: []const u8, fallback_ms: i64, value: std.json.Value, out: *Changes) !void {
        const usage = objectAny(value, &.{ "usage", "tokenUsage", "token_usage" }) orelse return;
        const id = stringAny(value, &.{ "sessionId", "session_id", "id" }) orelse path;
        const input = u64Any(usage, &.{ "inputTokens", "promptTokens", "input_tokens" });
        const prompt_details = objectAny(usage, &.{ "promptTokensDetails", "prompt_tokens_details" });
        const completion_details = objectAny(usage, &.{ "completionTokensDetails", "completion_tokens_details" });
        const flat_read = u64Any(usage, &.{ "cacheReadTokens", "cachedTokens", "cache_read_tokens" });
        const nested_read = if (prompt_details) |details| u64Any(details, &.{ "cachedTokens", "cacheReadTokens", "cached_tokens" }) else 0;
        const read = if (flat_read > 0) flat_read else nested_read;
        const flat_write = u64Any(usage, &.{ "cacheWriteTokens", "cache_creation_tokens" });
        const nested_write = if (prompt_details) |details| u64Any(details, &.{ "cacheWriteTokens", "cache_write_tokens" }) else 0;
        const write = if (flat_write > 0) flat_write else nested_write;
        const output = u64Any(usage, &.{ "outputTokens", "completionTokens", "output_tokens" });
        const flat_reasoning = u64Any(usage, &.{ "reasoningTokens", "thinkingTokens", "reasoning_tokens" });
        const nested_reasoning = if (completion_details) |details| u64Any(details, &.{ "reasoningTokens", "reasoning_tokens" }) else 0;
        const reasoning = if (flat_reasoning > 0) flat_reasoning else nested_reasoning;
        const reasoning_included = boolAny(usage, &.{ "reasoningIncludedInOutput", "reasoning_included_in_output" }) orelse (reasoning <= output);
        try self.reconcileCumulative(ea, .continue_cli, id, .{
            .agent = collectorAgent("continue_cli"),
            .timestamp_ms = timestampAny(value, &.{ "updatedAt", "updated_at", "createdAt", "created_at", "timestamp" }) orelse fallback_ms,
            .model = stringAny(value, &.{ "chatModelTitle", "model", "modelTitle" }) orelse "continue",
            .input_tokens = input -| (read +| write),
            .output_tokens = output +| (if (reasoning_included) 0 else reasoning),
            .cache_read_tokens = read,
            .cache_creation_tokens = write,
            .session_id = id,
            .cwd = stringAny(value, &.{ "workspaceDirectory", "workspace", "cwd" }) orelse "",
        }, out);
    }

    fn parseDroid(self: *Poller, ea: Allocator, path: []const u8, fallback_ms: i64, value: std.json.Value, out: *Changes) !bool {
        const metadata = objectAny(value, &.{"metadata"});
        const usage = objectAny(value, &.{ "tokenUsage", "token_usage", "usage" }) orelse blk: {
            const meta = metadata orelse return false;
            break :blk objectAny(meta, &.{ "tokenUsage", "token_usage", "usage" }) orelse return false;
        };
        const context = metadata orelse value;
        const id = stringAny(value, &.{ "sessionId", "session_id", "id" }) orelse stringAny(context, &.{ "sessionId", "session_id", "id" }) orelse droidSessionId(path);
        const event = types.UsageEvent{
            .agent = collectorAgent("droid"),
            .timestamp_ms = timestampAny(value, &.{ "updatedAt", "updated_at", "timestamp", "providerLockTimestamp", "created_at" }) orelse timestampAny(context, &.{ "updatedAt", "updated_at", "timestamp", "providerLockTimestamp", "created_at" }) orelse fallback_ms,
            .model = stringAny(value, &.{ "model", "modelId", "model_id" }) orelse stringAny(context, &.{ "model", "modelId", "model_id" }) orelse "droid",
            .input_tokens = u64Any(usage, &.{ "inputTokens", "input_tokens", "input" }),
            .output_tokens = u64Any(usage, &.{ "outputTokens", "output_tokens", "output" }) +| u64Any(usage, &.{ "thinkingTokens", "thinking_tokens", "reasoningTokens" }),
            .cache_read_tokens = u64Any(usage, &.{ "cacheReadTokens", "cache_read_tokens", "cacheRead" }),
            .cache_creation_tokens = u64Any(usage, &.{ "cacheWriteTokens", "cacheCreationTokens", "cache_write_tokens", "cache_creation_tokens", "cacheWrite" }),
            .session_id = id,
            .cwd = stringAny(value, &.{ "cwd", "workspace" }) orelse stringAny(context, &.{ "cwd", "workspace" }) orelse "",
        };
        if (event.totalTokens() == 0) return false;
        try putSession(self.allocator, &self.droid_snapshot_sessions, id);
        const file_session = droidSessionId(path);
        try putSession(self.allocator, &self.droid_snapshot_sessions, file_session);
        const native_key = try droidSnapshotNativeKey(self.allocator, path);
        defer self.allocator.free(native_key);
        try self.removeOtherSessionRecords(ea, .droid, native_key, id, out);
        if (!std.mem.eql(u8, file_session, id)) try self.removeOtherSessionRecords(ea, .droid, native_key, file_session, out);
        try self.reconcileCumulative(ea, .droid, native_key, event, out);
        return true;
    }

    fn parseDroidCall(self: *Poller, ea: Allocator, path: []const u8, line_no: usize, value: std.json.Value, out: *Changes) !void {
        const message = objectAny(value, &.{"message"}) orelse value;
        const usage = objectAny(message, &.{ "usage", "tokenUsage", "token_usage" }) orelse objectAny(value, &.{ "usage", "tokenUsage", "token_usage" }) orelse return;
        const timestamp_ms = timestampAny(value, &.{ "timestamp", "createdAt", "created_at", "ts" }) orelse timestampAny(message, &.{ "timestamp", "createdAt", "created_at", "ts" }) orelse return;
        const stable_id = stringAny(message, &.{ "responseId", "response_id", "id" }) orelse stringAny(value, &.{ "responseId", "response_id", "id" });
        const session_id = stringAny(message, &.{ "sessionId", "session_id" }) orelse stringAny(value, &.{ "sessionId", "session_id" }) orelse droidSessionId(path);
        if (self.droid_snapshot_sessions.contains(session_id) or self.droid_snapshot_sessions.contains(droidSessionId(path))) return;
        const key = if (stable_id) |id| try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ path, id }) else try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}", .{ path, timestamp_ms, line_no });
        defer self.allocator.free(key);
        try self.reconcile(ea, .droid, key, .{
            .agent = collectorAgent("droid"),
            .timestamp_ms = timestamp_ms,
            .model = stringAny(message, &.{ "model", "modelId", "model_id" }) orelse stringAny(value, &.{ "model", "modelId", "model_id" }) orelse "droid",
            .input_tokens = u64Any(usage, &.{ "inputTokens", "input_tokens", "input" }),
            .output_tokens = u64Any(usage, &.{ "outputTokens", "output_tokens", "output" }) +| u64Any(usage, &.{ "thinkingTokens", "thinking_tokens", "reasoningTokens" }),
            .cache_read_tokens = u64Any(usage, &.{ "cacheReadTokens", "cache_read_tokens", "cacheRead" }),
            .cache_creation_tokens = u64Any(usage, &.{ "cacheWriteTokens", "cacheCreationTokens", "cache_write_tokens", "cache_creation_tokens" }),
            .session_id = session_id,
        }, out);
    }

    const DbKind = enum { copilot, cline, kilo, goose };

    fn scanDatabase(self: *Poller, ea: Allocator, io: std.Io, source: Source, path: []const u8, queries: []const [:0]const u8, kind: DbKind, out: *Changes) !bool {
        if (!pathExists(io, path)) return false;
        self.markDetected(source);
        const zpath = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(zpath);
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(zpath.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return false;
        }
        defer _ = c.sqlite3_close(db);
        _ = c.sqlite3_busy_timeout(db, 50);

        var stmt: ?*c.sqlite3_stmt = null;
        for (queries) |sql| {
            if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) == c.SQLITE_OK) break;
            stmt = null;
        }
        if (stmt == null) return false;
        defer _ = c.sqlite3_finalize(stmt);
        var found_usable = false;
        var step_result = c.sqlite3_step(stmt);
        while (step_result == c.SQLITE_ROW) : (step_result = c.sqlite3_step(stmt)) {
            const id = columnText(stmt, 0) orelse continue;
            const session = columnText(stmt, 1) orelse id;
            const model = columnText(stmt, 2) orelse switch (kind) {
                .copilot => "copilot",
                .cline => "cline",
                .kilo => "kilo",
                .goose => "goose",
            };
            const timestamp_ms = columnTimestamp(stmt, 3) orelse fileMtimeMs(io, path) orelse 0;
            const raw_input = columnU64(stmt, 4);
            var output_tokens = columnU64(stmt, 5);
            const reasoning = columnU64(stmt, 6);
            const cache_read = columnU64(stmt, 7);
            const cache_write = columnU64(stmt, 8);
            const cwd = columnText(stmt, 9) orelse "";
            var input_tokens = raw_input;
            switch (kind) {
                .copilot, .goose => input_tokens -|= cache_read +| cache_write,
                .cline => input_tokens -|= cache_read +| cache_write,
                .kilo => output_tokens +|= reasoning,
            }
            if (input_tokens +| output_tokens +| cache_read +| cache_write == 0) continue;
            if (kind == .cline) {
                const fallback_id = try std.fmt.allocPrint(self.allocator, "cline:snapshot:{s}", .{id});
                defer self.allocator.free(fallback_id);
                const fallback_session = try std.fmt.allocPrint(self.allocator, "cline:snapshot:{s}", .{session});
                defer self.allocator.free(fallback_session);
                if (self.seen.contains(fallback_id) or self.seen.contains(fallback_session)) continue;
            }
            found_usable = true;
            if (kind == .copilot) {
                // Copilot's reasoning is a subset of output.
            }
            const agent = switch (kind) {
                .copilot => collectorAgent("copilot"),
                .cline => collectorAgent("cline"),
                .kilo => collectorAgent("kilo"),
                .goose => collectorAgent("goose"),
            };
            if (kind == .kilo or kind == .cline) {
                const native_key = if (kind == .cline) try std.fmt.allocPrint(self.allocator, "database:{s}", .{id}) else try self.allocator.dupe(u8, id);
                defer self.allocator.free(native_key);
                if (kind == .cline) {
                    try putSession(self.allocator, &self.cline_database_sessions, id);
                    try putSession(self.allocator, &self.cline_database_sessions, session);
                    try self.removeOtherSessionRecords(ea, source, native_key, session, out);
                }
                try self.reconcileCumulative(ea, source, native_key, .{
                    .agent = agent,
                    .timestamp_ms = timestamp_ms,
                    .model = model,
                    .input_tokens = input_tokens,
                    .output_tokens = output_tokens,
                    .cache_read_tokens = cache_read,
                    .cache_creation_tokens = cache_write,
                    .session_id = session,
                    .cwd = cwd,
                }, out);
                continue;
            }
            try self.reconcile(ea, source, id, .{
                .agent = agent,
                .timestamp_ms = timestamp_ms,
                .model = model,
                .input_tokens = input_tokens,
                .output_tokens = output_tokens,
                .cache_read_tokens = cache_read,
                .cache_creation_tokens = cache_write,
                .session_id = session,
                .cwd = cwd,
            }, out);
        }
        if (step_result != c.SQLITE_DONE) return error.DatabaseReadFailed;
        return found_usable;
    }
};

// Projections intentionally exclude conversation and credential payloads.
// Each fallback has the same ten-column normalized layout:
// id, session, model, timestamp, input, output, reasoning, cache read,
// cache write, working directory.
const copilot_queries = [_][:0]const u8{
    "SELECT id,session_id,model,created_at,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,'' FROM assistant_usage_events ORDER BY created_at,id",
    "SELECT id,session_id,model,created_at,input_tokens,output_tokens,reasoning_output_tokens,cache_read_input_tokens,cache_write_input_tokens,'' FROM assistant_usage_events ORDER BY created_at,id",
    "SELECT id,session_id,model,created_at,input_tokens,output_tokens,0,cached_input_tokens,0,'' FROM assistant_usage_events ORDER BY created_at,id",
};

const cline_queries = [_][:0]const u8{
    "SELECT session_id,session_id,coalesce(model,provider,'cline'),coalesce(updated_at,ended_at,started_at,0),coalesce(json_extract(metadata_json,'$.aggregateUsage.inputTokens'),json_extract(metadata_json,'$.usage.inputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.outputTokens'),json_extract(metadata_json,'$.usage.outputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.reasoningTokens'),json_extract(metadata_json,'$.usage.reasoningTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheReadTokens'),json_extract(metadata_json,'$.usage.cacheReadTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheWriteTokens'),json_extract(metadata_json,'$.usage.cacheWriteTokens'),0),coalesce(workspace_root,cwd,'') FROM sessions WHERE coalesce(is_subagent,0)=0 AND json_extract(metadata_json,'$.parentTaskId') IS NULL ORDER BY session_id",
    "SELECT id,id,coalesce(model,provider,'cline'),coalesce(updated_at,created_at,0),coalesce(json_extract(metadata_json,'$.aggregateUsage.inputTokens'),json_extract(metadata_json,'$.usage.inputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.outputTokens'),json_extract(metadata_json,'$.usage.outputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.reasoningTokens'),json_extract(metadata_json,'$.usage.reasoningTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheReadTokens'),json_extract(metadata_json,'$.usage.cacheReadTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheWriteTokens'),json_extract(metadata_json,'$.usage.cacheWriteTokens'),0),coalesce(workspace,cwd,'') FROM sessions WHERE coalesce(json_extract(metadata_json,'$.isSubagent'),0)=0 AND json_extract(metadata_json,'$.parentTaskId') IS NULL ORDER BY id",
    "SELECT id,id,coalesce(json_extract(metadata_json,'$.model'),json_extract(metadata_json,'$.modelId'),json_extract(metadata_json,'$.provider'),'cline'),coalesce(json_extract(metadata_json,'$.updatedAt'),json_extract(metadata_json,'$.createdAt'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.inputTokens'),json_extract(metadata_json,'$.usage.inputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.outputTokens'),json_extract(metadata_json,'$.usage.outputTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.reasoningTokens'),json_extract(metadata_json,'$.usage.reasoningTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheReadTokens'),json_extract(metadata_json,'$.usage.cacheReadTokens'),0),coalesce(json_extract(metadata_json,'$.aggregateUsage.cacheWriteTokens'),json_extract(metadata_json,'$.usage.cacheWriteTokens'),0),coalesce(json_extract(metadata_json,'$.workspace'),json_extract(metadata_json,'$.workspaceDirectory'),json_extract(metadata_json,'$.cwd'),'') FROM sessions WHERE coalesce(json_extract(metadata_json,'$.isSubagent'),0)=0 AND json_extract(metadata_json,'$.parentTaskId') IS NULL ORDER BY id",
    "SELECT id,id,coalesce(json_extract(metadata,'$.model'),json_extract(metadata,'$.modelId'),json_extract(metadata,'$.provider'),'cline'),coalesce(json_extract(metadata,'$.updatedAt'),json_extract(metadata,'$.createdAt'),0),coalesce(json_extract(metadata,'$.aggregateUsage.inputTokens'),json_extract(metadata,'$.usage.inputTokens'),0),coalesce(json_extract(metadata,'$.aggregateUsage.outputTokens'),json_extract(metadata,'$.usage.outputTokens'),0),coalesce(json_extract(metadata,'$.aggregateUsage.reasoningTokens'),json_extract(metadata,'$.usage.reasoningTokens'),0),coalesce(json_extract(metadata,'$.aggregateUsage.cacheReadTokens'),json_extract(metadata,'$.usage.cacheReadTokens'),0),coalesce(json_extract(metadata,'$.aggregateUsage.cacheWriteTokens'),json_extract(metadata,'$.usage.cacheWriteTokens'),0),coalesce(json_extract(metadata,'$.workspace'),json_extract(metadata,'$.workspaceDirectory'),json_extract(metadata,'$.cwd'),'') FROM sessions WHERE coalesce(json_extract(metadata,'$.isSubagent'),0)=0 AND json_extract(metadata,'$.parentTaskId') IS NULL ORDER BY id",
};

const kilo_queries = [_][:0]const u8{
    "SELECT id,id,coalesce(json_extract(model,'$.id'),'kilo'),time_updated,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write,coalesce(directory,'') FROM session ORDER BY id",
    "SELECT id,id,coalesce(model,'kilo'),updated_at,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,coalesce(directory,'') FROM session ORDER BY id",
    "SELECT id,id,coalesce(model,'kilo'),updated_at,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,coalesce(cwd,'') FROM sessions ORDER BY id",
    "SELECT session_id,session_id,coalesce(model,'kilo'),updated_at,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,coalesce(directory,'') FROM session_usage ORDER BY session_id",
};

const goose_queries = [_][:0]const u8{
    "SELECT id,session_id,coalesce(model,'goose'),created_timestamp,input_tokens,output_tokens,0,cache_read_tokens,cache_write_tokens,'' FROM usage_ledger ORDER BY id",
    "SELECT id,session_id,coalesce(model,'goose'),created_at,input_tokens,output_tokens,0,cache_read,cache_write,'' FROM usage_ledger ORDER BY created_at,id",
};

fn matchesFile(kind: Poller.FileKind, path: []const u8, basename: []const u8) bool {
    const separators = std.mem.count(u8, path, std.fs.path.sep_str);
    return switch (kind) {
        .gemini => (std.mem.endsWith(u8, basename, ".jsonl") or std.mem.endsWith(u8, basename, ".json")) and
            (std.mem.indexOf(u8, path, std.fs.path.sep_str ++ "chats" ++ std.fs.path.sep_str) != null or std.mem.startsWith(u8, path, "chats" ++ std.fs.path.sep_str)),
        .qwen => separators == 0 and std.mem.startsWith(u8, basename, "token-usage-") and std.mem.endsWith(u8, basename, ".jsonl"),
        .pi => std.mem.endsWith(u8, basename, ".jsonl"),
        .kimi => separators == 2 and std.mem.eql(u8, basename, "wire.jsonl"),
        .grok => separators == 2 and std.mem.eql(u8, basename, "updates.jsonl"),
        .cline_legacy, .roo => std.mem.eql(u8, basename, "history_item.json"),
        .cline_ui => std.mem.eql(u8, basename, "ui_messages.json"),
        .cline_messages => std.mem.eql(u8, basename, "api_conversation_history.json"),
        .continue_cli => separators == 0 and std.mem.endsWith(u8, basename, ".json"),
        .droid => separators == 1 and std.mem.endsWith(u8, basename, ".settings.json"),
        .droid_metadata => separators == 1 and std.mem.endsWith(u8, basename, ".metadata.json"),
        .droid_jsonl => separators == 1 and std.mem.endsWith(u8, basename, ".jsonl"),
    };
}

fn isLineFile(kind: Poller.FileKind) bool {
    return switch (kind) {
        .gemini, .qwen, .pi, .kimi, .grok, .droid_jsonl => true,
        else => false,
    };
}

fn clearSessionSet(allocator: Allocator, sessions: *std.StringHashMapUnmanaged(void)) void {
    var keys = sessions.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    sessions.clearRetainingCapacity();
}

fn putSession(allocator: Allocator, sessions: *std.StringHashMapUnmanaged(void), session: []const u8) !void {
    if (session.len == 0 or sessions.contains(session)) return;
    const owned = try allocator.dupe(u8, session);
    errdefer allocator.free(owned);
    try sessions.put(allocator, owned, {});
}

/// Resolve the primary directory or database for one source. The caller owns
/// the returned path. Roo may additionally scan other standard editor roots.
pub fn resolvePrimaryPath(allocator: Allocator, source: Source, env: Env) ![]u8 {
    return switch (source) {
        .gemini => std.fs.path.join(allocator, &.{ nonempty(env.gemini_cli_home) orelse env.home, ".gemini", "tmp" }),
        .qwen => blk: {
            const base = if (nonempty(env.qwen_runtime_dir) orelse nonempty(env.qwen_home)) |path| try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ env.home, ".qwen" });
            defer allocator.free(base);
            break :blk std.fs.path.join(allocator, &.{ base, "usage" });
        },
        .pi => if (nonempty(env.pi_session_dir)) |path|
            allocator.dupe(u8, path)
        else if (nonempty(env.pi_agent_dir)) |path|
            std.fs.path.join(allocator, &.{ path, "sessions" })
        else
            std.fs.path.join(allocator, &.{ env.home, ".pi", "agent", "sessions" }),
        .kimi => resolveFromBase(allocator, nonempty(env.kimi_share_dir), env.home, ".kimi", "sessions"),
        .grok => resolveFromBase(allocator, nonempty(env.grok_home), env.home, ".grok", "sessions"),
        .copilot => resolveFromBase(allocator, nonempty(env.copilot_home), env.home, ".copilot", "session-store.db"),
        .cline => blk: {
            const data = try resolveClineData(allocator, env);
            defer allocator.free(data);
            break :blk std.fs.path.join(allocator, &.{ data, "db", "sessions.db" });
        },
        .roo => std.fs.path.join(allocator, &.{ env.home, "Library", "Application Support", "Code", "User", "globalStorage", "rooveterinaryinc.roo-cline", "tasks" }),
        .continue_cli => resolveFromBase(allocator, nonempty(env.continue_global_dir), env.home, ".continue", "sessions"),
        .kilo => if (nonempty(env.kilo_db)) |path| blk: {
            if (std.fs.path.isAbsolute(path) or std.mem.eql(u8, path, ":memory:")) break :blk allocator.dupe(u8, path);
            const data = if (nonempty(env.xdg_data_home)) |root| try allocator.dupe(u8, root) else try std.fs.path.join(allocator, &.{ env.home, ".local", "share" });
            defer allocator.free(data);
            break :blk std.fs.path.join(allocator, &.{ data, "kilo", path });
        } else blk: {
            const data = if (nonempty(env.xdg_data_home)) |path| try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ env.home, ".local", "share" });
            defer allocator.free(data);
            break :blk std.fs.path.join(allocator, &.{ data, "kilo", "kilo.db" });
        },
        .goose => blk: {
            if (nonempty(env.goose_path_root)) |path| break :blk std.fs.path.join(allocator, &.{ path, "data", "sessions", "sessions.db" });
            break :blk std.fs.path.join(allocator, &.{ env.home, "Library", "Application Support", "Block", "goose", "sessions", "sessions.db" });
        },
        .droid => resolveFromBase(allocator, nonempty(env.factory_home), env.home, ".factory", "sessions"),
    };
}

fn resolveFromBase(allocator: Allocator, explicit: ?[]const u8, home: []const u8, default_name: []const u8, tail: []const u8) ![]u8 {
    const base = if (explicit) |path| try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ home, default_name });
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, tail });
}

fn resolveClineData(allocator: Allocator, env: Env) ![]u8 {
    if (nonempty(env.cline_data_dir)) |path| return allocator.dupe(u8, path);
    if (nonempty(env.cline_dir)) |path| return std.fs.path.join(allocator, &.{ path, "data" });
    return std.fs.path.join(allocator, &.{ env.home, ".cline", "data" });
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn replaceOwned(allocator: Allocator, owned: *?[]u8, current: *[]const u8, value: []const u8) !void {
    const duplicate = try allocator.dupe(u8, value);
    if (owned.*) |old| allocator.free(old);
    owned.* = duplicate;
    current.* = duplicate;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn fileMtimeMs(io: std.Io, path: []const u8) ?i64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const ms = @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, ms);
}

fn droidSessionId(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    inline for (.{ ".settings.json", ".metadata.json", ".jsonl" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    }
    return name;
}

fn droidSnapshotNativeKey(allocator: Allocator, path: []const u8) ![]u8 {
    const kind = if (std.mem.endsWith(u8, path, ".settings.json")) "settings" else "metadata";
    return std.fmt.allocPrint(allocator, "snapshot-{s}:{s}", .{ kind, droidSessionId(path) });
}

fn droidSnapshotSession(key: []const u8) []const u8 {
    const marker = if (std.mem.startsWith(u8, key, "droid:snapshot-settings:"))
        "droid:snapshot-settings:"
    else
        "droid:snapshot-metadata:";
    return key[marker.len..];
}

fn objectAny(value: std.json.Value, names: []const []const u8) ?std.json.Value {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (child == .object) return child;
    }
    return null;
}

fn arrayAny(value: std.json.Value, names: []const []const u8) ?std.json.Value {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (child == .array) return child;
    }
    return null;
}

fn stringAny(value: std.json.Value, names: []const []const u8) ?[]const u8 {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (child == .string and child.string.len != 0) return child.string;
    }
    return null;
}

fn stringEquals(value: std.json.Value, name: []const u8, expected: []const u8) bool {
    return if (stringAny(value, &.{name})) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn u64Any(value: std.json.Value, names: []const []const u8) u64 {
    if (value != .object) return 0;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (numberU64(child)) |number| return number;
    }
    return 0;
}

fn numberU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number < 0) null else @intCast(number),
        .float => |number| if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) null else @intFromFloat(number),
        else => null,
    };
}

fn boolAny(value: std.json.Value, names: []const []const u8) ?bool {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (child == .bool) return child.bool;
    }
    return null;
}

fn timestampAny(value: std.json.Value, names: []const []const u8) ?i64 {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (timestampValue(child, .heuristic)) |timestamp| return timestamp;
    }
    return null;
}

fn timestampSecondsAny(value: std.json.Value, names: []const []const u8) ?i64 {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (timestampValue(child, .seconds)) |timestamp| return timestamp;
    }
    return null;
}

fn timestampMillisecondsAny(value: std.json.Value, names: []const []const u8) ?i64 {
    if (value != .object) return null;
    for (names) |name| {
        const child = value.object.get(name) orelse continue;
        if (timestampValue(child, .milliseconds)) |timestamp| return timestamp;
    }
    return null;
}

const NumericTimestamp = enum { heuristic, seconds, milliseconds };

fn timestampValue(value: std.json.Value, numeric: NumericTimestamp) ?i64 {
    if (value == .string) return parseIso8601Ms(value.string);
    const raw: f64 = switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => return null,
    };
    if (!std.math.isFinite(raw) or raw < 0) return null;
    const millis = switch (numeric) {
        .seconds => raw * 1000,
        .milliseconds => raw,
        .heuristic => if (raw < 100_000_000_000) raw * 1000 else raw,
    };
    if (millis > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    return @intFromFloat(millis);
}

fn parseIso8601Ms(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const year = fixedDigits(s[0..4]) orelse return null;
    const month = fixedDigits(s[5..7]) orelse return null;
    const day = fixedDigits(s[8..10]) orelse return null;
    const hour = fixedDigits(s[11..13]) orelse return null;
    const minute = fixedDigits(s[14..16]) orelse return null;
    const second = fixedDigits(s[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return null;
    var at: usize = 19;
    var fraction_ms: i64 = 0;
    if (at < s.len and s[at] == '.') {
        at += 1;
        const start = at;
        var scale: i64 = 100;
        while (at < s.len and std.ascii.isDigit(s[at])) : (at += 1) {
            if (at < start + 3) {
                fraction_ms += scale * (s[at] - '0');
                scale = @divTrunc(scale, 10);
            }
        }
        if (at == start) return null;
    }
    var offset_minutes: i64 = 0;
    if (at < s.len) switch (s[at]) {
        'Z', 'z' => {
            at += 1;
        },
        '+', '-' => {
            const sign: i64 = if (s[at] == '-') -1 else 1;
            at += 1;
            if (s.len < at + 2) return null;
            const offset_hour = fixedDigits(s[at .. at + 2]) orelse return null;
            at += 2;
            if (at < s.len and s[at] == ':') at += 1;
            if (s.len != at + 2) return null;
            const offset_minute = fixedDigits(s[at .. at + 2]) orelse return null;
            at += 2;
            if (offset_hour > 23 or offset_minute > 59) return null;
            offset_minutes = sign * (offset_hour * 60 + offset_minute);
        },
        else => return null,
    };
    if (at != s.len) return null;
    const days = daysFromCivil(year, month, day);
    return (days * 86400 + hour * 3600 + minute * 60 + second - offset_minutes * 60) * 1000 + fraction_ms;
}

fn fixedDigits(s: []const u8) ?i64 {
    var result: i64 = 0;
    for (s) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        result = result * 10 + byte - '0';
    }
    return result;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn columnText(stmt: ?*c.sqlite3_stmt, column: c_int) ?[]const u8 {
    const pointer = c.sqlite3_column_text(stmt, column) orelse return null;
    const length = c.sqlite3_column_bytes(stmt, column);
    return pointer[0..@intCast(length)];
}

fn columnU64(stmt: ?*c.sqlite3_stmt, column: c_int) u64 {
    return switch (c.sqlite3_column_type(stmt, column)) {
        c.SQLITE_INTEGER => blk: {
            const value = c.sqlite3_column_int64(stmt, column);
            break :blk if (value < 0) 0 else @intCast(value);
        },
        c.SQLITE_FLOAT => blk: {
            const value = c.sqlite3_column_double(stmt, column);
            break :blk if (!std.math.isFinite(value) or value < 0) 0 else @intFromFloat(value);
        },
        else => 0,
    };
}

fn columnTimestamp(stmt: ?*c.sqlite3_stmt, column: c_int) ?i64 {
    return switch (c.sqlite3_column_type(stmt, column)) {
        c.SQLITE_INTEGER => blk: {
            const value = c.sqlite3_column_int64(stmt, column);
            break :blk if (value < 0) null else if (value < 100_000_000_000) value * 1000 else value;
        },
        c.SQLITE_FLOAT => timestampValue(.{ .float = c.sqlite3_column_double(stmt, column) }, .heuristic),
        c.SQLITE_TEXT => if (columnText(stmt, column)) |text| parseIso8601Ms(text) else null,
        else => null,
    };
}

fn dupeEvent(allocator: Allocator, event: types.UsageEvent) !types.UsageEvent {
    const model = try allocator.dupe(u8, event.model);
    errdefer allocator.free(model);
    const session = try allocator.dupe(u8, event.session_id);
    errdefer allocator.free(session);
    const cwd = try allocator.dupe(u8, event.cwd);
    return .{
        .agent = event.agent,
        .timestamp_ms = event.timestamp_ms,
        .model = model,
        .input_tokens = event.input_tokens,
        .output_tokens = event.output_tokens,
        .cache_creation_tokens = event.cache_creation_tokens,
        .cache_read_tokens = event.cache_read_tokens,
        .session_id = session,
        .cwd = cwd,
    };
}

fn freeEvent(allocator: Allocator, event: types.UsageEvent) void {
    allocator.free(event.model);
    allocator.free(event.session_id);
    allocator.free(event.cwd);
}

fn eventEqual(a: types.UsageEvent, b: types.UsageEvent) bool {
    return a.agent == b.agent and a.timestamp_ms == b.timestamp_ms and
        a.input_tokens == b.input_tokens and a.output_tokens == b.output_tokens and
        a.cache_creation_tokens == b.cache_creation_tokens and a.cache_read_tokens == b.cache_read_tokens and
        std.mem.eql(u8, a.model, b.model) and std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.cwd, b.cwd);
}

fn cumulativeDelta(previous: u64, current: u64) u64 {
    return if (current >= previous) current - previous else current;
}

pub fn freeChanges(allocator: Allocator, changes: []const Change) void {
    for (changes) |change| {
        if (change.previous) |event| freeEvent(allocator, event);
        freeEvent(allocator, change.current);
    }
}

const testing = std.testing;

test "reconciliation suppresses unchanged records and emits replacements" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    const first = types.UsageEvent{
        .agent = collectorAgent("gemini"),
        .timestamp_ms = 1000,
        .model = "gemini-test",
        .input_tokens = 10,
        .output_tokens = 20,
        .session_id = "session",
        .cwd = "/work",
    };
    try poller.reconcile(testing.allocator, .gemini, "native-id", first, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    try poller.reconcile(testing.allocator, .gemini, "native-id", first, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);
    var replacement = first;
    replacement.output_tokens = 25;
    try poller.reconcile(testing.allocator, .gemini, "native-id", replacement, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 20), changes.items[0].previous.?.output_tokens);
    try testing.expectEqual(@as(u64, 25), changes.items[0].current.output_tokens);
    freeChanges(testing.allocator, changes.items);
}

test "cumulative reconciliation emits only growth without relocating history" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    const first = types.UsageEvent{ .agent = .continue_cli, .timestamp_ms = 1_000, .model = "m", .input_tokens = 10, .output_tokens = 20 };
    try poller.reconcileCumulative(testing.allocator, .continue_cli, "session", first, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    var grown = first;
    grown.timestamp_ms = 2_000;
    grown.input_tokens = 13;
    grown.output_tokens = 25;
    try poller.reconcileCumulative(testing.allocator, .continue_cli, "session", grown, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expect(changes.items[0].previous == null);
    try testing.expectEqual(@as(u64, 3), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 5), changes.items[0].current.output_tokens);
    try testing.expectEqual(@as(i64, 2_000), changes.items[0].current.timestamp_ms);
    freeChanges(testing.allocator, changes.items);
}

test "cumulative reconciliation resets each counter independently" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);

    const first = types.UsageEvent{ .agent = .continue_cli, .timestamp_ms = 1_000, .model = "m", .input_tokens = 30, .output_tokens = 20 };
    try poller.reconcileCumulative(testing.allocator, .continue_cli, "session", first, &changes);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    const reset = types.UsageEvent{ .agent = .continue_cli, .timestamp_ms = 2_000, .model = "m", .input_tokens = 35, .output_tokens = 2 };
    try poller.reconcileCumulative(testing.allocator, .continue_cli, "session", reset, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expect(changes.items[0].previous == null);
    try testing.expectEqual(@as(u64, 5), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 2), changes.items[0].current.output_tokens);
    freeChanges(testing.allocator, changes.items);
}

test "authoritative cumulative records retract per-call fallback records" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);

    const call = types.UsageEvent{ .agent = .cline, .timestamp_ms = 1_000, .model = "m", .input_tokens = 10, .output_tokens = 5, .session_id = "session" };
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    try ledger.add(call, null);
    try poller.reconcile(testing.allocator, .cline, "/tasks/session/ui_messages.json:1000", call, &changes);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    try poller.removeOtherSessionRecords(testing.allocator, .cline, "session", "session", &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 10), changes.items[0].previous.?.input_tokens);
    try testing.expectEqual(@as(u64, 0), changes.items[0].current.totalTokens());
    try testing.expect(poller.seen.get("cline:/tasks/session/ui_messages.json:1000") == null);
    ledger.remove(changes.items[0].previous.?, null);
    try testing.expectEqual(@as(u64, 0), ledger.all.events);
    try ledger.add(.{ .agent = .cline, .timestamp_ms = 2_000, .model = "m", .input_tokens = 10, .output_tokens = 5, .session_id = "session" }, null);
    try testing.expectEqual(@as(u64, 1), ledger.all.events);
    freeChanges(testing.allocator, changes.items);
}

test "Cline database precedence applies only to matching sessions" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    try putSession(testing.allocator, &poller.cline_database_sessions, "database-session");

    var matched = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":\"database-session\",\"tokensIn\":10,\"tokensOut\":2}", .{});
    defer matched.deinit();
    try poller.parseTaskSnapshot(testing.allocator, .cline, "/matched/history_item.json", 1, matched.value, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);

    var unmatched = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"id\":\"editor-only\",\"tokensIn\":10,\"tokensOut\":2}", .{});
    defer unmatched.deinit();
    try poller.parseTaskSnapshot(testing.allocator, .cline, "/unmatched/history_item.json", 1, unmatched.value, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
}

test "Droid ignores unusable snapshots without suppressing JSONL" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    var empty = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sessionId\":\"session\",\"usage\":{\"inputTokens\":0}}", .{});
    defer empty.deinit();
    try testing.expect(!try poller.parseDroid(testing.allocator, "/factory/a/session.settings.json", 1, empty.value, &changes));
    try testing.expect(!poller.droid_snapshot_sessions.contains("session"));
    try testing.expectEqual(@as(usize, 0), changes.items.len);

    var usable = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sessionId\":\"session\",\"usage\":{\"inputTokens\":10}}", .{});
    defer usable.deinit();
    try testing.expect(try poller.parseDroid(testing.allocator, "/factory/a/session.settings.json", 1, usable.value, &changes));
    clearSessionSet(testing.allocator, &poller.droid_snapshot_sessions);
    try poller.collectDroid(testing.allocator, testing.io, .{ .home = "/missing", .factory_home = "/missing" }, &changes);
    try testing.expect(poller.droid_snapshot_sessions.contains("session"));
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    clearSessionSet(testing.allocator, &poller.droid_snapshot_sessions);
    var updated = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sessionId\":\"session\",\"usage\":{\"inputTokens\":12}}", .{});
    defer updated.deinit();
    try testing.expect(try poller.parseDroid(testing.allocator, "/factory/a/session.settings.json", 2, updated.value, &changes));
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 2), changes.items[0].current.input_tokens);
    freeChanges(testing.allocator, changes.items);
}

test "Cline retains established database authority when the database disappears" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    const event = types.UsageEvent{ .agent = .cline, .timestamp_ms = 1, .model = "m", .input_tokens = 10, .session_id = "session" };
    try poller.reconcileCumulative(testing.allocator, .cline, "database:session", event, &changes);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    try poller.collectCline(testing.allocator, testing.io, .{ .home = "/missing", .cline_data_dir = "/missing" }, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);
    try testing.expect(poller.cline_database_sessions.contains("session"));
    try testing.expect(poller.seen.get("cline:database:session") != null);
}

test "Gemini and Qwen fixtures normalize inclusive input and thoughts" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }

    const gemini_line = std.mem.sliceTo(@embedFile("fixtures/harness/gemini.jsonl"), '\n');
    var gemini = try std.json.parseFromSlice(std.json.Value, testing.allocator, gemini_line, .{});
    defer gemini.deinit();
    try poller.parseGemini(testing.allocator, "/project/chats/session/file.jsonl", gemini.value, &changes);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 100), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 35), changes.items[0].current.output_tokens);
    try testing.expectEqual(@as(u64, 20), changes.items[0].current.cache_read_tokens);

    const qwen_line = std.mem.sliceTo(@embedFile("fixtures/harness/qwen.jsonl"), '\n');
    var qwen = try std.json.parseFromSlice(std.json.Value, testing.allocator, qwen_line, .{});
    defer qwen.deinit();
    try poller.parseQwen(testing.allocator, qwen.value, &changes);
    try testing.expectEqual(@as(usize, 2), changes.items.len);
    try testing.expectEqual(@as(u64, 80), changes.items[1].current.input_tokens);
    try testing.expectEqual(@as(u64, 23), changes.items[1].current.output_tokens);
}

test "Pi fixture inherits session header and keeps reasoning inside output" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    try poller.scanPi(testing.allocator, @embedFile("fixtures/harness/pi.jsonl"), "/pi/session.jsonl", &changes);
    try testing.expectEqual(@as(usize, 3), changes.items.len);
    const event = changes.items[0].current;
    try testing.expectEqualStrings("session-pi", event.session_id);
    try testing.expectEqualStrings("/work/pi", event.cwd);
    try testing.expectEqual(@as(u64, 11), event.input_tokens);
    try testing.expectEqual(@as(u64, 12), event.output_tokens);
    try testing.expectEqual(@as(u64, 13), event.cache_read_tokens);
    try testing.expectEqual(@as(u64, 14), event.cache_creation_tokens);
    try testing.expectEqual(@as(u64, 3), changes.items[1].current.output_tokens);
    try testing.expectEqual(@as(u64, 7), changes.items[2].current.output_tokens);
}

test "Kimi recursive status and Grok per-model fixtures parse" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    var kimi_lines = std.mem.splitScalar(u8, @embedFile("fixtures/harness/kimi.jsonl"), '\n');
    while (kimi_lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try poller.parseKimi(testing.allocator, "/kimi/a/b/wire.jsonl", parsed.value, null, 0, &changes);
    }
    try testing.expectEqual(@as(usize, 2), changes.items.len);
    try testing.expectEqual(@as(u64, 15), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(i64, 1_784_541_780_000), changes.items[0].current.timestamp_ms);

    const grok_line = std.mem.sliceTo(@embedFile("fixtures/harness/grok.jsonl"), '\n');
    var grok = try std.json.parseFromSlice(std.json.Value, testing.allocator, grok_line, .{});
    defer grok.deinit();
    try poller.parseGrok(testing.allocator, "/grok/a/b/updates.jsonl", grok.value, &changes);
    try testing.expectEqual(@as(usize, 4), changes.items.len);
    try testing.expectEqual(@as(u64, 75), changes.items[2].current.input_tokens);
    try testing.expectEqual(@as(u64, 40), changes.items[2].current.output_tokens);
}

test "mutable JSON snapshot fixtures map source-specific semantics" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, @embedFile("fixtures/harness/snapshots.json"), .{});
    defer parsed.deinit();
    try poller.parseTaskSnapshot(testing.allocator, .roo, "/roo/history_item.json", 1, parsed.value.object.get("roo").?, &changes);
    try poller.parseContinue(testing.allocator, "/continue/session.json", 1, parsed.value.object.get("continue").?, &changes);
    try testing.expect(try poller.parseDroid(testing.allocator, "/factory/a/session.settings.json", 1, parsed.value.object.get("droid").?, &changes));
    try testing.expectEqual(@as(usize, 3), changes.items.len);
    try testing.expectEqual(@as(u64, 55), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 70), changes.items[1].current.input_tokens);
    try testing.expectEqual(@as(u64, 27), changes.items[1].current.output_tokens);
    try testing.expectEqual(@as(u64, 15), changes.items[2].current.output_tokens);
}

test "malformed and irrelevant JSON is ignored" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, @embedFile("fixtures/harness/malformed.json"), .{});
    defer parsed.deinit();
    try poller.parseGemini(testing.allocator, "/bad", parsed.value, &changes);
    try poller.parseQwen(testing.allocator, parsed.value, &changes);
    try poller.parseContinue(testing.allocator, "/bad", 1, parsed.value, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);
    try testing.expectEqual(@as(?i64, null), parseIso8601Ms("not a timestamp"));
}

test "root overrides and XDG paths follow documented precedence" {
    const env = Env{
        .home = "/home/test",
        .xdg_data_home = "/xdg",
        .qwen_home = "/qwen-home",
        .qwen_runtime_dir = "/qwen-runtime",
        .pi_agent_dir = "/pi-agent",
        .pi_session_dir = "/pi-sessions",
        .cline_dir = "/cline-base",
        .cline_data_dir = "/cline-data",
        .kilo_db = "/override/kilo.db",
        .goose_path_root = "/goose-root",
    };
    const qwen = try resolvePrimaryPath(testing.allocator, .qwen, env);
    defer testing.allocator.free(qwen);
    try testing.expectEqualStrings("/qwen-runtime/usage", qwen);
    const pi = try resolvePrimaryPath(testing.allocator, .pi, env);
    defer testing.allocator.free(pi);
    try testing.expectEqualStrings("/pi-sessions", pi);
    const cline = try resolvePrimaryPath(testing.allocator, .cline, env);
    defer testing.allocator.free(cline);
    try testing.expectEqualStrings("/cline-data/db/sessions.db", cline);
    const kilo = try resolvePrimaryPath(testing.allocator, .kilo, env);
    defer testing.allocator.free(kilo);
    try testing.expectEqualStrings("/override/kilo.db", kilo);
    const goose = try resolvePrimaryPath(testing.allocator, .goose, env);
    defer testing.allocator.free(goose);
    try testing.expectEqualStrings("/goose-root/data/sessions/sessions.db", goose);

    const fallback = try resolvePrimaryPath(testing.allocator, .kilo, .{ .home = "/home/test", .xdg_data_home = "/xdg" });
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("/xdg/kilo/kilo.db", fallback);

    inline for (std.meta.tags(Source)) |source| {
        const resolved = try resolvePrimaryPath(testing.allocator, source, .{ .home = "/home/test" });
        testing.allocator.free(resolved);
    }
}

test "poll rejects an unexpanded Agent enum instead of misattributing events" {
    if (agent_enum_ready) return;
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    try testing.expectError(error.AgentEnumNotIntegrated, poller.poll(testing.allocator, testing.io, .{ .home = "/path/that/does/not/exist" }, &changes));
}

test "all collector filesystem entry points tolerate absent sources" {
    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer changes.deinit(testing.allocator);
    const missing = "/path/that/does/not/exist";
    const env = Env{
        .home = missing,
        .gemini_cli_home = missing,
        .qwen_runtime_dir = missing,
        .pi_session_dir = missing,
        .kimi_share_dir = missing,
        .grok_home = missing,
        .copilot_home = missing,
        .cline_data_dir = missing,
        .continue_global_dir = missing,
        .kilo_db = missing,
        .goose_path_root = missing,
        .factory_home = missing,
    };
    try poller.collectGemini(testing.allocator, testing.io, env, &changes);
    try poller.collectQwen(testing.allocator, testing.io, env, &changes);
    try poller.collectPi(testing.allocator, testing.io, env, &changes);
    try poller.collectKimi(testing.allocator, testing.io, env, &changes);
    try poller.collectGrok(testing.allocator, testing.io, env, &changes);
    try poller.collectCopilot(testing.allocator, testing.io, env, &changes);
    try poller.collectCline(testing.allocator, testing.io, env, &changes);
    try poller.collectRoo(testing.allocator, testing.io, env, &changes);
    try poller.collectContinue(testing.allocator, testing.io, env, &changes);
    try poller.collectKilo(testing.allocator, testing.io, env, &changes);
    try poller.collectGoose(testing.allocator, testing.io, env, &changes);
    try poller.collectDroid(testing.allocator, testing.io, env, &changes);
    try testing.expectEqual(@as(usize, 0), changes.items.len);
}

test "SQLite projections are explicit and privacy-safe" {
    inline for (.{ copilot_queries, cline_queries, kilo_queries, goose_queries }) |queries| {
        inline for (queries) |sql| {
            const lower = try std.ascii.allocLowerString(testing.allocator, sql);
            defer testing.allocator.free(lower);
            try testing.expect(std.mem.indexOf(u8, lower, "select *") == null);
            inline for (.{ "prompt", "content", "tool", "auth" }) |forbidden| {
                try testing.expect(std.mem.indexOf(u8, lower, forbidden) == null);
            }
        }
    }
}

test "SQLite collectors map fixtures read-only and deduplicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ base, "session-store.db" });
    defer testing.allocator.free(path);
    const zpath = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(zpath);
    var db: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, @embedFile("fixtures/harness/sqlite.sql").ptr, null, null, null));
    _ = c.sqlite3_close(db);

    var poller = Poller.init(testing.allocator);
    defer poller.deinit();
    var changes: Changes = .empty;
    defer {
        freeChanges(testing.allocator, changes.items);
        changes.deinit(testing.allocator);
    }
    try testing.expect(try poller.scanDatabase(testing.allocator, testing.io, .copilot, path, &copilot_queries, .copilot, &changes));
    try testing.expect(poller.sourceStatus(.copilot).detected);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 60), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 20), changes.items[0].current.output_tokens);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();
    try testing.expect(try poller.scanDatabase(testing.allocator, testing.io, .copilot, path, &copilot_queries, .copilot, &changes));
    try testing.expectEqual(@as(usize, 0), changes.items.len);

    try testing.expect(try poller.scanDatabase(testing.allocator, testing.io, .cline, path, &cline_queries, .cline, &changes));
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 37), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 20), changes.items[0].current.output_tokens);
    try testing.expectEqualStrings("/work/cline", changes.items[0].current.cwd);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    try testing.expect(try poller.scanDatabase(testing.allocator, testing.io, .kilo, path, &kilo_queries, .kilo, &changes));
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 7), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 17), changes.items[0].current.output_tokens);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    try testing.expect(try poller.scanDatabase(testing.allocator, testing.io, .goose, path, &goose_queries, .goose, &changes));
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(@as(u64, 23), changes.items[0].current.input_tokens);
    try testing.expectEqual(@as(u64, 11), changes.items[0].current.output_tokens);
    freeChanges(testing.allocator, changes.items);
    changes.clearRetainingCapacity();

    db = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &db, c.SQLITE_OPEN_READWRITE, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "DELETE FROM sessions", null, null, null));
    _ = c.sqlite3_close(db);
    try testing.expect(!try poller.scanDatabase(testing.allocator, testing.io, .cline, path, &cline_queries, .cline, &changes));
}

test "coverage registry includes every collector and exposes integration status" {
    try testing.expectEqual(@as(usize, 12), coverage_registry.len);
    try testing.expectEqualStrings("gemini", coverage_registry[0].id);
    try testing.expectEqualStrings("droid", coverage_registry[11].id);
    if (!agent_enum_ready) try testing.expect(coverage_registry[0].agent == null);
}
