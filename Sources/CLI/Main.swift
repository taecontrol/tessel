import Foundation

@main
struct Main {
    static let usage = "Usage: tessel windows [--json] | tessel status [--json] | tessel log [--json] [--last <n>m|h|d]" + reportsUsage
    private static var reportsUsage: String {
        #if TESSEL_DEVELOPMENT
        " [--reports <dir>]"
        #else
        ""
        #endif
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "log" {
            do { try Log.run(Array(args.dropFirst())) }
            catch is Log.InvalidArguments { fail(usage, code: 2) }
            catch { fail(error.localizedDescription) }
            return
        }
        guard let command = args.first, ["windows", "status"].contains(command),
              args.count == 1 || (args.count == 2 && args[1] == "--json") else {
            fail(usage, code: 2)
        }
        let reply: Reply
        do { reply = try SocketIO.request(command) }
        catch let error as IPCError { fail(error.cliMessage) }
        catch { fail("Tessel is not running") }
        if let error = reply.error { fail(error) }
        do {
            if command == "windows", let windows = reply.windows {
                if args.contains("--json") { try printJSON(windows) }
                else {
                    for window in windows {
                        print("\(window.id)\t\(window.app)\t\(window.state.rawValue)\t\(window.reason)")
                    }
                }
            } else if command == "status", let status = reply.status {
                if args.contains("--json") { try printJSON(status) }
                else {
                    print("Tessel \(status.version)")
                    print(status.permission == "granted" ? "Accessibility permission granted" : "Accessibility permission needed")
                    print(status.openAtLogin.text)
                    print("Config: \(status.config.path) (\(status.config.state))")
                    if let error = status.config.error { print("Line \(error.line): \(error.message)") }
                }
            } else { fail("Invalid response from Tessel") }
        } catch { fail("Could not encode Tessel's response") }
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
