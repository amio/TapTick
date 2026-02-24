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

// MARK: - CGEvent Flag Conversion

import Carbon.HIToolbox
import CoreGraphics

extension KeyCombo.Modifiers {
    /// Convert from CGEventFlags to our Modifiers.
    init(cgEventFlags flags: CGEventFlags) {
        var mods: KeyCombo.Modifiers = []
        if flags.contains(.maskCommand)  { mods.insert(.command) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskControl)  { mods.insert(.control) }
        if flags.contains(.maskShift)    { mods.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { mods.insert(.function_) }
        self = mods
    }

    /// Convert to CGEventFlags.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command)  { flags.insert(.maskCommand) }
        if contains(.option)   { flags.insert(.maskAlternate) }
        if contains(.control)  { flags.insert(.maskControl) }
        if contains(.shift)    { flags.insert(.maskShift) }
        if contains(.function_) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
