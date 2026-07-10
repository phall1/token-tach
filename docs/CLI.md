# token-tach CLI

`token-tach --json` and `token-tach --statusline` read the same local state
as the menu-bar app, print once, and exit without launching the GUI.

The CLI is local-only: it reads config, the persisted state file, and any
newly appended Claude/Codex JSONL bytes. It does not poll the network, write
state, or touch the Keychain.

```sh
token-tach --json
token-tach --statusline
token-tach --version
token-tach --help
```

## Statusline

Claude Code statusline example:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/Token Tach.app/Contents/MacOS/token-tach --statusline"
  }
}
```

Example output:

```text
⚡ tach · today $114.23 · cdx 5h 14% wk 4%
```

## JSON Schema

The top-level schema is stable for v0.3.x. New fields may be added.

```json
{
  "version": "0.3.0",
  "generated_at_ms": 1783483200000,
  "tz_offset_min": -300,
  "note": null,
  "today": {
    "cost_usd": 114.23,
    "tokens": 123456,
    "input": 1,
    "output": 2,
    "cache_creation": 3,
    "cache_read": 4,
    "events": 5
  },
  "month": {},
  "all_time": {
    "cost_usd": 231.88,
    "tokens": 203000000,
    "events": 1234,
    "by_agent": {
      "claude": {},
      "codex": {}
    }
  },
  "burn_tokens_per_min": null,
  "limits": {
    "codex": {
      "plan": "pro",
      "read_at_ms": 1783483200000,
      "windows": [
        { "kind": "five_hour", "used_percent": 14.0, "resets_at_ms": 1783490000000 }
      ]
    },
    "claude": null,
    "claude_hint": "claude plan limits are OAuth server truth — run the app (claude-oauth = true) to see them"
  },
  "models": [],
  "projects": []
}
```

`burn_tokens_per_min` is always `null` in v0.3 CLI mode. The persisted
ledger stores rollups, not enough recent per-event history for an honest
one-shot burn rate.
