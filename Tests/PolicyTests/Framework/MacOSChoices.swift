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
}
