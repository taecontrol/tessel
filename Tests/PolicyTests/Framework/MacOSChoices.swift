import CoreGraphics
import Ports
import Simulator
import Testing

@Suite @MainActor struct MacOSChoices {
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
        let root = app.beginFullscreenTransition(1, publishingRoot: publishingRoot)
        let ax = mac.ax, application = ax.application(app.pid)
        for _ in 0..<2 {
            let roots = try #require(ax.copy(.windows, of: application).value?.elements)
            #expect(roots.count == (publishingRoot ? 2 : 1))
            if let root {
                let handle = try #require(roots.first { ax.windowID($0).value == root })
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
    }
}
