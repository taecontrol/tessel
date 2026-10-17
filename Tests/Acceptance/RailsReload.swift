import Foundation
import Darwin
import Testing

extension Acceptance.FunctionalRails {
    @Test(arguments: [true,false], ["layout","gaps","both"])
    func e02LayoutReloadPreservesNativeFocusAwaitingPublication(rails: Bool, change: String) throws {
        try reloadPreservingFocus(rails: rails, change: change, crossApp: false)
    }

    @Test(arguments: [true,false], ["layout","gaps","both"])
    func e02e16CrossApplicationReloadPreservesSelectionAwaitingPublication(rails: Bool, change: String) throws {
        try reloadPreservingFocus(rails: rails, change: change, crossApp: true)
    }

    private func reloadPreservingFocus(rails: Bool, change: String, crossApp: Bool) throws {
        let a = try open("known",width:0.25)
        try flow.activate(key:"known")
        let startsInRails = change == "gaps" ? rails : !rails
        if startsInRails { try enable(); try focus(a) }
        else { try flow.enable(); try flow.expectShown(a) }
        let publisher = try crossApp ? flow.other() : fixture
        let d = try publisher.open(kind:"dialog",key:"dialog")
        try #require(try eventually { try harness.row(d)?.workspace == 1 })
        try flow.activate(key:"known"); try focus(a)
        var sutStopped = false, publisherStopped = false
        defer {
            if publisherStopped { kill(publisher.pid,SIGCONT) }
            if sutStopped { kill(harness.appPID,SIGCONT) }
        }
        kill(harness.appPID,SIGSTOP); sutStopped = true
        try flow.activate(publisher,key:"dialog"); try focus(d)
        kill(publisher.pid,SIGSTOP); publisherStopped = true
        try writeConfig((rails ? config : flow.enabled) + (change == "layout" ? "" : "[gaps]\nouter = 11\n"))
        kill(harness.appPID,SIGCONT); sutStopped = false
        try #require(try eventually(within:1) {
            let status = try harness.status().workspaces
            return status?.layout == (rails ? "rails" : "stack")
                && status?.gaps.outer == (change == "layout" ? 10 : 11)
        })
        kill(publisher.pid,SIGCONT); publisherStopped = false
        try focus(d,within:1)
        #expect(try harness.row(d)?.workspace == 1)
        Thread.sleep(forTimeInterval:0.1)
        try focus(d)
        if crossApp {
            try flow.key(2,send:true)
            try #require(try eventually { try harness.row(d)?.workspace == 2 }, "native dialog selection must also own send")
        }
    }
}
