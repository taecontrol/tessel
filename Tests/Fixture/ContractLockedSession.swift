import AppKit
import ApplicationServices

/// Samples one fixture window across a screen lock for the attended
/// `locked-session-windows` contract. Each tick brackets its two AX reads with
/// the CG session's lock report, which needs no Accessibility call.
@MainActor
final class FixtureLockWatch: NSObject {
    private struct Sample: Equatable {
        /// The report before the list read, between the reads and after the handle read.
        var locked: [Bool]
        var listError: Int32
        var listIsArray: Bool
        var roots: Int
        var listsHandle: Bool
        var listsID: Bool
        /// The first listed root's own answers; -1 when no root is listed.
        var rootIDError: Int32
        var rootID: UInt32
        var rootRoleError: Int32
        /// The app's own attributes, which keep answering under a lock.
        var hiddenError: Int32
        var focusedError: Int32
        var focusedIsListed: Bool
        var frontmostError: Int32
        var handleIDError: Int32
        var handleID: UInt32
        var handleRoleError: Int32
        var windowServerLists: Bool
        var onScreen: Bool
    }
    private static let maximumRuns = 200
    private var application: AXUIElement?
    private var window: AXUIElement?
    private var id: UInt32 = 0
    private var timer: Timer?
    private var runs: [(sample: Sample, count: Int, first: Double, last: Double)] = []
    private var events: [[String: Any]] = []

    static func reportsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

    func start(application: AXUIElement, window: AXUIElement, id: UInt32) {
        stop()
        self.application = application
        self.window = window
        self.id = id
        runs.removeAll()
        events.removeAll()
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            center.addObserver(self, selector: #selector(changed(_:)), name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        application = nil
        window = nil
    }

    func facts() -> [String: Any] {
        ["runs": runs.map { run -> [String: Any] in
            ["locked": run.sample.locked, "listError": run.sample.listError, "listIsArray": run.sample.listIsArray,
             "roots": run.sample.roots, "listsHandle": run.sample.listsHandle, "listsID": run.sample.listsID,
             "rootIDError": run.sample.rootIDError, "rootID": run.sample.rootID, "rootRoleError": run.sample.rootRoleError,
             "hiddenError": run.sample.hiddenError, "focusedError": run.sample.focusedError,
             "focusedIsListed": run.sample.focusedIsListed, "frontmostError": run.sample.frontmostError,
             "handleIDError": run.sample.handleIDError, "handleID": run.sample.handleID,
             "handleRoleError": run.sample.handleRoleError, "windowServerLists": run.sample.windowServerLists,
             "onScreen": run.sample.onScreen, "count": run.count, "first": run.first, "last": run.last]
        }, "events": events]
    }

    @objc private func changed(_ notification: Notification) {
        events.append(["name": notification.name.rawValue, "locked": Self.reportsLocked(), "at": Self.now()])
    }

    private func tick() {
        guard let application, let window else { return }
        let before = Self.reportsLocked()
        var list: CFTypeRef?
        let listError = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &list)
        let roots = list as? [AXUIElement]
        let listsHandle = roots?.contains { CFEqual($0, window) } ?? false
        let listsID = roots?.contains { root in
            var number: UInt32 = 0
            return fixtureWindowID(root, &number) == .success && number == id
        } ?? false
        var rootIDError: Int32 = -1, rootID: UInt32 = 0, rootRoleError: Int32 = -1
        if let root = roots?.first {
            rootIDError = fixtureWindowID(root, &rootID).rawValue
            var rootRole: CFTypeRef?
            rootRoleError = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &rootRole).rawValue
        }
        var hidden: CFTypeRef?, focused: CFTypeRef?, frontmost: CFTypeRef?
        let hiddenError = AXUIElementCopyAttributeValue(application, kAXHiddenAttribute as CFString, &hidden)
        let focusedError = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        let focusedIsListed = focused.map { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() && (roots?.contains { CFEqual($0, value) } ?? false)
        } ?? false
        let frontmostError = AXUIElementCopyAttributeValue(application, kAXFrontmostAttribute as CFString, &frontmost)
        let between = Self.reportsLocked()
        var number: UInt32 = 0
        let idError = fixtureWindowID(window, &number)
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let after = Self.reportsLocked()
        let listing = PlacementSampler.windowServer(id)
        let sample = Sample(locked: [before, between, after], listError: listError.rawValue, listIsArray: roots != nil,
                            roots: roots?.count ?? 0, listsHandle: listsHandle, listsID: listsID, rootIDError: rootIDError,
                            rootID: rootID, rootRoleError: rootRoleError, hiddenError: hiddenError.rawValue,
                            focusedError: focusedError.rawValue, focusedIsListed: focusedIsListed,
                            frontmostError: frontmostError.rawValue, handleIDError: idError.rawValue,
                            handleID: number, handleRoleError: roleError.rawValue, windowServerLists: listing != nil,
                            onScreen: listing?.onScreen ?? false)
        let at = Self.now()
        if let last = runs.indices.last, runs[last].sample == sample {
            runs[last].count += 1
            runs[last].last = at
        } else if runs.count < Self.maximumRuns {
            runs.append((sample, 1, at, at))
        }
    }
}
