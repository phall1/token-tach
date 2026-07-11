# Direct GitHub Releases

The `Release` workflow publishes an existing `vMAJOR.MINOR.PATCH` tag. It builds
the tag's exact commit for arm64 and x86_64, creates and verifies a Universal 2
binary, applies an ad-hoc signature, and publishes the DMG, `SHA256SUMS`, and
GitHub artifact provenance. Homebrew is the canonical install/update path.

## Repository configuration

No signing or Apple credentials are required for the active ad-hoc release
workflow.
- `HOMEBREW_TAP_TOKEN` (optional): a fine-grained token with Actions dispatch
  access to `phall1/homebrew-tap`; it triggers an immediate cask update.

Enable GitHub artifact attestations for the repository. Provenance is generated
for public repositories, where GitHub's Sigstore-backed attestation service is
available without an Enterprise configuration. For a private repository,
configure GitHub Enterprise artifact attestations before changing the workflow
to remove its public-repository guard.

Protect `v*` tags with a repository ruleset, restrict tag creation to release
maintainers, require the normal CI checks before tag creation, and enable
immutable releases in repository settings when available. The workflow also
runs the full `scripts/verify` lane against the tagged commit and refuses to alter
an existing GitHub Release.

## Publishing

1. Set `app.zon`'s version to the intended `MAJOR.MINOR.PATCH` and land it through
   normal CI.
2. Create and push the matching tag, for example `v0.3.2`, after required checks
   pass on that commit. A tag push starts the workflow automatically.
The workflow can also be run manually with an existing tag. It never builds an
arbitrary branch or untagged SHA.

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
