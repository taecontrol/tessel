import Foundation
import CoreGraphics

package protocol AXElementIdentity: Sendable {
    func isEqual(to other: any AXElementIdentity) -> Bool
    func hash(into hasher: inout Hasher)
}

/// Identity belongs to the adapter; equal handles can have different timeouts.
package struct AXElement: Hashable, Sendable {
    package let identity: any AXElementIdentity
    package init(_ identity: any AXElementIdentity) { self.identity = identity }
    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity.isEqual(to: rhs.identity) }
    package func hash(into hasher: inout Hasher) { identity.hash(into: &hasher) }
}

package enum AXAttribute: String, Sendable {
    case windows = "AXWindows", hidden = "AXHidden", focusedWindow = "AXFocusedWindow"
    case minimized = "AXMinimized", fullscreen = "AXFullScreen", subrole = "AXSubrole"
    case size = "AXSize", position = "AXPosition", role = "AXRole", tabs = "AXTabs"
    case contents = "AXContents", children = "AXChildren", frontmost = "AXFrontmost"
    case main = "AXMain", window = "AXWindow"
}

package enum AXNotification: String, Sendable {
    case destroyed = "AXUIElementDestroyed", minimized = "AXWindowMiniaturized", restored = "AXWindowDeminiaturized"
    case moved = "AXWindowMoved", resized = "AXWindowResized", layoutChanged = "AXLayoutChanged", valueChanged = "AXValueChanged"
    case windowCreated = "AXWindowCreated", focusedWindowChanged = "AXFocusedWindowChanged"
    case mainWindowChanged = "AXMainWindowChanged", sheetCreated = "AXSheetCreated"
}

package enum AXAction: String, Sendable { case raise = "AXRaise" }

package enum AXStatus: Equatable, Sendable {
    case success, cannotComplete, apiDisabled, invalidUIElement, noValue, attributeUnsupported
    case notificationAlreadyRegistered, notificationUnsupported
    case other(Int32)
}

package enum AXValue: Sendable {
    case bool(Bool), string(String), element(AXElement), elements([AXElement]), point(CGPoint), size(CGSize), other

    package var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var element: AXElement? { if case .element(let value) = self { value } else { nil } }
    package var elements: [AXElement]? { if case .elements(let value) = self { value } else { nil } }
    package var point: CGPoint? { if case .point(let value) = self { value } else { nil } }
    package var size: CGSize? { if case .size(let value) = self { value } else { nil } }
}

package struct AXResult<Value: Sendable>: Sendable {
    package let status: AXStatus
    package let value: Value?
    package init(_ status: AXStatus, _ value: Value? = nil) { self.status = status; self.value = value }
}

package protocol AXObservation: AnyObject, Sendable {
    @MainActor func start()
    @MainActor func stop()
    func add(_ notification: AXNotification, to element: AXElement) -> AXStatus
    func remove(_ notification: AXNotification, from element: AXElement)
}

package protocol AccessibilityPort: Sendable {
    func application(_ pid: Int32) -> AXElement
    @discardableResult func setMessagingTimeout(_ element: AXElement, seconds: Float) -> AXStatus
    func copy(_ attribute: AXAttribute, of element: AXElement) -> AXResult<AXValue>
    func set(_ attribute: AXAttribute, of element: AXElement, to value: AXValue) -> AXStatus
    func isSettable(_ attribute: AXAttribute, of element: AXElement) -> AXResult<Bool>
    func perform(_ action: AXAction, on element: AXElement) -> AXStatus
    func windowID(_ element: AXElement) -> AXResult<UInt32>
    func observer(_ pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) -> AXResult<any AXObservation>
}
