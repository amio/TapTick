import SwiftUI
import UniformTypeIdentifiers

/// A button that opens an app picker (file dialog filtered to .app bundles).
struct AppPickerButton: View {
    @Binding var selectedBundleID: String
    @Binding var selectedAppName: String

    @State private var isShowingPicker = false

    var body: some View {
        HStack(spacing: 10) {
            if !selectedBundleID.isEmpty {
                AppIconView(bundleIdentifier: selectedBundleID)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedAppName)
                        .fontWeight(.medium)
                    Text(selectedBundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Choose App...") {
                pickApp()
            }
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select an application to launch"

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url),
               let bundleID = bundle.bundleIdentifier {
                selectedBundleID = bundleID
                selectedAppName = url.deletingPathExtension().lastPathComponent
            }
        }
    }
}

/// Displays an app icon from a bundle identifier.
struct AppIconView: View {
    let bundleIdentifier: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let icon = NSWorkspace.shared.icon(forFile: url.path) as NSImage? {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}
