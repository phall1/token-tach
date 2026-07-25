# Usage Coverage

Token Tach is local-first and automatic: install it, launch it, and it scans
known coding-harness storage locations without modifying them. The collector
priority is exact local provider counters first, mutable provider-reported
session totals second, and no estimate when exact historical usage is absent.

## Automatic Sources

| Source | Default local surface | Fidelity | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | exact | Per-message input/output/cache counters; cross-file message/request dedup |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` | exact | Per-turn cumulative deltas plus embedded 5h/weekly limits |
| OpenCode | `~/.local/share/opencode/opencode.db` | exact | Read-only usage-only SQL projection |
| Gemini CLI | `~/.gemini/tmp/**/chats/*.{jsonl,json}` | exact | Current append-only and legacy session formats |
| Qwen Code | `~/.qwen/usage/token-usage-YYYY-MM.jsonl` | exact | Dedicated schema-versioned usage ledger |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | exact | Assistant, compaction, branch-summary, and billable tool-result calls |
| Kimi CLI | `~/.kimi/sessions/*/*/wire.jsonl` | limited | Exact counters; old records without message IDs use deterministic fingerprints |
| Grok Build | `~/.grok/sessions/*/*/updates.jsonl` | exact | Completed turns, split by model when available |
| GitHub Copilot CLI | `~/.copilot/session-store.db` | exact | Dedicated `assistant_usage_events` rows; AIU is not presented as USD |
| Cline | `~/.cline/data/db/sessions.db` and editor task stores | limited | Root aggregate or per-call editor metrics, avoiding root/subagent double counts |
| Roo Code | editor global-storage task summaries | limited | Provider-reported mutable task totals; historical model switching is unavailable |
| Continue CLI | `~/.continue/sessions/*.json` | limited | Provider-reported mutable session totals with nested cache/reasoning detail |
| Kilo Code | `~/.local/share/kilo/kilo.db` | limited | Read-only cumulative session projection; no prompt-bearing columns selected |
| Goose | macOS app-support or XDG `sessions.db` | exact | Append-only `usage_ledger` rows |
| Factory Droid | `~/.factory/sessions/**` sidecars or JSONL | limited | Sidecar aggregate preferred; per-call JSONL is the fallback |

Environment overrides used by each harness are honored, including
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_DB`, `GEMINI_CLI_HOME`,
`QWEN_HOME`, `QWEN_RUNTIME_DIR`, `PI_CODING_AGENT_DIR`,
`PI_CODING_AGENT_SESSION_DIR`, `KIMI_SHARE_DIR`, `GROK_HOME`, `COPILOT_HOME`,
`CLINE_DIR`, `CLINE_DATA_DIR`, `CONTINUE_GLOBAL_DIR`, `KILO_DB`,
`GOOSE_PATH_ROOT`, and XDG data/state roots.

## Honest Gaps

| Surface | Status | Why automatic exact history is unavailable |
|---|---|---|
| Cursor | unsupported | Local chat/session state has no verified durable exact-token ledger |
| Windsurf | unsupported | Local state has no verified durable exact-token ledger |
| Aider | needs setup | Exact response usage is not persisted by default |
| Amp | needs setup | Runtime usage is exposed, but no default durable ledger is documented |
| Copilot VS Code | needs setup | Exact local history requires enabling its OTel database exporter in advance |
| Zed | unsupported | Usage is inside a zstd-compressed blob that also contains prompts and responses |
| Amazon Q | unsupported | Local history stores IDs and conversations, not exact provider counters |
| Crush | unsupported | Persisted token values are mutable context estimates, not lifetime usage |

Provider admin APIs and gateways can reconcile organization-level usage, but
they require credentials, account selection, or prior traffic routing. They
cannot be zero-config and are intentionally separate from the automatic local
collector.

## Accounting Rules

- Cached input is normalized into separate uncached-input, cache-read, and
  cache-creation buckets so totals are not doubled.
- Reasoning is added only when the source reports it outside output tokens.
- Stable request/message IDs are preferred; source-native session/record keys
  are the fallback.
- Mutable cumulative snapshots emit only positive growth after their first
  observation. Counter resets become explicit replacements.
- Prompts, responses, tool arguments, credentials, and auth payloads are never
  persisted by Token Tach. SQLite collectors never select those columns.
- `--json.coverage` exposes detection, enablement, fidelity, and the reason for
  every supported or known-unavailable surface.
