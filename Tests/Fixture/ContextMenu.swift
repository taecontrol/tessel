import AppKit
import CoreGraphics
import Darwin

/// Opens a native context menu in a fixture window and reports, while the menu
/// tracks, whether the window and its menu are on screen and which Spaces hold
/// the window. Tracking blocks the main run loop, so a common-modes timer
/// samples and then ends tracking; AX answering during tracking is unobserved.
@MainActor
final class FixtureContextMenu: NSObject {
    /// The menu stays open this long once it is on screen.
    private static let interval = 0.05, held = 0.4
    private let window: NSWindow
    /// The harness margin for the whole command. A menu that never appears
    /// ends tracking when it runs out, so the fixture answers later commands.
    private let margin: Double
    private let spaces: FixtureSpaces
    private let menu = NSMenu()
    private var samples: [[String: Any]] = []
    private var started = 0.0
    private var appeared: Double?

    init(window: NSWindow, margin: Double) throws {
        self.window = window
        self.margin = margin
        spaces = try FixtureSpaces()
        super.init()
        for index in 1...3 { menu.addItem(withTitle: "Fixture item \(index)", action: nil, keyEquivalent: "") }
    }

    /// Returns after the menu closes, with every sample taken while it tracked.
    func run() throws -> [[String: Any]] {
        guard let view = window.contentView else { throw FixtureContractError("a context menu needs a fixture window") }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        started = Self.now()
        menu.popUp(positioning: nil, at: NSPoint(x: 40, y: max(0, view.bounds.height - 40)), in: view)
        return samples
    }

    private func tick() {
        let now = Self.now(), id = CGWindowID(window.windowNumber)
        let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let own = listed.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let menuOnScreen = own.contains { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == menuLevel }
        samples.append(["windowOnScreen": own.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id },
                        "menuOnScreen": menuOnScreen, "activeSpace": spaces.active,
                        "spaces": spaces.memberships(id, mask: 0xF), "sampledAt": now])
        if appeared == nil, menuOnScreen { appeared = now }
        if appeared.map({ now - $0 >= Self.held }) ?? (now - started >= margin) { menu.cancelTracking() }
    }

    private static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }
}
