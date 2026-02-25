import Testing
import Foundation
@testable import KeyMagicKit

@Suite("ShortcutStore")
struct ShortcutStoreTests {

    /// Create a store backed by a temporary directory.
    private func makeStore() -> ShortcutStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyMagicTests-\(UUID().uuidString)")
        return ShortcutStore(directory: dir)
    }

    private func makeSampleShortcut(
        name: String = "Test",
        keyCode: UInt32 = 0,
        modifiers: KeyCombo.Modifiers = .command
    ) -> Shortcut {
        Shortcut(
            name: name,
            keyCombo: KeyCombo(keyCode: keyCode, modifiers: modifiers),
            action: .launchApp(bundleIdentifier: "com.test", appName: "Test")
        )
    }

    @Test("Starts empty")
    func startsEmpty() {
        let store = makeStore()
        #expect(store.shortcuts.isEmpty)
    }

    @Test("Add shortcut")
    func addShortcut() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        #expect(store.shortcuts.count == 1)
        #expect(store.shortcuts.first?.name == "Test")
    }

    @Test("Update shortcut")
    func updateShortcut() {
        let store = makeStore()
        var shortcut = makeSampleShortcut()
        store.add(shortcut)
        shortcut.name = "Updated"
        store.update(shortcut)
        #expect(store.shortcuts.first?.name == "Updated")
    }

    @Test("Remove shortcut by ID")
    func removeByID() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        store.remove(id: shortcut.id)
        #expect(store.shortcuts.isEmpty)
    }

    @Test("Remove at offsets")
    func removeAtOffsets() {
        let store = makeStore()
        store.add(makeSampleShortcut(name: "A"))
        store.add(makeSampleShortcut(name: "B"))
        store.add(makeSampleShortcut(name: "C"))
        store.remove(atOffsets: IndexSet(integer: 1))
        #expect(store.shortcuts.count == 2)
        #expect(store.shortcuts.map(\.name) == ["A", "C"])
    }

    @Test("Toggle enabled")
    func toggleEnabled() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        #expect(store.shortcuts.first?.isEnabled == true)
        store.toggleEnabled(id: shortcut.id)
        #expect(store.shortcuts.first?.isEnabled == false)
        store.toggleEnabled(id: shortcut.id)
        #expect(store.shortcuts.first?.isEnabled == true)
    }

    @Test("Mark triggered")
    func markTriggered() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        #expect(store.shortcuts.first?.lastTriggeredAt == nil)
        store.markTriggered(id: shortcut.id)
        #expect(store.shortcuts.first?.lastTriggeredAt != nil)
    }

    @Test("Find shortcut by key combo")
    func findByKeyCombo() {
        let store = makeStore()
        let combo = KeyCombo(keyCode: 0, modifiers: .command)
        let shortcut = Shortcut(
            name: "Find Me",
            keyCombo: combo,
            action: .launchApp(bundleIdentifier: "com.test", appName: "Test")
        )
        store.add(shortcut)

        let found = store.shortcut(for: combo)
        #expect(found?.name == "Find Me")

        // Disabled shortcuts should not be found
        store.toggleEnabled(id: shortcut.id)
        #expect(store.shortcut(for: combo) == nil)
    }

    @Test("Conflict detection")
    func conflictDetection() {
        let store = makeStore()
        let combo = KeyCombo(keyCode: 0, modifiers: .command)
        let s1 = Shortcut(name: "S1", keyCombo: combo, action: .launchApp(bundleIdentifier: "com.a", appName: "A"))
        let s2 = Shortcut(name: "S2", keyCombo: combo, action: .launchApp(bundleIdentifier: "com.b", appName: "B"))

        store.add(s1)
        #expect(!store.hasConflict(keyCombo: combo, excludingID: s1.id))
        #expect(store.hasConflict(keyCombo: combo, excludingID: s2.id))
        #expect(store.hasConflict(keyCombo: combo))
    }

    @Test("Persistence round-trip")
    func persistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyMagicTests-\(UUID().uuidString)")

        let store1 = ShortcutStore(directory: dir)
        store1.add(makeSampleShortcut(name: "Persisted"))

        let store2 = ShortcutStore(directory: dir)
        #expect(store2.shortcuts.count == 1)
        #expect(store2.shortcuts.first?.name == "Persisted")

        // Clean up
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Export and import")
    func exportImport() throws {
        let store1 = makeStore()
        store1.add(makeSampleShortcut(name: "Export1"))
        store1.add(makeSampleShortcut(name: "Export2"))

        let data = try store1.exportData()

        let store2 = makeStore()
        try store2.importData(data)
        #expect(store2.shortcuts.count == 2)
        #expect(store2.shortcuts.map(\.name).contains("Export1"))
        #expect(store2.shortcuts.map(\.name).contains("Export2"))
    }

    @Test("Update non-existent ID is no-op")
    func updateNonExistent() {
        let store = makeStore()
        var shortcut = makeSampleShortcut()
        shortcut = Shortcut(
            id: UUID(), // different ID
            name: "Ghost",
            keyCombo: shortcut.keyCombo,
            action: shortcut.action
        )
        store.update(shortcut) // should not crash
        #expect(store.shortcuts.isEmpty)
    }

    @Test("Remove non-existent ID is no-op")
    func removeNonExistent() {
        let store = makeStore()
        store.remove(id: UUID()) // should not crash
        #expect(store.shortcuts.isEmpty)
    }
}
