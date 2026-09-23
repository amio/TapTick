import Foundation
import Carbon.HIToolbox
import Observation

/// Owns the derived global binding plan and its native lifetime. Model writers never refresh
/// registrations themselves; only effective binding changes reach the shared Carbon namespace.
@Observable
@MainActor
public final class HotkeyService {
    public convenience init() { self.init(registrar: CarbonHotkeyRegistrar()) }

    init(registrar: any HotkeyRegistering) { self.registrar = registrar }

    private(set) var isListening = false
    private(set) var settingsWindowHotkey = HotkeyService.loadSettingsWindowHotkey()
    @ObservationIgnored private let registrar: any HotkeyRegistering
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var registrations: [UInt32: HotkeyBinding] = [:]
    @ObservationIgnored private var appliedPlan: [HotkeyBinding]?
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var suspensionCount = 0
    private var store: ShortcutStore?
    private var utilities: UtilitiesController?

    public var onShortcutTriggered: (@MainActor @Sendable (UUID) -> Void)?

    static let settingsWindowHotkeyDefaultsKey = "settingsWindowHotkey"
    static let defaultSettingsWindowHotkey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command, .control, .option]
    )

    isolated deinit {
        observationTask?.cancel()
        registrar.stop()
    }

    public func start(store: ShortcutStore, utilities: UtilitiesController? = nil) {
        stop()
        self.store = store
        if let utilities { self.utilities = utilities }
        isListening = registrar.start { [weak self] id in self?.handleHotKeyEvent(id: id) }
        guard isListening else { return }
        reconcile(registrationPlan)
        let plans = Observations { [weak self] in self?.registrationPlan ?? [] }
        observationTask = Task { [weak self] in
            for await plan in plans {
                guard !Task.isCancelled else { return }
                self?.reconcile(plan)
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        registrar.stop()
        registrations.removeAll()
        appliedPlan = nil
        isListening = false
    }

    func hasConflict(
        keyCombo: KeyCombo,
        excludingShortcutID: UUID? = nil,
        excludingSettingsWindowHotkey: Bool = false,
        excludingUtilityID: UtilityID? = nil
    ) -> Bool {
        let shortcutConflict = store?.hasConflict(keyCombo: keyCombo, excludingID: excludingShortcutID) ?? false
        let settingsConflict = !excludingSettingsWindowHotkey && settingsWindowHotkey == keyCombo
        let utilityConflict = utilities?.reservedHotkeyConflict(for: keyCombo, excluding: excludingUtilityID) ?? false
        return shortcutConflict || settingsConflict || utilityConflict
    }

    func updateSettingsWindowHotkey(_ combo: KeyCombo) {
        settingsWindowHotkey = combo
        saveSettingsWindowHotkey(combo)
    }

    func restoreDefaultSettingsWindowHotkey() {
        updateSettingsWindowHotkey(Self.defaultSettingsWindowHotkey)
    }

    func suspendRegistrations() {
        suspensionCount += 1
        guard suspensionCount == 1 else { return }
        registrar.unregisterAll()
        registrations.removeAll()
        appliedPlan = nil
    }

    func resumeRegistrations() {
        guard suspensionCount > 0 else { return }
        suspensionCount -= 1
        guard suspensionCount == 0 else { return }
        reconcile(registrationPlan)
    }

    private var registrationPlan: [HotkeyBinding] {
        var bindings = [HotkeyBinding(combo: settingsWindowHotkey, action: .toggleSettingsWindow)]
        bindings += (utilities?.reservedHotkeys() ?? []).map {
            HotkeyBinding(combo: $0.combo, action: .toggleUtility($0.featureID, $0.action))
        }
        bindings += (store?.shortcuts ?? []).compactMap { shortcut in
            guard shortcut.isEnabled, let combo = shortcut.keyCombo else { return nil }
            return HotkeyBinding(combo: combo, action: .shortcut(shortcut.id))
        }
        var seen: Set<KeyCombo> = []
        return bindings.filter { seen.insert($0.combo).inserted }
    }

    private func reconcile(_ plan: [HotkeyBinding]) {
        guard isListening, suspensionCount == 0, appliedPlan != plan else { return }
        registrar.unregisterAll()
        registrations.removeAll()
        appliedPlan = plan
        for binding in plan {
            let id = nextID
            nextID += 1
            if registrar.register(id: id, combo: binding.combo) { registrations[id] = binding }
        }
    }

    private func handleHotKeyEvent(id: UInt32) {
        // A queued event can arrive before observation reconciles a just-edited model.
        guard let binding = registrations[id], registrationPlan.contains(binding) else { return }
        switch binding.action {
        case .shortcut(let shortcutID): onShortcutTriggered?(shortcutID)
        case .toggleSettingsWindow:
            NotificationCenter.default.post(name: .toggleSettingsWindow, object: nil)
        case .toggleUtility(let featureID, let action):
            utilities?.handleHotkey(for: featureID, action: action)
        }
    }

    private static func loadSettingsWindowHotkey() -> KeyCombo {
        guard let data = UserDefaults.standard.data(forKey: settingsWindowHotkeyDefaultsKey),
            let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        else {
            return defaultSettingsWindowHotkey
        }

        return combo
    }

    private func saveSettingsWindowHotkey(_ combo: KeyCombo) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsWindowHotkeyDefaultsKey)
    }
}

private struct HotkeyBinding: Equatable, Sendable {
    let combo: KeyCombo
    let action: RegistrationAction
}

private enum RegistrationAction: Equatable, Sendable {
    case shortcut(Shortcut.ID)
    case toggleSettingsWindow
    case toggleUtility(UtilityID, String)
}

/// The native resource boundary; tests exercise the same plan/lifecycle without global key input.
@MainActor
protocol HotkeyRegistering: AnyObject {
    func start(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> Bool
    func register(id: UInt32, combo: KeyCombo) -> Bool
    func unregisterAll()
    func stop()
}

@MainActor
private final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    fileprivate var handler: (@MainActor @Sendable (UInt32) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> Bool {
        self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        return status == noErr && eventHandler != nil
    }

    func register(id: UInt32, combo: KeyCombo) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers.carbonModifiers,
            EventHotKeyID(signature: hotKeySignature, id: id),
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return false }
        references.append(reference)
        return true
    }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }

    func stop() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        handler = nil
    }
}

private let hotKeySignature: OSType = 0x5454_6763

private func hotKeyEventHandler(
    _: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in registrar.handler?(hotKeyID.id) }
    return noErr
}
