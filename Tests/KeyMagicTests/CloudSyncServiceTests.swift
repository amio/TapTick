import Testing
import Foundation
@testable import KeyMagicKit

@Suite("CloudSyncService")
struct CloudSyncServiceTests {

    private func makeShortcut(
        id: UUID = UUID(),
        name: String = "Test",
        modifiedAt: Date = Date()
    ) -> Shortcut {
        Shortcut(
            id: id,
            name: name,
            keyCombo: KeyCombo(keyCode: 0, modifiers: .command),
            action: .launchApp(bundleIdentifier: "com.test", appName: "Test"),
            modifiedAt: modifiedAt
        )
    }

    @Test("Merge: union of disjoint shortcuts")
    func mergeDisjoint() {
        let local = [makeShortcut(name: "Local")]
        let remote = [makeShortcut(name: "Remote")]
        let merged = CloudSyncService.merge(local: local, remote: remote)
        #expect(merged.count == 2)
        #expect(merged.contains { $0.name == "Local" })
        #expect(merged.contains { $0.name == "Remote" })
    }

    @Test("Merge: same ID — remote newer wins")
    func mergeRemoteNewer() {
        let id = UUID()
        let earlier = Date(timeIntervalSinceNow: -60)
        let later = Date()
        let local = [makeShortcut(id: id, name: "Old", modifiedAt: earlier)]
        let remote = [makeShortcut(id: id, name: "New", modifiedAt: later)]
        let merged = CloudSyncService.merge(local: local, remote: remote)
        #expect(merged.count == 1)
        #expect(merged.first?.name == "New")
    }

    @Test("Merge: same ID — local newer wins")
    func mergeLocalNewer() {
        let id = UUID()
        let earlier = Date(timeIntervalSinceNow: -60)
        let later = Date()
        let local = [makeShortcut(id: id, name: "Local", modifiedAt: later)]
        let remote = [makeShortcut(id: id, name: "Remote", modifiedAt: earlier)]
        let merged = CloudSyncService.merge(local: local, remote: remote)
        #expect(merged.count == 1)
        #expect(merged.first?.name == "Local")
    }

    @Test("Merge: empty local adopts all remote")
    func mergeEmptyLocal() {
        let remote = [makeShortcut(name: "A"), makeShortcut(name: "B")]
        let merged = CloudSyncService.merge(local: [], remote: remote)
        #expect(merged.count == 2)
    }

    @Test("Merge: empty remote keeps all local")
    func mergeEmptyRemote() {
        let local = [makeShortcut(name: "A"), makeShortcut(name: "B")]
        let merged = CloudSyncService.merge(local: local, remote: [])
        #expect(merged.count == 2)
    }

    @Test("Merge: both empty")
    func mergeBothEmpty() {
        let merged = CloudSyncService.merge(local: [], remote: [])
        #expect(merged.isEmpty)
    }

    @Test("Merge: result sorted by creation date")
    func mergeSortedByCreation() {
        let older = Date(timeIntervalSinceNow: -120)
        let newer = Date(timeIntervalSinceNow: -10)
        let s1 = Shortcut(name: "First", action: .runScript(script: "echo 1", shell: .zsh), createdAt: older)
        let s2 = Shortcut(name: "Second", action: .runScript(script: "echo 2", shell: .zsh), createdAt: newer)
        // Provide them in reverse order to prove sorting works.
        let merged = CloudSyncService.merge(local: [s2], remote: [s1])
        #expect(merged.count == 2)
        #expect(merged.first?.name == "First")
        #expect(merged.last?.name == "Second")
    }

    @Test("Backward-compatible decoding: modifiedAt absent falls back to createdAt")
    func backwardCompatibleDecoding() throws {
        // Simulate a legacy JSON without the modifiedAt field.
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "action": {"launchApp": {"bundleIdentifier": "com.test", "appName": "Test"}},
            "isEnabled": true,
            "createdAt": 700000000
        }
        """
        let data = Data(json.utf8)
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
        #expect(shortcut.name == "Legacy")
        #expect(shortcut.modifiedAt == shortcut.createdAt)
    }
}
