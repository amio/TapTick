import AppKit
import Carbon.HIToolbox
import SwiftUI

enum UtilityID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case keystrokeOverlay
    case screenshotTools
    case windowManager
    case largeType

    var id: String { rawValue }
}

enum UtilityAvailability: String, Codable, Hashable, Sendable {
    case available
    case planned
}

struct UtilityDescriptor: Identifiable, Hashable, Sendable {
    let id: UtilityID
    let title: String
    let summary: String
    let systemImage: String
    let availability: UtilityAvailability
    let highlights: [String]

    var directoryIconPointSize: CGFloat {
        switch id {
        case .windowManager:
            13
        case .keystrokeOverlay:
            14
        case .largeType:
            15
        case .screenshotTools:
            16
        }
    }

    static let catalog: [UtilityDescriptor] = [
        UtilityDescriptor(
            id: .screenshotTools,
            title: "CapMark",
            summary: "Capture a region, annotate it in a preview, and copy the finished image.",
            systemImage: "camera.viewfinder",
            availability: .available,
            highlights: [
                "Region capture",
                "Line and rectangle annotations",
                "Copy the finished image",
            ]
        ),
        UtilityDescriptor(
            id: .largeType,
            title: "Large Type",
            summary: "Project large temporary text on screen for quick glanceable display, similar to Alfred.",
            systemImage: "character.textbox",
            availability: .available,
            highlights: [
                "Huge readable text",
                "Native full-screen text input",
                "Animated QR-code presentation",
            ]
        ),
        UtilityDescriptor(
            id: .windowManager,
            title: "Window Manager",
            summary: "Resize, snap, and reposition windows with native layouts and shortcut-driven commands.",
            systemImage: "rectangle.3.offgrid",
            availability: .planned,
            highlights: [
                "Preset layouts",
                "Per-action hotkeys",
                "Native window geometry control",
            ]
        ),
        UtilityDescriptor(
            id: .keystrokeOverlay,
            title: "Keystroke Overlay",
            summary: "Show the current key chord in a subtitle-style HUD near the bottom of the screen.",
            systemImage: "keyboard.badge.eye",
            availability: .available,
            highlights: [
                "Global toggle hotkey",
                "Subtitle-style floating overlay",
                "Font, color, hold time, and fade controls",
            ]
        ),
    ]
}

enum EventListeningPermissionStatus: String, Codable, Hashable, Sendable {
    case unknown
    case granted
    case denied

    var title: String {
        switch self {
        case .unknown:
            "Unknown"
        case .granted:
            "Granted"
        case .denied:
            "Required"
        }
    }
}

struct RGBAColor: Codable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(
            red: Double(color.redComponent).nativeClamped,
            green: Double(color.greenComponent).nativeClamped,
            blue: Double(color.blueComponent).nativeClamped,
            alpha: Double(color.alphaComponent).nativeClamped
        )
    }

    var nsColor: NSColor {
        NSColor(
            red: red.nativeClamped,
            green: green.nativeClamped,
            blue: blue.nativeClamped,
            alpha: alpha.nativeClamped
        )
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

struct KeystrokeOverlayConfiguration: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var hotkey: KeyCombo
    var fontSize: Double
    var foregroundColor: RGBAColor
    var backgroundColor: RGBAColor
    var holdDuration: Double
    var fadeOutDuration: Double
    /// Vertical position on screen as a fraction (0 = bottom, 1 = top).
    var verticalPosition: Double

    init(
        isEnabled: Bool,
        hotkey: KeyCombo,
        fontSize: Double,
        foregroundColor: RGBAColor,
        backgroundColor: RGBAColor,
        holdDuration: Double,
        fadeOutDuration: Double,
        verticalPosition: Double
    ) {
        self.isEnabled = isEnabled
        self.hotkey = hotkey
        self.fontSize = fontSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.holdDuration = holdDuration
        self.fadeOutDuration = fadeOutDuration
        self.verticalPosition = verticalPosition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        hotkey = try container.decode(KeyCombo.self, forKey: .hotkey)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        foregroundColor = try container.decode(RGBAColor.self, forKey: .foregroundColor)
        backgroundColor = try container.decode(RGBAColor.self, forKey: .backgroundColor)
        holdDuration = try container.decode(Double.self, forKey: .holdDuration)
        fadeOutDuration = try container.decode(Double.self, forKey: .fadeOutDuration)
        verticalPosition =
            try container.decodeIfPresent(Double.self, forKey: .verticalPosition)
            ?? Self.default.verticalPosition
    }

    static let defaultHotkey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: [.command, .control, .option]
    )

    static let `default` = KeystrokeOverlayConfiguration(
        isEnabled: false,
        hotkey: defaultHotkey,
        fontSize: 36,
        foregroundColor: RGBAColor(NSColor.white),
        backgroundColor: RGBAColor(
            red: 0.05,
            green: 0.05,
            blue: 0.05,
            alpha: 0.84
        ),
        holdDuration: 1.3,
        fadeOutDuration: 0.28,
        verticalPosition: 0.15
    )
}

struct ScreenshotToolsConfiguration: Hashable, Sendable {
    var isEnabled: Bool
    var captureAndMarkHotkey: KeyCombo
    var lastAnnotationMode: AnnotationMode
    var lastAnnotationColorIndex: Int

    static let defaultCaptureAndMarkHotkey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: [.command, .control, .option]
    )

    static let `default` = ScreenshotToolsConfiguration(
        isEnabled: false,
        captureAndMarkHotkey: defaultCaptureAndMarkHotkey,
        lastAnnotationMode: .freehand,
        lastAnnotationColorIndex: 0
    )
}

enum LargeTypeTextDirection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case leftToRight
    case rightToLeft

    var id: Self { self }

    var displayName: String {
        switch self {
        case .leftToRight:
            "Left to Right"
        case .rightToLeft:
            "Right to Left"
        }
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        }
    }

    var writingDirection: NSWritingDirection {
        switch self {
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        }
    }
}

struct LargeTypeConfiguration: Hashable, Sendable {
    var isEnabled: Bool
    var hotkey: KeyCombo
    var fontFamily: String?
    var foregroundColor: RGBAColor
    var backgroundColor: RGBAColor
    var textDirection: LargeTypeTextDirection

    static let defaultHotkey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: [.command, .control, .option]
    )

    static let `default` = LargeTypeConfiguration(
        isEnabled: false,
        hotkey: defaultHotkey,
        fontFamily: nil,
        foregroundColor: RGBAColor(NSColor.white),
        backgroundColor: RGBAColor(
            red: 0.015,
            green: 0.018,
            blue: 0.025,
            alpha: 0.78
        ),
        textDirection: .leftToRight
    )
}

// Backward-compatible Codable: new fields default gracefully when absent from older JSON.
extension ScreenshotToolsConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case isEnabled, captureAndMarkHotkey
        case lastAnnotationMode, lastAnnotationColorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        captureAndMarkHotkey = try c.decode(KeyCombo.self, forKey: .captureAndMarkHotkey)
        lastAnnotationMode = try c.decodeIfPresent(AnnotationMode.self, forKey: .lastAnnotationMode) ?? .freehand
        lastAnnotationColorIndex = try c.decodeIfPresent(Int.self, forKey: .lastAnnotationColorIndex) ?? 0
    }
}

// Backward-compatible Codable: text direction defaults to LTR for existing installations.
extension LargeTypeConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case isEnabled, hotkey, fontFamily, foregroundColor, backgroundColor, textDirection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        hotkey = try container.decode(KeyCombo.self, forKey: .hotkey)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        foregroundColor = try container.decode(RGBAColor.self, forKey: .foregroundColor)
        backgroundColor = try container.decode(RGBAColor.self, forKey: .backgroundColor)
        textDirection =
            try container.decodeIfPresent(LargeTypeTextDirection.self, forKey: .textDirection)
            ?? .leftToRight
    }
}

struct UtilityConfiguration: Codable, Hashable, Sendable {
    var keystrokeOverlay: KeystrokeOverlayConfiguration
    var screenshotTools: ScreenshotToolsConfiguration
    var largeType: LargeTypeConfiguration

    init(
        keystrokeOverlay: KeystrokeOverlayConfiguration,
        screenshotTools: ScreenshotToolsConfiguration,
        largeType: LargeTypeConfiguration
    ) {
        self.keystrokeOverlay = keystrokeOverlay
        self.screenshotTools = screenshotTools
        self.largeType = largeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keystrokeOverlay = try container.decode(KeystrokeOverlayConfiguration.self, forKey: .keystrokeOverlay)
        screenshotTools =
            try container.decodeIfPresent(ScreenshotToolsConfiguration.self, forKey: .screenshotTools)
            ?? .default
        largeType =
            try container.decodeIfPresent(LargeTypeConfiguration.self, forKey: .largeType)
            ?? .default
    }

    static let `default` = UtilityConfiguration(
        keystrokeOverlay: .default,
        screenshotTools: .default,
        largeType: .default
    )
}

private extension Double {
    var nativeClamped: Double {
        min(max(self, 0), 1)
    }
}
