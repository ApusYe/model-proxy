import Foundation
import ServiceManagement
import Observation
import OSLog

/// Wraps SMAppService to register/unregister the app as a login item.
@MainActor
@Observable
final class LoginItemService {

    private(set) var isEnabled: Bool = false

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            AppLog.config.error("[LoginItemService] Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
