# DEVELOPMENT PROTOCOL — TapTick

## 1. Workflow & Strategy

### Execution Phase

**Pre-Task**: Before executing any assigned task, agents must conduct a thorough analysis of the relevant codebase to understand the context and potential impact of their changes. This includes:
  - **Contextual Audit**: Perform a comprehensive audit of relevant code for context and impact.
  - **Proactive Ownership**: Prioritize "why" over "how." Challenge sub-optimal architectures rather than passive execution.
  - **Strategic Research**: Formulate the optimal approach considering system-wide implications. Consolidate insights into `docs/research/{date}-{topic}.md`.

**Post Task**: After completing the assigned task, agents must:
  - **Refinement**: Review the complete changeset; refactor for maximum simplicity and resolve all diagnostic errors.
  - **Commit Draft**: End every response with an updated English **Conventional Commits** block.

### Design Framework (Three-Layer Onion)
1. **Foundations**: Define problem, goals/non-goals, and requirements.
2. **Functional Spec**: Detail external behavior.
3. **Technical Spec**: Describe internal logic and rationale.
*Note: Each layer must justify the next; fix upstream flaws before technical implementation.*

## 2. Development Principles

- **Simplicity (MVP)**: Eliminate over-engineering and "Trivial Forwarding" (Middle Man). Ensure every function adds value or refactor to reduce call depth.
- **Clean Architecture**: Enforce SOLID principles; prioritize cohesion and long-term readability.
- **Native-First**: Use platform APIs (Electron `nativeTheme`, Web Popover/Anchor) and GPU-accelerated CSS over JS-heavy simulations.
- **Performance-By-Design**: Optimize for real-world usage patterns; avoid premature optimization but identify and address bottlenecks early.
- **Use Edge APIs**: Leverage cutting-edge features (e.g., React 19 Actions, View Transitions) to enhance UX and maintain modern codebase.

## 3. Technical Standards

- **Stack**: Strict TypeScript (zero `any/as`), semicolon-free, **styled-jsx** only (no Tailwind).
- **Modernity**: React 19 (Actions/use), Node.js test runner, ES2023/2024, View Transitions.
- **Logic Structure**:
  - **Newspaper Metaphor**: Primary export at top; helpers follow in execution sequence.
  - **Organization**: Localize file-specific components; move large strings/prompts to constants.
- **Constraints**:
  - No manual reformatting. Use tools like `npm run format/lint`.
  - No standalone example files. All code must be production-ready and integrated into the system.

## 4. Documentation & Comments

- **In-Code Focus**: Document logic intent within source code, not external docs.
- **Language & Style**: English only. Use single-line `/** */` for types and **TSDoc** (`@param`, `@returns`) for exports.
- **Synchronization**: Maintain strict alignment between code comments and `README.md`.






# ARCHITECTURE BLUEPRINT

> ⚠️ **CRITICAL DIRECTIVE FOR ALL AGENTS** ⚠️
> This section is the **Mind Map** for the system's core structure and is maintained entirely by agents.
> **Mandatory Action**: Update this section immediately if your task alters the tech stack, product logic, or file responsibilities.
>
> **Content Focus & Style**: Keep it lean. Each concept must be 1-2 sentences. Only three categories are permitted:
>
> 1. **Core Tech Stack**: Critical selections and versions.
> 2. **Product Logic**: Core concepts and their interaction patterns.
> 3. **Component Map**: Key components and the specific files responsible for them.
>
> Failure to maintain this skeleton will degrade future agents' navigation and decision-making capabilities.

## Core Tech Stack

- **Language & UI**: Swift 6 (strict concurrency) + SwiftUI, targeting macOS 15+.
- **Build System**: XcodeGen (`project.yml`) generates `TapTick.xcodeproj`; `Makefile` drives all dev/CI tasks.
- **Package Structure**: SPM monorepo — `TapTickKit` library (`Sources/TapTickKit`) + `TapTick` app (`Sources/TapTick`).
- **Auto-Update**: Sparkle 2 (`SPUStandardUpdaterController`) with EdDSA-signed appcast at `https://amio.github.io/TapTick/appcast.xml`.
- **CI**: GitHub Actions (`.github/workflows/build.yml`) — unit tests on every push; archive → notarize → DMG → GitHub Release on `v*` tags.

## Product Logic

- **Global Hotkeys**: Carbon `RegisterEventHotKey` API (no Accessibility permission needed); each `KeyCombo` is registered individually and fires a targeted callback.
- **Shortcuts**: Each `Shortcut` has a `KeyCombo`, a `ShortcutAction` (launch app / run inline script / run script file), and metadata (`isEnabled`, `createdAt`, `modifiedAt`, `lastTriggeredAt`).
- **iCloud Sync**: Optional, uses ubiquity container `iCloud.com.taptick.app`; last-writer-wins merge by UUID + `modifiedAt`; currently disabled pending provisioning profile.
- **Persistence**: Local JSON at `~/Library/Application Support/TapTick/shortcuts.json`; cloud mirror at `iCloud.com.taptick.app/Documents/shortcuts.json`.

## Component Map

- **App entry point**: `Sources/TapTick/App/TapTickApp.swift` — `@main`, MenuBarExtra, Settings Window, environment wiring.
- **Hotkey engine**: `Sources/TapTickKit/Services/HotkeyService.swift` — registration, Carbon event dispatch, `ShortcutExecutor` invocation.
- **Data layer**: `Sources/TapTickKit/Services/ShortcutStore.swift` — CRUD, disk I/O, cloud sync coordination.
- **Cloud sync**: `Sources/TapTickKit/Services/CloudSyncService.swift` — NSMetadataQuery monitoring, upload/download, merge algorithm.
- **Action execution**: `Sources/TapTickKit/Services/ShortcutExecutor.swift` — app toggle/launch, inline script, script file.
- **Settings UI**: `Sources/TapTickKit/Views/SettingsView.swift` (sidebar nav) → `GeneralSettingsView`, `ApplicationsView`, `ScriptsView`.
- **Menu bar UI**: `Sources/TapTickKit/Views/MenuBarView.swift` — dropdown with shortcut rows, settings/quit buttons.
- **Bundle IDs**: App `com.taptick.app`; iCloud container `iCloud.com.taptick.app`.
