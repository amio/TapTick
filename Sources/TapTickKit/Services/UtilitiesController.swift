import Foundation
import Observation

@Observable
@MainActor
public final class UtilitiesController {
    public init(directory: URL? = nil) {
        let baseDirectory =
            directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent(
                TapTickRuntimeConfiguration.current.appSupportDirectoryName,
                isDirectory: true
            )

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let fileURL = baseDirectory.appendingPathComponent("utilities.json")
        let loadedConfig = Self.loadConfiguration(from: fileURL) ?? .default

        // Phase 1: initialize all stored properties before touching self.
        self.fileURL = fileURL
        self.catalog = UtilityDescriptor.catalog
        self.configuration = loadedConfig
        self.keystrokeOverlayService = KeystrokeOverlayService()
        self.largeTypeService = LargeTypeService()
        self.keystrokeOverlayPermission = .unknown
        self.isKeystrokeOverlayCapturing = false

        // All stored properties initialized — safe to capture self.
        keystrokeOverlayService.onPermissionChange = { [weak self] status in
            self?.keystrokeOverlayPermission = status
        }
        keystrokeOverlayService.onCaptureStateChange = { [weak self] isCapturing in
            self?.isKeystrokeOverlayCapturing = isCapturing
        }
    }

    let catalog: [UtilityDescriptor]

    private var configuration: UtilityConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            saveConfiguration()
            applyKeystrokeOverlayConfiguration(promptForPermission: false)
            applyLargeTypeConfiguration()
        }
    }

    private let fileURL: URL
    private let keystrokeOverlayService: KeystrokeOverlayService
    private let largeTypeService: LargeTypeService
    private let screenshotService: ScreenshotService = ScreenshotService()

    private(set) var keystrokeOverlayPermission: EventListeningPermissionStatus
    private(set) var isKeystrokeOverlayCapturing: Bool

    public var onReservedHotkeysChanged: (() -> Void)?

    var keystrokeOverlay: KeystrokeOverlayConfiguration {
        get { configuration.keystrokeOverlay }
        set { configuration.keystrokeOverlay = newValue }
    }

    var screenshotTools: ScreenshotToolsConfiguration {
        get { configuration.screenshotTools }
        set { configuration.screenshotTools = newValue }
    }

    var largeType: LargeTypeConfiguration {
        get { configuration.largeType }
        set { configuration.largeType = newValue }
    }

    /// Refresh the on-screen preview HUD using the current settings configuration.
    /// Repeated calls are expected while the user tunes settings, so the underlying
    /// presenter should keep the preview alive instead of flashing between updates.
    func showKeystrokeOverlayPreview() {
        keystrokeOverlayService.showPreview(configuration: keystrokeOverlay)
    }

    public func bootstrap() {
        keystrokeOverlayPermission = keystrokeOverlayService.refreshPermissionStatus()
        applyKeystrokeOverlayConfiguration(promptForPermission: false)
        applyLargeTypeConfiguration()
    }

    func descriptor(for featureID: UtilityID) -> UtilityDescriptor {
        catalog.first(where: { $0.id == featureID }) ?? catalog[0]
    }

    func reservedHotkeys() -> [(featureID: UtilityID, action: String, combo: KeyCombo)] {
        var hotkeys: [(featureID: UtilityID, action: String, combo: KeyCombo)] = [
            (.keystrokeOverlay, "toggle", keystrokeOverlay.hotkey)
        ]
        if screenshotTools.isEnabled {
            hotkeys.append((.screenshotTools, "captureClipboard", screenshotTools.captureToClipboardHotkey))
            hotkeys.append((.screenshotTools, "captureAndMark", screenshotTools.captureAndMarkHotkey))
        }
        if largeType.isEnabled {
            hotkeys.append((.largeType, "togglePresentation", largeType.hotkey))
        }
        return hotkeys
    }

    func reservedHotkeyConflict(for combo: KeyCombo, excluding featureID: UtilityID? = nil) -> Bool {
        reservedHotkeys().contains { entry in
            entry.featureID != featureID && entry.combo == combo
        }
    }

    func updateKeystrokeOverlayHotkey(_ combo: KeyCombo) {
        guard keystrokeOverlay.hotkey != combo else { return }
        keystrokeOverlay.hotkey = combo
        onReservedHotkeysChanged?()
    }

    func restoreDefaultKeystrokeOverlayHotkey() {
        updateKeystrokeOverlayHotkey(KeystrokeOverlayConfiguration.defaultHotkey)
    }

    // MARK: - Screenshot Tools

    func setScreenshotToolsEnabled(_ isEnabled: Bool) {
        screenshotTools.isEnabled = isEnabled
        onReservedHotkeysChanged?()
    }

    func updateScreenshotCaptureToClipboardHotkey(_ combo: KeyCombo) {
        guard screenshotTools.captureToClipboardHotkey != combo else { return }
        screenshotTools.captureToClipboardHotkey = combo
        onReservedHotkeysChanged?()
    }

    func updateScreenshotCaptureAndMarkHotkey(_ combo: KeyCombo) {
        guard screenshotTools.captureAndMarkHotkey != combo else { return }
        screenshotTools.captureAndMarkHotkey = combo
        onReservedHotkeysChanged?()
    }

    // MARK: - Large Type

    func setLargeTypeEnabled(_ isEnabled: Bool) {
        guard largeType.isEnabled != isEnabled else { return }
        largeType.isEnabled = isEnabled
        onReservedHotkeysChanged?()
    }

    func updateLargeTypeHotkey(_ combo: KeyCombo) {
        guard largeType.hotkey != combo else { return }
        largeType.hotkey = combo
        onReservedHotkeysChanged?()
    }

    func restoreDefaultLargeTypeHotkey() {
        updateLargeTypeHotkey(LargeTypeConfiguration.defaultHotkey)
    }

    func requestKeystrokeOverlayPermission() {
        keystrokeOverlayPermission = keystrokeOverlayService.requestPermission()
        if keystrokeOverlay.isEnabled {
            applyKeystrokeOverlayConfiguration(promptForPermission: false)
        }
    }

    func setKeystrokeOverlayEnabled(_ isEnabled: Bool, promptForPermission: Bool = true) {
        guard isEnabled else {
            keystrokeOverlay.isEnabled = false
            return
        }

        let permission =
            promptForPermission
            ? keystrokeOverlayService.requestPermission()
            : keystrokeOverlayService.refreshPermissionStatus()

        keystrokeOverlayPermission = permission

        guard permission == .granted else {
            keystrokeOverlay.isEnabled = false
            return
        }

        keystrokeOverlay.isEnabled = true
    }

    func toggleFeature(_ featureID: UtilityID) {
        switch featureID {
        case .keystrokeOverlay:
            setKeystrokeOverlayEnabled(!keystrokeOverlay.isEnabled)
        case .screenshotTools:
            setScreenshotToolsEnabled(!screenshotTools.isEnabled)
        case .largeType:
            setLargeTypeEnabled(!largeType.isEnabled)
        case .windowManager:
            break
        }
    }

    func handleHotkey(for featureID: UtilityID, action: String) {
        switch featureID {
        case .keystrokeOverlay:
            toggleFeature(featureID)
        case .screenshotTools:
            guard screenshotTools.isEnabled else { return }
            switch action {
            case "captureClipboard":
                screenshotService.captureToClipboard()
            case "captureAndMark":
                screenshotService.captureAndMark(
                    initialMode: screenshotTools.lastAnnotationMode,
                    initialColorIndex: screenshotTools.lastAnnotationColorIndex,
                    onSettingsChanged: { [weak self] mode, colorIndex in
                        Task { @MainActor [weak self] in
                            self?.screenshotTools.lastAnnotationMode = mode
                            self?.screenshotTools.lastAnnotationColorIndex = colorIndex
                        }
                    }
                )
            default:
                break
            }
        case .largeType:
            guard action == "togglePresentation", largeType.isEnabled else { return }
            largeTypeService.toggle(configuration: largeType)
        case .windowManager:
            break
        }
    }

    private func applyKeystrokeOverlayConfiguration(promptForPermission: Bool) {
        keystrokeOverlayPermission = keystrokeOverlayService.apply(
            configuration: keystrokeOverlay,
            promptForPermission: promptForPermission
        )
    }

    private func applyLargeTypeConfiguration() {
        largeTypeService.apply(configuration: largeType)
    }

    private func saveConfiguration() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TapTick: Failed to save utility configuration: \(error)")
        }
    }

    private static func loadConfiguration(from fileURL: URL) -> UtilityConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(UtilityConfiguration.self, from: data)
        } catch {
            print("TapTick: Failed to load utility configuration: \(error)")
            return nil
        }
    }
}
