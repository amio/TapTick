import Testing
import Foundation
@testable import TapTickKit

// MARK: - KeyCombo Tests

@Suite("KeyCombo")
struct KeyComboTests {

    @Test("Display string with single modifier")
    func displayStringSingleModifier() {
        let combo = KeyCombo(keyCode: 0, modifiers: .command)  // kVK_ANSI_A = 0
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

}

// MARK: - KeyCombo.Modifiers Tests

@Suite("KeyCombo.Modifiers")
struct ModifiersTests {

    @Test("carbonModifiers round-trip via Carbon flags")
    func carbonModifiersRoundTrip() {
        let mods: KeyCombo.Modifiers = [.command, .shift, .option]
        let carbon = mods.carbonModifiers
        // Carbon raw values: cmdKey=256, optionKey=2048, shiftKey=512, controlKey=4096
        #expect(carbon & 256 != 0)  // cmdKey
        #expect(carbon & 2048 != 0)  // optionKey
        #expect(carbon & 512 != 0)  // shiftKey
        #expect(carbon & 4096 == 0)  // controlKey — not in mods
    }
}
