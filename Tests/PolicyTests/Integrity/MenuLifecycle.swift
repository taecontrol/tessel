import Foundation
import Testing

@Suite struct MenuLifecycle {
    @Test("the status menu uses AppKit's population callback, not its opening notification")
    func statusMenuUsesPopulationCallback() throws {
        // NSMenu.h forbids changing menu structure or items in menuWillOpen.
        // The SDK selector is the contract here, not our delegate/type names.
        // Keep this headless: the real-system journey owns displaying the menu.
        let source = try String(contentsOf: IntegritySources.root.appending(path: "Sources/App/Main.swift"), encoding: .utf8)
        let code = PolicyPurity.codeOnly(source)
        #expect(code.range(of: #"\bfunc\s+menuNeedsUpdate\s*\("#, options: .regularExpression) != nil)
        #expect(code.range(of: #"\bfunc\s+menuWillOpen\s*\("#, options: .regularExpression) == nil)
    }
}
