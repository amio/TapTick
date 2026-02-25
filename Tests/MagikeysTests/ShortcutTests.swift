import Testing
import Foundation
@testable import MagikeysKit

@Suite("Shortcut")
struct ShortcutTests {

    @Test("Initialization with defaults")
    func initWithDefaults() {
        let combo = KeyCombo(keyCode: 0, modifiers: .command)
        let action = ShortcutAction.launchApp(bundleIdentifier: "com.test", appName: "Test")
        let shortcut = Shortcut(name: "Test", keyCombo: combo, action: action)

        #expect(shortcut.name == "Test")
        #expect(shortcut.isEnabled == true)
        #expect(shortcut.lastTriggeredAt == nil)
        #expect(!shortcut.id.uuidString.isEmpty)
    }

    @Test("Initialization with all parameters")
    func initWithAllParams() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        let combo = KeyCombo(keyCode: 0, modifiers: .command)
        let action = ShortcutAction.runScript(script: "echo hi", shell: .zsh)

        let shortcut = Shortcut(
            id: id,
            name: "Test",
            keyCombo: combo,
            action: action,
            isEnabled: false,
            createdAt: date,
            lastTriggeredAt: date
        )

        #expect(shortcut.id == id)
        #expect(shortcut.isEnabled == false)
        #expect(shortcut.createdAt == date)
        #expect(shortcut.lastTriggeredAt == date)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let combo = KeyCombo(keyCode: 0, modifiers: [.command, .shift])
        let action = ShortcutAction.launchApp(bundleIdentifier: "com.apple.finder", appName: "Finder")
        let shortcut = Shortcut(name: "Open Finder", keyCombo: combo, action: action)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(shortcut)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: data)

        #expect(decoded.id == shortcut.id)
        #expect(decoded.name == shortcut.name)
        #expect(decoded.keyCombo == shortcut.keyCombo)
        #expect(decoded.action == shortcut.action)
        #expect(decoded.isEnabled == shortcut.isEnabled)
    }

    @Test("Identifiable conformance")
    func identifiable() {
        let combo = KeyCombo(keyCode: 0, modifiers: .command)
        let action = ShortcutAction.launchApp(bundleIdentifier: "com.test", appName: "Test")
        let a = Shortcut(name: "A", keyCombo: combo, action: action)
        let b = Shortcut(name: "B", keyCombo: combo, action: action)
        #expect(a.id != b.id)
    }
}
