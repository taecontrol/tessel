import AppKit

/// LaunchServices hands back a pid before the replacement waits for our exit.
@MainActor
enum SystemRelaunch {
    static func launch(_ done: @escaping @MainActor (Result<Int32, RestartLaunchError>) -> Void) {
        guard !LaunchOptions.failedRelaunch else {
            done(.failure(RestartLaunchError(reason: "Launch refused by test argument")))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--restart-after", String(getpid())] + LaunchOptions.restartArguments
        if let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            configuration.environment = ["XDG_CONFIG_HOME": home]
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let result: Result<Int32, RestartLaunchError>
            if let error { result = .failure(RestartLaunchError(reason: error.localizedDescription)) }
            else if let pid = app?.processIdentifier, pid > 0, pid != getpid() { result = .success(pid) }
            else { result = .failure(RestartLaunchError(reason: "LaunchServices returned no replacement process")) }
            DispatchQueue.main.async { done(result) }
        }
    }

    private static var exitSource: DispatchSourceProcess?
    private static var timeout: DispatchSourceTimer?

    /// Called after AppKit finishes launching; no endpoint or window setup may precede it.
    /// SIGTERM keeps its default disposition until setup installs the cleanup handler.
    static func awaitPrevious(ready: @escaping @MainActor () -> Void,
                              abandoned: @escaping @MainActor (Int32) -> Void) -> Bool {
        guard let pid = LaunchOptions.restartAfter else { return false }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        exitSource = source
        timeout = timer
        source.setEventHandler { MainActor.assumeIsolated { finishWaiting(ready) } }
        timer.setEventHandler {
            MainActor.assumeIsolated {
                // Exit and timeout notifications can arrive on the same turn.
                if kill(pid, 0) == -1, errno == ESRCH { finishWaiting(ready) }
                else { finishWaiting { abandoned(pid) } }
            }
        }
        timer.schedule(deadline: .now() + (LaunchOptions.shortRestartWait ? 1 : 10))
        source.resume()
        timer.resume()
        // Close the race where the previous process exited before registration.
        if kill(pid, 0) == -1, errno == ESRCH { finishWaiting(ready) }
        return true
    }

    private static func finishWaiting(_ completion: () -> Void) {
        guard exitSource != nil else { return }
        exitSource?.cancel()
        timeout?.cancel()
        exitSource = nil
        timeout = nil
        completion()
    }
}
