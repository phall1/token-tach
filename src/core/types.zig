//! Shared engine types. UI-free: nothing in src/core may import runner,
//! canvas, or platform modules — this tree also feeds the future CLI.

const std = @import("std");

/// Which agent produced an event or limit reading.
///
/// The first three are the "core" agents with dedicated popover UI
/// (claude/codex limit groups, the opencode row); everything after is
/// the tt-hr8 expansion — collected with exact local token telemetry,
/// aggregated compactly in the popover, itemized in the dashboard and
/// CLI. Adding a member here auto-extends `source =` config parsing
/// (config.Sources), ledger rollups (EnumArray), CLI coverage, and the
/// dashboard agents table; the engine still needs a collector wired in
/// sweepOnce.
pub const Agent = enum {
    claude,
    codex,
    opencode,
    pi,
    gemini,
    qwen,
    kimi,
    goose,
    kilo,
    cline,
    roo,
    copilot,
    continue_cli,
    droid,

    pub fn label(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .opencode => "opencode",
            .pi => "pi",
            .gemini => "gemini",
            .qwen => "qwen",
            .kimi => "kimi",
            .goose => "goose",
            .kilo => "kilo",
            .cline => "cline",
            .roo => "roo",
            .copilot => "copilot",
            .continue_cli => "continue",
            .droid => "droid",
        };
    }

    /// Agents with dedicated popover panels (limit windows, staleness).
    /// Everything else renders through the aggregate treatment.
    pub fn hasLimitsPanel(self: Agent) bool {
        return self == .claude or self == .codex;
    }

    /// Agent -> on-disk id, the durable-history counterpart of `label()`.
    ///
    /// These numbers ARE the persisted identity of an agent. They may be
    /// appended to but MUST NEVER be reordered or reused: every record ever
    /// written carries one of them, and renumbering silently re-attributes
    /// years of history to a different tool with no error, no migration, and
    /// no way to tell after the fact. The switch is exhaustive on purpose —
    /// adding an `Agent` member fails to compile here until someone assigns
    /// it a number, which is the only moment anyone will think about it.
    ///
    /// 0 is reserved (an unwritten byte must not name an agent) and 255 is
    /// history.zig's synthetic marker, so ids start at 1.
    pub fn storageId(self: Agent) u8 {
        return switch (self) {
            .claude => 1,
            .codex => 2,
            .opencode => 3,
            .pi => 4,
            .gemini => 5,
            .qwen => 6,
            .kimi => 7,
            .goose => 8,
            .kilo => 9,
            .cline => 10,
            .roo => 11,
            .copilot => 12,
            .continue_cli => 13,
            .droid => 14,
        };
    }

    /// On-disk id -> Agent, or null for an id this build has never heard of
    /// (a record written by a NEWER build, or a removed agent). Callers must
    /// keep such rows: an unrecognized producer is still real spend, and a
    /// downgrade that dropped rows it could not name would silently shrink
    /// the user's history.
    pub fn fromStorageId(id: u8) ?Agent {
        inline for (@typeInfo(Agent).@"enum".fields) |field| {
            const agent: Agent = @enumFromInt(field.value);
            if (agent.storageId() == id) return agent;
        }
        return null;
    }
};

/// One priced unit of token consumption, normalized across agents.
/// Claude: one assistant message. Codex: one turn (cumulative diff).
pub const UsageEvent = struct {
    agent: Agent,
    /// Unix milliseconds.
    timestamp_ms: i64,
    /// Model identifier as logged (e.g. "claude-fable-5", "gpt-5.2-codex").
    model: []const u8,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    /// Session/rollout the event belongs to.
    session_id: []const u8 = "",
    /// Working directory as the agent logged it. Keeps its literal meaning:
    /// this is where the agent actually ran, worktree and subdirectory
    /// included, which is what a session's detail row shows.
    cwd: []const u8 = "",
    /// Repository root `cwd` belongs to, resolved at ingest by
    /// `core/project.zig`. Empty when nothing resolved it — a collector
    /// building an event by hand, or a cwd we could not classify.
    ///
    /// This, not `cwd`, is the per-project aggregation key. A git worktree
    /// is a different directory and the same project; so is a
    /// subdirectory. See `projectKey`.
    project_root: []const u8 = "",

    /// The key the project dimension groups on. Falls back to `cwd` so an
    /// event that never passed through the resolver still lands somewhere
    /// truthful instead of in a nameless bucket.
    pub fn projectKey(self: UsageEvent) []const u8 {
        return if (self.project_root.len > 0) self.project_root else self.cwd;
    }

    pub fn totalTokens(self: UsageEvent) u64 {
        return self.input_tokens + self.output_tokens +
            self.cache_creation_tokens + self.cache_read_tokens;
    }
};

/// A subscription limit window reading (server truth or embedded).
pub const LimitWindow = struct {
    /// e.g. .five_hour, .weekly, .weekly_opus
    kind: Kind,
    /// 0–100.
    used_percent: f64,
    /// Unix milliseconds when the window resets; 0 if unknown.
    resets_at_ms: i64 = 0,

    pub const Kind = enum { five_hour, weekly, weekly_opus, weekly_sonnet, monthly };
};

/// Snapshot of an agent's limit state.
pub const LimitSnapshot = struct {
    agent: Agent,
    /// Unix ms when this reading was taken (staleness display).
    read_at_ms: i64,
    plan: []const u8 = "",
    windows: []const LimitWindow = &.{},
};

test "agent storage ids are a frozen wire format: stable, dense, unique" {
    // Spot-checks on the endpoints. If reordering the `Agent` enum ever
    // renumbers anything, these are the assertions that catch it before a
    // release rewrites every user's history.
    try std.testing.expectEqual(@as(u8, 1), Agent.claude.storageId());
    try std.testing.expectEqual(@as(u8, 2), Agent.codex.storageId());
    try std.testing.expectEqual(@as(u8, 3), Agent.opencode.storageId());
    try std.testing.expectEqual(@as(u8, 14), Agent.droid.storageId());

    var seen = std.AutoHashMap(u8, void).init(std.testing.allocator);
    defer seen.deinit();
    inline for (@typeInfo(Agent).@"enum".fields) |field| {
        const agent: Agent = @enumFromInt(field.value);
        const id = agent.storageId();
        // 0 is "no agent written" and 255 is history.zig's synthetic
        // marker; neither may collide with a real agent.
        try std.testing.expect(id != 0 and id != 255);
        try std.testing.expect(!seen.contains(id));
        try seen.put(id, {});
        try std.testing.expectEqual(agent, Agent.fromStorageId(id).?);
    }

    // An id from a newer build round-trips to null, not to a neighbor.
    try std.testing.expectEqual(@as(?Agent, null), Agent.fromStorageId(0));
    try std.testing.expectEqual(@as(?Agent, null), Agent.fromStorageId(200));
}

test {
    const ev = UsageEvent{
        .agent = .claude,
        .timestamp_ms = 0,
        .model = "claude-fable-5",
        .input_tokens = 1,
        .output_tokens = 2,
        .cache_creation_tokens = 3,
        .cache_read_tokens = 4,
    };
    try std.testing.expectEqual(@as(u64, 10), ev.totalTokens());
}
