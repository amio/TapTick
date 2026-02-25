import SwiftUI

/// The menu bar dropdown view.
public struct MenuBarView: View {
    public init() {}

    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(\.openWindow) private var openWindow

    private var enabledShortcuts: [Shortcut] {
        store.shortcuts.filter(\.isEnabled)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Shortcuts list
            if enabledShortcuts.isEmpty {
                Text("No shortcuts configured")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(enabledShortcuts) { shortcut in
                            Button {
                                hotkeyService.trigger(shortcut: shortcut, store: store)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: shortcut.action.systemImage)
                                        .frame(width: 16)
                                        .font(.caption)
                                    Text(shortcut.name)
                                        .lineLimit(1)
                                        .font(.caption)
                                    Spacer()
                                    Text(shortcut.keyCombo.displayString)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer actions
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Text("Settings...")
                        .font(.caption)
                    Spacer()
                    Text("\u{2318},")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Magikeys")
                        .font(.caption)
                    Spacer()
                    Text("\u{2318}Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 260)
    }
}
