import Carbon.HIToolbox
import Foundation
import Testing
@testable import TapTickKit

@Suite("HotkeyService", .serialized)
struct HotkeyServiceTests {
    @Test("Uses the default settings window hotkey when no override is stored")
    @MainActor
    func defaultSettingsWindowHotkey() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: HotkeyService.settingsWindowHotkeyDefaultsKey)
        defaults.removeObject(forKey: HotkeyService.settingsWindowHotkeyDefaultsKey)
        defer {
            restore(previous, in: defaults)
        }

        let service = HotkeyService()
        #expect(service.settingsWindowHotkey == HotkeyService.defaultSettingsWindowHotkey)
    }

    @Test("Persists settings window hotkey overrides")
    @MainActor
    func persistsSettingsWindowHotkeyOverride() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: HotkeyService.settingsWindowHotkeyDefaultsKey)
        defer {
            restore(previous, in: defaults)
        }

        let override = KeyCombo(
            keyCode: UInt32(kVK_ANSI_Slash),
            modifiers: [.command, .control, .option]
        )

        let service = HotkeyService()
        service.updateSettingsWindowHotkey(override)

        let reloaded = HotkeyService()
        #expect(service.settingsWindowHotkey == override)
        #expect(reloaded.settingsWindowHotkey == override)
    }

    @Test("Utility hotkeys participate in conflict detection")
    @MainActor
    func utilityHotkeyConflicts() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickHotkeyService-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ShortcutStore(directory: directory)
        let utilities = UtilitiesController(directory: directory)
        let service = HotkeyService()

        service.start(store: store, utilities: utilities)
        defer { service.stop() }

        let reservedHotkey = utilities.keystrokeOverlay.hotkey
        #expect(service.hasConflict(keyCombo: reservedHotkey))
        #expect(
            service.hasConflict(
                keyCombo: reservedHotkey,
                excludingUtilityID: .keystrokeOverlay
            ) == false
        )
    }

    @Test("Registrations follow model writers and ignore changes unrelated to bindings")
    @MainActor
    func observesBindingPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TapTickHotkeys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = CloudSyncService()
        let store = ShortcutStore(directory: directory, cloudSync: cloud)
        let registrar = RecordingHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        var shortcut = Shortcut(
            name: "Script", keyCombo: KeyCombo(keyCode: 0, modifiers: [.control, .option]),
            action: .runScript(script: "#!/bin/sh\necho initial"))
        store.add(shortcut)
        service.start(store: store)
        defer { service.stop() }
        #expect(registrar.registered.values.contains(shortcut.keyCombo!))

        let remote = Shortcut(
            name: "Remote", keyCombo: KeyCombo(keyCode: 1, modifiers: [.control, .option]),
            action: .launchApp(bundleIdentifier: "test.remote", appName: "Remote"))
        cloud.onRemoteChange?(ShortcutSyncState(shortcuts: [remote], deletions: []))
        try await waitUntil { registrar.registered.values.contains(remote.keyCombo!) }
        let registrationsBefore = registrar.registrationCount
        store.markTriggered(id: shortcut.id)
        shortcut.action = .runScript(script: "#!/bin/sh\necho edited")
        try store.updateScript(shortcut)
        try await Task.sleep(for: .milliseconds(80))
        #expect(registrar.registrationCount == registrationsBefore)

        let oldID = try #require(registrar.registered.first { $0.value == shortcut.keyCombo }?.key)
        var triggered: [UUID] = []
        service.onShortcutTriggered = { triggered.append($0) }
        store.toggleEnabled(id: shortcut.id)
        registrar.handler?(oldID)
        #expect(triggered.isEmpty)
        try await waitUntil { !registrar.registered.values.contains(shortcut.keyCombo!) }
        store.remove(id: remote.id)
        try await waitUntil { registrar.registered.count == 1 }
    }

    @Test("Nested recorder suspension applies the latest user and utility bindings only on final resume")
    @MainActor
    func nestedSuspension() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TapTickHotkeys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let utilities = UtilitiesController(directory: directory)
        let registrar = RecordingHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        service.start(store: store, utilities: utilities)
        defer { service.stop() }
        service.suspendRegistrations()
        service.suspendRegistrations()
        let combo = KeyCombo(keyCode: 2, modifiers: [.control, .option])
        utilities.updateKeystrokeOverlayHotkey(combo)
        let shortcut = Shortcut(
            name: "Conflict", keyCombo: combo,
            action: .launchApp(bundleIdentifier: "test.conflict", appName: "Conflict"))
        store.add(shortcut)
        try await Task.sleep(for: .milliseconds(30))
        #expect(registrar.registered.isEmpty)
        service.resumeRegistrations()
        #expect(registrar.registered.isEmpty)
        service.resumeRegistrations()
        #expect(registrar.registered.values.filter { $0 == combo }.count == 1)
        #expect(service.isListening)
        #expect(service.hasConflict(keyCombo: combo))
    }

    @Test("Stopped services stay stopped, restart observes only the current store, and stale IDs are ignored")
    @MainActor
    func stopAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TapTickHotkeys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ShortcutStore(directory: directory.appendingPathComponent("first"))
        let second = ShortcutStore(directory: directory.appendingPathComponent("second"))
        let registrar = RecordingHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        let shortcut = Shortcut(
            name: "App", keyCombo: KeyCombo(keyCode: 3, modifiers: [.control, .option]),
            action: .launchApp(bundleIdentifier: "test.app", appName: "App"))
        first.add(shortcut)
        service.start(store: first)
        let oldID = try #require(registrar.registered.first { $0.value == shortcut.keyCombo }?.key)
        let oldHandler = registrar.handler
        service.stop()
        first.toggleEnabled(id: shortcut.id)
        service.suspendRegistrations()
        service.resumeRegistrations()
        try await Task.sleep(for: .milliseconds(30))
        #expect(registrar.registered.isEmpty)
        #expect(registrar.handler == nil)
        #expect(!service.isListening)
        second.add(shortcut)
        service.start(store: second)
        defer { service.stop() }
        var triggered: [UUID] = []
        service.onShortcutTriggered = { triggered.append($0) }
        oldHandler?(oldID)
        #expect(triggered.isEmpty)
        let currentID = try #require(registrar.registered.first { $0.value == shortcut.keyCombo }?.key)
        registrar.handler?(currentID)
        #expect(triggered == [shortcut.id])
        let count = registrar.registrationCount
        first.toggleEnabled(id: shortcut.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(registrar.registrationCount == count)
    }

    @Test("Service teardown cancels observation and releases native registrations")
    @MainActor
    func releasesNativeLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TapTickHotkeys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let registrar = RecordingHotkeyRegistrar()
        var service: HotkeyService? = HotkeyService(registrar: registrar)
        weak var observed = service
        service?.start(store: store)
        try await Task.sleep(for: .milliseconds(30))
        service = nil
        try await waitUntil { observed == nil }
        #expect(registrar.registered.isEmpty)
        #expect(registrar.handler == nil)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @MainActor
    private func restore(_ previous: Data?, in defaults: UserDefaults) {
        if let previous {
            defaults.set(previous, forKey: HotkeyService.settingsWindowHotkeyDefaultsKey)
        } else {
            defaults.removeObject(forKey: HotkeyService.settingsWindowHotkeyDefaultsKey)
        }
    }
}

@MainActor
private final class RecordingHotkeyRegistrar: HotkeyRegistering {
    var registered: [UInt32: KeyCombo] = [:]
    var registrationCount = 0
    var handler: (@MainActor @Sendable (UInt32) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> Bool {
        self.handler = handler
        return true
    }
    func register(id: UInt32, combo: KeyCombo) -> Bool {
        registered[id] = combo
        registrationCount += 1
        return true
    }
    func unregisterAll() { registered.removeAll() }
    func stop() {
        unregisterAll()
        handler = nil
    }
}
