import Testing
import Foundation
@testable import TapTickKit

@Suite("ShortcutStore")
@MainActor
struct ShortcutStoreTests {

    /// Create a store backed by a temporary directory.
    private func makeStore() -> ShortcutStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
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

    private func makeScriptShortcut(
        name: String = "Script",
        script: String = "#!/bin/zsh\necho initial"
    ) -> Shortcut {
        Shortcut(
            name: name,
            action: .runScript(script: script)
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

    @Test("Script updates preserve unrelated current fields")
    func scriptUpdatePreservesUnrelatedFields() throws {
        let store = makeStore()
        var shortcut = makeScriptShortcut()
        store.add(shortcut)

        let hotkey = KeyCombo(keyCode: 12, modifiers: .command)
        var rebound = shortcut
        rebound.keyCombo = hotkey
        store.update(rebound)

        shortcut.name = "Updated Script"
        shortcut.action = .runScript(script: "#!/bin/bash\necho updated")
        try store.updateScript(shortcut)

        #expect(store.shortcuts.first?.name == "Updated Script")
        #expect(store.shortcuts.first?.action == .runScript(script: "#!/bin/bash\necho updated"))
        #expect(store.shortcuts.first?.keyCombo == hotkey)
    }

    @Test("Remove shortcut by ID")
    func removeByID() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        store.remove(id: shortcut.id)
        #expect(store.shortcuts.isEmpty)
        #expect(store.deletions.map(\.id) == [shortcut.id])
    }

    @Test("Re-adding a deleted shortcut clears its deletion record")
    func readdDeletedShortcut() {
        let store = makeStore()
        let shortcut = makeSampleShortcut()
        store.add(shortcut)
        store.remove(id: shortcut.id)

        store.add(shortcut)

        #expect(store.shortcuts.map(\.id) == [shortcut.id])
        #expect(store.deletions.isEmpty)
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
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")

        let store1 = ShortcutStore(directory: dir)
        store1.add(makeSampleShortcut(name: "Persisted"))

        let store2 = ShortcutStore(directory: dir)
        #expect(store2.shortcuts.count == 1)
        #expect(store2.shortcuts.first?.name == "Persisted")

        // Clean up
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Deletion records survive persistence and block stale shortcuts")
    func deletionPersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let shortcut = makeSampleShortcut(name: "Removed")
        let firstStore = ShortcutStore(directory: dir)
        firstStore.add(shortcut)
        firstStore.remove(id: shortcut.id)

        let restoredStore = ShortcutStore(directory: dir)
        #expect(restoredStore.shortcuts.isEmpty)
        #expect(restoredStore.deletions.map(\.id) == [shortcut.id])

        let deletionDate = try #require(restoredStore.deletions.first?.deletedAt)
        var staleShortcut = shortcut
        staleShortcut.modifiedAt = deletionDate.addingTimeInterval(-60)
        let staleState = ShortcutSyncState(shortcuts: [staleShortcut], deletions: [])
        let localState = ShortcutSyncState(
            shortcuts: restoredStore.shortcuts,
            deletions: restoredStore.deletions
        )
        let merged = CloudSyncService.merge(local: localState, remote: staleState)
        #expect(merged.shortcuts.isEmpty)
    }

    @Test("Legacy local arrays load and migrate to the sync envelope")
    func legacyLocalMigration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let shortcut = makeSampleShortcut(name: "Legacy")
        let legacyData = try JSONEncoder().encode([shortcut])
        let fileURL = dir.appendingPathComponent("shortcuts.json")
        try legacyData.write(to: fileURL)

        let store = ShortcutStore(directory: dir)
        #expect(store.shortcuts.map(\.name) == ["Legacy"])
        #expect(store.deletions.isEmpty)

        store.toggleEnabled(id: shortcut.id)
        let savedData = try Data(contentsOf: fileURL)
        let savedState = try JSONDecoder().decode(ShortcutSyncState.self, from: savedData)
        #expect(savedState.shortcuts.count == 1)
        #expect(savedState.deletions.isEmpty)
    }

    @Test("Legacy inline scripts migrate to managed files with their selected shell")
    func legacyInlineScriptMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let data = Data(
            """
            [{
              "id": "\(id.uuidString)",
              "name": "Legacy Script",
              "action": {"runScript": {"script": "echo legacy", "shell": "/bin/bash"}},
              "isEnabled": true,
              "createdAt": 0,
              "modifiedAt": 0
            }]
            """.utf8
        )
        try data.write(to: directory.appendingPathComponent("shortcuts.json"))

        let store = ShortcutStore(directory: directory)
        let expectedSource = "#!/bin/bash\n\necho legacy"

        #expect(store.shortcuts.first?.action == .runScript(script: expectedSource))
        #expect(
            try String(
                contentsOf: store.scriptsDirectoryURL.appendingPathComponent("Legacy Script"),
                encoding: .utf8
            ) == expectedSource
        )
        let saved = try JSONDecoder().decode(
            ShortcutSyncState.self,
            from: Data(contentsOf: directory.appendingPathComponent("shortcuts.json"))
        )
        #expect(saved.schemaVersion == ShortcutSyncState.currentSchemaVersion)
    }

    @Test("Export and import")
    func exportImport() throws {
        let store1 = makeStore()
        store1.add(makeSampleShortcut(name: "Export1"))
        store1.add(makeSampleShortcut(name: "Export2"))

        let data = try store1.exportData()
        let exportedShortcuts = try JSONDecoder().decode([Shortcut].self, from: data)
        #expect(exportedShortcuts.count == 2)

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
            id: UUID(),  // different ID
            name: "Ghost",
            keyCombo: shortcut.keyCombo,
            action: shortcut.action
        )
        store.update(shortcut)  // should not crash
        #expect(store.shortcuts.isEmpty)
    }

    @Test("Remove non-existent ID is no-op")
    func removeNonExistent() {
        let store = makeStore()
        store.remove(id: UUID())  // should not crash
        #expect(store.shortcuts.isEmpty)
    }

    @Test("Managed scripts are persisted as readable executable files")
    func persistsManagedScriptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let shortcut = makeScriptShortcut(name: "Readable Script")

        store.add(shortcut)

        let url = store.scriptsDirectoryURL.appendingPathComponent("Readable Script")
        #expect(try String(contentsOf: url, encoding: .utf8) == "#!/bin/zsh\necho initial")
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }

    @Test("Renaming to an occupied script name reports a conflict")
    func renameCollision() throws {
        let store = makeStore()
        store.add(makeScriptShortcut(name: "First"))
        store.add(makeScriptShortcut(name: "Second"))
        var second = try #require(store.shortcuts.first { $0.name == "Second" })
        second.name = "First"

        #expect(throws: ScriptStoreError.nameExists("First")) {
            try store.updateScript(second)
        }
        #expect(store.shortcuts.map(\.name).contains("Second"))
    }

    @Test("Reconciliation adopts external adds, edits, and deletes")
    func reconcilesExternalChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        store.add(makeScriptShortcut(name: "Existing"))

        let existingURL = store.scriptsDirectoryURL.appendingPathComponent("Existing")
        let addedURL = store.scriptsDirectoryURL.appendingPathComponent("Added.py")
        try Data("#!/bin/sh\necho edited".utf8).write(to: existingURL, options: .atomic)
        try Data("#!/usr/bin/env python3\nprint('added')".utf8).write(to: addedURL)

        store.reconcileScriptDirectory()

        #expect(
            store.shortcuts.first { $0.name == "Existing" }?.action
                == .runScript(script: "#!/bin/sh\necho edited")
        )
        #expect(store.shortcuts.contains { $0.name == "Added.py" })

        try FileManager.default.removeItem(at: existingURL)
        store.reconcileScriptDirectory()

        #expect(!store.shortcuts.contains { $0.name == "Existing" })
        #expect(store.deletions.count == 1)
    }

    @Test("Reconciliation ignores scripts in subdirectories")
    func ignoresSubdirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let nestedDirectory = store.scriptsDirectoryURL.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho nested".utf8).write(
            to: nestedDirectory.appendingPathComponent("Nested Script")
        )

        store.reconcileScriptDirectory()

        #expect(store.shortcuts.isEmpty)
    }

    @Test("Directory monitor adopts top-level external changes automatically")
    func watchesExternalChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        store.add(makeScriptShortcut(name: "Watched"))
        let url = store.scriptsDirectoryURL.appendingPathComponent("Watched")
        let expectedSource = "#!/bin/sh\necho watched"

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(expectedSource.utf8))
        try handle.close()

        for _ in 0..<150 {
            if store.shortcuts.first?.action == .runScript(script: expectedSource) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.shortcuts.first?.action == .runScript(script: expectedSource))

        let addedURL = store.scriptsDirectoryURL.appendingPathComponent("Externally Added")
        try Data("#!/bin/sh\necho added".utf8).write(to: addedURL)
        for _ in 0..<150 {
            if store.shortcuts.contains(where: { $0.name == "Externally Added" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.shortcuts.contains { $0.name == "Externally Added" })

        try FileManager.default.removeItem(at: url)
        for _ in 0..<150 {
            if !store.shortcuts.contains(where: { $0.name == "Watched" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.shortcuts.contains { $0.name == "Watched" })
    }
}
