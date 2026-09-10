# Script Generation Providers

## Context & Goals

Scripts currently generates a complete replacement from script comments using Apple Foundation Models. `ScriptEditView` owns the model task; `ScriptTextEditorController` applies the result as a native undoable edit. Edits autosave through `ShortcutStore.updateScript`, which writes the executable file used by hotkeys and menu actions.

Support the locally installed Codex, Claude, Gemini, Copilot, Grok, and OpenCode CLIs alongside the existing OS model. Add a provider selector, an inline editable prompt containing a script placeholder, and a Send action. Show generated content as it becomes available.

The user explicitly accepted native output granularity: stream incremental text when supported; otherwise wait for complete messages or text blocks. No additional server protocol is needed for token-level parity.

## Requirements & Invariants

- Generate has an adjacent dropdown listing OS and all six CLIs. Unavailable providers remain visible but disabled.
- Generate expands a prompt editor within the editing area. Its text area is half the height of the script editor; Send starts generation.
- The default prompt teaches both creation and editing and includes a placeholder for the current script.
- Provider output updates the visible script at its native granularity.
- Existing shebang validation, native Undo/Redo, autosave, external-file reconciliation, explicit execution logs, and hotkey routing remain coherent.
- CLI discovery must work for GUI launches, including installations outside the current fixed script-execution PATH.

## Proposed Solution

### Interaction and prompt

Keep the existing editor mounted. Generate toggles a panel above it, with a plain multiline prompt editor and Send/Stop inside its lower-right corner. Reserve space for the controls so they never cover prompt text. The remaining text-editing height is divided 1:2 between prompt and script. Collapsing the panel preserves the prompt for the selected script. Changing scripts resets the prompt. Remember the selected provider as an app-local preference; never silently send to a different provider when the chosen one becomes unavailable.

Default prompt:

````text
Request:
[Describe what to create or change.]

Current script:
```
{{script}}
```
````

At Send, commit any IME composition and capture the provider, source, and prompt. Expand `{{script}}` once using the captured source; inserted source is never recursively templated. Removing the placeholder deliberately omits the source. Generation accepts empty scripts and missing, malformed, or unavailable shebangs; only script execution requires a valid source shebang.

A hidden instruction defines the output contract: return one complete script with a valid shebang on the first line, an absolute interpreter path (or `/usr/bin/env` with an interpreter name), no leading whitespace or BOM, UTF-8 text, and LF line endings. Preserve an existing valid shebang; otherwise add or repair it to match the script language, defaulting to `#!/bin/zsh` for a new script with no requested language. Omit explanations/Markdown/diffs, and generate text without executing the script or editing files. The result validator requires an installed interpreter and preserves only an originally valid shebang. Provider parameters restrict tools where supported. Prompt formatting is a model instruction, not a guarantee of syntactic correctness.

### Ownership

- `ScriptGenerationProvider` defines fixed provider identities and display names.
- `ScriptGenerationService` owns availability discovery, invocation configuration, Foundation Models streaming, and the one active generation task. It publishes text snapshots and a terminal result under `@MainActor` isolation.
- A dedicated CLI process boundary owns argv/stdin, independent stdout/stderr capture, bounded buffering, timeout, and cancellation. It does not use `ScriptRunner`: that service deliberately merges stdout/stderr and runs non-cancellable user scripts.
- Provider event decoding is pure and testable. It converts each protocol into a current text snapshot and recognizes semantic errors; reasoning, tool activity, diagnostics, and usage never become script source.
- `ScriptTextEditorController` owns a temporary preview transaction. Intermediate content changes native display only, with editing and Undo/Redo disabled. They never update the bound draft. Completion restores the original display internally and applies one `Generate Script` replacement. Cancellation restores the original display without changing history.
- `ScriptEditView` binds controls to the service, forwards preview updates, and preserves the existing save/store boundary. The CLI never receives a managed script path as an editing target.

No new persistence owner or generic plugin framework is introduced.

### Provider discovery

Resolve executables using the GUI environment PATH, a bounded user-shell PATH query, and conventional installation directories, including Homebrew, `~/.local/bin`, `~/.grok/bin`, and `~/.opencode/bin`. Launch the resolved absolute executable directly with argument arrays. Shell startup is used only to discover PATH; prompts are never interpolated into shell commands.

Probe help locally with a timeout to confirm executable identity and required headless/output flags. Cache the detected paths and capabilities in the generation service; refresh on activation and offer a refresh item. OS uses `SystemLanguageModel.default.availability`.

“Available” means installed and compatible, not guaranteed authenticated or funded. Discovery does not make paid model requests or inspect credentials. Authentication, model setup, quota, and network failures appear in the prompt panel after Send. CLI credentials and model defaults remain owned by each CLI.

Local inspection on 2026-09-09 found Codex 0.151.0, Claude 2.1.214, Gemini 0.50.0, Copilot 1.0.70, Grok 1.0.4, and OpenCode 1.18.18. Version/help were checked; this does not establish successful authenticated generation.

### Transport and output

| Provider | Headless output | Adaptation |
| --- | --- | --- |
| OS | `LanguageModelSession.streamResponse` | Each element is a full snapshot, not a delta. |
| Codex | `exec --json` | Accept agent-message updates/completions; use the final agent response, not reasoning or command output. No promise of token-level deltas. |
| Claude | `-p --output-format stream-json --verbose --include-partial-messages` | Accumulate text deltas; reconcile final response without duplicating streamed text. |
| Gemini | `-p --output-format stream-json` | Consume assistant message content, distinguish deltas, and inspect terminal status. |
| Copilot | `-p --output-format json --stream on` | Consume assistant text events and terminal errors. |
| Grok | `-p --output-format streaming-messages-json --include-partial-messages` | Installed CLI exposes Messages-format text deltas and complete messages. |
| OpenCode | `run --format json` | Consume completed text parts and detect error events. |

Use stdin for sizeable prompts where the CLI supports it, otherwise its prompt-file input or direct argv. Run in a disposable neutral working directory, preserving the user's home/authentication environment. Disable interactive approval/input, shell/file tools and custom integrations using the provider's supported configuration. Do not enable blanket approval modes. Temporary configuration affects only this invocation.

Decode JSONL across arbitrary byte boundaries, including split UTF-8 characters. Keep stderr separate and bounded for error reporting. A zero exit code alone is insufficient when the protocol reports failure. Copilot normalizes empty tool lists to defaults, so use the verified source-qualified exclusions `builtin:*,mcp:*,custom:*`. Reject empty responses and obvious format violations; accept only a single outer code fence as a recoverable formatting mistake. Preserve internal whitespace and here-documents. Validate the resulting shebang before committing; do not execute code to validate it.

Throttle preview publication to keep syntax highlighting responsive while always delivering the last snapshot. CLI cancellation must stop the invocation and its children and close pipes; no detached process may keep publishing after cancellation. Bound run duration and captured output.

### Editing and terminal transitions

1. Send snapshots the current source and starts the preview transaction. Existing manual edits can follow their normal save path; generated fragments cannot.
2. During generation, lock source editing, Run, shebang replacement, and script Undo/Redo. Keep Stop available. Hotkeys continue to run the persisted complete script.
3. Success validates the final response, restores the original display, and commits one native undoable replacement. The normal autosave path persists it.
4. Stop, timeout, error, view disappearance, or selection change cancels and restores the original content. Keep the prompt after recoverable failure.
5. External source changes cancel generation before loading the external version. A request identity prevents late callbacks from overwriting another script. Metadata-only store updates do not cancel generation.

## Implementation Plan

1. Add provider definitions, local discovery, and a cancellable process boundary with independent output channels.
2. Add prompt preparation, provider invocations, protocol decoders, and the Foundation Models stream adapter.
3. Add preview/commit/cancel support to the native editor controller and verify native Undo and IME behavior.
4. Replace the embedded Foundation Models generation path with the provider dropdown and prompt panel; integrate cancellation with current view/store lifecycles.
5. Add risk-focused tests for streaming protocols, process cancellation, prompt expansion, and editor transactions; run repository checks and launch the app.
6. Move this document to `docs/implemented` and preserve non-obvious protocol/preview invariants beside their owners.

## Alternatives Considered

- **Diff output:** rejected in favor of full scripts. Diff application requires a baseline, conflict handling, and special handling for incomplete patches without improving this editor's primary flow.
- **Codex app-server / OpenCode server:** unnecessary after the user accepted native CLI output granularity. These would introduce connection/session management only to improve animation granularity.
- **Write streaming text into the bound draft:** rejected because autosave can persist incomplete executable content and native Undo would accumulate fragments.
- **Reuse ScriptRunner:** its non-cancellable, merged-output contract is intentionally different. Changing it would couple generation to unrelated explicit-run and menu-bar behavior.

## Trade-offs & Risks

The most code-intensive work is subprocess lifecycle/output decoding and the editor preview transaction. The UI and provider catalogue are small. CLI releases can change event shapes and parameters, so compatibility is based on required capabilities and protocol tests, with clear failure instead of silent fallback.

Temporary preview means partial output is discarded on failure or Stop. Successful generation automatically applies the result and remains reversible through Undo; no extra Apply step is introduced. Long scripts may exceed the OS model context or the configured CLI model limit; report this without truncating source or switching providers.

CLI-local authentication, model configuration, networking, and installed customizations vary. Invocation controls reduce unwanted agent behavior but are not an operating-system sandbox for arbitrary third-party executables. Do not claim that a hidden prompt enforces isolation. Each adapter's tool restrictions and terminal semantics need focused validation against its supported CLI.

## Validation & Rollout

- Probe installed CLI help/version without model calls; test missing, unexecutable, and incompatible commands with temporary fixtures.
- Test split JSONL/UTF-8, deltas versus snapshots, final-response reconciliation, warnings, protocol failures, empty/truncated output, bounded buffers, and nonzero exit codes.
- Test a fixture subprocess that emits both channels, waits, forks a child, and is cancelled. Ensure the child and pipes terminate.
- Test preview without binding writes, cancellation without history loss, a single generated Undo/Redo operation, IME commit, and stale-request suppression.
- Preserve store/executor tests that establish complete-file persistence and explicit-run isolation.
- Run `make format`, `make lint`, `make test`, and `make run`. Do not automate the app UI; launching hands off manual visual/provider testing to the user.

Persist only the selected provider in app-local preferences. There are no shortcut schema changes, database migrations, import/export changes, or iCloud entitlement changes. Existing scripts are untouched until generation succeeds; older builds ignore the new preference, so rollback requires no data conversion.

## Implementation Validation

`make format`, `make lint`, and `make test` passed (142 tests, including the six protocol variants). The final Debug build and `make run` also succeeded; TapTick Dev was replaced and launched for manual UI validation. Native preview/commit/cancel and preceding Undo history were verified in AppKit unit tests. A real child-process test exposed buffering in `FileHandle.read(upToCount:)`; the implementation now uses immediate `read(2)` chunks on the dispatch pool and verifies process-group cancellation.

Minimal real CLI requests returned valid scripts with Codex and Copilot. Gemini rejected the locally configured account/client tier. OpenCode reached its configured provider but received an HTTP/API server error. Claude retried API failures until the probe deadline; Grok produced no response before the deadline. These are recorded as incomplete end-to-end validation, not successful generation. All six installed tools pass local capability detection after accounting for OpenCode's help on stderr. The application exposes request failures and leaves the original script intact.

## Evidence

- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode) and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
- [Claude programmatic streaming](https://code.claude.com/docs/en/headless) and [CLI reference](https://code.claude.com/docs/en/cli-reference).
- [Gemini headless mode](https://geminicli.com/docs/cli/headless/) and [policy engine](https://geminicli.com/docs/reference/policy-engine/).
- [Copilot CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference).
- [Grok headless mode](https://docs.x.ai/build/cli/headless-scripting), [CLI reference](https://docs.x.ai/build/cli/reference), and installed 1.0.4 `--help` for Messages-format partial events.
- [OpenCode CLI](https://opencode.ai/docs/cli/), [permissions](https://opencode.ai/docs/permissions/), and [run event loop](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/cli/cmd/run.ts).
- [Apple Foundation Models streaming](https://developer.apple.com/videos/play/wwdc2025/286/) and the locally installed FoundationModels Swift interface.
