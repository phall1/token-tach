# Development

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
npm `@native-sdk/cli`; keep its version aligned with the vendored commit.

### Rebasing onto a new SDK release

```sh
cd vendor/native
git fetch https://github.com/vercel-labs/native main
git rebase FETCH_HEAD          # replay our patches
cd ../.. && scripts/verify     # prove the world still stands
npm i -g @native-sdk/cli@<matching version>
git add vendor/native && git commit
```

Patches are kept small and mechanical; if a rebase fights back, check
whether the upstream API for trays/windows changed and fix forward.
