import Testing
import Foundation
@testable import TapTickKit

@Suite("ShortcutAction")
struct ShortcutActionTests {

    @Test("Codable round-trip for all variants")
    func codableRoundTrip() throws {
        let actions: [ShortcutAction] = [
            .launchApp(bundleIdentifier: "com.apple.safari", appName: "Safari"),
            .runScript(script: "#!/bin/zsh\necho hello"),
            .runScriptFile(path: "/test.sh", shell: .bash),
        ]

        for action in actions {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(ShortcutAction.self, from: data)
            #expect(decoded == action)
        }
    }

    @Test("Legacy inline action gains its selected shell as a shebang")
    func legacyInlineMigration() throws {
        let data = Data(#"{"runScript":{"script":"echo hi","shell":"/bin/bash"}}"#.utf8)
        let action = try JSONDecoder().decode(ShortcutAction.self, from: data)
        #expect(action == .runScript(script: "#!/bin/bash\n\necho hi"))
    }
}
