import Foundation

/// ServiceManagement's state without a platform dependency in Policy.
enum LoginItemState: Equatable, Sendable {
    case notFound, enabled, notRegistered, requiresApproval
}

enum LoginItemRequest: Equatable, Sendable {
    case register, unregister, openSettings
}

enum LoginMenuItem: Equatable {
    case absent
    case disabled(String)
    case toggle(on: Bool)
    case openSettings
}

enum OpenAtLogin: Equatable, Sendable {
    case development
    case notInApplications
    case installed(LoginItemState, refused: String? = nil)

    // Compile scaffolding; the acceptance tests define the missing behavior.
    init(development: Bool, bundle: URL, home: URL, read readLoginItem: () -> LoginItemState) {
        self = .installed(.notRegistered)
    }

    var launchRequest: LoginItemRequest? { nil }
    var clickRequest: LoginItemRequest? { nil }
    var menuItem: LoginMenuItem { .absent }
    var status: OpenAtLoginStatus { OpenAtLoginStatus(state: .off, reason: nil) }
    func reading(_ state: LoginItemState) -> OpenAtLogin { self }
    func performed(refused: String?, now state: LoginItemState) -> OpenAtLogin { self }
}
