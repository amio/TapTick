import SwiftUI

/// The menu bar dropdown view.
struct MenuBarView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Status
            HStack {
                Image(systemName: hotkeyService.isListening ? "keyboard.badge.ellipsis" : "keyboard")
                    .foregroundStyle(hotkeyService.isListening ? .green : .red)
                Text(hotkeyService.isListening ? "Listening" : "Not Active")
                    .font(.headline)
                Spacer()
                Text("\(store.shortcuts.filter(\.isEnabled).count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Quick list of shortcuts
            if store.shortcuts.isEmpty {
                Text("No shortcuts configured")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.shortcuts.prefix(10)) { shortcut in
                            HStack {
                                Image(systemName: shortcut.action.systemImage)
                                    .frame(width: 20)
                                    .foregroundStyle(shortcut.isEnabled ? .primary : .tertiary)
                                Text(shortcut.name)
                                    .lineLimit(1)
                                    .foregroundStyle(shortcut.isEnabled ? .primary : .secondary)
                                Spacer()
                                Text(shortcut.keyCombo.displayString)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Actions
            VStack(spacing: 2) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { _ in loginItemManager.toggle() }
                ))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Divider()

                Button {
                    openWindow(id: "settings")
                    // Bring app to front
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Text("Open Settings...")
                        Spacer()
                        Text("⌘,")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Divider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Text("Quit Magikeys")
                        Spacer()
                        Text("⌘Q")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 300)
    }
}
