import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_MAP"] == "1", "owner review of the rails map"))
    @MainActor struct MapCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        enum Scene: String, CaseIterable {
            case longRail = "long-rail", threeRails = "three-rails", floats, crowded, wall, workspace
            var presets: [[Double]] {
                switch self {
                case .longRail, .wall: [[0.5, 2.0 / 3, 1.0 / 3, 0.5, 2.0 / 3, 1.0 / 3]]
                case .threeRails: [[0.5, 0.5, 2.0 / 3], [1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 0.5], [1]]
                case .floats: [[2.0 / 3, 0.5, 1.0 / 3], [1]]
                case .crowded: [[0.5, 0.5, 2.0 / 3, 1.0 / 3],
                                [1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 0.5, 1.0 / 3, 2.0 / 3],
                                [1.0 / 3, 1.0 / 3, 2.0 / 3, 0.5, 0.5, 1.0 / 3, 0.5, 1.0 / 3, 2.0 / 3],
                                [1], [0.5, 0.5, 1.0 / 3]]
                case .workspace: [[1, 1]]
                }
            }
            var remembered: [Int] {
                switch self {
                case .longRail: [3]
                case .threeRails: [1, 2, 0]
                case .floats: [1, 0]
                case .crowded: [0, 4, 5, 0, 1]
                case .wall, .workspace: [0]
                }
            }
            var current: Int { self == .threeRails ? 1 : self == .crowded ? 2 : 0 }
            var floats: Int { self == .floats ? 3 : self == .crowded ? 2 : 0 }
        }

        @Test("#18 E28: the running map exports the six accepted views in light and dark", arguments: Scene.allCases)
        func captureRailsMap(_ scene: Scene) throws {
            try desktop.clear()
            harness.stopApp()
            let visible = try #require(try harness.observer.command("contract", ["operation": "screen", "pid": fixture.pid]).contract?.axVisibleFrame)
            let area = [visible[0] + 10, visible[1] + 10, visible[2] - 20, visible[3] - 20]
            var index = 0
            let rails = try scene.presets.map { presets in
                try presets.map { preset in
                    let key = "map\(index)"; index += 1
                    let id = try fixture.open(key: key, ["title": "Invented map window \(index)"])
                    try fixture.command("move", ["key": key, "frame": [area[0], area[1], preset * (area[2] + 10) - 10, area[3]]])
                    return id
                }
            }
            for i in 0..<scene.floats { _ = try fixture.open(kind: "panel", key: "float\(i)", ["background": true]) }
            try desktop.activate(key: "map0")
            try desktop.writeConfig(configuration(animation: 0))
            try harness.startApp(fixtureReady: false)
            try requireFinalState("all map capture fixtures catalogued") { try harness.rows().count == index + scene.floats }
            try desktop.expectFocus(rails[0][0])
            for r in rails.indices.dropFirst() {
                for id in rails[r] {
                    try focus(id)
                    for destination in 2...(r + 1) {
                        try press(kVK_ANSI_J, shift: true)
                        try requireFinalState("the capture tile moved into rail \(destination)") { try harness.row(id)?.rail == destination }
                        try desktop.expectFocus(id)
                    }
                }
            }
            for r in rails.indices {
                try focus(rails[r][0])
                try focus(rails[r][scene.remembered[r]])
            }
            try reachRail(scene.current + 1)
            try desktop.expectFocus(rails[scene.current][scene.remembered[scene.current]])
            if scene == .floats {
                // The prototype starts with the third float most recently used.
                // Untouched native floats enter at the first arrival instead.
                for code in [kVK_ANSI_Z, kVK_ANSI_L, kVK_ANSI_L, kVK_ANSI_Z] { try press(code) }
                try desktop.expectFocus(rails[scene.current][scene.remembered[scene.current]])
            }
            if scene == .wall {
                try press(kVK_ANSI_H)
            } else if scene == .workspace {
                try desktop.key(2, send: true)
                try desktop.expectFocus(rails[0][0])
                try desktop.key(1)
                try desktop.expectFocus(rails[0][1])
                try desktop.key(2)
                try desktop.expectFocus(rails[0][0])
            } else {
                try desktop.configure(configuration(animation: 250), layout: "carousel")
                if scene == .floats {
                    try press(kVK_ANSI_Z)
                    try press(kVK_ANSI_L)
                    try press(kVK_ANSI_L)
                } else if scene == .longRail {
                    try press(kVK_ANSI_L)
                } else {
                    // A wall-free vertical return shows the prepared scene.
                    try reachRail(scene.current == 0 ? 2 : scene.current)
                    try reachRail(scene.current + 1)
                }
            }
            let show = try harness.mapState().shows
            let directory = root.appending(path: ".work/captures/rails-map")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearance in ["light", "dark"] {
                let source = harness.configFile.deletingLastPathComponent().appending(path: "ui-captures/E28-map-\(show)-\(appearance).png")
                let data = try #require(finalValue { () -> Data? in
                    guard let png = FileManager.default.contents(atPath: source.path),
                          png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { return nil }
                    return png
                }, "the signed app must export its own map view")
                try data.write(to: directory.appending(path: "\(scene.rawValue)-\(appearance).png"), options: .atomic)
            }
            print("#18 E28 \(scene.rawValue): \(directory.path) — pending owner review")
        }

        private func configuration(animation: Int) -> String {
            "[experiments]\nmap = true\n[map]\nduration = 5000\n[animation]\nduration = \(animation)\n"
        }

        private func press(_ code: Int, shift: Bool = false) throws {
            let before = try harness.mapState().shows
            try desktop.post(code, shift: shift)
            try requireFinalState("the capture command executed") { try harness.mapState().shows > before }
        }

        private func reachRail(_ target: Int) throws {
            for _ in 0..<10 {
                let current = try #require(try harness.status().workspaces?.rail)
                if current == target { return }
                let next = current + (current < target ? 1 : -1)
                try press(current < target ? kVK_ANSI_J : kVK_ANSI_K)
                try requireFinalState("the capture selected rail \(next)") {
                    let observation = try desktop.observe()
                    guard let focused = observation.windows.first(where: { desktop.focused($0.id, in: observation) }) else { return false }
                    return try harness.status().workspaces?.rail == next && harness.row(focused.id)?.rail == next
                }
            }
            throw HarnessError("capture setup did not reach rail \(target)")
        }

        private func focus(_ id: UInt32) throws {
            let target = try #require(try harness.row(id))
            try reachRail(try #require(target.rail))
            let count = try harness.rows().count
            var trace: [String] = []
            for _ in 0..<(count * 5) {
                let before = try desktop.observe()
                if desktop.focused(id, in: before) { return }
                let selected = try #require(before.windows.first { desktop.focused($0.id, in: before) })
                let selectedRow = try #require(try harness.row(selected.id))
                let slot = try #require(selectedRow.slot)
                trace.append("\(selected.id) r\(selectedRow.rail ?? 0)s\(slot) frame \(selected.frame)")
                try press(slot < (target.slot ?? 1) ? kVK_ANSI_L : kVK_ANSI_H)
                try requireFinalState("the capture focus or stop advanced") {
                    let after = try desktop.observe()
                    return !desktop.focused(selected.id, in: after)
                        || after.windows.first { $0.id == selected.id }?.frame != selected.frame
                }
            }
            throw HarnessError("capture setup did not reach tile \(id) r\(target.rail ?? 0)s\(target.slot ?? 0); trace: \(trace)")
        }
    }
}
