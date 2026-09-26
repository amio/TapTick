import Carbon.HIToolbox
import Foundation
import Testing
@testable import TapTickKit

@Suite("UtilitiesController")
struct UtilitiesControllerTests {
    @Test("Persists keystroke overlay configuration")
    @MainActor
    func persistsKeystrokeOverlayConfiguration() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overrideHotkey = KeyCombo(
            keyCode: UInt32(kVK_ANSI_Slash),
            modifiers: [.command, .option]
        )

        let controller = UtilitiesController(directory: directory)
        controller.keystrokeOverlay.fontSize = 48
        controller.keystrokeOverlay.holdDuration = 2.4
        controller.updateKeystrokeOverlayHotkey(overrideHotkey)

        let reloaded = UtilitiesController(directory: directory)
        #expect(reloaded.keystrokeOverlay.fontSize == 48)
        #expect(reloaded.keystrokeOverlay.holdDuration == 2.4)
        #expect(reloaded.keystrokeOverlay.hotkey == overrideHotkey)
    }

    @Test("Persists Large Type configuration and reserves its enabled hotkey")
    @MainActor
    func persistsLargeTypeConfiguration() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overrideHotkey = KeyCombo(
            keyCode: UInt32(kVK_ANSI_Semicolon),
            modifiers: [.command, .option]
        )
        let foregroundColor = RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.9)

        let controller = UtilitiesController(directory: directory)
        #expect(
            controller.reservedHotkeys().contains(where: { $0.featureID == .largeType }) == false
        )

        controller.largeType.fontFamily = "Helvetica"
        controller.largeType.foregroundColor = foregroundColor
        controller.largeType.textDirection = .rightToLeft
        controller.updateLargeTypeHotkey(overrideHotkey)
        controller.setLargeTypeEnabled(true)

        #expect(
            controller.reservedHotkeys().contains {
                $0.featureID == .largeType && $0.combo == overrideHotkey
            }
        )

        let reloaded = UtilitiesController(directory: directory)
        #expect(reloaded.largeType.isEnabled)
        #expect(reloaded.largeType.fontFamily == "Helvetica")
        #expect(reloaded.largeType.foregroundColor == foregroundColor)
        #expect(reloaded.largeType.textDirection == .rightToLeft)
        #expect(reloaded.largeType.hotkey == overrideHotkey)
    }

    @Test("Legacy capture hotkey is removed while CapMark binding survives")
    @MainActor
    func dropsLegacyCaptureHotkey() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let markHotkey = KeyCombo(
            keyCode: UInt32(kVK_ANSI_Semicolon),
            modifiers: [.command, .option]
        )
        let captureHotkey = KeyCombo(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: [.command, .control, .option]
        )
        let encoded = try JSONEncoder().encode(UtilityConfiguration.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var screenshotTools = try #require(object["screenshotTools"] as? [String: Any])
        screenshotTools["isEnabled"] = true
        screenshotTools["captureAndMarkHotkey"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(markHotkey)
        )
        screenshotTools["captureToClipboardHotkey"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(captureHotkey)
        )
        object["screenshotTools"] = screenshotTools
        let fileURL = directory.appendingPathComponent("utilities.json")
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let controller = UtilitiesController(directory: directory)
        let reserved = controller.reservedHotkeys().filter { $0.featureID == .screenshotTools }
        #expect(reserved.count == 1)
        #expect(reserved.first?.action == "captureAndMark")
        #expect(reserved.first?.combo == markHotkey)
        #expect(reserved.contains(where: { $0.combo == captureHotkey }) == false)

        controller.screenshotTools.lastAnnotationMode = .rectangle
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let savedScreenshotTools = try #require(saved["screenshotTools"] as? [String: Any])
        #expect(savedScreenshotTools["captureToClipboardHotkey"] == nil)
    }

    @Test("Older utility configuration receives Large Type defaults")
    func decodesLargeTypeDefaultsFromOlderConfiguration() throws {
        let encoded = try JSONEncoder().encode(UtilityConfiguration.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "largeType")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(UtilityConfiguration.self, from: legacyData)

        #expect(decoded.largeType == .default)
        #expect(decoded.largeType.hotkey == LargeTypeConfiguration.defaultHotkey)
    }

    @Test("Older Large Type configuration defaults text direction to LTR")
    func decodesLargeTypeTextDirectionDefault() throws {
        let encoded = try JSONEncoder().encode(UtilityConfiguration.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var largeType = try #require(object["largeType"] as? [String: Any])
        largeType.removeValue(forKey: "textDirection")
        object["largeType"] = largeType
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(UtilityConfiguration.self, from: legacyData)

        #expect(decoded.largeType.textDirection == .leftToRight)
    }

    @Test("Large Type progressively allows more lines for long text")
    @MainActor
    func largeTypeProgressiveWrapping() {
        let shortLayout = LargeTypeLayoutEngine.layout(
            text: "Hello",
            in: CGSize(width: 1_200, height: 700),
            screenHeight: 900,
            fontFamily: nil
        )
        let longLayout = LargeTypeLayoutEngine.layout(
            text: String(repeating: "Large type should remain readable everywhere. ", count: 18),
            in: CGSize(width: 1_200, height: 700),
            screenHeight: 900,
            fontFamily: nil
        )

        #expect(shortLayout.lineLimit == 1)
        #expect(longLayout.lineLimit > shortLayout.lineLimit)
        #expect(longLayout.fontSize > 1)
    }

    @Test("Large Type preserves explicit line breaks")
    @MainActor
    func largeTypeExplicitLineBreaks() {
        let layout = LargeTypeLayoutEngine.layout(
            text: "First\nSecond\nThird",
            in: CGSize(width: 1_200, height: 700),
            screenHeight: 900,
            fontFamily: nil
        )

        #expect(layout.lineLimit >= 3)
    }

    @Test("Large Type keeps ordinary words intact in the narrow QR layout")
    @MainActor
    func largeTypeQRCodeWrappingPreservesWords() {
        let availableSize = CGSize(width: 531, height: 807)
        let layout = LargeTypeLayoutEngine.layout(
            text: "large is awesome",
            in: availableSize,
            screenHeight: 1_121,
            fontFamily: nil
        )
        let wordSize = NSAttributedString(
            string: "awesome",
            attributes: [.font: LargeTypeLayoutEngine.font(family: nil, size: layout.fontSize)]
        ).size()

        #expect(wordSize.width <= availableSize.width + 0.5)
    }

    @Test("A bare Option press toggles Large Type QR mode")
    func largeTypeBareOptionGesture() {
        var gesture = LargeTypeOptionKeyGesture()
        let pressed = gesture.handleFlagsChanged(
            optionIsActive: true,
            hasOtherModifiers: false
        )
        let released = gesture.handleFlagsChanged(
            optionIsActive: false,
            hasOtherModifiers: false
        )

        #expect(pressed == false)
        #expect(released)
    }

    @Test("Option shortcuts do not toggle Large Type QR mode")
    func largeTypeOptionShortcutGesture() {
        var modifierGesture = LargeTypeOptionKeyGesture()
        _ = modifierGesture.handleFlagsChanged(optionIsActive: true, hasOtherModifiers: true)
        let modifierReleased = modifierGesture.handleFlagsChanged(
            optionIsActive: false,
            hasOtherModifiers: false
        )

        var keyGesture = LargeTypeOptionKeyGesture()
        _ = keyGesture.handleFlagsChanged(optionIsActive: true, hasOtherModifiers: false)
        keyGesture.handleKeyDown()
        let keyReleased = keyGesture.handleFlagsChanged(
            optionIsActive: false,
            hasOtherModifiers: false
        )

        #expect(modifierReleased == false)
        #expect(keyReleased == false)
    }

    @Test("Preview sessions suppress event presentations until they expire")
    func previewSessionsSuppressEventPresentations() {
        var coordinator = KeystrokeOverlayPresentationCoordinator()
        coordinator.begin(.preview)

        #expect(coordinator.isPreviewActive)
        #expect(coordinator.allowsEventPresentation == false)
        #expect(coordinator.stopCapture() == .keepPresentation)
        #expect(coordinator.isPreviewActive)
    }

    @Test("Stopping capture only dismisses event presentations")
    func stoppingCaptureDismissesOnlyEventPresentations() {
        var coordinator = KeystrokeOverlayPresentationCoordinator()
        coordinator.begin(.event)

        #expect(coordinator.allowsEventPresentation)
        #expect(coordinator.stopCapture() == .hidePresentation)
        #expect(coordinator.activeIntent == nil)
    }

    @Test("Denied keystroke overlay permission opens Input Monitoring recovery")
    @MainActor
    func deniedPermissionOpensSettingsRecovery() {
        var openedURLs: [URL] = []
        let service = KeystrokeOverlayService(
            preflightPermissionAccess: { false },
            requestPermissionAccess: { false },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        let status = service.requestPermission()

        #expect(status == .denied)
        #expect(openedURLs.count == 1)
        #expect(
            openedURLs[0].absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickUtilities-\(UUID().uuidString)")
    }
}
