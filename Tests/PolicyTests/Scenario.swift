import Foundation
import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

enum Layout: String, CaseIterable, Sendable { case off, stack, carousel }

@MainActor final class Tessel {
    let workspaces: Workspaces
    let catalog: WindowCatalog
    let config: ConfigManager
    let rows: PublishedRows
    let keys = PressedKeys()
    private(set) var configurationPublications: [(at: Int, status: ConfigStatus)] = []
    private let input: ConfigurationInput
    private let mac: SimulatedMac
    private(set) var quitCompletions = 0
    private(set) var quitReadyAt: Int?

    init(on mac: SimulatedMac, configuration: Layout = .off, text: String? = nil) {
        self.mac = mac
        let input = ConfigurationInput()
        self.input = input
        input.data = text.map { Data($0.utf8) }
        rows = PublishedRows(now: { mac.scheduler.now })
        config = ConfigManager(path: "/scenario/tessel.toml", main: mac.scheduler.main, load: { [input] in
            if input.unreadable { throw CocoaError(.fileReadNoPermission) }
            return input.data
        }, watch: { [input] in input.watchRequests += 1 })
        workspaces = Workspaces(store: rows, trusted: true, configuration: config.status.effective,
                                applications: mac.applications, ax: mac.ax, screens: mac.screens,
                                windowOrder: mac.windowOrder, scheduler: mac.scheduler, hotkeys: keys,
                                fixtureOnly: true, motionPreferences: mac.motionPreferences, stage: mac.stage,
                                pointerActivity: mac.pointerActivity) { mac.closetPort }
        catalog = WindowCatalog(workspaces: workspaces, applications: mac.applications, ax: mac.ax, windowOrder: mac.windowOrder, scheduler: mac.scheduler)
        workspaces.catalog = catalog
        configurationPublications.append((mac.scheduler.now, config.status))
        config.onChange = { [weak self] status in
            guard let self else { return }
            self.configurationPublications.append((mac.scheduler.now, status))
            self.workspaces.configure(status.effective)
        }
        if configuration != .off { configure(configuration) }
    }

    func configure(_ layout: Layout) {
        mac.action("configure \(layout.rawValue)")
        input.data = Data((layout == .off ? "" : "[experiments]\n\(layout == .carousel ? "carousel" : "workspaces") = true\n").utf8)
        input.unreadable = false
        config.reload()
    }
    func changeConfig(_ text: String?, unreadable: Bool = false) {
        changeConfig(contents: text.map { Data($0.utf8) }, unreadable: unreadable)
    }
    func changeConfig(contents: Data?, unreadable: Bool = false) {
        mac.action("change configuration")
        input.data = contents
        input.unreadable = unreadable
        config.scheduleReload()
    }
    func press(_ command: String) {
        mac.action("press \(command)")
        keys.press(command)
    }
    func pressKey(_ chord: String) {
        mac.action("press key \(chord)")
        keys.pressKey(chord)
    }
    var windows: [WindowRecord] { rows.byPID.keys.sorted().flatMap { rows.byPID[$0] ?? [] }.sorted { $0.id < $1.id } }
    var status: WorkspaceStatus { workspaces.status }
    var configuration: ConfigStatus { config.status }
    var configurationWatchRequests: Int { input.watchRequests }
    var windowPublications: [PublishedRows.Publication] { rows.publications }
    func quit() {
        mac.action("quit tessel")
        workspaces.prepareToQuit { [self] in finishQuit() }
    }
    private func finishQuit() {
        quitReadyAt = mac.scheduler.now
        workspaces.disable(reason: "quit")
        quitCompletions += 1
    }
}

@MainActor private final class ConfigurationInput { var data: Data?; var unreadable = false; var watchRequests = 0 }
@MainActor final class PublishedRows: WindowPublishing {
    struct Publication {
        let at: Int
        let pid: Int32
        let windows: [WindowRecord]?
    }
    private let now: () -> Int
    var byPID: [Int32: [WindowRecord]] = [:]
    private(set) var publications: [Publication] = []
    var onUpdate: ((Int32, [WindowRecord]?) -> Void)?
    init(now: @escaping () -> Int) { self.now = now }
    func update(pid: Int32, windows: [WindowRecord]?) {
        let windows = windows?.sorted { $0.id < $1.id }
        byPID[pid] = windows
        publications.append(Publication(at: now(), pid: pid, windows: windows))
        onUpdate?(pid, windows)
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
    func pressKey(_ chord: String) {
        guard let registration, registration.active, let value = registration.keys[chord],
              let command = WorkspaceCommand(value) else { return }
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
    func startTessel(_ configuration: Layout = .off, text: String? = nil) -> Tessel {
        let tessel = Tessel(on: mac, configuration: configuration, text: text)
        tessels.append(tessel)
        return tessel
    }
    func step(_ name: String, _ body: () -> Void) {
        schedule.append(name)
        guard mac.scheduler.failure == nil else { return }
        body()
        if mac.scheduler.writeOrder == .eager { mac.scheduler.runReadyWorkers() }
    }
    func after(milliseconds: Int, _ name: String, _ body: @escaping @MainActor @Sendable () -> Void) {
        mac.scheduler.main.after(milliseconds: milliseconds) { [self] in step(name, body) }
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
        let result = scenario.result()
        ScenarioDigests.shared.record(result)
        return result
    }
}

func requireScenario(_ result: ScenarioResult, sourceLocation: SourceLocation = #_sourceLocation) {
    if !result.failures.isEmpty { Issue.record(Comment(rawValue: result.report), sourceLocation: sourceLocation) }
}
