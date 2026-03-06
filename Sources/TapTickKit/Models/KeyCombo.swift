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

        static let command  = Modifiers(rawValue: 1 << 0)
        static let option   = Modifiers(rawValue: 1 << 1)
        static let control  = Modifiers(rawValue: 1 << 2)
        static let shift    = Modifiers(rawValue: 1 << 3)
        static let function_ = Modifiers(rawValue: 1 << 4)

        /// All modifier flags currently set, as an array.
        var activeModifiers: [Modifiers] {
            var result: [Modifiers] = []
            if contains(.control)  { result.append(.control) }
            if contains(.option)   { result.append(.option) }
            if contains(.shift)    { result.append(.shift) }
            if contains(.command)  { result.append(.command) }
            if contains(.function_) { result.append(.function_) }
            return result
        }

        /// Modifier-only display string, e.g. "⌃⌥⌘". Used for live recording preview
        /// where no key has been pressed yet — avoids appending a raw modifier keyCode.
        var displayString: String {
            var parts: [String] = []
            if contains(.control)   { parts.append("⌃") }
            if contains(.option)    { parts.append("⌥") }
            if contains(.shift)     { parts.append("⇧") }
            if contains(.command)   { parts.append("⌘") }
            if contains(.function_) { parts.append("fn") }
            return parts.joined()
        }
    }

    /// Human-readable display string, e.g. "⌃⌥⌘K"
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.function_) { parts.append("fn") }
        parts.append(KeyCodeMapping.keyName(for: keyCode))
        return parts.joined()
    }
}

// MARK: - Carbon Modifier Conversion

import Carbon.HIToolbox

extension KeyCombo.Modifiers {
    /// Convert to Carbon modifier flags for use with RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if contains(.command)   { flags |= UInt32(cmdKey) }
        if contains(.option)    { flags |= UInt32(optionKey) }
        if contains(.control)   { flags |= UInt32(controlKey) }
        if contains(.shift)     { flags |= UInt32(shiftKey) }
        return flags
    }
}

// MARK: - NSEvent Flag Conversion

import AppKit

extension KeyCombo.Modifiers {
    /// Convert from NSEvent modifier flags (used by KeyRecorderView during shortcut recording).
    init(nsEventFlags flags: NSEvent.ModifierFlags) {
        var mods: KeyCombo.Modifiers = []
        if flags.contains(.command)  { mods.insert(.command) }
        if flags.contains(.option)   { mods.insert(.option) }
        if flags.contains(.control)  { mods.insert(.control) }
        if flags.contains(.shift)    { mods.insert(.shift) }
        if flags.contains(.function) { mods.insert(.function_) }
        self = mods
    }
}
