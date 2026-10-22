import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("#19 E29: real layer keys show and hide a signed panel and move a signed tile to the layer and back")
    func layerKeysReachSignedWindows() throws {
        let tile = try fixture.open(key: "tile"), neighbor = try fixture.open(key: "neighbor")
        let panel = try fixture.open(kind: "normalPanel", key: "panel", ["background": true])
        try desktop.activate(key: "tile")
        try requireFinalState("all layer journey fixtures are catalogued") { Set(try harness.rows().map(\.id)) == Set([tile, neighbor, panel]) }
        try desktop.configure("[experiments]\nlayer = true\n", layout: "carousel")
        try requireFinalState("the panel starts hidden while its tile has native focus") {
            let observed = try desktop.observe()
            return desktop.focused(tile, in: observed) && !observed.visibleIDs.contains(panel)
        }
        try desktop.post(kVK_ANSI_Z)
        try requireFinalState("alt-z shows and focuses the signed floating panel") {
            let observed = try desktop.observe()
            return observed.visibleIDs.contains(panel) && observed.windows.contains { $0.id == panel && $0.visible && $0.focused }
                && observed.frontmostFixturePID == fixture.pid
        }
        try desktop.post(kVK_ANSI_Z)
        try requireFinalState("alt-z hides the signed panel and returns native focus to its tile") {
            let observed = try desktop.observe()
            return !observed.visibleIDs.contains(panel) && desktop.focused(tile, in: observed)
        }
        try desktop.post(kVK_ANSI_F)
        try requireFinalState("alt-f removes the signed tile from its rail into the visible layer") {
            let observed = try desktop.observe(), row = try harness.row(tile)
            return row?.state == "floats" && row?.rail == nil && observed.visibleIDs.contains(tile)
                && observed.windows.contains { $0.id == tile && $0.focused }
                && observed.visibleIDs.contains(panel)
        }
        try desktop.post(kVK_ANSI_F)
        try requireFinalState("alt-f restores the signed tile to its rail and hides the panel") {
            let observed = try desktop.observe(), row = try harness.row(tile)
            return row?.state == "tiled" && row?.rail != nil && row?.slot != nil
                && desktop.focused(tile, in: observed) && !observed.visibleIDs.contains(panel)
        }
    }
}
