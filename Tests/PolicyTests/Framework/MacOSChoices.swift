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
}
