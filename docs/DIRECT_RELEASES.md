# Direct GitHub Releases

The `Release` workflow publishes a validated `vMAJOR.MINOR.PATCH` release target.
It builds the matching merged release PR commit for arm64 and x86_64, creates and
verifies a Universal 2 binary, applies an ad-hoc signature, and publishes the
DMG, `SHA256SUMS`, and GitHub artifact provenance. Homebrew is the canonical
install/update path.

## Repository configuration

No signing or Apple credentials are required for the active ad-hoc release
workflow.
- `HOMEBREW_TAP_TOKEN` (optional): a fine-grained token with Actions dispatch
  access to `phall1/homebrew-tap`; it triggers an immediate cask update.
- Enable **Allow GitHub Actions to create and approve pull requests**. Release
  Please uses the repository `GITHUB_TOKEN`; no long-lived release PAT is needed.
- Keep the `main` ruleset's required GitHub Actions `verify` check active. This
  binds merges to the current PR head; administrators retain emergency bypass.

Enable GitHub artifact attestations for the repository. Provenance is generated
for public repositories, where GitHub's Sigstore-backed attestation service is
available without an Enterprise configuration. For a private repository,
configure GitHub Enterprise artifact attestations before changing the workflow
to remove its public-repository guard.

Protect `v*` tags with a repository ruleset, restrict tag creation to release
maintainers, require the normal CI checks before tag creation, and enable
immutable releases in repository settings when available. Before any repository
code runs, the workflow validates the draft target or lightweight tag against the
unique merged release PR and all version mirrors. It runs the full
`scripts/verify` lane against that commit and never mutates a published Release.

## Publishing

Release Please maintains one **draft** release PR from Conventional Commits.
Draft PRs do not run the macOS CI lane; mark the release PR ready when its notes
and version are ready for review, then merge only after the resulting CI run is
green. If Release Please later updates an already-ready release PR, it explicitly
dispatches CI against the new head so an older green result cannot authorize it.

Merging the release PR atomically updates `version.txt`, `app.zon`,
`build.zig.zon`, `CHANGELOG.md`, and the Release Please manifest. The
`Release Please` workflow then creates a private draft Release targeting that
exact merge commit and
explicitly dispatches the existing `Release` workflow. The explicit dispatch is
required because GitHub suppresses recursive workflows created with
`GITHUB_TOKEN`.

The `Release` workflow remains the sole publisher and artifact owner: it verifies
the draft target against the matching merged release PR, builds and signs that
exact commit, uploads the DMG/checksums/provenance, then publishes the complete
draft. Publication creates the lightweight `vX.Y.Z` tag at the validated commit;
no assetless release is public. Do not manually edit release versions or create
the normal release tag, and do not edit an in-flight draft.

After publication, `Release` dispatches `Release Please` to mark the merged
release PR as `autorelease: tagged`. Release Please then evaluates whether to
open or update the next draft version PR; this explicit continuation replaces
the label transition normally performed while creating a GitHub Release.

For recovery, rerun `Release Please` on `main`; it derives the target directly
from the matching merged release PR, validates every version mirror at that
commit, and redispatches the publisher. `Release` accepts either that private
draft target or an existing tag, and independently requires the exact matching
merged release PR commit. It never builds an arbitrary branch or caller-supplied
SHA. Duplicate publisher runs cheaply stop before allocating a macOS runner once
the release exists.

If artifact upload fails while the Release is still a draft, rerun `Release`; it
clobbers partial draft assets and resumes publication. If a published Release is
somehow incomplete, preflight fails with the exact cleanup command. Delete only
that incomplete Release with `gh release delete vX.Y.Z --yes` (the existing tag
is preserved), then rerun `Release` for the same tag. Complete releases are never
mutated.

After publication, the workflow dispatches `phall1/homebrew-tap` with the
released version and verified DMG checksum when the optional token is present.
The tap also polls the latest release hourly, so updates remain automatic
without a cross-repository credential. It rewrites and commits the cask,
including the quarantine compatibility required by ad-hoc builds.

For a local equivalent, run:

```sh
scripts/release --universal
```

Developer ID signing, notarization, and signed Sparkle updates are deferred in
Bead `tt-ejr`.
