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
    /// Working directory (claude) — powers per-project attribution.
    cwd: []const u8 = "",

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
