import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Journeys {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        init() throws { try desktop.clear() }

        func step(_ name: String, _ body: () throws -> Void) throws {
            print("Journey step: \(name)")
            fflush(nil)
            do {
                try body()
                print("PASS: \(name)")
            } catch {
                print("FAIL: \(name)")
                throw HarnessError("Journey step \(name): \(error)")
            }
        }

        @Test("enable journey")
        func enable() throws {
            try step("#1 E9 startup discovers existing windows and native tabs") {
                harness.stopApp()
                var expected: [UInt32: String] = [:]
                for kind in ["standard", "noFullscreen", "fixed", "dialog", "panel", "sheet"] {
                    expected[try fixture.open(kind: kind, key: kind)] = ["standard", "noFullscreen"].contains(kind) ? "tiled" : "floats"
                    if kind == "sheet" {
                        expected[try #require(try fixture.command("ping").windows["sheetParent"])] = "tiled"
                    }
                }
                let tabs = try fixture.command("open", ["kind": "tabs", "key": "existingTabs", "count": 3])
                expected[try #require(tabs.windows["existingTabs0"])] = "tiled"
                try harness.startApp(fixtureReady: false)
                try requireFinalState("all preexisting fixture classifications and the native tab group") {
                    let rows = try harness.rows()
                    return Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { $1 }) == expected
                        && rows.filter { $0.tabs == 3 }.count == 1
                }
                let before = try harness.rows()
                harness.stopApp()
                try harness.startApp(fixtureReady: false)
                try requireFinalState("the same fixture records after restart") { try harness.rows() == before }
                harness.stopApp()
                try fixture.command("minimize", ["key": "fixed"])
                try fixture.command("minimize", ["key": "existingTabs0"])
                try fixture.command("hide")
                try harness.startApp(fixtureReady: false)
                let tabIDs = Set(try (0..<3).map { try #require(tabs.windows["existingTabs\($0)"]) })
                let fixed = try #require(try fixture.command("ping").windows["fixed"])
                var states = expected.mapValues { _ in "hidden" }
                for id in tabIDs.union([fixed]) { states[id] = "minimized" }
                try requireFinalState("preexisting minimized and hidden fixtures") {
                    let rows = try harness.rows()
                    return Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { $1 }) == states
                        && rows.filter { tabIDs.contains($0.id) }.map(\.tabs).sorted() == [1, 1, 3]
                }
            }
            try desktop.clear()
            let window = try fixture.open()
            try desktop.activate()
            try step("#2 E1 experiment off leaves frames and ordinary keys alone") {
                let frame = try #require(try desktop.window(window)).frame
                try desktop.expectPassedKey(kVK_ANSI_1)
                try #require(try desktop.window(window)?.frame == frame)
                let status = try #require(try harness.status().workspaces)
                try #require(!status.enabled && status.reason == "experiment off")
            }
            try step("rails off leaves rail hotkeys unregistered") {
                for enabled in [false, true] {
                    if enabled {
                        try desktop.configure(desktop.stack, layout: "stack")
                        try desktop.expectShown(window)
                    }
                    let frame = try #require(try desktop.window(window)).frame
                    for (code, shift) in [(kVK_ANSI_H, false), (kVK_ANSI_L, false), (kVK_ANSI_H, true),
                                          (kVK_ANSI_J, true), (kVK_ANSI_K, true), (kVK_ANSI_L, true)] {
                        try desktop.expectPassedKey(code, shift: shift)
                    }
                    try #require(try desktop.window(window)?.frame == frame)
                }
                try desktop.configure(desktop.stack + "[keys]\nalt-h = 'focus right'\nalt-shift-h = 'move down'\n", layout: "stack")
                let frame = try #require(try desktop.window(window)).frame
                try desktop.expectPassedKey(kVK_ANSI_H)
                try desktop.expectPassedKey(kVK_ANSI_H, shift: true)
                try #require(try desktop.window(window)?.frame == frame)
            }
        }

        @Test("switch journey")
        func switchWorkspaces() throws {
            var windows = [try fixture.open(key: "digit1")]
            try desktop.activate(key: "digit1")
            try desktop.configure(desktop.stack, layout: "stack")
            try desktop.expectShown(windows[0])
            try step("#2 E31 status lists all default shortcuts and each works") {
                let keys = try #require(try harness.status().workspaces).keys
                try #require(keys.count == 22)
                for number in 1...10 {
                    let digit = number == 10 ? 0 : number
                    try #require(keys["alt-\(digit)"] == "workspace \(number)")
                    try #require(keys["alt-shift-\(digit)"] == "send \(number)")
                }
                try #require(keys["alt-j"] == "focus next" && keys["alt-k"] == "focus previous")
                for number in 2...10 {
                    let window = try fixture.open(key: "digit\(number)")
                    windows.append(window)
                    try desktop.expectShown(window)
                    try requireFinalState("the new fixture assigned before sending") { try harness.row(window)?.workspace != nil }
                    try desktop.key(number, send: true)
                    try desktop.expectShown(window)
                    try requireFinalState("the default send binding and workspace status") {
                        try harness.row(window)?.workspace == number && harness.status().workspaces?.active == number
                    }
                }
                try desktop.key(1, send: true)
                try desktop.expectShown(windows[9])
                try requireFinalState("the default send-to-1 binding") {
                    try harness.row(windows[9])?.workspace == 1 && harness.status().workspaces?.active == 1
                }
                try desktop.key(10, send: true)
                try desktop.expectShown(windows[9])
                try requireFinalState("the digit fixture returned to workspace 10") {
                    try harness.row(windows[9])?.workspace == 10 && harness.status().workspaces?.active == 10
                }
                for number in 1...10 {
                    try desktop.key(number)
                    try desktop.expectShown(windows[number - 1])
                    try desktop.expectMenu("Workspace \(number)")
                    try #require(try harness.status().workspaces?.active == number)
                }
                try desktop.key(1)
                try desktop.expectShown(windows[0])
                var cycleWindows: [UInt32] = []
                for key in ["cycle1", "cycle2"] {
                    let sibling = try fixture.open(key: key)
                    cycleWindows.append(sibling)
                    try desktop.expectShown(sibling)
                    try requireFinalState("the cycle fixture assigned") { try harness.row(sibling)?.workspace == 1 }
                }
                try desktop.post(kVK_ANSI_J)
                try desktop.expectShown(windows[0])
                try desktop.post(kVK_ANSI_K)
                try desktop.expectShown(cycleWindows[1])
                try fixture.command("close", ["key": "cycle1"])
                try fixture.command("close", ["key": "cycle2"])
                try desktop.expectShown(windows[0])
                try requireFinalState("the cycle fixtures retired before testing overrides") {
                    Set(try harness.rows().map(\.id)).isDisjoint(with: cycleWindows)
                }
            }
            try step("#2 E32 custom modifiers and every ANSI letter reach merged bindings") {
                try desktop.configure(desktop.stack + "[keys]\nctrl-alt-shift-cmd-g = 'workspace 2'\n", layout: "stack")
                try desktop.post(kVK_ANSI_G, modifiers: ["alt", "shift", "ctrl", "cmd"])
                try desktop.expectShown(windows[1])
                try desktop.key(1)
                try desktop.expectShown(windows[0])
                let letters = [("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
                    ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
                    ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
                    ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
                    ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
                    ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
                    ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z)]
                for (letter, code) in letters {
                    try desktop.configure(desktop.stack + "[keys]\nalt-\(letter) = 'workspace 2'\n", layout: "stack")
                    try desktop.post(code)
                    try desktop.expectShown(windows[1])
                    try desktop.key(1)
                    try desktop.expectShown(windows[0])
                }
                try desktop.configure(desktop.stack + "[keys]\nalt-1 = 'workspace 2'\nalt-2 = ''\n", layout: "stack")
                try desktop.expectPassedKey(kVK_ANSI_2)
                try desktop.expectShown(windows[0])
                try desktop.key(1)
                try desktop.expectShown(windows[1])
                try #require(try harness.status().workspaces?.keys["alt-j"] == "focus next")
            }
        }

        @Test("send journey")
        func send() throws {
            let previous = try fixture.open(key: "previous")
            let sent = try fixture.open(key: "sent", ["title": "Invented journey content"])
            try desktop.activate(key: "sent")
            try requireFinalState("both send journey fixtures listed") {
                Set(try harness.rows().map(\.id)) == Set([previous, sent])
            }
            try desktop.configure(desktop.stack, layout: "stack")
            try desktop.expectShown(sent)
            try step("a real send follows its window and the previous workspace stays reachable") {
                try desktop.key(3, send: true)
                try desktop.expectShown(sent)
                try requireFinalState("the sent fixture membership and active workspace") {
                    try harness.row(sent)?.workspace == 3 && harness.status().workspaces?.active == 3
                }
                try desktop.key(1)
                try desktop.expectShown(previous)
            }
            try step("#2 E35 CLI reports workspace and visibility without titles") {
                try requireFinalState("the CLI workspace and visibility fields") {
                    let rows = try harness.rows()
                    return rows.contains { $0.id == previous && $0.workspace == 1 && $0.visible == true }
                        && rows.contains { $0.id == sent && $0.workspace == 3 && $0.visible == false }
                }
                let status = try #require(try harness.status().workspaces)
                try #require(status.enabled && status.active == 1 && status.gaps.outer == 10 && !status.keys.isEmpty)
                for flags in [[], ["--json"]] {
                    let result = try harness.invoke(["windows"] + flags)
                    let leaked = (result.output + result.error).contains("Invented journey content")
                    try #require(result.status == 0 && !leaked, "CLI output must omit fixture titles")
                }
            }
        }

        @Test("rail scroll and elevator journey")
        func railScrollAndElevator() throws {
            let ids = try desktop.railSetup()
            try step("CLI reports rail, slot, layout and nulls outside a rail") {
                try desktop.post(kVK_ANSI_J, shift: true)
                try desktop.expectShown(ids[0])
                try requireFinalState("the moved fixture rail and slot fields") {
                    let rows = try harness.rows()
                    let rail = try harness.status().workspaces?.rail
                    return rows.contains { $0.id == ids[0] && $0.rail == 2 && $0.slot == 1 }
                        && ids.dropFirst().enumerated().allSatisfy { index, id in
                            rows.contains { $0.id == id && $0.rail == 1 && $0.slot == index + 1 }
                        } && rail == 2
                }
                try #require(try harness.status().workspaces?.layout == "carousel")
                let dialog = try fixture.open(kind: "dialog", key: "dialog")
                try desktop.expectFocus(dialog)
                try requireFinalState("the floating fixture listed") { try harness.row(dialog)?.workspace == 1 }
                let result = try harness.invoke("windows", "--json")
                let objects = try JSONSerialization.jsonObject(with: result.outputData) as? [[String: Any]]
                let row = try #require(objects?.first { ($0["id"] as? NSNumber)?.uint32Value == dialog })
                let hasNulls = row["rail"] is NSNull && row["slot"] is NSNull
                let leaked = result.output.contains("\"title\"") || result.output.contains("Fixture dialog")
                try #require(hasNulls && !leaked, "floating fixtures expose null rail/slot and no titles")
                try fixture.command("close", ["key": "dialog"])
                try desktop.expectShown(ids[0])
            }
            try step("real scroll hotkeys reveal the next destination") {
                try desktop.post(kVK_ANSI_K)
                try requireFinalState("the upper rail has landed and the singleton has hidden before external selection") {
                    let observation = try desktop.observe()
                    return !observation.visibleIDs.contains(ids[0]) && desktop.focused(ids[1], in: observation)
                        && observation.windows.filter { observation.visibleIDs.contains($0.id) }.allSatisfy {
                            abs($0.frame[1] - observation.area[1] - 10) <= 1
                        }
                }
                try desktop.activate(key: "w1")
                let before = try #require(try desktop.window(ids[3])).frame
                try desktop.post(kVK_ANSI_L)
                try desktop.expectFocus(ids[2])
                try desktop.post(kVK_ANSI_L)
                try desktop.expectFocus(ids[3])
                try requireFinalState("the scrolled destination fully visible at a changed position") {
                    let observation = try desktop.observe()
                    return observation.windows.contains {
                        $0.id == ids[3] && !desktop.near($0.frame, before)
                            && $0.frame[0] >= observation.area[0] + 9
                            && $0.frame[0] + $0.frame[2] <= observation.area[0] + observation.area[2] - 9
                    }
                }
            }
            try step("status item AX label tracks real elevator trips") {
                try desktop.expectMenu("Workspace 1, rail 1 of 2")
                try desktop.post(kVK_ANSI_J)
                try desktop.expectFocus(ids[0])
                try desktop.expectMenu("Workspace 1, rail 2 of 2")
                try desktop.post(kVK_ANSI_K)
                try desktop.expectFocus(ids[3])
                try desktop.expectMenu("Workspace 1, rail 1 of 2")
            }
        }

        @Test("reload journey")
        func reload() throws {
            let window = try fixture.open()
            try desktop.activate()
            try step("saving config changes the live layout and gap") {
                try desktop.configure(desktop.stack + "[gaps]\nouter = 20\n", layout: "stack")
                try desktop.expectShown(window, gap: 20)
                try #require(try harness.status().workspaces?.gaps.outer == 20)
            }
            try step("atomic replacement reloads the file watcher and rail layout") {
                let revision = try harness.status().config.revision
                let replacement = harness.configFile.appendingPathExtension("new")
                try Data((desktop.carousel + "[gaps]\nouter = 11\n").utf8).write(to: replacement)
                try #require(rename(replacement.path, harness.configFile.path) == 0)
                try requireFinalState("the atomically replaced config and rail geometry") {
                    let status = try harness.status(), observation = try desktop.observe()
                    return status.config.revision > revision && status.workspaces?.layout == "carousel"
                        && status.workspaces?.gaps.outer == 11 && observation.windows.contains {
                            $0.id == window && desktop.near($0.frame, [observation.area[0] + 11, observation.area[1] + 11,
                                observation.area[2] - 22, observation.area[3] - 22])
                        }
                }
            }
            try step("unreadable config reports an error and permission repair reloads it") {
                let revision = try harness.status().config.revision
                try #require(chmod(harness.configFile.path, 0) == 0)
                defer { chmod(harness.configFile.path, 0o600) }
                try requireFinalState("the unreadable file error") { try harness.status().config.state == "error" }
                try #require(try harness.status().config.revision == revision)
                try #require(chmod(harness.configFile.path, 0o600) == 0)
                try requireFinalState("config recovered after permission repair") {
                    let config = try harness.status().config
                    return config.state == "loaded" && config.error == nil && config.revision > revision
                }
            }
            try step("deleting config restores defaults and releases live keys") {
                try FileManager.default.removeItem(at: harness.configFile)
                try requireFinalState("default configuration after deletion") {
                    let status = try harness.status()
                    return status.config.state == "defaults" && status.config.error == nil && status.workspaces?.enabled == false
                }
                try desktop.expectInside([window])
                try desktop.activate()
                try desktop.expectPassedKey(kVK_ANSI_L)
            }
        }
    }
}
