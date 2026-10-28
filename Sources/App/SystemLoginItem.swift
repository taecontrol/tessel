#if !TESSEL_DEVELOPMENT
import Foundation
import ServiceManagement

struct SystemLoginItem: Sendable {
    func state() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .notFound: .notFound
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        @unknown default: .notRegistered
        }
    }

    /// A request's error is shown alongside the state macOS reports afterwards.
    func perform(_ request: LoginItemRequest) -> String? {
        do {
            switch request {
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            case .openSettings: SMAppService.openSystemSettingsLoginItems()
            }
            return nil
        } catch { return error.localizedDescription }
    }
}
#endif
