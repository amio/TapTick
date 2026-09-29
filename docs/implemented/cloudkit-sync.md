# CloudKit shortcut sync

## Scope and ownership

Sync the existing shortcut library and managed script source on macOS 26 and 27 using CKSyncEngine and the user's private CloudKit database. Local JSON and Scripts remain the working library; menus, utilities, preferences, and execution logs remain local. Debug and Release use separate App IDs and containers.

ShortcutStore owns local persistence and script adoption. CloudSyncService owns account binding, CKSyncEngine, a durable cloud inbox/outbox, and transport errors. CloudKit stores one `ShortcutLibrary` record in the `Shortcuts` custom zone. Its `payload` CKAsset contains the versioned JSON envelope, including durable deletion tombstones. This small configuration library favors a single atomic snapshot over per-shortcut records; a change uploads the snapshot, trading bandwidth for fewer cross-record failure states. CKAsset avoids the record-field size limit for script bodies.

## Consistency and compatibility

All merges use UUID and modification/deletion timestamps; equal-time deletions win. Equal-time live conflicts use deterministic encoded content ordering so devices converge. Trigger history is local. Cloud metadata persists downloaded payloads together with server record system fields and engine serialization. Downloaded payloads remain recoverable when local script adoption fails; no transport acknowledgment implies successful local adoption. Local startup requeues the persisted library, covering interruption before an outbox update. Assets remain on disk for the duration of send operations.

Account identity is checked before an engine may send. Switching accounts pauses until the user explicitly chooses to merge the local library into the current account. Old engine events cannot mutate the new account's cache. Local files are never deleted on sign-out. Unknown schemas and unreadable sync metadata fail closed.

Existing local legacy arrays/envelopes still migrate through ShortcutStore. The old Drive transport was not provisioned for release; these CloudKit containers were created for this rollout, so there is no released Drive container to migrate. Older apps continue to use local data and cannot participate in CloudKit sync.

## Provisioning and rollout

App IDs: `com.taptick.app` and `com.taptick.app.dev`. Containers: `iCloud.com.taptick.app` and `iCloud.com.taptick.app.dev`. Both need CloudKit and Push Notifications. Developer ID distribution needs its provisioning profile embedded in the app; development uses a macOS development profile. Production schema deployment is required before release. No App Store submission is required.

Validate merge convergence, deletion propagation, durable cache round trips, failure recovery, local script adoption, unsigned tests, signed builds and embedded profile entitlements. Verify actual two-Mac propagation and account transitions with signed apps. CI must install its Developer ID profile before archiving; generating a portal profile alone does not complete release readiness.

## Configured rollout state

The production and development App IDs are bound only to their respective containers, with push enabled. `ShortcutLibrary` has `payload: Asset` and `schemaVersion: Int64`; the production container schema is deployed to Production, while the dev container uses Development. `Resources/CloudKit.ckdb` is the checked schema definition. The app always uses the private database, and ShortcutLibrary has no public `_world` read grant.

`TapTick Developer ID CloudKit` is the distribution profile; Xcode automatic signing downloads a matching Mac Team profile for Debug. The distribution profile is installed locally and stored as `APPLE_PROVISIONING_PROFILE_BASE64` in the repository's Actions secrets. For a new Mac, sign in to Xcode and run `make build PROVISIONING_FLAGS=-allowProvisioningUpdates`; Developer ID archive can use the same flag to download its profile. CI installs the profile before archive. Certificates and profiles are not committed.

Local format/lint, 160 unit tests (170 parameterized runs), signed Debug build, Developer ID universal archive/export, and exported code-signature integrity have been verified on macOS 27, with macOS 26 as the deployment target. macOS 26 runtime testing remains outstanding. Two-Mac propagation, offline recovery against the live service, and actual account switching still require signed-app end-to-end checks. No release was published as part of setup.
