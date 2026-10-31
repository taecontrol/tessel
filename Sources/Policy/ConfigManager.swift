import Foundation
#if SWIFT_PACKAGE
import Ports
#endif

@MainActor
final class ConfigManager {
    private let main: any MainLane
    private let load: () throws -> Data?
    private let watch: () -> Void
    private var pending: (any ScheduledWork)?
    private var previous: Data?
    private var hasRead = false
    private(set) var status: ConfigStatus
    var onChange: ((ConfigStatus) -> Void)?

    init(path: String, main: any MainLane, diagnostics: any DiagnosticsPort,
         load: @escaping () throws -> Data?, watch: @escaping () -> Void) {
        self.main = main
        self.load = load
        self.watch = watch
        status = ConfigStatus(path: path)
        reload()
        watch()
    }

    func reload() {
        let data: Data?
        do { data = try load() }
        catch {
            hasRead = false
            status.state = "error"
            status.error = ConfigError(line: 1, message: "Unable to read configuration file")
            onChange?(status)
            return
        }
        guard !hasRead || previous != data else { return }
        hasRead = true
        previous = data
        do {
            status.effective = try data.map(ConfigParser.parse) ?? Configuration()
            status.state = data == nil ? "defaults" : "loaded"
            status.error = nil
            status.revision += 1
        } catch let error as ConfigError {
            status.state = "error"
            status.error = error
        } catch {
            status.state = "error"
            status.error = ConfigError(line: 1, message: "Invalid TOML")
        }
        onChange?(status)
    }

    func scheduleReload() {
        pending?.cancel()
        pending = main.after(milliseconds: 30) { [weak self] in
            self?.reload()
            self?.watch() // Editors often replace the inode rather than writing it.
        }
    }
}
