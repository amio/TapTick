import Foundation
import Observation
import ServiceManagement

/// Manages the "Launch at Login" setting using ServiceManagement framework.
@Observable
@MainActor
public final class LoginItemManager {
    private(set) var isEnabled: Bool = false

    private let service = SMAppService.mainApp

    public init() {
        refreshStatus()
    }

    /// Toggle launch-at-login on/off.
    func toggle() {
        do {
            if isEnabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            print("TapTick: Failed to toggle login item: \(error)")
        }
        refreshStatus()
    }

    /// Refresh the current status from the system.
    func refreshStatus() {
        isEnabled = service.status == .enabled
    }
}
