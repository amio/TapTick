import SwiftUI
import UniformTypeIdentifiers

/// General settings pane for operational app behavior such as startup, sync, and hotkeys.
struct GeneralSettingsView: View {
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(ShortcutStore.self) private var store
    @Environment(CloudSyncService.self) private var cloudSync

    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var isRecordingSettingsWindowHotkey = false
    @State private var isImportingShortcuts = false
    @State private var isExportingShortcuts = false
    @State private var exportDocument: ShortcutExportDocument?
    @State private var fileOperationError = ""
    @State private var isShowingFileOperationError = false

    var body: some View {
        Form {
            statusSection
            startupSection
            globalHotkeysSection
            dataAndSyncSection
        }
        .settingsFormStyle()
        .fileImporter(
            isPresented: $isImportingShortcuts,
            allowedContentTypes: [.json]
        ) { result in
            importShortcuts(from: result)
        }
        .fileExporter(
            isPresented: $isExportingShortcuts,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "taptick-shortcuts"
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                presentFileOperationError(error)
            }
        }
        .alert("Shortcut File Error", isPresented: $isShowingFileOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileOperationError)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Hotkey Listener") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hotkeyService.isListening ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(hotkeyService.isListening ? "Active" : "Inactive")

                    if !hotkeyService.isListening {
                        Button("Start") {
                            hotkeyService.start(store: store)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Startup & Appearance

    private var startupSection: some View {
        Section {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { _ in loginItemManager.toggle() }
                ))

            Toggle("Show Dock Icon", isOn: $showDockIcon)

            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
        } header: {
            Text("Startup & Appearance")
        }
    }

    // MARK: - Global Hotkeys

    private var globalHotkeysSection: some View {
        Section {
            LabeledContent("Toggle Settings Window") {
                HStack(spacing: 8) {
                    HotkeyBindingControl(
                        keyCombo: hotkeyService.settingsWindowHotkey,
                        isRecording: isRecordingSettingsWindowHotkey,
                        onStartRecording: {
                            isRecordingSettingsWindowHotkey = true
                        },
                        onRecordKey: { combo in
                            hotkeyService.updateSettingsWindowHotkey(combo)
                            isRecordingSettingsWindowHotkey = false
                        },
                        onCancelRecording: {
                            isRecordingSettingsWindowHotkey = false
                        },
                        checkConflict: { combo in
                            hotkeyService.hasConflict(
                                keyCombo: combo,
                                excludingSettingsWindowHotkey: true
                            )
                        },
                        emptyTitle: "Record Hotkey"
                    )

                    Button("Default") {
                        hotkeyService.restoreDefaultSettingsWindowHotkey()
                    }
                    .controlSize(.small)
                    .disabled(hotkeyService.settingsWindowHotkey == HotkeyService.defaultSettingsWindowHotkey)
                }
            }

            Text("Shows or hides the TapTick settings window from anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Global Hotkeys")
        }
    }

    // MARK: - Data & Sync

    private var appShortcutCount: Int {
        store.shortcuts.filter {
            if case .launchApp = $0.action { return true }
            return false
        }.count
    }

    private var scriptShortcutCount: Int {
        store.shortcuts.filter {
            switch $0.action {
            case .runScript, .runScriptFile: return true
            case .launchApp: return false
            }
        }.count
    }

    /// Single section combining shortcut counts, import/export, and iCloud sync.
    private var dataAndSyncSection: some View {
        Section {
            // Shortcut counts + Export/Import in one row
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Export…") { prepareShortcutExport() }
                    Button("Import…") { isImportingShortcuts = true }
                }
            } label: {
                Text(
                    "\(appShortcutCount) app\(appShortcutCount == 1 ? "" : "s"), \(scriptShortcutCount) script\(scriptShortcutCount == 1 ? "" : "s")"
                )
                .foregroundStyle(.secondary)
            }

            // iCloud sync toggle or unavailable notice
            if cloudSync.isAvailable {
                Toggle(
                    "Sync via iCloud",
                    isOn: Binding(
                        get: { cloudSync.isEnabled },
                        set: { newValue in
                            cloudSync.isEnabled = newValue
                            if newValue { store.performFullSync() }
                        }
                    ))

                if cloudSync.isEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if cloudSync.isSyncing {
                                ProgressView().controlSize(.small)
                                Text("Syncing…")
                            } else {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text("Up to date")
                            }
                        }
                    }

                    if let lastSync = cloudSync.lastSyncDate {
                        LabeledContent("Last Synced") {
                            Text(lastSync, style: .relative).foregroundStyle(.secondary)
                        }
                    }

                    if let error = cloudSync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    Button("Sync Now") { store.performFullSync() }.controlSize(.small)
                }
            } else {
                LabeledContent("iCloud") {
                    HStack(spacing: 8) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("Not Available")
                    }
                }
                Text("Sign in to iCloud in System Settings to enable sync across your Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Data & Sync")
        }
    }

    // MARK: - Export / Import

    private func prepareShortcutExport() {
        do {
            exportDocument = ShortcutExportDocument(data: try store.exportData())
            isExportingShortcuts = true
        } catch {
            presentFileOperationError(error)
        }
    }

    private func importShortcuts(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try store.importData(Data(contentsOf: url))
        } catch {
            presentFileOperationError(error)
        }
    }

    private func presentFileOperationError(_ error: Error) {
        fileOperationError = error.localizedDescription
        isShowingFileOperationError = true
    }
}

private struct ShortcutExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
