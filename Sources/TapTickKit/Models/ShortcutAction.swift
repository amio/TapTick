import Foundation

/// The action a shortcut performs when triggered.
enum ShortcutAction: Codable, Hashable, Sendable {
    /// Launch an application at the given path or bundle identifier.
    case launchApp(bundleIdentifier: String, appName: String)

    /// Execute a managed script. Its shebang is the sole runtime declaration.
    case runScript(script: String)

    /// Decode-only compatibility for external files saved by older TapTick versions.
    case runScriptFile(path: String, shell: LegacyShell)

    enum LegacyShell: String, Codable, Sendable {
        case bash = "/bin/bash"
        case zsh = "/bin/zsh"
        case sh = "/bin/sh"
        case fish = "/opt/homebrew/bin/fish"
    }

    private enum CodingKeys: String, CodingKey {
        case launchApp
        case runScript
        case runScriptFile
    }

    private struct LaunchAppPayload: Codable {
        let bundleIdentifier: String
        let appName: String
    }

    private struct RunScriptPayload: Codable {
        let script: String
        let shell: LegacyShell?
    }

    private struct RunScriptFilePayload: Codable {
        let path: String
        let shell: LegacyShell
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.launchApp) {
            let payload = try container.decode(LaunchAppPayload.self, forKey: .launchApp)
            self = .launchApp(
                bundleIdentifier: payload.bundleIdentifier,
                appName: payload.appName
            )
            return
        }

        if container.contains(.runScript) {
            let payload = try container.decode(RunScriptPayload.self, forKey: .runScript)
            let source: String
            if let shell = payload.shell,
                case .missing = ScriptShebang.inspect(payload.script)
            {
                source = ScriptShebang.replacingShebang(in: payload.script, with: "#!\(shell.rawValue)")
            } else {
                source = payload.script
            }
            self = .runScript(script: source)
            return
        }

        if container.contains(.runScriptFile) {
            let payload = try container.decode(RunScriptFilePayload.self, forKey: .runScriptFile)
            self = .runScriptFile(path: payload.path, shell: payload.shell)
            return
        }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown shortcut action")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launchApp(let bundleIdentifier, let appName):
            try container.encode(
                LaunchAppPayload(bundleIdentifier: bundleIdentifier, appName: appName),
                forKey: .launchApp
            )
        case .runScript(let script):
            try container.encode(
                RunScriptPayload(script: script, shell: nil),
                forKey: .runScript
            )
        case .runScriptFile(let path, let shell):
            try container.encode(
                RunScriptFilePayload(path: path, shell: shell),
                forKey: .runScriptFile
            )
        }
    }

    /// Whether this action launches an application (as opposed to running a script).
    var isLaunchApp: Bool {
        if case .launchApp = self { return true }
        return false
    }
}
