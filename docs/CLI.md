# token-tach CLI

The same binary that runs the menu-bar app answers questions on stdout and
exits without opening a window. There are two families:

- **Snapshot modes** (`--json`, `--statusline`, `--bench`) — read config,
  the persisted state file, and any newly appended transcript bytes, then
  print one answer about *now*.
- **Query verbs** (`history`, `burn`, `top`, `sessions`, `export`,
  `doctor`) — read the durable time-series store at
  `$XDG_STATE_HOME/token-tach/history/` and answer questions about the
  past.

Everything here is read-only. Nothing polls the network, writes state, or
touches the Keychain. The query verbs open the history store as a
**reader**: they never take the write lock and never compact, so running
one while the app is collecting cannot stall it. OpenCode
prompt/content/tool/auth fields are never queried.

```sh
token-tach                # launch the menu-bar app (default)
token-tach --json         # usage/limits snapshot as JSON
token-tach --statusline   # one line, statusline-ready
token-tach --bench        # time one collection pass, print JSON
token-tach --version      # -v
token-tach --help         # -h
```

Precedence rule: `argv[1]` decides. A bare word matching a verb runs that
verb; anything starting with `-` is a flag and is never treated as a verb;
anything else falls through and launches the GUI. That is what keeps the
SDK runner's own argv intact.

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

`--statusline` deliberately skips both the system sampler and the durable
store: it renders neither, and it is invoked once per prompt render.

## Query verbs

All six read the same store and share one option parser — an option a verb
has no use for is accepted and ignored rather than rejected, so
`--format json` works uniformly.

| Verb | Answers | Default bucket | Default format |
|---|---|---|---|
| `history` | usage over time | `day` | `table` |
| `burn` | tokens/min at an instant | `minute` (fixed) | `table` |
| `top` | biggest N along one dimension | `day` | `table` |
| `sessions` | recent sessions and their spans | `day` | `table` |
| `export` | the archival CSV | `hour` | `csv` |
| `doctor` | store health | — | `table` |

```sh
token-tach history  [--since 7d|2026-06-01] [--until now] [--bucket minute|hour|day]
                    [--group agent,model,project,session,bucket]
                    [--agent claude,codex] [--project P] [--model M] [--session S]
                    [--format json|csv|tsv|table]
token-tach burn     [--at <iso|epoch-ms>|--now] [--window 15m] [--format table|json]
token-tach top      --dim project|model|session|agent [--since ..] [-n 20]
token-tach sessions [--since 30d] [--project P] [--agent A] [-n 20]
token-tach export   --format csv [--since ..] [--bucket hour]
token-tach doctor   --history [--format table|json]
```

### Options

| Option | Applies to | Meaning |
|---|---|---|
| `--since` / `--until` | history, top, sessions, export | range ends; omitted `--since` reaches back as far as the store goes, omitted `--until` means now |
| `--at` / `--now` | burn | the instant the window ends |
| `--window` | burn | window length, `15m` / `2h` / a bare minute count; rounds up to a whole minute |
| `--bucket` | history, top, sessions, export | `minute`/`min`/`m`, `hour`/`h`, `day`/`d` |
| `--group` | history | comma list of `bucket` (alias `time`), `agent`, `model`, `project`, `session`. Ignored by `export`, whose column set is the contract |
| `--agent` | history, sessions, export | comma list of agent names |
| `--project` / `--model` / `--session` | history (all three), sessions (`--project`) | exact-name filters |
| `--dim` | top | required: `agent`, `model`, `project`, `session` |
| `-n` / `--limit` | top, sessions | row cap (default 20) |
| `--format` | all | `table`, `json`, `csv`, `tsv` |
| `--history` | doctor | the only subject today, and also the default |

Both `--opt value` and `--opt=value` spellings work. A bad option is a
usage error printed to stderr — it never falls through and launches the
GUI, because `argv[1]` already committed to the query path.

### Time arguments

`--since` / `--until` / `--at` accept:

- a relative age: `90m`, `36h`, `7d`, `4w` (a leading `-` is accepted and
  ignored — `--since -7d` and `--since 7d` mean the same thing)
- an ISO-8601 date: `2026-06-01`
- an ISO-8601 timestamp: `2026-06-01T12:00:00Z` (a zoneless
  `2026-06-01T12:00` is read as UTC)
- a bare integer, which is **epoch milliseconds** — seconds would be a
  silent 1000x error, so there is deliberately no heuristic that tries to
  tell them apart
- `now`

A bare date and an instant are handled differently on purpose. `2026-06-01`
names a calendar day, which is only an instant once you pick a zone — so on
the day tier the civil date *is* the bucket key, with no zone round trip.
That is what keeps `--since 2026-06-01 --bucket day` meaning the first of
June rather than the 31st of May shifted by the store's offset.

### Time basis

Minute and hour buckets are **UTC**: a flight to Tokyo must not
retroactively re-key the hour series, and a UTC bucket is the only key that
survives a timezone move. Day buckets are **LOCAL**, keyed at the offset
`days.log` was written with — "what did I spend today" is a local question.
A reader standing at a different offset reports the pair rather than
silently re-bucketing, because re-bucketing would need the original
timestamps a day bucket has already discarded.

Every query states the basis it used. `table` and `json` carry it inline;
`csv` and `tsv` put it on **stderr**, so a redirect yields a clean file:

```text
# token-tach history  bucket=day  basis=local(-04:00)  since=2026-07-28T04:00:00Z  until=2026-08-05T03:59:59Z  buckets=20662..20669
```

### Row output

Every row-shaped verb goes through one emitter, so table, csv, tsv and json
can never disagree about what a column contains. The metric columns are
always, in order:

```
input  output  cache_creation  cache_read  cost_usd  events  covered
```

preceded by whichever dimension columns the grouping selected
(`bucket_ms`, `agent`, `model`, `project`, `session`, and for `sessions`
also `first_ms`/`last_ms`), and followed by `synthetic` when the agent
column is present. `covered` is the subscription-covered share of
`cost_usd`; `synthetic` marks rows this app synthesized rather than
observed.

`--format json` adds `tokens` (the sum of the four token columns) and
`records` (physical store rows behind the aggregate) to each row, and wraps
them in a `query` object carrying `bucket`, `time_basis`, `tz_offset_min`,
`since_ms`, `until_ms`, `from_bucket`, `to_bucket`.

Naming a `--model` / `--project` / `--session` the store has never seen is a
hard stop with an explanatory note, not a filter that matches nothing:
an empty filter would answer a question nobody asked with a full table of
everything.

A `--project` is a **repository root**, not the directory an agent happened
to sit in: worktrees and subdirectories are attributed to the repository
that contains them, so `--project ~/workspace/token-tach` covers every
worktree of it. Records written before v0.9.6 kept the raw working
directory, so a store with history from both eras lists a repo's older
worktree spend under the worktree's own path — ids are never reassigned, so
that history is reported as-is rather than rewritten.

### `export` — the archival seam

`export` has one fixed CSV schema. `--group` is ignored so the file cannot
silently change shape:

```
bucket_ms,agent,model,project,session,input,output,cache_creation,cache_read,cost_usd,events,covered,synthetic
```

`bucket_ms` is an absolute instant, so no zone is needed to read the file
back. Fields are RFC 4180 quoted (a project path routinely contains a
comma); TSV has no quoting mechanism, so it escapes `\\`, `\t`, `\n`, `\r`
C-style instead.

### `burn`

```text
# token-tach burn  bucket=minute  basis=utc  window=15m  ending=2026-08-04T11:20:00Z
tokens_per_min   50713.2
cost_per_min     0.041827
tokens           760698
cost_usd         0.627405
events           412
```

`burn` reads the hot minute ring, which reaches back 48 hours. A `--window`
longer than that under-reports, and the output says so rather than printing
a confident number (`beyond_hot_tier: true` in JSON).

### `doctor --history`

Reports the store directory, that the write lock was not taken, dangling
dictionary ids (a name lost to a crash before the record that references
it; those render `?id:<n>`), and per tier: bytes, physical slots, valid
records, unreadable slots, basis, and first/last bucket with its instant.

The CRC scan is not a separate pass — the extent scan validates every
record it counts, so `valid records` is the number that passed and the
difference from the slot count is the number that did not.

## `--json` schema

The top-level schema is stable: field additions are non-breaking, renames
and removals are breaking and get a version note here.

```json
{
  "version": "0.8.0",
  "generated_at_ms": 1785842524014,
  "tz_offset_min": -240,
  "note": null,
  "today": {
    "cost_usd": 49.047159,
    "tokens": 548262647,
    "input": 8969084,
    "output": 1651127,
    "cache_creation": 6285926,
    "cache_read": 531356510,
    "events": 3718,
    "by_agent": { "claude": {}, "codex": {} }
  },
  "month": { "by_agent": {} },
  "all_time": {
    "cost_usd": 6124.646423,
    "tokens": 10571129573,
    "events": 72399,
    "by_agent": { "claude": {}, "codex": {} }
  },
  "coverage": [
    {
      "agent": "claude",
      "enabled": true,
      "detected": true,
      "events": 41475,
      "first_seen_ms": 1783303200000,
      "last_seen_ms": 1785841200000
    }
  ],
  "burn_tokens_per_min": 50713.2,
  "history": {
    "available": true,
    "hot_minutes": 2819,
    "first_ms": 1783303200000,
    "last_ms": 1785841200000,
    "records": 99065,
    "bytes": 6353952,
    "backfilled": true,
    "burn_window_min": 15,
    "burn_cost_per_min": 0.041827,
    "day_tz_offset_min": -240
  },
  "limits": {
    "codex": {
      "plan": "pro",
      "read_at_ms": 1785841200000,
      "windows": [
        { "kind": "five_hour", "used_percent": 14.0, "resets_at_ms": 1785855600000 }
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

**`today.by_agent` / `month.by_agent`** are the per-agent splits the
ledger's blended per-day rollup cannot produce; they come from the history
store's `days.log`, so they are LOCAL days keyed at
`history.day_tz_offset_min` — the offset the app was running at when it
wrote them, not necessarily the one this process is standing in. They are
`null`, never an all-zero split, when the store was not read: an all-zero
object would read as "no agent spent anything today".

**`burn_tokens_per_min`** is a real number now (it was always `null` before
the durable store existed). It is tokens/min over the last
`history.burn_window_min` minutes of the hot ring. It stays `null` when the
store is unreadable or holds nothing in that window — an honest "no idea",
which is a different claim from zero.

**`history`** describes the store itself. `records` and `bytes` are
**physical**: one event contributes a row to each of three tiers and
additive duplicates are counted individually, so this is store size, never
an event count. `hot_minutes` is distinct minute buckets currently in the
hot ring. `backfilled` is the one-time gate saying the store has been
seeded from the full transcript history.

**`coverage`** reports every known agent: whether its source is enabled in
config, whether its data location exists on this machine (`null` = no
collector probes it yet), how many events it contributed, and the
`first_seen_ms` / `last_seen_ms` span from `hours.log`. Those two are UTC
hour-bucket **start** instants at hour resolution — the durable record
keeps buckets, not timestamps — and are `null` for an agent the store has
never seen.

**`all_time.by_agent`** carries a totals object per agent, keyed by the
agent's identifier (`continue_cli` for Continue).

**`system`** is live machine telemetry sampled at invocation over a ~150 ms
window — mach/sysctl/IOKit reads, no subprocesses, no root. A `null` module
means the hardware or counter is unavailable on this machine (for example
`battery: null` on a desktop). Fractions are 0..1; `mem.pressure` is the
kernel's memorystatus level (`normal`/`warn`/`critical`/`unknown`).

**`models`** and **`projects`** are the top 10 by cost; `limits.codex`
carries at most 4 windows.

## `--bench`

Times one full `collect` pass and prints what it cost. There is no fixture
magic: every source resolves its root from an environment variable, so
pointing the whole pipeline at a fixture tree is just

```sh
CLAUDE_CONFIG_DIR=… CODEX_HOME=… XDG_STATE_HOME=… token-tach --bench
```

`input_files` / `input_bytes` are the transcript corpus the pass had to
consider — the denominator for a bytes/second figure. On a warm run (a
state file present) most of those bytes are never read, which is precisely
the effect worth measuring. The output also carries `state`
(`restored`/`absent`/`invalid`), `events`, `wall_ms` / `wall_ns`,
`peak_rss_bytes`, `history_records`, `history_bytes`.

## Source resolution

OpenCode database resolution uses the first non-empty value only:
`opencode-db` in config, `OPENCODE_DB`, `$XDG_DATA_HOME/opencode/opencode.db`,
then `~/.local/share/opencode/opencode.db`. This intentionally supports one
database, preventing the same local usage from being counted through
multiple discovery channels. The history store resolves to
`$XDG_STATE_HOME/token-tach/history/`, falling back to
`~/.local/state/token-tach/history/`.
