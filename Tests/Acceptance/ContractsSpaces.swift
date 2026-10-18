import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("closet-moves: SkyLight moves a parent and sheet without changing AX focus", contract(.closetMoves))
    func closetMoves() throws {
        let sheet = try fixture.open(kind: "sheet", key: "sheet")
        let parent = try #require(try fixture.command("ping").windows["sheetParent"])
        try desktop.activate(key: "sheetParent")
        _ = try window(parent)
        let before = try native(), focused = try #require(before.focused?.id)
        try #require(before.visible.isSuperset(of: [parent, sheet]))
        let frame = try #require(before.roots.first { $0.id == parent }?.frame)
        try native("closetStart")
        defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [parent]])
        try requireFinalState("the parent and its sheet disappear from the active Space without losing native focus") {
            let state = try native()
            let retained = try native("retained", ["id": parent]).window
            return state.visible.isDisjoint(with: [parent, sheet]) && state.focused?.id == focused
                && retained?.frame == frame && retained?.sheets.contains { $0.id == sheet } == true
        }
        try native("closetShow", ["ids": [parent]])
        try requireFinalState("the parent and sheet return without a frame or focus change") {
            let state = try native()
            let retained = try native("retained", ["id": parent]).window
            return state.visible.isSuperset(of: [parent, sheet]) && state.focused?.id == focused
                && retained?.frame == frame
        }
    }

    @Test("closet-membership: ordinary queries omit the closet while all-Space queries retain it", contract(.closetMembership))
    func closetMembership() throws {
        let id = try fixture.open(key: "hidden")
        _ = try fixture.open(key: "front")
        try desktop.activate(key: "front")
        _ = try window(id)
        let before = try native("spaces", ["ids": [id]])
        let active = try #require(before.activeSpace)
        try #require(before.memberships?.first?.ordinary.contains(active) == true && before.memberships?.first?.all.contains(active) == true)
        let started = try native("closetStart"), closet = try #require(started.closetSpace)
        try #require(closet != 0 && closet != active)
        defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [id]])
        try requireFinalState("all-Space membership retains the invisible closet") {
            let state = try native("spaces", ["ids": [id]])
            return state.activeSpace == active && state.memberships?.first?.ordinary.isEmpty == true
                && state.memberships?.first?.all == [closet]
        }
        try native("closetShow", ["ids": [id]])
        try requireFinalState("shown windows have ordinary active membership and may retain the invisible membership") {
            let state = try native("spaces", ["ids": [id]])
            let all = Set(state.memberships?.first?.all ?? [])
            return state.activeSpace == active && state.memberships?.first?.ordinary == [active]
                && (all == [active] || all == [active, closet])
        }
        try native("closetStop")
        try requireFinalState("destroying the closet removes its retained membership") {
            let state = try native("spaces", ["ids": [id]])
            return state.activeSpace == active && state.memberships?.first?.ordinary == [active]
                && state.memberships?.first?.all == [active]
        }
    }

    @Test("finder-desktop: the native desktop has scroll-area shape and activates without reopening windows", contract(.finderDesktop))
    func finderDesktop() throws {
        let state = try native("finder")
        try #require(state.desktopRole == "AXScrollArea" && state.desktopID == 0)
        try #require(state.desktopSubroleError == -25212 || state.desktopSubroleError == -25205)
        guard state.finderSafe == true else {
            print("SKIP: Finder desktop activation requires an AXWindows list without ordinary or unknown entries; desktop shape was checked.")
            return
        }
        _ = try fixture.open()
        try desktop.activate()
        try fixture.command("contract", ["operation": "activateFinder"])
        try requireFinalState("Finder activates its desktop without opening an ordinary window") {
            let state = try native("finder")
            return state.finderSafe == true && state.finderFrontmost == true && state.finderFocused == true
        }
    }
}
