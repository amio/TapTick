import Testing
import Foundation
@testable import MagikeysKit

// MARK: - KeyCombo Tests

@Suite("KeyCombo")
struct KeyComboTests {

    @Test("Display string with single modifier")
    func displayStringSingleModifier() {
        let combo = KeyCombo(keyCode: 0, modifiers: .command) // kVK_ANSI_A = 0
        #expect(combo.displayString == "⌘A")
    }

    @Test("Display string with multiple modifiers")
    func displayStringMultipleModifiers() {
        let combo = KeyCombo(keyCode: 0, modifiers: [.control, .option, .command])
        #expect(combo.displayString == "⌃⌥⌘A")
    }

    @Test("Display string with all modifiers")
    func displayStringAllModifiers() {
        let combo = KeyCombo(keyCode: 0, modifiers: [.control, .option, .shift, .command])
        #expect(combo.displayString == "⌃⌥⇧⌘A")
    }

    @Test("Display string with function key")
    func displayStringFunctionKey() {
        // kVK_F1 = 122
        let combo = KeyCombo(keyCode: 122, modifiers: [])
        #expect(combo.displayString == "F1")
    }

    @Test("Display string with shift + number")
    func displayStringShiftNumber() {
        // kVK_ANSI_1 = 18
        let combo = KeyCombo(keyCode: 18, modifiers: .shift)
        #expect(combo.displayString == "⇧1")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let combo = KeyCombo(keyCode: 0, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        #expect(decoded == combo)
    }

    @Test("Hashable equality")
    func hashableEquality() {
        let a = KeyCombo(keyCode: 0, modifiers: .command)
        let b = KeyCombo(keyCode: 0, modifiers: .command)
        let c = KeyCombo(keyCode: 1, modifiers: .command)
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - KeyCombo.Modifiers Tests

@Suite("KeyCombo.Modifiers")
struct ModifiersTests {

    @Test("Active modifiers returns correct list")
    func activeModifiers() {
        let mods: KeyCombo.Modifiers = [.control, .command]
        let active = mods.activeModifiers
        #expect(active.count == 2)
        #expect(active.contains(.control))
        #expect(active.contains(.command))
    }

    @Test("Empty modifiers returns empty list")
    func emptyModifiers() {
        let mods: KeyCombo.Modifiers = []
        #expect(mods.activeModifiers.isEmpty)
    }

    @Test("CGEventFlags round-trip")
    func cgEventFlagsRoundTrip() {
        let original: KeyCombo.Modifiers = [.command, .shift, .option]
        let flags = original.cgEventFlags
        let converted = KeyCombo.Modifiers(cgEventFlags: flags)
        #expect(converted == original)
    }
}
