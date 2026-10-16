import Foundation

@main
struct Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["windows", "status"].contains(command),
              args.count == 1 || (args.count == 2 && args[1] == "--json") else {
            fail("Usage: tessel windows [--json] | tessel status [--json]", code: 2)
        }
        let reply: Reply
        do { reply = try SocketIO.request(command) }
        catch IPCError.timeout { fail("tessel is not responding") }
        catch { fail("tessel is not running") }
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
                    print("tessel \(status.version)")
                    print(status.permission == "granted" ? "Accessibility permission granted" : "Accessibility permission needed")
                    print("Config: \(status.config.path) (\(status.config.state))")
                    if let error = status.config.error { print("Line \(error.line): \(error.message)") }
                }
            } else { fail("Invalid response from tessel") }
        } catch { fail("Could not encode tessel's response") }
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
