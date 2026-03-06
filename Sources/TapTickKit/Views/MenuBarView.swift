import AppKit
import SwiftUI

/// The menu bar dropdown view.
public struct MenuBarView: View {
    public init() {}

    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(UpdateService.self) private var updateService
    @Environment(\.openWindow) private var openWindow

    private var appShortcuts: [Shortcut] {
        store.shortcuts.filter { $0.isEnabled && $0.action.isLaunchApp }
    }

    private var scriptShortcuts: [Shortcut] {
        store.shortcuts.filter { $0.isEnabled && !$0.action.isLaunchApp }
    }

    public var body: some View {
        VStack(spacing: 0) {
            shortcutsList
            Divider()
            updateButton
            Divider()
            settingsButton
            Divider()
            quitButton
        }
        .padding(.vertical, 4)
        .frame(width: 280)
    }

    // MARK: - Shortcuts List

    @ViewBuilder
    private var shortcutsList: some View {
        let hasApps = !appShortcuts.isEmpty
        let hasScripts = !scriptShortcuts.isEmpty

        if !hasApps && !hasScripts {
            Text("No shortcuts configured")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if hasApps {
                        ForEach(appShortcuts) { shortcut in
                            MenuBarShortcutRow(shortcut: shortcut) {
                                hotkeyService.trigger(shortcut: shortcut, store: store)
                            }
                        }
                    }
                    if hasApps && hasScripts {
                        Divider().padding(.vertical, 4)
                    }
                    if hasScripts {
                        ForEach(scriptShortcuts) { shortcut in
                            MenuBarShortcutRow(shortcut: shortcut) {
                                hotkeyService.trigger(shortcut: shortcut, store: store)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    // MARK: - Footer Buttons

    private var updateButton: some View {
        Button {
            updateService.checkForUpdates()
        } label: {
            HStack {
                Text("Check for Updates…")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .disabled(!updateService.canCheckForUpdates)
    }

    private var settingsButton: some View {
        Button {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack {
                Text("Settings...")
                Spacer()
                Text("\u{2318},")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack {
                Text("Quit TapTick")
                Spacer()
                Text("\u{2318}Q")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar Shortcut Row

/// A single tappable row for a shortcut in the menu bar dropdown, showing icon, name, and key combo.
private struct MenuBarShortcutRow: View {
    let shortcut: Shortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 18, height: 18)

                Text(shortcut.name)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let keyCombo = shortcut.keyCombo {
                    Text(keyCombo.displayString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var icon: some View {
        switch shortcut.action {
        case .launchApp(let bundleID, _):
            AppIconView(bundleIdentifier: bundleID)
        case .runScript, .runScriptFile:
            Image(systemName: shortcut.action.systemImage)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}
