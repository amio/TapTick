import Foundation
import Testing

@testable import TapTickKit

@Suite("First Sync Adoption")
@MainActor
struct FirstSyncAdoptionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FirstSyncAdoption-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Combining scripts preserves trigger history, menu-bar references, and bounded execution history")
    func preservesLocalReferences() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let source = "#!/bin/sh\necho hello"
        let local = Shortcut(name: "CPU", action: .runScript(script: source))
        let cloud = Shortcut(name: "CPU", action: .runScript(script: source))
        store.add(local)
        store.markTriggered(id: local.id)
        let trigger = try #require(store.shortcuts[0].lastTriggeredAt)
        let menu = MenuBarTextController(store: store, directory: directory)
        let slotID = menu.addSlot()
        menu.updateSlot(id: slotID) {
            $0.topLine.scriptID = local.id
            $0.bottomLine.scriptID = local.id
            $0.topLine.refreshIntervalSeconds = 30
        }
        let history = (0..<40).map { index in
            ScriptExecutionLog(
                shortcutID: index < 20 ? local.id : cloud.id,
                output: "run \(index)", exitCode: 0, timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        try JSONEncoder().encode(["logs": history]).write(to: directory.appendingPathComponent("script-logs.json"))
        let logs = ScriptLogStore(directory: directory)
        store.onScriptIDsReplaced = { replacements in
            try menu.replaceScriptIDs(replacements)
            try logs.replaceScriptIDs(replacements)
        }
        let result = FirstSyncMerge(
            local: ShortcutSyncState(shortcuts: store.shortcuts, deletions: []),
            remote: ShortcutSyncState(shortcuts: [cloud], deletions: []))
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        #expect(store.shortcuts.count == 1)
        #expect(store.shortcuts[0].id == cloud.id)
        #expect(store.shortcuts[0].lastTriggeredAt == trigger)
        #expect(menu.slots[0].topLine.scriptID == cloud.id)
        #expect(menu.slots[0].bottomLine.scriptID == cloud.id)
        #expect(menu.slots[0].topLine.refreshIntervalSeconds == 30)
        #expect(logs.recentLogs(for: cloud.id).count == ScriptLogStore.recentLogLimit)
        #expect(logs.recentLogs(for: local.id).isEmpty)
        #expect(logs.recentLogs.first?.output == "run 39")
        let restoredMenu = MenuBarTextController(store: store, directory: directory)
        let restoredLogs = ScriptLogStore(directory: directory)
        #expect(restoredMenu.slots[0].topLine.scriptID == cloud.id)
        #expect(restoredLogs.recentLogs(for: cloud.id).count == ScriptLogStore.recentLogLimit)
        // Runs started before adoption can finish after it.
        logs.record(ScriptExecutionLog(shortcutID: local.id, output: "late", exitCode: 0, timestamp: Date()))
        #expect(logs.recentLogs.first?.shortcutID == cloud.id)
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        #expect(store.shortcuts.count == 1)
        #expect(store.shortcuts[0].lastTriggeredAt == trigger)
        #expect(logs.recentLogs(for: cloud.id).count == ScriptLogStore.recentLogLimit)
    }

    @Test("A failed reference write can replay after the script library has already committed")
    func retriesReferenceWrite() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let local = Shortcut(name: "CPU", action: .runScript(script: "echo 1"))
        let cloud = Shortcut(name: "CPU", action: .runScript(script: "echo 1"))
        store.add(local)
        let menu = MenuBarTextController(store: store, directory: directory)
        let slot = menu.addSlot()
        menu.updateSlot(id: slot) { $0.topLine.scriptID = local.id }
        store.onScriptIDsReplaced = { try menu.replaceScriptIDs($0) }
        let result = FirstSyncMerge(
            local: ShortcutSyncState(shortcuts: store.shortcuts, deletions: []),
            remote: ShortcutSyncState(shortcuts: [cloud], deletions: [])
        )
        let menuFile = directory.appendingPathComponent("menu-bar-text.json")
        try FileManager.default.removeItem(at: menuFile)
        try FileManager.default.createDirectory(at: menuFile, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try store.applyRemoteChanges(result.library, replacements: result.replacements)
        }
        #expect(store.shortcuts[0].id == cloud.id)
        #expect(menu.slots[0].topLine.scriptID == local.id)
        try FileManager.default.removeItem(at: menuFile)
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        #expect(menu.slots[0].topLine.scriptID == cloud.id)
        #expect(store.scriptDirectoryIssue == nil)
    }

    @Test("Preserving differing versions still creates separate managed script files")
    func keepBothVersions() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let local = Shortcut(name: "CPU", action: .runScript(script: "echo local"))
        let cloud = Shortcut(name: "CPU", action: .runScript(script: "echo cloud"))
        store.add(local)
        let result = FirstSyncMerge(
            local: ShortcutSyncState(shortcuts: store.shortcuts, deletions: []),
            remote: ShortcutSyncState(shortcuts: [cloud], deletions: [])
        )
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        #expect(store.shortcuts.count == 2)
        #expect(Set(store.shortcuts.map(\.name)) == Set(["CPU", "CPU 2"]))
        for shortcut in store.shortcuts {
            guard case .runScript(let source) = shortcut.action else { continue }
            let file = store.scriptsDirectoryURL.appendingPathComponent(shortcut.name)
            #expect(try String(contentsOf: file, encoding: .utf8) == source)
        }
    }

    @Test("File reconciliation preserves source byte differences before first-sync matching")
    func sourceBytes() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let cloud = Shortcut(name: "CPU", action: .runScript(script: "echo é"))
        store.add(Shortcut(name: "CPU", action: cloud.action))
        let source = "echo e\u{301}"
        try Data(source.utf8).write(to: store.scriptsDirectoryURL.appendingPathComponent("CPU"))
        store.reconcileScriptDirectory()
        let result = FirstSyncMerge(
            local: ShortcutSyncState(shortcuts: store.shortcuts, deletions: []),
            remote: ShortcutSyncState(shortcuts: [cloud], deletions: []))
        #expect(result.replacements.isEmpty)
        #expect(result.summary.keptBothPairs == 1)
    }

    @Test("Restoring a retired ID keeps its new references and logs independent")
    func restoredIdentity() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShortcutStore(directory: directory)
        let local = Shortcut(name: "CPU", action: .runScript(script: "echo 1"))
        let cloud = Shortcut(name: "CPU", action: .runScript(script: "echo 1"))
        store.add(local)
        let result = FirstSyncMerge(
            local: ShortcutSyncState(shortcuts: store.shortcuts, deletions: []),
            remote: ShortcutSyncState(shortcuts: [cloud], deletions: [])
        )
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        var restored = local
        restored.name = "Restored"
        restored.modifiedAt = try #require(result.library.deletions.first?.deletedAt).addingTimeInterval(1)
        let data = try JSONEncoder().encode([restored, cloud])
        try store.importData(data)
        let menu = MenuBarTextController(store: store, directory: directory)
        let slot = menu.addSlot()
        menu.updateSlot(id: slot) { $0.topLine.scriptID = local.id }
        let logs = ScriptLogStore(directory: directory)
        store.onScriptIDsReplaced = { replacements in
            try menu.replaceScriptIDs(replacements)
            try logs.replaceScriptIDs(replacements)
        }
        try store.applyRemoteChanges(result.library, replacements: result.replacements)
        #expect(store.shortcuts.count == 2)
        #expect(menu.slots[0].topLine.scriptID == local.id)
        logs.record(ScriptExecutionLog(shortcutID: local.id, output: "restored", exitCode: 0, timestamp: Date()))
        #expect(logs.recentLogs.first?.shortcutID == local.id)
    }
}
