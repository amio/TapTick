# Release Guide

TapTick ships outside the Mac App Store as a Developer ID-signed app, notarized
and stapled before DMG packaging. [project.yml](project.yml) owns versions and
build settings; the [Makefile](Makefile) owns local commands;
[build.yml](.github/workflows/build.yml) owns CI distribution.

## Development and signing

Install Xcode and Homebrew, then run `make setup`. DMG packaging additionally
requires `brew install create-dmg`. Use `make help` for the complete target list.

| Build path | App / bundle identifier | Signing |
| --- | --- | --- |
| `make build`, `make run` | TapTick Dev / `com.taptick.app.dev` | Automatic, Apple Development |
| `make release` | TapTick / `com.taptick.app` | Automatic, Apple Development |
| `make archive`, `make dist`, CI distribution | TapTick / `com.taptick.app` | Manual Developer ID Application override at archive time |

Local app builds need a usable Apple Development identity for the configured
team. Debug and Release have separate Application Support directories and macOS
privacy identities. `make run` replaces only the Debug instance.

`make release` validates a Release build; use `make dist` for a notarized DMG.
Unit tests run with signing disabled through `make test`. `make ci` runs lint,
unit tests, and a Release build locally; it does not publish anything.

## Versions and CI triggers

`MARKETING_VERSION` in `project.yml` must be `X.Y.Z`, and
`CURRENT_PROJECT_VERSION` must be an integer. Run `make gen` after changing
project settings. Never maintain generated Xcode metadata by hand.

The version targets update `project.yml`, regenerate the project, commit, and
create an annotated tag:

- `make version-patch`, `make version-minor`, or `make version-major` increments
  the chosen version component and build number, then tags `vX.Y.Z`.
- `make version-build` increments only the build number and tags `vX.Y.Z+bN`.

Use these targets from a clean working tree with no unrelated staged changes.
They do not push. Push the resulting commit and its exact tag when ready to
publish. CI rejects a release tag unless it matches either `vX.Y.Z` or
`vX.Y.Z+bN` from the tagged revision's project settings.

| Build & Distribute trigger | Result |
| --- | --- |
| Pull request | Unit tests |
| `v*` tag push | Unit tests, signed/notarized DMG, GitHub Release, appcast, landing page |
| Manual dispatch, default inputs | Unit tests only |
| Manual dispatch with `build_distribution` enabled | Unit tests and signed/notarized DMG artifact; no GitHub Release or appcast publication |
| Plain push to `main` | No Build & Distribute run |

For manual dispatch, `revision` accepts a full commit SHA, branch, or tag; blank
uses the selected branch. Manual artifacts include the project version, build
number, and short SHA (`X.Y.Z+bN-dev-SHA`). DMG artifacts remain downloadable
from the Actions run for 30 days.

## Local distribution

Prepare the signing certificate, notarization profile, and Sparkle public key
described below, then run:

```bash
make gen
make dist
```

The pipeline archives to `build/TapTick.xcarchive`, exports to
`build/export/TapTick.app`, submits that app for notarization, staples its ticket,
and packages `build/TapTick.dmg`. Run the pipeline sequentially, without `-j`.

For individual steps, `make export` also runs `make archive`. `make notarize`
requires an existing exported app; `make dmg` requires that app to have already
been notarized and stapled. Export uses
[Resources/exportOptions.plist](Resources/exportOptions.plist); its team must
match the archive's signing team. Local distribution does not publish a release
or update feed.

### Certificate and notarization profile

Use an Apple Developer Program account with a Developer ID Application
certificate and its private key installed in the login Keychain. Certificates
can be managed through Xcode's account settings. Inspect available identities:

```bash
security find-identity -v -p codesigning
```

Store notarization credentials interactively; supply the Apple ID, developer
team ID, and an app-specific password when prompted:

```bash
xcrun notarytool store-credentials "TapTick"
```

The profile name matches the Makefile's `NOTARIZE_PROFILE`. A different profile
can be selected with `make dist NOTARIZE_PROFILE=MyProfile`. CI uses its own
secrets rather than this local Keychain profile.

### Sparkle keys

Sparkle is exactly pinned to **2.9.6** in [Package.swift](Package.swift),
`project.yml`, and the CI tools download. Keep all three aligned when upgrading.
Use the matching [Sparkle release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)
for its CLI tools. In the extracted tools directory, the initial setup is:

```bash
./bin/generate_keys
./bin/generate_keys -x sparkle_private_key
```

`generate_keys` creates a signing key in the login Keychain, or reuses the
existing key, and prints the public key. `-x` exports the private key for CI.
For an existing release channel, retain its established key pair; creating a
new key is not a routine release step. Store the exported private key in the CI
secret and remove the temporary export after transfer, retaining a secure backup.

[Resources/Info.plist](Resources/Info.plist) expands the `SPARKLE_ED_PUBLIC_KEY`
build setting into `SUPublicEDKey`. CI supplies this setting explicitly when
archiving. For local distribution with working updates, set the matching public
key in `project.yml` and run `make gen`; the checked-in setting is empty.
The local Makefile does not inject the CI secret.

## CI credentials

Configure these repository secrets under Settings → Secrets and variables →
Actions:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of the Developer ID Application certificate and private key exported as `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `APPLE_TEAM_ID` | Signing team, matching the certificate and export options |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | That account's app-specific password |
| `SPARKLE_ED_PRIVATE_KEY` | Contents exported by `generate_keys -x` |
| `SPARKLE_ED_PUBLIC_KEY` | Matching public key printed by `generate_keys` |

Export the certificate with its private key from Keychain Access as
`DeveloperID.p12`, then copy the encoded value for the secret:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Remove the temporary `.p12` after transfer. CI imports it into a temporary
Keychain and removes that Keychain after distribution.

## Update feed and landing page ownership

[UpdateService](Sources/TapTickKit/Services/UpdateService.swift) wraps Sparkle.
The app's feed URL is [appcast.xml](https://amio.github.io/TapTick/appcast.xml);
update archives are hosted on GitHub Releases.

On a version tag, `build.yml` publishes the DMG to GitHub Releases, fetches the
existing feed, and invokes the pinned `generate_appcast` tool. It passes the
private key through stdin using `--ed-key-file -`, and sets the download URL
prefix to that tag's GitHub Release. The tool does not implicitly read TapTick's
`SPARKLE_ED_PRIVATE_KEY` environment variable.

The generated feed travels as the `sparkle-appcast` Actions artifact to the
`publish-appcast` job, which updates `gh-pages` while preserving other files.
The release then calls [pages.yml](.github/workflows/pages.yml) to refresh the
landing page's download link and version from the latest GitHub Release.

`pages.yml` also runs for changes to `public/**` or itself on `main`. It preserves
the feed from `gh-pages` before deploying the landing page. Both publication
jobs share the `github-pages` concurrency group. `public/appcast.xml` is a
deployment staging file, not a source file to edit in the repository.

## iCloud distribution status

Sync code and migration support exist, but iCloud entitlements remain disabled
in [Resources/TapTick.entitlements](Resources/TapTick.entitlements). Current
distribution does not enable iCloud sync.

Enabling it requires a separate provisioning and rollout decision: register the
App ID and container, obtain a compatible Developer ID provisioning profile,
then coordinate entitlements, local archive settings, export profile mapping,
and CI profile installation. Validate migration and multi-device behavior in
the provisioned build before advertising sync as available.

## Verify a distributable build

After `make dist` (or `make export` followed by `make notarize`), verify the
exported app:

```bash
codesign --verify --deep --strict build/export/TapTick.app
codesign -dv --verbose=4 build/export/TapTick.app
xcrun stapler validate build/export/TapTick.app
spctl --assess --type exec --verbose build/export/TapTick.app
```

Expect the intended Developer ID Application authority, a valid stapled ticket,
and Gatekeeper acceptance as `Notarized Developer ID`. Export alone does not
notarize or staple the app. Check the exported `Contents/Info.plist` for the
release identifier `com.taptick.app`, the intended marketing/build versions,
and the established `SUPublicEDKey` before distributing updates.
