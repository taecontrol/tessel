import CoreGraphics
import Foundation
import Ports

extension SimulatedMac {
    package struct GeometryWrite: Sendable {
        package let at: Int
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
    }
    struct MotionState {
        var writes: [GeometryWrite] = []
        var visibility: [VisibilityChange] = []
        var reduced = false
        var preferences: [WeakPreference] = []
        var pointers: [WeakPointer] = []
        var shortSizes = Set<UInt32>()
    }
    struct WeakPreference { weak var value: PreferenceToken? }
    struct WeakPointer { weak var value: PointerToken? }
    @MainActor final class PointerToken: MotionPreferenceObservation {
        let receive: @MainActor @Sendable () -> Void
        init(_ receive: @escaping @MainActor @Sendable () -> Void) { self.receive = receive }
    }
    @MainActor final class PreferenceToken: MotionPreferenceObservation {
        let receive: @MainActor @Sendable (Bool) -> Void
        init(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) { self.receive = receive }
    }

    @MainActor package var motionPreferences: any MotionPreferencePort { Preferences(mac: self) }
    @MainActor package var pointerActivity: any PointerActivityPort { PointerActivity(mac: self) }
    @MainActor func pressPointer() {
        assume(.pointerPressNotifications)
        for box in motion.pointers { box.value?.receive() }
    }
    @MainActor package var geometryWrites: [GeometryWrite] { motion.writes }
    @MainActor package var visibilityChanges: [VisibilityChange] { motion.visibility }
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
        motion.writes.removeAll(); motion.visibility.removeAll(); stageState.events.removeAll()
    }
    func isCloseted(_ id: UInt32) -> Bool {
        guard let spaces = windows[id]?.spaces else { return false }
        return !spaces.isEmpty && spaces.allSatisfy { $0 >= 2 && $0 < 10_000 }
    }
    func recordGeometry(_ id: UInt32, attribute: AXAttribute, requested: AXValue) -> Int {
        let index = motion.writes.count
        motion.writes.append(GeometryWrite(at: scheduler.now, window: id, attribute: attribute,
                                           requested: requested, hidden: isCloseted(id), accepted: windows[id]!.spec.frame))
        return index
    }
    func finishGeometry(_ id: UInt32, index: Int) {
        motion.writes[index].accepted = windows[id]!.spec.frame
    }
    func recordVisibility(_ ids: [UInt32], showing: Bool) {
        motion.visibility.append(VisibilityChange(at: scheduler.now, windows: ids, showing: showing))
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
        func observePress(_ receive: @escaping @MainActor @Sendable () -> Void) -> any MotionPreferenceObservation {
            mac.assume(.pointerPressNotifications)
            mac.scheduler.call("PointerActivityPort.observePress")
            let token = PointerToken(receive)
            mac.motion.pointers.append(WeakPointer(value: token))
            return token
        }
    }
}
