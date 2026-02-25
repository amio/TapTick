import Testing
import Foundation
@testable import MagikeysKit

@Suite("ShortcutAction")
struct ShortcutActionTests {

    @Test("Launch app display description")
    func launchAppDescription() {
        let action = ShortcutAction.launchApp(
            bundleIdentifier: "com.apple.finder",
            appName: "Finder"
        )
        #expect(action.displayDescription == "Launch Finder")
    }

    @Test("Run script display description truncates")
    func runScriptDescriptionTruncates() {
        let longScript = String(repeating: "echo hello; ", count: 10)
        let action = ShortcutAction.runScript(script: longScript, shell: .bash)
        #expect(action.displayDescription.contains("..."))
        #expect(action.displayDescription.hasPrefix("Bash:"))
    }

    @Test("Run script file display description shows filename")
    func runScriptFileDescription() {
        let action = ShortcutAction.runScriptFile(
            path: "/Users/test/scripts/hello.sh",
            shell: .zsh
        )
        #expect(action.displayDescription == "Zsh: hello.sh")
    }

    @Test("System images are non-empty")
    func systemImages() {
        let app = ShortcutAction.launchApp(bundleIdentifier: "com.test", appName: "Test")
        let script = ShortcutAction.runScript(script: "echo hi", shell: .bash)
        let file = ShortcutAction.runScriptFile(path: "/test.sh", shell: .sh)

        #expect(!app.systemImage.isEmpty)
        #expect(!script.systemImage.isEmpty)
        #expect(!file.systemImage.isEmpty)
    }

    @Test("Codable round-trip for all variants")
    func codableRoundTrip() throws {
        let actions: [ShortcutAction] = [
            .launchApp(bundleIdentifier: "com.apple.safari", appName: "Safari"),
            .runScript(script: "echo hello", shell: .zsh),
            .runScriptFile(path: "/test.sh", shell: .bash),
        ]

        for action in actions {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(ShortcutAction.self, from: data)
            #expect(decoded == action)
        }
    }

    @Test("ShellType display names")
    func shellTypeDisplayNames() {
        #expect(ShortcutAction.ShellType.bash.displayName == "Bash")
        #expect(ShortcutAction.ShellType.zsh.displayName == "Zsh")
        #expect(ShortcutAction.ShellType.sh.displayName == "sh")
        #expect(ShortcutAction.ShellType.fish.displayName == "Fish")
    }

    @Test("ShellType raw values are valid paths")
    func shellTypeRawValues() {
        for shell in ShortcutAction.ShellType.allCases {
            #expect(shell.rawValue.hasPrefix("/"))
        }
    }
}
