import Darwin
import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("application-lifecycle: launch, metadata and termination", contract(.applicationLifecycle))
    func applicationLifecycle() throws {
        try native("lifecycleStart")
        for prohibited in [false, true] {
            let target = try other(prohibited: prohibited), pid = target.pid
            try requireFinalState("native fixture metadata with prohibited=\(prohibited)") {
                let metadata = try native("metadata", session: target)
                return metadata.alive == true && metadata.listed == true && metadata.bundleMatches == true
                    && metadata.regular == !prohibited && metadata.prohibited == prohibited && metadata.terminated == false
            }
            if !prohibited {
                try requireFinalState("the regular fixture launch notification") {
                    try native("lifecycle").lifecycle?.contains { $0.pid == pid && $0.name == "NSWorkspaceDidLaunchApplicationNotification" && $0.mainThread } == true
                }
            }
            try target.command("quit")
            try requireFinalState("native fixture termination") { kill(pid, 0) != 0 }
            target.disconnect()
            harness.otherFixtures.removeAll { $0 === target }
            if !prohibited {
                try requireFinalState("the regular fixture termination notification") {
                    try native("lifecycle").lifecycle?.contains { $0.pid == pid && $0.name == "NSWorkspaceDidTerminateApplicationNotification" && $0.mainThread } == true
                }
            }
            let events = try #require(try native("lifecycle").lifecycle).filter { $0.pid == pid }
            for name in ["NSWorkspaceDidLaunchApplicationNotification", "NSWorkspaceDidTerminateApplicationNotification"] {
                let matching = events.filter { $0.name == name }
                try #require(matching.count <= 1 && matching.allSatisfy { $0.mainThread && $0.knownPID == pid })
            }
        }
    }

    @Test("application-activation: activation preserves window order", contract(.applicationActivation))
    func applicationActivation() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "b")
        let target = try other(), cover = try target.open()
        try desktop.activate(target)
        try #require(try native().focused?.id == b)
        try native("lifecycleStart")
        try target.command("yieldActivation", ["pid": fixture.pid])
        try native("activate")
        try expectFocus(b)
        try requireFinalState("activation reported by NSWorkspace") {
            try native("lifecycle").lifecycle?.contains { $0.pid == fixture.pid && $0.name == "NSWorkspaceDidActivateApplicationNotification" } == true
        }
        let observation = try desktop.observe()
        let background = try #require(observation.windows.first { $0.id == a })
        let covering = try #require(observation.windows.first { $0.id == cover })
        try #require(background.order > covering.order, "activation must not order every window of the target app")
    }

    @Test("application-visibility: hide and unhide publish AXHidden and CG state", contract(.applicationVisibility))
    func applicationVisibility() throws {
        let ids = try Set([fixture.open(key: "a"), fixture.open(key: "b")])
        try desktop.activate(key: "b")
        try requireFinalState("both native windows initially visible") { try native().visible == ids }
        try fixture.command("hide")
        try requireFinalState("native app hidden") {
            let state = try native()
            return state.hidden == true && state.visible.isDisjoint(with: ids)
        }
        let hidden = try native()
        try #require(hidden.listError == 0 && hidden.listIsArray == true)
        let listed = Set(hidden.roots.map(\.id))
        try #require(listed == ids || listed.isEmpty, "hidden AXWindows must be complete or omitted")
        try fixture.command("show")
        try requireFinalState("native app unhidden") {
            let state = try native()
            return state.hidden == false && state.visible == ids && Set(state.roots.map(\.id)) == ids
        }
    }

    @Test("ax-application-windows: roots preserve app enumeration and include minimized windows", contract(.axApplicationWindows))
    func axApplicationWindows() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        let sheet = try fixture.open(kind: "sheet", key: "sheet")
        let reply = try fixture.command("ping"), parent = try #require(reply.windows["sheetParent"])
        try requireFinalState("ordinary roots and attached sheet") {
            let state = try native()
            return Set(state.roots.map(\.id)) == Set([a, b, parent])
                && state.roots.first { $0.id == parent }?.sheets.contains { $0.id == sheet } == true
        }
        try #require(try native().roots.map(\.id) == fixture.command("ping").axWindowOrder)
        try fixture.command("minimize", ["key": "a"])
        try requireFinalState("the minimized root remains in AXWindows") {
            try native().roots.contains { $0.id == a && $0.minimized == true }
        }
        try #require(try native().roots.map(\.id) == fixture.command("ping").axWindowOrder)
    }

    @Test("ax-window-attributes: AppKit roles, flags, frames, children and settability", contract(.axWindowAttributes))
    func axWindowAttributes() throws {
        for (kind, subrole, resizable) in [("standard", "AXStandardWindow", true), ("noFullscreen", "AXStandardWindow", true),
                                          ("fixed", "AXStandardWindow", false), ("dialog", "AXDialog", true), ("panel", "AXFloatingWindow", true)] {
            let id = try fixture.open(kind: kind, key: kind)
            let state = try window(id)
            try #require(state.role == "AXWindow" && state.subrole == subrole && state.minimized == false && state.fullscreen == false)
            try #require(state.sizeSettable == resizable && state.settableError == 0 && state.frameError == 0 && state.frame.count == 4)
            if !resizable { try #require(try write(id, "AXSize", [650, 400]) == -25200) }
        }
        let sheet = try fixture.open(kind: "sheet", key: "sheet")
        let state = try window(sheet)
        try #require(state.role == "AXSheet" && state.subrole != "AXStandardWindow")
        try #require(state.minimized == nil && state.minimizedError == -25205)
        try #require(state.fullscreen == nil && state.fullscreenError == -25205)
    }

    @Test("ax-size-constraints: successful size writes accept clamped geometry", contract(.axSizeConstraints))
    func axSizeConstraints() throws {
        let id = try fixture.open(kind: "maxWidth")
        _ = try window(id)
        try #require(try write(id, "AXSize", [650, 400]) == 0)
        try requireFinalState("the maximum width clamps an otherwise successful AXSize write") {
            let state = try native().roots.first { $0.id == id }
            return state.map { $0.frame.count == 4 && abs($0.frame[2] - 480) <= 1 && abs($0.frame[3] - 400) <= 1 } == true
        }
        try fixture.command("limits", ["key": "window", "minimum": [300.0, 200.0]])
        let initial = try #require(try fixture.command("ping").frames?["window"])
        try #require(try write(id, "AXSize", [100, 100]) == 0)
        try requireFinalState("the minimum content size clamps the AXSize write") {
            let state = try native().roots.first { $0.id == id }
            return state.map { $0.frame.count == 4 && $0.frame[2] >= 300 && $0.frame[3] >= 200
                && $0.frame[2] <= initial[2] && $0.frame[3] <= initial[3] } == true
        }
    }

    @Test("ax-focus: AXMain and AXRaise select real windows", contract(.axFocus))
    func axFocus() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "b")
        _ = try window(a)
        try expectFocus(b)
        try #require(try write(a, "AXMain") == 0)
        try expectFocus(a)
        try #require(try write(b, "AXRaise") == 0)
        try expectFocus(b)
        let sheet = try fixture.open(kind: "sheet", key: "sheet")
        let parent = try #require(try fixture.command("ping").windows["sheetParent"])
        try requireFinalState("a focused sheet leaves its parent main") {
            let state = try native()
            return state.focused?.id == sheet && state.focused?.main == nil && state.focused?.mainError == -25205
                && state.roots.first { $0.id == parent }?.main == true
        }
    }

    @Test("ax-notifications: native creation and focus events arrive on the main run loop", contract(.axNotifications))
    func axNotifications() throws {
        let a = try fixture.open(key: "a")
        try desktop.activate(key: "a")
        try watch(["AXWindowCreated", "AXFocusedWindowChanged", "AXMainWindowChanged"])
        let b = try fixture.open(key: "b")
        try expectEvent("AXWindowCreated", id: b)
        try expectEvent("AXFocusedWindowChanged")
        try expectEvent("AXMainWindowChanged")
        try expectFocus(b)
        let events = try #require(try native("events").events)
        try #require(events.allSatisfy { $0.mainThread })
        try native("clearEvents")
        try fixture.command("tab", ["key": "a"])
        try expectEvent("AXFocusedWindowChanged")
        try expectEvent("AXMainWindowChanged")
        try expectFocus(a)
    }

    @Test("ax-subscriptions: equal handles share registrations and removal stops delivery", contract(.axSubscriptions))
    func axSubscriptions() throws {
        let id = try fixture.open()
        try desktop.activate()
        _ = try window(id)
        try #require(try native("identity", ["id": id]).equal == true)
        try watch(["AXWindowMoved", "AXWindowResized"], id: id)
        try #require(try native("add", ["id": id, "notifications": ["AXWindowMoved"]]).results == [-25209])
        let state = try window(id)
        try #require(try write(id, "AXPosition", [state.frame[0] + 20, state.frame[1] + 20]) == 0)
        try expectEvent("AXWindowMoved", id: id)
        try #require(try native("remove", ["id": id, "notifications": ["AXWindowMoved"]]).results == [0])
        try native("clearEvents")
        for offset in [40.0, 60.0] {
            try #require(try write(id, "AXPosition", [state.frame[0] + offset, state.frame[1] + offset]) == 0)
        }
        try #require(try write(id, "AXSize", [state.frame[2] + 30, state.frame[3] + 30]) == 0)
        try expectEvent("AXWindowResized", id: id)
        try #require(try native("events").events?.contains { $0.name == "AXWindowMoved" } == false)
    }

    @Test("ax-notifications: moves, sizes and fullscreen expose their native geometry notifications", contract(.axNotifications))
    func geometryAndFullscreenNotifications() throws {
        for kind in ["standard", "web"] {
            let id = try fixture.open(kind: kind, key: kind)
            try desktop.activate(key: kind)
            let state = try window(id)
            try watch(["AXWindowMoved", "AXWindowResized", "AXLayoutChanged", "AXValueChanged"], id: id)
            try native("clearEvents")
            try #require(try write(id, "AXPosition", [state.frame[0] + 20, state.frame[1] + 20]) == 0)
            try #require(try write(id, "AXSize", [state.frame[2] + 30, state.frame[3] + 30]) == 0)
            try expectEvent("AXWindowMoved", id: id)
            try expectEvent("AXWindowResized", id: id)
            sleep(seconds: 0.1)
            let geometry = try #require(try native("events").events)
            try #require(geometry.allSatisfy { ["AXWindowMoved", "AXWindowResized"].contains($0.name) }, "geometry echoes must remain distinct from layout/value state notifications")
            try native("clearEvents")
            try fixture.command("fullscreen", ["key": kind])
            var entered = true
            defer { if entered { _ = try? fixture.command("fullscreen", ["key": kind]) } }
            try requireFinalState("the notification fixture enters native fullscreen") {
                try native().focused?.fullscreen == true
            }
            // Production revalidates the notified element by AX equality with
            // its retained handle; a window ID lookup can fail mid-transition.
            var fullscreen: [NativeContractReply.Event] = []
            let resized = try finalState {
                fullscreen = try native("events").events ?? []
                return fullscreen.contains { $0.name == "AXWindowResized" && $0.registered == true && $0.mainThread }
            }
            let described = fullscreen.map { "\($0.name) id=\($0.id ?? 0) idError=\($0.idError ?? 0) registered=\($0.registered.map(String.init) ?? "nil")" }
            try #require(resized, "fullscreen must reach the resize-state revalidation path for the registered window: \(described)")
            try #require(fullscreen.allSatisfy { $0.idError != 0 || $0.id == id }, "a resolved window ID must name the registered window: \(described)")
            try fixture.command("fullscreen", ["key": kind])
            entered = false
        }
    }

    @Test("ax-messaging-timeout: timeout configuration is local and hung reads report cannotComplete", contract(.axMessagingTimeout))
    func axMessagingTimeout() throws {
        let id = try fixture.open()
        _ = try window(id)
        kill(fixture.pid, SIGSTOP)
        do {
            defer { kill(fixture.pid, SIGCONT) }
            for seconds in [0.002, 0.05] {
                let result = try native("timeout", ["id": id, "seconds": seconds])
                try #require(result.result == 0, "timeout configuration succeeds without a reply from the stopped app")
                try #require(result.readError == -25204, "the subsequent remote AX read needs the app to answer")
            }
        }
        try requireFinalState("the resumed fixture answers AX again") { try native("retained", ["id": id]).window?.roleError == 0 }
    }

    @Test("ax-read-delivery: retained AX values keep the state captured before a native change", contract(.axReadDelivery))
    func axReadDelivery() throws {
        let a = try fixture.open(key: "a"), b = try fixture.open(key: "b")
        try desktop.activate(key: "a")
        let before = try window(a)
        try #require(try native("capture", ["id": a]).capturedCount == 3)
        let changed = [before.frame[0] + 30, before.frame[1] + 30, before.frame[2] + 40, before.frame[3] + 40]
        try fixture.command("move", ["key": "a", "frame": changed])
        try fixture.command("tab", ["key": "b"])
        try expectFocus(b)
        try requireFinalState("the live window has the new geometry") { try native().roots.first { $0.id == a }.map { desktop.near($0.frame, changed) } == true }
        let reply = try native("readCapture")
        try #require(reply.capturedFocus == a && reply.capturedFrame == before.frame)
    }
}
