import Carbon.HIToolbox
import Observation

/// Manages global hotkey registration using Carbon's RegisterEventHotKey API.
///
/// This approach is sandbox-compatible and requires no Accessibility permission.
/// Instead of intercepting the entire keyboard event stream, each KeyCombo is
/// registered individually with the system; macOS delivers a targeted callback
/// only when that exact combination is pressed.
@Observable
@MainActor
public final class HotkeyService: @unchecked Sendable {
    public init() {}

    private(set) var isListening = false

    /// Active registrations keyed by the Carbon hot-key ID (sequential UInt32).
    private var registrations: [UInt32: Registration] = [:]
    /// Monotonically increasing ID counter for Carbon hot-key handles.
    private var nextID: UInt32 = 1

    private var store: ShortcutStore?
    private var executor: ShortcutExecutor?
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Public API

    /// Register all shortcuts in the store and begin dispatching.
    func start(store: ShortcutStore) {
        self.store = store
        self.executor = ShortcutExecutor()
        rebuildRegistrations(store: store)
    }

    /// Unregister all hotkeys and stop dispatching.
    func stop() {
        registrations.values.forEach { UnregisterEventHotKey($0.ref) }
        registrations.removeAll()
        isListening = false
    }

    /// Re-register all hotkeys (call after shortcuts change).
    func restart(store: ShortcutStore) {
        stop()
        start(store: store)
    }

    /// Trigger a shortcut action directly (e.g. from menu bar click).
    func trigger(shortcut: Shortcut, store: ShortcutStore) {
        store.markTriggered(id: shortcut.id)
        let exec = executor ?? ShortcutExecutor()
        exec.execute(action: shortcut.action)
    }

    // MARK: - Registration

    private func rebuildRegistrations(store: ShortcutStore) {
        registrations.values.forEach { UnregisterEventHotKey($0.ref) }
        registrations.removeAll()

        installEventHandlerIfNeeded()

        for shortcut in store.shortcuts where shortcut.isEnabled {
            guard let combo = shortcut.keyCombo else { continue }
            registerCombo(combo, shortcutID: shortcut.id)
        }

        // Listening is considered active as long as the handler is installed,
        // even if there are currently no shortcuts to register.
        isListening = eventHandlerRef != nil
    }

    private func registerCombo(_ combo: KeyCombo, shortcutID: Shortcut.ID) {
        let id = nextID
        nextID += 1

        let eventHotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonModifiers,
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return }
        registrations[id] = Registration(ref: ref, shortcutID: shortcutID)
    }

    // MARK: - Carbon Event Handler

    /// Install the application-level Carbon event handler (idempotent).
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userInfo,
            &eventHandlerRef
        )
    }

    // MARK: - Dispatch

    /// Called by the C-level event handler when a registered hotkey fires.
    fileprivate func handleHotKeyEvent(id: UInt32) {
        guard let registration = registrations[id],
              let store,
              let shortcut = store.shortcuts.first(where: { $0.id == registration.shortcutID })
        else { return }

        store.markTriggered(id: shortcut.id)
        executor?.execute(action: shortcut.action)
    }
}

// MARK: - Supporting Types

/// Associates a Carbon EventHotKeyRef with a Shortcut UUID.
private struct Registration {
    let ref: EventHotKeyRef
    let shortcutID: Shortcut.ID
}

/// Four-char code used to namespace our hot-key IDs within the system.
/// 'TTgc' — TapTick global combos.
private let hotKeySignature: OSType = 0x5454_6763

// MARK: - Carbon Event Handler (C function pointer)

private func hotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        service.handleHotKeyEvent(id: hotKeyID.id)
    }

    return noErr
}
