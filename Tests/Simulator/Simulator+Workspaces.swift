import Foundation
import CoreGraphics
import Ports

extension SimulatedApp {
    @MainActor package var focusedWindow: UInt32? { mac.apps[pid]?.key }
    @MainActor package func activate() { mac.activate(pid) }
    @MainActor package func selectTabInBackground(_ id: UInt32) { mac.selectBackgroundTab(id) }
    @MainActor @discardableResult package func addTab(to id: UInt32, activating: Bool = true) -> UInt32 {
        mac.addTab(to: id, activating: activating)
    }
}

extension SimulatedMac {
    @MainActor package var screenGeometry: ScreenGeometry { geometry }
    @MainActor package var visibleOrder: [UInt32] { visibleIDs() }
    @MainActor package func isMain(_ id: UInt32) -> Bool { windows[id].flatMap { apps[$0.pid]?.main } == id }

    @MainActor func activate(_ pid: Int32) {
        assume(.activationHiddenFocus)
        action("activate \(apps[pid]!.alias) without ordering windows")
        if apps[pid]?.hidden == true { visibility(pid, hidden: false, omitWindows: false) }
        front = pid
        post(.activated, pid: pid)
    }

    @MainActor func selectBackgroundTab(_ id: UInt32) {
        assume(.nativeTabIdentity)
        guard let window = windows[id], !window.closed, let group = window.group else {
            scheduler.failUnmodeled("app.selectBackgroundTab missing tab \(id)"); return
        }
        action("select background native tab window \(id)")
        groups[group]?.selected = id
        apps[window.pid]?.key = id
        apps[window.pid]?.main = id
        notify(.focusedWindowChanged, node: .application(window.pid))
        notify(.mainWindowChanged, node: .application(window.pid))
    }

    @MainActor func addTab(to id: UInt32, activating: Bool) -> UInt32 {
        assume(.nativeTabInsertion)
        guard let window = windows[id], let group = window.group else {
            scheduler.failUnmodeled("app.addTab missing group for \(id)"); return 0
        }
        nextWindow += 1
        let added = nextWindow
        windows[added] = Window(id: added, pid: window.pid, spec: window.spec, spaces: window.spaces, group: group)
        groups[group]?.windows.append(added)
        zOrder.insert(added, at: 0)
        action("add native tab window \(added) to window \(id)")
        if activating { focus(added) } else { selectBackgroundTab(added) }
        notify(.windowCreated, node: .application(window.pid))
        return added
    }
}
