import CloudKit
import Foundation
import Testing

@testable import TapTickKit

@Suite("First Sync Merge")
struct FirstSyncMergeTests {
    private func script(name: String = "CPU", source: String = "echo 1") -> Shortcut {
        Shortcut(
            name: name, action: .runScript(script: source), createdAt: Date(timeIntervalSince1970: 10),
            modifiedAt: Date(timeIntervalSince1970: 20))
    }
    private func state(_ shortcuts: [Shortcut], deletions: [ShortcutDeletion] = []) -> ShortcutSyncState {
        ShortcutSyncState(shortcuts: shortcuts, deletions: deletions)
    }

    @Test("Identical scripts keep cloud identity and retire local identity beyond future edits")
    func identical() {
        var local = script(name: "cpu")
        local.modifiedAt = Date(timeIntervalSince1970: 1_000.5)
        let cloud = script()
        let result = FirstSyncMerge(local: state([local]), remote: state([cloud]), now: Date(timeIntervalSince1970: 30))
        #expect(result.library.shortcuts == [cloud])
        #expect(result.replacements == [local.id: cloud.id])
        #expect(
            result.library.deletions == [ShortcutDeletion(id: local.id, deletedAt: Date(timeIntervalSince1970: 1_001))])
        #expect(result.summary.identicalScripts == 1)
        #expect(CloudSyncService.merge(local: result.library, remote: state([local])).shortcuts == [cloud])
    }

    @Test("Any source or configuration difference keeps both versions", arguments: 0..<5)
    func differences(variant: Int) {
        var local = script(source: "echo é")
        let cloud = script(source: "echo é")
        switch variant {
        case 0: local.action = .runScript(script: "echo e\u{301}")
        case 1: local.action = .runScript(script: "echo é ")
        case 2: local.action = .runScript(script: "echo other")
        case 3: local.keyCombo = KeyCombo(keyCode: 0, modifiers: .command)
        default: local.isEnabled = false
        }
        let result = FirstSyncMerge(local: state([local]), remote: state([cloud]))
        #expect(result.library.shortcuts.count == 2)
        #expect(result.replacements.isEmpty)
        #expect(result.library.deletions.isEmpty)
        #expect(result.summary.keptBothPairs == 1)
    }

    @Test(
        "Only unambiguous independent same-name scripts combine; existing identities and deletions retain UUID semantics"
    )
    func matchingBoundary() {
        let local = script()
        let cloud = script()
        let copy = script(name: "CPU 2")
        let app = Shortcut(name: "CPU", action: .launchApp(bundleIdentifier: "test", appName: "test"))
        for (locals, remotes) in [
            ([copy], [cloud]), ([local, script()], [cloud]), ([local], [local, cloud]), ([app], [cloud]),
        ] {
            #expect(FirstSyncMerge(local: state(locals), remote: state(remotes)).replacements.isEmpty)
        }
        let deletion = ShortcutDeletion(id: local.id, deletedAt: local.modifiedAt)
        let deleted = FirstSyncMerge(local: state([local]), remote: state([cloud], deletions: [deletion]))
        #expect(deleted.library.shortcuts == [cloud])
        #expect(deleted.replacements.isEmpty)
        var newer = local
        newer.action = .runScript(script: "newer")
        newer.modifiedAt = local.modifiedAt.addingTimeInterval(1)
        #expect(FirstSyncMerge(local: state([local]), remote: state([newer])).library.shortcuts == [newer])
    }

    @Test(
        "Fetch and durable adoption gate sending; identical and differing scripts survive restart",
        arguments: [true, false])
    func durableMerge(identical: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirstSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = script(source: identical ? "echo 1" : "echo local")
        let cloud = script()
        var sender = CloudSyncSnapshot()
        try sender.merge(state([cloud]))
        let record = try sender.record(assetURL: directory.appendingPathComponent("asset.json"))
        var receiver = CloudSyncSnapshot()
        try receiver.merge(state([local]))
        #expect(!receiver.canAdopt && !receiver.canSend)
        try receiver.receive(record)
        #expect(receiver.canAdopt && !receiver.canSend)
        let cache = directory.appendingPathComponent("cache.json")
        try receiver.write(to: cache)
        var restored = try CloudSyncSnapshot.read(from: cache)
        let count = identical ? 1 : 2
        #expect(restored.library.shortcuts.count == count)
        #expect(restored.scriptIDReplacements?[local.id] == (identical ? cloud.id : nil))
        #expect(restored.firstSyncSummary?.identicalScripts == (identical ? 1 : 0))
        #expect(restored.firstSyncSummary?.keptBothPairs == (identical ? 0 : 1))
        restored.firstSync?.hasAdopted = true
        #expect(restored.canSend)
        try restored.merge(state([local]))
        #expect(restored.library.shortcuts.count == count)
        restored.firstSync = nil
        sender.library = state([script()])
        try restored.receive(sender.record(assetURL: directory.appendingPathComponent("next.json")))
        #expect(restored.firstSync == nil)
        #expect(restored.library.shortcuts.count == count + 1)
    }

    @Test(
        "Established caches skip first-sync deduplication; concurrent joins compose replacements until acknowledgment")
    func relationshipBoundary() throws {
        let legacy = Data("{\"version\":1,\"library\":{\"schemaVersion\":2,\"shortcuts\":[],\"deletions\":[]}}".utf8)
        var established = try JSONDecoder().decode(CloudSyncSnapshot.self, from: legacy)
        #expect(established.firstSync == nil && established.canSend)
        let local = script()
        let cloud = script()
        try established.merge(state([local]))
        try established.merge(state([cloud]))
        #expect(established.library.shortcuts.count == 2)
        var joining = CloudSyncSnapshot()
        try joining.merge(state([local]))
        joining.mergeFirstSync(state([cloud]))
        let finalCloud = script()
        joining.mergeFirstSync(state([finalCloud]))
        #expect(joining.firstSync != nil)
        #expect(joining.library.shortcuts == [finalCloud])
        #expect(joining.scriptIDReplacements?[local.id] == finalCloud.id)
        #expect(joining.scriptIDReplacements?[cloud.id] == finalCloud.id)
    }
}
