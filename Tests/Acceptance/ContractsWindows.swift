import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("transient-window-lists: native transitions stay within the modeled AX outcomes", contract(.transientWindowLists))
    func transientWindowLists() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "b")
        _ = try window(a)
        let screen = try #require(try native("screen").screen)
        let display = [screen[0], 0, screen[2], screen[3]]
        var fullscreenTransition = false
        func sample() throws -> NativeContractReply {
            let state = try native()
            try #require(state.listError == 0 || state.listError == -25204, "native transition returned unmodeled AXWindows error \(state.listError ?? 1)")
            if state.listError == 0 && state.listIsArray == true {
                let extra = state.roots.filter { ![0, a, b].contains($0.id) }
                try #require(extra.isEmpty || fullscreenTransition && extra.count == 1,
                             "only a fullscreen transition may publish one auxiliary fixture root")
                for root in extra {
                    try #require(root.role == "AXWindow" && root.roleError == 0 && root.subrole == "AXUnknown" && root.subroleError == 0)
                    try #require(root.frameError == 0 && desktop.near(root.frame, display) && !root.sizeSettable && root.settableError == 0)
                    try #require(root.fullscreen == false && root.fullscreenError == 0 && root.minimized == false && root.minimizedError == 0)
                    try #require(root.main == false && root.mainError == 0 && root.sheets.isEmpty && root.bar == nil)
                }
                try #require(state.roots.allSatisfy { $0.id == 0 || $0.roleError == 0 || $0.roleError == -25202 || $0.roleError == -25204 })
            }
            return state
        }
        try fixture.command("hide")
        try requireFinalState("the hidden transition completes with a modeled window list") { try sample().hidden == true }
        try fixture.command("show")
        try requireFinalState("the unhidden list recovers every live root") { Set(try sample().roots.map(\.id)) == Set([a, b]) }
        for minimized in [true, false] {
            try fixture.command(minimized ? "minimize" : "restore", ["key": "b", "waitForTransition": false])
            try requireFinalState("the minimize transition returns a modeled list and final flag") {
                try sample().roots.first { $0.id == b }?.minimized == minimized && fixture.command("ping").transitionCount == 0
            }
        }
        for fullscreen in [true, false] {
            fullscreenTransition = true
            try fixture.command("fullscreen", ["key": "b", "waitForTransition": false])
            try requireFinalState("the fullscreen transition returns a modeled list and final flag") {
                let state = try sample()
                let completed = try fixture.command("ping").transitionCount == 0
                return state.focused?.id == b && state.focused?.fullscreen == fullscreen && completed
            }
        }
        try requireFinalState("ordinary AXWindows recovers after native transitions") { Set(try sample().roots.map(\.id)) == Set([a, b]) }
        fullscreenTransition = false
        _ = try sample()
    }

    @Test("closed-window-handles: retained AX handles become invalid after native close", contract(.closedWindowHandles))
    func closedWindowHandles() throws {
        let id = try fixture.open()
        _ = try window(id)
        try watch(["AXUIElementDestroyed"], id: id)
        try fixture.command("close", ["retain": true])
        try expectEvent("AXUIElementDestroyed")
        try requireFinalState("the closed retained AX handle becomes invalid") {
            try native("retained", ["id": id]).window?.roleError == -25202
        }
        let state = try native()
        try #require(state.listError == 0 && state.listIsArray == true)
        try #require(state.roots.allSatisfy { $0.id == 0 || $0.id == id }, "a closed native root may disappear or remain listed")
    }

    @Test("minimize-restore: Dock operations update AX, CG, notifications and successor focus", contract(.minimizeRestore))
    func minimizeRestore() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "b")
        _ = try window(b)
        try watch(["AXWindowMiniaturized", "AXWindowDeminiaturized"], id: b)
        try fixture.command("minimize", ["key": "b"])
        try expectEvent("AXWindowMiniaturized", id: b, minimized: true)
        try requireFinalState("the minimized window leaves CG and the native successor is selected") {
            let state = try native()
            return state.roots.first { $0.id == b }?.minimized == true && !state.visible.contains(b)
                && state.visible.contains(a) && state.focused?.id == a && state.focused?.main == true
        }
        try fixture.command("restore", ["key": "b"])
        try expectEvent("AXWindowDeminiaturized", id: b, minimized: false)
        try requireFinalState("the restored window returns to AX and CG") {
            let state = try native()
            return state.roots.first { $0.id == b }?.minimized == false && state.visible.contains(b)
                && state.focused?.id == b && state.focused?.main == true
        }
        try expectFocus(b)
    }

    @Test("native-fullscreen: entering and exiting changes native Space membership", contract(.nativeFullscreen))
    func nativeFullscreen() throws {
        let ordinary = try fixture.open(key: "ordinary"), full = try fixture.open(key: "full")
        try desktop.activate(key: "full")
        _ = try window(full)
        let before = try native("spaces", ["ids": [full]])
        let desktopSpace = try #require(before.activeSpace)
        try fixture.command("fullscreen", ["key": "full"])
        var entered = true
        defer { if entered { _ = try? fixture.command("fullscreen", ["key": "full"]) } }
        try requireFinalState("fullscreen occupies its own visible Space") {
            let state = try native(), spaces = try native("spaces", ["ids": [full]])
            return state.focused?.id == full && state.focused?.fullscreen == true && state.visible.contains(full)
                && !state.visible.contains(ordinary) && spaces.activeSpace != desktopSpace
                && spaces.memberships?.first?.all.contains(spaces.activeSpace ?? 0) == true
        }
        try fixture.command("fullscreen", ["key": "full"])
        entered = false
        try requireFinalState("the window returns to its original desktop Space") {
            let state = try native(), spaces = try native("spaces", ["ids": [full]])
            return state.focused?.fullscreen == false && state.visible.isSuperset(of: [ordinary, full])
                && spaces.activeSpace == desktopSpace && spaces.memberships?.first?.all.contains(desktopSpace) == true
        }
    }

    @Test("native-tab-identity: selected roots retain their bar and minimized tabs enumerate separately", contract(.nativeTabIdentity))
    func nativeTabIdentity() throws {
        let reply = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
        let ids = try (0..<3).map { try #require(reply.windows["tabs\($0)"]) }
        try desktop.activate(key: "tabs0")
        let initial = try window(ids[0])
        let changed = [initial.frame[0] + 25, initial.frame[1] + 25, initial.frame[2] + 30, initial.frame[3] + 30]
        try #require(try write(ids[0], "AXPosition", Array(changed.prefix(2))) == 0)
        try #require(try write(ids[0], "AXSize", Array(changed.suffix(2))) == 0)
        try requireFinalState("native group geometry changed before selecting other roots") {
            try native().roots.first { $0.id == ids[0] }.map { desktop.near($0.frame, changed) } == true
        }
        let first = try window(ids[0]), bar = try #require(first.bar)
        try #require(first.tabs == 3)
        for index in [1, 2, 0] {
            try fixture.command("tab", ["key": "tabs\(index)"])
            try requireFinalState("one selected native root with the same AX bar") {
                let state = try native()
                return state.roots.count == 1 && state.roots[0].id == ids[index]
                    && state.roots[0].bar == bar && state.roots[0].tabs == 3 && desktop.near(state.roots[0].frame, first.frame)
            }
        }
        try fixture.command("minimize", ["key": "tabs0"])
        try requireFinalState("all minimized tabs have separate AX roots and one bar") {
            let roots = try native().roots
            return Set(roots.map(\.id)) == Set(ids) && roots.allSatisfy { $0.minimized == true }
                && roots.map(\.tabs).sorted() == [0, 0, 3]
        }
        try fixture.command("restore", ["key": "tabs0"])
        try requireFinalState("restoration returns the single native root") { try native().roots.count == 1 }
        try fixture.command("detachTab", ["key": "tabs1"])
        try requireFinalState("detaching yields an ordinary focused root and the remaining group") {
            let state = try native()
            return state.roots.count == 2 && state.focused?.id == ids[1]
                && state.roots.contains { $0.id == ids[1] && $0.bar == nil }
                && state.roots.contains { $0.id != ids[1] && $0.bar == bar && $0.tabs == 2 }
        }
        try fixture.command("reset")
        for kind in ["contentTabs", "emptyContentTabs", "manyContentTabs", "segmentedTabs"] {
            let id = try fixture.open(kind: kind, key: kind)
            let state = try window(id)
            try #require(state.bar == nil && state.tabs == 0, "content tab controls must not have native-bar identity")
        }
    }

    @Test("window-geometry-writes: AX position and size writes are independent and notify", contract(.windowGeometryWrites))
    func windowGeometryWrites() throws {
        let id = try fixture.open()
        try desktop.activate()
        let before = try window(id)
        try watch(["AXWindowMoved", "AXWindowResized"], id: id)
        let position = [before.frame[0] + 25, before.frame[1] + 25]
        try #require(try write(id, "AXPosition", position) == 0)
        try requireFinalState("position changed without changing size") {
            let frame = try native().roots.first { $0.id == id }?.frame ?? []
            return desktop.near(frame, position + Array(before.frame.suffix(2)))
        }
        try expectEvent("AXWindowMoved", id: id)
        let size = [before.frame[2] + 25, before.frame[3] + 25]
        try #require(try write(id, "AXSize", size) == 0)
        try requireFinalState("size changed without changing position") {
            let frame = try native().roots.first { $0.id == id }?.frame ?? []
            return desktop.near(frame, position + size)
        }
        try expectEvent("AXWindowResized", id: id)
        let screen = try #require(try native("screen").screen)
        let outside = [screen[0] + screen[2] + 100, position[1]]
        try #require(try write(id, "AXPosition", outside) == 0)
        let clamped = [screen[0] + screen[2] - 40, position[1]]
        try requireFinalState("the successful position write accepts the point or leaves the modeled 40-point strip") {
            let frame = try native().roots.first { $0.id == id }?.frame ?? []
            return desktop.near(frame, outside + size) || desktop.near(frame, clamped + size)
        }
    }

    @Test("cg-on-screen-order: native stacking excludes hidden, minimized and off-screen windows", contract(.cgOnScreenOrder))
    func cgOnScreenOrder() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(kind: "unconstrained", key: "b")
        try desktop.activate(key: "b")
        try requireFinalState("CG front-to-back order follows the native key window") { try native().visibleIDs == [b, a] }
        try fixture.command("tab", ["key": "a"])
        try requireFinalState("CG order changes when another window is raised") { try native().visibleIDs == [a, b] }
        try fixture.command("minimize", ["key": "a"])
        try requireFinalState("CG excludes a minimized window") { try native().visibleIDs == [b] }
        try fixture.command("hide")
        try requireFinalState("CG excludes app-hidden windows") { try native().visible.isEmpty }
        try fixture.command("show")
        try fixture.command("restore", ["key": "a"])
        try requireFinalState("CG includes restored windows") { try native().visible == Set([a, b]) }
        let before = try window(b)
        let screen = try #require(try native("screen").screen)
        try fixture.command("move", ["key": "b", "frame": [screen[0] + screen[2] + 100, before.frame[1], before.frame[2], before.frame[3]]])
        try requireFinalState("the native fixture accepts a frame outside the display") {
            let frame = try fixture.command("ping").frames?["b"] ?? []
            return frame.count == 4 && frame[0] >= screen[0] + screen[2]
        }
        try requireFinalState("CG excludes a native window with no display intersection") {
            let state = try native()
            return !state.visible.contains(b)
        }
    }

    @Test("primary-screen-geometry: native frames convert from bottom origin to AX top origin", contract(.primaryScreenGeometry))
    func primaryScreenGeometry() throws {
        let id = try fixture.open()
        let state = try window(id), screen = try native("screen")
        let full = try #require(screen.screen), visible = try #require(screen.visibleFrame)
        let cg = try #require(screen.cgDisplay), axVisible = try #require(screen.axVisibleFrame)
        try #require(full.count == 4 && visible.count == 4 && cg.count == 4 && axVisible.count == 4)
        try #require(full[0] == 0 && full[1] == 0 && full[2] > 0 && full[3] > 0)
        try #require(cg[0] == 0 && cg[1] == 0 && cg[2] == full[2] && cg[3] == full[3])
        try #require(visible[0] >= full[0] && visible[1] >= full[1]
                     && visible[0] + visible[2] <= full[0] + full[2] && visible[1] + visible[3] <= full[1] + full[3])
        let frame = try #require(try fixture.command("ping").frames?["window"])
        try #require(desktop.near(state.frame, [frame[0], full[1] + full[3] - frame[1] - frame[3], frame[2], frame[3]]))
        try #require(desktop.near(axVisible, [visible[0], full[1] + full[3] - visible[1] - visible[3], visible[2], visible[3]]))
        try #require(desktop.near(try desktop.observe().area, axVisible))
    }
}
