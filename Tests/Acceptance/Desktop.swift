import Darwin
import Foundation

/// Real keyboard input and independent observations, shared by journeys and latency.
@MainActor
struct Desktop {
    var harness: Harness { Harness.shared }
    var fixture: FixtureSession { harness.fixture }
    let carousel = ""

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: harness.configFile)
    }

    func configure(_ text: String, layout: String) throws {
        let revision = try harness.status().config.revision
        try writeConfig(text)
        try requireFinalState("the saved configuration and \(layout) layout") {
            let status = try harness.status()
            return status.config.revision > revision && status.config.state == "loaded"
                && status.workspaces?.enabled == true && status.workspaces?.layout == layout
        }
    }

    func observe(focusedOnly: Bool = false, expectedPID: pid_t? = nil) throws -> Observation {
        var arguments: [String: Any] = ["pids": ([fixture] + harness.otherFixtures).map(\.pid), "focusedOnly": focusedOnly]
        if let expectedPID { arguments["expectedPID"] = expectedPID }
        guard let observation = try harness.observer.command("observe", arguments).observation else {
            throw HarnessError("the independent observer did not return a fixture observation")
        }
        return observation
    }

    func window(_ id: UInt32) throws -> Observation.Window? {
        try observe().windows.first { $0.id == id }
    }

    func visible(_ id: UInt32) throws -> Bool {
        try observe(focusedOnly: true).visibleIDs.contains(id)
    }

    func near(_ actual: [Double], _ expected: [Double]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 }
    }

    func focused(_ id: UInt32, in observation: Observation) -> Bool {
        observation.visibleIDs.contains(id) && observation.windows.contains { window in
            window.id == id && window.visible && window.main
                && (window.focused || observation.windows.contains { $0.parent == id && $0.focused })
        }
    }

    func shown(_ id: UInt32, in observation: Observation, gap: Double = 10) -> Bool {
        let area = observation.area
        let expected = [area[0] + gap, area[1] + gap, area[2] - gap * 2, area[3] - gap * 2]
        return focused(id, in: observation) && observation.windows.contains { $0.id == id && near($0.frame, expected) }
    }

    func expectShown(_ id: UInt32, gap: Double = 10) throws {
        // A timeout names the last observation so a CI-only failure is diagnosable.
        var last = "no observation"
        do {
            try requireFinalState("fixture \(id) visible, filled and focused") {
                let observation = try observe(focusedOnly: true)
                let window = observation.windows.first { $0.id == id }
                last = "area \(observation.area), " + (window.map { "frame \($0.frame), visible \($0.visible), main \($0.main), focused \($0.focused)" } ?? "window absent")
                return shown(id, in: observation, gap: gap)
            }
        } catch {
            let foreground = (try? harness.observer.command("contract", ["operation": "foreground"]).contract?.foreground)?.joined(separator: ", ") ?? "unknown"
            throw HarnessError("\(error); last observation: \(last); foreground: \(foreground)")
        }
    }

    func expectFocus(_ id: UInt32) throws {
        try requireFinalState("fixture \(id) visible, main and focused") {
            try focused(id, in: observe(focusedOnly: true))
        }
    }

    @discardableResult
    func post(_ code: Int, shift: Bool = false, modifiers: [String]? = nil) throws -> Double {
        var arguments: [String: Any] = ["code": code, "shift": shift]
        if let modifiers { arguments["modifiers"] = modifiers }
        guard let posted = try harness.observer.command("hotkey", arguments).postedAt else {
            throw HarnessError("the trusted fixture did not confirm the key post")
        }
        return posted
    }

    @discardableResult
    func key(_ number: Int, send: Bool = false) throws -> Double {
        let codes = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 10: 29]
        guard let code = codes[number] else { throw HarnessError("invalid fixture workspace number") }
        return try post(code, shift: send)
    }

    func activate(_ session: FixtureSession? = nil, key: String = "window") throws {
        let session = session ?? fixture
        let observation = try observe()
        let front = observation.activeFixturePID != 0 ? observation.activeFixturePID : observation.frontmostFixturePID
        if front != session.pid, let source = ([fixture] + harness.otherFixtures).first(where: { $0.pid == front }) {
            try source.command("yieldActivation", ["pid": session.pid])
        }
        try session.command("activate", ["key": key])
        let windows = try session.command("ping").windows
        var arguments: [String: Any] = ["pid": session.pid]
        if let id = windows[key] { arguments["id"] = id }
        try harness.observer.command("activateFixture", arguments)
        try requireFinalState("the target fixture frontmost") {
            let observation = try observe()
            return observation.activeFixturePID == session.pid && observation.frontmostFixturePID == session.pid
                && (windows[key].map { focused($0, in: observation) } ?? true)
        }
    }

    func expectPassedKey(_ code: Int, shift: Bool = false) throws {
        let count = try fixture.command("ping").keyCount ?? 0
        try post(code, shift: shift)
        try requireFinalState("an unregistered key delivered to the fixture") {
            try fixture.command("ping").keyCount == count + 1
        }
    }

    func expectMenu(_ expected: String, open: Bool = false, pid: pid_t? = nil) throws {
        let pid = pid ?? harness.appPID
        if open {
            try harness.observer.command("menu", ["pid": pid, "open": true, "keepOpen": true])
        }
        defer {
            if open { _ = try? harness.observer.command("menu", ["pid": pid, "open": true, "press": false]) }
        }
        try requireFinalState("the development status item or menu label") {
            try harness.observer.command("menu", ["pid": pid, "open": open, "press": false,
                "keepOpen": true, "expected": expected, "suffix": !open]).menuContains == true
        }
    }

    func expectInside(_ ids: [UInt32]) throws {
        try requireFinalState("every managed fixture returned inside the visible desktop") {
            let observation = try observe()
            return ids.allSatisfy { id in
                observation.windows.contains { window in
                    window.id == id && observation.visibleIDs.contains(id) && window.visible
                        && window.frame[0] >= observation.area[0] - 1 && window.frame[1] >= observation.area[1] - 1
                        && window.frame[0] + window.frame[2] <= observation.area[0] + observation.area[2] + 1
                        && window.frame[1] + window.frame[3] <= observation.area[1] + observation.area[3] + 1
                }
            }
        }
    }

    func clear() throws {
        try harness.reset()
        try requireFinalState("the fixture catalog emptied") { try harness.rows().isEmpty }
    }

    func split() throws -> (UInt32, UInt32) {
        harness.stopApp()
        let a = try fixture.open(key: "a", ["widthFraction": 1.0]), b = try fixture.open(key: "b", ["widthFraction": 1.0])
        try activate(key: "b")
        try writeConfig("[animation]\nduration = 0\n")
        try harness.startApp(fixtureReady: false)
        try requireFinalState("both workspace setup fixtures listed") {
            Set(try harness.rows().map(\.id)) == Set([a, b])
        }
        try expectShown(b)
        try key(2, send: true)
        try expectShown(b)
        try requireFinalState("the sent fixture in workspace 2") {
            try harness.row(b)?.workspace == 2 && harness.status().workspaces?.active == 2
        }
        try key(1)
        try expectShown(a)
        return (a, b)
    }

    func railSetup(_ widths: [Double] = Array(repeating: 0.45, count: 5), firstIn firstSession: FixtureSession? = nil, duration: Int = 80, configuration: String = "") throws -> [UInt32] {
        harness.stopApp()
        let ids = try widths.enumerated().map { index, width in
            let session = index == 0 ? firstSession ?? fixture : fixture
            return try session.open(key: "w\(index)", ["widthFraction": width])
        }
        try activate(firstSession, key: "w0")
        try writeConfig(configuration + "[animation]\nduration = \(duration)\n")
        try harness.startApp(fixtureReady: false)
        try requireFinalState("every rail setup window listed") { Set(try harness.rows().map(\.id)) == Set(ids) }
        // The focused first window keeps its width at the rail's left end.
        var last = "no observation"
        do {
            try requireFinalState("fixture \(ids[0]) focused at the rail's left end") {
                let observation = try observe(focusedOnly: true), area = observation.area
                last = "area \(area), " + observation.windows.map { "\($0.id): \($0.frame) visible \($0.visible) focused \($0.focused)" }.joined(separator: "; ")
                return focused(ids[0], in: observation) && observation.windows.contains {
                    $0.id == ids[0] && abs($0.frame[0] - (area[0] + 10)) <= 1 && abs($0.frame[3] - (area[3] - 20)) <= 1
                }
            }
        } catch { throw HarnessError("\(error); last observation: \(last)") }
        try requireFinalState("initial rail sizing and membership") {
            let observation = try observe(), rows = try harness.rows()
            return ids.enumerated().allSatisfy { index, id in
                rows.contains { $0.id == id && $0.rail == 1 && $0.slot == index + 1 }
                    // Hidden tiles defer sizing until their next on-screen reveal.
                    && (!observation.visibleIDs.contains(id) || observation.windows.contains {
                        $0.id == id && abs($0.frame[3] - (observation.area[3] - 20)) <= 1
                    })
            }
        }
        return ids
    }
}
