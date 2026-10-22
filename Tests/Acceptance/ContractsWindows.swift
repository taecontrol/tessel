import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("window-levels: CG layers distinguish native roots and remain readable by ID off the active Space", contract(.windowLevels))
    func windowLevels() throws {
        let reply = try fixture.command("windowLevels")
        let ordinary = try #require(reply.windows["ordinary"]), dialog = try #require(reply.windows["dialog"])
        let panel = try #require(reply.windows["panel"])
        let popup = try #require(reply.windows["popup"]), status = try #require(reply.windows["status"])
        // One native setup and one closet round trip, with no sleeps or
        // repeated transitions; this contract is intended to cost about 1 s.
        try requireFinalState("the independent observer reads each native layer and AX root") {
            let roots = try native().roots
            guard let a = roots.first(where: { $0.id == ordinary }), let b = roots.first(where: { $0.id == dialog }),
                  let utility = roots.first(where: { $0.id == panel }),
                  let child = roots.first(where: { $0.id == popup }), let high = roots.first(where: { $0.id == status }) else { return false }
            return a.layer == 0 && a.subrole == "AXStandardWindow" && b.layer == 0 && b.subrole == "AXDialog"
                && utility.layer == 3 && utility.subrole == "AXFloatingWindow"
                && child.layer == 0 && child.subrole == "AXUnknown" && child.role == "AXWindow"
                && high.layer.map { $0 != 0 && $0 != 3 } == true
                && [a, b, utility, child, high].allSatisfy { $0.subroleError == 0 && $0.roleError == 0 }
                && !a.sheets.contains { $0.id == popup }
        }
        let started = try native("closetStart")
        defer { _ = try? native("closetStop") }
        let active = try #require(started.activeSpace), closet = try #require(started.closetSpace)
        try #require(closet != 0 && closet != active)
        try native("closetHide", ["ids": [dialog]])
        try requireFinalState("CG still describes a fixture window by ID while it is only in the closet") {
            let state = try native(), spaces = try native("spaces", ["ids": [dialog]])
            let retained = try native("retained", ["id": dialog]).window
            return spaces.activeSpace == active && spaces.memberships?.first?.ordinary.isEmpty == true
                && spaces.memberships?.first?.all == [closet] && !state.visible.contains(dialog)
                && retained?.id == dialog && retained?.layer == 0
        }
        try native("closetShow", ["ids": [dialog]])
        try requireFinalState("the observed window returns to the active Space with the same readable layer") {
            let state = try native(), spaces = try native("spaces", ["ids": [dialog]])
            return spaces.activeSpace == active && spaces.memberships?.first?.ordinary == [active]
                && state.visible.contains(dialog) && state.roots.first { $0.id == dialog }?.layer == 0
        }
    }

    @Test("transient-window-lists: native transitions stay within the modeled AX outcomes", contract(.transientWindowLists))
    func transientWindowLists() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "b")
        _ = try window(a)
        let screen = try #require(try native("screen").screen)
        let display = [screen[0], 0, screen[2], screen[3]]
        var fullscreenTransition = false
        var watchedRoot: UInt32?
        try watch(["AXWindowCreated"])
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
                    if watchedRoot == nil {
                        try expectEvent("AXWindowCreated", id: root.id)
                        let results = try native("watch", ["id": root.id, "notifications": ["AXUIElementDestroyed"]]).results
                        try #require(results == [0] || results == [-25202])
                        if results == [0] { watchedRoot = root.id }
                        else { try watch(["AXWindowCreated"]) }
                    }
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
            // A timeout names the last observation so a CI-only failure is diagnosable.
            var last = "no observation"
            do {
                try requireFinalState("the minimize transition returns a modeled list and final flag") {
                    let state = try sample(), transitions = try fixture.command("ping").transitionCount
                    let root = state.roots.first { $0.id == b }
                    last = "listError \(state.listError ?? 0), roots \(state.roots.map(\.id)), minimized \(String(describing: root?.minimized)) "
                        + "error \(String(describing: root?.minimizedError)), transitions \(String(describing: transitions))"
                    return root?.minimized == minimized && transitions == 0
                }
            } catch { throw HarnessError("\(error); minimized=\(minimized), last observation: \(last)") }
        }
        for fullscreen in [true, false] {
            try desktop.activate(key: "b")
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
        // Only this root is watched; a destroyed handle no longer exposes its CG ID.
        if watchedRoot != nil { try expectEvent("AXUIElementDestroyed") }
    }

    @Test("closed-window-handles: ID lookups and attributes report different errors after native close", contract(.closedWindowHandles))
    func closedWindowHandles() throws {
        for retain in [false, true] {
            try native("reset")
            try fixture.command("reset")
            let id = try fixture.open()
            let before = try window(id)
            try #require(before.idError == 0 && before.roleError == 0 && before.minimizedError == 0 && before.frameError == 0)
            try #require(before.minimized == false)
            // The catalog replaces its cached proxy on each complete AXWindows read.
            for _ in 0..<2 {
                let current = try native("reacquire", ["id": id])
                try #require(current.equal == true && current.window?.id == id && current.window?.idError == 0)
            }
            try watch(["AXUIElementDestroyed"], id: id)
            try fixture.command("close", ["retain": retain])
            let closedAt = monotonicSeconds()
            try expectEvent("AXUIElementDestroyed")
            func invalid(_ window: NativeContractReply.Window) -> Bool {
                window.idError == -25201 && window.id == 0 && window.roleError == -25202
                    && window.minimizedError == -25202 && window.frameError == -25202
            }
            func empty(_ state: NativeContractReply) -> Bool {
                state.listError == 0 && state.listIsArray == true && state.roots.isEmpty
            }
            var reads = 0
            try requireFinalState("the closed retained AX handle becomes invalid and both window lists omit it") {
                let listed = try native()
                let retained = try native("retained", ["id": id]).window
                let confirmed = try native()
                reads += 1
                return retained.map(invalid) == true && empty(listed) && empty(confirmed)
            }
            let first = monotonicSeconds() - closedAt
            for _ in 0..<20 {
                let listed = try native()
                let retained = try #require(try native("retained", ["id": id]).window)
                try #require(invalid(retained))
                let confirmed = try native()
                try #require(empty(listed) && empty(confirmed))
            }
            print(String(format: "closed handle retain=%@ first=%.3f s reads=%d+20 idError=-25201 id=0 role=-25202 minimized=-25202 position=-25202 lists=empty/empty",
                         String(retain), first, reads))
        }
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

    @Test("cg-on-screen-order: native stacking excludes hidden and minimized windows and may retain off-display windows", contract(.cgOnScreenOrder))
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
        try requireFinalState("CG keeps native stacking with either modeled off-display membership") {
            let state = try native()
            return state.visibleIDs == [a, b] || state.visibleIDs == [a]
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
        // This is the capture's independent frame source, including a busy
        // app: WindowServer metadata must match accepted AX geometry.
        for x in [10.0, full[2] - 1] {
            try #require(try write(id, "AXPosition", [x, axVisible[1] + 10]) == 0)
            let accepted = try window(id).frame
            try requireFinalState("CG window bounds match accepted AX top-origin geometry") {
                try native("cgFrames").cgFrames?[String(id)].map { desktop.near($0, accepted) } == true
            }
        }
        let accepted = try window(id).frame
        try native("motionStart", ["targets": [["pid": fixture.pid, "ids": [id]]]])
        defer { _ = try? native("motionStop") }
        kill(fixture.pid, SIGSTOP)
        let stoppedAt = monotonicSeconds()
        do {
            defer { kill(fixture.pid, SIGCONT) }
            let cgFrame = try #require(try native("cgFrames").cgFrames?[String(id)])
            try #require(desktop.near(cgFrame, accepted), "WindowServer geometry remains observable while the fixture cannot answer AX")
            var samples: [NativeContractReply.MotionSample] = []
            try requireFinalState("the independent motion observer samples the stopped fixture") {
                samples = try native("motionSamples").motionSamples?.filter { ($0.startedAt ?? 0) >= stoppedAt } ?? []
                return samples.count >= 2
            }
            try #require(samples.allSatisfy { sample in
                sample.windows.contains { $0.id == id && $0.valid && desktop.near($0.frame, accepted) }
            }, "motion geometry remains valid without a reply from the fixture")
        }

    }
}
