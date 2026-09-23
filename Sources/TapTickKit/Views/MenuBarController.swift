import AppKit
import Observation

/// Manages the single menu bar button containing TapTick's icon, text slots, and native menu.
///
/// Replaces the SwiftUI `MenuBarExtra` with a real `NSStatusItem` + `NSMenu` that provides:
/// - Native key equivalent glyphs (⌘⌥⌃⇧+key) rendered by AppKit
/// - Standard keyboard navigation and VoiceOver support
/// - Observation-driven menu rebuilds and text slot rendering
/// - Dynamic show/hide via UserDefaults KVO for `"showMenuBarIcon"`
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusContentView: MenuBarStatusContentView?
    private let store: ShortcutStore
    private let shortcutExecutor: ShortcutExecutor
    private let updateService: UpdateService
    private let menuBarTextController: MenuBarTextController

    /// Watches `"showMenuBarIcon"` in UserDefaults via KVO.
    private var visibilityObservation: NSKeyValueObservation?

    /// Tracks the Observation framework subscription so we can cancel on deinit.
    private var storeObservationTask: Task<Void, Never>?
    private var textObservationTask: Task<Void, Never>?

    /// Tag used to identify the "Check for Updates…" item for dynamic enable/disable.
    private static let updateMenuItemTag = 999

    public init(
        store: ShortcutStore,
        shortcutExecutor: ShortcutExecutor,
        updateService: UpdateService,
        menuBarTextController: MenuBarTextController
    ) {
        self.store = store
        self.shortcutExecutor = shortcutExecutor
        self.updateService = updateService
        self.menuBarTextController = menuBarTextController
        super.init()

        // Seed default if not yet set — matches GeneralSettingsView's @AppStorage default.
        UserDefaults.standard.register(defaults: ["showMenuBarIcon": true])

        // Apply initial visibility, then observe changes.
        applyVisibility(UserDefaults.standard.bool(forKey: "showMenuBarIcon"))

        visibilityObservation = UserDefaults.standard.observe(
            \.showMenuBarIcon,
            options: [.new]
        ) { [weak self] _, change in
            guard let visible = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.applyVisibility(visible)
            }
        }

        startObservingStore()
        startObservingMenuBarText()
    }

    deinit {
        storeObservationTask?.cancel()
        textObservationTask?.cancel()
    }

    // MARK: - Visibility

    private func applyVisibility(_ visible: Bool) {
        if visible {
            installStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let contentView = MenuBarStatusContentView(frame: .zero)
        contentView.widthDidChange = { [weak self] width in
            self?.statusItem?.length = width
        }
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.addSubview(contentView)
            contentView.frame = button.bounds
            contentView.autoresizingMask = [.width, .height]
            button.setAccessibilityLabel("TapTick")
        }
        let menu = buildMenu(ShortcutMenuSnapshot(shortcuts: store.shortcuts))
        menu.delegate = self
        item.menu = menu
        statusItem = item
        statusContentView = contentView
        updateStatusContent(menuBarTextController.renderedSlots)
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusContentView = nil
    }

    // MARK: - Observation

    private func startObservingStore() {
        let observedStore = store
        let initial = ShortcutMenuSnapshot(shortcuts: observedStore.shortcuts)
        let menus = Observations { ShortcutMenuSnapshot(shortcuts: observedStore.shortcuts) }
        storeObservationTask = Task { [weak self] in
            var previous = initial
            for await snapshot in menus {
                guard !Task.isCancelled else { return }
                guard snapshot != previous else { continue }
                previous = snapshot
                self?.rebuildMenu(snapshot)
            }
        }
    }

    private func startObservingMenuBarText() {
        let observedController = menuBarTextController
        let initial = observedController.renderedSlots
        let content = Observations { observedController.renderedSlots }
        textObservationTask = Task { [weak self] in
            var previous = initial
            for await slots in content {
                guard !Task.isCancelled else { return }
                guard slots != previous else { continue }
                previous = slots
                self?.updateStatusContent(slots)
            }
        }
    }

    private func rebuildMenu(_ snapshot: ShortcutMenuSnapshot) {
        let menu = buildMenu(snapshot)
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func updateStatusContent(_ slots: [MenuBarTextRenderedSlot]) {
        statusContentView?.update(slots: slots, animated: true)

        let accessibilityValue =
            slots
            .flatMap(\.contents)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        statusItem?.button?.setAccessibilityValue(accessibilityValue)
    }

    // MARK: - NSMenuDelegate

    /// Refresh dynamic state (e.g. update button enabled) every time the menu opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if let updateItem = menu.item(withTag: Self.updateMenuItemTag) {
            updateItem.isEnabled = updateService.canCheckForUpdates
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        statusContentView?.needsDisplay = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        statusContentView?.needsDisplay = true
    }

    // MARK: - Menu Construction

    private func buildMenu(_ snapshot: ShortcutMenuSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let appShortcuts = snapshot.applications
        let scriptShortcuts = snapshot.scripts
        let hasApps = !appShortcuts.isEmpty
        let hasScripts = !scriptShortcuts.isEmpty

        if !hasApps && !hasScripts {
            let empty = NSMenuItem(title: "No shortcuts configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for shortcut in appShortcuts {
                menu.addItem(menuItem(for: shortcut))
            }
            if hasApps && hasScripts {
                menu.addItem(.separator())
            }
            for shortcut in scriptShortcuts {
                menu.addItem(menuItem(for: shortcut))
            }
        }

        menu.addItem(.separator())

        // Check for Updates…
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.tag = Self.updateMenuItemTag
        updateItem.isEnabled = updateService.canCheckForUpdates
        applyImage(
            symbolImage("arrow.triangle.2.circlepath", size: NSSize(width: 18, height: 18)),
            to: updateItem
        )
        menu.addItem(updateItem)

        // Settings…
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit TapTick",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Build an `NSMenuItem` for a single shortcut, with its app icon and native key equivalent glyph.
    private func menuItem(for shortcut: ShortcutMenuEntry) -> NSMenuItem {
        let keyEquiv: String
        var modMask: NSEvent.ModifierFlags = []

        if let combo = shortcut.keyCombo {
            keyEquiv = combo.menuItemKeyEquivalent
            modMask = combo.menuItemModifierMask
        } else {
            keyEquiv = ""
        }

        let item = NSMenuItem(
            title: shortcut.name,
            action: #selector(triggerShortcut(_:)),
            keyEquivalent: keyEquiv
        )
        item.keyEquivalentModifierMask = modMask
        item.target = self
        item.representedObject = shortcut.id
        applyImage(icon(for: shortcut.icon), to: item)

        return item
    }

    private func applyImage(_ image: NSImage?, to item: NSMenuItem) {
        item.image = image

        // Release builds use the stable Xcode toolchain, where the macOS 27 SDK API is absent.
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
        #endif
    }

    /// Resolve an appropriately-sized icon for the shortcut's action type.
    private func icon(for icon: ShortcutMenuEntry.Icon) -> NSImage? {
        let size = NSSize(width: 18, height: 18)

        switch icon {
        case .application(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return symbolImage("app", size: size)
            }
            let appIcon = NSWorkspace.shared.icon(forFile: url.path)
            appIcon.size = size
            return appIcon

        case .script:
            return symbolImage("terminal", size: size)

        case .legacyFile:
            return symbolImage("doc.text", size: size)
        }
    }

    /// Create a template SF Symbol image at the given point size.
    private func symbolImage(_ name: String, size: NSSize) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let configured = image.withSymbolConfiguration(config) ?? image
        configured.size = size
        configured.isTemplate = true
        return configured
    }

    // MARK: - Actions

    @objc private func triggerShortcut(_ sender: NSMenuItem) {
        guard let shortcutID = sender.representedObject as? UUID else { return }
        shortcutExecutor.execute(shortcutID: shortcutID)
    }

    @objc private func checkForUpdates() {
        updateService.checkForUpdates()
    }

    @objc private func openSettings() {
        // Post a notification that TapTickApp's AppDelegate picks up to open the settings window.
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Notification Name

public extension Notification.Name {
    /// Posted by `MenuBarController` when the user clicks "Settings…" in the menu bar dropdown.
    static let openSettingsWindow = Notification.Name("TapTick.openSettingsWindow")
    /// Posted by `HotkeyService` when the reserved settings hotkey should toggle the window.
    static let toggleSettingsWindow = Notification.Name("TapTick.toggleSettingsWindow")
}

// MARK: - UserDefaults KVO Key Path

/// Expose `"showMenuBarIcon"` as an `@objc dynamic` property so `NSKeyValueObservation` works.
extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        bool(forKey: "showMenuBarIcon")
    }
}

/// Only values consumed by the native menu participate in invalidation.
struct ShortcutMenuSnapshot: Equatable, Sendable {
    let applications: [ShortcutMenuEntry]
    let scripts: [ShortcutMenuEntry]

    init(shortcuts: [Shortcut]) {
        let entries = shortcuts.compactMap(ShortcutMenuEntry.init)
        applications = entries.filter { if case .application = $0.icon { true } else { false } }
        scripts = entries.filter { if case .application = $0.icon { false } else { true } }
    }
}

struct ShortcutMenuEntry: Equatable, Sendable {
    enum Icon: Equatable, Sendable {
        case application(String)
        case script
        case legacyFile
    }
    let id: UUID
    let name: String
    let keyCombo: KeyCombo?
    let icon: Icon

    init?(_ shortcut: Shortcut) {
        guard shortcut.isEnabled, shortcut.action.isLaunchApp || shortcut.keyCombo != nil else { return nil }
        id = shortcut.id
        name = shortcut.name
        keyCombo = shortcut.keyCombo
        switch shortcut.action {
        case .launchApp(let bundleID, _): icon = .application(bundleID)
        case .runScript: icon = .script
        case .runScriptFile: icon = .legacyFile
        }
    }
}
