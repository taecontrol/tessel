import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationNativeTabs {
    @Test("#1 E5: native selection, insertion, hide, minimize, restore and close preserve the reported group", arguments: WriteOrder.allCases)
    func groupLifecycle(_ writes: WriteOrder) {
        requireScenario(Scenario.run("native group lifecycle", writes: writes) { scenario in
            let app = scenario.mac.launch(windows: 3)
            app.groupTabs([1, 2, 3], selected: 1)
            let tessel = scenario.startTessel()
            scenario.settle()
            @MainActor func group(_ selected: UInt32, count: Int = 3, state: WindowState = .tiled) {
                scenario.expect("one native group entry", tessel.windows.map(\.id) == [selected])
                FoundationProof.row(selected, in: tessel, state: state,
                                    reason: "\(state == .hidden ? "application hidden" : "standard window"); \(count) native tabs",
                                    tabs: count, scenario: scenario)
            }
            group(1)
            scenario.step("select the second native tab") { app.selectTab(2) }
            scenario.settle()
            group(2)
            var inserted: UInt32 = 0
            scenario.step("insert a fourth tab retaining the native bar") { inserted = app.addNativeTab(to: 2) }
            scenario.settle()
            group(inserted, count: 4)
            app.close(inserted, selecting: 2)
            scenario.settle()
            group(2)
            app.selectTab(1)
            scenario.settle()
            group(1)
            app.hide(omitWindows: true)
            scenario.settle()
            group(1, state: .hidden)
            app.unhide()
            scenario.settle()
            group(1)
            app.minimize(1)
            scenario.settle()
            scenario.expect("minimized tabs are reported separately", tessel.windows.map(\.id) == [1, 2, 3] && tessel.windows.allSatisfy { $0.state == .minimized })
            scenario.expect("only the selected minimized root reports the native bar", tessel.windows.map(\.tabs).sorted() == [1, 1, 3])
            let separate = app.open()
            scenario.settle()
            app.minimize(separate)
            scenario.settle()
            scenario.expect("an unrelated minimized window is never guessed into the group", tessel.windows.map(\.id) == [1, 2, 3, separate] && tessel.windows.allSatisfy { $0.state == .minimized })
            FoundationProof.row(separate, in: tessel, state: .minimized, reason: "minimized", scenario: scenario)
            app.close(separate)
            app.restore(1)
            scenario.settle()
            group(1)
            app.close(1, selecting: 2)
            scenario.settle()
            group(2, count: 2)
            app.close(2, selecting: 3)
            scenario.settle()
            scenario.expect("the final native tab becomes an ordinary single entry", tessel.windows.map(\.id) == [3])
            FoundationProof.row(3, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
            app.close(3)
            scenario.settle()
            scenario.expect("the final close removes the group", tessel.windows.isEmpty)
        })
    }

    @Test("#1 E5: empty, populated and segmented content tabs never count as native windows", arguments: ContentTabStyle.allCases)
    func contentTabs(_ style: ContentTabStyle) {
        requireScenario(Scenario.run("\(style.rawValue) content tabs") { scenario in
            let app = scenario.mac.launch(windows: 1)
            app.showContentTabs(in: 1, style: style)
            let tessel = scenario.startTessel()
            scenario.settle()
            scenario.expect("content pages leave one ordinary window", tessel.windows.map(\.id) == [1])
            FoundationProof.row(1, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
        })
    }

    enum ChromeCase: String, CaseIterable { case noCloseButtons, newTabButton, moreContentTabs }

    @Test("#1 E5: native tab counts ignore content tabs and extra controls and require no close buttons", arguments: ChromeCase.allCases)
    func nativeChrome(_ chrome: ChromeCase) {
        requireScenario(Scenario.run("native chrome \(chrome.rawValue)") { scenario in
            let app = scenario.mac.launch(windows: 3)
            app.groupTabs([1, 2, 3], selected: 1)
            if chrome == .newTabButton { app.showNewTabButton(in: 1) }
            if chrome == .moreContentTabs {
                for id: UInt32 in [1, 2, 3] { app.showContentTabs(in: id, count: 5) }
            }
            let tessel = scenario.startTessel()
            for selected: UInt32 in [1, 2] {
                if selected == 2 { app.selectTab(selected) }
                scenario.settle()
                scenario.expect("native chrome leaves one entry", tessel.windows.map(\.id) == [selected])
                FoundationProof.row(selected, in: tessel, state: .tiled, reason: "standard window; 3 native tabs", tabs: 3, scenario: scenario)
            }
        })
    }

    enum InsertionStep: CaseIterable { case select, read, deliver, insert }

    @Test("#1 E5: native insertion keeps one entry under every selection/read/delivery order")
    func insertionReplacesFront() {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let orders = mac.orders(of: InsertionStep.allCases, requiring: [
            .init(.select, before: .read), .init(.read, before: .deliver), .init(.select, before: .insert),
        ])
        #expect(orders.count == 9)
        for order in orders {
            requireScenario(Scenario.run("native insertion around a captured read", writes: order.writes) { scenario in
                let app = scenario.mac.launch(windows: 3)
                app.groupTabs([1, 2, 3], selected: 1)
                let tessel = scenario.startTessel()
                scenario.settle()
                var inserted: UInt32 = 0
                for step in order.steps {
                    switch step {
                    case .select: scenario.step("select tab 2") { app.selectTab(2) }
                    case .insert: scenario.step("insert beside tab 2") { inserted = app.addNativeTab(to: 2) }
                    case .read:
                        scenario.step("capture native-tab read") {
                            let outcome = scenario.mac.pause(after: .read(app))
                            if case .paused = outcome {} else { scenario.expect("expected captured read, got \(outcome)", false) }
                        }
                    case .deliver:
                        scenario.step("deliver captured native-tab read") {
                            let outcome = scenario.mac.deliver(app)
                            if case .paused = outcome {} else { scenario.expect("expected read delivery, got \(outcome)", false) }
                        }
                    }
                }
                scenario.settle()
                scenario.expect("selection plus insertion has one front entry", tessel.windows.map(\.id) == [inserted])
                FoundationProof.row(inserted, in: tessel, state: .tiled, reason: "standard window; 4 native tabs", tabs: 4, scenario: scenario)
                app.close(inserted, selecting: 2)
                scenario.settle()
                scenario.expect("removing the inserted tab restores one three-tab entry", tessel.windows.map(\.id) == [2])
                FoundationProof.row(2, in: tessel, state: .tiled, reason: "standard window; 3 native tabs", tabs: 3, scenario: scenario)
            })
        }
    }

    @Test("#1 E5: lagging AXWindows retires the former root whether native focus arrives immediately or later", arguments: [false, true], WriteOrder.allCases)
    func laggingRoot(_ delayedFocus: Bool, _ writes: WriteOrder) {
        requireScenario(Scenario.run("lagging native root, delayed focus=\(delayedFocus)", writes: writes) { scenario in
            let app = scenario.mac.launch(windows: 3)
            app.groupTabs([1, 2, 3], selected: 1)
            let tessel = scenario.startTessel()
            scenario.settle()
            FoundationProof.row(1, in: tessel, state: .tiled, reason: "standard window; 3 native tabs", tabs: 3, scenario: scenario)
            app.publishWindowList([1])
            if delayedFocus { app.publishFocusedWindow(false) }
            scenario.step("select tab 2 while AXWindows retains tab 1") { app.selectTab(2) }
            scenario.settle()
            if delayedFocus {
                scenario.expect("the old root is observed after losing its bar", tessel.windows.map(\.id) == [1])
                FoundationProof.row(1, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
                scenario.step("publish the native focus after the old bar disappeared") { app.publishFocusedWindow(true) }
                scenario.settle()
            }
            scenario.expect("the focused replacement retires the retained old root", tessel.windows.map(\.id) == [2])
            FoundationProof.row(2, in: tessel, state: .tiled, reason: "standard window; 3 native tabs", tabs: 3, scenario: scenario)
            scenario.step("a later read still lists the retired root") { app.selectTab(2) }
            scenario.settle()
            scenario.expect("later reads keep the former root retired", tessel.windows.map(\.id) == [2])
        })
    }
}
