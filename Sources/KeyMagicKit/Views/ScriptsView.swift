import SwiftUI

/// The Scripts settings view: manages script-type shortcuts with add/edit/test-run.
struct ScriptsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService

    @State private var showingAddSheet = false
    @State private var editingShortcut: Shortcut?
    @State private var showingDeleteConfirmation = false
    @State private var deletingShortcutID: UUID?
    @State private var runOutput: String?
    @State private var runningShortcutID: UUID?
    @State private var showingRunOutput = false

    /// Only script-type shortcuts.
    private var scriptShortcuts: [Shortcut] {
        store.shortcuts.filter { shortcut in
            switch shortcut.action {
            case .runScript, .runScriptFile: return true
            case .launchApp: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scripts")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(scriptShortcuts.count) scripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Script", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if scriptShortcuts.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("No Scripts", systemImage: "terminal")
                } description: {
                    Text("Add a script shortcut to run shell commands with a hotkey.")
                } actions: {
                    Button("Add Script") {
                        showingAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                // Table header
                ListTableHeader {
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Script / File")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Shell")
                        .frame(width: 60, alignment: .center)
                    Text("Hotkey")
                        .frame(width: 120, alignment: .center)
                    Text("Enabled")
                        .frame(width: 70, alignment: .center)
                    Text("Actions")
                        .frame(width: 100, alignment: .center)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(scriptShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                            ScriptRow(
                                shortcut: shortcut,
                                isOdd: index.isMultiple(of: 2) == false,
                                isRunning: runningShortcutID == shortcut.id,
                                onEdit: { editingShortcut = shortcut },
                                onDelete: {
                                    deletingShortcutID = shortcut.id
                                    showingDeleteConfirmation = true
                                },
                                onToggleEnabled: {
                                    store.toggleEnabled(id: shortcut.id)
                                    hotkeyService.restart(store: store)
                                },
                                onTestRun: { testRun(shortcut) }
                            )
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                ScriptEditView(mode: .add) { shortcut in
                    store.add(shortcut)
                    hotkeyService.restart(store: store)
                }
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            NavigationStack {
                ScriptEditView(mode: .edit(shortcut)) { updated in
                    store.update(updated)
                    hotkeyService.restart(store: store)
                }
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

    // MARK: - Test Run

    private func testRun(_ shortcut: Shortcut) {
        runningShortcutID = shortcut.id
        runOutput = nil

        Task.detached {
            let output = await Self.executeForOutput(action: shortcut.action)
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

// MARK: - Script Row

private struct ScriptRow: View {
    let shortcut: Shortcut
    let isOdd: Bool
    let isRunning: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: () -> Void
    let onTestRun: () -> Void

    var body: some View {
        ListRowContainer(isOdd: isOdd, verticalPadding: 8) {
            // Name
            HStack(spacing: 8) {
                Image(systemName: shortcut.action.systemImage)
                    .foregroundStyle(shortcut.isEnabled ? .primary : .tertiary)
                Text(shortcut.name)
                    .lineLimit(1)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Script preview / file path
            Text(scriptPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Shell
            Text(shellName)
                .font(.caption)
                .frame(width: 60, alignment: .center)

            // Hotkey
            Text(shortcut.keyCombo.displayString)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                )
                .frame(width: 120, alignment: .center)

            // Enabled
            Toggle("", isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in onToggleEnabled() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 70, alignment: .center)

            // Actions
            HStack(spacing: 8) {
                Button {
                    onTestRun()
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.circle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(isRunning)
                .help("Test Run")

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit")

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
                .help("Delete")
            }
            .frame(width: 100, alignment: .center)
        }
        .opacity(shortcut.isEnabled ? 1.0 : 0.7)
    }

    private var scriptPreview: String {
        switch shortcut.action {
        case .runScript(let script, _):
            let preview = script.prefix(60)
            return script.count > 60 ? "\(preview)..." : String(preview)
        case .runScriptFile(let path, _):
            return path
        case .launchApp:
            return ""
        }
    }

    private var shellName: String {
        switch shortcut.action {
        case .runScript(_, let shell), .runScriptFile(_, let shell):
            return shell.displayName
        case .launchApp:
            return ""
        }
    }
}

// MARK: - Script Edit View (Add / Edit)

struct ScriptEditView: View {
    enum Mode: Identifiable {
        case add
        case edit(Shortcut)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let s): return s.id.uuidString
            }
        }
    }

    let mode: Mode
    let onSave: (Shortcut) -> Void

    @Environment(ShortcutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var keyCombo: KeyCombo?
    @State private var isEnabled = true
    @State private var useScriptFile = false
    @State private var scriptContent = ""
    @State private var scriptFilePath = ""
    @State private var shellType: ShortcutAction.ShellType = .zsh
    @State private var showConflictWarning = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingShortcut: Shortcut? {
        if case .edit(let s) = mode { return s }
        return nil
    }

    private var isValid: Bool {
        !name.isEmpty && keyCombo != nil &&
            (useScriptFile ? !scriptFilePath.isEmpty : !scriptContent.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Deploy Script"))

                KeyRecorderView(keyCombo: $keyCombo) { combo in
                    showConflictWarning = store.hasConflict(
                        keyCombo: combo,
                        excludingID: existingShortcut?.id
                    )
                }

                if showConflictWarning {
                    Label(
                        "This shortcut conflicts with another binding.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            } header: {
                Text("Shortcut")
            }

            Section {
                Toggle("Use script file", isOn: $useScriptFile)

                if useScriptFile {
                    HStack {
                        TextField("Script path", text: $scriptFilePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            browseScriptFile()
                        }
                    }
                } else {
                    TextEditor(text: $scriptContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 250)
                        .border(.quaternary)
                }

                Picker("Shell", selection: $shellType) {
                    ForEach(ShortcutAction.ShellType.allCases, id: \.self) { shell in
                        Text(shell.displayName).tag(shell)
                    }
                }
            } header: {
                Text("Script")
            }

            Section {
                Toggle("Enabled", isOn: $isEnabled)
            } header: {
                Text("Options")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") {
                    save()
                    dismiss()
                }
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .navigationTitle(isEditing ? "Edit Script" : "New Script")
        .onAppear {
            if let s = existingShortcut {
                loadFrom(s)
            }
        }
    }

    private func save() {
        guard let keyCombo else { return }

        let action: ShortcutAction
        if useScriptFile {
            action = .runScriptFile(path: scriptFilePath, shell: shellType)
        } else {
            action = .runScript(script: scriptContent, shell: shellType)
        }

        if var existing = existingShortcut {
            existing.name = name
            existing.keyCombo = keyCombo
            existing.action = action
            existing.isEnabled = isEnabled
            onSave(existing)
        } else {
            let shortcut = Shortcut(
                name: name,
                keyCombo: keyCombo,
                action: action,
                isEnabled: isEnabled
            )
            onSave(shortcut)
        }
    }

    private func loadFrom(_ shortcut: Shortcut) {
        name = shortcut.name
        keyCombo = shortcut.keyCombo
        isEnabled = shortcut.isEnabled

        switch shortcut.action {
        case .runScript(let script, let shell):
            scriptContent = script
            shellType = shell
            useScriptFile = false
        case .runScriptFile(let path, let shell):
            scriptFilePath = path
            shellType = shell
            useScriptFile = true
        case .launchApp:
            break
        }
    }

    private func browseScriptFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a script file"

        if panel.runModal() == .OK, let url = panel.url {
            scriptFilePath = url.path
        }
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
