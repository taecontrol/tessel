import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private struct NativeAXElement: AXElementIdentity, @unchecked Sendable {
    let value: AXUIElement
    func isEqual(to other: any AXElementIdentity) -> Bool {
        guard let other = other as? NativeAXElement else { return false }
        return CFEqual(value, other.value)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(value)) }
}

private extension AXElement {
    init(_ value: AXUIElement) { self.init(NativeAXElement(value: value)) }
    var native: AXUIElement { (identity as! NativeAXElement).value }
}

private extension AXStatus {
    init(_ error: AXError) {
        switch error {
        case .success: self = .success
        case .cannotComplete: self = .cannotComplete
        case .apiDisabled: self = .apiDisabled
        case .invalidUIElement: self = .invalidUIElement
        case .noValue: self = .noValue
        case .attributeUnsupported: self = .attributeUnsupported
        case .notificationAlreadyRegistered: self = .notificationAlreadyRegistered
        case .notificationUnsupported: self = .notificationUnsupported
        default: self = .other(error.rawValue)
        }
    }
}

struct SystemAccessibility: AccessibilityPort {
    func application(_ pid: Int32) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }
    func setMessagingTimeout(_ element: AXElement, seconds: Float) -> AXStatus {
        AXStatus(AXUIElementSetMessagingTimeout(element.native, seconds))
    }
    func copy(_ attribute: AXAttribute, of element: AXElement) -> AXResult<AXValue> {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.native, attribute.rawValue as CFString, &result)
        return AXResult(AXStatus(error), result.map(decode))
    }
    func set(_ attribute: AXAttribute, of element: AXElement, to value: AXValue) -> AXStatus {
        let native: CFTypeRef
        switch value {
        case .bool(let flag): native = flag ? kCFBooleanTrue : kCFBooleanFalse
        case .point(var point): native = AXValueCreate(.cgPoint, &point)!
        case .size(var size): native = AXValueCreate(.cgSize, &size)!
        case .string(let text): native = text as CFString
        case .element(let element): native = element.native
        case .elements(let elements): native = elements.map(\.native) as CFArray
        case .other: preconditionFailure("Cannot write an undecoded AX value")
        }
        return AXStatus(AXUIElementSetAttributeValue(element.native, attribute.rawValue as CFString, native))
    }
    func isSettable(_ attribute: AXAttribute, of element: AXElement) -> AXResult<Bool> {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element.native, attribute.rawValue as CFString, &settable)
        return AXResult(AXStatus(error), settable.boolValue)
    }
    func perform(_ action: AXAction, on element: AXElement) -> AXStatus {
        AXStatus(AXUIElementPerformAction(element.native, action.rawValue as CFString))
    }
    func windowID(_ element: AXElement) -> AXResult<UInt32> {
        var id: UInt32 = 0
        let error = axWindowID(element.native, &id)
        return AXResult(AXStatus(error), id)
    }
    func observer(_ pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) -> AXResult<any AXObservation> {
        SystemAXObservation.create(pid, callback: callback)
    }

    private func decode(_ value: CFTypeRef) -> AXValue {
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return .element(AXElement(value as! AXUIElement)) }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let value = value as! ApplicationServices.AXValue
            switch AXValueGetType(value) {
            case .cgPoint:
                var point = CGPoint.zero
                _ = AXValueGetValue(value, .cgPoint, &point)
                return .point(point)
            case .cgSize:
                var size = CGSize.zero
                _ = AXValueGetValue(value, .cgSize, &size)
                return .size(size)
            default: return .other
            }
        }
        if let elements = value as? [AXUIElement] { return .elements(elements.map(AXElement.init)) }
        if let bool = value as? Bool { return .bool(bool) }
        if let string = value as? String { return .string(string) }
        return .other
    }
}

private final class SystemAXObservation: AXObservation, @unchecked Sendable {
    private var value: AXObserver!
    private let callback: @Sendable (AXNotification, AXElement) -> Void
    private init(callback: @escaping @Sendable (AXNotification, AXElement) -> Void) { self.callback = callback }

    static func create(_ pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) -> AXResult<any AXObservation> {
        let observation = SystemAXObservation(callback: callback)
        let error = AXObserverCreate(pid, { _, element, notification, context in
            guard let context, let name = AXNotification(rawValue: notification as String) else { return }
            let owner = Unmanaged<SystemAXObservation>.fromOpaque(context).takeUnretainedValue()
            owner.callback(name, AXElement(element))
        }, &observation.value)
        return AXResult(AXStatus(error), error == .success && observation.value != nil ? observation : nil)
    }
    @MainActor func start() { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes) }
    @MainActor func stop() { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes) }
    func add(_ notification: AXNotification, to element: AXElement) -> AXStatus {
        AXStatus(AXObserverAddNotification(value, element.native, notification.rawValue as CFString, Unmanaged.passUnretained(self).toOpaque()))
    }
    func remove(_ notification: AXNotification, from element: AXElement) {
        AXObserverRemoveNotification(value, element.native, notification.rawValue as CFString)
    }
}
