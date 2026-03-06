import SwiftUI

/// General settings pane for the app (launch at login, appearance, data & sync, updates).
struct GeneralSettingsView: View {
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(ShortcutStore.self) private var store
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(UpdateService.self) private var updateService

    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            statusSection
            startupSection
            dataAndSyncSection
            updatesSection
            versionFooterSection
        }
        .formStyle(.grouped)
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
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { _ in loginItemManager.toggle() }
            ))

            Toggle("Show Dock Icon", isOn: $showDockIcon)
                .onChange(of: showDockIcon) { _, newValue in
                    applyDockIconPolicy(visible: newValue)
                }

            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
        } header: {
            Text("Startup & Appearance")
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
                    Button("Export...") { exportShortcuts() }
                    Button("Import...") { importShortcuts() }
                }
            } label: {
                Text("\(appShortcutCount) app\(appShortcutCount == 1 ? "" : "s"), \(scriptShortcutCount) script\(scriptShortcutCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            // iCloud sync toggle or unavailable notice
            if cloudSync.isAvailable {
                Toggle("Sync via iCloud", isOn: Binding(
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
                                Text("Syncing...")
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

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            Toggle("Automatically Check for Updates", isOn: Binding(
                get: { updateService.automaticallyChecksForUpdates },
                set: { updateService.automaticallyChecksForUpdates = $0 }
            ))

            LabeledContent("Last Checked") {
                HStack(spacing: 12) {
                    if let lastCheck = updateService.lastUpdateCheckDate {
                        Text(lastCheck, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                    Button("Check for Updates…") {
                        updateService.checkForUpdates()
                    }
                    .controlSize(.small)
                    .disabled(!updateService.canCheckForUpdates)
                }
            }
        } header: {
            Text("Updates")
        }
    }

    // MARK: - Version Footer

    private var versionFooterSection: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return Section {
            Text("TapTick \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Dock Icon

    private func applyDockIconPolicy(visible: Bool) {
        if visible {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
            // Ensure window stays visible after switching to accessory
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Export / Import

    private func exportShortcuts() {
        guard let data = try? store.exportData() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "taptick-shortcuts.json"

        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importShortcuts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url) {
                try? store.importData(data)
            }
        }
    }
}
