@preconcurrency import Cocoa
import CoreGraphics
import Observation

/// Manages global keyboard event monitoring and dispatches matched shortcuts.
@Observable
@MainActor
final class HotkeyService: @unchecked Sendable {
    private(set) var isListening = false
    private(set) var lastError: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var store: ShortcutStore?
    private var executor: ShortcutExecutor?

    /// Start listening for global hotkeys. Requires Accessibility permission.
    func start(store: ShortcutStore) {
        guard !isListening else { return }
        self.store = store
        self.executor = ShortcutExecutor()

        // Check accessibility — prompt if not trusted
        if !AXIsProcessTrusted() {
            Self.promptAccessibility()
            lastError = "Accessibility permission required. Please grant access in System Settings > Privacy & Security > Accessibility."
            return
        }

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

    /// Whether accessibility permission has been granted.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user for accessibility permission.
    static func requestAccessibilityPermission() {
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
