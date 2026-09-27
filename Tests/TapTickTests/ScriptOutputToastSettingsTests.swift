import Foundation
import Testing
@testable import TapTickKit

@Suite("ScriptOutputToastSettings")
struct ScriptOutputToastSettingsTests {
    @Test("Stored toast durations use the configured default, range, and step")
    func normalizesStoredDuration() throws {
        let suiteName = "TapTickTests.ToastDuration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ScriptOutputToastSettings.holdDuration(defaults: defaults) == 2.4)

        defaults.set(2.0, forKey: ScriptOutputToastSettings.holdDurationKey)
        #expect(ScriptOutputToastSettings.holdDuration(defaults: defaults) == 1.8)

        defaults.set(0.5, forKey: ScriptOutputToastSettings.holdDurationKey)
        #expect(ScriptOutputToastSettings.holdDuration(defaults: defaults) == 1.2)

        defaults.set(10.0, forKey: ScriptOutputToastSettings.holdDurationKey)
        #expect(ScriptOutputToastSettings.holdDuration(defaults: defaults) == 6.0)

        defaults.set(Double.nan, forKey: ScriptOutputToastSettings.holdDurationKey)
        #expect(ScriptOutputToastSettings.holdDuration(defaults: defaults) == 2.4)
    }
}
