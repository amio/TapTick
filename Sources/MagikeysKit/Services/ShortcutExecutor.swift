import Cocoa
import Foundation

/// Executes shortcut actions (launch/toggle apps, run scripts).
final class ShortcutExecutor: Sendable {

    /// Execute the given action.
    func execute(action: ShortcutAction) {
        switch action {
        case .launchApp(let bundleIdentifier, _):
            toggleApp(bundleIdentifier: bundleIdentifier)
        case .runScript(let script, let shell):
            runInlineScript(script: script, shell: shell)
        case .runScriptFile(let path, let shell):
            runScriptFile(path: path, shell: shell)
        }
    }

    // MARK: - Toggle App Visibility

    private func toggleApp(bundleIdentifier: String) {
        // Check if the app is already running
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier
        }

        if let app = runningApps.first {
            // App is running — toggle visibility
            if app.isActive {
                // Currently frontmost, hide it
                app.hide()
            } else if app.isHidden {
                // Hidden, unhide and activate
                app.unhide()
                app.activate()
            } else {
                // Visible but not frontmost, bring to front
                app.activate()
            }
        } else {
            // App not running — launch it
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else {
                print("Magikeys: App not found: \(bundleIdentifier)")
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    print("Magikeys: Failed to launch app: \(error)")
                }
            }
        }
    }

    // MARK: - Run Script

    private func runInlineScript(script: String, shell: ShortcutAction.ShellType) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell.rawValue)
            process.arguments = ["-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    print("Magikeys: Script exited with code \(process.terminationStatus)")
                }
            } catch {
                print("Magikeys: Failed to run script: \(error)")
            }
        }
    }

    private func runScriptFile(path: String, shell: ShortcutAction.ShellType) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("Magikeys: Script file not found: \(expandedPath)")
            return
        }

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell.rawValue)
            process.arguments = [expandedPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    print("Magikeys: Script exited with code \(process.terminationStatus)")
                }
            } catch {
                print("Magikeys: Failed to run script file: \(error)")
            }
        }
    }
}
