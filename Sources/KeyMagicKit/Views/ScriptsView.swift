import FoundationModels
import SwiftUI

/// The Scripts settings view: manages script-type shortcuts.
/// Fixed two-panel layout: 240px list on the left, edit panel on the right.
struct ScriptsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService

    @State private var selectedID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var deletingShortcutID: UUID?
    @State private var runOutput: String?
    @State private var runningShortcutID: UUID?
    @State private var showingRunOutput = false
    @State private var recordingShortcutID: UUID?

    /// Only script-type shortcuts (runScript / runScriptFile).
    private var scriptShortcuts: [Shortcut] {
        store.shortcuts.filter { shortcut in
            switch shortcut.action {
            case .runScript, .runScriptFile: return true
            case .launchApp: return false
            }
        }
    }

    /// The currently selected shortcut (derived from selectedID).
    private var selectedShortcut: Shortcut? {
        scriptShortcuts.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: script list (fixed 260px)
            scriptListPanel
                .frame(width: 260)

            Divider()

            // Right: edit panel (fills remaining width)
            editPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Scripts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addNewScript()
                } label: {
                    Label("Add Script", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingRunOutput) {
            RunOutputView(output: runOutput ?? "")
        }
        .confirmationDialog(
            "Delete Script?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingShortcutID {
                    // Clear selection if deleting the selected item
                    if selectedID == id { selectedID = nil }
                    store.remove(id: id)
                    hotkeyService.restart(store: store)
                    deletingShortcutID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Left Panel: Script List

    @ViewBuilder
    private var scriptListPanel: some View {
        VStack(spacing: 0) {
            if scriptShortcuts.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("No Scripts", systemImage: "terminal")
                } description: {
                    Text("Add a script to get started.")
                } actions: {
                    Button("Add Script") { addNewScript() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer()
            } else {
                // Header
                ListTableHeader(
                    backgroundStyle: AnyShapeStyle(Color(.windowBackgroundColor)),
                    content: {
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Hotkey")
                        .frame(width: 100, alignment: .leading)
                })

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(scriptShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                            ScriptRow(
                                shortcut: shortcut,
                                isOdd: !index.isMultiple(of: 2),
                                isSelected: selectedID == shortcut.id,
                                isRecording: recordingShortcutID == shortcut.id,
                                onStartRecording: {
                                    recordingShortcutID = shortcut.id
                                },
                                onRecordKey: { combo in
                                    bindHotkey(combo, to: shortcut)
                                    recordingShortcutID = nil
                                },
                                onCancelRecording: {
                                    recordingShortcutID = nil
                                },
                                onClearHotkey: {
                                    clearHotkey(for: shortcut)
                                },
                                checkConflict: { combo in
                                    store.hasConflict(keyCombo: combo, excludingID: shortcut.id)
                                }
                            )
                            .onTapGesture { selectedID = shortcut.id }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Right Panel: Edit / Placeholder

    @ViewBuilder
    private var editPanel: some View {
        if let shortcut = selectedShortcut {
            ScriptEditView(
                shortcut: shortcut,
                isRunning: runningShortcutID == shortcut.id,
                onSave: { updated in
                    store.update(updated)
                    hotkeyService.restart(store: store)
                },
                onRun: { script, shell in
                    testRun(id: shortcut.id, script: script, shell: shell)
                },
                onDelete: {
                    deletingShortcutID = shortcut.id
                    showingDeleteConfirmation = true
                }
            )
            .id(shortcut.id)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "cursorarrow.click")
            } description: {
                Text("Select a script from the list to edit, or add a new one.")
            }
        }
    }

    // MARK: - Actions

    private func addNewScript() {
        let newShortcut = Shortcut(
            name: "Untitled Script",
            keyCombo: nil,
            action: .runScript(script: "", shell: .zsh),
            isEnabled: true
        )
        store.add(newShortcut)
        hotkeyService.restart(store: store)
        selectedID = newShortcut.id
    }

    private func bindHotkey(_ combo: KeyCombo, to shortcut: Shortcut) {
        var updated = shortcut
        updated.keyCombo = combo
        store.update(updated)
        hotkeyService.restart(store: store)
    }

    private func clearHotkey(for shortcut: Shortcut) {
        var updated = shortcut
        updated.keyCombo = nil
        store.update(updated)
        hotkeyService.restart(store: store)
    }

    private func testRun(id: UUID, script: String, shell: ShortcutAction.ShellType) {
        runningShortcutID = id
        runOutput = nil

        let action = ShortcutAction.runScript(script: script, shell: shell)
        Task.detached {
            let output = await Self.executeForOutput(action: action)
            await MainActor.run {
                runOutput = output
                runningShortcutID = nil
                showingRunOutput = true
            }
        }
    }

    private static func executeForOutput(action: ShortcutAction) async -> String {
        let process = Process()
        let pipe = Pipe()

        switch action {
        case .runScript(let script, let shell):
            process.executableURL = URL(fileURLWithPath: shell.rawValue)
            process.arguments = ["-c", script]
        case .runScriptFile(let path, let shell):
            let expandedPath = NSString(string: path).expandingTildeInPath
            process.executableURL = URL(fileURLWithPath: shell.rawValue)
            process.arguments = [expandedPath]
        case .launchApp:
            return "Error: Not a script action."
        }

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let status = process.terminationStatus
            if status != 0 {
                return output + "\n[Exit code: \(status)]"
            }
            return output.isEmpty ? "(No output)" : output
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Script Row (compact: name + hotkey cell with recording support)

private struct ScriptRow: View {
    let shortcut: Shortcut
    let isOdd: Bool
    let isSelected: Bool
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecordKey: (KeyCombo) -> Void
    let onCancelRecording: () -> Void
    let onClearHotkey: () -> Void
    var checkConflict: ((KeyCombo) -> Bool)?

    var body: some View {
        ListRowContainer(
            isOdd: isOdd,
            accentBackground: isSelected ? Color.accentColor.opacity(0.12) : .clear,
            verticalPadding: 6
        ) {
            // Name + icon + availability warning
            HStack(spacing: 6) {
                Image(systemName: shortcut.action.systemImage)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(shortcut.name)
                    .lineLimit(1)
                    .fontWeight(.medium)
                    .font(.callout)

                // Warn when a script file doesn't exist on this Mac (e.g. synced from another device).
                if !shortcut.isAvailableOnThisDevice {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Script file not found on this Mac")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hotkey cell with recording / edit / delete
            HotkeyCellView(
                keyCombo: shortcut.keyCombo,
                isRecording: isRecording,
                onStartRecording: onStartRecording,
                onRecordKey: onRecordKey,
                onCancelRecording: onCancelRecording,
                onClearHotkey: onClearHotkey,
                checkConflict: checkConflict
            )
            .frame(width: 100, alignment: .leading)
        }
        .opacity(shortcut.isEnabled ? 1.0 : 0.6)
    }
}

// MARK: - Script Edit View (always-visible right panel)

struct ScriptEditView: View {
    let shortcut: Shortcut
    let isRunning: Bool
    let onSave: (Shortcut) -> Void
    let onRun: (String, ShortcutAction.ShellType) -> Void
    let onDelete: () -> Void

    @State private var name = ""
    @State private var scriptContent = ""
    @State private var shellType: ShortcutAction.ShellType = .zsh
    @State private var hasUnsavedChanges = false

    // AI generation state
    @State private var isGenerating = false
    @State private var generationError: String?

    private var isValid: Bool {
        !name.isEmpty && !scriptContent.isEmpty
    }

    /// Whether the on-device Foundation Models framework is usable on this system.
    private var isAIAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// Human-readable reason when AI generation is unavailable.
    private var aiUnavailableReason: String? {
        guard #available(macOS 26, *) else {
            return "Requires macOS 26 or later"
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence"
            case .modelNotReady:
                return "Apple Intelligence model is not ready — check Settings"
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in System Settings"
            @unknown default:
                return "Apple Intelligence is not available"
            }
        @unknown default:
            return "Apple Intelligence is not available"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: title + action buttons
            headerBar

            Divider()

            // Form body
            VStack(alignment: .leading, spacing: 12) {
                nameField
                shellPicker
                scriptEditor

                // Inline error banner for AI generation failures
                if let error = generationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") { generationError = nil }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadFrom(shortcut) }
        .onChange(of: name) { hasUnsavedChanges = true }
        .onChange(of: scriptContent) { hasUnsavedChanges = true }
        .onChange(of: shellType) { hasUnsavedChanges = true }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Edit Script")
                .font(.headline)

            Spacer()

            // Delete button
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .frame(minWidth: headerActionMinWidth)
            .controlSize(.regular)
            .help("Delete this script")

            Divider()
                .frame(height: 16)

            // Save button
            Button {
                save()
            } label: {
                Text("Save")
            }
            .disabled(!isValid || !hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .frame(minWidth: headerActionMinWidth)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // Keep header action buttons aligned and stable in width.
    private var headerActionMinWidth: CGFloat { 60 }

    // MARK: - Form Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. Deploy Script", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var shellPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shell")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $shellType) {
                ForEach(ShortcutAction.ShellType.allCases, id: \.self) { shell in
                    Text(shell.displayName).tag(shell)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label row: "Script" caption on the left, action buttons on the right
            HStack(alignment: .center) {
                Text("Script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                editorActionButtons
            }
            TextEditor(text: $scriptContent)
                .font(.system(.body, design: .monospaced))
                // Inner padding so text doesn't hug the border
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                )
        }
        .frame(maxHeight: .infinity)
    }

    /// Generate and Run buttons sitting above the editor's top-right corner.
    private var editorActionButtons: some View {
        HStack(spacing: 6) {
            // AI Generate button — disabled with an instant tooltip when unavailable
            Button {
                handleGenerate()
            } label: {
                ZStack {
                    Label("Generate", systemImage: "sparkles")
                        .opacity(isGenerating ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isGenerating ? 1 : 0)
                }
            }
            .disabled(!isAIAvailable || isGenerating || isRunning)
            .controlSize(.small)
            .immediateHelp(aiUnavailableReason ?? "Generate script from comments using Apple Intelligence")

            // Run button — executes the current editor content directly
            Button {
                onRun(scriptContent, shellType)
            } label: {
                ZStack {
                    Label("Run", systemImage: "play.fill")
                        .opacity(isRunning ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isRunning ? 1 : 0)
                }
            }
            .disabled(scriptContent.isEmpty || isRunning)
            .controlSize(.small)
            .help("Test run this script")
        }
    }

    // MARK: - Logic

    private func save() {
        let action = ShortcutAction.runScript(script: scriptContent, shell: shellType)
        var updated = shortcut
        updated.name = name
        updated.action = action
        onSave(updated)
        hasUnsavedChanges = false
    }

    private func loadFrom(_ shortcut: Shortcut) {
        name = shortcut.name

        switch shortcut.action {
        case .runScript(let script, let shell):
            scriptContent = script
            shellType = shell
        case .runScriptFile(let path, let shell):
            // Legacy: show file path as placeholder
            scriptContent = "# Script file: \(path)\n"
            shellType = shell
        case .launchApp:
            break
        }

        // Reset dirty flag after loading
        hasUnsavedChanges = false
    }

    // MARK: - AI Generation

    /// Inserts a starter comment template when the editor is empty,
    /// otherwise sends the current content to the on-device model for code generation.
    private func handleGenerate() {
        generationError = nil

        // Empty editor: insert a starter template so the user knows how to use the feature.
        let trimmed = scriptContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            scriptContent = scriptTemplateForShell(shellType)
            return
        }

        guard #available(macOS 26, *) else { return }
        generateWithModel()
    }

    /// Calls the on-device Foundation Model to generate script code from the user's comments.
    @available(macOS 26, *)
    private func generateWithModel() {
        let shell = shellType
        let input = scriptContent
        isGenerating = true
        generationError = nil

        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                        You are a shell script generator. The user provides comments \
                        describing what they want the script to do. Generate ONLY the \
                        script code. Do NOT wrap output in markdown code fences. Preserve \
                        the user's original comments in-place and add implementation code \
                        right after each relevant comment block. Use \(shell.displayName) \
                        syntax. Output must be valid, runnable shell code.
                        """
                )

                let prompt = """
                    Based on the following commented instructions, generate a complete \
                    \(shell.displayName) script:

                    \(input)
                    """

                let response = try await session.respond(to: prompt)
                scriptContent = response.content
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    /// Returns a starter comment template that teaches the user how to use AI generation.
    private func scriptTemplateForShell(_ shell: ShortcutAction.ShellType) -> String {
        let shebang = "#!\(shell.rawValue)"
        return """
            \(shebang)

            # Describe what you want this script to do.
            # Write your instructions as comments, then click "Generate" again
            # to let Apple Intelligence generate the code for you.
            #
            # Example:
            #   List all .log files in /var/log that are older than 7 days,
            #   then print their total size in human-readable format.

            """
    }
}

// MARK: - Run Output View

private struct RunOutputView: View {
    let output: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Script Output")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}
