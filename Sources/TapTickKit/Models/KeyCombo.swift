import AppKit
import Carbon.HIToolbox
import Foundation

/// Represents a keyboard combination: a key code plus modifier flags.
struct KeyCombo: Codable, Hashable, Sendable {
    /// The virtual key code (Carbon key code).
    let keyCode: UInt32
    /// Modifier flags stored as raw value for Codable conformance.
    let modifiers: Modifiers

    /// Modifier flags for a key combo.
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt32

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
        static let function_ = Modifiers(rawValue: 1 << 4)

        /// Modifier-only display string, e.g. "⌃⌥⌘". Used for live recording preview
        /// where no key has been pressed yet — avoids appending a raw modifier keyCode.
        var displayString: String {
            var parts: [String] = []
            if contains(.control) { parts.append("⌃") }
            if contains(.option) { parts.append("⌥") }
            if contains(.shift) { parts.append("⇧") }
            if contains(.command) { parts.append("⌘") }
            if contains(.function_) { parts.append("fn") }
            return parts.joined()
        }
    }

    /// Human-readable display string, e.g. "⌃⌥⌘K"
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.function_) { parts.append("fn") }
        parts.append(KeyCodeMapping.keyName(for: keyCode))
        return parts.joined()
    }

    // MARK: - NSMenuItem Key Equivalent

    /// The character string for `NSMenuItem.keyEquivalent`.
    ///
    /// Maps Carbon virtual key codes to the Unicode characters that AppKit expects.
    /// Letters/digits are lowercase strings; special keys use the symbolic constants
    /// defined in `NSEvent` (e.g. `NSUpArrowFunctionKey`).
    var menuItemKeyEquivalent: String {
        switch Int(keyCode) {
        // Letters — NSMenuItem expects lowercase
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"

        // Digits
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        // Function keys — Unicode Private Use Area values that AppKit recognises
        case kVK_F1: return String(UnicodeScalar(NSF1FunctionKey)!)
        case kVK_F2: return String(UnicodeScalar(NSF2FunctionKey)!)
        case kVK_F3: return String(UnicodeScalar(NSF3FunctionKey)!)
        case kVK_F4: return String(UnicodeScalar(NSF4FunctionKey)!)
        case kVK_F5: return String(UnicodeScalar(NSF5FunctionKey)!)
        case kVK_F6: return String(UnicodeScalar(NSF6FunctionKey)!)
        case kVK_F7: return String(UnicodeScalar(NSF7FunctionKey)!)
        case kVK_F8: return String(UnicodeScalar(NSF8FunctionKey)!)
        case kVK_F9: return String(UnicodeScalar(NSF9FunctionKey)!)
        case kVK_F10: return String(UnicodeScalar(NSF10FunctionKey)!)
        case kVK_F11: return String(UnicodeScalar(NSF11FunctionKey)!)
        case kVK_F12: return String(UnicodeScalar(NSF12FunctionKey)!)
        case kVK_F13: return String(UnicodeScalar(NSF13FunctionKey)!)
        case kVK_F14: return String(UnicodeScalar(NSF14FunctionKey)!)
        case kVK_F15: return String(UnicodeScalar(NSF15FunctionKey)!)
        case kVK_F16: return String(UnicodeScalar(NSF16FunctionKey)!)
        case kVK_F17: return String(UnicodeScalar(NSF17FunctionKey)!)
        case kVK_F18: return String(UnicodeScalar(NSF18FunctionKey)!)
        case kVK_F19: return String(UnicodeScalar(NSF19FunctionKey)!)
        case kVK_F20: return String(UnicodeScalar(NSF20FunctionKey)!)

        // Navigation / editing
        case kVK_Return: return "\r"
        case kVK_Tab: return String(UnicodeScalar(NSTabCharacter)!)
        case kVK_Space: return " "
        case kVK_Delete: return String(UnicodeScalar(NSBackspaceCharacter)!)
        case kVK_ForwardDelete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
        case kVK_Escape: return String(UnicodeScalar(0x1B)!)
        case kVK_Home: return String(UnicodeScalar(NSHomeFunctionKey)!)
        case kVK_End: return String(UnicodeScalar(NSEndFunctionKey)!)
        case kVK_PageUp: return String(UnicodeScalar(NSPageUpFunctionKey)!)
        case kVK_PageDown: return String(UnicodeScalar(NSPageDownFunctionKey)!)

        // Arrows
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)

        // Symbols
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"

        default: return ""
        }
    }

    /// The modifier mask for `NSMenuItem.keyEquivalentModifierMask`.
    var menuItemModifierMask: NSEvent.ModifierFlags {
        modifiers.nsEventModifierFlags
    }
}

// MARK: - Carbon Modifier Conversion

extension KeyCombo.Modifiers {
    /// Convert to Carbon modifier flags for use with RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// Convert to `NSEvent.ModifierFlags` for `NSMenuItem.keyEquivalentModifierMask`.
    var nsEventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.function_) { flags.insert(.function) }
        return flags
    }
}

// MARK: - NSEvent Flag Conversion

extension KeyCombo.Modifiers {
    /// Convert from NSEvent modifier flags for shortcut recording and event display.
    init(nsEventFlags flags: NSEvent.ModifierFlags) {
        var mods: KeyCombo.Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.function) { mods.insert(.function_) }
        self = mods
    }
}
