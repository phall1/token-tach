# token-tach — Plan of Record

A macOS-native menu-bar instrument for AI coding-agent token usage and
subscription limits. LiteLLM-dashboard truth, without the proxy: everything is
read from local session ledgers plus each vendor's own limit data.

Decisions below were made 2026-07-09 after research into vercel-labs/native,
the data-source landscape, and ~20 prior-art apps.

---

## Locked decisions

| Axis | Decision |
|---|---|
| Stack | **vercel-labs Native SDK v0.4** (Zig + `.native` markup), forked/vendored with ObjC host patches |
| Hero glance | **Burn rate + predicted cutoff** in the live tray title: `⚡ 4.2k/m → wall 3:40p` |
| Vibe | **Instrument cluster / tachometer** — needle sweep for burn, redline at the wall, odometer totals. Dark, glowy, kinetic. The name is the brand. |
| Surfaces | All of them, staged: tray → popover → dashboard window → notifications → CLI/statusline. Ghostty-energy: great defaults, clean seams for config. |
| Config | Plain-text key=value file at `~/.config/token-tach/config`, live-reloaded, ghostty-style (which is *the* idiomatic Zig-app config — ghostty itself is Zig). No settings UI in v1. |
| End state | **Open source, full spice** — signed/notarized releases, Keychain OAuth access opt-in with a clear trust story. |
| v1 cutline | Glance + truth first (see roadmap). |

---

## Stack detail

- **Native SDK v0.4+** (`github.com/vercel-labs/native`, Apache-2.0). Declarative
  `.native` markup compiled at build time; logic in Zig (Elm-style Model/Msg/update).
  Custom Metal renderer; real `NSStatusItem` tray with live-updating title;
  built-in `<chart>` component (line/area/bar, downsampling, hover); `fx.readFile`,
  `fx.spawn`, `fx.startTimer`, notifications, keychain credentials — all
  permission-gated via `app.zon`.
- **Fork & patch the ObjC host** (`src/platform/macos/appkit_host.m`, plain ObjC,
  Zig has first-class C interop). Patches to carry, PR'd upstream:
  1. `NSPopover` anchored to the status item (transient dismiss) — the one-click popover.
  2. `LSUIElement=YES` in generated Info.plist (menu-bar-only, no Dock icon).
  3. `SMAppService` launch-at-login.
- **Known SDK gaps we absorb**: no file watching (poll JSONL trees with
  `fx.startTimer`, 1–2 s, byte-offset tailing — cheap); pre-1.0 API churn
  (pin + vendor the fork; expect rebase cost per 0.x release; project is 2 months
  old, single maintainer — this is the accepted risk of the fun bet).
- **Escape hatches**: `fx.spawn` for anything shell-able; whole macOS host is
  readable ObjC in-tree; `native_module` capability exists.

## Architecture

```
token-tach/
├── vendor/native/            # forked SDK, pinned + patched
├── src/
│   ├── main.zig              # Model/Msg/update loop
│   ├── app.native            # popover + dashboard markup
│   ├── core/                 # UI-free engine (also powers future CLI)
│   │   ├── source.zig        # Source interface (poll → Snapshot)
│   │   ├── claude.zig        # JSONL tailer + OAuth limits poller
│   │   ├── codex.zig         # JSONL tailer (limits embedded, free)
│   │   ├── pricing.zig       # LiteLLM model-prices db (bundled + refresh)
│   │   ├── predict.zig       # burn rate, ETA-to-wall
│   │   └── ledger.zig        # dedup, rollups (session/5h/day/week)
│   └── config.zig            # key=value parser, live reload, schema→docs
└── app.zon                   # capabilities: tray, filesystem, network, notifications, credentials
```

## Data sources (verified 2026-07-09)

### Claude Code — tokens (local, no creds)
- Glob `projects/**/*.jsonl` under each of: `$CLAUDE_CONFIG_DIR` (may be
  comma-separated list), `~/.config/claude`, `~/.claude`. Include
  `<session>/subagents/agent-*.jsonl`.
- Token lines: `type == "assistant"`; fields `message.usage.{input_tokens,
  output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`,
  `message.model`, `timestamp`, `sessionId`, `cwd` (→ per-project attribution later).
- **Dedup key: `message.id + ":" + requestId`** (messages reappear across
  resumed sessions / subagent files).
- `costUSD` is null on current versions → always compute from tokens ×
  LiteLLM `model_prices_and_context_window.json` rates (input / output /
  cache-write / cache-read).
- Files are append-only NDJSON; tail by byte offset, buffer partial last line.

### Claude Code — plan limits (server truth)
- `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, and
  **`User-Agent: claude-code/<version>` (mandatory — wrong UA → persistent 429s)**.
- Returns `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet`:
  `{utilization: 0–100, resets_at: ISO8601}`.
- Token: Keychain generic password, service **`Claude Code-credentials`** →
  JSON `claudeAiOauth.accessToken` (expires ~60 min; `refreshToken` present;
  `subscriptionType` gives plan tier with zero network). Use SecItem via the
  SDK credentials API / host patch — never shell out to `security`.
- Poll every **180 s**, cache, exponential backoff on 429 (3→6→12 min, cap 15),
  show staleness in UI past 5 min. Opt-in via `claude-oauth = true`.

### Codex CLI — tokens AND limits (local only, zero network)
- `$CODEX_HOME` (default `~/.codex`) `/sessions/YYYY/MM/DD/rollout-*.jsonl`.
- `event_msg` lines with `payload.type == "token_count"`:
  `info.total_token_usage` is **cumulative per session** (subtract previous
  total for per-turn); `info.last_token_usage` = latest turn.
- Same events embed `rate_limits`: `primary` (5 h) / `secondary` (weekly)
  `{used_percent, window_minutes, resets_at (epoch sec)}` + `plan_type`.
  Current limits = last token_count line of newest rollout file.

### Later sources (plugin seam)
- opencode (`~/.local/share/opencode/storage/`, JSON, has per-message tokens/cost),
  Gemini CLI (requires user-enabled local OTEL telemetry), others behind the
  `Source` interface. Cursor/Copilot are server-side only — out of scope.

## Prediction (the differentiator)

- Burn rate: EWMA of tokens/min from tailed events (window ~10 min), per agent
  and blended.
- ETA-to-wall: for each limit window, project `used_percent` forward at current
  burn → `min()` across windows = "the wall", rendered as clock time.
  Idle state (no events N min) → show reset countdown instead.
- Later (v1.x): learn per-window token capacity from history (P90 approach à la
  Claude-Code-Usage-Monitor) so ETA works even between OAuth polls.

## Roadmap

- **v0.5 — the swiss-army cluster** (shipped 2026-07-22): the glance
  thesis generalized beyond tokens — system telemetry (CPU, GPU, memory
  pressure, disk, network, battery) sampled natively (mach/sysctl/IOKit,
  no subprocesses, no root) on the same 2 s sweep, surfaced as a quiet
  micro-meter strip in the popover, `{cpu}`-style tray tokens, and a
  `system` object in `--json`. Vendored SDK rebased onto upstream v0.5.4.

- **v1.0 — glance + truth**: live tray title (burn + ETA, format-string
  configurable), tray popover (patched) with tach gauge + 5h/weekly bars +
  reset countdowns per agent, Claude JSONL + OAuth, Codex JSONL, pricing,
  config file, launch-at-login, dock-less.
- **v1.1**: standalone dashboard window — history (day/week/month bars),
  per-model + per-project breakdowns, odometer totals, subscription-value
  ("API-equivalent $ earned on your plan").
- **v1.2**: notifications — threshold crossings (70/90 %), predicted wall
  within N min, window-reset all-clear. Quiet hours.
- **v1.3**: `token-tach --json` CLI / statusline output from the same core.
- **v2**: plugin sources (opencode, Gemini), themes, maybe WidgetKit companion
  (requires a small Swift extension — separate decision).

## Distribution / trust story

- `native package --target macos` → .app + DMG; Developer ID signing +
  hardened runtime via SDK tooling; notarize with notarytool.
- Trust posture for the README: local-files-only by default; Keychain/OAuth is
  an explicit opt-in config line; document the exact endpoint, headers, and
  poll cadence; no telemetry, no analytics, everything auditable.

## Risks

1. **SDK churn** (renamed end-to-end the day before this plan) — pin + vendor;
   budget rebase time per release; core/ stays UI-free so a shell swap is survivable.
2. **Fork patches drift** — keep them small, PR upstream early.
3. **OAuth endpoint is undocumented** — degrade gracefully to JSONL-estimated
   limits when it changes; Codex limits are immune (local).
4. **Access-token expiry (~60 min)** — read Keychain fresh each poll (Claude
   Code refreshes it); only implement our own refresh flow if that proves flaky.
