import SwiftUI

/// General settings pane for operational app behavior such as startup, sync, and hotkeys.
struct GeneralSettingsView: View {
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(ShortcutStore.self) private var store
    @Environment(CloudSyncService.self) private var cloudSync

    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage(ScriptOutputToastSettings.holdDurationKey)
    private var toastHoldDuration = ScriptOutputToastSettings.defaultHoldDuration
    @AppStorage(ScriptExecutionSettings.timeoutKey)
    private var scriptTimeout = ScriptExecutionSettings.defaultTimeout
    @State private var isRecordingSettingsWindowHotkey = false

    var body: some View {
        Form {
            Section("App") {
                appPreferences
                settingsWindowHotkey
            }
            Section("Script Behavior") {
                executionTimeout
                messageDuration
            }
            syncSection
        }
        .settingsFormStyle()
    }

    // MARK: - App Preferences

    private var appPreferences: some View {
        Group {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { _ in loginItemManager.toggle() }
                ))

            Toggle("Show Dock Icon", isOn: $showDockIcon)

            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
        }
    }

    // MARK: - Script Output

    private var executionTimeout: some View {
        LabeledContent("Execution Timeout") {
            HStack(spacing: 8) {
                TextField("Execution Timeout", value: scriptTimeoutBinding, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .accessibilityLabel("Execution Timeout in seconds")
                Text("s")
                    .foregroundStyle(.secondary)
            }
        }
        .help(
            "Stop scripts after 1–3600 seconds. Applies to new runs, including menu bar refreshes. Default: 60 seconds."
        )
    }

    private var scriptTimeoutBinding: Binding<TimeInterval> {
        Binding(
            get: { ScriptExecutionSettings.normalizedTimeout(scriptTimeout) },
            set: { scriptTimeout = ScriptExecutionSettings.normalizedTimeout($0) }
        )
    }

    private var messageDuration: some View {
        Group {
            LabeledContent("Message Duration") {
                HStack(spacing: 12) {
                    Slider(
                        value: toastHoldDurationBinding,
                        in: ScriptOutputToastSettings.holdDurationRange
                    )
                    .accessibilityLabel("Message Duration")
                    .frame(width: 200)

                    Text("\(toastHoldDurationBinding.wrappedValue.formatted(.number.precision(.fractionLength(1)))) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .help("Time each script output message stays visible before the next one appears.")
    }

    private var toastHoldDurationBinding: Binding<TimeInterval> {
        Binding(
            get: { ScriptOutputToastSettings.normalizedHoldDuration(toastHoldDuration) },
            set: { toastHoldDuration = ScriptOutputToastSettings.normalizedHoldDuration($0) }
        )
    }

    // MARK: - Settings Window Hotkey

    private var settingsWindowHotkey: some View {
        Group {
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
        }
        .help("Shows or hides the TapTick settings window from anywhere.")
    }

    // MARK: - iCloud Sync

    private var syncSection: some View {
        Section {
            if cloudSync.isAvailable {
                LabeledContent("Sync via iCloud") {
                    HStack(spacing: 12) {
                        if cloudSync.isEnabled {
                            syncStatus
                        }
                        Toggle(
                            "Sync via iCloud",
                            isOn: Binding(
                                get: { cloudSync.isEnabled },
                                set: { newValue in
                                    cloudSync.isEnabled = newValue
                                    if newValue { store.performFullSync() }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                if cloudSync.isEnabled {
                    HStack(spacing: 12) {
                        if let lastSync = cloudSync.lastSyncDate {
                            HStack(spacing: 6) {
                                Text("Last Synced")
                                Text(lastSync, style: .relative)
                                    .monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Not synced yet")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sync Now") { store.performFullSync() }
                            .controlSize(.small)
                    }

                    if let error = cloudSync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    if cloudSync.accountChanged {
                        Button("Merge Local Shortcuts with Current iCloud Account") {
                            cloudSync.useCurrentAccount()
                        }
                    }
                }
            } else {
                LabeledContent("iCloud") {
                    HStack(spacing: 8) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("Not Available")
                    }
                }
                Text(cloudSync.lastError ?? "Sign in to iCloud in System Settings to enable sync across your Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud Sync")
        }
    }

    private var syncStatus: some View {
        HStack(spacing: 6) {
            if cloudSync.isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            } else if cloudSync.lastError != nil {
                Text("Needs attention")
            } else if cloudSync.hasPendingChanges || cloudSync.lastSyncDate == nil {
                Text("Waiting to sync")
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Up to date")
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

}

/// Compact listener health and recovery in the General pane's toolbar.
struct HotkeyListenerStatus: View {
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(ShortcutStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Text(hotkeyService.isListening ? "Hotkey Listener Active" : "Hotkey Listener Inactive")
                .font(.body)
                .foregroundStyle(.secondary)
            Circle()
                .fill(hotkeyService.isListening ? .green : .red)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            if !hotkeyService.isListening {
                Button("Start") {
                    hotkeyService.start(store: store)
                }
                .controlSize(.small)
            }
        }
        .help("Whether the global hotkey event listener is running.")
    }
}
