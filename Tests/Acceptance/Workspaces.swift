import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

/// Issue #2's accepted examples. Shortcuts cross Carbon; frames and focus come
/// from an independent AX client and visibility from CG, never tessel's claims.
extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct FunctionalWorkspaces: AppSessionTest {
        init() throws {
            try Harness.shared.reset()
            struct Budget: Decodable { let nanoseconds: UInt64; let measurements: [UInt64]; let sourceRun: String }
            let recorded = try JSONDecoder().decode(Budget.self, from: Data(contentsOf: root.appending(path: "Tests/Acceptance/switch-budget.json")))
            let maximum = recorded.measurements.max() ?? 0
            try #require(recorded.measurements.count == 20 && recorded.measurements.allSatisfy { $0 > 0 && $0 <= 200_000_000 }
                         && UInt64(recorded.sourceRun) != nil && recorded.nanoseconds == min(200_000_000, maximum * 3),
                         "the switch budget must retain twenty CI measurements and their capped calibration")
            budget = Double(recorded.nanoseconds) / 1e9
        }
        let enabled = "[experiments]\nworkspaces = true\n"

        let budget: Double

        func enable(_ extra: String = "") throws {
            let revision = try harness.status().config.revision
            try writeConfig(enabled + extra)
            try #require(try eventually(within: 1) {
                let status = try harness.status()
                return status.workspaces?.enabled == true && status.config.revision > revision
            },
                         "the accepted workspaces configuration must enable the experiment")
        }

        func observe(_ sessions: [FixtureSession]? = nil, finder: Bool = false, focusedOnly: Bool = false) throws -> Observation {
            try #require(try harness.observer.command("observe", ["pids": (sessions ?? [fixture] + harness.otherFixtures).map(\.pid),
                "finder": finder, "focusedOnly": focusedOnly]).observation)
        }

        func window(_ id: UInt32) throws -> Observation.Window? { try observe().windows.first { $0.id == id } }

        func visible(_ id: UInt32) throws -> Bool { try observe(focusedOnly: true).visibleIDs.contains(id) }

        /// Observe the active number without including CLI startup in a switch.
        /// The suffix distinguishes workspace 1 from workspace 10.
        func statusItemShows(_ workspace: Int) throws -> Bool {
            try harness.observer.command("menu", ["pid": harness.appPID, "open": false,
                "expected": "Workspace \(workspace)", "suffix": true]).menuContains == true
        }

        func filled(_ window: Observation.Window, area: [Double], gap: Double = 10) -> Bool {
            let expected = [area[0] + gap, area[1] + gap, area[2] - gap * 2, area[3] - gap * 2]
            return zip(window.frame, expected).allSatisfy { abs($0 - $1) <= 1 }
        }

        func shown(_ id: UInt32, gap: Double = 10, floating: Bool = false) throws -> Bool {
            let observation = try observe(focusedOnly: true)
            guard let window = observation.windows.first(where: { $0.id == id }) else { return false }
            let focused = window.focused || observation.windows.contains { $0.parent == id && $0.focused }
            return window.visible && window.main && focused && (floating || filled(window, area: observation.area, gap: gap))
        }

        func expectShown(_ id: UInt32, since start: Double? = nil, within timeout: Double? = nil,
                         gap: Double = 10, floating: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let remaining = max(0, (timeout ?? (start == nil ? 1 : budget)) - (start.map { monotonicSeconds() - $0 } ?? 0))
            let success = try eventually(within: remaining) { try shown(id, gap: gap, floating: floating) }
            try #require(success,
                         "fixture \(id) must be visible, focused, and correctly sized before the deadline", sourceLocation: sourceLocation)
        }

        @discardableResult
        func key(_ number: Int, send: Bool = false) throws -> Double {
            let codes = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 10: 29]
            return try post(codes[number]!, shift: send)
        }

        @discardableResult
        func post(_ code: Int, shift: Bool = false) throws -> Double {
            try #require(try harness.observer.command("hotkey", ["code": code, "shift": shift]).postedAt)
        }

        func activate(_ session: FixtureSession? = nil, key: String = "window", sourceLocation: SourceLocation = #_sourceLocation) throws {
            let session = session ?? fixture
            try yieldActivation(to: session)
            try session.command("activate", ["key": key])
            var arguments: [String: Any] = ["pid": session.pid]
            let target = try session.command("ping").windows[key]
            if let target { arguments["id"] = target }
            try harness.observer.command("activateFixture", arguments)
            let hasWindows = try !session.command("ping").windows.isEmpty
            let active = try eventually {
                let observation = try observe()
                guard observation.activeFixturePID == session.pid else { return false }
                if let target {
                    guard let window = observation.windows.first(where: { $0.id == target }),
                          window.frame[2] > 0, window.frame[3] > 0 else { return false }
                }
                if hasWindows { return observation.frontmostFixturePID == session.pid }
                return try session.command("ping").active == true
            }
            try #require(active, "the target fixture must be frontmost", sourceLocation: sourceLocation)
        }

        func yieldActivation(to session: FixtureSession) throws {
            let observation = try observe()
            let front = observation.activeFixturePID != 0 ? observation.activeFixturePID : observation.frontmostFixturePID
            if front != session.pid, let source = ([fixture] + harness.otherFixtures).first(where: { $0.pid == front }) {
                try source.command("yieldActivation")
            }
        }

        func other(swiftUI: Bool = false) throws -> FixtureSession {
            let session = try FixtureSession(directory: harness.directory, number: harness.otherFixtures.count + 1, swiftUI: swiftUI)
            harness.otherFixtures.append(session)
            try #require(try eventually(within: 3) {
                try harness.observer.command("fixtureReady", ["pid": session.pid]).ready == true
            }, "LaunchServices must identify the fixture before it is activated or observed")
            return session
        }

        /// A stays in 1 and B is sent to 2, then A is shown again.
        func split() throws -> (UInt32, UInt32) {
            let a = try fixture.open(key: "a")
            let b = try fixture.open(key: "b")
            try activate(key: "b")
            try enable()
            try expectShown(b)
            try expectShown(b, since: key(2, send: true))
            try expectShown(a, since: key(1))
            return (a, b)
        }

        func expectEmpty(since start: Double) throws {
            let managed = Set(([fixture] + harness.otherFixtures).flatMap(\.windowIDs))
            let verifyFinder: Bool
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                verifyFinder = true
            } else {
                verifyFinder = try observe(finder: true).finderHasNoOrdinaryWindows == true
            }
            if !verifyFinder {
                print("Skipping Finder-frontmost assertion: Finder has ordinary or unknown AX entries, or its AXWindows read failed; managed-window visibility is still checked.")
            }
            let empty = try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                let observation = try observe(finder: verifyFinder, focusedOnly: true)
                return managed.isDisjoint(with: observation.visibleIDs) && (!verifyFinder || observation.finderDesktop)
            }
            try #require(empty, "an empty workspace must hide managed windows and, when safe, focus Finder's desktop")
        }

        @Test func e01ExperimentOffLeavesFramesAndOrdinaryKeysAlone() throws {
            let a = try fixture.open()
            try activate()
            let before = try #require(try window(a)).frame
            let count = try fixture.command("ping").keyCount
            try post(18)
            #expect(try eventually { try fixture.command("ping").keyCount == (count ?? 0) + 1 })
            #expect(try window(a)?.frame == before)
            let status = try #require(try harness.status().workspaces)
            #expect(!status.enabled)
            #expect(status.reason == "experiment off")
        }

        @Test(arguments: [false, true])
        func e02EnablingOrStartingAssignsExistingWindowsAndKeepsTheFocusedOne(startup: Bool) throws {
            if startup { harness.stopApp() }
            // Focus must win over arrival order in both startup paths.
            let c = try fixture.open(key: "c")
            let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
            try activate(key: "c")
            let start = monotonicSeconds()
            if startup {
                try writeConfig(enabled)
                try harness.startApp(fixtureReady: false)
            } else { try enable() }
            try expectShown(c, since: start, within: 1)
            let assigned = try harness.rows().filter { [a,b,c].contains($0.id) }
            #expect(assigned.count == 3 && assigned.allSatisfy { $0.workspace == 1 })
            #expect(try !visible(a))
            #expect(try !visible(b))
            #expect(try harness.status().workspaces?.active == 1)
        }

        @Test(arguments: [false, true])
        func e03ExistingDialogStaysAboveTheTiledWindowAtItsOriginalFrame(startup: Bool) throws {
            if startup { harness.stopApp() }
            let c = try fixture.open(key: "c")
            _ = try fixture.open(key: "a")
            _ = try fixture.open(key: "b")
            try activate(key: "c")
            let dialog = try fixture.open(kind: "dialog", key: "dialog")
            try activate(key: "dialog")
            let frame = try #require(try window(dialog)).frame
            if !startup {
                try #require(try converges { $0.count == 4 && $0.contains { $0.id == dialog } })
            }
            let start = monotonicSeconds()
            if startup {
                try writeConfig(enabled)
                try harness.startApp(fixtureReady: false)
            } else { try enable() }
            try #require(try eventually(within: max(0, 1 - (monotonicSeconds() - start))) {
                try harness.row(dialog)?.workspace == 1
            })
            try expectShown(dialog, since: start, within: 1, floating: true)
            #expect(try visible(c))
            #expect(try #require(try window(dialog)).order < #require(try window(c)).order)
            #expect(try window(dialog)?.frame == frame)
            #expect(try harness.row(dialog)?.workspace == 1)
        }

        @Test func e04WorkspaceShortcutsHideFillAndFocusBothDirections() throws {
            let (a,b) = try split()
            try expectShown(b, since: key(2))
            #expect(try !visible(a))
            try expectShown(a, since: key(1))
            #expect(try !visible(b))
        }

        @Test func e05OptionZeroSelectsWorkspaceTen() throws {
            let b = try fixture.open(key: "b")
            let a = try fixture.open()
            try activate()
            try enable()
            try expectShown(a)
            try expectShown(a, since: key(10, send: true))
            try expectShown(b, since: key(1))
            try expectShown(a, since: key(10))
            #expect(try harness.row(a)?.workspace == 10)
            #expect(try harness.status().workspaces?.active == 10)
        }

        @Test(arguments: [false, true])
        func e06e09SelectingOrSendingToTheCurrentWorkspaceDoesNotMoveAWindow(send: Bool) throws {
            let a = try fixture.open()
            try activate()
            try enable()
            try expectShown(a)
            sleep(seconds: 0.15)
            try fixture.command("move", ["frame": [110.0, 130.0, 420.0, 280.0]])
            let frame = try #require(try window(a)).frame
            try key(1, send: send)
            sleep(seconds: budget)
            #expect(try window(a)?.frame == frame)
        }

        @Test func e07EmptyWorkspaceFocusesFinderDesktop() throws {
            _ = try fixture.open()
            try activate()
            try enable()
            try expectEmpty(since: key(8))
            #expect(try harness.status().workspaces?.active == 8)
            let observation = try observe(finder: true)
            if ProcessInfo.processInfo.environment["CI"] != "true", observation.finderHasNoOrdinaryWindows == false {
                #expect(observation.frontmostFixture, "fixture-only empty-workspace hotkeys must leave focus with the fixture when Finder activation is unsafe")
            }
        }

        @Test func e08SendingFollowsTheWindowAndLeavesThePreviousOneAvailable() throws {
            let b = try fixture.open(key: "b"), a = try fixture.open(key: "a")
            try activate(key: "a")
            try enable()
            try expectShown(a)
            try expectShown(a, since: key(3, send: true))
            #expect(try harness.row(a)?.workspace == 3)
            #expect(try harness.status().workspaces?.active == 3)
            try expectShown(b, since: key(1))
        }

        @Test func e10SendingADialogPreservesItsFrame() throws {
            _ = try fixture.open(key: "a")
            let dialog = try fixture.open(kind: "dialog", key: "dialog")
            try activate(key: "dialog")
            let frame = try #require(try window(dialog)).frame
            try enable()
            try expectShown(dialog, floating: true)
            try expectShown(dialog, since: key(4, send: true), floating: true)
            #expect(try window(dialog)?.frame == frame)
            #expect(try harness.row(dialog)?.workspace == 4)
        }

        @Test func e11SendingTheLastWindowLeavesAnEmptyWorkspace() throws {
            let a = try fixture.open()
            try activate()
            try enable()
            try expectShown(a)
            try expectShown(a, since: key(3, send: true))
            try expectEmpty(since: key(1))
        }

        @Test func e12CyclingUsesArrivalOrderAndWrapsInBothDirections() throws {
            let a = try fixture.open(key: "a"), b = try fixture.open(key: "b"), c = try fixture.open(key: "c")
            try activate(key: "c")
            try enable()
            try expectShown(c)
            try expectShown(a, since: post(38))
            for expected in [b,c,a] { try expectShown(expected, since: post(38)) }
            for expected in [c,b,a] { try expectShown(expected, since: post(40)) }
        }

        @Test func e13CycleIncludesFloatsButSkipsMinimizedHiddenAndSheets() throws {
            let hidden = try other()
            let h = try hidden.open()
            try hidden.command("hide")
            let a = try fixture.open(key: "a")
            let m = try fixture.open(key: "minimized")
            try fixture.command("minimize", ["key": "minimized"])
            let d = try fixture.open(kind: "dialog", key: "dialog")
            let frame = try #require(try window(d)).frame
            try activate(key: "dialog")
            try enable()
            try expectShown(d, floating: true)
            try expectShown(a, since: post(38))
            try expectShown(d, since: post(38), floating: true)
            #expect(try window(d)?.frame == frame)
            #expect(try harness.row(m)?.state == "minimized")
            #expect(try harness.row(h)?.state == "hidden")
            // E24 independently exercises a real attached sheet; it cannot be cycled away from its parent.
            let sheet = try fixture.open(kind: "sheet", key: "sheet")
            let parent = try #require(try fixture.command("ping").windows["sheetParent"])
            try #require(try eventually { try harness.row(parent)?.workspace == 1 })
            for expected in [a,d,parent,a] {
                try expectShown(expected, since: post(38), floating: expected == d)
                #expect(try window(sheet)?.main != true)
            }
        }

        @Test(arguments: [false, true])
        func e12ReplacingANativeTabFrontPreservesArrivalOrderAndWorkspace(inserting: Bool) throws {
            let b = try fixture.open(key: "b")
            try activate(key: "b")
            try enable()
            try expectShown(b)
            let group = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
            let first = try #require(group.windows["tabs0"])
            try expectShown(first)
            try #require(try converges { $0.count == 2 && $0.contains { $0.id == first && $0.tabs == 3 } })
            let c = try fixture.open(key: "c")
            try expectShown(c)
            try expectShown(first, since: post(40))

            func replaceFront(key: String) throws -> UInt32 {
                let reply = inserting
                    ? try fixture.command("addTab", ["key": key, "reference": "tabs0"])
                    : try fixture.command("tab", ["key": key])
                return try #require(reply.windows[key])
            }
            let replacement = try replaceFront(key: inserting ? "inserted" : "tabs1")
            try #require(try converges { $0.count == 3 && $0.contains { $0.id == replacement && $0.workspace == 1 && $0.tabs == (inserting ? 4 : 3) } })
            try expectShown(replacement)
            // The group arrived between B and C; a different front is not an arrival.
            try expectShown(c, since: post(38))
            try expectShown(replacement, since: post(40))

            // A background selection must preserve hide intent and the group's
            // focus history while another fixture owns the active workspace.
            let foreground = try other()
            let d = try foreground.open()
            try activate(foreground)
            try expectShown(d)
            try expectShown(d, since: key(2, send: true))
            let backgroundReplacement = try replaceFront(key: inserting ? "backgroundInserted" : "tabs2")
            try #require(try converges { $0.count == 4 && $0.contains { $0.id == backgroundReplacement && $0.workspace == 1 } })
            #expect(try !visible(backgroundReplacement))
            #expect(try harness.status().workspaces?.active == 2)
            try expectShown(d)
            try expectShown(backgroundReplacement, since: key(1))

            try expectShown(backgroundReplacement, since: key(3, send: true))
            // A delayed activation from the preceding handoff must not undo a
            // newer keyboard selection, even when sends finish without moving.
            for _ in 0..<4 {
                try expectShown(c, since: key(1))
                try expectShown(backgroundReplacement, since: key(3))
            }
            try expectShown(c, since: key(1))
            #expect(try !visible(backgroundReplacement))

            // Selecting a hidden group's next front keeps its original workspace.
            let hiddenReplacement = try replaceFront(key: inserting ? "insertedAgain" : "tabs0")
            try #require(try converges { $0.count == 4 && $0.contains { $0.id == hiddenReplacement && $0.workspace == 3 } })
            try expectShown(hiddenReplacement)
            #expect(try harness.status().workspaces?.active == 3)
            try expectShown(c, since: key(1))
            #expect(try !visible(hiddenReplacement))
        }

        @Test func e14NewWindowJoinsTheActiveWorkspaceAndTheEndOfTheCycle() throws {
            let (a,b) = try split()
            try expectShown(b, since: key(2))
            let start = monotonicSeconds()
            let c = try fixture.open(key: "c")
            try expectShown(c, since: start, within: 0.5)
            #expect(try harness.row(c)?.workspace == 2)
            #expect(try !visible(a))
            try expectShown(b, since: post(38))
            try expectShown(c, since: post(38))
        }

        @Test(arguments: [false, true])
        func e15ClosingCannotFollowMacOSFocusToAnotherWorkspace(last: Bool) throws {
            let a = try fixture.open(key: "a")
            let b = last ? nil : try fixture.open(key: "b")
            let d = try fixture.open(key: "d")
            try activate(key: "d")
            try enable()
            try expectShown(d)
            try expectShown(d, since: key(3, send: true))
            if let b { try expectShown(b, since: key(1)); try expectShown(a, since: post(40)) }
            else { try expectShown(a, since: key(1)) }
            let start = monotonicSeconds()
            try fixture.command("close", ["key": "a"])
            if let b { try expectShown(b, since: start) } else { try expectEmpty(since: start) }
            for _ in 0..<10 {
                #expect(try harness.status().workspaces?.active == 1)
                sleep(seconds: 0.02)
            }
        }

        @Test func e16ExternalActivationRescuesAnInvisibleFocusedFixtureWindow() throws {
            let a = try fixture.open(key: "a")
            let x = try other(), d = try x.open()
            try activate(x)
            try enable()
            try expectShown(d)
            try expectShown(d, since: key(3, send: true))
            try expectShown(a, since: key(1))
            // Validate the stand-in: without tessel running, plain activation really
            // leaves the app frontmost with a main window that is still invisible.
            kill(harness.appPID, SIGSTOP)
            do {
                defer { kill(harness.appPID, SIGCONT) }
                try yieldActivation(to: x)
                try x.command("activate", ["key": "activationOnly"])
                try #require(try eventually { try observe().frontmostFixturePID == x.pid }, "the fixture must activate itself with all windows in the closet")
                try #require(try eventually { try window(d).map { $0.focused && !$0.visible } == true })
            }
            try expectShown(d)
            try expectShown(a, since: key(1))
            try yieldActivation(to: x)
            let start = monotonicSeconds()
            try x.command("activate", ["key": "activationOnly"])
            try expectShown(d, since: start)
            #expect(try harness.status().workspaces?.active == 3)
        }

        @Test(arguments: [false, true])
        func e16ActivationAfterFailedOrCancelledPresentationRescuesTheActualFocus(cancelled: Bool) throws {
            let b = try fixture.open(key: "b"), c = try fixture.open(key: "c")
            let empty = try other()
            try activate(key: "c")
            try enable()
            try expectShown(c)
            try expectShown(c, since: key(2, send: true))
            try expectShown(b, since: key(1))
            try expectShown(b, since: key(3, send: true))

            // Queue real hotkeys while their safety check can still read a
            // responsive, visible fixture. Suspend it only after posting: AX
            // presentation must fail without ever changing its focused window.
            kill(harness.appPID, SIGSTOP)
            do {
                defer { kill(harness.appPID, SIGCONT) }
                try key(2)
                if cancelled { try key(1) }
                kill(fixture.pid, SIGSTOP)
            }
            defer { kill(fixture.pid, SIGCONT) }
            let destination = cancelled ? 1 : 2
            try #require(try eventually { try harness.status().workspaces?.active == destination })
            // Exceed the bounded AX timeout before resuming the app. In the
            // cancellation case the second render has already ended its intent.
            sleep(seconds: 0.4)
            // Establish a windowless foreground app without relying on AppKit
            // activating a never-keyed windowless process. While tessel is
            // paused, activate Y with a temporary fixture window, then close it.
            // No catalog snapshot can observe that setup window.
            kill(harness.appPID, SIGSTOP)
            do {
                defer { kill(harness.appPID, SIGCONT) }
                kill(fixture.pid, SIGCONT)
                _ = try empty.open()
                try activate(empty)
                try empty.command("close")
                let foreground = try empty.command("ping")
                try #require(foreground.active == true && foreground.windows.isEmpty)
            }
            // Let read-only recovery snapshots settle with the windowless app
            // frontmost; none is an acknowledgement of the requested C focus.
            sleep(seconds: 0.5)
            #expect(try harness.status().workspaces?.active == destination)
            #expect(try !visible(b))
            try yieldActivation(to: fixture)
            let start = monotonicSeconds()
            // With C still visible, AppKit may select it on a plain activation.
            // Select B explicitly in the failed-only case; cancellation leaves
            // both windows hidden and preserves the unchanged key-window trace.
            try fixture.command("activate", ["key": cancelled ? "activationOnly" : "b"])
            try expectShown(b, since: start)
            #expect(try harness.status().workspaces?.active == 3)
        }

        @Test func e16ActivatingAnInvisibleFocusedSheetRescuesItsParentsWorkspace() throws {
            let a = try fixture.open(key: "a")
            try activate(key: "a")
            try enable()
            let x = try other()
            try activate(x)
            let sheet = try x.open(kind: "sheet", key: "sheet")
            let parent = try #require(try x.command("ping").windows["sheetParent"])
            try expectShown(parent)
            try #require(try eventually { try window(sheet)?.focused == true })
            try expectShown(parent, since: key(3, send: true))
            try expectShown(a, since: key(1))
            try yieldActivation(to: x)
            let start = monotonicSeconds()
            try x.command("activate", ["key": "activationOnly"])
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                try shown(parent) && visible(sheet) && statusItemShows(3)
            }, "activating a focused sheet must show its parent workspace")
            #expect(try harness.status().workspaces?.active == 3)
        }

        @Test func e17ActivatingAnAppWhoseFocusedWindowIsHereKeepsTheWorkspace() throws {
            let (a,_) = try split()
            let empty = try other()
            try activate(empty)
            try yieldActivation(to: fixture)
            let start = monotonicSeconds()
            try fixture.command("activate", ["key": "activationOnly"])
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                try shown(a) && statusItemShows(1)
            })
            #expect(try harness.status().workspaces?.active == 1)
        }

        @Test func e18ActivatingAnAppWithoutWindowsDoesNotSwitchWorkspace() throws {
            _ = try split()
            let empty = try other()
            try activate(empty)
            sleep(seconds: budget)
            #expect(try harness.status().workspaces?.active == 1)
        }

        @Test(arguments: [0.0, 10.0])
        func e19TilesFillVisibleFrameWithConfiguredGapAndOnePointTolerance(gap: Double) throws {
            let a = try fixture.open()
            try activate()
            try enable("[gaps]\nouter = \(Int(gap))\n")
            try expectShown(a, gap: gap)
            #expect(try harness.row(a)?.state == "tiled")
            #expect(try harness.row(a)?.reason.contains("cannot fill") == false)
        }

        enum WidthLimit: CaseIterable, Sendable { case appKit, swiftUI, nativeTabs }

        @Test(arguments: WidthLimit.allCases)
        func e20AppKitAndSwiftUIWidthLimitsFloatCenteredOnEveryShow(_ kind: WidthLimit) throws {
            let session = kind == .swiftUI ? try other(swiftUI: true) : fixture
            var a: UInt32
            if kind == .swiftUI {
                a = try #require(try eventualValue(within: 3) { try session.command("ping").windows["window"] })
            } else if kind == .nativeTabs {
                a = try #require(try session.command("open", ["kind": "tabs", "key": "limited", "count": 2,
                                                            "windowKind": "maxWidth"]).windows["limited0"])
            } else { a = try session.open(kind: "maxWidth") }
            try activate(session)
            let immediate = try #require(try harness.probe(resizing: a, session: session).first { $0.id == a })
            #expect(immediate.resizeError == 0)
            #expect(try #require(immediate.acceptedSize).first! < 550)
            try enable()
            if kind == .nativeTabs {
                try expectShown(a, floating: true)
                try expectState(a, "floats", "cannot fill the screen")
                a = try #require(try session.command("tab", ["key": "limited1"]).windows["limited1"])
            }
            try expectShown(a, floating: true)
            let row = try expectState(a, "floats", "cannot fill the screen")
            #expect(row.workspace == 1)
            func centered() throws -> Bool {
                let observation = try observe(focusedOnly: true)
                let window = try #require(observation.windows.first { $0.id == a })
                return abs(window.frame[0] + window.frame[2] / 2 - (observation.area[0] + observation.area[2] / 2)) <= 1
                    && abs(window.frame[1] + window.frame[3] / 2 - (observation.area[1] + observation.area[3] / 2)) <= 1
                    && window.frame[2] < observation.area[2] - 100
            }
            #expect(try centered())
            for target in [2,1] {
                let start = try key(target, send: true)
                #expect(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                    try statusItemShows(target) && shown(a, floating: true) && centered()
                })
                #expect(try harness.status().workspaces?.active == target)
                #expect(try harness.row(a)?.state == "floats")
                #expect(try harness.row(a)?.reason == "cannot fill the screen")
            }
        }

        @Test(arguments: [false, true])
        func e21ManualMoveIsLeftAloneUntilTheWindowIsShownAgain(nativeTabs: Bool) throws {
            var a: UInt32
            let b: UInt32
            if nativeTabs {
                let group = try fixture.command("open", ["kind": "tabs", "key": "a", "count": 2])
                a = try #require(group.windows["a0"])
                b = try fixture.open(key: "b")
                try activate(key: "b")
                try enable()
                try expectShown(b)
                try expectShown(b, since: key(2, send: true))
                try expectShown(a, since: key(1))
            } else { (a,b) = try split() }
            sleep(seconds: 0.15)
            try fixture.command("move", ["key": nativeTabs ? "a0" : "a", "frame": [120.0, 130.0, 430.0, 290.0]])
            let frame = try #require(try window(a)).frame
            if nativeTabs {
                a = try #require(try fixture.command("tab", ["key": "a1"]).windows["a1"])
                try #require(try converges { $0.count == 2 && $0.contains { $0.id == a && $0.workspace == 1 } })
            }
            let empty = try other()
            empty.stop()
            harness.otherFixtures.removeAll { $0 === empty }
            sleep(seconds: 0.15)
            let after = try window(a)?.frame
            #expect(after == frame)
            let dialog = try fixture.open(kind: "dialog", key: "dialog")
            try expectShown(dialog, floating: true)
            #expect(try window(a)?.frame == frame)
            try fixture.command("close", ["key": "dialog"])
            try #require(try eventually { try window(dialog) == nil })
            #expect(try window(a)?.frame == frame)
            try expectShown(b, since: key(2))
            try expectShown(a, since: key(1))
        }

        @Test func e15DeliberateSelectionAfterCloseStillFollowsExternalFocus() throws {
            let a = try fixture.open(key: "a"), b = try fixture.open(key: "b"), d = try fixture.open(key: "d")
            try activate(key: "d")
            try enable()
            try expectShown(d)
            try expectShown(d, since: key(3, send: true))
            try expectShown(b, since: key(1))
            try expectShown(a, since: post(40))
            try fixture.command("close", ["key": "a"])
            try expectShown(b)
            let start = monotonicSeconds()
            try fixture.command("tab", ["key": "d"])
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                try shown(d) && statusItemShows(3)
            })
            #expect(try harness.status().workspaces?.active == 3)
        }

        @Test func e29RecoveryWaitsForTheFirstSuccessfulAXEnumeration() throws {
            let (a,b) = try split()
            try #require(try eventually { try !visible(b) })
            kill(harness.appPID, SIGKILL)
            try #require(eventually { !harness.appIsRunning })
            try writeConfig("")
            kill(fixture.pid, SIGSTOP)
            do {
                defer { kill(fixture.pid, SIGCONT) }
                try harness.startApp(fixtureReady: false)
                sleep(seconds: 0.5)
                guard let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                    throw HarnessError("cannot read on-screen visibility during the blocked AX read")
                }
                let orphanVisible = listed.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == b }
                #expect(!orphanVisible, "recovery must wait for a successful AX enumeration")
            }
            // The ordinary crash test enforces the one-second restart deadline.
            // This failure-path test deliberately suspends AX; time from resume.
            try #require(try eventually(within: 1) {
                try harness.row(b) != nil && visible(a) && visible(b)
            })
        }

        @Test func e19OnePointShortReadbackRemainsTiled() throws {
            let a = try fixture.open()
            try activate()
            let area = try observe().area
            try fixture.command("limitHeight", ["height": area[3] - 21])
            try enable()
            try expectShown(a)
            #expect(try harness.row(a)?.state == "tiled")
            #expect(abs(try #require(try window(a)).frame[3] - (area[3] - 21)) <= 0.5)
        }

        @Test func e22OversizedGapKeepsTheConstrainedWindowCenteredOnDisplay() throws {
            let a = try fixture.open()
            try activate()
            try enable("[gaps]\nouter = 10000\n")
            _ = try expectState(a, "floats", "cannot fill the screen")
            let observation = try observe(), window = try #require(observation.windows.first { $0.id == a })
            #expect(abs(window.frame[0] + window.frame[2] / 2 - (observation.area[0] + observation.area[2] / 2)) <= 1)
            #expect(abs(window.frame[1] + window.frame[3] / 2 - (observation.area[1] + observation.area[3] / 2)) <= 1)
        }

        @Test func e20ConstrainedWindowFloatsAboveTheWorkspacesTile() throws {
            let tile = try fixture.open(key: "tile")
            try activate(key: "tile")
            try enable()
            try expectShown(tile)
            let limited = try fixture.open(kind: "maxWidth", key: "limited")
            try expectShown(limited, floating: true)
            _ = try expectState(limited, "floats", "cannot fill the screen")
            #expect(try eventually { try visible(tile) })
            #expect(try #require(try window(limited)).order < #require(try window(tile)).order)
        }

        @Test func e22GapReloadRelayoutsOnlyTheVisibleWindowUntilSwitch() throws {
            let (a,b) = try split()
            let before = try #require(try window(b)).frame
            let start = monotonicSeconds()
            try enable("[gaps]\nouter = 20\n")
            try expectShown(a, since: start, within: 1, gap: 20)
            #expect(try window(b)?.frame == before)
            try expectShown(b, since: key(2), gap: 20)
        }

        @Test func e23DialogsBelongToTheActiveWorkspaceAndKeepTheirFrames() throws {
            let (_,b) = try split()
            try expectShown(b, since: key(2))
            let d = try fixture.open(kind: "dialog", key: "dialog")
            try expectShown(d, floating: true)
            let frame = try #require(try window(d)).frame
            #expect(try harness.row(d)?.workspace == 2)
            try key(1)
            try #require(try eventually(within: budget) { try !visible(d) })
            try expectShown(d, since: key(2), floating: true)
            #expect(try window(d)?.frame == frame)
        }

        @Test func e24ASheetAlwaysSharesItsParentsVisibilityAndWorkspace() throws {
            let sheet = try fixture.open(kind: "sheet", key: "sheet")
            let parent = try #require(try fixture.command("ping").windows["sheetParent"])
            try activate(key: "sheetParent")
            try enable()
            try #require(try eventually { try visible(sheet) })
            let b = try fixture.open(key: "b")
            try expectShown(b)
            try expectShown(b, since: key(2, send: true))
            #expect(try !visible(sheet))
            #expect(try !visible(parent))
            try key(1)
            try #require(try eventually(within: budget) { try visible(parent) && visible(sheet) })
            #expect(try harness.row(sheet)?.workspace == harness.row(parent)?.workspace)
            try #require(try eventually { try window(sheet)?.focused == true })
            let sent = try key(3, send: true)
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - sent))) {
                try harness.row(parent)?.workspace == 3 && harness.row(sheet)?.workspace == 3
                    && shown(parent) && visible(sheet)
            }, "sending while a sheet is focused must move its parent and sheet together")
        }

        @Test(arguments: [false, true])
        func e25MinimizeSelectsRecentWindowOrDesktopAndRestoreReturnsToWorkspace(last: Bool) throws {
            let b = last ? nil : try fixture.open(key: "b")
            let a = try fixture.open(key: "a")
            try activate(key: "a")
            try enable()
            try expectShown(a)
            try fixture.command("minimize", ["key": "a"])
            let start = monotonicSeconds()
            if let b { try expectShown(b, since: start) } else { try expectEmpty(since: start) }
            #expect(try harness.row(a)?.workspace == 1)
            #expect(try harness.row(a)?.state == "minimized")
            try fixture.command("restore", ["key": "a"])
            try expectShown(a, since: monotonicSeconds())
            #expect(try harness.status().workspaces?.active == 1)
        }

        @Test func e25RestoringFromAnotherWorkspaceReturnsToTheMinimizedWindowsWorkspace() throws {
            let (a,b) = try split()
            try expectShown(b, since: key(2))
            try fixture.command("minimize", ["key": "b"])
            try expectEmpty(since: monotonicSeconds())
            let c = try fixture.open(key: "c")
            try activate(key: "c")
            try expectShown(c)
            let sent = try key(1, send: true)
            try #require(try eventually(within: budget - (monotonicSeconds() - sent)) { try statusItemShows(1) })
            #expect(try harness.status().workspaces?.active == 1)
            try fixture.command("restore", ["key": "b"])
            try #require(try eventually(within: budget) {
                try shown(b) && statusItemShows(2)
            })
            #expect(try harness.status().workspaces?.active == 2)
            #expect(try harness.row(b)?.workspace == 2)
            #expect(try !visible(a))
        }

        @Test(arguments: [false, true])
        func e26HideSelectsRecentWindowOrDesktopAndReactivationReturnsToItsWorkspace(last: Bool) throws {
            let b = last ? nil : try fixture.open(key: "b")
            let x = try other(), a = try x.open()
            try activate(x)
            try enable()
            try expectShown(a)
            try x.command("hide")
            if let b { try expectShown(b, since: monotonicSeconds()) } else { try expectEmpty(since: monotonicSeconds()) }
            #expect(try harness.row(a)?.workspace == 1)
            try yieldActivation(to: x)
            let start = monotonicSeconds()
            try x.command("activate", ["key": "activationOnly"])
            try expectShown(a, since: start)
        }

        @Test func e27NativeFullscreenHasNoWorkspaceAndIsNeverHiddenOrResized() throws {
            let a = try fixture.open()
            try activate()
            try enable()
            try expectShown(a)
            try fixture.command("fullscreen")
            #expect(try window(a)?.nativeFullscreen == true)
            try expectState(a, "fullscreen")
            #expect(try harness.row(a)?.workspace == nil)
            let payload = try JSONSerialization.jsonObject(with: harness.invoke("windows", "--json").outputData) as? [[String: Any]]
            let explicitNull = payload?.first { ($0["id"] as? UInt32) == a }?["workspace"] is NSNull
            #expect(explicitNull)
            let frame = try #require(try window(a)).frame
            sleep(seconds: budget)
            #expect(try window(a)?.frame == frame)
            #expect(try visible(a))
            try fixture.command("fullscreen")
            try expectShown(a)
            #expect(try harness.row(a)?.workspace == 1)
        }

        @Test func e27FullscreenLeavesItsClosetedSiblingAloneAndCannotSendIt() throws {
            let b = try fixture.open(key: "b"), a = try fixture.open(key: "a")
            try activate(key: "a")
            try enable()
            try expectShown(a)
            try fixture.command("fullscreen", ["key": "a"])
            defer {
                if (try? window(a)?.nativeFullscreen) == true { _ = try? fixture.command("fullscreen", ["key": "a"]) }
            }
            _ = try expectState(a, "fullscreen")
            try #require(try eventually { try window(a).map { $0.visible && $0.focused } == true })
            #expect(try !visible(b))
            try key(2, send: true)
            sleep(seconds: budget)
            #expect(try harness.status().workspaces?.active == 1)
            #expect(try harness.row(b)?.workspace == 1)
            #expect(try window(a)?.nativeFullscreen == true)
            #expect(try window(a)?.focused == true)
            try fixture.command("fullscreen", ["key": "a"])
            try expectShown(a)
        }

        @Test func e26UnhideUsesTheAppsFocusedWindowAcrossWorkspaces() throws {
            let x = try other(), a = try x.open(key: "a"), b = try x.open(key: "b")
            try activate(x, key: "b")
            try enable()
            try expectShown(b)
            try expectShown(b, since: key(3, send: true))
            try expectShown(a, since: key(1))
            try x.command("hide")
            try expectEmpty(since: monotonicSeconds())
            try #require(try eventually {
                try harness.row(a)?.state == "hidden" && harness.row(a)?.workspace == 1
                    && harness.row(b)?.state == "hidden" && harness.row(b)?.workspace == 3
            }, "hiding an app must retain every window's workspace")
            let c = try fixture.open(key: "c")
            try activate(key: "c")
            try expectShown(c)
            try expectShown(c, since: key(2, send: true))
            try yieldActivation(to: x)
            let start = monotonicSeconds()
            try x.command("activate", ["key": "activationOnly"])
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                try shown(a) && statusItemShows(1)
            })
            #expect(try harness.status().workspaces?.active == 1)
            #expect(try !visible(b))
            #expect(try harness.row(b)?.workspace == 3)
        }

        @Test func e33GapNumbersFollowTOMLGrammarWithTheFlagOff() throws {
            for (literal, expected) in [("0x14", 20.0), ("0o24", 20.0), ("0b10100", 20.0), ("1_0.5", 10.5), ("+2e1", 20.0)] {
                let revision = try harness.status().config.revision
                try writeConfig("[gaps]\nouter = \(literal)\n")
                try #require(try eventually(within: 1) { try harness.status().config.revision > revision })
                #expect(try harness.status().workspaces?.gaps.outer == expected)
                #expect(try harness.status().workspaces?.enabled == false)
            }
            for literal in [".1", "1.", "01", "1__0", "inf", "nan", "9223372036854775808"] {
                let before = try harness.status().config.revision
                try writeConfig("[gaps]\nouter = 20 # before \(literal)\n")
                try #require(try eventually(within: 1) { try harness.status().config.revision > before })
                let revision = try harness.status().config.revision
                try writeConfig("[gaps]\nouter = \(literal)\n")
                try #require(try eventually(within: 1) { try harness.status().config.error?.line == 2 })
                #expect(try harness.status().config.revision == revision)
                #expect(try harness.status().workspaces?.gaps.outer == 20)
            }
        }

        @Test(arguments: [false, true])
        func e28DisableOrQuitReturnsAllWindowsAndUnregistersHotkeys(quit: Bool) throws {
            let (a,b) = try split()
            let start = monotonicSeconds()
            if quit { harness.stopApp() } else { try writeConfig("[experiments]\nworkspaces = false\n") }
            try #require(try eventually(within: max(0, 1 - (monotonicSeconds() - start))) {
                try visible(a) && visible(b)
            })
            try activate(key: "a")
            let count = try fixture.command("ping").keyCount ?? 0
            try key(1)
            #expect(try eventually { try fixture.command("ping").keyCount == count + 1 })
            if quit {
                let result = try harness.invoke("status", "--json")
                #expect(result.status != 0 && result.error.contains("tessel is not running"))
                try writeConfig("")
                try harness.startApp()
            } else { #expect(try harness.status().workspaces?.enabled == false) }
        }

        @Test(arguments: [false, true])
        func e29CrashRecoveryReturnsOrphansWithExperimentOnOrOff(on: Bool) throws {
            let (a,b) = try split()
            kill(harness.appPID, SIGKILL)
            try #require(eventually(within: 2) { !harness.appIsRunning })
            if !on { try writeConfig("") }
            let start = monotonicSeconds()
            try harness.startApp(fixtureReady: false)
            if on {
                try #require(try eventually(within: max(0, 1 - (monotonicSeconds() - start))) {
                    let rows = try harness.rows()
                    return rows.filter { [a,b].contains($0.id) }.count == 2 && rows.allSatisfy { $0.workspace == 1 }
                })
                let current = try #require(try eventualValue { try observe().windows.first { $0.main && $0.visible }?.id })
                try expectShown(current == a ? b : a, since: post(38))
            } else {
                #expect(try eventually(within: max(0, 1 - (monotonicSeconds() - start))) {
                    try visible(a) && visible(b)
                })
            }
        }

        @Test func e30HungAppDoesNotBlockSwitchingOrCLI() throws {
            let (a,b) = try split()
            let hung = try other(), h = try hung.open()
            try activate(hung)
            try expectShown(h)
            try activate(key: "a")
            try expectShown(a)
            try hung.command("hang")
            let start = try key(2)
            try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                let observation = try observe([fixture])
                return observation.windows.first { $0.id == b }.map { $0.visible && $0.main && $0.focused && filled($0, area: observation.area) } == true
            })
            let query = monotonicSeconds()
            #expect(try harness.row(h) != nil)
            #expect(monotonicSeconds() - query < 1)
        }

        @Test func e31StatusListsAllDefaultShortcuts() throws {
            var windows = [try fixture.open(key: "digit1")]
            try activate(key: "digit1")
            try enable()
            try expectShown(windows[0])
            let keys = try #require(try harness.status().workspaces).keys
            #expect(keys.count == 22)
            for number in 1...10 {
                let digit = number == 10 ? 0 : number
                #expect(keys["alt-\(digit)"] == "workspace \(number)")
                #expect(keys["alt-shift-\(digit)"] == "send \(number)")
            }
            #expect(keys["alt-j"] == "focus next")
            #expect(keys["alt-k"] == "focus previous")
            for number in 2...10 {
                let window = try fixture.open(key: "digit\(number)")
                windows.append(window)
                try expectShown(window)
                let start = try key(number, send: true)
                try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                    try shown(window) && statusItemShows(number)
                })
                #expect(try harness.status().workspaces?.active == number)
                #expect(try harness.row(window)?.workspace == number)
            }
            for number in 1...10 {
                let start = try key(number)
                try #require(try eventually(within: max(0, budget - (monotonicSeconds() - start))) {
                    try shown(windows[number - 1]) && statusItemShows(number)
                })
                #expect(try harness.status().workspaces?.active == number)
            }
        }

        @Test func e32CustomModifiersReachTheRegisteredCommand() throws {
            let (_,b) = try split()
            try enable("[keys]\nctrl-alt-shift-cmd-g = \"workspace 2\"\n")
            let start = try #require(try harness.observer.command("hotkey", ["code": 5, "modifiers": ["alt","shift","ctrl","cmd"]]).postedAt)
            try expectShown(b, since: start)
            #expect(try harness.status().workspaces?.active == 2)
        }

        @Test func e32EveryANSILetterCanBindARealHotkey() throws {
            let (a,b) = try split()
            let letters = [
                ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F),
                ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
                ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R),
                ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
                ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z)
            ]
            for (letter, code) in letters {
                try enable("[keys]\nalt-\(letter) = \"workspace 2\"\n")
                try expectShown(b, since: post(code))
                try expectShown(a, since: key(1))
            }
        }

        @Test func e32OverridesMergeWithDefaultsAndEmptyBindingPassesThrough() throws {
            let (a,b) = try split()
            try enable("[keys]\nalt-1 = \"workspace 2\"\nalt-2 = \"\"\n")
            let count = try fixture.command("ping").keyCount ?? 0
            try key(2)
            #expect(try eventually { try fixture.command("ping").keyCount == count + 1 })
            #expect(try shown(a))
            try expectShown(b, since: key(1))
            #expect(try harness.status().workspaces?.keys["alt-j"] == "focus next")
        }

        nonisolated static let invalidWorkspaceConfigurations = [
            ("[keys]\nalt-1 = \"workspace 2\"\nalt-1 = \"workspace 3\"\n", 5),
            ("[keys]\nalt-1 = \"unknown\"\n", 4),
            ("[keys]\nalt-1 = \"workspace 11\"\n", 4),
            ("[keys]\ninvalid-1 = \"workspace 1\"\n", 4),
            ("[gaps]\nouter = -1\n", 4),
            ("[keys]\nalt-shift-1 = \"send 2\"\nshift-alt-1 = \"send 3\"\n", 5)
        ]
        @Test(arguments: [true, false], invalidWorkspaceConfigurations)
        func e33InvalidConfigurationReportsItsLineAndKeepsWorkingBindings(on: Bool, invalid: (String, Int)) throws {
            let (text, line) = invalid
            let b: UInt32?
            if on {
                b = try split().1
                try enable("[keys]\nalt-1 = \"workspace 2\"\n")
            } else {
                b = nil
                let revision = try harness.status().config.revision
                try writeConfig("[keys]\nalt-1 = \"workspace 2\"\n")
                try #require(try eventually(within: 1) { try harness.status().config.revision > revision })
            }
            let revision = try harness.status().config.revision
            try writeConfig("[experiments]\nworkspaces = \(on)\n" + text)
            try #require(try eventually(within: 1) { try harness.status().config.error?.line == line })
            #expect(try harness.status().config.revision == revision)
            #expect(try harness.status().workspaces?.keys["alt-1"] == "workspace 2")
            if let b { try expectShown(b, since: key(1)) }
            else { #expect(try harness.status().workspaces?.enabled == false) }
        }

        @Test func e34MissingSkyLightDisablesWithoutMovingWindowsOrTakingKeys() throws {
            harness.stopApp()
            let a = try fixture.open()
            try activate()
            let frame = try #require(try window(a)).frame
            try writeConfig(enabled)
            try harness.startApp(fixtureReady: false, arguments: ["--test-missing-skylight"])
            let status = try #require(try harness.status().workspaces)
            #expect(!status.enabled)
            #expect(status.reason.lowercased().contains("skylight"))
            #expect(try window(a)?.frame == frame)
            #expect(try visible(a))
            let count = try fixture.command("ping").keyCount ?? 0
            try key(1)
            #expect(try eventually { try fixture.command("ping").keyCount == count + 1 })
            try harness.observer.command("menu", ["pid": harness.appPID, "expected": status.reason, "open": true, "keepOpen": true])
            #expect(try eventually(within: 1) {
                try harness.observer.command("menu", ["pid": harness.appPID, "expected": status.reason, "open": true, "press": false, "keepOpen": true]).menuContains == true
            })
            harness.stopApp()
            try writeConfig("")
            try harness.startApp()
        }

        @Test func e34FailedHideReturnsAllWindowsAndReleasesHotkeys() throws {
            harness.stopApp()
            let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
            try activate(key: "b")
            try writeConfig(enabled)
            let start = monotonicSeconds()
            try harness.startApp(fixtureReady: false, arguments: ["--test-failed-hide"])
            try #require(try eventually(within: max(0, 1 - (monotonicSeconds() - start))) {
                try harness.status().workspaces?.enabled == false
                    && harness.status().workspaces?.reason == "SkyLight could not hide a window"
                    && visible(a) && visible(b)
            })
            try activate(key: "b")
            let count = try fixture.command("ping").keyCount ?? 0
            try key(1)
            #expect(try eventually { try fixture.command("ping").keyCount == count + 1 })
            harness.stopApp()
            try writeConfig("")
            try harness.startApp()
        }

        @Test func e34TestArgumentsRequireFixtureModeAndAreRejectedByTheDailyBuild() throws {
            for argument in ["--test-missing-skylight", "--test-failed-hide", "--test-capture-ui"] {
                #expect(try run([appExecutable.path, "--check-permission", argument]).status == 2)
            }
            #expect(try run([appExecutable.path, "--check-permission", "--test-fixture-only", "--test-unknown"]).status == 2)
            let output = root.appending(path: ".work/daily-argument-check")
            defer { try? FileManager.default.removeItem(at: output) }
            try run([buildTool.path, "--variant", "daily", "--output-dir", output.path], timeout: 180, check: true)
            let executable = output.appending(path: "Tessel.app/Contents/MacOS/TesselApp")
            for argument in ["--test-fixture-only", "--test-missing-skylight", "--test-failed-hide", "--test-capture-ui"] {
                // --check-permission exits before NSApplication starts, even if
                // a regression incorrectly accepts a development argument.
                #expect(try run([executable.path, "--check-permission", argument]).status == 2)
            }
        }

        @Test func e35CLIReportsWorkspaceVisibilityAndNeverTitles() throws {
            let (a,b) = try split()
            let rows = try harness.rows()
            #expect(rows.first { $0.id == a }?.workspace == 1)
            #expect(rows.first { $0.id == a }?.visible == true)
            #expect(rows.first { $0.id == b }?.workspace == 2)
            #expect(rows.first { $0.id == b }?.visible == false)
            let status = try #require(try harness.status().workspaces)
            #expect(status.active == 1)
            #expect(status.gaps.outer == 10)
            #expect(!status.keys.isEmpty)
            #expect(status.enabled)
        }

        @Test func switchLatencyCalibrationMeasuresTwentyCompletedSwitches() throws {
            let (a,b) = try split()
            var nanoseconds: [UInt64] = []
            for index in 0..<20 {
                let start = try key(index.isMultiple(of: 2) ? 2 : 1)
                try expectShown(index.isMultiple(of: 2) ? b : a, since: start)
                nanoseconds.append(UInt64((monotonicSeconds() - start) * 1e9))
            }
            let maximum = nanoseconds.max()!
            #expect(maximum <= 200_000_000)
            let result: [String: Any] = ["measurements": nanoseconds, "nanoseconds": min(200_000_000, maximum * 3),
                "sourceRun": ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? "local"]
            let path = root.appending(path: ".work/switch-calibration.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path)
            print("Switch calibration: maximum \(Double(maximum) / 1e6) ms across 20 switches")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_WORKSPACES"] == "1", "local E37 visual capture"))
        func captureWorkspaceMenuForOwnerReview() throws {
            let (a,b) = try split()
            let directory = root.appending(path: ".work/captures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func capture(_ name: String, open: Bool = false, expected: String) throws {
                let reply = try harness.observer.command("menu", ["pid": harness.appPID, "expected": expected, "open": open, "keepOpen": true])
                if open {
                    try #require(try eventually(within: 1) {
                        try harness.observer.command("menu", ["pid": harness.appPID, "expected": expected, "open": true, "press": false, "keepOpen": true]).menuContains == true
                    })
                } else { try #require(reply.menuContains == true) }
                let source = harness.configFile.deletingLastPathComponent().appending(path: "ui-captures/" + name + ".png")
                let destination = directory.appending(path: name + ".png")
                let png = try #require(eventualValue(within: 1) { () -> Data? in
                    guard let data = FileManager.default.contents(atPath: source.path),
                          data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else { return nil }
                    return data
                }, "the running development app must export its own rendered view")
                try png.write(to: destination, options: .atomic)
            }
            try expectShown(a)
            try capture("E37-workspace-1", expected: "Workspace 1")
            try expectShown(b, since: key(2))
            try capture("E37-workspace-2", expected: "Workspace 2")
            try writeConfig("")
            try #require(try eventually(within: 1) { try harness.status().workspaces?.enabled == false })
            try capture("E37-disabled-menu", open: true, expected: "experiment off")
            harness.stopApp()
            try harness.startApp()
        }
    }
}
