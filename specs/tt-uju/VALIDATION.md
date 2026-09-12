# Validation evidence

## Baseline

- Worktree: `feat/allowance-first`, baseline `1a7b815`.
- Pinned Native SDK `bb165dc`: baseline `scripts/verify --no-smoke` passed
  404 tests with one skipped, model contract, manifest check and ReleaseFast build.
- The original checkout's unrelated SDK change (`a1bf628`) failed baseline
  compilation on missing HUD window fields. It was preserved; validation uses
  the pinned SDK in the separate worktree.

## Complexity

No project-native Zig complexity tool is configured. Used a lexical proxy:
`1 + if + for + while + catch + and + or + non-default switch arms`.
Comments, strings and character literals are excluded; grouped switch arms
count once. Baseline was read with `git show 1a7b815:<path>`, independently
measured, with manual cross-checks of the major dispatchers.

| Function | Before | After |
|---|---:|---:|
| engine.update | 29 | 10 |
| engine.applyUxMsg | 16 | 10 |
| engine.computeGlanceState | 10 | 5 |
| trayfmt.writeToken | 25 | 8 |
| dashboard.sessionRows | 11 | 7 |
| engine.boot | 2 | 2 |
| engine.maybeOauthPoll | 4 | 5 |
| engine.handleCreds | 7 | 7 |
| engine.handleOauthResponse | 4 | 4 |

New view functions peak at 6; presentation functions peak at 7; summary
functions peak at 4. New engine helpers remain at or below 10. Old view
hotspots (animations 24, agentColumn/focusBlock/systemHoverDetail 20) were
retired with the instrument canvas. Existing unrelated engine hotspots were
not rewritten. Custom tray tokens retain their existing tests.

## Independent review

Fresh-context read-only review found and verified fixes for:

1. Disabled harness sessions and completed retained sessions: now filtered and
   sorted in the presentation layer, with regression coverage.
2. Failed archive flush presenting fresh old data: writer health is rechecked
   after flush; cached summary and timestamp survive failure.
3. Archive-only usage hidden after statefile loss: archive events qualify a source.
4. Rounded model/day counts: models show integers; daily drill-down exposes `u64`.
5. Yesterday labeled Today after failed refresh and hidden timezone warnings:
   labels compare actual day keys; timezone and failure messages are composed.
6. Dashboard regression coverage: restored alongside the HUD gauge regression.
7. Permanent writer failure promising automatic retry: now distinguishes an
   unavailable collector (restart to retry) from a retryable archive read.

The initial critic agent could not start because its OAuth token was revoked;
an independent general reviewer completed the review and follow-up instead.

## Acceptance checks

Tests exercise freshness, expired resets, disabled allowance sources, account
non-attribution, stable source selection, real archived day/model rollups after
warm reopen, archive-only usage, unavailable history, exact integers beyond
`f32` precision, source filtering, retained sessions, timezone disclosure,
button routing, and layout/display-list budgets for all pages with 32 sessions.
Existing history, collector, dashboard, HUD and CLI suites remain enabled.

The smoke harness waits for the launched process's publisher PID before issuing
commands, preventing stale automation files from swallowing the opening toggle.
`TACH_SMOKE_HOME` supports an isolated synthetic home during runtime validation.

Visual inspection caught an SDK styling mismatch: progress bars consume the
`accent` style field, not `foreground`. The allowance meter now supplies accent
explicitly so stale bars are muted and fresh warning thresholds use their ink.

## Upgraded app and visual checks

Native v0.10.1 passes the app's manifest check, model contract, 396 tests
(one additional test skipped), ReleaseFast build and tray/navigation/history
smoke drive. The login-item API now returns a status; the app logs that status
instead of treating every accepted request as enabled.

The navigation/footer and scrolling body use separate anchored frames. The
scrolling body paints last. With this layout, source switching and scrolling
to the last retained session preserve the footer in live screenshots; an
earlier sibling-after-scroll arrangement lost footer pixels despite correct
accessibility frames. A proposed forced-repaint adapter did not solve it and
was removed. No SDK canvas workaround is included.

Runtime validation used isolated synthetic homes, covering populated and empty
data, source switching, exact daily totals, stale limits with muted bars,
sessions through the final row, Back via keyboard Enter, History, and desktop
HUD creation. Checked-in visual artifacts:

- [Overview](../../docs/assets/popover.png)
- [Source chooser](../../docs/assets/allowance/sources.png)
- [Local-only usage](../../docs/assets/allowance/local-only.png)
- [Exact daily totals](../../docs/assets/allowance/daily.png)
- [Sessions](../../docs/assets/allowance/sessions.png)
- [Last retained session](../../docs/assets/allowance/sessions-bottom.png)
- [Empty state](../../docs/assets/allowance/empty.png)

## Native v0.10.1 fork review

Final SDK pin: `2858f1f0d7a80e4eb4c93f98fc25b718e6e82b68`.
Independent review accepted fixes for shell updates stealing popover clicks,
dynamic native/WebView mounts attaching to the temporary backing container,
and secondary clicks incorrectly executing activation hooks. An executable
AppKit harness covers shell updates, six click/modifier combinations, and
native/WebView mounting through content borrow/return. Full SDK Zig tests,
CLI build, manifest validation, examples, and devhost journal replay identity
checks passed. The fork retains upstream event tags and updates the devhost
fingerprint for the new popover event.

App review and spec comparison found no remaining material mismatches. A
reviewer's initial screenshot discrepancy was retracted after decoding the
actual image bytes: empty, daily and local-only footer crops were identical
and contained all navigation buttons. Visual checks were local, with isolated
synthetic data; no cloud computer-use validation was run.

SDK gate limitations: Android requires an unavailable NDK; CEF linking requires
an absent runtime layout. Generic render timing budgets were not consistently
green on this busy host (unrelated Rust/Zig compiler load was observed). Pure
upstream v0.10.1 also exceeded keystroke and toggle thresholds. These timing
results are recorded as inconclusive, not a passing full cross-platform gate;
the app's deterministic layout/display-command budgets remain enforced.
