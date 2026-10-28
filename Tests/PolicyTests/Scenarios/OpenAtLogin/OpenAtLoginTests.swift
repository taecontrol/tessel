import Foundation
import Testing
@testable import Policy

@Suite struct OpenAtLoginTests {
    private let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    private let states: [LoginItemState] = [.notFound, .enabled, .notRegistered, .requiresApproval]

    @Test("#55 E1: an installed daily build registers once on first launch, also without Accessibility")
    func firstLaunchRegisters() throws {
        // Accessibility is deliberately not an input to the login-item decision.
        for path in ["/Applications/Tessel.app", "/Applications/Tools/Tessel.app",
                     "/Applications/Tools/../Tessel.app", "/Users/fixture/Applications/Tessel.app",
                     "/Users/fixture/Applications/Tools/../Tessel.app"] {
            var reads = 0
            let value = OpenAtLogin(development: false, bundle: URL(fileURLWithPath: path), home: home) {
                reads += 1
                return .notFound
            }
            #expect(reads == 1)
            #expect(value.launchRequest == .register)
            let registered = value.performed(refused: nil, now: .enabled)
            #expect(registered.launchRequest == nil)
            #expect(registered.menuItem == .toggle(on: true))
            #expect(registered.status == OpenAtLoginStatus(state: .enabled, reason: nil))
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registered.status)) as? [String: Any]
            #expect(json?["state"] as? String == "enabled")
            #expect(json?["reason"] is NSNull)
        }
    }

    @Test("#55 E2: choosing Open at Login when enabled unregisters and reports off without a check")
    func menuTurnsItOff() {
        let value = OpenAtLogin.installed(.enabled)
        #expect(value.clickRequest == .unregister)
        let changed = value.performed(refused: nil, now: .notRegistered)
        #expect(changed.menuItem == .toggle(on: false))
        #expect(changed.status == OpenAtLoginStatus(state: .off, reason: nil))
    }

    @Test("#55 E3: launching after a menu off never turns the login item back on")
    func launchRespectsMenuOff() {
        let value = OpenAtLogin(development: false, bundle: URL(fileURLWithPath: "/Applications/Tessel.app"), home: home) { .notRegistered }
        #expect(value.launchRequest == nil)
        #expect(value.menuItem == .toggle(on: false))
        #expect(value.status == OpenAtLoginStatus(state: .off, reason: nil))
    }

    @Test("#55 E4: choosing Open at Login after a menu off registers and reports enabled")
    func menuTurnsItOn() {
        let value = OpenAtLogin.installed(.notRegistered)
        #expect(value.clickRequest == .register)
        let changed = value.performed(refused: nil, now: .enabled)
        #expect(changed.menuItem == .toggle(on: true))
        #expect(changed.status == OpenAtLoginStatus(state: .enabled, reason: nil))
    }

    @Test("#55 E5: launching after a System Settings off leaves registration alone and reports offInSettings")
    func launchRespectsSettingsOff() {
        let value = OpenAtLogin(development: false, bundle: URL(fileURLWithPath: "/Applications/Tessel.app"), home: home) { .requiresApproval }
        #expect(value.launchRequest == nil)
        #expect(value.menuItem == .openSettings)
        #expect(value.status == OpenAtLoginStatus(state: .offInSettings, reason: nil))
    }

    @Test("#55 E6: choosing Open at Login… opens Login Items settings without changing registration")
    func menuOpensSettings() {
        let value = OpenAtLogin.installed(.requiresApproval)
        #expect(value.clickRequest == .openSettings)
        let changed = value.performed(refused: nil, now: .requiresApproval)
        #expect(changed.menuItem == .openSettings)
        #expect(changed.status == OpenAtLoginStatus(state: .offInSettings, reason: nil))
    }

    @Test("#55 E7: the next requested read reflects System Settings changes and clears a refusal only on a state change")
    func freshReadsReflectSettings() {
        // No timer is a property of App/SocketServer wiring, not a simulated clock.
        let value = OpenAtLogin.installed(.enabled, refused: "Request denied")
        let unchanged = value.reading(.enabled)
        #expect(unchanged.menuItem == .toggle(on: true))
        #expect(unchanged.status == OpenAtLoginStatus(state: .enabled, reason: "macOS refused: Request denied"))
        let off = unchanged.reading(.requiresApproval)
        #expect(off.menuItem == .openSettings)
        #expect(off.status == OpenAtLoginStatus(state: .offInSettings, reason: nil))
        let on = off.reading(.enabled)
        #expect(on.menuItem == .toggle(on: true))
        #expect(on.status == OpenAtLoginStatus(state: .enabled, reason: nil))
    }

    @Test("#55 E8: development builds never read BTM or emit requests, have no menu item and report development build")
    func developmentNeverTouchesLoginItems() {
        for state in states {
            for path in ["/Applications/Tessel Dev.app", "/Users/fixture/Applications/Tessel Dev.app", "/worktree/.build/apps/Tessel Dev.app"] {
                var reads = 0
                let value = OpenAtLogin(development: true, bundle: URL(fileURLWithPath: path), home: home) {
                    reads += 1
                    return state
                }
                #expect(reads == 0)
                for current in [value, value.reading(state), value.performed(refused: "Denied", now: state)] {
                    #expect(current.launchRequest == nil)
                    #expect(current.clickRequest == nil)
                    #expect(current.menuItem == .absent)
                    #expect(current.status == OpenAtLoginStatus(state: .unavailable, reason: "development build"))
                }
            }
        }
    }

    @Test("#55 E9: daily builds outside Applications never read BTM or emit requests and explain the disabled menu item")
    func misplacedDailyNeverTouchesLoginItems() {
        for path in ["/worktree/.build/apps/Tessel.app", "/Applications-old/Tessel.app",
                     "/Applications/../Downloads/Tessel.app", "/Users/fixture/Applications-old/Tessel.app",
                     "/Users/fixture/Applications/../Downloads/Tessel.app", "/Users/other/Applications/Tessel.app"] {
            for state in states {
                var reads = 0
                let value = OpenAtLogin(development: false, bundle: URL(fileURLWithPath: path), home: home) {
                    reads += 1
                    return state
                }
                #expect(reads == 0)
                for current in [value, value.reading(state), value.performed(refused: "Denied", now: state)] {
                    #expect(current.launchRequest == nil)
                    #expect(current.clickRequest == nil)
                    #expect(current.menuItem == .disabled("Open at Login: move tessel to Applications"))
                    #expect(current.status == OpenAtLoginStatus(state: .unavailable, reason: "not in Applications"))
                }
            }
        }
    }

    @Test("#55 E10: a refused register or unregister reports BTM's actual state and reason without an automatic retry")
    func refusedRequestsKeepTheReportedState() {
        let cases: [(LoginItemState, LoginItemRequest, LoginItemState, LoginMenuItem, OpenAtLoginStatus.State)] = [
            (.notFound, .register, .notFound, .toggle(on: false), .off),
            (.notRegistered, .register, .requiresApproval, .openSettings, .offInSettings),
            (.enabled, .unregister, .enabled, .toggle(on: true), .enabled),
            (.enabled, .unregister, .notRegistered, .toggle(on: false), .off),
        ]
        for (before, request, reported, menu, state) in cases {
            let value = OpenAtLogin.installed(before)
            #expect(before == .notFound ? value.launchRequest == request : value.clickRequest == request)
            let failed = value.performed(refused: "Request denied", now: reported)
            let expected = OpenAtLoginStatus(state: state, reason: "macOS refused: Request denied")
            #expect(failed.menuItem == menu)
            #expect(failed.status == expected)
            #expect(failed.launchRequest == nil)
            #expect(failed.reading(reported).status == expected)
            #expect(failed.reading(reported).launchRequest == nil)
            let next: LoginItemState = reported == .enabled ? .notRegistered : .enabled
            #expect(failed.reading(next).status.reason == nil)
        }
    }

    @Test("#55 E10: opening Login Items settings keeps a refusal while BTM still reports the same state")
    func openingSettingsKeepsARefusal() {
        let refused = OpenAtLogin.installed(.notRegistered).performed(refused: "Request denied", now: .requiresApproval)
        #expect(refused.clickRequest == .openSettings)
        let opened = refused.performed(refused: nil, now: .requiresApproval)
        #expect(opened.status == OpenAtLoginStatus(state: .offInSettings, reason: "macOS refused: Request denied"))
        #expect(refused.performed(refused: nil, now: .enabled).status == OpenAtLoginStatus(state: .enabled, reason: nil))
    }

    @Test("#55 E11: status text says on, off, off in System Settings or unavailable with its reason")
    func statusText() {
        let cases: [(OpenAtLoginStatus, String)] = [
            (OpenAtLoginStatus(state: .enabled, reason: nil), "Open at login: on"),
            (OpenAtLoginStatus(state: .off, reason: nil), "Open at login: off"),
            (OpenAtLoginStatus(state: .offInSettings, reason: nil), "Open at login: off in System Settings"),
            (OpenAtLoginStatus(state: .unavailable, reason: "development build"), "Open at login: unavailable (development build)"),
            (OpenAtLoginStatus(state: .unavailable, reason: "not in Applications"), "Open at login: unavailable (not in Applications)"),
            (OpenAtLoginStatus(state: .enabled, reason: "macOS refused: Request denied"), "Open at login: on"),
        ]
        for (status, text) in cases { #expect(status.text == text) }
    }

    @Test("status JSON retains login-item fields and accepts replies predating openAtLogin")
    func statusCompatibility() throws {
        var status = AppStatus(permission: "needed", config: ConfigStatus(path: "/fixture/tessel.toml"), version: "fixture", pid: 1)
        #expect(status.openAtLogin == OpenAtLoginStatus(state: .unavailable, reason: "development build"))
        status.openAtLogin = OpenAtLoginStatus(state: .enabled, reason: "macOS refused: Request denied")
        let data = try JSONEncoder().encode(status)
        let decoded = try? JSONDecoder().decode(AppStatus.self, from: data)
        #expect(decoded?.openAtLogin == status.openAtLogin)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "openAtLogin")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try? JSONDecoder().decode(AppStatus.self, from: oldData)
        #expect(old?.openAtLogin == OpenAtLoginStatus(state: .unavailable, reason: "development build"))
        #expect(old?.permission == "needed")
    }
}
