# Development

## First run

```sh
scripts/setup   # git hooks + submodules + toolchain check (idempotent)
```

Run this once after cloning (and any time after pulling if hooks change).
It points `core.hooksPath` at the tracked `.githooks/`, initializes
`vendor/native`, and verifies zig >= 0.16 and the `native` CLI are installed.

## The loop

```sh
scripts/verify            # check + test + build + headless smoke drive
scripts/verify --no-smoke # CI-safe subset (no GUI launch)
native test               # just the tests — the fast inner gate
native dev                # run with hot-reloading .native markup
```

`scripts/verify` is the definition of done for any change: it validates
markup/manifest (`native check`), runs unit + model-contract tests
(`native test`), builds an automation-enabled binary, then launches the app
headlessly, snapshots the accessibility tree, clicks a widget, asserts the
state change, and screenshots the canvas.

Driving a running app by hand:

```sh
native build -Dautomation=true && ./zig-out/bin/token-tach &
native automate snapshot          # a11y tree with widget ids
native automate widget-click main-canvas <id>
native automate screenshot main-canvas
```

## SDK docs

The SDK ships its own agent-oriented docs. Read before touching markup or
runtime wiring:

```sh
native skills get core --full      # project anatomy, runtime, packaging
native skills get native-ui --full # .native markup grammar, Model/Msg/update
native skills get automation       # driving a running app
```

## Vendored SDK (vendor/native)

The app builds against a **vendored fork** of the Native SDK
(`vendor/native`, submodule → github.com/phall1/native), not the npm CLI's
copy. `build.zig`/`build.zig.zon` are ejected (`native eject`) and owned by
this repo; `build.zig.zon` points `.native_sdk` at `vendor/native`. App release
versions belong in `app.zon`. Zig 0.16 requires `build.zig.zon` to repeat its
package version, so `scripts/version check` fails unless that compatibility
field mirrors the manifest. The build imports the manifest version directly
for CLI, JSON, and menu consumers, while Native SDK packaging uses it for
bundle metadata and artifact names.

Currently pinned to **upstream v0.8.0**, on the fork branch
`phall1/native@token-tach-patches-v0.8.0`. Four patches ride on top:

1. **status-item NSPopover hosting** — an `NSPopover` anchored to the tray
   item, reparenting the app's Metal surface in and out of an
   `NSViewController` (`src/platform/macos/appkit_host.m`).
2. **`app.zon` `.macos.accessory`** — emits `LSUIElement` so the app is
   menu-bar-only with no Dock icon.
3. **launch-at-login** — a runtime API over `SMAppService` (macOS 13+).
4. **render animations anchored to the presenting frame**, not the
   declarer's stale clock — without it the ignition sweep replays from
   whatever time the declaring frame happened to carry.

These stay on the fork. Do not open upstream PRs to vercel-labs/native;
a prior one was withdrawn on explicit instruction. "Patches available on
request" is the correct posture.

The `native` CLI itself (check/test/build/automate verbs) still comes from
the vendored fork (`cd vendor/native && zig build cli` -> vendor/native/zig-out/bin/native); scripts/setup builds it. The stock npm CLI cannot parse app.zon's `.macos` key.

### Rebasing onto a new SDK release

The fork branch carries the upstream version it was rebased onto, so the
branch that produced any given release is still reachable after the next
bump:

```sh
cd vendor/native
git fetch upstream                       # https://github.com/vercel-labs/native
git switch -c token-tach-patches-vX.Y.Z token-tach-patches-<previous>
git rebase vX.Y.Z                        # replay our four patches onto the tag
git push origin token-tach-patches-vX.Y.Z
cd ../.. && scripts/verify               # prove the world still stands
(cd vendor/native && zig build cli)      # rebuild the fork CLI — required
git add vendor/native && git commit
```

`git -C vendor/native describe --tags` names the upstream tag plus the
patch count (`v0.8.0-4-g<sha>`), which is the fastest way to confirm what
the submodule is actually pinned to.

Patches are kept small and mechanical; if a rebase fights back, check
whether the upstream API for trays/windows changed and fix forward.
Rebuilding the fork CLI is not optional: the stock npm CLI cannot parse
`app.zon`'s `.macos` key, and a stale fork CLI will `check` against the
wrong SDK.

## Hygiene

Git hooks live in the tracked `.githooks/` directory (activated by
`scripts/setup` via `core.hooksPath`). Both hooks chain through to the
beads-managed hooks in `.beads/hooks/` first, so issue-tracker bookkeeping
keeps working.

**pre-commit** (fast, <2s, staged files only):

- `zig fmt --check` on staged `.zig`/`.zon` files (vendor/ excluded)
- `native check` — markup + manifest validation, catches broken `app.zon`
- blocks merge-conflict markers in staged content
- blocks any staged file over 500KB — large blobs don't belong in history
- warns (but allows) newly added `TODO`/`FIXME` lines

**pre-push**: runs `scripts/verify --no-smoke` — full build + tests, no GUI
windows. If it fails, the push is blocked; don't push a broken build.

**Bypassing in an emergency**: `git commit --no-verify` / `git push
--no-verify` skip the hooks. Reserve this for genuine emergencies (hotfixing
a broken hook itself, a WIP branch nobody builds from). Every bypass ships
work the hooks would have caught to CI — or to a teammate's clone — where it
costs 100x more to notice. CI runs the same `zig fmt --check` and
`scripts/verify`, so a bypassed failure will still bounce, just slower.

Editor settings are kept honest by `.editorconfig` (4-space Zig, 2-space
YAML/JSON/Markdown, LF, final newline) and `.gitattributes` (LF
normalization).

## Local state a dev run touches

Running the app (not the tests) writes two things under
`$XDG_STATE_HOME/token-tach/` — `~/.local/state/token-tach/` when the
variable is unset:

- `tailers.json` — the state file (tailer offsets + ledger rollups). A
  **cache**: deleting it costs one full re-parse and nothing else. Its
  `format_version` is bumped on every wire change and `restore` demands an
  exact match, so an older file is declined and the boot path re-derives
  everything. That is the entire upgrade mechanism; there is no migration
  code.
- `history/` — the durable time series (`.lock`, `dict.log`, `hot.ring`,
  `hours.log`, `days.log`). **Not** a cache: the source transcripts get
  rotated and deleted out from under us, so this is the only copy. Do not
  delete it to "reset" something. A single writer holds `.lock` via
  `flock`; a second instance logs once and runs inert rather than
  corrupting anything.

Both are 0600 under a 0700 directory. To sandbox a run entirely, point
`XDG_STATE_HOME` (and `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / …) at a scratch
tree — that is also how `token-tach --bench` is aimed at a fixture corpus.

Tests never touch either: every history test builds its own `TmpDir`.

## Releasing

Read **docs/DIRECT_RELEASES.md**. The short version: Release Please owns
`version.txt`, `.release-please-manifest.json`, and the
`x-release-please-start-version` lines in `app.zon` and `build.zig.zon`,
and creates the `vX.Y.Z` tag; the `Release` workflow owns the GitHub
Release and its artifacts. Do not bump a version by hand and do not create
a `v*` tag — doing either desyncs the four mirrors and produces a tag the
publisher did not author. `scripts/release --universal` is the local build
equivalent and publishes nothing.
