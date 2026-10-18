import CoreGraphics
import Ports
import Simulator
import Testing

private final class NativeRootEvents: @unchecked Sendable {
    var names: [AXNotification] = []
    var destroyed: [AXElement] = []
}

@Suite @MainActor struct MacOSChoices {
    @Test("survivor activation can precede process exit while the dying app's windows are gone", arguments: TerminationExitOrder.allCases, [false, true])
    func termination(_ exitOrder: TerminationExitOrder, _ automaticNotice: Bool) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let survivor = mac.launch(windows: 1), dying = mac.launch(windows: 1)
        let ax = mac.ax, application = ax.application(dying.pid)
        let window = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        #expect(mac.settle() == .settled)
        var promotions: [Bool] = [], terminations: [Bool] = []
        let observation = mac.applications.observe { event, app in
            if event == .activated && app.pid == survivor.pid { promotions.append(mac.applications.isAlive(dying.pid)) }
            if event == .terminated && app.pid == dying.pid { terminations.append(mac.applications.isAlive(dying.pid)) }
        }
        dying.terminate(activating: 1, crash: true, publishesNotification: automaticNotice, exitOrder: exitOrder)
        #expect(mac.applications.isAlive(dying.pid) == (exitOrder == .afterPromotion))
        #expect(ax.copy(.role, of: window).status == .invalidUIElement)
        #expect(mac.windowOrder.onScreenOrder() == [1])
        #expect(mac.settle() == .settled)
        #expect(promotions == [exitOrder == .afterPromotion])
        if !automaticNotice {
            #expect(terminations.isEmpty && mac.applications.isAlive(dying.pid) == (exitOrder == .afterPromotion))
            dying.publishTermination()
            #expect(mac.settle() == .settled)
        }
        #expect(terminations == [false] && !mac.applications.isAlive(dying.pid))
        withExtendedLifetime(observation) {}
    }

    @Test("native tab insertion publishes the new root on the active desktop even from a closeted reference", arguments: [false, true])
    func nativeTabInsertion(_ closeted: Bool) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 2)
        app.groupTabs([1, 2], selected: 1)
        let ax = mac.ax, application = ax.application(app.pid)
        let reference = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        let bar = try #require(ax.copy(.children, of: reference).value?.elements?.first)
        let frame = mac.frame(1)
        let closet = mac.closetPort
        try closet.start()
        if closeted { closet.hide([1]) }
        let cover = mac.launch(windows: 1)
        let added = app.addTab(to: 1, activating: false)
        let root = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        #expect(ax.windowID(root).value == added)
        #expect(ax.copy(.children, of: root).value?.elements == [bar])
        #expect(ax.copy(.tabs, of: bar).value?.elements?.count == 3)
        #expect(mac.frame(added) == frame && app.focusedWindow == added)
        #expect(mac.frontmostApp == cover.pid && mac.isVisible(added))
        for scope in [SpaceScope.ordinary, .all] { #expect(closet.memberships(added, scope: scope) == [closet.activeSpace()]) }
        if closeted { #expect(closet.memberships(1, scope: .all) == [closet.closetSpace]) }
        #expect(mac.settle() == .settled)
    }

    @Test("pending AX activation may complete on a focus write, a native event, or the next request", arguments: DeferredActivationCompletion.allCases)
    func deferredActivation(_ completion: DeferredActivationCompletion) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        _ = mac.launch(windows: 1)
        let ax = mac.ax, application = ax.application(app.pid)
        let window = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        app.deferNextActivation(completion: completion)
        #expect(ax.set(.frontmost, of: application, to: .bool(true)) == .success)
        #expect(ax.copy(.frontmost, of: application).value?.bool == false)
        #expect(ax.set(.main, of: window, to: .bool(true)) == .success)
        #expect(ax.perform(.raise, on: window) == .success)
        #expect(ax.copy(.frontmost, of: application).value?.bool == (completion == .focusWrite))
        #expect(mac.isMain(1) && app.focusedWindow == 1)
        #expect(mac.settle() == .settled)
        #expect((mac.frontmostApp == app.pid) == (completion != .nextRequest))
        if completion == .nextRequest { #expect(ax.set(.frontmost, of: application, to: .bool(true)) == .success) }
        #expect(mac.settle() == .settled)
        #expect(mac.focusedWindow == 1 && mac.frontmostApp == app.pid)
    }

    @Test("content tab contents flatten selected pages and segmented controls expose only radio children", arguments: [ContentTabStyle.empty, .populated, .segmentedRadioGroup])
    func contentTabs(_ style: ContentTabStyle) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        app.showContentTabs(in: 1, style: style)
        let ax = mac.ax, application = ax.application(app.pid)
        let window = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        let group = try #require(ax.copy(.children, of: window).value?.elements?.first)
        let tabReply = ax.copy(.tabs, of: group), contentReply = ax.copy(.contents, of: group)
        let children = try #require(ax.copy(.children, of: group).value?.elements)
        if style == .segmentedRadioGroup {
            #expect(ax.copy(.role, of: group).value?.string == "AXRadioGroup")
            #expect(tabReply.status == .attributeUnsupported && tabReply.value == nil)
            #expect(contentReply.status == .attributeUnsupported && contentReply.value == nil)
            #expect(children.map { ax.copy(.role, of: $0).value?.string } == Array(repeating: "AXRadioButton", count: 3))
            for button in children { #expect(ax.copy(.children, of: button).status == .noValue) }
        } else {
            let tabs = try #require(tabReply.value?.elements), contents = try #require(contentReply.value?.elements)
            #expect(contents.count == (style == .empty ? 0 : 1))
            #expect(children == tabs + contents)
            #expect(tabs.allSatisfy { !contents.contains($0) })
            for tab in tabs { #expect(ax.copy(.children, of: tab).status == .noValue) }
            for content in contents { #expect(ax.copy(.role, of: content).value?.string == "AXStaticText") }
        }
        #expect(mac.settle() == .settled)
    }

    @Test("prohibited lifecycle notifications may be delivered or omitted independently", arguments: ProhibitedNotifications.allCases)
    func prohibitedLifecycle(_ notifications: ProhibitedNotifications) {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        var events: [String] = []
        let observation = mac.applications.observe { event, app in events.append("\(event):\(app.pid)") }
        let regular = mac.launch()
        let prohibited = mac.launch(prohibited: true, prohibitedNotifications: notifications)
        #expect(mac.applications.runningApplications.contains { $0.pid == prohibited.pid && $0.prohibited && !$0.terminated })
        #expect(mac.applications.isAlive(prohibited.pid))
        #expect(mac.settle() == .settled)
        regular.quit(); prohibited.quit()
        #expect(mac.settle() == .settled)
        var expected = ["launched:\(regular.pid)"]
        if [.delivered, .launchOnly].contains(notifications) { expected.append("launched:\(prohibited.pid)") }
        expected.append("terminated:\(regular.pid)")
        if [.delivered, .terminationOnly].contains(notifications) { expected.append("terminated:\(prohibited.pid)") }
        #expect(events == expected)
        #expect(!mac.applications.isAlive(prohibited.pid))
        withExtendedLifetime(observation) {}
    }

    @Test("attached sheets expose unsupported main, minimized and fullscreen attributes")
    func sheetAttributes() throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let id = app.open(WindowSpec(parent: 1))
        let ax = mac.ax, application = ax.application(app.pid)
        let parent = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        let sheet = try #require(ax.copy(.children, of: parent).value?.elements?.first)
        #expect(ax.windowID(sheet).value == id)
        #expect(ax.copy(.focusedWindow, of: application).value?.element == sheet)
        #expect(ax.copy(.main, of: parent).value?.bool == true)
        for attribute in [AXAttribute.main, .minimized, .fullscreen] {
            let result = ax.copy(attribute, of: sheet)
            #expect(result.status == .attributeUnsupported)
            #expect(result.value == nil)
        }
        #expect(mac.settle() == .settled)
    }

    @Test("fullscreen transitions may publish a live auxiliary root until the app completes the transition", arguments: [false, true])
    func fullscreenRoot(_ publishingRoot: Bool) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let ax = mac.ax, application = ax.application(app.pid)
        let events = NativeRootEvents()
        let observer = try #require(ax.observer(app.pid) { notification, element in
            events.names.append(notification)
            if notification == .destroyed { events.destroyed.append(element) }
        }.value)
        observer.start()
        #expect(observer.add(.windowCreated, to: application) == .success)
        let root = app.beginFullscreenTransition(1, publishingRoot: publishingRoot)
        var observedRoot: AXElement?
        for _ in 0..<2 {
            let roots = try #require(ax.copy(.windows, of: application).value?.elements)
            #expect(roots.count == (publishingRoot ? 2 : 1))
            if let root {
                let handle = try #require(roots.first { ax.windowID($0).value == root })
                if observedRoot == nil {
                    #expect(observer.add(.destroyed, to: handle) == .success)
                    observedRoot = handle
                }
                #expect(ax.copy(.role, of: handle).value?.string == "AXWindow")
                #expect(ax.copy(.subrole, of: handle).value?.string == "AXUnknown")
                #expect(ax.copy(.fullscreen, of: handle).value?.bool == false)
                #expect(ax.copy(.minimized, of: handle).value?.bool == false)
                #expect(ax.copy(.main, of: handle).value?.bool == false)
                #expect(ax.isSettable(.size, of: handle).value == false)
                #expect(mac.frame(root) == CGRect(x: 0, y: 0, width: 1024, height: 768))
                #expect(mac.focusedWindow == 1)
                #expect(mac.isVisible(root))
            }
        }
        app.enterFullscreen(1)
        app.finishFullscreenTransition(1)
        #expect(ax.copy(.windows, of: application).value?.elements?.count == 1)
        #expect(mac.settle() == .settled)
        #expect(events.names == (publishingRoot ? [.windowCreated, .destroyed] : []))
        #expect(events.destroyed == observedRoot.map { [$0] } ?? [])
    }

    @Test("a successful AX position write may accept the point or retain the right-edge strip", arguments: PositionAcceptance.allCases)
    func positionAcceptance(_ acceptance: PositionAcceptance) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch()
        let id = app.open(WindowSpec(positionAcceptance: acceptance))
        let ax = mac.ax, application = ax.application(app.pid)
        let window = try #require(ax.copy(.windows, of: application).value?.elements?.first)
        let before = try #require(mac.frame(id))
        let point = CGPoint(x: 1124, y: 85)
        #expect(ax.set(.position, of: window, to: .point(point)) == .success)
        let expected = CGPoint(x: acceptance == .requested ? 1124 : 984, y: 85)
        #expect(mac.frame(id) == CGRect(origin: expected, size: before.size))
        app.drag(id, to: point)
        #expect(mac.frame(id) == CGRect(origin: point, size: before.size))
        #expect(mac.settle() == .settled)
    }

    @Test("CG membership outside the display is independent of frame intersection and excludes hidden or minimized windows", arguments: OffDisplayMembership.allCases)
    func offDisplayMembership(_ membership: OffDisplayMembership) {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let outside = app.open(WindowSpec(frame: CGRect(x: 1124, y: 60, width: 451, height: 400), offDisplayMembership: membership))
        #expect(mac.windowOrder.onScreenOrder() == (membership == .included ? [outside, 1] : [1]))
        #expect(!mac.isFullyOnScreen(outside))
        app.minimize(outside)
        #expect(mac.windowOrder.onScreenOrder() == [1])
        app.restore(outside)
        #expect(mac.windowOrder.onScreenOrder() == (membership == .included ? [outside, 1] : [1]))
        app.hide()
        #expect(mac.windowOrder.onScreenOrder().isEmpty)
        app.unhide()
        #expect(mac.windowOrder.onScreenOrder() == (membership == .included ? [outside, 1] : [1]))
        #expect(mac.settle() == .settled)
    }

    @Test("shown windows may retain closet membership until destruction without remaining hidden", arguments: [false, true])
    func closetMembership(_ retained: Bool) throws {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let sheet = app.open(WindowSpec(parent: 1))
        let closet = mac.closetPort(retainingShownMembership: retained)
        try closet.start()
        let active = closet.activeSpace(), hidden = closet.closetSpace
        closet.hide([1])
        for id in [UInt32(1), sheet] {
            #expect(closet.memberships(id, scope: .ordinary).isEmpty)
            #expect(closet.memberships(id, scope: .all) == [hidden])
            #expect(!mac.isVisible(id) && mac.isInCloset(id))
        }
        closet.show([1])
        for id in [UInt32(1), sheet] {
            #expect(closet.memberships(id, scope: .ordinary) == [active])
            #expect(Set(closet.memberships(id, scope: .all)) == (retained ? [active, hidden] : [active]))
            #expect(mac.isVisible(id) && !mac.isInCloset(id))
        }
        closet.stop(returning: [])
        for id in [UInt32(1), sheet] {
            #expect(closet.memberships(id, scope: .ordinary) == [active])
            #expect(closet.memberships(id, scope: .all) == [active])
            #expect(mac.isVisible(id))
        }
        #expect(mac.focusedWindow == sheet)
        #expect(mac.settle() == .settled)
    }
}
