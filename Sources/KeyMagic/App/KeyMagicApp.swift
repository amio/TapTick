import AppKit
import SwiftUI
import KeyMagicKit

/// Applies the dock icon policy once at launch based on the stored user preference.
/// Using an app delegate avoids the crash from accessing `NSApp` in the `App.init()`,
/// where `NSApplication.shared` has not yet been created.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        if !showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// KeyMagic — a utility app for launching apps and running scripts via global hotkeys.
///
/// Architecture:
/// - The app lives primarily in the menu bar (MenuBarExtra).
/// - A settings window is the main (and only) substantial UI.
/// - Global keyboard shortcuts are registered via Carbon's RegisterEventHotKey (no permissions needed).
/// - Login item is managed through ServiceManagement.
/// - Shortcuts are optionally synced across Macs via iCloud Drive.
@main
struct KeyMagicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var cloudSync = CloudSyncService()
    @State private var store: ShortcutStore
    @State private var hotkeyService = HotkeyService()
    @State private var loginItemManager = LoginItemManager()

    init() {
        let sync = CloudSyncService()
        _cloudSync = State(initialValue: sync)
        _store = State(initialValue: ShortcutStore(cloudSync: sync))
    }

    var body: some Scene {
        // MARK: - Menu Bar
        MenuBarExtra("KeyMagic", systemImage: "keyboard.badge.ellipsis") {
            MenuBarView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
                .environment(cloudSync)
        }

        // MARK: - Settings Window
        Window("KeyMagic Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
                .environment(cloudSync)
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 620)
    }
}
