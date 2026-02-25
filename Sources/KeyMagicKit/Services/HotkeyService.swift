@preconcurrency import Cocoa
import CoreGraphics
import Observation

/// Manages global keyboard event monitoring and dispatches matched shortcuts.
@Observable
@MainActor
public final class HotkeyService: @unchecked Sendable {
    public init() {}

    private(set) var isListening = false
    private(set) var lastError: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var store: ShortcutStore?
    private var executor: ShortcutExecutor?

    // Polling task that watches for accessibility permission grant while waiting for user.
    private var permissionPollingTask: Task<Void, Never>?

    /// Start listening for global hotkeys. Requires Accessibility permission.
    /// If permission is missing, begins silent polling and auto-starts once granted.
    func start(store: ShortcutStore) {
        guard !isListening else { return }
        self.store = store
        self.executor = ShortcutExecutor()

        // Check accessibility — skip tap creation and begin polling instead
        if !AXIsProcessTrusted() {
            lastError = "Accessibility permission required. Please grant access in System Settings > Privacy & Security > Accessibility."
            beginPermissionPolling(store: store)
            return
        }

        startEventTap()
    }

    /// Create and install the CGEvent tap. Assumes accessibility permission is already granted.
    private func startEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Use a static callback that retrieves `self` from the userInfo pointer
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            lastError = "Failed to create event tap. Ensure Accessibility permission is granted."
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isListening = true
        self.lastError = nil
    }

    /// Start polling for accessibility permission. Checks every 2 seconds and auto-starts
    /// the event tap once permission is granted (triggered by user action in System Settings).
    private func beginPermissionPolling(store: ShortcutStore) {
        permissionPollingTask?.cancel()
        permissionPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                guard let self, !self.isListening else { break }
                guard AXIsProcessTrusted() else { continue }
                // Permission was just granted — wire up the tap and stop polling.
                self.permissionPollingTask = nil
                self.lastError = nil
                self.store = store
                self.executor = ShortcutExecutor()
                self.startEventTap()
                break
            }
        }
    }

    /// Stop listening.
    func stop() {
        guard isListening else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isListening = false
    }

    /// Restart listening (useful after shortcuts change).
    func restart(store: ShortcutStore) {
        stop()
        start(store: store)
    }

    /// Called internally when a matching key combo is detected.
    fileprivate func handleKeyEvent(keyCode: UInt32, flags: CGEventFlags) {
        let combo = KeyCombo(
            keyCode: keyCode,
            modifiers: KeyCombo.Modifiers(cgEventFlags: flags)
        )

        guard let store, let shortcut = store.shortcut(for: combo) else { return }
        store.markTriggered(id: shortcut.id)
        executor?.execute(action: shortcut.action)
    }

    /// Trigger a shortcut action directly (e.g. from menu bar click).
    func trigger(shortcut: Shortcut, store: ShortcutStore) {
        store.markTriggered(id: shortcut.id)
        let exec = executor ?? ShortcutExecutor()
        exec.execute(action: shortcut.action)
    }

    /// Whether accessibility permission has been granted.
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user for accessibility permission via the system dialog.
    public static func requestAccessibilityPermission() {
        promptAccessibility()
    }

    /// Internal: prompt accessibility using the C global. Wrapped to isolate concurrency warning.
    private static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - CGEvent Callback (C function pointer)

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    // Only process events that have at least one modifier key
    let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    guard !flags.intersection(modifierMask).isEmpty else {
        return Unmanaged.passRetained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    // Dispatch to main actor
    Task { @MainActor in
        service.handleKeyEvent(keyCode: keyCode, flags: flags)
    }

    return Unmanaged.passRetained(event)
}
