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
| Stack | **vercel-labs Native SDK** (Zig + `.native` markup), forked/vendored with ObjC host patches. Decided at upstream v0.4; pinned to **upstream v0.8.0** as of v0.9 |
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
  Zig has first-class C interop). Patches carried on the fork
  (`phall1/native@token-tach-patches-v0.8.0`); the original "PR'd upstream"
  intent was withdrawn — patches stay on the fork, available on request:
  1. `NSPopover` anchored to the status item (transient dismiss) — the one-click popover.
  2. `app.zon` `.macos.accessory` → `LSUIElement` (menu-bar-only, no Dock icon).
  3. `SMAppService` launch-at-login.
  4. Render animations anchored to the presenting frame, not the declarer's
     stale clock (added at the v0.8.0 rebase).
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

### Local harness coverage (v0.6, the collector fleet)
- Automatic exact-token collectors: Claude Code, Codex CLI, OpenCode, Pi,
  Gemini CLI, Qwen Code, Kimi CLI, Goose, Kilo Code, Cline, Roo Code —
  built on two generic engines (tailsource for append-only JSONL,
  snapsource for rewritten-JSON snapshots) plus read-only SQLite pollers.
- Stable per-record keys reconcile through add/replace or dedup semantics;
  tailer offsets, SQLite high-waters, and snapshot records persist in
  statefile v3 for warm restarts.
- `--json.coverage` reports enabled/detected/events per source. Copilot CLI,
  Continue CLI, and Factory Droid are enum-reserved (`types.Agent` members
  `copilot`, `continue_cli`, `droid`) but pending format reconciliation —
  two research passes disagreed; see the bead tracker. Grok Build has no
  enum slot at all: the research could not establish that it persists
  billable usage anywhere. Exact-only is the bar, so contested formats
  don't ship counters.
- Cursor, Windsurf, Aider, Amp, Zed, Amazon Q, and Crush remain explicit
  gaps until they expose durable exact counters (see docs/COVERAGE.md).

## Prediction (the differentiator)

- Burn rate: EWMA of tokens/min from tailed events (window ~10 min), per agent
  and blended.
- ETA-to-wall: for each limit window, project `used_percent` forward at current
  burn → `min()` across windows = "the wall", rendered as clock time.
  Idle state (no events N min) → show reset countdown instead.
- Later (v1.x): learn per-window token capacity from history (P90 approach à la
  Claude-Code-Usage-Monitor) so ETA works even between OAuth polls.

## v0.9 — the memory wave (landed 2026-08-04, unreleased at time of writing)

The product question moved from "how much am I burning" to "**which agent
is burning it, and what did that cost me last month**". Both halves of
that needed state the app did not have: a live per-session dimension, and
a durable time series. This section records what landed and, more
usefully, the four decisions that were genuinely contested.

### What landed

- **`src/core/history.zig`** — a durable append-only usage time series
  under `$XDG_STATE_HOME/token-tach/history/`. Three tiers (48 h minute
  ring, hour log, day log), 64-byte fixed records keyed by bucket × agent
  × model × project × session, an append-only string dictionary, one
  `flock` writer.
- **`src/core/sessions.zig`** — a fixed-capacity (32) live roster of agent
  sessions: agent, project, model, turns, tokens, cost, per-session burn
  ring, and an `Activity` of running/idle/done.
- **`predict.AgentBurn`** — burn split per agent (one minute ring each)
  plus one shared fine-grained scope trace, and `hottest(now_ms)`.
- **`engine.SystemHistory`** — 5 s × 360 buckets = exactly 30 minutes of
  cpu/gpu/mem/disk/net/battery on a wall clock, ~12.5 KB of Model.
- **Trip odometer** — `Model.trip` / `trip_start_ms`, this-launch totals.
- **`ledger.per_hour` / `per_session`**, and range queries on the ledger.
- **Six CLI query verbs** — `history`, `burn`, `top`, `sessions`,
  `export`, `doctor` — plus `history` in `--json`, per-agent `today` /
  `month` splits, `first_seen_ms` / `last_seen_ms` in `coverage`, and a
  `burn_tokens_per_min` that is finally a number.
- **Statefile v5**, and the vendored SDK rebased onto upstream v0.8.0.

### Decision: per-session data has three lifetimes, and they do not merge

The obvious design — one session table, persisted — is wrong, and the
reason is that "session" means three different things depending on how
long the answer is supposed to survive:

| Lifetime | Home | Why it cannot be one of the others |
|---|---|---|
| **INSTANT** | `sessions.Roster` | Liveness. A restored `running` row would be a claim about a process that exited while the app was closed — a lie, not stale data. So the roster is never persisted, at all. |
| **PROCESS** | `ledger.per_session` | Bounded rollups that ride in the statefile so a warm launch doesn't lose today's per-session totals. Cache-shaped: deletable, re-derivable. |
| **FOREVER** | `history.zig`'s session dimension | Truth. The agents rotate and delete their own transcripts, so after that happens this is the only copy that exists anywhere. |

Persisting the roster would collapse the first two and make a liveness
flag durable, which is exactly the failure the split exists to prevent.

The roster's flagship signal falls out of the same discipline: a usage
event proves a turn *finished*, not that anything is running. Claude Code
writes user/tool_use/tool_result lines continuously during a turn and only
appends the token-bearing assistant line at the end — so **a transcript
that grew with no parsed event behind it means an agent is thinking right
now**. Growth and events are recorded through two separate entry points
and `mid_turn` is a stored flag, not `last_growth_ms > last_event_ms`:
event timestamps come from the transcript's own clock and routinely trail
our wall clock by a second or two, so the derived comparison would leave
freshly-completed turns permanently stuck reading "mid-turn".

### Decision: hour keys are LOCAL, not UTC

"Hours don't have a timezone" is true and irrelevant. Every hourly reading
this instrument wants is a *slice of a local day*: "today by hour", "the
current 5 h window". With UTC hour keys and a half-hour zone — IST +5:30,
NPT +5:45 — local midnight lands in the **middle** of a bucket, so the
first and last bars of "today" silently include minutes from the
neighbouring day and **the hourly bars stop summing to the daily total**.
A chart whose parts don't add up to its own total is not a chart anyone
should ship.

Shifting the instant before the divide makes the nesting exact for every
offset, because 86_400_000 is a whole multiple of 3_600_000 and both floor
the same shifted instant: `dayOfHour(hourKey(t, off)) == dayKey(t, off)`,
always. (`ledger.zig:60-84`; there is a test over a table of offsets.)

The price: a DST change re-buckets only *future* events, so the wall-clock
hour a historical bucket represents shifts by the delta. One ambiguous
hour twice a year beats permanently wrong "today" edges in half the
world's timezones.

Note this is the **ledger's** rule. `history.zig` splits the difference on
purpose: its minute and hour tiers are UTC (a flight to Tokyo must not
retroactively corrupt an archive, and a UTC bucket is the only key that
survives a timezone move), while `days.log` is local and carries the
offset its keys were computed with in its header. A reader at a different
offset reports the pair rather than re-bucketing — re-bucketing would need
the original timestamps a day bucket has already thrown away.

### Decision: there is no lossless statefile v4 → history migration

There cannot be one, and the reason is arithmetic rather than effort. The
history store's records are keyed by bucket × model × project × session at
minute resolution. A v4 statefile persisted only the **marginals** of that
cross-product: `per_day` is six blended scalars per local day, and
`per_model` / `per_project` are all-time cumulative with no time axis at
all. **You cannot factor a product back out of its marginals.** Anything
labelled "migration" would be invented data, in the one store in this app
that is TRUTH rather than cache.

The real history is still on disk — in the agents' own JSONL and SQLite
trees. So the fix is not a migration but **one cold-start catch-up pass
with the history writer attached**, re-reading the transcripts. What is
persisted is therefore a *gate*, not a mirror: `statefile.Backfill`
records that the pass ran. That gate is load-bearing, not bookkeeping —
history records are additive and event dedup belongs to the tailers, which
have no memory of a pass that ignored their offsets, so running the
backfill twice double-counts.

The gate is also falsifiable, via `dict_generation`. A quarantined or
rebuilt `dict.log` mints a fresh generation and abandons every tier file
stamped with the old one; the store is then empty again, and a
`backfilled: true` inherited from the previous generation would be a claim
about files that no longer exist. Comparing generations turns silent
permanent data loss into one more catch-up.

### Decision: additive records, and why compaction may never run

Multiple records sharing a key **sum**. That one rule collapses four
separate problems into the same append:

- a late arrival (a transcript re-scanned hours later) is just a record
  with an old bucket — no read-modify-write;
- a six-month backfill is a stream of appends — no sorting, no merging,
  no boot-time dedup;
- a crash mid-flush leaves a *prefix* of a batch, and a prefix of an
  additive set is a smaller answer, never a wrong one;
- a partial flush and a full flush are the same operation.

The cost is duplicate keys, which is a **size** problem, not a correctness
one. Compaction is therefore purely a space optimization that runs at most
once per launch and could be skipped forever without any reader ever
seeing a different number.

Two supporting rules, both about preferring an unnameable answer to a
confidently wrong one: a dictionary entry is fsync'd *before* any record
referencing its id (a crash in the gap yields `?id:<n>`, never a
misattribution from id reuse); and structurally broken files are
**quarantined** to `<name>.bad.<ms>`, never deleted, because the statefile
is a cache and this is not.

Finally, `Writer.record` returns `void` and never propagates an error.
Telemetry recording must not be able to break token collection: any I/O
failure logs once, disables the writer for the session, and the app runs
exactly as it did before this module existed.

### Left for later

- The `--json` `history.records` / `bytes` are PHYSICAL store size, not an
  event count. Anyone reading them as "how many events do I have" will be
  wrong; documented in docs/CLI.md, not yet defended in the schema.
- Hour-tier `first_seen_ms` / `last_seen_ms` are bucket starts at hour
  resolution. Event-resolution first/last would need a dimension the
  durable record deliberately does not keep.
- No config key gates the history store. It is unconditional and disclosed
  in the README; a `history = false` escape hatch has not been asked for.

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
- **v2**: provider/gateway reconciliation adapters, isolated subprocess source
  plugins, themes, and maybe a WidgetKit companion (requires a small Swift
  extension — separate decision).

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
