import Foundation
import Darwin
import Testing

/// Issue #17: real Carbon events, independent AX frames/focus and CG visibility.
extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct FunctionalRails: AppSessionTest {
        let flow: FunctionalWorkspaces
        init() throws { flow = try FunctionalWorkspaces() }
        let config = "[experiments]\nrails = true\n"

        func enable(_ extra: String = "") throws {
            let revision = try harness.status().config.revision
            try writeConfig(config + extra)
            try #require(try eventually(within: 1) {
                let s = try harness.status()
                return s.config.revision > revision && s.workspaces?.enabled == true && s.workspaces?.layout == "rails"
            }, "rails alone must enable the rail workspace layout")
        }
        func open(_ key: String, width: Double = 0.3, session: FixtureSession? = nil) throws -> UInt32 {
            try (session ?? fixture).open(key: key, ["widthFraction": width])
        }
        func frame(_ id: UInt32) throws -> [Double] { try #require(try flow.window(id)).frame }
        func focus(_ id: UInt32, since: Double? = nil, within timeout: Double = 0.5, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let ready = try eventually(within: max(0, timeout - (since.map { monotonicSeconds() - $0 } ?? 0))) {
                let o = try flow.observe(focusedOnly: true)
                return o.visibleIDs.contains(id) && o.windows.contains { $0.id == id && $0.main && ($0.focused || o.windows.contains { $0.parent == id && $0.focused }) }
            }
            if !ready { print("Focus failure",id,"elapsed",since.map { monotonicSeconds()-$0 } as Any,try harness.status().workspaces as Any,try harness.rows(),try flow.observe()) }
            try #require(ready, "fixture \(id) must be visible, main and focused before the deadline", sourceLocation: sourceLocation)
        }
        func order(_ ids: [UInt32], rail: Int = 1, workspace: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let ready = try eventually {
                let rows = try harness.rows()
                return ids.enumerated().allSatisfy { i,id in rows.contains { $0.id == id && $0.workspace == workspace && $0.rail == rail && $0.slot == i + 1 } }
            }
            if !ready { print("Order failure", ids,try harness.status().workspaces as Any,try harness.rows()) }
            try #require(ready, "CLI rail and slot membership must match the accepted order",sourceLocation:sourceLocation)
        }
        func near(_ actual: [Double], _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(zip(actual,expected).allSatisfy { abs($0 - $1) <= 1 }, "actual \(actual), expected \(expected)", sourceLocation: sourceLocation)
        }
        func setup(_ widths: [Double] = [0.3,0.3,0.3]) throws -> [UInt32] {
            var ids: [UInt32] = []
            for (i,w) in widths.enumerated() { ids.append(try open("w\(i)", width: w)) }
            try flow.activate(key: "w0")
            try #require(try converges { $0.count == widths.count })
            try enable()
            try focus(ids[0])
            try order(ids)
            let ready = try eventually {
                let o = try flow.observe()
                return ids.allSatisfy { id in o.windows.contains { $0.id == id && abs($0.frame[3]-(o.area[3]-20)) <= 1 } }
            }
            if !ready { print("Rail setup fixture geometry:", try flow.observe()) }
            try #require(ready, "initial sizing must finish before commands are measured")
            return ids
        }
        func invariant(_ ids: [UInt32], sizes: [[Double]]) throws {
            let o = try flow.observe()
            let rows = try harness.rows()
            for (i,id) in ids.enumerated() {
                guard let w = o.windows.first(where: { $0.id == id }) else { continue }
                near(Array(w.frame[2...3]), sizes[i])
                #expect(w.frame[1] >= o.area[1] - 1)
                if w.visible {
                    #expect(w.frame[0] + w.frame[2] > o.area[0] && w.frame[0] < o.area[0] + o.area[2])
                    for other in o.windows where other.visible && other.id > id && rows.first(where: { $0.id == id })?.rail == rows.first(where: { $0.id == other.id })?.rail {
                        #expect(w.frame[0] + w.frame[2] <= other.frame[0] + 1 || other.frame[0] + other.frame[2] <= w.frame[0] + 1)
                    }
                }
            }
        }

        @Test func e01RailsOffLeavesRailHotkeysUnregistered() throws {
            let a = try open("w0")
            try flow.activate(key: "w0")
            for enabled in [false,true] {
                if enabled { try flow.enable(); try flow.expectShown(a) }
                let before = try frame(a), count = try fixture.command("ping").keyCount ?? 0
                for (code,shift) in [(4,false),(37,false),(4,true),(38,true),(40,true),(37,true)] { try flow.post(code, shift: shift) }
                #expect(try eventually { try fixture.command("ping").keyCount == count + 6 })
                near(try frame(a), before)
            }
        }
        @Test(arguments: [false,true])
        func e02EnableAndStartupKeepWidthsArrivalAndFocus(startup: Bool) throws {
            if startup { harness.stopApp() }
            let a = try open("w0", width: 0.25), b = try open("w1", width: 0.4)
            try flow.activate(key: "w0")
            let aw = try frame(a)[2], bw = try frame(b)[2]
            if startup { try writeConfig(config); try harness.startApp(fixtureReady: false) }
            else { try enable() }
            try focus(a); try order([a,b])
            let area = try flow.observe().area
            let ready = try eventually { abs(try frame(b)[3]-(area[3]-20)) <= 1 }
            if !ready { print("Initial fixture geometry",try frame(a),try frame(b),area) }
            try #require(ready)
            near(try frame(a), [area[0]+10,area[1]+10,aw,area[3]-20])
            near(try frame(b), [area[0]+20+aw,area[1]+10,bw,area[3]-20])
        }
        @Test func e02ReloadPreservesExistingWorkspaceMembershipAndClampsOversizeWidth() throws {
            let a = try open("w0"), b = try open("w1")
            try flow.activate(key: "w1"); try flow.enable(); try flow.expectShown(b)
            try flow.expectShown(b, since: flow.key(2, send: true))
            try enable(); try focus(b)
            try order([a], workspace: 1); try order([b], workspace: 2)
            #expect(try harness.status().workspaces?.active == 2)
            let area = try flow.observe().area
            #expect(try frame(b)[2] <= area[2]-20+1)
        }
        @Test(arguments: [false,true])
        func e03DisableAndQuitBringPeeksInsideAndReleaseKeys(quit: Bool) throws {
            let ids = try setup([0.6,0.6,0.6]); try focus(ids[1], since: flow.post(37))
            if quit { harness.stopApp() } else {
                try writeConfig(""); try #require(try eventually { try harness.status().workspaces?.enabled == false })
            }
            try #require(try eventually {
                let o = try flow.observe()
                return ids.allSatisfy { id in o.windows.contains { $0.id == id && $0.visible && $0.frame[0] >= o.area[0]-1 && $0.frame[0]+$0.frame[2] <= o.area[0]+o.area[2]+1 } }
            })
            let count = try fixture.command("ping").keyCount ?? 0
            try flow.post(37)
            #expect(try eventually { try fixture.command("ping").keyCount == count + 1 })
        }
        @Test(arguments: [false,true])
        func e03CrashRecoveryReturnsClosetWindows(on: Bool) throws {
            let ids = try setup([0.6,0.6,0.6])
            try #require(try eventually { try !flow.visible(ids[2]) })
            kill(harness.appPID, SIGKILL)
            try #require(eventually { !harness.appIsRunning })
            try writeConfig(on ? config : "")
            try harness.startApp(fixtureReady: false)
            if on {
                try focus(ids[0]); try focus(ids[1], since: flow.post(37)); try focus(ids[2], since: flow.post(37))
            } else { #expect(try eventually { try ids.allSatisfy { try flow.visible($0) } }) }
        }
        @Test func e04e06FittingRailFocusAndWrapNeverMoveFrames() throws {
            let ids = try setup(), before = try ids.map(frame)
            for id in [ids[1],ids[2],ids[0]] { try focus(id, since: flow.post(37)) }
            try focus(ids[2], since: flow.post(4))
            for (i,id) in ids.enumerated() { near(try frame(id),before[i]) }
        }
        @Test(arguments: ["default","alias","external"])
        func e04e20VisibleFocusPreservesManuallyMovedFrames(command: String) throws {
            let ids = try setup([0.25,0.25])
            if command == "alias" { try enable("[keys]\nalt-a = 'focus next'\n") }
            try focus(ids[1],since:flow.post(37)); try focus(ids[0],since:flow.post(4))
            var moved = try frame(ids[0]); moved[0] += 23; moved[1] += 17
            try fixture.command("move",["key":"w0","frame":moved])
            if command == "external" { try fixture.command("tab",["key":"w1"]); try focus(ids[1]) }
            else { try focus(ids[1],since:flow.post(command == "alias" ? 0 : 37)) }
            // Include the bounded external-focus decision, not just its first
            // AX focus sample, in this negative assertion.
            sleep(seconds:0.2)
            near(try frame(ids[0]),moved)
        }

        @Test func e04e18HeightConstrainedFocusPreservesManuallyMovedFrames() throws {
            let ids = try setup([0.25,0.25])
            let area = try flow.observe().area
            try fixture.command("limitHeight",["key":"w0","height":area[3]/2])
            try enable("[gaps]\nouter = 11\n")
            try #require(try eventually {
                try frame(ids[0])[3] <= area[3]/2+1 && harness.row(ids[0])?.reason.contains("height") == true
            })
            var moved = try frame(ids[0]); moved[0] += 23; moved[1] += 17
            try fixture.command("move",["key":"w0","frame":moved])
            try focus(ids[1],since:flow.post(37))
            sleep(seconds:0.2)
            near(try frame(ids[0]),moved)
        }

        @Test func e05e06e27RingScrollPeeksHidesWrapsAndNeverResizes() throws {
            let ids = try setup([0.45,0.45,0.45,0.45,0.45])
            let sizes = try ids.map { Array(try frame($0)[2...3]) }
            let area = try flow.observe().area
            for target in [ids[1],ids[2],ids[3],ids[4],ids[0]] {
                try focus(target, since: flow.post(37))
                try #require(try eventually { try frame(target)[0] >= area[0]+9 && frame(target)[0]+frame(target)[2] <= area[0]+area[2]-9 })
                try invariant(ids, sizes: sizes)
            }
            let a = try frame(ids[0]), next = try frame(ids[1])
            #expect(abs(a[0]+a[2] - (area[0]+area[2]-10-56)) <= 1)
            #expect(abs(next[0] - (area[0]+area[2]-56)) <= 1)
            #expect(try !flow.visible(ids[2]))
            try focus(ids[4], since: flow.post(4)); try invariant(ids, sizes: sizes)
        }
        @Test(arguments: [2,3])
        func e05ShortRingsUseOneMostVisiblePlacementAfterTheRevealTarget(count: Int) throws {
            let fraction = count == 2 ? 0.6 : 0.4
            let ids = try setup(Array(repeating:fraction,count:count))
            for id in ids.dropFirst() { try focus(id,since:flow.post(37)) }
            let area = try flow.observe().area, w = try frame(ids[0])[2]
            let focusedX = area[0]+area[2]-10-56-w
            let nextRight = focusedX+w+10
            let nextLeft = nextRight-Double(count)*(w+10)
            try #require(nextLeft+w-area[0]>56,"the worked short ring must expose more of its next neighbor on the left")
            try #require(try eventually {
                let target = try frame(ids.last!), next = try frame(ids[0])
                return abs(target[0]-focusedX)<=1 && abs(next[0]-nextLeft)<=1
            })
            #expect(try flow.visible(ids[0]))
            try invariant(ids,sizes:Array(repeating:[w,area[3]-20],count:count))
        }

        @Test func e05WideWindowIsCenteredAndSingleWindowIsStable() throws {
            let ids = try setup([0.3,1.0])
            try focus(ids[1], since: flow.post(37))
            let area = try flow.observe().area, f = try frame(ids[1])
            #expect(abs(f[0]+f[2]/2 - (area[0]+area[2]/2)) <= 1)
            try focus(ids[1], since: flow.post(38, shift: true))
            let before = try frame(ids[1])
            for (c,s) in [(37,false),(4,false),(38,false),(37,true),(38,true)] { try flow.post(c, shift: s) }
            sleep(seconds: 0.2); near(try frame(ids[1]),before)
            #expect(try harness.row(ids[1])?.rail == 2)
        }
        @Test func e07e08ElevatorRemembersWindowAndEveryXAndStopsAtEnds() throws {
            let ids = try setup([0.45,0.45,0.45,0.45])
            try focus(ids[0], since: flow.post(38, shift: true))
            try order([ids[0]],rail: 2)
            try focus(ids[3], since: flow.post(40))
            try focus(ids[1], since: flow.post(37))
            try focus(ids[2], since: flow.post(37))
            let before = try ids.dropFirst().map(frame)
            try focus(ids[0], since: flow.post(38))
            #expect(try !flow.visible(ids[2]))
            try focus(ids[2], since: flow.post(40))
            for (i,id) in ids.dropFirst().enumerated() { near(try frame(id), before[i]) }
            try flow.post(40); try focus(ids[2]); #expect(try harness.status().workspaces?.rail == 1)
            try focus(ids[0], since: flow.post(38)); try flow.post(38); try focus(ids[0])
            #expect(try harness.status().workspaces?.rail == 2)
        }
        @Test func e09HorizontalMovesSwapAndWrapKeepingFocusAndWidths() throws {
            let ids = try setup(), widths = try ids.map { try frame($0)[2] }
            try focus(ids[0], since: flow.post(37,shift: true)); try order([ids[1],ids[0],ids[2]])
            try focus(ids[0], since: flow.post(4,shift: true)); try order(ids)
            try focus(ids[0], since: flow.post(4,shift: true)); try order([ids[2],ids[1],ids[0]])
            for (i,id) in ids.enumerated() { #expect(abs(try frame(id)[2]-widths[i]) <= 1) }
        }
        @Test func e10e11VerticalMovesInsertAfterMemoryCreateRailsAndRemoveEmptyOnes() throws {
            let ids = try setup()
            try focus(ids[0],since: flow.post(38,shift: true)); try order([ids[0]],rail: 2)
            try focus(ids[2],since: flow.post(40))
            try focus(ids[2],since: flow.post(38,shift: true)); try order([ids[0],ids[2]],rail: 2)
            try focus(ids[2],since: flow.post(40,shift: true)); try order([ids[1],ids[2]])
            try focus(ids[2],since: flow.post(40,shift: true)); try order([ids[2]])
            try focus(ids[1],since: flow.post(38)); try focus(ids[1],since: flow.post(38,shift: true))
            try order([ids[0],ids[1]],rail: 2)
            try order([ids[2]],rail: 1)
        }
        @Test func e12e13ArrivalsAnchorPreviousAndCloseSelectsLeftClosingTheGap() throws {
            let ids = try setup([0.22,0.22])
            let before = try frame(ids[0]), c = try open("new",width: 0.22)
            try focus(c); try order([ids[0],c,ids[1]])
            near(try frame(ids[0]),before)
            let left = try frame(ids[0])
            try fixture.command("close",["key":"new"]); try focus(ids[0]); try order(ids)
            near(try frame(ids[0]),left)
            #expect(abs(try frame(ids[1])[0] - (left[0]+left[2]+10)) <= 1)
            try fixture.command("close",["key":"w0"]); try focus(ids[1])
            let start = monotonicSeconds(); try fixture.command("close",["key":"w1"]); try flow.expectEmpty(since: start)
        }
        @Test(arguments: [2,3,5,8])
        func e13CoalescedClosuresSelectASurvivingLeftNeighbor(closedCount: Int) throws {
            let ids = try setup(Array(repeating:min(0.22,0.8/Double(closedCount+1)),count:closedCount+1))
            for id in ids.dropFirst().dropLast() { try focus(id,since:flow.post(37)) }
            kill(harness.appPID,SIGSTOP)
            do {
                defer { kill(harness.appPID,SIGCONT) }
                let indices = Array(0..<closedCount)
                for index in closedCount.isMultiple(of:2) ? indices : indices.reversed() {
                    try fixture.command("close",["key":"w\(index)"])
                }
            }
            try focus(ids.last!); try order([ids.last!])
            sleep(seconds:0.2)
            try focus(ids.last!)
            // AppKit can focus the survivor even if tessel forgot its own
            // selection. Sending proves that the logical focus also survived.
            try flow.key(2,send:true)
            try order([ids.last!],workspace:2)
        }

        @Test func e14e15SendingFollowsInsertsAfterMemoryAndWorkspaceRestoresRail() throws {
            let ids = try setup()
            try focus(ids[0],since: flow.key(2,send: true)); try order([ids[0]],workspace: 2)
            try focus(ids[2],since: flow.key(1))
            try focus(ids[2],since: flow.key(2,send: true)); try order([ids[0],ids[2]],workspace: 2)
            try focus(ids[2],since: flow.post(38,shift: true)); try order([ids[2]],rail: 2,workspace: 2)
            try #require(try eventually { abs(try frame(ids[2])[0]-10)<=1 })
            let before = try frame(ids[2])
            try focus(ids[1],since: flow.key(1)); try focus(ids[2],since: flow.key(2))
            near(try frame(ids[2]),before)
            #expect(try !flow.visible(ids[0]) && !flow.visible(ids[1]))
        }
        @Test func e16ExternalFocusSelectsHiddenRailAndOffscreenWindow() throws {
            let ids = try setup([0.45,0.45,0.45,0.45])
            try focus(ids[0],since: flow.post(38,shift: true))
            try order([ids[0]],rail:2)
            try fixture.command("tab",["key":"w2"]); try focus(ids[2])
            let followed = try eventually { try harness.status().workspaces?.rail == 1 }
            if !followed { print("External failure",try harness.status().workspaces as Any,try harness.rows()) }
            try #require(followed)
            try fixture.command("tab",["key":"w0"]); try focus(ids[0])
            #expect(try eventually { try harness.status().workspaces?.rail == 2 })
            try focus(ids[2],since: flow.post(40))
            try focus(ids[3],since: flow.post(37))
            try focus(ids[0],since: flow.post(38))
            try focus(ids[0],since: flow.key(3,send: true))
            try focus(ids[3],since: flow.key(1))
            try fixture.command("tab",["key":"w0"]); try focus(ids[0])
            #expect(try eventually { try harness.status().workspaces?.active == 3 })
        }
        @Test(arguments: [false,true])
        func e11e17MinimizeAndHideRestoreAfterFormerLeftNeighbor(hide: Bool) throws {
            let base = try setup([0.22,0.22,0.22])
            let other = try flow.other(), b = try open("window",width:0.22,session:other)
            let ids = [base[0],b,base[1]], d = base[2]
            try flow.activate(other); try focus(b)
            try order([ids[0],b,ids[2],d])
            try focus(ids[2],since:flow.post(37))
            try focus(b,since:flow.post(4))
            if hide {
                try other.command("hide"); try focus(ids[2])
                try other.command("show"); try flow.activate(other); try focus(b)
            } else {
                try other.command("minimize"); try focus(ids[2])
                try order([ids[0],ids[2],d])
                try other.command("restore"); try focus(b)
            }
            try order([ids[0],ids[1],ids[2],d])
            try focus(ids[1],since: flow.post(38,shift: true)); try order([ids[1]],rail:2)
            // Observe a completed activation after the same-focus move before
            // starting another native minimize/restore animation.
            try focus(ids[0],since:flow.post(40))
            try focus(d,since:flow.post(4))
            try focus(ids[1],since:flow.post(38))
            try other.command("minimize"); try focus(d)
            #expect(try harness.status().workspaces?.rail == 1)
            try other.command("restore"); try focus(ids[1]); try order([ids[0],ids[2],d,ids[1]])
        }
        @Test func e17MinimizeImmediatelyAfterExternalFocusDoesNotCancelTheNativeTransition() throws {
            let ids = try setup([0.22,0.22])
            let other = try flow.other(), b = try open("window",width:0.22,session:other)
            try flow.activate(other); try focus(b)
            try order([ids[0],b,ids[1]])
            try focus(ids[1],since:flow.post(37))
            try flow.activate(other); try focus(b)
            try other.command("minimize")
            try focus(ids[1])
            try other.command("restore"); try focus(b)
        }

        @Test func e12FirstWindowOfANewBackgroundAppInsertsAfterFocusAndTakesFocus() throws {
            let ids = try setup([0.22,0.22])
            kill(harness.appPID,SIGSTOP)
            let other: FixtureSession, b: UInt32
            do {
                defer { kill(harness.appPID,SIGCONT) }
                other = try flow.other()
                b = try open("window",width:0.22,session:other)
            }
            try focus(b); try order([ids[0],b,ids[1]])
            try focus(ids[1],since:flow.post(37))
        }

        @Test(arguments: ["minimize","hide","close"])
        func e11e17EmptyRailUsesRecentFocusForMinimizeOrHideAndAdjacentRailForClose(operation: String) throws {
            let ids = try setup([0.22,0.22])
            let other = try flow.other(), middle = try open("window",width:0.22,session:other)
            try flow.activate(other); try focus(middle)
            // AppKit can focus the newly opened window before the catalog has
            // inserted it. Establish its rail membership before moving focus.
            try order([ids[0],middle,ids[1]])
            try focus(middle,since:flow.post(38,shift:true)); try order([middle],rail:2)
            try focus(ids[0],since:flow.post(40))
            try focus(ids[1],since:flow.post(37))
            try focus(ids[1],since:flow.post(38,shift:true)); try order([middle,ids[1]],rail:2)
            try focus(ids[1],since:flow.post(38,shift:true)); try order([ids[1]],rail:3)
            try focus(middle,since:flow.post(40))
            try focus(ids[0],since:flow.post(40))
            try flow.activate(other); try focus(middle)
            try #require(try eventually { try harness.status().workspaces?.rail == 2 })
            try other.command(operation)
            try focus(operation == "close" ? ids[1] : ids[0])
            try order([ids[0]],rail:1); try order([ids[1]],rail:2)
        }

        @Test func e11TerminatingTheFocusedAppsOnlyRailSelectsTheRailBelow() throws {
            let ids = try setup([0.22,0.22])
            let other = try flow.other(), middle = try open("window",width:0.22,session:other)
            try focus(middle); try order([ids[0],middle,ids[1]])
            try focus(middle,since:flow.post(38,shift:true)); try order([middle],rail:2)
            try focus(ids[0],since:flow.post(40))
            try focus(ids[1],since:flow.post(37))
            try focus(ids[1],since:flow.post(38,shift:true)); try order([middle,ids[1]],rail:2)
            try focus(ids[1],since:flow.post(38,shift:true)); try order([ids[1]],rail:3)
            try focus(middle,since:flow.post(40))
            try focus(ids[0],since:flow.post(40))
            let dialog = try fixture.open(kind:"dialog",key:"dialog"); try focus(dialog)
            try flow.activate(other); try focus(middle)
            try #require(try eventually { try harness.status().workspaces?.rail == 2 })
            other.stop()
            harness.otherFixtures.removeAll { $0.pid == other.pid }
            try focus(ids[1])
            try order([ids[0]],rail:1); try order([ids[1]],rail:2)
        }

        @Test func e18HeightAndWidthConstraintsRemainTiledAndExplained() throws {
            let ids = try setup([0.3])
            let area = try flow.observe().area
            try fixture.command("limitHeight",["key":"w0","height":area[3]/2])
            // A gap reload is a layout operation, without changing width.
            try enable("[gaps]\nouter = 11\n")
            try #require(try eventually { try frame(ids[0])[3] <= area[3]/2+1 })
            #expect(abs(try frame(ids[0])[1] - (area[1]+11)) <= 1)
            #expect(try eventually { try harness.row(ids[0])?.reason.contains("height") == true && harness.row(ids[0])?.rail == 1 })
            let b = try fixture.open(kind: "maxWidth",key: "limited")
            try focus(b); #expect(try frame(b)[2] <= 481); #expect(try harness.row(b)?.rail == 1)
        }
        @Test func e19DialogsSheetsAndFullscreenKeepWorkspaceRules() throws {
            let ids = try setup([0.3])
            let d = try fixture.open(kind:"dialog",key:"dialog"), before = try frame(d)
            try focus(d); near(try frame(d),before)
            #expect(try harness.row(d)?.rail == nil && harness.row(d)?.workspace == 1)
            let payload = try JSONSerialization.jsonObject(with:harness.invoke("windows","--json").outputData) as? [[String:Any]]
            let dialog = try #require(payload?.first { ($0["id"] as? UInt32) == d })
            #expect(dialog["rail"] is NSNull && dialog["slot"] is NSNull)
            try focus(d,since: flow.key(2,send:true)); near(try frame(d),before)
            try focus(ids[0],since: flow.key(1))
            let sheet = try fixture.open(kind:"sheet",key:"sheet")
            let parent = try #require(try fixture.command("ping").windows["sheetParent"])
            try focus(parent)
            try focus(parent,since: flow.key(3,send:true))
            #expect(try flow.visible(sheet)); #expect(try harness.row(sheet)?.rail == nil)
            try fixture.command("close",["key":"sheet"])
            try fixture.command("fullscreen",["key":"sheetParent"])
            #expect(try eventually(within:1) { try harness.row(parent)?.state == "fullscreen" && harness.row(parent)?.rail == nil && harness.row(parent)?.workspace == nil })
            try fixture.command("fullscreen",["key":"sheetParent"])
        }
        @Test func e19ReturningToAMixedWorkspaceRestoresTheRememberedDialog() throws {
            let ids = try setup([0.25])
            let dialog = try fixture.open(kind:"dialog",key:"dialog")
            try focus(dialog)
            let original = try frame(dialog)
            let b = try open("new",width:0.25); try focus(b)
            try focus(b,since:flow.key(2,send:true))
            try focus(dialog,since:flow.key(1))
            #expect(try flow.visible(ids[0]))
            near(try frame(dialog),original)
        }

        @Test func e19NativeTabReplacementRetainsRailSlotSizeAndRememberedFocus() throws {
            let ids = try setup([0.25,0.25])
            let group = try fixture.command("open",["kind":"tabs","key":"tabs","count":2])
            let first = try #require(group.windows["tabs0"]), next = try #require(group.windows["tabs1"])
            try focus(first); try order([ids[0],first,ids[1]])
            let before = try frame(first)
            try focus(first,since:flow.post(38,shift:true)); try order([first],rail:2)
            try focus(ids[0],since:flow.post(40))
            try fixture.command("tab",["key":"tabs1"])
            try focus(next); try order([next],rail:2)
            #expect(try eventually { try harness.row(first) == nil })
            #expect(abs(try frame(next)[2]-before[2])<=1)
            try focus(ids[0],since:flow.post(40)); try focus(ids[1],since:flow.post(37))
            try focus(next,since:flow.post(38))
        }

        @Test func e03FailedRailHideReturnsWindowsInsideAndReleasesHotkeys() throws {
            harness.stopApp()
            defer { harness.stopApp(); try? writeConfig("") }
            let ids = try (0..<3).map { try open("w\($0)",width:0.6) }
            try flow.activate(key:"w0")
            try writeConfig(config)
            try harness.startApp(fixtureReady:false,arguments:["--test-failed-hide"])
            try #require(try eventually(within:1) {
                let s = try harness.status().workspaces, o = try flow.observe()
                return s?.enabled == false && s?.reason == "SkyLight could not hide a window"
                    && ids.allSatisfy { id in o.windows.contains { $0.id == id && $0.visible && $0.frame[0]>=o.area[0]-1 && $0.frame[0]+$0.frame[2]<=o.area[0]+o.area[2]+1 } }
            })
            let count = try fixture.command("ping").keyCount ?? 0
            try flow.post(37)
            #expect(try eventually { try fixture.command("ping").keyCount == count+1 })
        }

        @Test func e20ManualMoveWaitsForRenderAndE21ResizeAdoptsOnlyNewWidth() throws {
            let ids = try setup([0.25,0.25,0.25]), originals = try ids.map(frame)
            var moved = originals[1]; moved[0] += 23; moved[1] += 17
            try fixture.command("move",["key":"w1","frame":moved]); sleep(seconds:0.2)
            near(try frame(ids[1]),moved)
            // Redraw on a new arrival restores the manual position.
            let d = try open("new",width:0.15); try focus(d)
            try #require(try eventually { abs(try frame(ids[1])[1]-originals[1][1]) <= 1 })
            let before = try frame(ids[1]); var resized = before; resized[2] -= 40
            try fixture.command("move",["key":"w1","frame":resized])
            try #require(try eventually { abs(try frame(ids[2])[0] - (resized[0]+resized[2]+10)) <= 1 })
            #expect(abs(try frame(ids[2])[2]-originals[2][2]) <= 1)
            #expect(abs(try frame(ids[1])[2]-resized[2]) <= 1)
        }
        @Test func e22HungAppDoesNotBlockHealthyScrollElevatorOrCLI() throws {
            let ids = try setup([0.45,0.45,0.45])
            let hung = try flow.other(), h = try open("window",width:0.4,session:hung)
            try flow.activate(hung); try focus(h)
            // Walk right from H through the responsive windows. This establishes
            // tessel's logical selection before the app is deliberately hung.
            try focus(ids[1],since:flow.post(37))
            try focus(ids[2],since:flow.post(37))
            try focus(ids[2],since: flow.post(38,shift:true)); try order([ids[2]],rail:2)
            try hung.command("hang")
            try focus(ids[1],since: flow.post(40),within:0.5)
            // The first left selects the hung neighbor; a second left must
            // still reach the responsive app without waiting for that queue.
            try flow.post(4)
            try focus(ids[0],since: flow.post(4),within:0.5)
            #expect(try harness.invoke("status","--json").status == 0)
            #expect(try harness.invoke("windows","--json").status == 0)
            try focus(ids[2],since: flow.post(38),within:0.5)
        }
        @Test func e23CommandsDefaultsOverridesAndInvalidLinePreserveBindings() throws {
            let ids = try setup()
            let keys = try #require(try harness.status().workspaces).keys
            for (chord,command) in ["alt-h":"focus left","alt-j":"focus down","alt-k":"focus up","alt-l":"focus right","alt-shift-h":"move left","alt-shift-j":"move down","alt-shift-k":"move up","alt-shift-l":"move right"] { #expect(keys[chord] == command) }
            #expect(!keys.values.contains("focus next") && !keys.values.contains("focus previous"))
            try enable("[keys]\nalt-a = 'focus next'\nalt-b = 'focus previous'\nalt-c = 'move down'\n")
            try focus(ids[1],since:flow.post(0)); try focus(ids[0],since:flow.post(11)); try focus(ids[0],since:flow.post(8))
            try writeConfig(config+"[keys]\nalt-a = 'move sideways'\n")
            #expect(try eventually { try harness.status().config.error?.line == 4 })
            let message = try #require(try harness.status().config.error).message
            #expect(message.contains("focus next|previous|left|right|up|down"))
            #expect(message.contains("move left|right|up|down"))
            #expect(try harness.status().workspaces?.keys["alt-c"] == "move down")
        }
        @Test func e24e25CLIHasRailSlotLayoutAndAXLabelTracksElevator() throws {
            let ids = try setup()
            try focus(ids[0],since:flow.post(38,shift:true)); try order([ids[0]],rail:2)
            #expect(try harness.status().workspaces?.rail == 2)
            #expect(try harness.status().workspaces?.layout == "rails")
            try #require(try eventually { try harness.observer.command("menu",["pid":harness.appPID,"open":false,"expected":"Workspace 1, rail 2 of 2","suffix":true]).menuContains == true })
            let start = try flow.post(40)
            try #require(try eventually(within:max(0,flow.budget-(monotonicSeconds()-start))) { try harness.observer.command("menu",["pid":harness.appPID,"open":false,"expected":"Workspace 1, rail 1 of 2","suffix":true]).menuContains == true })
            let result = try harness.invoke("windows","--json")
            #expect(!result.output.contains("Fixture w")); #expect(!result.output.contains("\"title\""))
        }
        @Test func e28RailLatencyCalibrationMeasuresTwentyScrollsAndElevatorTrips() throws {
            let ids = try setup([0.45,0.45,0.45,0.45,0.45])
            try focus(ids[0],since:flow.post(38,shift:true)); try order([ids[0]],rail:2)
            try focus(ids[4],since:flow.post(40))
            try focus(ids[1],since:flow.post(37))
            try focus(ids[2],since:flow.post(37))
            try focus(ids[0],since:flow.post(38))
            let area = try flow.observe().area
            let w = try frame(ids[0])[2], step = w+10
            let right = area[0]+area[2]-10-56-w
            var samples: [UInt64] = []
            for i in 0..<20 {
                let elevator = i % 4 == 0 || i % 4 == 3
                let slot = (1+(i/4)*2+(elevator ? 0 : i%4))%4
                let target = i%4 == 3 ? ids[0] : ids[slot+1]
                let start = try flow.post(i%4 == 0 ? 40 : i%4 == 3 ? 38 : 37)
                let complete = try eventually(within:max(0,0.2-(monotonicSeconds()-start))) {
                    let o = try flow.observe()
                    guard o.windows.contains(where: { $0.id == target && $0.focused && $0.main && $0.visible }) else { return false }
                    if i%4 == 3 {
                        guard let tile = o.windows.first(where: { $0.id == ids[0] }) else { return false }
                        return zip(tile.frame,[area[0]+10,area[1]+10,w,area[3]-20]).allSatisfy { abs($0-$1)<=1 }
                            && Set(ids.dropFirst()).isDisjoint(with:o.visibleIDs)
                    }
                    // Worked ring: focus at the right reveal edge, previous one
                    // step left, next one step right, opposite two steps left.
                    let offsets = [0.0,step,-2*step,-step]
                    return ids.dropFirst().enumerated().allSatisfy { index,id in
                        let expectedX = right+offsets[(index-slot+4)%4]
                        let visible = expectedX+w>area[0] && expectedX<area[0]+area[2]
                        guard o.visibleIDs.contains(id) == visible else { return false }
                        guard visible else { return true }
                        guard let tile = o.windows.first(where: { $0.id == id }) else { return false }
                        return zip(tile.frame,[expectedX,area[1]+10,w,area[3]-20]).allSatisfy { abs($0-$1)<=1 }
                    } && !o.visibleIDs.contains(ids[0])
                }
                if !complete { print("Latency failure",i,target,slot,try flow.observe(),try harness.status().workspaces as Any) }
                try #require(complete,"scroll/elevator must finish all destination geometry, visibility and focus within 200 ms")
                samples.append(UInt64((monotonicSeconds()-start)*1e9))
            }
            let maximum = samples.max()!
            let result: [String:Any] = ["measurements":samples,"nanoseconds":min(200_000_000,maximum*3),"sourceRun":ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? "local"]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appending(path:".work/rails-calibration.json"))
            let budgetFile = root.appending(path:"Tests/Acceptance/rails-budget.json")
            if FileManager.default.fileExists(atPath:budgetFile.path) {
                struct Budget: Decodable { let measurements:[UInt64]; let nanoseconds:UInt64; let sourceRun:String }
                let budget = try JSONDecoder().decode(Budget.self,from:Data(contentsOf:budgetFile))
                #expect(budget.measurements.count == 20 && UInt64(budget.sourceRun) != nil && budget.nanoseconds == min(200_000_000,(budget.measurements.max() ?? 0)*3))
                #expect(samples.allSatisfy { $0 <= budget.nanoseconds })
            } else { print("Rails E28: initial calibration pending the authorized xcode-27 run; 200 ms cap verified") }
        }
        @Test(.enabled(if:ProcessInfo.processInfo.environment["TESSEL_CAPTURE_WORKSPACES"] == "1","local E26 visual capture"))
        func captureRailsStatusItem() throws {
            let ids = try setup()
            try focus(ids[0],since:flow.post(38,shift:true))
            let directory = root.appending(path:".work/captures")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try focus(ids[2],since:flow.post(40))
            for (rail,code) in [(2,38),(1,40)] {
                let name = "E26-workspace-1-rail-\(rail)"
                let source = harness.configFile.deletingLastPathComponent().appending(path:"ui-captures/\(name).png")
                try? FileManager.default.removeItem(at:source)
                try flow.post(code)
                try #require(try eventually { try harness.observer.command("menu",["pid":harness.appPID,"open":false,"expected":"Workspace 1, rail \(rail) of 2","suffix":true]).menuContains == true })
                let data = try #require(eventualValue(within:1) { FileManager.default.contents(atPath:source.path) })
                try data.write(to:directory.appending(path:name+".png"))
            }
        }
    }
}
