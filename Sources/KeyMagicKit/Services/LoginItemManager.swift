import Foundation
import Observation
import ServiceManagement

/// Manages the "Launch at Login" setting using ServiceManagement framework.
@Observable
public final class LoginItemManager: @unchecked Sendable {
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
            print("KeyMagic: Failed to toggle login item: \(error)")
        }
        refreshStatus()
    }

    /// Enable launch at login.
    func enable() {
        guard !isEnabled else { return }
        toggle()
    }

    /// Disable launch at login.
    func disable() {
        guard isEnabled else { return }
        toggle()
    }

    /// Refresh the current status from the system.
    func refreshStatus() {
        isEnabled = service.status == .enabled
    }
}
