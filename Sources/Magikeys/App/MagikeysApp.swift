import AppKit
import SwiftUI
import MagikeysKit

/// Applies the dock icon policy once at launch based on the stored user preference.
/// Using an app delegate avoids the crash from accessing `NSApp` in the `App.init()`,
/// where `NSApplication.shared` has not yet been created.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        if !showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Magikeys — a utility app for launching apps and running scripts via global hotkeys.
///
/// Architecture:
/// - The app lives primarily in the menu bar (MenuBarExtra).
/// - A settings window is the main (and only) substantial UI.
/// - Global keyboard shortcuts are registered via CGEvent taps.
/// - Login item is managed through ServiceManagement.
@main
struct MagikeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 620)
    }
}
