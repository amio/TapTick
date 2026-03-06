import AppKit
import SwiftUI
import TapTickKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var openSettingsTrigger = 0
}

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

        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Close the settings window automatically created by SwiftUI on subsequent launches
            for window in NSApp.windows {
                if window.title == "TapTick Settings" || window.identifier?.rawValue == "settings" {
                    window.close()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.openSettingsTrigger += 1
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

/// TapTick — a utility app for launching apps and running scripts via global hotkeys.
///
/// Architecture:
/// - The app lives primarily in the menu bar (MenuBarExtra).
/// - A settings window is the main (and only) substantial UI.
/// - Global keyboard shortcuts are registered via Carbon's RegisterEventHotKey (no permissions needed).
/// - Login item is managed through ServiceManagement.
/// - Shortcuts are optionally synced across Macs via iCloud Drive.
@main
struct TapTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    @State private var cloudSync = CloudSyncService()
    @State private var store: ShortcutStore
    @State private var hotkeyService = HotkeyService()
    @State private var loginItemManager = LoginItemManager()
    @State private var updateService = UpdateService()

    init() {
        let sync = CloudSyncService()
        _cloudSync = State(initialValue: sync)
        _store = State(initialValue: ShortcutStore(cloudSync: sync))
    }

    var body: some Scene {
        // MARK: - Menu Bar
        MenuBarExtra("TapTick", systemImage: "keyboard.badge.ellipsis") {
            MenuBarView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
                .environment(cloudSync)
                .environment(updateService)
        }

        // MARK: - Settings Window
        Window("TapTick Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(hotkeyService)
                .environment(loginItemManager)
                .environment(cloudSync)
                .environment(updateService)
                .frame(minWidth: 890, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 620)
        .onChange(of: appState.openSettingsTrigger) { _ in
            openWindow(id: "settings")
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateService.checkForUpdates()
                }
                .disabled(!updateService.canCheckForUpdates)
            }
        }
    }
}