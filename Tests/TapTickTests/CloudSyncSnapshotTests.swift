import CloudKit
import Foundation
import Testing

@testable import TapTickKit

@MainActor
struct CloudSyncSnapshotTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Equal-time edits converge regardless of arrival order")
    func deterministicConflict() {
        let date = Date(timeIntervalSince1970: 42)
        var first = Shortcut(name: "a", action: .runScript(script: "echo a"), createdAt: date, modifiedAt: date)
        var second = first
        second.name = "b"
        second.action = .runScript(script: "echo b")
        first.lastTriggeredAt = Date()
        let a = CloudSyncSnapshot.portable(ShortcutSyncState(shortcuts: [first], deletions: []))
        let b = CloudSyncSnapshot.portable(ShortcutSyncState(shortcuts: [second], deletions: []))
        #expect(CloudSyncService.merge(local: a, remote: b) == CloudSyncService.merge(local: b, remote: a))
        #expect(a.shortcuts[0].lastTriggeredAt == nil)
    }

    @Test("Downloaded scripts and tombstones survive interruption before store adoption")
    func durableInbox() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortcut = Shortcut(name: "test.sh", action: .runScript(script: "#!/bin/sh\necho hello"))
        let deletion = ShortcutDeletion(id: UUID(), deletedAt: Date())
        var sender = CloudSyncSnapshot()
        try sender.merge(ShortcutSyncState(shortcuts: [shortcut], deletions: [deletion]))
        let record = try sender.record(assetURL: directory.appendingPathComponent("asset.json"))
        var receiver = CloudSyncSnapshot()
        receiver.account = "account-a"
        try receiver.receive(record)
        let cache = directory.appendingPathComponent("cache.json")
        try receiver.write(to: cache)
        let restored = try CloudSyncSnapshot.read(from: cache)
        #expect(restored.library == sender.library)
        #expect(restored.account == "account-a")
        #expect(!restored.needsUpload)
        #expect(restored.recordFields != nil)
    }

    @Test("An edit during upload stays pending after the older upload is acknowledged")
    func editDuringUpload() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var shortcut = Shortcut(name: "test.sh", action: .runScript(script: "echo old"))
        var snapshot = CloudSyncSnapshot()
        try snapshot.merge(ShortcutSyncState(shortcuts: [shortcut], deletions: []))
        let sending = snapshot.library
        let record = try snapshot.record(assetURL: directory.appendingPathComponent("asset.json"))
        shortcut.modifiedAt = shortcut.modifiedAt.addingTimeInterval(1)
        shortcut.action = .runScript(script: "echo new")
        try snapshot.merge(ShortcutSyncState(shortcuts: [shortcut], deletions: []))
        snapshot.acknowledge(record, library: sending)
        #expect(snapshot.needsUpload)
        #expect(snapshot.library.shortcuts[0].action == .runScript(script: "echo new"))
    }

    @Test("Stale cloud data cannot resurrect locally deleted scripts")
    func deletionSurvives() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortcut = Shortcut(name: "test.sh", action: .runScript(script: "echo old"))
        var old = CloudSyncSnapshot()
        try old.merge(ShortcutSyncState(shortcuts: [shortcut], deletions: []))
        let record = try old.record(assetURL: directory.appendingPathComponent("asset.json"))
        var current = CloudSyncSnapshot()
        try current.merge(
            ShortcutSyncState(
                shortcuts: [], deletions: [ShortcutDeletion(id: shortcut.id, deletedAt: shortcut.modifiedAt)]))
        try current.receive(record)
        #expect(current.library.shortcuts.isEmpty)
        #expect(current.library.deletions.count == 1)
        #expect(current.needsUpload)
    }

    @Test("Unknown server format leaves the durable inbox unchanged")
    func unknownFormat() throws {
        var snapshot = CloudSyncSnapshot()
        let record = CKRecord(recordType: "ShortcutLibrary", recordID: CloudSyncSnapshot.recordID)
        record["schemaVersion"] = 999
        #expect(throws: (any Error).self) { try snapshot.receive(record) }
        #expect(snapshot.library == .empty)
        #expect(snapshot.acknowledged == nil)
    }

    @Test("A corrupt cache fails closed rather than discarding its account binding")
    func corruptCache() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.json")
        try Data("invalid".utf8).write(to: cache)
        #expect(throws: (any Error).self) { try CloudSyncSnapshot.read(from: cache) }
    }
}
