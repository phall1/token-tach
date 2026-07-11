# Direct GitHub Releases

The `Release` workflow publishes an existing `vMAJOR.MINOR.PATCH` tag. It builds
the tag's exact commit for arm64 and x86_64, creates and verifies a Universal 2
binary with Sparkle, signs it with Developer ID, notarizes and staples the app
and DMG, verifies the signature and Gatekeeper result, and publishes the DMG,
signed update ZIP/appcast, `SHA256SUMS`, and GitHub artifact provenance.

## Repository configuration

Create a GitHub environment named `release` and require trusted reviewers. Put
the signing secrets on that environment so they are unavailable until approval:

- `MACOS_CERTIFICATE_P12`: base64 of the Developer ID Application `.p12`.
- `MACOS_CERTIFICATE_PASSWORD`: password used when exporting the `.p12`.
- `MACOS_KEYCHAIN_PASSWORD`: a strong, release-only temporary keychain password.
- `APPLE_API_PRIVATE_KEY`: base64 of an App Store Connect API `.p8` key permitted
  to submit notarizations.
- `APPLE_API_KEY_ID`: App Store Connect API key ID.
- `APPLE_API_ISSUER_ID`: App Store Connect API issuer UUID.
- `SPARKLE_PRIVATE_KEY`: the production Sparkle Ed25519 private key used only
  to sign update archives and appcasts.

Add these environment variables (not secrets):

- `DEVELOPER_ID_APPLICATION`: full certificate name, beginning with
  `Developer ID Application: `.
- `APPLE_TEAM_ID`: the 10-character Apple Developer team ID.
- `SPARKLE_PUBLIC_KEY`: base64-encoded 32-byte public key matching the private
  key. It is embedded in direct-download builds.

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
3. Approve the `release` environment deployment after checking the tag and
   commit shown by the verify job.

The workflow can also be run manually with an existing tag. It never builds an
arbitrary branch or untagged SHA.

For a local updater-enabled equivalent, import the Developer ID identity, keep
the Sparkle private key outside the repository, and store notarytool credentials
in a keychain profile, then run:

```sh
scripts/release-updater \
  --identity "Developer ID Application: Example (TEAMID)" \
  --feed-url "https://github.com/phall1/token-tach/releases/latest/download/appcast.xml" \
  --public-key "$SPARKLE_PUBLIC_KEY" --notarize
SPARKLE_ED_KEY_FILE=/secure/path/to/sparkle-private-key \
  scripts/updater-generate-appcast zig-out/updater/releases \
  "https://github.com/phall1/token-tach/releases/download/vX.Y.Z/"
```

App Store Connect API credentials can be used instead by setting
`NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID`.
