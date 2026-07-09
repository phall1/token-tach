# token-tach

A macOS menu-bar tachometer for AI coding-agent token usage and subscription
limits. LiteLLM-dashboard truth without the proxy: everything is read from
the session ledgers your agents already write, plus each vendor's own limit
data.

```
⚡ 214k/m → wall 3:40p          ← the menu bar, all day
```

Click it:

```
claude  172M tok · $202.80 · 5h 34% · wk 12% · max
codex   188M tok · $154.16 · 5h 3%  · wk 8%  · pro
today   $114.85 · 116M tok
```

<!-- screenshot: docs/assets/popover.png (tach cluster) -->

## What it shows

- **Burn rate** — limit-weighted tokens/minute (cache reads at 0.1×),
  decayed over a 15-minute window. The needle.
- **Predicted wall** — "at this pace you hit a limit at 3:40 PM", projected
  from the *slope of the vendors' own utilization numbers*, not guessed
  token capacities.
- **Window utilization** — Claude 5-hour / weekly (server truth) and Codex
  5-hour / weekly (embedded in its logs), with reset countdowns.
- **Today's spend** — API-equivalent dollars for what your subscription
  absorbed, priced against LiteLLM's model-price database.

## Where the data comes from (the trust story)

**Local files, read-only, by default:**

| Source | What | How |
|---|---|---|
| Claude Code | tokens per message | tails `~/.claude/projects/**/*.jsonl` (and `$CLAUDE_CONFIG_DIR`), dedupes on `message.id:requestId` |
| Codex CLI | tokens **and** 5h/weekly limit % | tails `~/.codex/sessions/**` — Codex embeds `rate_limits` in its own logs, so no network is involved |
| Pricing | $/token rates | bundled snapshot of LiteLLM's `model_prices_and_context_window.json` |

**Opt-in (`claude-oauth = true` in the config):** Claude's *server-truth*
window utilization comes from the same endpoint Claude Code's `/usage` uses:
`GET https://api.anthropic.com/api/oauth/usage` with your existing Claude
Code OAuth token (read from the macOS Keychain item
`Claude Code-credentials` via Apple's `security` tool — macOS will ask for
consent). Polled every 180 s, exponential backoff on 429, nothing else is
sent — the request carries only your token and standard headers. Off by
default; the app never writes to the Keychain and never talks to any other
host.

## Install

```sh
git clone --recurse-submodules https://github.com/phall1/token-tach
cd token-tach
scripts/setup        # hooks, submodules, toolchain check (zig ≥ 0.16, native CLI)
native build && ./zig-out/bin/token-tach
```

Package a .app / DMG: `scripts/release` (adhoc) or
`scripts/release --identity "Developer ID Application: …" --notarize`.

## Configure

`~/.config/token-tach/config` — plain `key = value`, ghostty-style, every
default overridable:

```ini
# the menu-bar template: {burn} {eta} {pct} {tok} {cost}
tray-format = {burn} → {eta}

claude-oauth = true        # opt in to server-truth Claude limits
poll-interval = 180s
alert-threshold = 70, 90
source = claude, codex     # enable/disable agents
# claude-config-dir = ~/some/other/claude-root
# codex-home = ~/.codex
```

## Development

```sh
scripts/verify   # check + test + build + headless smoke drive
native dev       # run with hot-reloading .native markup
```

See `docs/DEVELOPMENT.md` for the full loop, the SDK's built-in agent docs
(`native skills get core`), and the vendored-fork rebase procedure.

## Architecture

Built on the [Native SDK](https://github.com/vercel-labs/native) (Zig,
compiled declarative markup, own Metal renderer — no Electron, no webview;
the binary is a few MB). The repo vendors a fork at `vendor/native` carrying
small AppKit-host patches (tray popover, dock-less mode, launch-at-login)
that are being upstreamed.

```
src/core/       UI-free engine: tailers, pricing, ledger, prediction, oauth
src/engine.zig  the TEA loop: timers → sweep → ledger/burn/walls → display
src/main.zig    shell: window scene, status item, runtime entry
```

Everything in `src/core` is fixture-tested and also powers the planned
`token-tach --json` CLI.

## Status

Early but real: the tray glance, both tailers, pricing, prediction, and
server-truth limits are live. Popover instrument cluster, notifications,
history dashboard, and the CLI are in flight — see the issue tracker
(this repo uses [beads](https://github.com/steveyegge/beads): `bd list`).

## License

MIT. Not affiliated with Anthropic, OpenAI, or Vercel.
