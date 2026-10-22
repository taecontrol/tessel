import CoreGraphics
import Foundation
import Ports

extension SimulatedMac {
    package struct GeometryWrite: Sendable {
        package let at: Int
        package let traceIndex: Int
        package let window: UInt32
        package let attribute: AXAttribute
        package let requested: AXValue
        package let hidden: Bool
        package var accepted: CGRect
    }
    package struct VisibilityChange: Sendable {
        package let at: Int
        package let windows: [UInt32]
        package let showing: Bool
        package let focusedWindow: UInt32?
    }
    package struct FocusRequest: Sendable {
        package let window: UInt32
        package let hidden: Bool
    }
    package struct NativeFocus: Sendable {
        package let at: Int
        package let window: UInt32?
        package let hidden: Bool
        /// The AXRaise target, when this effect followed that action.
        package let raisedWindow: UInt32?
    }
    package struct PresentationState: Sendable {
        package let operation: String
        package let traceIndex: Int
        package let frames: [UInt32: CGRect]
        package let order: [UInt32]
    }
    struct MotionState {
        var states: [PresentationState] = []
        var tracingPresentation = false
        var pointerHeld = false
        var writes: [GeometryWrite] = []
        var visibility: [VisibilityChange] = []
        var focusRequests: [FocusRequest] = []
        var focusEffects: [NativeFocus] = []
        var reduced = false
        var preferences: [WeakPreference] = []
        var pointers: [WeakPointer] = []
        var shortSizes = Set<UInt32>()
    }
    struct WeakPreference { weak var value: PreferenceToken? }
    struct WeakPointer { weak var value: PointerToken? }
    @MainActor final class PointerToken: MotionPreferenceObservation {
        let receive: @MainActor @Sendable (Bool) -> Void
        init(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) { self.receive = receive }
    }
    @MainActor final class PreferenceToken: MotionPreferenceObservation {
        let receive: @MainActor @Sendable (Bool) -> Void
        init(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) { self.receive = receive }
    }

    @MainActor package var motionPreferences: any MotionPreferencePort { Preferences(mac: self) }
    @MainActor package var pointerActivity: any PointerActivityPort { PointerActivity(mac: self) }
    @MainActor package func pointerDown() { pressPointer() }
    @MainActor package func pointerUp() {
        motion.pointerHeld = false
        for box in motion.pointers { box.value?.receive(false) }
    }
    @MainActor func pressPointer() {
        assume(.pointerPressNotifications)
        motion.pointerHeld = true
        for box in motion.pointers { box.value?.receive(true) }
    }
    @MainActor package var presentationStates: [PresentationState] { motion.states }
    @MainActor package func beginPresentationTrace() { motion.tracingPresentation = true; motion.states.removeAll() }
    func recordPresentation(_ operation: String) {
        guard motion.tracingPresentation else { return }
        let order = visibleIDs()
        motion.states.append(PresentationState(operation: operation, traceIndex: scheduler.trace.count,
            frames: Dictionary(uniqueKeysWithValues: order.compactMap { id in windows[id].map { (id, $0.spec.frame) } }), order: order))
    }
    @MainActor package var geometryWrites: [GeometryWrite] { motion.writes }
    @MainActor package var visibilityChanges: [VisibilityChange] { motion.visibility }
    @MainActor package var focusRequests: [FocusRequest] { motion.focusRequests }
    /// Actual keyboard focus after a tessel focus effect, rather than its
    /// requested target. External app/user selections are not policy effects.
    @MainActor package var focusEffects: [NativeFocus] { motion.focusEffects }
    @MainActor package func setScreen(_ geometry: ScreenGeometry) { self.geometry = geometry }
    @MainActor package func setReduceMotion(_ enabled: Bool) {
        assume(.reduceMotionNotifications)
        action("Reduce Motion=\(enabled)")
        guard enabled != motion.reduced else { return }
        motion.reduced = enabled
        for box in motion.preferences {
            guard let token = box.value else { continue }
            scheduler.nativeEvent { [weak token] in token?.receive(enabled) }
        }
    }
    @MainActor package func clearMotionHistory() {
        motion.states.removeAll(); motion.writes.removeAll(); motion.visibility.removeAll(); motion.focusRequests.removeAll(); motion.focusEffects.removeAll()
        clearStageHistory()
    }
    func recordFocusEffect(raisedWindow: UInt32? = nil) {
        recordPresentation("focus")
        let window = front.flatMap { apps[$0]?.key }
        motion.focusEffects.append(NativeFocus(at: scheduler.now, window: window, hidden: window.map(isCloseted) ?? false, raisedWindow: raisedWindow))
    }
    func isCloseted(_ id: UInt32) -> Bool {
        guard let spaces = windows[id]?.spaces else { return false }
        return !spaces.isEmpty && spaces.allSatisfy { $0 >= 2 && $0 < 10_000 }
    }
    func recordGeometry(_ id: UInt32, attribute: AXAttribute, requested: AXValue) -> Int {
        let index = motion.writes.count
        motion.writes.append(GeometryWrite(at: scheduler.now, traceIndex: scheduler.trace.count, window: id, attribute: attribute,
                                           requested: requested, hidden: isCloseted(id), accepted: windows[id]!.spec.frame))
        return index
    }
    func finishGeometry(_ id: UInt32, index: Int) {
        motion.writes[index].accepted = windows[id]!.spec.frame
        recordPresentation("geometry")
    }
    func recordVisibility(_ ids: [UInt32], showing: Bool) {
        motion.visibility.append(VisibilityChange(at: scheduler.now, windows: ids, showing: showing,
                                                 focusedWindow: front.flatMap { apps[$0]?.key }))
    }
    @MainActor private struct Preferences: MotionPreferencePort {
        let mac: SimulatedMac
        var reduceMotion: Bool {
            mac.assume(.reduceMotionNotifications)
            mac.scheduler.call("MotionPreferencePort.reduceMotion")
            return mac.motion.reduced
        }
        func observe(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation {
            mac.assume(.reduceMotionNotifications)
            mac.scheduler.call("MotionPreferencePort.observe")
            let token = PreferenceToken(receive)
            mac.motion.preferences.append(WeakPreference(value: token))
            return token
        }
    }
    @MainActor private struct PointerActivity: PointerActivityPort {
        let mac: SimulatedMac
        func observeButtons(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation {
            mac.assume(.pointerPressNotifications)
            mac.scheduler.call("PointerActivityPort.observeButtons")
            let token = PointerToken(receive)
            mac.motion.pointers.append(WeakPointer(value: token))
            return token
        }
    }
}
