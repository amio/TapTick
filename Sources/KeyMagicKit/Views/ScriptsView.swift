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
                ListTableHeader {
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Hotkey")
                        .frame(width: 80, alignment: .trailing)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(scriptShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                            ScriptRow(
                                shortcut: shortcut,
                                isOdd: !index.isMultiple(of: 2),
                                isSelected: selectedID == shortcut.id
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

// MARK: - Script Row (compact: name + hotkey only)

private struct ScriptRow: View {
    let shortcut: Shortcut
    let isOdd: Bool
    let isSelected: Bool

    var body: some View {
        ListRowContainer(
            isOdd: isOdd,
            accentBackground: isSelected ? Color.accentColor.opacity(0.12) : .clear,
            verticalPadding: 6
        ) {
            // Name + icon
            HStack(spacing: 6) {
                Image(systemName: shortcut.action.systemImage)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(shortcut.name)
                    .lineLimit(1)
                    .fontWeight(.medium)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hotkey badge
            hotkeyBadge
                .frame(width: 80, alignment: .trailing)
        }
        .opacity(shortcut.isEnabled ? 1.0 : 0.6)
    }

    @ViewBuilder
    private var hotkeyBadge: some View {
        if let keyCombo = shortcut.keyCombo {
            Text(keyCombo.displayString)
                .font(.system(.caption2))
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                )
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
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

    private var isValid: Bool {
        !name.isEmpty && !scriptContent.isEmpty
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
                .frame(minWidth: headerActionMinWidth)
            }
            .disabled(scriptContent.isEmpty || isRunning)
            .controlSize(.regular)
            .help("Test run this script")

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
            Text("Script")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $scriptContent)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                )
        }
        .frame(maxHeight: .infinity)
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
