import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailReload {
    @Test("#17 E16: a layout/gap reload preserves unpublished cross-app dialog focus and its send intent", arguments: [false, true], ["layout", "gaps", "both"])
    func delayedDialog(rails: Bool, change: String) {
        requireScenario(Scenario.run("cross-app reload rails=\(rails) change=\(change)") { s in
            let f = RailFixture(s, widths: [0.25]), a = f.ids[0]
            let startsInRails = change == "gaps" ? rails : !rails
            f.tessel.configure(startsInRails ? .rails : .stack); s.settle()
            let other = f.mac.launch(), dialog = other.open(WindowSpec(subrole: "AXDialog"))
            s.settle(); f.select(a)
            s.step("select dialog, then stop its AX replies before publication") { other.select(dialog); other.hang() }
            let gap = change == "layout" ? 10 : 11
            f.tessel.changeConfig("[experiments]\n\(rails ? "rails" : "workspaces") = true\n[gaps]\nouter = \(gap)\n")
            var reloaded = false, retained = false
            // Queue behind the 30 ms config debounce. AX timeouts may delay
            // this main callback; there is no deadline on the native operation.
            f.mac.scheduler.main.after(milliseconds: 31) {
                reloaded = f.tessel.status.layout == (rails ? "rails" : "stack") && f.tessel.status.gaps.outer == Double(gap)
                retained = f.mac.focusedWindow == dialog && f.mac.frontmostApp == other.pid
                other.resume()
            }
            s.settle()
            s.expect("reload completes before the publisher resumes", reloaded)
            s.expect("reload leaves the unpublished native dialog selected", retained)
            f.focus(dialog)
            s.expect("the dialog retains its original workspace", f.tessel.windows.first { $0.id == dialog }?.workspace == 1)
            f.press("send 2", focus: dialog)
            s.expect("the unpublished native selection also owns send", f.tessel.windows.first { $0.id == dialog }?.workspace == 2)
        })
    }

    @Test("#17 E16: reloading an empty workspace never reactivates Finder over delayed external activation", arguments: [false, true])
    func emptyWorkspace(rails: Bool) {
        requireScenario(Scenario.run("empty workspace reload rails=\(rails)") { s in
            let f = RailFixture(s, widths: [0.25])
            if !rails { f.tessel.configure(.stack); s.settle() }
            let other = f.mac.launch(), dialog = other.open(WindowSpec(subrole: "AXDialog"))
            s.settle(); f.focus(dialog)
            f.tessel.press("workspace 2"); s.settle()
            s.expect("setup: workspace 2 starts empty on Finder desktop", f.tessel.status.active == 2 && f.mac.frontmostApp == f.mac.finder.pid)
            s.step("activate the dialog from the desktop and stop AX replies") { other.select(dialog); other.hang() }
            f.tessel.changeConfig("[experiments]\n\(rails ? "rails" : "workspaces") = true\n[gaps]\nouter = 11\n")
            var reloaded = false, retained = false
            f.mac.scheduler.main.after(milliseconds: 31) {
                reloaded = f.tessel.status.gaps.outer == 11
                retained = f.mac.frontmostApp == other.pid && f.mac.focusedWindow == dialog
                other.resume()
            }
            s.settle()
            s.expect("the gap reload completes before focus publication", reloaded)
            s.expect("the nonfocusing reload retains the external application", retained)
            f.focus(dialog)
            s.expect("publishing external focus returns to workspace 1", f.tessel.status.active == 1)
        })
    }
}
