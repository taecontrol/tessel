import CoreGraphics

extension SimulatedApp {
    @MainActor @discardableResult package func beginFullscreenTransition(_ window: UInt32, publishingRoot: Bool) -> UInt32? {
        mac.beginFullscreenTransition(window, pid: pid, publishingRoot: publishingRoot)
    }
    @MainActor package func finishFullscreenTransition(_ window: UInt32) { mac.finishFullscreenTransition(window) }
}

extension SimulatedMac {
    @MainActor func beginFullscreenTransition(_ window: UInt32, pid: Int32, publishingRoot: Bool) -> UInt32? {
        assume(.transientWindowLists)
        guard let source = windows[window], source.pid == pid, !source.closed, fullscreenRoots[window] == nil else {
            scheduler.failUnmodeled("app.beginFullscreenTransition invalid window \(window)"); return nil
        }
        action("window \(window) begins fullscreen transition, auxiliary root=\(publishingRoot)")
        guard publishingRoot else { return nil }
        nextWindow += 1
        let id = nextWindow
        let frame = CGRect(x: geometry.frame.minX, y: 0, width: geometry.frame.width, height: geometry.frame.height)
        windows[id] = Window(id: id, pid: pid, spec: WindowSpec(frame: frame, subrole: "AXUnknown", resizable: false), spaces: [active])
        fullscreenRoots[window] = id
        zOrder.insert(id, at: 0)
        notify(.layoutChanged, node: .application(pid))
        return id
    }

    @MainActor func finishFullscreenTransition(_ window: UInt32) {
        assume(.transientWindowLists)
        action("window \(window) finishes fullscreen transition")
        guard let id = fullscreenRoots.removeValue(forKey: window), let root = windows[id] else { return }
        windows[id]?.closed = true
        zOrder.removeAll { $0 == id }
        notify(.layoutChanged, node: .application(root.pid))
    }
}
