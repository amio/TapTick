import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TapTickKit

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private(set) var openSettingsTrigger = 0
    @ObservationIgnored weak var settingsWindow: NSWindow?

    // MARK: - Shared Services

    let cloudSync: CloudSyncService
    let store: ShortcutStore
    let utilities = UtilitiesController()
    let hotkeyService = HotkeyService()
    let loginItemManager = LoginItemManager()
    let updateService = UpdateService()
    let scriptLogStore: ScriptLogStore
    let scriptOutputPresenter: ScriptOutputPresenter
    let shortcutExecutor: ShortcutExecutor
    let menuBarTextController: MenuBarTextController

    /// Native NSStatusItem + NSMenu controller — retained for the lifetime of the app.
    @ObservationIgnored
    var menuBarController: MenuBarController?

    private init() {
        let sync = CloudSyncService()
        self.cloudSync = sync
        let store = ShortcutStore(cloudSync: sync)
        let scriptLogStore = ScriptLogStore()
        let scriptOutputPresenter = ScriptOutputPresenter()
        self.store = store
        self.scriptLogStore = scriptLogStore
        self.scriptOutputPresenter = scriptOutputPresenter
        self.shortcutExecutor = ShortcutExecutor(
            store: store,
            logStore: scriptLogStore,
            outputPresenter: scriptOutputPresenter
        )
        self.menuBarTextController = MenuBarTextController(store: store)
    }

    func requestSettingsOpen() {
        openSettingsTrigger &+= 1
    }
}

/// Returns `true` only when the launch Apple Event identifies this as a login-item launch.
/// Parent-process inspection is not reliable because LaunchServices may also launch a manually
/// opened UIElement app through launchd.
private func isLaunchedByLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
    return event.eventID == kAEOpenApplication
        && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
}

/// Owns app-level presentation: Settings window lifecycle, focus handoff, and Dock policy.
/// Keeping these decisions together prevents individual views and entry points from creating
/// different activation behavior for the same window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsNotificationObserver: Any?
    private var toggleSettingsNotificationObserver: Any?
    private var settingsWindowCloseObserver: Any?
    private var workspaceActivationObserver: Any?
    private var defaultsObserver: Any?
    private weak var observedSettingsWindow: NSWindow?
    private var lastExternalActiveApp: NSRunningApplication?
    private var appliedDockIconVisibility: Bool?
    private var isReadyForActivationPresentation = false
    private var isSettingsSceneOpening = false
    private var isSettingsPresentationRequested = false
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        startTrackingExternalActivation()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState.shared
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        let shouldOpenSettings = !hasLaunchedBefore || !isLaunchedByLoginItem()

        UserDefaults.standard.register(defaults: ["showDockIcon": false])

        if !hasLaunchedBefore {
            // First launch: apply defaults and register login item
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // Enable launch at login by default on first launch
            try? SMAppService.mainApp.register()
        }

        applyDockIconPolicyFromDefaults()
        startObservingDockIconPreference()

        // Install the native menu bar controller now that NSApplication is fully initialised.
        appState.menuBarController = MenuBarController(
            store: appState.store,
            shortcutExecutor: appState.shortcutExecutor,
            updateService: appState.updateService,
            menuBarTextController: appState.menuBarTextController
        )
        appState.menuBarTextController.bootstrap()

        appState.utilities.bootstrap()

        appState.hotkeyService.onShortcutTriggered = {
            [weak shortcutExecutor = appState.shortcutExecutor] shortcutID in
            shortcutExecutor?.execute(shortcutID: shortcutID)
        }

        appState.hotkeyService.start(
            store: appState.store,
            utilities: appState.utilities
        )

        // Listen for the "open settings" notification posted by MenuBarController.
        settingsNotificationObserver = NotificationCenter.default.addObserver(
            forName: .openSettingsWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openSettingsWindow()
            }
        }

        toggleSettingsNotificationObserver = NotificationCenter.default.addObserver(
            forName: .toggleSettingsWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toggleSettingsWindow()
            }
        }

        isReadyForActivationPresentation = true
        if shouldOpenSettings {
            // Manual and first launches present Settings. Login-item launches remain quiet.
            openSettingsWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isReadyForActivationPresentation else { return }

        if let settingsWindow = currentSettingsWindow() {
            if isSettingsPresentationRequested {
                presentSettingsWindow(settingsWindow)
                return
            }

            if settingsWindow.isMiniaturized {
                return
            }

            if settingsWindow.isVisible {
                if NSApp.keyWindow == nil {
                    settingsWindow.makeKeyAndOrderFront(nil)
                }
                return
            }
        }

        guard !hasVisibleInteractiveWindow() else {
            return
        }

        openSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        removeObservers()
    }

    func registerSettingsWindow(_ window: NSWindow) {
        window.identifier = settingsWindowIdentifier
        // This settings window is toggled frequently by a global hotkey. AppKit's automatic
        // ordering animation exposes intermediate SwiftUI sidebar rendering, so present the
        // fully resolved key-window appearance immediately.
        window.animationBehavior = .none
        // Inner pages own independent scrollers, but the window owns one stable toolbar boundary.
        window.titlebarSeparatorStyle = .line
        AppState.shared.settingsWindow = window
        isSettingsSceneOpening = false

        if observedSettingsWindow !== window {
            if let settingsWindowCloseObserver {
                NotificationCenter.default.removeObserver(settingsWindowCloseObserver)
            }
            observedSettingsWindow = window
            settingsWindowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let window else { return }
                    self?.settingsWindowWillClose(window)
                }
            }
        }

        if isSettingsPresentationRequested {
            presentSettingsWindow(window)
        }
    }

    func dismissSettingsWindow() {
        isSettingsPresentationRequested = false

        guard let window = currentSettingsWindow(), window.isVisible else {
            return
        }

        // Keep the window alive for a synchronous reopen, then return to the user's work.
        window.orderOut(nil)
        handOffFocusIfNeeded(excluding: window)
    }

    private func openSettingsWindow() {
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)
        isSettingsPresentationRequested = true

        if let window = currentSettingsWindow() {
            presentSettingsWindow(window)
            return
        }

        guard !isSettingsSceneOpening else { return }
        isSettingsSceneOpening = true
        AppState.shared.requestSettingsOpen()
    }

    private func presentSettingsWindow(_ window: NSWindow) {
        NSApp.unhide(nil)
        // Settings presentation only follows an explicit user action or a manual launch. The
        // cooperative API can leave LSUIElement windows behind the active app on macOS 26 and 27
        // (FB23508310), so keep this compatibility call at the app-presentation boundary.
        guard NSApp.isActive else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Ordering the window while the app is inactive starts its enter animation with an
        // inactive appearance, then restarts SwiftUI rendering when activation makes it key.
        // Consume the request only after activation so the window enters exactly once.
        isSettingsPresentationRequested = false
        window.makeKeyAndOrderFront(nil)
    }

    private func toggleSettingsWindow() {
        // Only collapse the window when it is already the key window and the app is active
        // (i.e. the user is actively looking at it). If the window is merely visible but
        // behind another app, the first press should bring it to front, not close it.
        if let window = currentSettingsWindow(), window.isVisible, window.isKeyWindow {
            dismissSettingsWindow()
            return
        }

        openSettingsWindow()
    }

    private func settingsWindowWillClose(_ window: NSWindow) {
        guard observedSettingsWindow === window else { return }

        if let settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(settingsWindowCloseObserver)
            self.settingsWindowCloseObserver = nil
        }
        AppState.shared.settingsWindow = nil
        observedSettingsWindow = nil
        isSettingsSceneOpening = false
        isSettingsPresentationRequested = false
        handOffFocusIfNeeded(excluding: window)
    }

    private func handOffFocusIfNeeded(excluding settingsWindow: NSWindow) {
        guard !isTerminating, NSApp.isActive else { return }
        guard !hasVisibleInteractiveWindow(excluding: settingsWindow) else { return }

        guard let target = lastExternalActiveApp, !target.isTerminated else {
            // A cold launch may not have observed the previously active process. Hiding lets
            // macOS select the appropriate successor without leaving TapTick active and empty.
            NSApp.hide(nil)
            return
        }

        NSApp.yieldActivation(to: target)
        target.activate()
    }

    private func hasVisibleInteractiveWindow(excluding excludedWindow: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            if let excludedWindow, window === excludedWindow { return false }
            return window.isVisible
                && window.canBecomeKey
                && !window.styleMask.contains(.nonactivatingPanel)
        }
    }

    private func startTrackingExternalActivation() {
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.rememberExternalApp(app)
            }
        }
    }

    private func rememberExternalApp(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        lastExternalActiveApp = app
    }

    private func startObservingDockIconPreference() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyDockIconPolicyFromDefaults()
            }
        }
    }

    private func applyDockIconPolicyFromDefaults() {
        let isVisible = UserDefaults.standard.bool(forKey: "showDockIcon")
        guard appliedDockIconVisibility != isVisible else { return }

        let settingsWindow = currentSettingsWindow()
        let shouldRestoreSettingsFocus =
            settingsWindow?.isKeyWindow == true || isSettingsPresentationRequested
        guard NSApp.setActivationPolicy(isVisible ? .regular : .accessory) else { return }
        appliedDockIconVisibility = isVisible

        guard shouldRestoreSettingsFocus else { return }
        isSettingsPresentationRequested = true
        Task { @MainActor [weak self, weak settingsWindow] in
            await Task.yield()
            guard let self, let settingsWindow else { return }
            self.presentSettingsWindow(settingsWindow)
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        [
            settingsNotificationObserver, toggleSettingsNotificationObserver,
            settingsWindowCloseObserver, defaultsObserver,
        ]
        .compactMap { $0 }
        .forEach(center.removeObserver)

        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }

        settingsNotificationObserver = nil
        toggleSettingsNotificationObserver = nil
        settingsWindowCloseObserver = nil
        workspaceActivationObserver = nil
        defaultsObserver = nil
    }

    private func currentSettingsWindow() -> NSWindow? {
        AppState.shared.settingsWindow
            ?? NSApp.windows.first(where: { $0.identifier == settingsWindowIdentifier })
    }
}

/// TapTick — a utility app for launching apps and running scripts via global hotkeys.
///
/// Architecture:
/// - The app lives primarily in the menu bar (native NSStatusItem + NSMenu via MenuBarController).
/// - A settings window is the main (and only) substantial UI.
/// - Global keyboard shortcuts are registered via Carbon's RegisterEventHotKey (no permissions needed).
/// - Login item is managed through ServiceManagement.
/// - Shortcuts are optionally synced across Macs via iCloud Drive.
@main
struct TapTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // MARK: - Settings Window
        Window("TapTick Settings", id: "settings") {
            SettingsView()
                .environment(appState.store)
                .environment(appState.utilities)
                .environment(appState.hotkeyService)
                .environment(appState.loginItemManager)
                .environment(appState.cloudSync)
                .environment(appState.updateService)
                .environment(appState.scriptLogStore)
                .environment(appState.shortcutExecutor)
                .environment(appState.menuBarTextController)
                .onExitCommand {
                    appDelegate.dismissSettingsWindow()
                }
                .background(
                    SettingsWindowObserver { window in
                        guard let window else { return }
                        appDelegate.registerSettingsWindow(window)
                    }
                )
                .frame(
                    minWidth: 880,
                    minHeight: 560
                )
        }
        .defaultSize(width: 1_020, height: 680)
        .windowResizability(.contentMinSize)
        // Column titles are explicit toolbar items so native tracking separators remain
        // free to align with split dividers when the leading sidebar is collapsed.
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowStyle(.titleBar)
        .defaultLaunchBehavior(.suppressed)
        .onChange(of: appState.openSettingsTrigger) {
            openWindow(id: "settings")
        }
        .commands {
            SidebarCommands()
            TextEditingCommands()

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.updateService.checkForUpdates()
                }
                .disabled(!appState.updateService.canCheckForUpdates)
            }
        }
    }
}

private let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("TapTick.settingsWindow")

/// Captures the underlying NSWindow for the SwiftUI settings scene once it exists.
private struct SettingsWindowObserver: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> SettingsWindowObserverView {
        let view = SettingsWindowObserverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SettingsWindowObserverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveWindow()
    }

    static func dismantleNSView(_ nsView: SettingsWindowObserverView, coordinator: Void) {
        nsView.onResolve = nil
    }
}

@MainActor
private final class SettingsWindowObserverView: NSView {
    var onResolve: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindow()
    }

    func resolveWindow() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            onResolve?(window)
        }
    }
}
