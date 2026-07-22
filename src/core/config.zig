//! Ghostty-style plain-text config for token-tach.
//!
//! The file lives at `~/.config/token-tach/config` and is a flat list of
//! `key = value` lines:
//!
//!   - `#` starts a comment. Full-line comments and trailing comments are
//!     supported; a trailing `#` only starts a comment when it is preceded
//!     by whitespace (so values like `tach-dark#red` survive verbatim).
//!   - Blank lines are ignored. Whitespace around keys, `=`, and values is
//!     trimmed. CRLF line endings are tolerated.
//!   - Repeated *list* keys (`alert-threshold`, `source`,
//!     `claude-config-dir`) APPEND, ghostty-style. The first valid
//!     occurrence replaces the built-in default; an explicitly empty value
//!     (`alert-threshold =`) clears the list.
//!   - Repeated *scalar* keys: last valid value wins.
//!   - Bad values never error out — they produce a `Warning` (with line
//!     number) and the previous/default value is retained. A config file
//!     must never crash the app.
//!
//! Ownership: `parse` and `load` allocate every returned slice (config
//! strings, lists, warning messages) with the passed allocator and provide
//! no deinit. Pass an arena allocator and free everything by resetting the
//! arena — that is the intended usage.

const std = @import("std");

/// Refuse to slurp config files larger than this (something is wrong).
const max_config_bytes: usize = 1 << 20;

/// Which usage sources are enabled (key: `source`).
pub const Sources = packed struct {
    claude: bool = true,
    codex: bool = true,
    opencode: bool = true,

    pub const none: Sources = .{ .claude = false, .codex = false, .opencode = false };

    pub fn any(self: Sources) bool {
        return self.claude or self.codex or self.opencode;
    }
};

/// Which system stat modules are shown (key: `system-stats`).
pub const SystemStats = packed struct {
    cpu: bool = true,
    gpu: bool = true,
    mem: bool = true,
    disk: bool = true,
    net: bool = true,
    battery: bool = true,

    pub const none: SystemStats = .{ .cpu = false, .gpu = false, .mem = false, .disk = false, .net = false, .battery = false };

    pub fn any(self: SystemStats) bool {
        return self.cpu or self.gpu or self.mem or self.disk or self.net or self.battery;
    }
};

/// Default alert thresholds, in percent.
pub const default_alert_thresholds = [_]u8{ 70, 90 };

/// Parsed configuration with defaults. Field docs name the config key.
pub const Config = struct {
    /// `tray-format` — tray title template, stored verbatim. Placeholder
    /// substitution ({burn}, {eta}, ...) is the renderer's job.
    tray_format: []const u8 = "{burn} → {eta}",
    /// `alert-threshold` — notification thresholds in percent (0–100).
    /// Comma-separated, appendable across repeated keys.
    alert_thresholds: []const u8 = &default_alert_thresholds,
    /// `claude-oauth` — opt-in to Keychain OAuth limit polling.
    claude_oauth: bool = false,
    /// `poll-interval` — OAuth poll cadence in seconds. Accepts a bare
    /// number of seconds or an `s`/`m`/`h` suffix ("180", "180s", "3m", "1h").
    poll_interval_s: u32 = 180,
    /// `theme` — theme name, stored verbatim.
    theme: []const u8 = "tach-dark",
    /// `source` — enabled agents, comma-separated, appendable.
    sources: Sources = .{},
    /// `system-stats` — the system telemetry strip. `true`/`all` (default)
    /// shows every available module, `false`/`none` hides the strip, or a
    /// comma-separated module list (cpu, gpu, mem, disk, net, battery)
    /// shows exactly those.
    system_stats: SystemStats = .{},
    /// `claude-config-dir` — extra Claude config roots, appendable, one per
    /// line. Stored verbatim; `~` expansion is the CALLER's job. Empty
    /// (the default) means auto-discover.
    claude_config_dirs: []const []const u8 = &.{},
    /// `codex-home` — Codex root, stored verbatim. Empty means auto
    /// (`$CODEX_HOME` or `~/.codex`).
    codex_home: []const u8 = "",
    /// `opencode-db` — one OpenCode SQLite database. Empty means resolve
    /// `$OPENCODE_DB`, then `$XDG_DATA_HOME/opencode/opencode.db`, then
    /// `~/.local/share/opencode/opencode.db`.
    opencode_db: []const u8 = "",
};

/// A non-fatal parse problem: unknown key, malformed line, or bad value
/// (in which case the default/previous value was kept).
pub const Warning = struct {
    /// 1-based line number in the config text.
    line: usize,
    message: []const u8,
};

/// Result of parsing one config text. All slices (including warning
/// messages) are allocated with the allocator passed to `parse`/`load`;
/// use an arena and reset it to free.
pub const ParseResult = struct {
    config: Config,
    warnings: []const Warning,
};

/// Parse config text. Never fails on file *content* — malformed input only
/// produces warnings. The only error is `OutOfMemory`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}!ParseResult {
    var warnings: std.ArrayList(Warning) = .empty;
    var cfg: Config = .{};

    var thresholds: std.ArrayList(u8) = .empty;
    var thresholds_touched = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    var dirs_touched = false;
    var sources: Sources = .none;
    var sources_touched = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try warn(allocator, &warnings, line_no, "expected `key = value`, got \"{s}\"", .{line});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) {
            try warn(allocator, &warnings, line_no, "missing key before '='", .{});
            continue;
        }

        if (std.mem.eql(u8, key, "tray-format")) {
            cfg.tray_format = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "theme")) {
            cfg.theme = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "codex-home")) {
            cfg.codex_home = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "opencode-db")) {
            cfg.opencode_db = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "claude-oauth")) {
            if (parseBool(value)) |b| {
                cfg.claude_oauth = b;
            } else {
                try warn(allocator, &warnings, line_no, "claude-oauth: invalid boolean \"{s}\" (want true/false/yes/no/1/0); keeping {}", .{ value, cfg.claude_oauth });
            }
        } else if (std.mem.eql(u8, key, "poll-interval")) {
            if (parseDurationSeconds(value)) |secs| {
                cfg.poll_interval_s = secs;
            } else {
                try warn(allocator, &warnings, line_no, "poll-interval: invalid duration \"{s}\" (want e.g. 180, 180s, 3m, 1h); keeping {d}s", .{ value, cfg.poll_interval_s });
            }
        } else if (std.mem.eql(u8, key, "alert-threshold")) {
            if (value.len == 0) {
                // Explicit clear: `alert-threshold =` disables alerts.
                thresholds_touched = true;
                continue;
            }
            var items = std.mem.splitScalar(u8, value, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                const pct = std.fmt.parseInt(u8, item, 10) catch {
                    try warn(allocator, &warnings, line_no, "alert-threshold: invalid percent \"{s}\"; skipped", .{item});
                    continue;
                };
                if (pct > 100) {
                    try warn(allocator, &warnings, line_no, "alert-threshold: {d} is out of range (0-100); skipped", .{pct});
                    continue;
                }
                try thresholds.append(allocator, pct);
                thresholds_touched = true;
            }
        } else if (std.mem.eql(u8, key, "source")) {
            var items = std.mem.splitScalar(u8, value, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(item, "claude")) {
                    sources.claude = true;
                    sources_touched = true;
                } else if (std.ascii.eqlIgnoreCase(item, "codex")) {
                    sources.codex = true;
                    sources_touched = true;
                } else if (std.ascii.eqlIgnoreCase(item, "opencode")) {
                    sources.opencode = true;
                    sources_touched = true;
                } else {
                    try warn(allocator, &warnings, line_no, "source: unknown source \"{s}\" (want claude, codex, opencode); skipped", .{item});
                }
            }
        } else if (std.mem.eql(u8, key, "system-stats")) {
            if (parseBool(value)) |b| {
                cfg.system_stats = if (b) .{} else SystemStats.none;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(value, "all")) {
                cfg.system_stats = .{};
                continue;
            }
            if (std.ascii.eqlIgnoreCase(value, "none")) {
                cfg.system_stats = SystemStats.none;
                continue;
            }
            var picked = SystemStats.none;
            var any_valid = false;
            var items = std.mem.splitScalar(u8, value, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(item, "cpu")) {
                    picked.cpu = true;
                    any_valid = true;
                } else if (std.ascii.eqlIgnoreCase(item, "gpu")) {
                    picked.gpu = true;
                    any_valid = true;
                } else if (std.ascii.eqlIgnoreCase(item, "mem") or std.ascii.eqlIgnoreCase(item, "memory")) {
                    picked.mem = true;
                    any_valid = true;
                } else if (std.ascii.eqlIgnoreCase(item, "disk")) {
                    picked.disk = true;
                    any_valid = true;
                } else if (std.ascii.eqlIgnoreCase(item, "net") or std.ascii.eqlIgnoreCase(item, "network")) {
                    picked.net = true;
                    any_valid = true;
                } else if (std.ascii.eqlIgnoreCase(item, "battery") or std.ascii.eqlIgnoreCase(item, "bat")) {
                    picked.battery = true;
                    any_valid = true;
                } else {
                    try warn(allocator, &warnings, line_no, "system-stats: unknown module \"{s}\" (want cpu, gpu, mem, disk, net, battery); skipped", .{item});
                }
            }
            // A value that named only unknown modules keeps the previous
            // setting — bad values keep the default, per contract above.
            if (any_valid) cfg.system_stats = picked;
        } else if (std.mem.eql(u8, key, "claude-config-dir")) {
            if (value.len == 0) {
                // Explicit clear: back to auto-discovery.
                dirs_touched = true;
                continue;
            }
            try dirs.append(allocator, try allocator.dupe(u8, value));
            dirs_touched = true;
        } else {
            try warn(allocator, &warnings, line_no, "unknown key \"{s}\"", .{key});
        }
    }

    // A list key that only ever produced bad values stays untouched, so the
    // default survives (bad values keep the default, per contract above).
    if (thresholds_touched) cfg.alert_thresholds = try thresholds.toOwnedSlice(allocator);
    if (dirs_touched) cfg.claude_config_dirs = try dirs.toOwnedSlice(allocator);
    if (sources_touched) cfg.sources = sources;

    return .{
        .config = cfg,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

/// Read and parse the config file at `path_resolved` (absolute or
/// cwd-relative; `~` must already be expanded by the caller). Returns null
/// if the file does not exist. Same ownership rules as `parse`: pass an
/// arena allocator.
pub fn load(allocator: std.mem.Allocator, path_resolved: []const u8) !?ParseResult {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, path_resolved, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parse(allocator, text);
}

/// "<home>/.config/token-tach/config". Caller owns the returned slice.
pub fn defaultPath(allocator: std.mem.Allocator, home: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/token-tach/config", .{home});
}

/// Modification time of `path` in nanoseconds since the epoch, or null if
/// the file cannot be stat'ed. For live-reload polling: stash the value,
/// re-check on a timer, re-`load` when it changes.
pub fn fileMtimeNs(path: []const u8) ?i128 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(stat.mtime.nanoseconds);
}

/// Truncate `line` at the first `#` that starts a comment: at column 0 or
/// preceded by whitespace. A `#` embedded in a value (`tach-dark#red`) is
/// kept.
fn stripComment(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

fn parseBool(value: []const u8) ?bool {
    const truthy = [_][]const u8{ "true", "yes", "1" };
    const falsy = [_][]const u8{ "false", "no", "0" };
    for (truthy) |t| {
        if (std.ascii.eqlIgnoreCase(value, t)) return true;
    }
    for (falsy) |f| {
        if (std.ascii.eqlIgnoreCase(value, f)) return false;
    }
    return null;
}

/// "180" → 180, "180s" → 180, "3m" → 180, "1h" → 3600. Null on anything
/// else (including 0 and overflow — a zero poll interval is never wanted).
fn parseDurationSeconds(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var digits = value;
    var multiplier: u32 = 1;
    switch (value[value.len - 1]) {
        's' => digits = value[0 .. value.len - 1],
        'm' => {
            multiplier = 60;
            digits = value[0 .. value.len - 1];
        },
        'h' => {
            multiplier = 3600;
            digits = value[0 .. value.len - 1];
        },
        '0'...'9' => {},
        else => return null,
    }
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    const secs = std.math.mul(u32, n, multiplier) catch return null;
    if (secs == 0) return null;
    return secs;
}

fn warn(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(Warning),
    line: usize,
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    try warnings.append(allocator, .{
        .line = line,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "defaults when empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "");
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqualStrings("{burn} → {eta}", result.config.tray_format);
    try testing.expectEqualSlices(u8, &.{ 70, 90 }, result.config.alert_thresholds);
    try testing.expectEqual(false, result.config.claude_oauth);
    try testing.expectEqual(@as(u32, 180), result.config.poll_interval_s);
    try testing.expectEqualStrings("tach-dark", result.config.theme);
    try testing.expect(result.config.sources.claude);
    try testing.expect(result.config.sources.codex);
    try testing.expect(result.config.sources.opencode);
    try testing.expectEqual(@as(usize, 0), result.config.claude_config_dirs.len);
    try testing.expectEqualStrings("", result.config.codex_home);
    try testing.expectEqualStrings("", result.config.opencode_db);
}

test "comments-only file is equivalent to empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\# a full-line comment
        \\
        \\   # an indented comment
    );
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqual(@as(u32, 180), result.config.poll_interval_s);
}

test "full happy-path config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\# token-tach config
        \\tray-format = ⚡ {burn} → wall {eta}
        \\alert-threshold = 50
        \\claude-oauth = true
        \\poll-interval = 3m
        \\theme = tach-light
        \\source = claude
        \\claude-config-dir = ~/.claude
        \\codex-home = /Users/x/.codex
        \\opencode-db = /Users/x/.local/share/opencode/opencode.db
    );
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqualStrings("⚡ {burn} → wall {eta}", result.config.tray_format);
    try testing.expectEqualSlices(u8, &.{50}, result.config.alert_thresholds);
    try testing.expectEqual(true, result.config.claude_oauth);
    try testing.expectEqual(@as(u32, 180), result.config.poll_interval_s);
    try testing.expectEqualStrings("tach-light", result.config.theme);
    try testing.expect(result.config.sources.claude);
    try testing.expect(!result.config.sources.codex);
    try testing.expect(!result.config.sources.opencode);
    try testing.expectEqual(@as(usize, 1), result.config.claude_config_dirs.len);
    try testing.expectEqualStrings("~/.claude", result.config.claude_config_dirs[0]);
    try testing.expectEqualStrings("/Users/x/.codex", result.config.codex_home);
    try testing.expectEqualStrings("/Users/x/.local/share/opencode/opencode.db", result.config.opencode_db);
}

test "unknown key produces a warning with the line number" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\theme = tach-dark
        \\
        \\tray-fromat = oops
    );
    try testing.expectEqual(@as(usize, 1), result.warnings.len);
    try testing.expectEqual(@as(usize, 3), result.warnings[0].line);
    try testing.expect(std.mem.indexOf(u8, result.warnings[0].message, "tray-fromat") != null);
}

test "bad values warn and keep defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\claude-oauth = maybe
        \\poll-interval = soon
        \\alert-threshold = seventy
        \\source = cursor
        \\this line has no equals sign
    );
    try testing.expectEqual(@as(usize, 5), result.warnings.len);
    try testing.expectEqual(@as(usize, 1), result.warnings[0].line);
    try testing.expectEqual(@as(usize, 2), result.warnings[1].line);
    try testing.expectEqual(@as(usize, 3), result.warnings[2].line);
    try testing.expectEqual(@as(usize, 4), result.warnings[3].line);
    try testing.expectEqual(@as(usize, 5), result.warnings[4].line);
    // Defaults survive every bad value.
    try testing.expectEqual(false, result.config.claude_oauth);
    try testing.expectEqual(@as(u32, 180), result.config.poll_interval_s);
    try testing.expectEqualSlices(u8, &.{ 70, 90 }, result.config.alert_thresholds);
    try testing.expect(result.config.sources.claude);
    try testing.expect(result.config.sources.codex);
    try testing.expect(result.config.sources.opencode);
}

test "partially bad list keeps the good items" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "alert-threshold = 55, seventy, 120, 95");
    try testing.expectEqual(@as(usize, 2), result.warnings.len); // "seventy", 120
    try testing.expectEqualSlices(u8, &.{ 55, 95 }, result.config.alert_thresholds);
}

test "duration suffix parsing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { text: []const u8, want: u32 }{
        .{ .text = "poll-interval = 180", .want = 180 },
        .{ .text = "poll-interval = 180s", .want = 180 },
        .{ .text = "poll-interval = 3m", .want = 180 },
        .{ .text = "poll-interval = 1h", .want = 3600 },
        .{ .text = "poll-interval = 45", .want = 45 },
    };
    for (cases) |case| {
        const result = try parse(arena, case.text);
        try testing.expectEqual(@as(usize, 0), result.warnings.len);
        try testing.expectEqual(case.want, result.config.poll_interval_s);
    }
    // Zero and garbage keep the default.
    for ([_][]const u8{ "poll-interval = 0", "poll-interval = 0m", "poll-interval = 5x", "poll-interval = m" }) |text| {
        const result = try parse(arena, text);
        try testing.expectEqual(@as(usize, 1), result.warnings.len);
        try testing.expectEqual(@as(u32, 180), result.config.poll_interval_s);
    }
}

test "list keys append across repeated occurrences" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\alert-threshold = 50
        \\alert-threshold = 75, 95
        \\claude-config-dir = ~/.claude
        \\claude-config-dir = ~/work/.config/claude
        \\source = claude
        \\source = codex
    );
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqualSlices(u8, &.{ 50, 75, 95 }, result.config.alert_thresholds);
    try testing.expectEqual(@as(usize, 2), result.config.claude_config_dirs.len);
    try testing.expectEqualStrings("~/.claude", result.config.claude_config_dirs[0]);
    try testing.expectEqualStrings("~/work/.config/claude", result.config.claude_config_dirs[1]);
    try testing.expect(result.config.sources.claude);
    try testing.expect(result.config.sources.codex);
}

test "empty list value clears to empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "alert-threshold =");
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqual(@as(usize, 0), result.config.alert_thresholds.len);
}

test "repeated scalar keys: last wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\theme = first
        \\theme = second
        \\claude-oauth = true
        \\claude-oauth = nonsense
    );
    try testing.expectEqualStrings("second", result.config.theme);
    // A later bad value keeps the earlier good one.
    try testing.expectEqual(true, result.config.claude_oauth);
    try testing.expectEqual(@as(usize, 1), result.warnings.len);
}

test "trailing comments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "poll-interval = 45s # keep it snappy\n" ++
        "theme = tach-dark#red\n" ++
        "claude-oauth = yes\t# tab before the comment\n");
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqual(@as(u32, 45), result.config.poll_interval_s);
    // '#' without preceding whitespace stays part of the value.
    try testing.expectEqualStrings("tach-dark#red", result.config.theme);
    try testing.expectEqual(true, result.config.claude_oauth);
}

test "whitespace chaos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "\t  theme=tach-light  \r\n" ++
        "poll-interval\t =\t 2m\r\n" ++
        "   \r\n" ++
        "alert-threshold =  10 ,\t20 , 30\t\r\n" ++
        "claude-oauth   =yes\n");
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqualStrings("tach-light", result.config.theme);
    try testing.expectEqual(@as(u32, 120), result.config.poll_interval_s);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, result.config.alert_thresholds);
    try testing.expectEqual(true, result.config.claude_oauth);
}

test "boolean spellings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const truthy = [_][]const u8{ "true", "yes", "1", "TRUE", "Yes" };
    for (truthy) |v| {
        const text = try std.fmt.allocPrint(arena, "claude-oauth = {s}", .{v});
        const result = try parse(arena, text);
        try testing.expectEqual(true, result.config.claude_oauth);
    }
    const falsy = [_][]const u8{ "false", "no", "0", "False" };
    for (falsy) |v| {
        const text = try std.fmt.allocPrint(arena, "claude-oauth = true\nclaude-oauth = {s}", .{v});
        const result = try parse(arena, text);
        try testing.expectEqual(false, result.config.claude_oauth);
    }
}

test "defaultPath joins home" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try defaultPath(arena, "/Users/phall");
    try testing.expectEqualStrings("/Users/phall/.config/token-tach/config", path);
}

test "load returns null for a missing file, fileMtimeNs returns null too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const missing = "/nonexistent/token-tach-test/config";
    try testing.expectEqual(@as(?ParseResult, null), try load(arena, missing));
    try testing.expectEqual(@as(?i128, null), fileMtimeNs(missing));
}

test "load reads and parses a real file; fileMtimeNs sees it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config",
        .data = "theme = from-disk # trailing comment\npoll-interval = 2m\n",
    });

    // tmpDir lives under .zig-cache/tmp/<sub_path> relative to the test
    // process cwd, and load/fileMtimeNs resolve relative paths against
    // that same cwd.
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/config", .{tmp.sub_path});

    const result = (try load(arena, path)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
    try testing.expectEqualStrings("from-disk", result.config.theme);
    try testing.expectEqual(@as(u32, 120), result.config.poll_interval_s);

    const mtime = fileMtimeNs(path) orelse return error.TestUnexpectedResult;
    try testing.expect(mtime > 0);
}

test "system-stats accepts booleans, all/none, and module lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const off = try parse(arena, "system-stats = false\n");
    try testing.expect(!off.config.system_stats.any());

    const back_on = try parse(arena, "system-stats = none\nsystem-stats = all\n");
    try testing.expect(back_on.config.system_stats.cpu);
    try testing.expect(back_on.config.system_stats.battery);

    const some = try parse(arena, "system-stats = cpu, gpu, memory\n");
    try testing.expect(some.config.system_stats.cpu);
    try testing.expect(some.config.system_stats.gpu);
    try testing.expect(some.config.system_stats.mem);
    try testing.expect(!some.config.system_stats.disk);
    try testing.expect(!some.config.system_stats.net);
    try testing.expect(!some.config.system_stats.battery);
    try testing.expectEqual(@as(usize, 0), some.warnings.len);
}

test "system-stats keeps the default when only unknown modules are named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "system-stats = fan, vibes\n");
    try testing.expect(result.config.system_stats.cpu);
    try testing.expect(result.config.system_stats.battery);
    try testing.expectEqual(@as(usize, 2), result.warnings.len);
}
