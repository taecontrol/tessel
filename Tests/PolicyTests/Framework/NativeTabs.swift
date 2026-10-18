import Foundation
import CoreGraphics
import Ports
import Simulator
import Testing

@Suite @MainActor struct NativeTabFramework {
    @Test("native tab selection retains the group's dragged, resized, or AX-written frame", arguments: [false, true])
    func sharedFrame(axWrites: Bool) {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 2)
        app.groupTabs([1, 2], selected: 1)
        let expected = CGRect(x: 81, y: 55, width: 601, height: 333)
        if axWrites {
            let ax = mac.ax
            let application = ax.application(app.pid)
            let window = ax.copy(.windows, of: application).value!.elements!.first!
            #expect(ax.set(.position, of: window, to: .point(expected.origin)) == .success)
            #expect(ax.set(.size, of: window, to: .size(expected.size)) == .success)
        } else {
            app.drag(1, to: expected.origin)
            app.resize(1, to: expected.size)
        }
        app.selectTab(2)
        #expect(mac.settle() == .settled)
        #expect(mac.focusedWindow == 2)
        #expect(mac.frame(2) == expected)
    }
}
