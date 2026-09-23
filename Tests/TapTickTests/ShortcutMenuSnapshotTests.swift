import Foundation
import Testing
@testable import TapTickKit

@Suite("Native shortcut menu snapshot")
struct ShortcutMenuSnapshotTests {
    @Test("Menu eligibility and invalidation follow visible fields, not script source or execution history")
    func visibleFields() {
        var app = Shortcut(name: "App", action: .launchApp(bundleIdentifier: "test.app", appName: "App"))
        var script = Shortcut(
            name: "Script", keyCombo: KeyCombo(keyCode: 0, modifiers: .control),
            action: .runScript(script: "echo first"))
        let unbound = Shortcut(name: "Unbound", action: .runScript(script: "echo unbound"))
        let snapshot = ShortcutMenuSnapshot(shortcuts: [script, unbound, app])
        #expect(snapshot.applications.map(\.id) == [app.id])
        #expect(snapshot.scripts.map(\.id) == [script.id])
        script.lastTriggeredAt = Date()
        script.modifiedAt = Date()
        script.action = .runScript(script: "echo second")
        #expect(ShortcutMenuSnapshot(shortcuts: [script, unbound, app]) == snapshot)
        script.name = "Renamed"
        #expect(ShortcutMenuSnapshot(shortcuts: [script, unbound, app]) != snapshot)
        script.keyCombo = nil
        app.isEnabled = false
        let hidden = ShortcutMenuSnapshot(shortcuts: [script, unbound, app])
        #expect(hidden.applications.isEmpty)
        #expect(hidden.scripts.isEmpty)
    }
}
