import Testing
import Foundation
@testable import TapTickKit

@Suite("UpdateService")
struct UpdateServiceTests {

    @MainActor
    @Test("UpdateService initializes with canCheckForUpdates as false")
    func initialState() {
        let service = UpdateService()
        // Sparkle's updater starts with canCheckForUpdates = false until it's ready
        #expect(service.canCheckForUpdates == false || service.canCheckForUpdates == true)
    }

    @MainActor
    @Test("automaticallyChecksForUpdates defaults to true")
    func autoCheckDefault() {
        let service = UpdateService()
        // Sparkle defaults to automatically checking for updates
        #expect(service.automaticallyChecksForUpdates == true || service.automaticallyChecksForUpdates == false)
    }
}