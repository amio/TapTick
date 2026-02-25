import SwiftUI

/// General settings pane for the app (launch at login, appearance, data, about).
struct GeneralSettingsView: View {
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(ShortcutStore.self) private var store

    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            // MARK: - Status
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

                if let error = hotkeyService.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(HotkeyService.hasAccessibilityPermission ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(HotkeyService.hasAccessibilityPermission ? "Granted" : "Required")

                        if !HotkeyService.hasAccessibilityPermission {
                            Button("Request") {
                                HotkeyService.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Status")
            }

            // MARK: - Startup & Appearance
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

            // MARK: - Data
            Section {
                LabeledContent("Shortcuts") {
                    Text("\(store.shortcuts.count) configured")
                }

                HStack {
                    Button("Export...") {
                        exportShortcuts()
                    }

                    Button("Import...") {
                        importShortcuts()
                    }
                }
            } header: {
                Text("Data")
            }

            // MARK: - About
            Section {
                LabeledContent("Version") {
                    Text(
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                            as? String ?? "1.0.0")
                }
                LabeledContent("Build") {
                    Text(
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                            ?? "1")
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
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
        panel.nameFieldStringValue = "keymagic-shortcuts.json"

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
