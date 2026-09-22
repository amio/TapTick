import Foundation
import Testing
@testable import TapTickKit

@Suite("Shortcut persistence boundaries")
@MainActor
struct ShortcutPersistenceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TapTickPersistence-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script(_ name: String, source: String = "#!/bin/sh\necho original") -> Shortcut {
        Shortcut(name: name, action: .runScript(script: source))
    }

    @Test(
        "Unreadable libraries preserve bytes and files until successful retry",
        arguments: [
            "{broken JSON",
            "{\"schemaVersion\":999,\"shortcuts\":[],\"deletions\":[],\"futureField\":42}",
            "{\"schemaVersion\":2,\"shortcuts\":[{\"unknown\":true}],\"deletions\":[]}",
        ])
    func failedLoadIsNotAnEmptyLibrary(json: String) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shortcuts.json")
        let original = Data(json.utf8)
        try original.write(to: file)
        let scripts = directory.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let stored = script("Preserved")
        let source = "#!/bin/sh\necho original"
        try Data(source.utf8).write(to: scripts.appendingPathComponent(stored.name))
        let store = ShortcutStore(directory: directory)

        #expect(store.loadIssue != nil)
        store.add(script("Must not be added"))
        store.remove(id: stored.id)
        store.reconcileScriptDirectory()
        store.performFullSync()
        #expect(throws: (any Error).self) { try store.createScript() }
        #expect(throws: (any Error).self) { try store.importData(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try store.exportData() }
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scripts.path) == [stored.name])

        let repaired = ShortcutSyncState(shortcuts: [stored], deletions: [])
        try JSONEncoder().encode(repaired).write(to: file)
        store.reloadFromDisk()
        #expect(store.loadIssue == nil)
        #expect(store.shortcuts.map(\.id) == [stored.id])
        store.toggleEnabled(id: stored.id)
        #expect(store.shortcuts.first?.isEnabled == false)
    }

    @Test("A read failure does not create the managed directory")
    func readFailure() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("shortcuts.json"), withIntermediateDirectories: true)
        let store = ShortcutStore(directory: directory)
        #expect(store.loadIssue != nil)
        #expect(!FileManager.default.fileExists(atPath: store.scriptsDirectoryURL.path))
    }

    @Test("Legacy migration retries never leave partial files or duplicate migrated scripts")
    func legacyMigrationRetry() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = [script("First"), script(String(repeating: "a", count: 255))]
        let metadata = try JSONEncoder().encode(originals)
        let file = directory.appendingPathComponent("shortcuts.json")
        try metadata.write(to: file)
        let scripts = directory.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let occupied = scripts.appendingPathComponent(originals[1].name)
        try Data("existing unrelated file".utf8).write(to: occupied)
        let store = ShortcutStore(directory: directory)

        for _ in 0..<2 {
            #expect(store.loadIssue != nil)
            #expect(try Data(contentsOf: file) == metadata)
            #expect(try FileManager.default.contentsOfDirectory(atPath: scripts.path) == [originals[1].name])
            store.reloadFromDisk()
        }
        try FileManager.default.removeItem(at: occupied)
        store.reloadFromDisk()
        #expect(store.loadIssue == nil)
        #expect(store.shortcuts.map(\.id) == originals.map(\.id))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: scripts.path)) == Set(originals.map(\.name)))
        store.reloadFromDisk()
        #expect(store.shortcuts.map(\.id) == originals.map(\.id))
    }

    @Test("Import preparation failures leave the original library unchanged")
    func importPreflightFailure() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let original = script("Original")
        store.add(original)
        let originalData = try Data(contentsOf: directory.appendingPathComponent("shortcuts.json"))
        let unavailable = Shortcut(
            name: "Missing", action: .runScriptFile(path: directory.appendingPathComponent("absent").path, shell: .bash)
        )
        let duplicate = script("Duplicate")
        let invalidImports = [
            Data("invalid".utf8), try JSONEncoder().encode([unavailable]),
            try JSONEncoder().encode([duplicate, duplicate]),
        ]
        for data in invalidImports {
            #expect(throws: (any Error).self) { try store.importData(data) }
            #expect(store.shortcuts.map(\.id) == [original.id])
            #expect(try Data(contentsOf: directory.appendingPathComponent("shortcuts.json")) == originalData)
            #expect(
                try String(contentsOf: store.scriptsDirectoryURL.appendingPathComponent(original.name), encoding: .utf8)
                    == "#!/bin/sh\necho original")
        }
    }

    @Test("Metadata commit failure rolls back installed and removed script files")
    func importCommitRollback() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let first = script("First")
        let second = script("Second")
        store.add(first)
        store.add(second)
        let previous = store.shortcuts
        let file = directory.appendingPathComponent("shortcuts.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let incoming = [script("First", source: "#!/bin/sh\necho changed"), script("New")]

        #expect(throws: (any Error).self) { try store.importData(JSONEncoder().encode(incoming)) }

        #expect(store.shortcuts == previous)
        #expect(store.deletions.isEmpty)
        #expect(store.loadIssue == nil)
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: store.scriptsDirectoryURL.path)) == [
                "First", "Second",
            ])
        for original in [first, second] {
            #expect(
                try String(contentsOf: store.scriptsDirectoryURL.appendingPathComponent(original.name), encoding: .utf8)
                    == "#!/bin/sh\necho original")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
                !$0.hasPrefix(".shortcut-import-")
            })
    }

    @Test("Import resolves legacy scripts and collisions while preserving non-managed entries")
    func importFilesAndReload() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        store.add(script("Replaced"))
        let scripts = store.scriptsDirectoryURL
        try FileManager.default.createDirectory(
            at: scripts.appendingPathComponent("Reserved"), withIntermediateDirectories: true)
        try Data("external file".utf8).write(to: scripts.appendingPathComponent("Untracked"))
        try Data("hidden".utf8).write(to: scripts.appendingPathComponent(".hidden"))
        let external = directory.appendingPathComponent("legacy")
        try Data("echo legacy".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: scripts.appendingPathComponent("Link"), withDestinationURL: external)
        let legacy = Shortcut(name: "Reserved", action: .runScriptFile(path: external.path, shell: .bash))
        let incoming = [legacy, script("reserved"), script("Link"), script("Untracked")]

        try store.importData(JSONEncoder().encode(incoming))

        #expect(store.shortcuts.map(\.name) == ["Reserved 2", "reserved 3", "Link 2", "Untracked 2"])
        #expect(store.shortcuts.first?.action == .runScript(script: "#!/bin/bash\n\necho legacy"))
        #expect(try String(contentsOf: scripts.appendingPathComponent("Untracked"), encoding: .utf8) == "external file")
        #expect(try String(contentsOf: scripts.appendingPathComponent(".hidden"), encoding: .utf8) == "hidden")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: scripts.appendingPathComponent("Link").path)
                == external.path)
        #expect(FileManager.default.isExecutableFile(atPath: scripts.appendingPathComponent("Reserved 2").path))
        let reloaded = ShortcutStore(directory: directory)
        #expect(Set(reloaded.shortcuts.map(\.id)).isSuperset(of: Set(incoming.map(\.id))))
        #expect(!FileManager.default.fileExists(atPath: scripts.appendingPathComponent("Replaced").path))
    }

    @Test("Imported restoration and replacement survive cloud precision and future known events")
    func importTombstoneSemantics() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let future = Date().addingTimeInterval(3600)
        var replaced = script("Replaced")
        replaced.modifiedAt = future
        var restored = script("Restored")
        restored.modifiedAt = future.addingTimeInterval(-1)
        let unrelated = UUID()
        let old = ShortcutSyncState(
            shortcuts: [replaced],
            deletions: [
                ShortcutDeletion(id: restored.id, deletedAt: future.addingTimeInterval(0.9)),
                ShortcutDeletion(id: unrelated, deletedAt: future),
            ])
        let scripts = directory.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho original".utf8).write(to: scripts.appendingPathComponent(replaced.name))
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("shortcuts.json"))
        let store = ShortcutStore(directory: directory)
        try store.importData(JSONEncoder().encode([restored]))
        let state = ShortcutSyncState(shortcuts: store.shortcuts, deletions: store.deletions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transported = try ShortcutSyncState.decode(from: encoder.encode(state), using: decoder)
        let merged = CloudSyncService.merge(local: transported, remote: old)
        #expect(merged.shortcuts.map(\.id) == [restored.id])
        #expect(Set(merged.deletions.map(\.id)) == [unrelated, replaced.id])
        let reloaded = ShortcutStore(directory: directory)
        #expect(reloaded.shortcuts.map(\.id) == [restored.id])
        #expect(Set(reloaded.deletions.map(\.id)) == [unrelated, replaced.id])
    }

    @Test("Unsupported constructed remote state does not modify a valid local library")
    func unsupportedRemoteState() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = CloudSyncService()
        let store = ShortcutStore(directory: directory, cloudSync: cloud)
        store.add(script("Local"))
        let before = try Data(contentsOf: directory.appendingPathComponent("shortcuts.json"))
        cloud.onRemoteChange?(ShortcutSyncState(schemaVersion: 999, shortcuts: [], deletions: []))
        #expect(store.scriptDirectoryIssue != nil)
        #expect(store.shortcuts.count == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent("shortcuts.json")) == before)
    }
}
