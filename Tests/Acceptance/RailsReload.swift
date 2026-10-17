import Foundation
import Darwin
import Testing

extension Acceptance.FunctionalRails {
    @Test(arguments: [true,false])
    func e02LayoutReloadPreservesNativeFocusAwaitingPublication(rails: Bool) throws {
        let a = try open("known",width:0.25)
        try flow.activate(key:"known")
        if rails { try flow.enable(); try flow.expectShown(a) }
        else { try enable(); try focus(a) }
        let d = try fixture.open(kind:"dialog",key:"dialog")
        try #require(try eventually { try harness.row(d)?.workspace == 1 })
        try flow.activate(key:"known"); try focus(a)
        var sutStopped = false, publisherStopped = false
        defer {
            if publisherStopped { kill(fixture.pid,SIGCONT) }
            if sutStopped { kill(harness.appPID,SIGCONT) }
        }
        kill(harness.appPID,SIGSTOP); sutStopped = true
        try flow.activate(key:"dialog"); try focus(d)
        kill(fixture.pid,SIGSTOP); publisherStopped = true
        try writeConfig(rails ? config : flow.enabled)
        kill(harness.appPID,SIGCONT); sutStopped = false
        try #require(try eventually(within:1) { try harness.status().workspaces?.layout == (rails ? "rails" : "stack") })
        kill(fixture.pid,SIGCONT); publisherStopped = false
        try focus(d,within:1)
        #expect(try harness.row(d)?.workspace == 1)
        Thread.sleep(forTimeInterval:0.1)
        try focus(d)
    }
}
