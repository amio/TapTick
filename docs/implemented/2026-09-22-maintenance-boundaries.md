# Shortcut Persistence and Native Observation Boundaries

Status: Implemented and validated on 2026-09-22.

## Context & Goals

The project-wide maintenance audit reproduced three persistence failures: an import can discard the current library while swallowing a legacy-file error; imports erase durable deletion history; and startup can overwrite unreadable or unsupported metadata. Carbon registrations also depend on eleven manual refresh calls, while the native menu implements its own one-shot observation loops.

The approved work makes import outcomes reliable, preserves files that cannot be interpreted safely, and assigns model-to-native synchronization to its consuming service. Existing script execution policies, menu-bar scheduling, app identities, and distribution settings remain governed by their current owners.

## Requirements & Invariants

- Import replaces the shortcut list and accepts existing exported arrays and supported legacy script actions.
- An unavailable legacy source or invalid import must fail before removing existing scripts. A commit failure must be reported and ordinary I/O failures must roll back files already changed.
- Deletion records remain durable. Replaced IDs get deletion records; explicitly restored IDs become live again.
- Managed script files remain canonical. Hidden entries, symlinks, and directories are outside the managed collection.
- Missing metadata is a new library; unreadable, corrupt, or unsupported metadata is not. Unknown original bytes must be preserved.
- Legacy arrays and supported envelope versions continue to load and migrate. Retrying a failed migration must not create duplicate files. This change does not introduce a new schema or enable iCloud entitlements.
- Settings, utilities, and user shortcuts retain one Carbon namespace and the current conflict priority. Nested recorders suspend registrations until the final recorder ends.
- Explicit-run metadata and script text changes must not cause hotkey re-registration.
- The single native menu consumes the controller's existing rendered snapshot. Serial workers and approximately one-second publication stay in MenuBarTextController.

## Proposed Solution

### Loading and write permission

ShortcutSyncState validates supported schema versions and unique live IDs at the decoding boundary. Legacy-array fallback is limited to a root shape mismatch, so a malformed or unsupported envelope does not get mistaken for another format. Constructed remote states are validated before adoption as well.

ShortcutStore exposes a loading issue and a retry operation. Startup reads and validates metadata before creating or reconciling Scripts. A loading issue prevents mutation, directory reconciliation, migration, and upload through one owner-defined write-permission check at the store's mutation entry points. Retry reloads the original file; legacy migration prepares a complete state and reuses the file commit operation before publishing it, so failed attempts can safely retry. Only successful loading reattaches the directory monitor and cloud callback. Settings displays the issue with a Retry action independently of the selected pane.

Cloud download distinguishes a missing file from a failed read. Full sync stops after a failed download. Coordinated uploads validate any existing cloud file before replacing it, so an unreadable future envelope cannot be overwritten through an unrelated local edit.

### Import preparation and commit

Import validates the complete array and resolves every legacy source before touching the current library. Name allocation uses the same normalization and collision rules as ordinary managed scripts, reserving filesystem entries that are not being replaced. A filesystem-only file that has not yet been adopted is preserved; the ordinary watcher can adopt it later.

Preparation produces the new live records, retained tombstones, and tombstones for replaced IDs. Its event date is later than all known imported/local edits and deletions at whole-second precision, matching the existing cloud codec; no global clock state is introduced. It stages all new scripts in a temporary directory beside the store, on the same filesystem. The store moves existing managed files into that directory as backups, installs prepared files, and writes metadata atomically last. In-memory publication and cloud upload happen only after metadata succeeds. The operation has no suspension points, so queued FSEvents reconciliation cannot observe an intermediate state on MainActor.

On an ordinary failure, installed files are removed and moved originals restored. If rollback itself fails, backup files and a copy of the original metadata are retained. The same write gate distinguishes this incomplete-rollback reason from ordinary unreadable data, identifies the recovery directory, and refuses ordinary Retry until the files have been manually recovered and the app reopened. It must not clean up the only recoverable original. Successful cleanup failure is reported separately from import failure.

This is a bounded import operation, not a generic filesystem transaction framework. It does not promise crash-atomic replacement of multiple files and metadata. No recovery journal or new persistent format is introduced. The file commit primitive also serves the existing legacy migration, preserving existing directory entries and record IDs. Existing unsupported or unreadable data cannot be bypassed by import; it must first become readable through Retry.

### Native observation consumers

HotkeyService derives an equatable registration plan from the store, utility configuration, and its settings hotkey. It seeds registration synchronously and then consumes native Observations. An unchanged plan does not touch Carbon. Recorder suspension keeps the current plan derivable without registering it; final resume applies the latest plan. Stop cancels observation, unregisters keys, and removes its event handler, and subsequent model changes cannot restart it.

The native Carbon boundary exposes the minimum registration/event operations needed to test lifecycle and ordering without simulated keyboard input. Production retains a single event handler and monotonically increasing registration IDs so delayed events do not acquire another action.

MenuBarController directly consumes Observations for visible menu entries and rendered slots, replacing continuations and the 50 ms delay. Snapshot equality excludes trigger timestamps and source text. Menu rendering and action dispatch use those entries; the underlying store remains authoritative for execution. No shared event bus or reusable observer framework is added.

## Implementation Plan

1. Add supported-state validation, safe loading/retry, cloud read-failure propagation, and Settings error presentation (C).
2. Replace the partial import loop with preparation, staged commit, rollback, and durable tombstones (A).
3. Implement consumer-owned hotkey and menu observation; remove refresh callbacks and callers (B).
4. Add focused regression coverage, run formatter/lint/tests and Debug/universal Release builds, then launch the Dev app.
5. Fold essential invariants into owning source files and move this design to docs/implemented.

## Trade-offs & Risks

- Old applications will refuse to mutate a future schema rather than discard data they do not understand.
- Import needs temporary disk space for the prepared scripts and backups; failures must not publish partial success.
- External applications can edit the directory independently during an import. This work does not add cross-process edit locking or promise crash consistency; rollback must preserve backups if it cannot restore safely.
- Observations delivers after an actor transaction. Initial registration remains synchronous, cancellation and re-entry require focused coverage, and menu/hotkey snapshots must include every field relevant to their native consumer.
- Ordinary CRUD retains its existing behavior beyond the new load gate; this maintenance does not silently expand into a full persistence rewrite.

## Validation & Rollout

Test import preflight failure, duplicate IDs, collisions, non-managed entries, metadata commit failure with file rollback, successful reload, and tombstone merge behavior. Test absent/current/legacy/future/corrupt metadata, mutation attempts during load failure, and recovery after correcting the file. Exercise constructed unsupported remote states without enabling live iCloud.

Use a fake native hotkey boundary for start/stop, changes from any model writer, irrelevant edits, namespace conflicts, and nested recorders. Verify observation cancellation and menu snapshot identity without UI automation. Preserve existing scheduler, execution, migration, and editor tests.

There is no database migration or new data format. Successful imports still persist schema 2; legacy migration remains existing behavior. Rollback of this code does not require data conversion, although the older implementation would reintroduce the audited failure behavior. No commit, release, provisioning change, or GUI interaction is implied by validation and make run.


## Independent Review

The design review accepted two refinements: distinguish incomplete rollback from a retryable read failure, and choose import event times that retain precedence after the cloud codec truncates fractional seconds. The implementation review identified non-idempotent legacy migration on Retry; preparing the full migration and reusing the same file commit boundary removes that partial-write path. These refinements preserve the approved behavior without adding a journal, global clock, or transaction framework.


## Validation Results

- `make format`, `make lint`, and `git diff --check` pass.
- `make test`: 151 tests passed, zero failures and zero skips (xcresult summary).
- Debug and universal arm64/x86_64 Release builds pass on macOS 27.0 with Xcode 27.0 / Swift 6.4.
- Native observation and teardown compile for the macOS 26 deployment target. Observations and isolated deinit are available with Swift 6.2; the minimum OS was not separately run on this host. References: [SE-0475](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md), [SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md).
- Tests use temporary libraries and a fake Carbon boundary; no GUI automation, real AI request, or live iCloud rollout was used.
