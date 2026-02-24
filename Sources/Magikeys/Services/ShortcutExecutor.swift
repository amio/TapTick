import Cocoa
import Foundation

/// Executes shortcut actions (launch apps, run scripts).
final class ShortcutExecutor: Sendable {

    /// Execute the given action.
    func execute(action: ShortcutAction) {
        switch action {
        case .launchApp(let bundleIdentifier, _):
            launchApp(bundleIdentifier: bundleIdentifier)
        case .runScript(let script, let shell):
            runInlineScript(script: script, shell: shell)
        case .runScriptFile(let path, let shell):
            runScriptFile(path: path, shell: shell)
        }
    }

    // MARK: - Launch App

    private func launchApp(bundleIdentifier: String) {
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
