# Direct-download updates

Direct-download releases use Sparkle 2.9.4. The framework archive is fetched
from Sparkle's GitHub release and checked against its published SHA-256 before
it is linked or packaged. Normal development builds contain no updater code or
framework; updater support is enabled only for signed release builds.

The updater release path fails closed unless it receives a Developer ID
Application identity, an HTTPS appcast URL, and a 32-byte Ed25519 public key:

```sh
scripts/release-updater \
  --identity "Developer ID Application: Example (TEAMID)" \
  --feed-url "https://example.com/token-tach/appcast.xml" \
  --public-key "$SPARKLE_PUBLIC_KEY" \
  --notarize
```

The resulting Universal 2 ZIP and direct-install DMG are under
`zig-out/updater/releases/`. Generate the appcast
with the matching private key held in the login Keychain (Sparkle's default
account is `ed25519`):

```sh
scripts/updater-generate-appcast \
  zig-out/updater/releases \
  https://example.com/token-tach/
```

Set `SPARKLE_KEY_ACCOUNT` for a non-default Keychain account, or
`SPARKLE_ED_KEY_FILE` to a protected key file in CI. Signing keys, generated
archives, and appcasts remain outside source control. The shipped bundle
requires both a signed feed and pre-extraction Ed25519 archive verification;
its signed-feed failure fallback is disabled.

Before publishing, test a real notarized N to N+1 update from a writable copy
in `/Applications`. Verify the old build detects the new version, rejects a
modified archive and a downgraded appcast item, installs over the same bundle
identifier, and relaunches successfully. This test requires the production
feed, Developer ID certificate, notarization credentials, and private Sparkle
key, so it cannot be completed from a keyless checkout.
