//! Shared engine types. UI-free: nothing in src/core may import runner,
//! canvas, or platform modules — this tree also feeds the future CLI.

const std = @import("std");

/// Which agent produced an event or limit reading.
pub const Agent = enum {
    claude,
    codex,
    opencode,
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

    pub fn label(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .opencode => "opencode",
            .gemini => "gemini",
            .qwen => "qwen",
            .pi => "pi",
            .kimi => "kimi",
            .grok => "grok",
            .copilot => "copilot",
            .cline => "cline",
            .roo => "roo",
            .continue_cli => "continue",
            .kilo => "kilo",
            .goose => "goose",
            .droid => "droid",
        };
    }

    pub fn displayLabel(self: Agent) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex CLI",
            .opencode => "OpenCode",
            .gemini => "Gemini CLI",
            .qwen => "Qwen Code",
            .pi => "Pi",
            .kimi => "Kimi CLI",
            .grok => "Grok Build",
            .copilot => "Copilot CLI",
            .cline => "Cline",
            .roo => "Roo Code",
            .continue_cli => "Continue CLI",
            .kilo => "Kilo Code",
            .goose => "Goose",
            .droid => "Factory Droid",
        };
    }

    pub fn parse(value: []const u8) ?Agent {
        inline for (std.meta.tags(Agent)) |agent| {
            if (std.ascii.eqlIgnoreCase(value, @tagName(agent))) return agent;
            if (std.ascii.eqlIgnoreCase(value, agent.label())) return agent;
        }
        if (std.ascii.eqlIgnoreCase(value, "claude-code")) return .claude;
        if (std.ascii.eqlIgnoreCase(value, "codex-cli")) return .codex;
        if (std.ascii.eqlIgnoreCase(value, "gemini-cli")) return .gemini;
        if (std.ascii.eqlIgnoreCase(value, "qwen-code")) return .qwen;
        if (std.ascii.eqlIgnoreCase(value, "kimi-cli")) return .kimi;
        if (std.ascii.eqlIgnoreCase(value, "grok-build")) return .grok;
        if (std.ascii.eqlIgnoreCase(value, "github-copilot")) return .copilot;
        if (std.ascii.eqlIgnoreCase(value, "roo-code")) return .roo;
        if (std.ascii.eqlIgnoreCase(value, "continue-cli")) return .continue_cli;
        if (std.ascii.eqlIgnoreCase(value, "kilo-code")) return .kilo;
        if (std.ascii.eqlIgnoreCase(value, "factory") or std.ascii.eqlIgnoreCase(value, "factory-droid")) return .droid;
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
