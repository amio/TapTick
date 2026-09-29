# PROJECT RULES

> Keep this file as short as useful, target no more than 1000 words, and never exceed 1200 words. Do not add content to reach a target. Update by replacing or consolidating guidance, not by appending task history. Keep a fact only when it is project-wide, non-obvious, decision-relevant, and durable; otherwise put it in scoped instructions, owning code, tests, or focused docs. Never duplicate or weaken a fact across sections. Before finishing an edit, recheck the size and section limits.

- Before changing code, inspect the relevant owner and its callers, persistence, and runtime boundaries. Fix root causes at the highest coherent owner and raise disproportionate complexity or architecture costs before implementing non-essential requirements.
- Treat `project.yml` as the source for generated Xcode metadata. Run `make gen` after changing it; do not hand-maintain generated `TapTick.xcodeproj` state.
- Use Makefile workflows for repository operations. Do not format Swift manually: after code changes, run `make format`, `make lint`, focused risk-based tests, and the proportionate build target.
- After completing and non-interactively validating code changes, automatically run `make run` to replace and launch the modified app for the user to test. Launching the app is a handoff, not authorization for Codex to interact with its UI.
- Do not use Computer Use, UI automation, or simulated mouse or keyboard input to validate TapTick because they take over the user's active Mac session, unless the user explicitly authorizes that specific interaction.
- Preserve Swift 6 strict concurrency and macOS 26 compatibility. Keep shared mutable runtime state under an explicit owner, normally isolated to `@MainActor`; do not bypass an owner with parallel state or lifecycle machinery.
- Treat SwiftUI API knowledge—especially for macOS 26+ components—as unverified until confirmed. Before using these APIs, consult the official documentation or run a focused compile/runtime probe; never code from memory, analogy, or guessed signatures and behavior.
- Do not add standalone examples or speculative scaffolding; changes must be production-ready and integrated into the owning module.

# PROJECT CONTEXT

- **Stack**: Swift 6, SwiftUI plus focused AppKit integration, and an SPM monorepo containing the `TapTickKit` library and `TapTick` app. XcodeGen generates Xcode 27 project metadata.
- **Platform**: macOS 26+ menu-bar utility. Carbon owns permission-free registered global hotkeys; AppKit owns native status items, panels, process launching, and macOS permission or workspace integration where SwiftUI is not the correct boundary.
- **Constraints**: The app executes user-selected shell scripts. Generated project state, release signing/notarization, Sparkle appcast inputs, macOS privacy identity, and forward-compatible stored data must remain consistent across local and CI workflows.
- **CloudKit**: Debug and Release use separate containers and environments. Keep CloudKit/push entitlements, provisioning profiles, `Resources/CloudKit.ckdb`, and local/CI signing workflows consistent. Sync uses the private database; never move shortcut or script data into the public database.

# ARCHITECTURE INDEX

## Ownership Map

- `Sources/TapTick/App/TapTickApp.swift` is the composition root: `AppState` owns process-lifetime services and `AppDelegate` owns launch, settings-window, menu-bar, and hotkey wiring.
- `Sources/TapTickKit/Services/ShortcutStore.swift`, `Sources/TapTickKit/Models/ShortcutSyncState.swift`, `Sources/TapTickKit/Services/CloudSyncService.swift`, and `Sources/TapTickKit/Services/CloudSyncSnapshot.swift` own user shortcuts, local/cloud envelopes, deletion records, migrations, merge semantics, account binding, and CKSyncEngine lifecycle.
- `Sources/TapTickKit/Services/HotkeyService.swift`, `Sources/TapTickKit/Services/UtilitiesController.swift`, and `Sources/TapTickKit/Services/KeystrokeOverlayService.swift` own the global hotkey namespace, utility configuration/routing, permission recovery, and utility runtime lifecycle.
- `Sources/TapTickKit/Services/ScriptRunner.swift`, `Sources/TapTickKit/Services/ShortcutExecutor.swift`, and `Sources/TapTickKit/Services/ScriptLogStore.swift`, together with `ScriptOutputPresenter`, own context-free script processes, explicit-run policy and active runs, bounded persisted history, and subtitle presentation.
- `Sources/TapTickKit/Services/MenuBarTextController.swift`, `Sources/TapTickKit/Models/MenuBarTextSlot.swift`, and `Sources/TapTickKit/Views/MenuBarController.swift` own status-text persistence/scheduling/display state, schema normalization, and the sole native `NSStatusItem`/menu.
- `project.yml`, `Package.swift`, and `.github/workflows/build.yml` are the coordinated build/release authorities for identity, versions, dependency pins, validation, signing, notarization, packaging, and appcast generation.

## Cross-Cutting Invariants

- Debug is `TapTick Dev` / `com.taptick.app.dev`; Release is `TapTick` / `com.taptick.app`. Their Application Support directories and macOS privacy identities stay isolated; release packaging keeps the release identity.
- Settings, utility, and user shortcuts share one conflict-checked Carbon registration namespace. `HotkeyService` alone registers and dispatches them; nested recorder sessions suspend registrations until the final recorder exits.
- Native utilities remain outside the user shortcut schema. `UtilitiesController` persists their settings separately, exposes named reserved actions, and delegates permission request and System Settings recovery to the permission-owning service.
- Shortcut persistence uses an envelope of live records plus UUID/timestamp deletion tombstones. An equal-or-newer deletion defeats an edit, tombstones remain durable, legacy arrays still decode, and user import/export exposes only live shortcut arrays.
- Hotkey, native-menu, and Editor Run triggers share the process-lifetime `ShortcutExecutor`; each script retains 32 persisted explicit-run logs. Menu-bar refreshes reuse only `ScriptRunner` and must never update explicit logs, trigger metadata, or subtitles.
- Each configured menu-bar line has one persistent serial worker. Configuration changes wake it, obsolete results are discarded, and non-cancellable processes never overlap per line. Completed results publish together through one controller-level approximate one-second snapshot shared by the real menu bar and Settings preview.
- Sparkle stays exactly pinned to one audited version across SPM, XcodeGen, and release tooling. `project.yml` owns marketing/build versions; CI validates release tags against them and intentionally ignores plain pushes to `main`.
