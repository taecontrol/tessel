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

    @Test(arguments: [true,false])
    func e02e16EmptyWorkspaceReloadRetainsExternalActivation(rails: Bool) throws {
        let a = try open("known",width:0.25)
        try flow.activate(key:"known")
        if rails { try enable(); try focus(a) }
        else { try flow.enable(); try flow.expectShown(a) }
        let other = try flow.other()
        let d = try other.open(kind:"dialog",key:"dialog")
        try flow.activate(other,key:"dialog"); try focus(d)
        try #require(try eventually { try harness.row(d)?.workspace == 1 })
        if try flow.observe(finder:true).finderHasNoOrdinaryWindows != true {
            try #require(!onDisposableRunner,"CI must expose only Finder's desktop for this journey")
            print("Skipping empty-workspace reload: Finder's desktop cannot be safely activated")
            return
        }
        try flow.expectEmpty(since:flow.key(2))
        try #require(try harness.status().workspaces?.active == 2)
        var sutStopped = false, publisherStopped = false
        defer {
            if publisherStopped { kill(other.pid,SIGCONT) }
            if sutStopped { kill(harness.appPID,SIGCONT) }
        }
        kill(harness.appPID,SIGSTOP); sutStopped = true
        try flow.activate(other,key:"dialog")
        try #require(try flow.observe(focusedOnly:true).frontmostFixturePID == other.pid)
        kill(other.pid,SIGSTOP); publisherStopped = true
        try writeConfig((rails ? config : flow.enabled)+"[gaps]\nouter = 11\n")
        kill(harness.appPID,SIGCONT); sutStopped = false
        try #require(try eventually(within:1) { try harness.status().workspaces?.gaps.outer == 11 })
        Thread.sleep(forTimeInterval:0.1)
        #expect(try flow.observe(focusedOnly:true).frontmostFixturePID == other.pid,
                "a nonfocusing gap reload must retain native activation while its facts are delayed")
        kill(other.pid,SIGCONT); publisherStopped = false
        try focus(d,within:1)
        #expect(try harness.status().workspaces?.active == 1)
    }
}
