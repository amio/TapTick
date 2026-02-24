import SwiftUI

/// Magikeys — a utility app for launching apps and running scripts via global hotkeys.
///
/// Architecture:
/// - The app lives primarily in the menu bar (MenuBarExtra).
/// - A settings window is the main (and only) substantial UI.
/// - Global keyboard shortcuts are registered via CGEvent taps.
/// - Login item is managed through ServiceManagement.
@main
struct MagikeysApp: App {
    @State private var store = ShortcutStore()
    @State private var hotkeyService = HotkeyService()
    @State private var loginItemManager = LoginItemManager()

    var body: some Scene {
        // MARK: - Menu Bar
        MenuBarExtra("Magikeys", systemImage: "keyboard.badge.ellipsis") {
            MenuBarView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
        }

        // MARK: - Settings Window
        Window("Magikeys Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 780, height: 560)
    }
}
