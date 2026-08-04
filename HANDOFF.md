# HANDOFF — continuation playbook

## 2026-08-04 addendum (read first — it corrects the ones below)

- **CI is green and required.** The account-wide Actions billing lock
  recorded in the 2026-07-25 addendum is over; `CI` runs on `macos-15`
  on every push and PR, and `Release Please` runs on `ubuntu-latest`.
  Check with `gh run list --limit 5` before believing any claim about
  CI being down.
- **Nobody hand-tags any more.** Release Please owns all four version
  mirrors — `version.txt`, `.release-please-manifest.json`, and the
  `x-release-please-start-version` lines in `app.zon` and
  `build.zig.zon`. Creating a `vX.Y.Z` tag by hand desyncs them and
  produces a tag the release workflow did not author. The current
  instruction is **docs/DIRECT_RELEASES.md**; cardinal rule 5 below is
  superseded and marked as such.
- **Vendored SDK is upstream v0.8.0.** `vendor/native` tracks
  `phall1/native@token-tach-patches-v0.8.0` and carries four patches on
  top of upstream `v0.8.0`: status-item NSPopover hosting, `app.zon`
  `.macos.accessory` (LSUIElement), launch-at-login via `SMAppService`,
  and render animations anchored to the presenting frame.
- **Wave 2 landed**: the durable history store
  (`src/core/history.zig`), the live session roster
  (`src/core/sessions.zig`), per-agent burn (`predict.AgentBurn`),
  30 minutes of system telemetry history (`engine.SystemHistory`), the
  trip odometer, and six CLI query verbs. Statefile is at v5.

## 2026-07-25 addendum

- **v0.6.0 shipped** (collector fleet: 11 zero-config sources). Canonical
  architecture: per-source modules on tailsource/snapsource generic
  engines + fleet.zig aggregator. A parallel session's single-module
  harness.zig implementation was superseded in merge a590907 (reachable
  at e16dd6d; its contested extra formats are tracked in the
  "Reconcile contested harness formats" bead).
- **Coordination rule after that collision**: check `bd list` for
  in_progress issues AND `git fetch && git log origin/main` before
  starting work on an open bead — another session may be mid-flight.
  Claim beads with `bd update <id> --status in_progress` first.
- v0.6.0 was released by hand (`scripts/release --universal` →
  `gh release create` → direct tap cask commit) during an Actions
  billing lock. That lock is over and that path is no longer the
  release flow — see the 2026-08-04 addendum.

---

# Original playbook (written 2026-07-09 ~14:00 UTC)

Audience: a fresh agent (Codex or Claude) picking up token-tach mid-wave.
The prior orchestrator (Claude, 5h window ~93%) may vanish without warning.

## Mission state

v0.2.0 is released (tag + GitHub release). Everything on `main` is green:
`scripts/verify` = check + test + build + headless popover smoke. The
current wave ("amaze the user": dashboard, notifications, CLI, icon) is
IN FLIGHT via subagents that edit this working tree directly or deliver
patches as reports.

## Cardinal rules (non-negotiable)

1. **NEVER open PRs or push to any repo not owned by phall1.** Fork pushes
   to github.com/phall1/* are fine. No upstream PRs to vercel-labs/native
   — a prior PR was withdrawn on explicit user instruction.
2. Use the FORK CLI for everything: `vendor/native/zig-out/bin/native`
   (stock npm CLI cannot parse app.zon's `.macos`). Rebuild it after any
   vendor bump: `cd vendor/native && zig build cli`.
3. `scripts/verify` must be ALL GREEN before every commit. Run
   `pkill -f zig-out/bin/token-tach` before manual launches (stale
   instances hijack the automation socket).
4. Commit style: conventional, `Co-Authored-By:` trailer per repo history.
   Push to main is authorized. Beads (`bd`) is the issue tracker — close
   issues with `--reason`, file follow-ups.
5. ~~The release flow: bump app.zon version → `scripts/release` → ...~~
   **SUPERSEDED.** Release Please owns every version mirror and creates
   the tag; the `Release` workflow owns the GitHub Release and its
   artifacts. Do not bump a version by hand and do not create a `v*`
   tag. Read **docs/DIRECT_RELEASES.md** — that is the current flow.
   `scripts/release --universal` remains useful as a *local* build
   equivalent, but it does not publish anything.

## In-flight subagents (their deliverables)

Reports get saved to docs/handoff/<name>.md by the orchestrator as they
land. If a report file is missing, the agent's full transcript JSONL is at
/private/tmp/claude-501/-Users-phall-workspace-token-tach/0d61d1b2-2eec-415f-8144-d65e7645cc48/tasks/<id>.output
— the final assistant message (its report) is recoverable from the tail.

1. **dashboard** — second window (~920×640): month hero stats +
   subscription-value multiple, 30-day bars, per-model/per-project tables.
   EDITS THE TREE DIRECTLY (src/dashboard.zig, engine.zig, main.zig,
   app.zon, tests). When landed: run scripts/verify, screenshot the
   dashboard (`native automate native-command tach.dashboard`), judge, commit.
2. **alerts** — src/core/alerts.zig ONLY (pure hysteresis alert engine) +
   report contains an EXACT engine.zig integration patch (notification
   dispatch on threshold/wall/reset) + app.zon needs 'notifications'
   permission/capability. Apply patch AFTER dashboard lands (same files).
3. **cli** — src/cli.zig ONLY (--json / --statusline from persisted state,
   local-only) + report contains a small main.zig hook patch + docs/CLI.md.
   Apply after dashboard.
4. **icon** — replaces assets/icon.png (1024px tach glyph) via a scratch
   SDK app. Tree-direct, self-contained. Commit when landed.

Integration order: dashboard commit → apply alerts patch + verify →
apply cli patch + verify → icon → README updates (dashboard screenshot,
CLI section, alerts mention) → bump 0.3.0 → release per flow above.

## Also queued (beads)

- tt-rex: launch-at-login config key → Runtime.setLaunchAtLogin (packaged only)
- tt-s9n: respect poll-interval config in oauth gate; hint clipping
- tt-nzj: hero ignition GIF — script ready at
  <scratchpad>/capture-ignition-gif.sh (session scratchpad above); needs the
  automation socket free (no other manual app instances). ffmpeg installed.

## Sentinel protocol (Codex-in-tmux)

- /tmp/tach-handoff/DONE exists → orchestrator finished; do nothing, exit.
- /tmp/tach-handoff/GO exists → take over NOW per this file.
- Neither after your patience window → assume the orchestrator hit its
  limit mid-wave; take over.

When taking over: `git status` first — uncommitted tree changes are agent
work in progress. If an agent is still mid-edit (files changing between
looks), wait for quiescence (~10 min stable) before integrating.
