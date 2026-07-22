# token-tach CLI

`token-tach --json` and `token-tach --statusline` read the same local state
as the menu-bar app, print once, and exit without launching the GUI.

The CLI is local-only: it reads config, the persisted state file, and any
newly appended Claude/Codex JSONL bytes, and one OpenCode SQLite database via
a read-only connection. It does not poll the network, write state, or touch
the Keychain. OpenCode prompt/content/tool/auth fields are never queried.

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
  "version": "0.3.2",
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
      "codex": {},
      "opencode": {}
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
  "projects": [],
  "system": {
    "cpu": { "utilization": 0.43, "cores": 14, "load_avg_1m": 3.25 },
    "gpu": { "utilization": 0.12 },
    "mem": { "used_bytes": 40700000000, "total_bytes": 51500000000, "used_fraction": 0.79, "pressure": "normal" },
    "disk": { "total_bytes": 994000000000, "free_bytes": 186000000000, "used_fraction": 0.81, "read_bytes_per_sec": 120000, "write_bytes_per_sec": 8000 },
    "net": { "rx_bytes_per_sec": 1230000, "tx_bytes_per_sec": 88000 },
    "battery": null
  }
}
```

`system` (v0.5+) is live machine telemetry sampled at invocation over a
~150 ms window — mach/sysctl/IOKit reads, no subprocesses, no root. A
`null` module means the hardware or counter is unavailable on this
machine (for example `battery: null` on a desktop). Fractions are 0..1;
`mem.pressure` is the kernel's memorystatus level
(`normal`/`warn`/`critical`/`unknown`). `--statusline` performs no system
sampling.

`burn_tokens_per_min` is always `null` in v0.3 CLI mode. The persisted
ledger stores rollups, not enough recent per-event history for an honest
one-shot burn rate.

OpenCode database resolution uses the first non-empty value only:
`opencode-db` in config, `OPENCODE_DB`,
`$XDG_DATA_HOME/opencode/opencode.db`, then
`~/.local/share/opencode/opencode.db`. This intentionally supports one
database, preventing the same local usage from being counted through multiple
discovery channels.
