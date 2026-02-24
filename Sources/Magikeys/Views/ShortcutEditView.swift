import SwiftUI

/// The edit/create form for a shortcut. Presented as a sheet.
struct ShortcutEditView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// If editing an existing shortcut, this is set; otherwise it's a new shortcut.
    var editingShortcut: Shortcut?

    @State private var name: String = ""
    @State private var keyCombo: KeyCombo?
    @State private var actionType: ActionType = .launchApp
    @State private var isEnabled: Bool = true

    // App action fields
    @State private var appBundleID: String = ""
    @State private var appName: String = ""

    // Script action fields
    @State private var scriptContent: String = ""
    @State private var scriptFilePath: String = ""
    @State private var shellType: ShortcutAction.ShellType = .zsh
    @State private var useScriptFile: Bool = false

    // Validation
    @State private var showConflictWarning = false

    enum ActionType: String, CaseIterable {
        case launchApp = "Launch App"
        case runScript = "Run Script"
    }

    var isValid: Bool {
        !name.isEmpty && keyCombo != nil && isActionValid
    }

    private var isActionValid: Bool {
        switch actionType {
        case .launchApp:
            return !appBundleID.isEmpty
        case .runScript:
            return useScriptFile ? !scriptFilePath.isEmpty : !scriptContent.isEmpty
        }
    }

    var body: some View {
        Form {
            // MARK: - Basic Info
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Open Terminal"))

                KeyRecorderView(keyCombo: $keyCombo) { combo in
                    showConflictWarning = store.hasConflict(
                        keyCombo: combo,
                        excludingID: editingShortcut?.id
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

            // MARK: - Action
            Section {
                Picker("Action Type", selection: $actionType) {
                    ForEach(ActionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                switch actionType {
                case .launchApp:
                    AppPickerButton(
                        selectedBundleID: $appBundleID,
                        selectedAppName: $appName
                    )

                case .runScript:
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
                            .frame(minHeight: 100, maxHeight: 200)
                            .border(.quaternary)
                    }

                    Picker("Shell", selection: $shellType) {
                        ForEach(ShortcutAction.ShellType.allCases, id: \.self) { shell in
                            Text(shell.displayName).tag(shell)
                        }
                    }
                }
            } header: {
                Text("Action")
            }

            // MARK: - Options
            Section {
                Toggle("Enabled", isOn: $isEnabled)
            } header: {
                Text("Options")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editingShortcut != nil ? "Save" : "Add") {
                    save()
                    dismiss()
                }
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .navigationTitle(editingShortcut != nil ? "Edit Shortcut" : "New Shortcut")
        .onAppear {
            if let shortcut = editingShortcut {
                loadFromShortcut(shortcut)
            }
        }
    }

    // MARK: - Actions

    private func save() {
        guard let keyCombo else { return }

        let action: ShortcutAction
        switch actionType {
        case .launchApp:
            action = .launchApp(bundleIdentifier: appBundleID, appName: appName)
        case .runScript:
            if useScriptFile {
                action = .runScriptFile(path: scriptFilePath, shell: shellType)
            } else {
                action = .runScript(script: scriptContent, shell: shellType)
            }
        }

        if var existing = editingShortcut {
            existing.name = name
            existing.keyCombo = keyCombo
            existing.action = action
            existing.isEnabled = isEnabled
            store.update(existing)
        } else {
            let shortcut = Shortcut(
                name: name,
                keyCombo: keyCombo,
                action: action,
                isEnabled: isEnabled
            )
            store.add(shortcut)
        }
    }

    private func loadFromShortcut(_ shortcut: Shortcut) {
        name = shortcut.name
        keyCombo = shortcut.keyCombo
        isEnabled = shortcut.isEnabled

        switch shortcut.action {
        case .launchApp(let bundleID, let appN):
            actionType = .launchApp
            appBundleID = bundleID
            appName = appN
        case .runScript(let script, let shell):
            actionType = .runScript
            scriptContent = script
            shellType = shell
            useScriptFile = false
        case .runScriptFile(let path, let shell):
            actionType = .runScript
            scriptFilePath = path
            shellType = shell
            useScriptFile = true
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
