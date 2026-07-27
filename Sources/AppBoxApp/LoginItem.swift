import Observation
import ServiceManagement
import SwiftUI

/// Launch-at-login, via `SMAppService`.
///
/// macOS may put the registration into `.requiresApproval` — the user has to
/// enable it in System Settings, and there is no way to do it for them. That
/// state has to be surfaced or the toggle silently appears not to work.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var explanation: String {
        switch status {
        case .enabled:
            "AppBox will start automatically when you log in."
        case .requiresApproval:
            "macOS needs you to approve this in System Settings before it takes effect."
        case .notFound:
            "macOS can't find the app bundle to register. Move AppBox to /Applications and try again."
        case .notRegistered:
            "AppBox will not start automatically."
        @unknown default:
            "Unknown status."
        }
    }
}
