import Foundation
import Testing
@testable import TapTickKit

@Suite("ScriptRunner")
struct ScriptRunnerTests {
    @Test("Stored timeout defaults and invalid values remain bounded")
    func storedTimeout() throws {
        let suiteName = "TapTickTests.ScriptTimeout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ScriptExecutionSettings.timeout(defaults: defaults) == 60)
        for (stored, expected) in [(120.0, 120.0), (0, 1), (7200, 3600), (1.6, 2), (.nan, 60)] {
            defaults.set(stored, forKey: ScriptExecutionSettings.timeoutKey)
            #expect(ScriptExecutionSettings.timeout(defaults: defaults) == expected)
        }
    }

    @Test("An existing runner reads changed stored timeouts for subsequent runs")
    func appliesChangedTimeout() async throws {
        let suiteName = "TapTickTests.ScriptTimeout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = try makeScript("#!/bin/sh\nprintf started\n/bin/sleep 2")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let runner = ScriptRunner.process(timeoutProvider: {
            ScriptExecutionSettings.timeout(defaults: UserDefaults(suiteName: suiteName)!)
        })

        defaults.set(1, forKey: ScriptExecutionSettings.timeoutKey)
        let timedOut = await runner.run(ScriptCommand(fileURL: url))
        #expect(!timedOut.succeeded)
        #expect(timedOut.output.contains("started"))
        #expect(timedOut.output.contains("timed out after 1 seconds"))

        defaults.set(10, forKey: ScriptExecutionSettings.timeoutKey)
        let completed = await runner.run(ScriptCommand(fileURL: url))
        #expect(completed.succeeded)
        #expect(completed.output == "started")
    }

    @Test("Captures combined output and nonzero exit status")
    func capturesOutputAndExitStatus() async throws {
        let url = try makeScript("#!/bin/sh\nprintf output; printf error >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ScriptRunner.live.run(ScriptCommand(fileURL: url))

        #expect(result.output == "outputerror")
        #expect(result.exitCode == 7)
        #expect(!result.succeeded)
        #expect(result.duration > 0)
    }

    @Test("Reports a missing script file as a typed process failure")
    func reportsMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTick-missing-\(UUID().uuidString)")

        let result = await ScriptRunner.live.run(ScriptCommand(fileURL: url))

        guard case .failed(let message) = result.termination else {
            Issue.record("Expected a failed termination")
            return
        }
        #expect(message.contains("Script file not found"))
        #expect(result.exitCode == -1)
    }

    @Test("Rejects a script without a shebang")
    func rejectsMissingShebang() async throws {
        let url = try makeScript("echo no")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ScriptRunner.live.run(ScriptCommand(fileURL: url))

        #expect(!result.succeeded)
        #expect(result.output.contains("shebang"))
    }

    @Test("Drains output while the child process is running")
    func drainsLargeOutput() async throws {
        let byteCount = 262_144
        let url = try makeScript(
            "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c \(byteCount)"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ScriptRunner.live.run(ScriptCommand(fileURL: url))

        #expect(result.succeeded)
        #expect(result.output.utf8.count == byteCount)
    }

    @Test("Timeout stops scripts that ignore TERM and preserves partial output")
    func timesOutUnresponsiveScript() async throws {
        let url = try makeScript("#!/bin/sh\ntrap '' TERM\nprintf partial\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ScriptRunner.process(timeout: 2).run(ScriptCommand(fileURL: url))

        #expect(!result.succeeded)
        #expect(result.output.contains("partial"))
        #expect(result.output.contains("timed out"))
        #expect(result.duration < 5)
        let log = ScriptExecutionLog(shortcutID: UUID(), result: result)
        let restored = try JSONDecoder().decode(ScriptExecutionLog.self, from: JSONEncoder().encode(log))
        #expect(restored.displayText.contains("timed out"))
        #expect(restored.subtitleText?.contains("timed out") == true)
    }

    @Test("Timeout also covers inherited pipes after the script exits")
    func timesOutInheritedPipe() async throws {
        let url = try makeScript("#!/bin/sh\n/bin/sleep 30 &\nprintf started\nexit 0")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await ScriptRunner.process(timeout: 2).run(ScriptCommand(fileURL: url))

        #expect(!result.succeeded)
        #expect(result.output.contains("started"))
        #expect(result.output.contains("timed out"))
        #expect(result.duration < 5)
    }

    private func makeScript(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapTickRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("script")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }
}
