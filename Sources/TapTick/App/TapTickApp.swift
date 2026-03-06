import AppKit
import ServiceManagement
import SwiftUI
import TapTickKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var openSettingsTrigger = 0
}

/// Returns `true` when this process was launched by launchd (login item / system boot),
/// rather than directly by the user (Dock, Finder, Terminal, etc.).
///
/// The heuristic compares the parent-process name: launchd always has PID 1 and name
/// "launchd". Any interactive launch will have a parent such as "Dock" or "launchservicesd".
private func isLaunchedByLoginItem() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let parentName = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
        bytes.baseAddress.flatMap { String(validatingCString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
    }
    return parentName == "launchd"
}

/// Applies the dock icon policy once at launch based on the stored user preference.
/// Using an app delegate avoids the crash from accessing `NSApp` in the `App.init()`,
/// where `NSApplication.shared` has not yet been created.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")

        if !hasLaunchedBefore {
            // First launch: apply defaults and register login item
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // showDockIcon defaults to true — no write needed; @AppStorage default handles UI,
            // but AppDelegate reads UserDefaults directly, so seed the value explicitly.
            if UserDefaults.standard.object(forKey: "showDockIcon") == nil {
                UserDefaults.standard.set(true, forKey: "showDockIcon")
            }
            // Enable launch at login by default on first launch
            try? SMAppService.mainApp.register()

            NSApp.activate(ignoringOtherApps: true)
        } else {
            let launchedBySystem = isLaunchedByLoginItem()

            if !launchedBySystem {
                // Launched manually by the user: open settings window and bring app to front.
                // Window uses .defaultLaunchBehavior(.suppressed) so it won't open automatically.
                AppState.shared.openSettingsTrigger += 1
                NSApp.activate(ignoringOtherApps: true)
            }
            // Launched by login item: do nothing — window stays hidden, app lives in menu bar.
        }

        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        if !showDockIcon {
            NSApp.setActivationPolicy(.accessory)
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
        .defaultLaunchBehavior(.suppressed)
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