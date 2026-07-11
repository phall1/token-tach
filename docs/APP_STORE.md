# Mac App Store release

The App Store build uses bundle ID `com.phall.token-tach`. It is a sandboxed
variant of the direct-download app: on first launch, the user chooses their
`.claude`, `.codex`, and `.local/share/opencode` directories in standard macOS folder pickers. Token Tach
stores read-only security-scoped bookmarks in its app container and performs
all log processing locally. The Store build does not read Claude Code's
Keychain credential, invoke the `security` command, or poll Claude OAuth.

The package declares Apple's Developer Tools category
(`public.app-category.developer-tools`) and ships as Universal 2 (`arm64` and
`x86_64`) with a macOS 11.0 minimum. Store binaries reserve Mach-O header
padding and are normalized with Apple's `vtool` so both `LC_BUILD_VERSION`
slices identify Apple's linker. Direct-download and development builds retain
the Native SDK defaults.

## Credential-free validation

The `App Store artifact validation` workflow runs on pushes and pull requests.
It needs no Apple secrets. It runs the runtime contract regression, builds both
architectures, creates an ad hoc-signed Store-shaped app and unsigned installer,
then re-expands and audits the installer that it uploads as a short-lived CI
artifact:

- exact bundle ID, executable, app version, CI build number, category, platform,
  and minimum OS
- exactly the `arm64` and `x86_64` slices and expected Mach-O build metadata
- valid ad hoc signature with App Sandbox, app-scoped bookmarks, and read-only
  user-selected file access
- survival of a packaged sandbox launch from `/`, exercising Store access setup
- no unknown entitlements, embedded production profile, escaping symlink, extra
  main executable, or quarantine metadata

Run the same lane locally with:

```sh
STORE_BUILD_NUMBER=202607110001 STORE_BUILD_FLOOR=0 scripts/release-app-store --ci
```

CI packages end in `-mac-app-store-ci.pkg`. They are deliberately not signed
installer products and cannot be uploaded to Apple.

## Signing assets

A production package requires:

1. An Apple Distribution or Mac App Distribution certificate and private key.
2. A Mac Installer Distribution certificate and private key.
3. A Mac App Store distribution provisioning profile for
   `com.phall.token-tach`.

The certificate identities may coexist in one password-protected PKCS#12 file.
For a local build, install them in Keychain and run:

```sh
scripts/release-app-store --profile /path/to/profile.provisionprofile
```

The profile is auto-discovered from Xcode's standard profile directories when
`--profile` is omitted. The script strips extended attributes, signs the app
and installer, re-expands the final package, and applies the same fail-closed
audit with additional profile/signature consistency checks.

## Build numbers

`CFBundleVersion` is generated and printed before packaging:

- GitHub Actions uses `GITHUB_RUN_ID` plus the run attempt, so reruns increase.
- A credentialed local run asks App Store Connect for the newest uploaded build
  and increments its final numeric component.
- An offline local run uses a UTC timestamp (`YYYYMMDDhhmmss`).

For a deliberate local override, provide a positive integer and the latest
submitted floor. The script refuses a number that does not exceed the floor:

```sh
STORE_BUILD_NUMBER=202607110002 STORE_BUILD_FLOOR=202607110001 scripts/release-app-store
```

## API delivery

Create an App Store Connect team API key with the App Manager role (or the
least role Apple permits for build upload and internal group assignment). Keep
the `.p8` file outside the checkout and export:

```sh
export APP_STORE_CONNECT_API_KEY_ID=ABC123DEFG
export APP_STORE_CONNECT_API_ISSUER_ID=00000000-0000-0000-0000-000000000000
export APP_STORE_CONNECT_API_KEY_PATH=/secure/AuthKey_ABC123DEFG.p8
export APP_STORE_CONNECT_APP_ID=1234567890
scripts/release-app-store --upload --testflight-group 'Token Tach Internal'
```

`--upload` runs Apple's preflight validation, uploads with `altool`, polls the
App Store Connect API until the build is `VALID` or `INVALID`, prints API and
Apple tool errors, and times out after one hour. When a group is supplied, the
script requires exactly one matching group and refuses it unless Apple marks it
as internal. Processing failures still need inspection under App Store Connect
> TestFlight > macOS because Apple does not expose every processing diagnostic
through the public builds API. Local API automation requires `curl`, `jq`,
Ruby/OpenSSL, Xcode command-line tools, and zsh.

## GitHub delivery setup

The manual `App Store delivery` workflow builds, signs, audits, uploads, waits
for processing, and optionally assigns the selected internal TestFlight group.
Configure these environment secrets on the `app-store-delivery` environment:

| Name | Value |
| --- | --- |
| `MACOS_DISTRIBUTION_CERTIFICATE_P12_BASE64` | Base64 PKCS#12 containing both distribution identities and private keys |
| `MACOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | PKCS#12 password |
| `MACOS_APP_STORE_PROVISIONING_PROFILE_BASE64` | Base64 Store distribution profile |
| `MACOS_CI_KEYCHAIN_PASSWORD` | Random password for the runner's ephemeral keychain |
| `APP_STORE_CONNECT_API_PRIVATE_KEY` | Complete `.p8` contents |
| `APP_STORE_CONNECT_API_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | API issuer UUID |

Configure `APP_STORE_CONNECT_APP_ID` as an environment variable (the numeric
Apple app ID, not the bundle ID). Restrict environment deployment branches to
`main`. The workflow writes credentials only beneath `RUNNER_TEMP`, deletes the
temporary keychain, and never uploads signed products as workflow artifacts.

Create a second environment named `app-store-production-review`, restrict it to
`main`, and add required reviewers. The workflow reaches that environment only
after a processed upload. Approval records that a human may begin the final
release checklist; it does not submit anything to Apple.

## Manual Apple steps

Final Apple review remains manual:

1. In App Store Connect, inspect the processed build and TestFlight results.
2. Complete screenshots, description, privacy details, age rating, pricing,
   export compliance, and review notes.
3. Confirm the selected build and release/phased-release settings.
4. Approve the protected `app-store-production-review` job.
5. Submit for Review in App Store Connect and respond to Apple if required.

Certificates, private keys, profiles, Apple credentials, and generated signed
packages must never be committed. The repository contains only public metadata,
permission entitlements, and automation.
