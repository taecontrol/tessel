/// Decides when the fixture ends a native context menu's tracking. The menu
/// stays open `held` seconds once it is on screen. A menu that never appears
/// ends tracking when the harness margin runs out, so the fixture still
/// answers later commands. The Acceptance target compiles this file too, so
/// its tests judge the same rule the signed fixture runs.
package struct MenuHold {
    package static let held = 0.4
    private let started: Double
    private let margin: Double
    private var appeared: Double?

    package init(startedAt started: Double, margin: Double) {
        self.started = started
        self.margin = margin
    }

    /// Records one sample taken at `now` and returns whether tracking continues.
    package mutating func continues(at now: Double, menuOnScreen: Bool) -> Bool {
        if appeared == nil, menuOnScreen { appeared = now }
        return !(appeared.map { now - $0 >= Self.held } ?? (now - started >= margin))
    }
}
