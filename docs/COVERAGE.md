# Usage Coverage

Token Tach is local-first and automatic: install it, launch it, and it scans
known coding-harness storage locations without modifying them. The bar is
**exact local counters only** — when a harness does not persist exact token
usage, Token Tach reports the gap instead of estimating.

`token-tach --json` carries the live answer in `coverage`: per source,
whether it is enabled in config, whether its data location exists on this
machine, and how many events it has contributed.

## Automatic sources (shipped)

| Source | Default local surface | Fidelity | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | exact | Per-message counters; cross-file message/request dedup |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` | exact | Per-turn cumulative deltas plus embedded 5h/weekly limits |
| OpenCode | `~/.local/share/opencode/opencode.db` | exact | Read-only usage-only SQL projection |
| Pi | `~/.pi/agent/sessions/**/*.jsonl` | exact | Per-message counters; fork re-logs deduped |
| Gemini CLI | `~/.gemini/tmp/**/chats/*.jsonl` | exact | Cache reads are a subset of prompt tokens — never double counted |
| Qwen Code | `~/.qwen/{projects,tmp}/**/*.jsonl` | exact | Per-response `usageMetadata` |
| Kimi CLI | `~/.kimi/sessions/*/*/wire.jsonl` | exact, unpriced | Model id is not logged per call — counted, not costed |
| Goose | `sessions.db` (app support / `GOOSE_PATH_ROOT`) | exact | Append-only `usage_ledger` rows |
| Kilo Code | `~/.local/share/kilo/kilo.db` | exact | Read-only projection; no content columns selected |
| Cline | `~/.cline/data/sessions/*.messages.json` + editor task stores | exact | Snapshot reconciliation by stable message ids |
| Roo Code | editor global-storage `ui_messages.json` | exact | Same snapshot reconciliation as Cline legacy |

Environment overrides are honored per harness: `CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `OPENCODE_DB`, `PI_HOME`, `GEMINI_CLI_HOME`, `QWEN_HOME`,
`QWEN_RUNTIME_DIR`, `KIMI_SHARE_DIR`, `GOOSE_PATH_ROOT`, `KILO_DB`,
`CLINE_DIR`, `CLINE_DATA_DIR`, plus XDG data/state roots.

## Pending reconciliation

Two independent format-research passes reached conflicting conclusions for
these sources, so their collectors are held back (enum-reserved, config-
recognized, zero counters) until the formats are re-verified against real
data — exact-only is the bar:

| Source | Contested question |
|---|---|
| GitHub Copilot CLI | usage rows in `session-store.db` vs cumulative `session.shutdown` events in `events.jsonl` |
| Continue CLI | mutable session-cumulative totals with an estimation fallback when the API omits usage |
| Factory Droid | sidecar `settings.json` aggregate vs per-call JSONL |
| Grok Build | whether `updates.jsonl`/`signals.json` persist billable usage at all |

## Honest gaps

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
story.
