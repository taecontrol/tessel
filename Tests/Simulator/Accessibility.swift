import Foundation
import CoreGraphics
import Ports

extension SimulatedMac {
    enum Node: Hashable, Sendable {
        case application(Int32), window(UInt32), bar(Int), tab(Int, Int), desktop
        case foundation(UInt32, FoundationNode)
    }
    final class Handle: AXElementIdentity, @unchecked Sendable {
        unowned let mac: SimulatedMac
        let node: Node
        var timeout: Float = 0.05
        var focusedReadJob: Int?
        init(_ mac: SimulatedMac, _ node: Node) { self.mac = mac; self.node = node }
        func isEqual(to other: any AXElementIdentity) -> Bool {
            guard let other = other as? Handle else { return false }
            return mac === other.mac && node == other.node
        }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(mac)); hasher.combine(node) }
    }
    func element(_ node: Node) -> AXElement { AXElement(Handle(self, node)) }
    func pid(_ node: Node) -> Int32? {
        switch node {
        case .application(let pid): pid
        case .window(let id): windows[id]?.pid
        case .foundation(let id, _): windows[id]?.pid
        case .bar(let group), .tab(let group, _): groups[group].flatMap { windows[$0.selected]?.pid }
        case .desktop: 10
        }
    }
    func name(_ node: Node) -> String {
        let alias = pid(node).flatMap { apps[$0]?.alias } ?? "app-unknown"
        switch node {
        case .application(let pid): return "\(alias) pid=\(pid)"
        case .window(let id): return "window \(id) \(alias)"
        case .foundation(let id, let node): return "\(node) window \(id) \(alias)"
        case .bar(let group): return "native-bar \(group) \(alias)"
        case .tab(let group, let index): return "tab \(group).\(index) \(alias)"
        case .desktop: return "desktop app-desktop"
        }
    }
    func info(_ pid: Int32) -> RunningApplication? {
        guard let app = apps[pid] else { return nil }
        return RunningApplication(pid: pid, bundleID: app.bundleID, name: app.alias, hidden: app.hidden,
                                  terminated: app.terminated, prohibited: app.prohibited)
    }

    struct Accessibility: AccessibilityPort {
        let mac: SimulatedMac
        func application(_ pid: Int32) -> AXElement {
            mac.scheduler.call("AccessibilityPort.application \(mac.apps[pid]?.alias ?? "app-unknown") pid=\(pid)")
            if mac.apps[pid] == nil { mac.scheduler.failUnmodeled("AccessibilityPort.application unknown pid=\(pid)") }
            return mac.element(.application(pid))
        }
        private func handle(_ element: AXElement, operation: String) -> Handle? {
            guard let handle = element.identity as? Handle, handle.mac === mac else {
                mac.scheduler.failUnmodeled("AccessibilityPort.\(operation) foreign element"); return nil
            }
            mac.scheduler.call("AccessibilityPort.\(operation) \(mac.name(handle.node))")
            return handle
        }
        private func unavailable(_ handle: Handle) -> AXStatus? {
            guard mac.scheduler.isActive else { return .cannotComplete }
            guard let pid = mac.pid(handle.node), let app = mac.apps[pid], !app.terminated else { return .invalidUIElement }
            if app.hung || app.busyUntil > mac.scheduler.now { return .cannotComplete }
            if case .window(let id) = handle.node, mac.windows[id]?.closed != false { return .invalidUIElement }
            return nil
        }
        private func finish(_ handle: Handle, operation: String, status: AXStatus, value: String = "", point: PausePoint? = nil) {
            mac.assume(.axReadDelivery)
            let cost = status == .cannotComplete ? max(1, Int((handle.timeout * 1_000).rounded())) : 1
            mac.scheduler.reply("AccessibilityPort.\(operation) reply \(mac.name(handle.node)) \(status)\(value.isEmpty ? "" : " " + value)",
                                cost: cost, point: point)
        }
        @discardableResult func setMessagingTimeout(_ element: AXElement, seconds: Float) -> AXStatus {
            mac.assume(.axMessagingTimeout)
            guard let handle = handle(element, operation: "setMessagingTimeout \(seconds)s") else { return .cannotComplete }
            guard mac.scheduler.isActive else { return .cannotComplete }
            handle.timeout = seconds
            finish(handle, operation: "setMessagingTimeout", status: .success)
            return .success
        }
        func copy(_ attribute: AXAttribute, of element: AXElement) -> AXResult<AXValue> {
            guard let handle = handle(element, operation: "copy \(attribute.rawValue)") else { return AXResult(.cannotComplete) }
            let result: AXResult<AXValue>
            if let error = unavailable(handle) { result = AXResult(error) }
            else { result = mac.read(attribute, node: handle.node) }
            var point: PausePoint?
            if case .application(let pid) = handle.node {
                if attribute == .focusedWindow { handle.focusedReadJob = mac.scheduler.currentJobID }
                if attribute == .frontmost {
                    if let job = mac.scheduler.currentJobID, handle.focusedReadJob == job { point = .read(pid) }
                    handle.focusedReadJob = nil
                }
            }
            finish(handle, operation: "copy \(attribute.rawValue)", status: result.status,
                   value: result.value.map(mac.describe) ?? "nil", point: point)
            return result
        }
        func set(_ attribute: AXAttribute, of element: AXElement, to value: AXValue) -> AXStatus {
            guard let handle = handle(element, operation: "set \(attribute.rawValue)=\(mac.describe(value))") else { return .cannotComplete }
            let result = unavailable(handle) ?? mac.write(attribute, node: handle.node, value: value)
            finish(handle, operation: "set \(attribute.rawValue)", status: result)
            return result
        }
        func isSettable(_ attribute: AXAttribute, of element: AXElement) -> AXResult<Bool> {
            mac.assume(.axWindowAttributes)
            guard let handle = handle(element, operation: "isSettable \(attribute.rawValue)") else { return AXResult(.cannotComplete) }
            let result: AXResult<Bool>
            if let error = unavailable(handle) { result = AXResult(error) }
            else if attribute == .size, case .window(let id) = handle.node, let window = mac.windows[id] {
                result = AXResult(.success, window.spec.resizable)
            } else {
                mac.scheduler.failUnmodeled("AccessibilityPort.isSettable \(attribute.rawValue) \(mac.name(handle.node))")
                result = AXResult(.cannotComplete)
            }
            finish(handle, operation: "isSettable \(attribute.rawValue)", status: result.status, value: result.value.map(String.init) ?? "nil")
            return result
        }
        func perform(_ action: AXAction, on element: AXElement) -> AXStatus {
            mac.assume(.axFocus)
            guard let handle = handle(element, operation: "perform \(action.rawValue)") else { return .cannotComplete }
            var status = unavailable(handle) ?? .success
            if status == .success {
                if case .window(let id) = handle.node { mac.selectFromAX(id) }
                else { mac.scheduler.failUnmodeled("AccessibilityPort.perform \(action.rawValue) \(mac.name(handle.node))"); status = .cannotComplete }
            }
            finish(handle, operation: "perform \(action.rawValue)", status: status)
            return status
        }
        func windowID(_ element: AXElement) -> AXResult<UInt32> {
            mac.assume(.axWindowAttributes)
            guard let handle = handle(element, operation: "windowID") else { return AXResult(.cannotComplete) }
            let result: AXResult<UInt32>
            if let error = unavailable(handle) { result = AXResult(error) }
            else if case .window(let id) = handle.node {
                let zero = mac.windows[id].flatMap { mac.apps[$0.pid]?.zeroIDs.contains(id) } == true
                result = AXResult(.success, zero ? 0 : id)
            } else if handle.node == .desktop { result = AXResult(.success, 0) }
            else { mac.scheduler.failUnmodeled("AccessibilityPort.windowID \(mac.name(handle.node))"); result = AXResult(.cannotComplete) }
            finish(handle, operation: "windowID", status: result.status, value: result.value.map(String.init) ?? "nil")
            return result
        }
        func observer(_ pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) -> AXResult<any AXObservation> {
            mac.assume(.axSubscriptions)
            mac.scheduler.call("AccessibilityPort.observer \(mac.apps[pid]?.alias ?? "app-unknown") pid=\(pid)")
            guard mac.scheduler.isActive else { return AXResult(.cannotComplete) }
            let observer = Observation(mac: mac, pid: pid, callback: callback)
            mac.observers.append(WeakObservation(value: observer))
            mac.scheduler.reply("AccessibilityPort.observer reply \(mac.apps[pid]!.alias) success", cost: 1)
            return AXResult(.success, observer)
        }
    }

    func describe(_ value: AXValue) -> String {
        switch value {
        case .bool(let value): String(value)
        case .string(let value): value
        case .element(let element): (element.identity as? Handle).map { name($0.node) } ?? "foreign"
        case .elements(let elements): "[" + elements.map { describe(.element($0)) }.joined(separator: ",") + "]"
        case .point(let point): "\(point.x),\(point.y)"
        case .size(let size): "\(size.width)x\(size.height)"
        case .other: "non-array"
        }
    }
    func read(_ attribute: AXAttribute, node: Node) -> AXResult<AXValue> {
        switch node {
        case .application(let pid):
            switch attribute {
            case .windows: return windowList(pid)
            case .hidden:
                assume(.applicationVisibility)
                return AXResult(.success, .bool(apps[pid]!.hidden))
            case .focusedWindow:
                assume(.axFocus)
                if withholdsFocus(pid) { return AXResult(.noValue) }
                if apps[pid]?.publishesFocus == false {
                    assume(.nativeTabPublication)
                    return AXResult(.noValue)
                }
                return apps[pid]?.key.map { AXResult(.success, .element(element(.window($0)))) } ?? AXResult(.noValue)
            case .frontmost:
                assume(.applicationActivation)
                return AXResult(.success, .bool(front == pid))
            default: break
            }
        case .window(let id):
            assume(.axWindowAttributes)
            let window = windows[id]!
            if window.spec.parent != nil, [.main, .minimized, .fullscreen].contains(attribute) {
                if attribute == .main { assume(.axFocus) }
                return AXResult(.attributeUnsupported)
            }
            switch attribute {
            case .minimized: return AXResult(.success, .bool(window.minimized))
            case .fullscreen: return AXResult(.success, .bool(window.fullscreen))
            case .subrole: return AXResult(.success, .string(window.spec.subrole))
            case .size: return AXResult(.success, .size(window.spec.frame.size))
            case .position: return AXResult(.success, .point(window.spec.frame.origin))
            case .main: return AXResult(.success, .bool(apps[window.pid]?.main == id))
            case .role: return AXResult(.success, .string(window.spec.parent == nil ? "AXWindow" : "AXSheet"))
            case .children:
                var children = windows.values.filter { !$0.closed && $0.spec.parent == id }.map(\.id).sorted().map { element(.window($0)) }
                if let group = window.group, let bar = groups[group], bar.selected == id, bar.windows.count > 1 { children.append(element(.bar(group))) }
                children.append(contentsOf: foundationChildren(id))
                return AXResult(.success, .elements(children))
            default: break
            }
        case .bar(let id):
            assume(.nativeTabIdentity)
            guard let group = groups[id] else { return AXResult(.invalidUIElement) }
            switch attribute {
            case .role: return AXResult(.success, .string("AXTabGroup"))
            case .tabs: return AXResult(.success, .elements(group.windows.indices.map { element(.tab(id, $0)) }))
            case .contents:
                return AXResult(.success, .elements(group.windows.indices.map { element(.tab(id, $0)) } + extraNativeControls(id)))
            case .window: return AXResult(.success, .element(element(.window(group.selected))))
            default: break
            }
        case .tab:
            if attribute == .role { return AXResult(.success, .string("AXRadioButton")) }
            if attribute == .children {
                assume(.nativeTabExtraControls)
                return AXResult(.success, .elements([]))
            }
        case .foundation(let id, let node): return readFoundation(attribute, window: id, node: node)
        case .desktop:
            assume(.finderDesktop)
            switch attribute {
            case .role: return AXResult(.success, .string("AXScrollArea"))
            case .subrole: return AXResult(.noValue)
            default: break
            }
        }
        scheduler.failUnmodeled("AccessibilityPort.copy \(attribute.rawValue) \(name(node))")
        return AXResult(.cannotComplete)
    }

    func windowList(_ pid: Int32) -> AXResult<AXValue> {
        assume(.axApplicationWindows)
        var ids = windows.values.filter { window in
            guard window.pid == pid, !window.closed, window.spec.parent == nil else { return false }
            return window.group.flatMap { groups[$0]?.selected == window.id || window.minimized } ?? true
        }.map(\.id).sorted()
        if let published = apps[pid]?.publishedWindows {
            assume(.nativeTabPublication)
            ids = published
        }
        if apps[pid]?.hidden == true && apps[pid]?.omitHiddenWindows == true { ids = [] }
        if let published = publishedWindowList(pid) { ids = published }
        apps[pid]?.zeroIDs.removeAll()
        if let reply = apps[pid]?.windowLists.first {
            apps[pid]?.windowLists.removeFirst()
            switch reply {
            case .complete: break
            case .omitting(let omitted): ids.removeAll { omitted.contains($0) }
            case .zeroIDs(let zero): apps[pid]?.zeroIDs = Set(zero)
            case .failure(let status): return AXResult(status)
            case .nonArray: return AXResult(.success, .other)
            case .includingClosed(let closed): ids = Array(Set(ids + closed)).sorted()
            }
        }
        var elements = ids.map { element(.window($0)) }
        if pid == 10 { elements.append(element(.desktop)) }
        return AXResult(.success, .elements(elements))
    }

    func write(_ attribute: AXAttribute, node: Node, value: AXValue) -> AXStatus {
        switch (node, attribute, value) {
        case (.application(let pid), .frontmost, .bool(true)):
            assume(.applicationActivation)
            activateFromAX(pid)
        case (.window(let id), .main, .bool(true)):
            assume(.axFocus)
            selectFromAX(id)
        case (.window(let id), .position, .point(let point)):
            assume(.windowGeometryWrites)
            var accepted = point
            if windows[id]?.spec.positionAcceptance == .rightEdgeStrip { accepted.x = min(point.x, geometry.frame.maxX - 40) }
            applyPosition(id, accepted)
        case (.window(let id), .size, .size(let size)):
            assume(.axSizeConstraints)
            guard windows[id]?.spec.resizable == true else { return .other(-25200) }
            applySize(id, size)
        default:
            scheduler.failUnmodeled("AccessibilityPort.set \(attribute.rawValue) \(name(node))")
            return .cannotComplete
        }
        return .success
    }

    final class Observation: AXObservation, @unchecked Sendable {
        unowned let mac: SimulatedMac
        let pid: Int32
        let callback: @Sendable (AXNotification, AXElement) -> Void
        var active = false
        var registrations: [Node: Set<AXNotification>] = [:]
        init(mac: SimulatedMac, pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) {
            self.mac = mac; self.pid = pid; self.callback = callback
        }
        @MainActor func start() { mac.scheduler.call("AXObservation.start \(mac.apps[pid]!.alias)"); active = true }
        @MainActor func stop() { mac.scheduler.call("AXObservation.stop \(mac.apps[pid]!.alias)"); active = false }
        func add(_ notification: AXNotification, to element: AXElement) -> AXStatus {
            mac.assume(.axSubscriptions)
            guard let handle = element.identity as? Handle else { mac.scheduler.failUnmodeled("AXObservation.add foreign element"); return .cannotComplete }
            mac.scheduler.call("AXObservation.add \(notification.rawValue) \(mac.name(handle.node))")
            guard mac.scheduler.isActive else { return .cannotComplete }
            let status: AXStatus
            if mac.apps[pid]?.hung == true || (mac.apps[pid]?.busyUntil ?? 0) > mac.scheduler.now { status = .cannotComplete }
            else { status = registrations[handle.node, default: []].insert(notification).inserted ? .success : .notificationAlreadyRegistered }
            mac.scheduler.reply("AXObservation.add reply \(notification.rawValue) \(mac.name(handle.node)) \(status)",
                                cost: status == .cannotComplete ? max(1, Int((handle.timeout * 1_000).rounded())) : 1)
            return status
        }
        func remove(_ notification: AXNotification, from element: AXElement) {
            mac.assume(.axSubscriptions)
            guard let handle = element.identity as? Handle else { mac.scheduler.failUnmodeled("AXObservation.remove foreign element"); return }
            mac.scheduler.call("AXObservation.remove \(notification.rawValue) \(mac.name(handle.node))")
            registrations[handle.node]?.remove(notification)
            mac.scheduler.reply("AXObservation.remove reply \(notification.rawValue) \(mac.name(handle.node))", cost: 1)
        }
    }
    func notify(_ notification: AXNotification, node: Node) {
        assume(.axNotifications)
        for box in observers {
            guard let observer = box.value, observer.active, observer.pid == pid(node), observer.registrations[node]?.contains(notification) == true else { continue }
            let handle = element(node)
            scheduler.nativeEvent { [weak observer] in
                guard let observer, observer.active else { return }
                self.scheduler.note("AX notification \(notification.rawValue) \(self.name(node))")
                observer.callback(notification, handle)
            }
        }
    }
}
