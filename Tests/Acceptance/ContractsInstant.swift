import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("#33 E8: enhanced-ui-resize loses size in the raw order and preserves it with the flag disabled", contract(.enhancedUIResize))
    func enhancedUIResizeOrder() throws {
        let id = try fixture.open(); _ = try window(id)
        let original = try #require(try native("enhancedUI").enhancedUI)
        defer { _ = try? native("enhancedUI", ["enabled": original]) }
        let area = try #require(try native("screen").axVisibleFrame)
        let origin = [area[0] + 10, area[1] + 10]
        try native("enhancedUI", ["enabled": false])
        try #require(try write(id, "AXPosition", origin) == 0)
        try #require(try write(id, "AXSize", [600, 400]) == 0)
        try requireFinalState("baseline fixture size") { try native("retained", ["id": id]).window?.frame.suffix(2) == [600, 400] }
        let enabled = try native("enhancedUI", ["enabled": true])
        try #require(enabled.enhancedUI == true && [Int32(0), -25208].contains(enabled.result ?? 1))
        try #require(try native("writeSizeThenPosition", ["id": id, "frame": [origin[0] + 200, origin[1], 900, 400]]).results == [0, 0])
        try requireFinalState("enhanced UI loses the size followed by position") {
            try native("retained", ["id": id]).window?.frame.suffix(2) == [600, 400]
        }
        try native("enhancedUI", ["enabled": false])
        try #require(try native("writeSizeThenPosition", ["id": id, "frame": [origin[0], origin[1], 900, 400]]).results == [0, 0])
        try native("enhancedUI", ["enabled": true])
        try requireFinalState("disabling enhanced UI around the writes preserves the requested size and restores the flag") {
            try native("retained", ["id": id]).window?.frame.suffix(2) == [900, 400] && native("enhancedUI").enhancedUI == true
        }
    }

    @Test("#33 E19: hidden geometry is accepted in the closet and survives showing", contract(.closetAXIdentity))
    func hiddenGeometryLandsBeforeShowing() throws {
        let id = try fixture.open(); _ = try window(id)
        let area = try #require(try native("screen").axVisibleFrame)
        let target = [area[0] + 10, area[1] + 10, (area[2] - 30) / 2, area[3] - 20]
        let original = try #require(try native("enhancedUI").enhancedUI)
        defer { _ = try? native("enhancedUI", ["enabled": original]) }
        try native("closetStart"); defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [id]])
        try requireFinalState("fixture hidden before preparation") { !(try desktop.observe()).visibleIDs.contains(id) }
        try native("enhancedUI", ["enabled": false])
        try #require(try write(id, "AXPosition", Array(target.prefix(2))) == 0)
        try #require(try write(id, "AXSize", Array(target.suffix(2))) == 0)
        try native("enhancedUI", ["enabled": original])
        try requireFinalState("AX geometry lands while the fixture is still hidden") {
            let state = try native("retained", ["id": id])
            let hidden = !(try desktop.observe()).visibleIDs.contains(id)
            return state.window.map { desktop.near($0.frame, target) } == true && hidden
        }
        try native("closetShow", ["ids": [id]])
        try requireFinalState("the prepared frame survives showing") {
            let state = try desktop.observe()
            return state.windows.contains { $0.id == id && $0.visible && desktop.near($0.frame, target) }
        }
    }
}
