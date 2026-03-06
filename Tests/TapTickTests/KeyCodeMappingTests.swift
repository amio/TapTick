import Testing
import Foundation
@testable import TapTickKit

@Suite("KeyCodeMapping")
struct KeyCodeMappingTests {

    @Test("All letter keys map correctly")
    func letterKeys() {
        #expect(KeyCodeMapping.keyName(for: 0) == "A")
        #expect(KeyCodeMapping.keyName(for: 11) == "B")
        #expect(KeyCodeMapping.keyName(for: 8) == "C")
        #expect(KeyCodeMapping.keyName(for: 45) == "N")
        #expect(KeyCodeMapping.keyName(for: 6) == "Z")
    }

    @Test("Number keys map correctly")
    func numberKeys() {
        #expect(KeyCodeMapping.keyName(for: 29) == "0")
        #expect(KeyCodeMapping.keyName(for: 18) == "1")
        #expect(KeyCodeMapping.keyName(for: 25) == "9")
    }

    @Test("Function keys map correctly")
    func functionKeys() {
        #expect(KeyCodeMapping.keyName(for: 122) == "F1")
        #expect(KeyCodeMapping.keyName(for: 120) == "F2")
        #expect(KeyCodeMapping.keyName(for: 111) == "F12")
    }

    @Test("Special keys map correctly")
    func specialKeys() {
        #expect(KeyCodeMapping.keyName(for: 36) == "↩")   // Return
        #expect(KeyCodeMapping.keyName(for: 48) == "⇥")   // Tab
        #expect(KeyCodeMapping.keyName(for: 49) == "Space") // Space
        #expect(KeyCodeMapping.keyName(for: 51) == "⌫")   // Delete
        #expect(KeyCodeMapping.keyName(for: 53) == "⎋")   // Escape
    }

    @Test("Arrow keys map correctly")
    func arrowKeys() {
        #expect(KeyCodeMapping.keyName(for: 126) == "↑")
        #expect(KeyCodeMapping.keyName(for: 125) == "↓")
        #expect(KeyCodeMapping.keyName(for: 123) == "←")
        #expect(KeyCodeMapping.keyName(for: 124) == "→")
    }

    @Test("Unknown key code returns Key(n)")
    func unknownKeyCode() {
        #expect(KeyCodeMapping.keyName(for: 999) == "Key(999)")
    }

    @Test("Reverse lookup keyCode(for:)")
    func reverseKeyCodeLookup() {
        #expect(KeyCodeMapping.keyCode(for: "A") == 0)
        #expect(KeyCodeMapping.keyCode(for: "Space") == 49)
        #expect(KeyCodeMapping.keyCode(for: "unknown") == nil)
    }
}
