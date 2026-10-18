import Darwin
import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("background-window-creation: creation leaves the app's key and main window unchanged", contract(.backgroundWindowCreation))
    func backgroundWindowCreation() throws {
        let front = try fixture.open(key: "front")
        try desktop.activate(key: "front")
        try watch(["AXWindowCreated", "AXFocusedWindowChanged", "AXMainWindowChanged"])
        let background = try fixture.open(key: "background", ["background": true])
        try expectEvent("AXWindowCreated", id: background)
        let state = try native(), local = try fixture.command("ping")
        try #require(state.focused?.id == front && state.roots.first { $0.id == front }?.main == true)
        try #require(state.roots.first { $0.id == background }?.main == false && state.visible.contains(background))
        try #require(local.keyWindow == front && local.mainWindow == front)
        let creation = try #require(try native("events").events?.first { $0.name == "AXWindowCreated" && $0.id == background })
        try #require(creation.focusedID == front, "creation must not select the background window before its notification")
    }

    @Test("content-tab-chrome: content tabs separate their buttons from selected contents", contract(.contentTabChrome))
    func contentTabChrome() throws {
        for kind in ["emptyContentTabs", "contentTabs", "segmentedTabs"] {
            let id = try fixture.open(kind: kind, key: kind)
            _ = try window(id)
            let groups = try #require(try native("chrome", ["id": id]).chrome)
            let group = try #require(groups.first, "the \(kind) fixture must expose its real tab controls")
            try #require(["AXTabGroup", "AXGroup", "AXRadioGroup"].contains(group.role ?? ""))
            try #require(group.childrenError == 0 && group.childrenIsArray)
            if kind == "segmentedTabs" {
                try #require(group.children.filter { $0 == "AXRadioButton" }.count == 3)
            } else {
                try #require(group.tabsError == 0 && group.tabsIsArray && group.contentsError == 0 && group.contentsIsArray)
                try #require(group.tabs == Array(repeating: "AXRadioButton", count: 3))
                try #require(!group.tabsInContents, "content tab buttons must not acquire native-bar identity")
                try #require(kind == "emptyContentTabs" ? group.contents.isEmpty : group.contents == ["AXGroup"], "\(kind) publishes AXContents roles \(group.contents)")
            }
        }
    }

    @Test("native-tab-extra-controls: New Tab is outside AXTabs and close buttons are optional", contract(.nativeTabExtraControls))
    func nativeTabExtraControls() throws {
        let reply = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3, "windowKind": "newTabButton", "closable": false])
        let first = try #require(reply.windows["tabs0"])
        _ = try window(first)
        try #require(reply.nativeTabs["tabs0"] == 3 && reply.closable.values.allSatisfy { !$0 })
        let group = try #require(try native("chrome", ["id": first]).chrome?.first { $0.tabsInContents })
        try #require(group.tabsError == 0 && group.tabsIsArray && group.contentsError == 0 && group.contentsIsArray)
        try #require(group.tabs == Array(repeating: "AXRadioButton", count: 3))
        try #require(group.contents == group.tabs + ["AXButton"])
        try #require(zip(group.tabChildrenErrors, group.tabChildrenAreArrays).allSatisfy { error, array in
            error == 0 && array || error == -25212 || error == -25205
        }, "unanswered tab-child reads cannot prove close buttons absent")
        try #require(group.tabChildren.count == 3 && group.tabChildren.allSatisfy { !$0.contains("AXButton") })
    }

    @Test("delayed-native-tab-focus: native selection stays within the modeled list and focus publication choices", contract(.delayedNativeTabFocus))
    func delayedNativeTabFocus() throws {
        let ids = try nativeTabs()
        let bar = try #require(try window(ids[0]).bar)
        var former = ids[0], samples = 0, unpublishedFocus = 0, staleFormer = 0
        for index in [1, 2, 0, 2, 1, 0] {
            try fixture.command("tab", ["key": "tabs\(index)"])
            try requireFinalState("the selected native root and its focus are published") {
                let state = try publication(ids, bar: bar, former: former, selected: ids[index])
                samples += 1
                if state.focusedError == -25212 { unpublishedFocus += 1 }
                if state.roots.contains(where: { $0.id == former && $0.bar == nil }) { staleFormer += 1 }
                return state.roots.map(\.id) == [ids[index]] && state.focused?.id == ids[index]
                    && state.roots.first?.bar == bar
            }
            former = ids[index]
        }
        print("Delayed native tab focus: samples=\(samples), unpublished focus=\(unpublishedFocus), former listed without bar=\(staleFormer)")
    }

    @Test("activation-hidden-focus: plain activation reads closet focus and unhides the app", contract(.activationHiddenFocus))
    func activationHiddenFocus() throws {
        let hidden = try fixture.open(key: "hidden")
        try desktop.activate(key: "hidden")
        _ = try window(hidden)
        try native("closetStart")
        defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [hidden]])
        try requireFinalState("the key window is in the closet with readable AX focus") {
            let state = try native()
            return !state.visible.contains(hidden) && state.focused?.id == hidden
        }
        let cover = try other()
        _ = try cover.open()
        try desktop.activate(cover)
        for appHidden in [false, true] {
            if appHidden {
                try fixture.command("hide")
                try requireFinalState("the fixture app is hidden") { try native().hidden == true }
            }
            try cover.command("yieldActivation", ["pid": fixture.pid])
            try native("activate")
            try requireFinalState("plain activation preserves closet focus and unhides") {
                let state = try native()
                return state.frontmost == true && state.hidden == false && state.focused?.id == hidden && !state.visible.contains(hidden)
            }
            try desktop.activate(cover)
        }
    }

    @Test("close-focus-promotion: destruction observes no successor or an already promoted sibling", contract(.closeFocusPromotion))
    func closeFocusPromotion() throws {
        let sibling = try fixture.open(key: "sibling"), closing = try fixture.open(key: "closing")
        try desktop.activate(key: "closing")
        _ = try window(sibling)
        try native("closetStart")
        defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [sibling]])
        try requireFinalState("the sibling is closeted before closing the key window") { try !native().visible.contains(sibling) }
        try watch(["AXUIElementDestroyed"], id: closing)
        try fixture.command("close", ["key": "closing", "retain": true])
        try expectEvent("AXUIElementDestroyed")
        let event = try #require(try native("events").events?.first { $0.name == "AXUIElementDestroyed" })
        let state = try native(), retained = try native("retained", ["id": sibling]).window
        try #require(event.focusedError == 0 || event.focusedError == -25212, "an unanswered focus read cannot establish promotion ordering")
        try #require(event.focusedID == nil || event.focusedID == sibling)
        try #require(state.focused?.id == event.focusedID && !state.visible.contains(sibling), "native promotion must not follow destruction delivery")
        if event.focusedID == sibling { try #require(retained?.main == true) }
        print("Close focus promotion: sibling selected at destruction delivery=\(event.focusedID == sibling)")
    }

    @Test("sheet-focus-ownership: raising or making the parent main keeps the sheet focused", contract(.sheetFocusOwnership))
    func sheetFocusOwnership() throws {
        let sheet = try fixture.open(kind: "sheet", key: "sheet")
        let parent = try #require(try fixture.command("ping").windows["sheetParent"])
        try desktop.activate(key: "sheetParent")
        _ = try window(parent)
        for attribute in ["AXMain", "AXRaise"] {
            try #require(try write(parent, attribute) == 0)
            try requireFinalState("the sheet remains focused while its parent owns AXMain after \(attribute)") {
                let state = try native()
                return state.focused?.id == sheet && state.roots.contains { $0.id == parent && $0.main == true && $0.sheets.contains { $0.id == sheet } }
            }
        }
    }

    @Test("native-tab-insertion: insertion preserves bar identity, frame and Space", contract(.nativeTabInsertion))
    func nativeTabInsertion() throws {
        let ids = try nativeTabs()
        let first = try window(ids[0]), bar = try #require(first.bar)
        let frame = [first.frame[0] + 20, first.frame[1] + 20, first.frame[2] + 60, first.frame[3] + 40]
        try #require(try write(ids[0], "AXPosition", Array(frame.prefix(2))) == 0)
        try #require(try write(ids[0], "AXSize", Array(frame.suffix(2))) == 0)
        try requireFinalState("the existing tab group has distinct geometry before insertion") { try desktop.near(window(ids[0]).frame, frame) }
        let space = try #require(try native("spaces", ["ids": [ids[0]]]).memberships?.first?.ordinary)
        let reply = try fixture.command("addTab", ["key": "inserted", "reference": "tabs0"])
        let inserted = try #require(reply.windows["inserted"])
        try requireFinalState("the inserted tab becomes the selected native root") {
            let state = try native()
            return state.roots.count == 1 && state.focused?.id == inserted && state.roots[0].id == inserted
                && state.roots[0].bar == bar && state.roots[0].tabs == 4 && desktop.near(state.roots[0].frame, frame)
        }
        for key in ["tabs0", "tabs1", "inserted"] {
            try fixture.command("tab", ["key": key])
            let id = try #require(reply.windows[key])
            try requireFinalState("each selected group member shares the original frame, bar and Space") {
                let state = try native(), membership = try native("spaces", ["ids": [id]])
                return state.focused?.id == id && state.roots.first?.bar == bar
                    && state.roots.first.map { desktop.near($0.frame, frame) } == true && membership.memberships?.first?.ordinary == space
            }
        }
        let cover = try other()
        _ = try cover.open()
        try desktop.activate(cover)
        let closet = try #require(try native("closetStart").closetSpace)
        defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [inserted]])
        try requireFinalState("the selected native reference is in the closet before background insertion") {
            let state = try native(), memberships = try native("spaces", ["ids": [inserted]]).memberships ?? []
            return !state.visible.contains(inserted) && memberships.count == 1
                && memberships.allSatisfy { $0.ordinary.isEmpty && $0.all.contains(closet) }
        }
        let added = try #require(try fixture.command("addTab", ["key": "backgroundInserted", "reference": "inserted", "activating": false]).windows["backgroundInserted"])
        try requireFinalState("background insertion keeps the group frame and invisible Space") {
            let state = try native()
            guard state.focused?.id == added || state.roots.contains(where: { $0.id == added }) else { return false }
            let membership = try native("spaces", ["ids": [added]])
            return state.focused?.id == added && state.frontmost == false && state.roots.first?.bar == bar && state.roots.first?.tabs == 5
                && state.roots.first.map { desktop.near($0.frame, frame) } == true && !state.visible.contains(added)
                && membership.memberships?.first?.ordinary.isEmpty == true && membership.memberships?.first?.all.contains(closet) == true
        }
    }

    @Test("size-limit-changes: maximum changes preserve the current frame and clamp the next write", contract(.sizeLimitChanges))
    func sizeLimitChanges() throws {
        let id = try fixture.open()
        try desktop.activate()
        for dimension in ["Width", "Height"] {
            let before = try window(id).frame, index = dimension == "Width" ? 2 : 3
            let limit = before[index] - 80
            try fixture.command("limit" + dimension, [dimension.lowercased(): limit])
            try #require(try native("retained", ["id": id]).window?.frame == before, "changing maximum \(dimension.lowercased()) must leave current geometry intact")
            var size = Array(before.suffix(2))
            size[index - 2] += 40
            try #require(try write(id, "AXSize", size) == 0)
            var expected = before
            expected[index] = limit
            try requireFinalState("the next AXSize write clamps to the new maximum \(dimension.lowercased())") {
                try native().roots.first { $0.id == id }.map { desktop.near($0.frame, expected) } == true
            }
        }
    }

    @Test("termination-activation-order: promotion before termination delivery sees a dead process", contract(.terminationActivationOrder))
    func terminationActivationOrder() throws {
        _ = try fixture.open()
        try desktop.activate()
        try native("metadata")
        try native("lifecycleStart")
        for crash in [false, true] {
            let target = try other(), pid = target.pid
            _ = try target.open()
            try desktop.activate(target)
            try native("metadata", session: target)
            try requireFinalState("the target activation notification precedes termination") {
                try native("lifecycle").lifecycle?.contains { $0.knownPID == pid && $0.name == "NSWorkspaceDidActivateApplicationNotification" } == true
            }
            let offset = try native("lifecycle").lifecycle?.count ?? 0
            if crash { kill(pid, SIGKILL) } else { try target.command("quit") }
            try requireFinalState("the terminated fixture exits") { kill(pid, 0) != 0 }
            target.disconnect()
            harness.otherFixtures.removeAll { $0 === target }
            try requireFinalState("native promotion and termination notifications arrive") {
                let events = Array((try native("lifecycle").lifecycle ?? []).dropFirst(offset))
                return events.contains { $0.knownPID == pid && $0.name == "NSWorkspaceDidTerminateApplicationNotification" }
                    && events.contains { $0.knownPID == fixture.pid && $0.name == "NSWorkspaceDidActivateApplicationNotification" }
            }
            let events = Array((try native("lifecycle").lifecycle ?? []).dropFirst(offset))
            let terminated = try #require(events.firstIndex { $0.knownPID == pid && $0.name == "NSWorkspaceDidTerminateApplicationNotification" })
            let promotions = events.prefix(terminated).filter { $0.knownPID == fixture.pid && $0.name == "NSWorkspaceDidActivateApplicationNotification" }
            print("Termination activation: crash=\(crash), promotions before termination delivery=\(promotions.count)")
            for event in promotions {
                let alive = try #require(event.alivePIDs)
                try #require(!alive.contains(pid) && alive.contains(fixture.pid), "promotion before lifecycle delivery must not precede process exit (crash=\(crash))")
            }
        }
    }

    @Test("native-tab-publication: a retained bar identifies the successor independently of list and focus publication", contract(.nativeTabPublication))
    func nativeTabPublication() throws {
        let ids = try nativeTabs(), bar = try #require(try window(ids[0]).bar)
        let cover = try other()
        _ = try cover.open()
        var former = ids[0], delayedSuccessors = 0
        for index in [1, 2, 0] {
            try desktop.activate(cover)
            try fixture.command("tab", ["key": "tabs\(index)"])
            try requireFinalState("the retained native bar identifies the new front") {
                let state = try publication(ids, bar: bar, former: former, selected: ids[index])
                let owner = try native("barOwner", ["bar": bar])
                if owner.window?.id == ids[index] && state.focusedError == -25212
                    && state.roots.contains(where: { $0.id == former && $0.bar == nil }) { delayedSuccessors += 1 }
                return owner.readError == 0 && owner.window?.id == ids[index] && owner.window?.bar == bar
            }
            let retired = try native("retained", ["id": former]).window
            try #require(retired?.bar == nil, "the former root loses the bar when its successor is selected")
            former = ids[index]
        }
        print("Native tab publication: retained-bar successors with delayed list and focus=\(delayedSuccessors)")
    }

    @Test("deferred-ax-activation: accepted main and raise requests allow an unconfirmed activation", contract(.deferredAXActivation))
    func deferredAXActivation() throws {
        let id = try fixture.open()
        try desktop.activate()
        _ = try window(id)
        let cover = try other()
        _ = try cover.open()
        try desktop.activate(cover)
        let activation = try native("activateAX")
        try #require(activation.result == 0 && activation.readError == 0 && activation.frontmost != nil)
        let pending = activation.frontmost == false
        print("Deferred activation: first accepted request pending=\(pending)")
        for attribute in ["AXMain", "AXRaise"] {
            try #require(try write(id, attribute) == 0)
            let state = try native()
            try #require(state.focused?.id == id && state.roots.first?.main == true)
            if pending { try #require(state.frontmost == false, "main and raise must not complete the modeled pending activation") }
        }
        try cover.command("yieldActivation", ["pid": fixture.pid])
        try #require(try native("activateAX").result == 0)
        try expectFocus(id)
    }

    @Test("minimize-focus-interruption: a main or raise request can cancel the unfinished Dock operation", contract(.minimizeFocusInterruption), arguments: ["AXMain", "AXRaise"])
    func minimizeFocusInterruption(_ attribute: String) throws {
        _ = try fixture.open(key: "sibling")
        let id = try fixture.open(kind: "minimize")
        try desktop.activate()
        _ = try window(id)
        try fixture.command("minimize")
        try #require(try native("retained", ["id": id]).window?.minimized == true, "the same native window must minimize without interruption")
        try fixture.command("restore")
        let baseline = try #require(try fixture.command("ping").minimizeEvents?["window"])
        try #require(baseline.contains { $0.name == "NSWindowDidMiniaturizeNotification" && $0.minimized }
            && baseline.contains { $0.name == "NSWindowDidDeminiaturizeNotification" && !$0.minimized }, "the native notification recorder must witness the control operation")
        let offset = baseline.count
        let began = try fixture.command("minimize", ["waitForTransition": false])
        let alreadyMinimized = try #require(began.miniaturized?["window"])
        let write = try native("write", ["id": id, "attribute": attribute])
        try #require(write.result == 0 || write.result == -25204, "a Dock transition must return a modeled AX write outcome")
        let returnedAt = try #require(write.writeReturnedAt)
        // A cancelled request need not notify completion. Let the Dock finish
        // another real request before checking the interrupted window.
        try fixture.command("minimize", ["key": "sibling"])
        let events = Array((try #require(try fixture.command("ping").minimizeEvents?["window"])).dropFirst(offset))
        print("Minimize \(attribute): " + events.map { "\($0.name)(minimized=\($0.minimized))" }.joined(separator: " -> "))
        let state = try native()
        // These stamps establish cross-process order, never a latency budget.
        let completed = events.filter { $0.name == "NSWindowDidMiniaturizeNotification" && $0.minimized }
        let finishedBeforeReply = completed.contains { $0.sampledAt <= returnedAt }
        if write.result == 0 && !alreadyMinimized && !finishedBeforeReply {
            try #require(completed.isEmpty, "the accepted AX request returned before native minimization completed instead of cancelling it")
            try #require(state.focused?.id == id && state.visible.contains(id) && state.roots.first { $0.id == id }?.minimized == false)
            print("Minimize \(attribute): accepted pending request cancelled native minimization")
        } else {
            try #require(state.roots.first { $0.id == id }?.minimized == true && !state.visible.contains(id), "an unanswered AX request or earlier completion must leave native minimization intact")
            print("Minimize \(attribute): completion won or AX returned cannotComplete; cancellation path not observed")
        }
    }

    private func nativeTabs() throws -> [UInt32] {
        let reply = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
        let ids = try (0..<3).map { try #require(reply.windows["tabs\($0)"]) }
        try desktop.activate(key: "tabs0")
        for index in [1, 2, 0] {
            try fixture.command("tab", ["key": "tabs\(index)"])
            _ = try window(ids[index])
        }
        return ids
    }

    private func publication(_ ids: [UInt32], bar: Int, former: UInt32, selected: UInt32) throws -> NativeContractReply {
        let state = try native("publication", ["ids": ids])
        try #require(state.listError == 0 || state.listError == -25204)
        try #require(state.focusedError == 0 || state.focusedError == -25212 || state.focusedError == -25204)
        try #require(Set(state.roots.map(\.id)).isSubset(of: [0, former, selected]))
        if let focused = state.focused { try #require(focused.id == former || focused.id == selected) }
        for root in (state.retainedWindows ?? []) where root.bar != nil {
            try #require(root.bar == bar && root.tabs == ids.count, "a published native bar must preserve its AX identity")
        }
        return state
    }
}
