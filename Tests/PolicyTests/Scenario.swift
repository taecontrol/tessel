import Foundation
import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

enum Layout: String, CaseIterable, Sendable { case off, stack, rails }

@MainActor final class Tessel {
    let workspaces: Workspaces
    let catalog: WindowCatalog
    let config: ConfigManager
    let rows = PublishedRows()
    let keys = PressedKeys()
    private let input = ConfigurationInput()
    private let mac: SimulatedMac

    init(on mac: SimulatedMac, configuration: Layout = .off) {
        self.mac = mac
        config = ConfigManager(path: "/scenario/tessel.toml", main: mac.scheduler.main, load: { [input] in
            if input.unreadable { throw CocoaError(.fileReadNoPermission) }
            return input.data
        }, watch: {})
        workspaces = Workspaces(store: rows, trusted: true, configuration: config.status.effective,
                                applications: mac.applications, ax: mac.ax, screens: mac.screens,
                                windowOrder: mac.windowOrder, scheduler: mac.scheduler, hotkeys: keys,
                                fixtureOnly: true) { mac.closetPort }
        catalog = WindowCatalog(workspaces: workspaces, applications: mac.applications, ax: mac.ax, scheduler: mac.scheduler)
        workspaces.catalog = catalog
        config.onChange = { [weak workspaces] in workspaces?.configure($0.effective) }
        if configuration != .off { configure(configuration) }
    }

    func configure(_ layout: Layout) {
        mac.action("configure \(layout.rawValue)")
        input.data = Data((layout == .off ? "" : "[experiments]\n\(layout == .rails ? "rails" : "workspaces") = true\n").utf8)
        input.unreadable = false
        config.reload()
    }
    func changeConfig(_ text: String?, unreadable: Bool = false) {
        mac.action("change configuration")
        input.data = text.map { Data($0.utf8) }
        input.unreadable = unreadable
        config.scheduleReload()
    }
    func press(_ command: String) {
        mac.action("press \(command)")
        keys.press(command)
    }
    var windows: [WindowRecord] { rows.byPID.keys.sorted().flatMap { rows.byPID[$0] ?? [] }.sorted { $0.id < $1.id } }
    var status: WorkspaceStatus { workspaces.status }
    var configuration: ConfigStatus { config.status }
    func quit() { mac.action("quit tessel"); workspaces.disable(reason: "quit") }
}

@MainActor private final class ConfigurationInput { var data: Data?; var unreadable = false }
@MainActor final class PublishedRows: WindowPublishing {
    var byPID: [Int32: [WindowRecord]] = [:]
    var onUpdate: ((Int32, [WindowRecord]?) -> Void)?
    func update(pid: Int32, windows: [WindowRecord]?) {
        byPID[pid] = windows?.sorted { $0.id < $1.id }
        onUpdate?(pid, byPID[pid])
    }
}
@MainActor final class PressedKeys: HotkeyInstalling {
    private var registration: Registration?
    func install(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) throws -> any HotkeyRegistration {
        let registration = Registration(keys: keys, perform: perform)
        self.registration = registration
        return registration
    }
    func press(_ command: String) {
        guard let registration, registration.active, registration.keys.values.contains(command),
              let command = WorkspaceCommand(command) else { Issue.record("Command has no registered hotkey"); return }
        registration.perform(command)
    }
    private final class Registration: HotkeyRegistration {
        let keys: [String: String]
        let perform: (WorkspaceCommand) -> Void
        var active = true
        init(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) { self.keys = keys; self.perform = perform }
        func stop() { active = false }
    }
}

struct ScenarioResult {
    let failures: [String]
    let schedule: [String]
    let trace: [String]
    var digest: String { BatonScheduler.digest(trace.joined(separator: "\n") + "\n") }
    var report: String {
        failures.map { "Expectation: \($0)" }.joined(separator: "\n")
            + "\nSchedule: " + schedule.joined(separator: " → ")
            + "\nTrace:\n" + trace.joined(separator: "\n")
    }
}

@MainActor final class Scenario {
    let mac: SimulatedMac
    private var tessels: [Tessel] = []
    private var failures: [String] = []
    private var schedule: [String]

    init(_ name: String, writes: WriteOrder = .writesFirst) {
        mac = SimulatedMac()
        mac.scheduler.writeOrder = writes
        schedule = [name, "writes=\(writes.rawValue)"]
    }
    func startTessel(_ configuration: Layout = .off) -> Tessel {
        let tessel = Tessel(on: mac, configuration: configuration)
        tessels.append(tessel)
        return tessel
    }
    func step(_ name: String, _ body: () -> Void) {
        schedule.append(name)
        guard mac.scheduler.failure == nil else { return }
        body()
        if mac.scheduler.writeOrder == .eager { mac.scheduler.runReadyWorkers() }
    }
    func expect(_ expectation: String, _ condition: @autoclosure () -> Bool) {
        if !condition() { failures.append(expectation) }
    }
    @discardableResult func settle() -> RunOutcome {
        let outcome = mac.settle()
        if outcome != .settled { failures.append("Expected settled, got \(outcome)") }
        return outcome
    }
    func result() -> ScenarioResult {
        if let failure = mac.scheduler.failure { failures.append(failure.description) }
        return ScenarioResult(failures: failures, schedule: schedule, trace: mac.scheduler.trace)
    }
    static func run(_ name: String, writes: WriteOrder = .writesFirst, _ body: (Scenario) -> Void) -> ScenarioResult {
        let scenario = Scenario(name, writes: writes)
        defer { scenario.mac.shutdown() }
        body(scenario)
        return scenario.result()
    }
}

func requireScenario(_ result: ScenarioResult, sourceLocation: SourceLocation = #_sourceLocation) {
    if !result.failures.isEmpty { Issue.record(Comment(rawValue: result.report), sourceLocation: sourceLocation) }
}
