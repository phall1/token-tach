# Allowance-first implementation

## Context

See [PRODUCT.md](PRODUCT.md). Baseline: Token Tach `1a7b815`.
`src/view.zig` is a 640 x 500 absolute instrument canvas; `main.zig` wires
its chrome and animations. `engine.zig` owns collection and SDK effects.
`core/history.zig` already stores day x harness x model x project x session.
The ledger's per-day map lacks the harness/model cross-product and its hourly
map is cold after warm restore, so neither can honestly supply this popover.

The main checkout has an unrelated SDK change. Implementation uses the separate
`feat/allowance-first` worktree, initially baselined with SDK `bb165dc`.

### Native upgrade (added by user during implementation)

Upgrade the vendored fork to upstream **v0.10.1**, the latest stable release
reported by GitHub on 2026-09-12. Preserve Token Tach's popover hosting,
menu-bar-only accessory mode and launch-at-login behavior on the new tray APIs.
Keep compatibility work in the owned Native fork; validate its affected gates,
rebuild the vendored CLI, then rerun the app's complete checks and runtime smoke.
The prior v0.8.3 baseline remains comparison evidence, not the final SDK target.
Final fork pin: `2858f1f0d7a80e4eb4c93f98fc25b718e6e82b68`.

## Proposed changes

- `core/usage_summary.zig`: bounded, owned seven-day summaries per harness,
  loaded from the existing archive. Uses the archive timezone, groups daily
  tokens and top models on the same interval. No persistence format change.
  Summary reads occur in the collection/effects path, never in a view. Cache
  them for 30 seconds and refresh on explicit user refresh after collection.
- `presentation.zig`: small UI-free snapshot interface. Inputs are normalized
  limits, summary, enabled sources, loading/error state and session observations.
  Outputs are typed source cards and freshness verdicts. Harness identity stays
  separate from allowance provider and unknown account identity. No inferred
  account billing attribution is written to history.
- `view.zig`: replace the instrument canvas with flow-layout source overview,
  source chooser, exact daily totals and sessions drill-down. A fixed 400 x 600 popover has
  anchored header/footer frames and a flow-layout scrollable body. Paint the
  scrolling body after navigation so its clip stays independent. Render only the presentation
  snapshot; one small engine adapter assembles it at the app seam.

The chart uses floating-point geometry, while exact `u64` daily totals are a
button drill-down and model rows print exact integers. Cached chart labels are
anchored to the summary day rather than assuming its last bucket is today.
Sessions enumerate all retained rows of enabled harnesses, sorted by inferred
activity and recency. A failed flush preserves the prior summary and its age.
- Engine: retain accounting, collectors and history. Add summary caching and
  presentation messages; stop scheduling ignition. Normalize allowance freshness
  once for both tray and popover. Preserve custom tray tokens, adding `{status}`
  as the default. Keep the existing HUD instrument state it still consumes.
- Tests for the removed dial/chrome are retired with that implementation.
  Accounting, collectors, dashboard, HUD and CLI tests remain. New tests exercise
  the snapshot and actual view interaction seam.

## Testing and validation

- PRODUCT 1, 5, 6, 12: deterministic freshness and default-glance tests for fresh,
  stale, future-dated, expired-reset, disabled and unavailable allowances.
- PRODUCT 3, 4: stable source selection and unknown account/billing tests;
  multi-provider usage never acquires a subscription by model name.
- PRODUCT 8, 9, 13: real temporary archive round trips, warm reopen, day/model
  totals and timezone disclosure; existing history/collector/CLI suite.
- PRODUCT 2, 3, 10, 11: build/layout the actual canvas tree, route button messages,
  verify source selection, Back, History, Sessions and bounded node budgets.
- Run `scripts/verify` against the pinned SDK, including app build and live
  automation. Capture populated, empty and drill-down screenshots and inspect
  them. Smoke checks target the new hierarchy, not retired instrument furniture.
- Measure touched branching functions before/after with explicit Zig token-count
  convention (no repository-native complexity tool); review new functions and
  split hotspots. Obtain independent read-only review and fix material findings.
