# CORE GUIDELINES

## Workflow
- **Post-Development**:
  - Refactor for maximum simplicity; resolve all diagnostic errors (auto-apply safe fixes).
  - Document logic using **in-code comments** (not external docs).
  - Provide a **Conventional Commits** draft (English, code block) for the change set. Blank lines between sections.

## Development Principles
- **Simplicity & MVP**: Focus on minimal design; avoid over-engineering.
- **Proactive Execution**: Analyze "why" over "how"; propose optimizations/alternatives instead of passive task completion.
- **Clean Architecture**: Ensure High Cohesion, Low Coupling (SOLID); prioritize readability over "just working."
- **Native-First**: Prefer Platform APIs over simulations.

## Coding Standards
- **Modernity**: Prioritize latest features and modern MacOS APIs.
- **Structure**:
  - Max **6 levels** of indentation; extract functions/variables to flatten logic.
  - Use **local components** for file-specific UI; split complex ternary ops (>3 lines).
  - Move large inline strings (prompts/constants) to utility functions.
  - Adopt the "Newspaper Metaphor": Place the primary exported function at the top of the file. Arrange internal helper functions below it, ordered by their sequence of invocation.
- **Rules**:
  - **No formatting**: Do not fix indentation/style (handled by external tools).
  - **No example files**: Provide usage examples directly in chat.

## Design Philosophy
- Meet the standards of the Apple Design Awards, prioritizing intuitive interaction, exceptional craftsmanship, and profound emotional resonance.
- Embrace the bleeding edge, utilizing the latest SDKs, APIs, and modern UI components to build a state-of-the-art interface.

## Documentation
- **Quality**: Focus on "purpose," not a list of changes. Use **English** only.

## Technical Design Framework

- **The Three-Layer Onion**:
  1. **Foundations**: Define the problem statement, goals/non-goals, and requirements.
  2. **Functional Spec**: Detail the system's behavior from an external perspective.
  3. **Technical Spec**: Describe internal implementation and logic.
- **Top-Down Logic**: Each layer must justify the next. Fix flaws in the problem statement or functional spec *before* moving to technical details to avoid ineffective implementation.
- **Decision Rationale**: Do not just present the final spec. Document alternatives considered and provide clear rationale for chosen solutions to enable meaningful review.

# PROJECT ARCHITECTURE

> **Note for agents**: This section is maintained by agents. If a task changes any aspect of the architecture described here, update this section accordingly — keep it accurate, concise, and informative for agent's future work.

## Overview

KeyMagic is a native macOS menu bar utility (SwiftUI, Swift 6, macOS 15+) that binds global hotkeys to app launches and shell scripts. Built as a two-target project: `KeyMagic` (app) and `KeyMagicKit` (SPM library containing all models, services, and views).

## Data Model

- **`Shortcut`** — core entity: UUID-identified, binds a `KeyCombo` to a `ShortcutAction`. Has `modifiedAt` for iCloud merge conflict resolution. `isAvailableOnThisDevice` computed property checks local app/file availability.
- **`ShortcutAction`** — enum: `.launchApp(bundleIdentifier, appName)`, `.runScript(script, shell)`, `.runScriptFile(path, shell)`.
- **`KeyCombo`** — Carbon key code + modifier flags.

## Persistence

- **Local**: `~/Library/Application Support/KeyMagic/shortcuts.json` — single JSON file, read/written by `ShortcutStore`.
- **iCloud**: Optional sync via iCloud Drive container `iCloud.com.keymagic.app`. Managed by `CloudSyncService`. File: `<ubiquity-container>/Documents/shortcuts.json`.
- **UserDefaults**: `showDockIcon`, `showMenuBarIcon`, `iCloudSyncEnabled`.

## iCloud Sync

- **Approach**: iCloud Drive document sync (not CloudKit/NSUbiquitousKeyValueStore). File coordination via `NSFileCoordinator`, change detection via `NSMetadataQuery`.
- **Merge strategy**: Union by UUID; conflicting UUIDs resolved by later `modifiedAt` wins. `markTriggered` is local-only (no sync/no modifiedAt bump).
- **Cross-device handling**: `Shortcut.isAvailableOnThisDevice` checks if the target app is installed or script file exists. `ApplicationsView` shows an "Unavailable on This Mac" section for synced app shortcuts whose bundle ID isn't locally installed. `ScriptsView` shows a warning icon for `runScriptFile` shortcuts with missing files.
- **Opt-in**: Toggle in General Settings. First enable triggers a full sync (download + merge + upload).
- **Entitlements**: `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers` set to `iCloud.com.keymagic.app`.

## Services

| Service | Responsibility |
|---|---|
| `ShortcutStore` | In-memory state + local JSON persistence + cloud sync integration |
| `CloudSyncService` | iCloud Drive upload/download, `NSMetadataQuery` monitoring, merge logic |
| `HotkeyService` | Global `CGEvent` tap for keyboard shortcuts |
| `ShortcutExecutor` | Executes actions (toggle app visibility, run scripts) |
| `LoginItemManager` | Launch-at-login via `SMAppService` |

## App Entry

`KeyMagicApp` creates `CloudSyncService` first, passes it into `ShortcutStore` via constructor injection. All services are injected into views via SwiftUI `.environment()`.
