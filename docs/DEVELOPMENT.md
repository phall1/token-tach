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
this repo; `build.zig.zon` points `.native_sdk` at `vendor/native`.

Why: we carry patches to the macOS host (`src/platform/macos/appkit_host.m`)
for NSPopover-under-status-item, LSUIElement, and SMAppService — upstream
PRs pending.

The `native` CLI itself (check/test/build/automate verbs) still comes from
the vendored fork (`cd vendor/native && zig build cli` -> vendor/native/zig-out/bin/native); scripts/setup builds it. The stock npm CLI cannot parse app.zon's `.macos` key.

### Rebasing onto a new SDK release

```sh
cd vendor/native
git fetch https://github.com/vercel-labs/native main
git rebase FETCH_HEAD          # replay our patches
cd ../.. && scripts/verify     # prove the world still stands
(cd vendor/native && zig build cli)   # rebuild the fork CLI
git add vendor/native && git commit
```

Patches are kept small and mechanical; if a rebase fights back, check
whether the upstream API for trays/windows changed and fix forward.

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
