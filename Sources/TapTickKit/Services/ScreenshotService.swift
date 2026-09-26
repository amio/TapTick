import AppKit
import Foundation

/// Orchestrates screenshot capture using macOS's native `screencapture` tool.
@MainActor
final class ScreenshotService {
    private var previewWindow: ScreenshotPreviewWindow?

    /// Interactive capture → temp file → annotation preview window.
    /// - Parameters:
    ///   - initialMode: The draw mode to restore from the last session.
    ///   - initialColorIndex: The palette index to restore from the last session.
    ///   - onSettingsChanged: Called whenever the user changes mode or color; persist as needed.
    func captureAndMark(
        initialMode: AnnotationMode,
        initialColorIndex: Int,
        onSettingsChanged: @escaping @Sendable (AnnotationMode, Int) -> Void
    ) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("taptick_screenshot_\(UUID().uuidString).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", tempURL.path]

        task.terminationHandler = { [weak self, tempURL] _ in
            Task { @MainActor [weak self] in
                self?.handleCaptureCompletion(
                    tempURL: tempURL,
                    initialMode: initialMode,
                    initialColorIndex: initialColorIndex,
                    onSettingsChanged: onSettingsChanged
                )
            }
        }
        try? task.run()
    }

    private func handleCaptureCompletion(
        tempURL: URL,
        initialMode: AnnotationMode,
        initialColorIndex: Int,
        onSettingsChanged: @escaping @Sendable (AnnotationMode, Int) -> Void
    ) {
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard FileManager.default.fileExists(atPath: tempURL.path),
            let image = NSImage(contentsOf: tempURL)
        else {
            // User cancelled the capture.
            return
        }

        showPreviewWindow(
            image: image,
            initialMode: initialMode,
            initialColorIndex: initialColorIndex,
            onSettingsChanged: onSettingsChanged
        )
    }

    private func showPreviewWindow(
        image: NSImage,
        initialMode: AnnotationMode,
        initialColorIndex: Int,
        onSettingsChanged: @escaping @Sendable (AnnotationMode, Int) -> Void
    ) {
        previewWindow?.close()

        let window = ScreenshotPreviewWindow(
            image: image,
            initialMode: initialMode,
            initialColorIndex: initialColorIndex
        )
        previewWindow = window

        window.onAnnotationSettingsChanged = onSettingsChanged
        window.onDismiss = { [weak self] in
            self?.previewWindow = nil
        }
        window.show()
    }
}
