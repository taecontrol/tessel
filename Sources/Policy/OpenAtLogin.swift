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

    /// Only an installed daily copy may read or change the login item.
    init(development: Bool, bundle: URL, home: URL, read readLoginItem: () -> LoginItemState) {
        guard !development else { self = .development; return }
        let path = bundle.standardizedFileURL.path
        let applications = ["/Applications", home.appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path]
        guard applications.contains(where: { path.hasPrefix($0 + "/") }) else {
            self = .notInApplications
            return
        }
        self = .installed(readLoginItem())
    }

    var launchRequest: LoginItemRequest? {
        if case .installed(.notFound, refused: nil) = self { .register } else { nil }
    }

    var clickRequest: LoginItemRequest? {
        switch self {
        case .development, .notInApplications: nil
        case .installed(.enabled, _): .unregister
        case .installed(.notFound, _), .installed(.notRegistered, _): .register
        case .installed(.requiresApproval, _): .openSettings
        }
    }

    var menuItem: LoginMenuItem {
        switch self {
        case .development: .absent
        case .notInApplications: .disabled("Open at Login: move tessel to Applications")
        case .installed(.enabled, _): .toggle(on: true)
        case .installed(.notFound, _), .installed(.notRegistered, _): .toggle(on: false)
        case .installed(.requiresApproval, _): .openSettings
        }
    }

    var status: OpenAtLoginStatus {
        switch self {
        case .development: return OpenAtLoginStatus(state: .unavailable, reason: "development build")
        case .notInApplications: return OpenAtLoginStatus(state: .unavailable, reason: "not in Applications")
        case .installed(let state, let refused):
            let reported: OpenAtLoginStatus.State = switch state {
            case .enabled: .enabled
            case .notFound, .notRegistered: .off
            case .requiresApproval: .offInSettings
            }
            return OpenAtLoginStatus(state: reported, reason: refused.map { "macOS refused: " + $0 })
        }
    }

    /// Keep a refusal only while BTM still reports the state that followed it.
    func reading(_ state: LoginItemState) -> OpenAtLogin {
        guard case .installed(let previous, _) = self else { return self }
        return previous == state ? self : .installed(state)
    }

    /// A request that macOS accepted, such as opening Settings, is only a fresh
    /// read: it must not clear an earlier refusal while the state is unchanged.
    func performed(refused: String?, now state: LoginItemState) -> OpenAtLogin {
        guard case .installed = self else { return self }
        guard let refused else { return reading(state) }
        return .installed(state, refused: refused)
    }
}
