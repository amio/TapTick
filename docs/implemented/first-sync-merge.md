# First-sync script merge

## Context and goals

Independently adopting the same files on two Macs creates different shortcut UUIDs. First sync should combine identical scripts without duplicating them. Existing duplicates and routine UUID sync remain outside this feature.

## Requirements and invariants

- Match only unambiguous, independent managed scripts with the same normalized filename, exact UTF-8 source bytes, hotkey, and enabled state. Different names, ambiguous groups, and application shortcuts remain separate.
- Different content or configuration automatically keeps both versions through the existing filename collision handling. No review UI or waiting for user choices.
- Preserve cloud identity and retire the redundant local ID with a deletion newer than both edits. Preserve local trigger history, menu-bar references, and bounded execution history.
- Fetch and durably adopt the library/references before the first upload. Keep initial reconciliation active until server acknowledgment; restarting or turning sync off/on must not repeat a completed join.

## Proposed solution and ownership

`FirstSyncMerge` directly computes the library, local ID replacements, and result counts. `CloudSyncSnapshot` uses its existing library as the durable inbox and retains two first-join completion flags, ID replacements, and counts. No pending-review snapshot or choice model is needed.

`CloudSyncService` reads current local files before the first remote merge. Recovery recombines the acknowledged remote snapshot with current local state before adoption, preserving downloaded data even from the earlier pending-review cache. General settings displays one result message.

`ShortcutStore` commits the library and transfers local trigger metadata. The composition root connects replayable reference writes to the menu-bar and log owners. Remapping applies only while the retired identity is absent and its replacement is live. Late-finishing runs use the current replacement map.

## Implementation plan

1. Remove review UI, choices, pending-review state, and stale-choice validation; merge remote data immediately.
2. Retain initial fetch/adoption gates, durable tombstones, and replayable local ID migration.
3. Replace review tests with automatic keep-both tests, run validation, and launch the Debug app.

## Trade-offs and alternatives

Different versions require manual editing/deletion if the user later wants one version. This avoids a persisted interactive workflow. Content-derived IDs would change on edits; routine content deduplication could collapse intentional copies. Ambiguous groups therefore retain existing UUID semantics. A deliberately newer edit can restore a retired ID under the existing deletion policy.

## Data compatibility and rollout

No CloudKit schema or shortcut-envelope version change. Established caches lack the optional first-join session and skip deduplication. Older review-cache fields are ignored; its acknowledged remote payload is merged with current local data on retry. Library commits and reference writes remain replayable after failure. Import/export stays unchanged. Rollback retains UUID records and deletion tombstones; there is no automatic inverse migration.

## Validation

Cover byte/configuration differences, intentional copies, ambiguous names, UUID deletion precedence, durable cache and upload gates, concurrent joins, persisted reference/history migration, and deliberately restored IDs. Use repository format/lint, focused tests, full unit tests, and a signed Debug build/run. Actual two-Mac propagation remains user-driven; no UI automation or live-data reset.

## Verified implementation

- Production additions reduced from 450 to 223 lines; the direct merge/session types occupy 54 lines. The review view and pending-choice machinery are removed.
- `make gen`, `make format`, `make lint`, and diff whitespace checks passed. The focused sync/store/menu/log/hotkey suites passed: 64 tests / 71 runs on macOS 26.6.2.
- Full `make test` ran 172 tests / 187 runs with three existing process-test failures: `ScriptRunnerTests.appliesChangedTimeout`, `ScriptRunnerTests.timesOutInheritedPipe`, and `GenerationProcessTests.staleRequest`. The 1-second timeout test also failed when ScriptRunner ran independently; generation and inherited-pipe tests passed in a subsequent grouped run. No process execution implementation was changed. Result bundles remain in `build/Logs/Test`.
- `make build` passed with Debug signing; `codesign --verify --deep --strict` passed. `make run` replaced and launched TapTick Dev. Two-Mac first-join propagation remains a manual validation boundary.
