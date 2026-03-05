import Foundation

/// The action a shortcut performs when triggered.
enum ShortcutAction: Codable, Hashable, Sendable {
    /// Launch an application at the given path or bundle identifier.
    case launchApp(bundleIdentifier: String, appName: String)

    /// Execute a shell script with the given content.
    case runScript(script: String, shell: ShellType)

    /// Execute a script file at the given path.
    case runScriptFile(path: String, shell: ShellType)

    /// Supported shell types.
    enum ShellType: String, Codable, CaseIterable, Sendable {
        case bash = "/bin/bash"
        case zsh = "/bin/zsh"
        case sh = "/bin/sh"
        case fish = "/opt/homebrew/bin/fish"

        var displayName: String {
            switch self {
            case .bash: return "bash"
            case .zsh:  return "zsh"
            case .sh:   return "sh"
            case .fish: return "fish"
            }
        }
    }

    /// Human-readable description of the action.
    var displayDescription: String {
        switch self {
        case .launchApp(_, let appName):
            return "Launch \(appName)"
        case .runScript(let script, let shell):
            let preview = script.prefix(40)
            let suffix = script.count > 40 ? "..." : ""
            return "\(shell.displayName): \(preview)\(suffix)"
        case .runScriptFile(let path, let shell):
            let filename = (path as NSString).lastPathComponent
            return "\(shell.displayName): \(filename)"
        }
    }

    /// System symbol name for the action type.
    var systemImage: String {
        switch self {
        case .launchApp:     return "app.badge.checkmark"
        case .runScript:     return "terminal"
        case .runScriptFile: return "doc.text"
        }
    }

    /// Whether this action launches an application (as opposed to running a script).
    var isLaunchApp: Bool {
        if case .launchApp = self { return true }
        return false
    }
}
