import Foundation

@main struct Check {
    static func main() {
        do {
            let command = try CheckCommand(Array(CommandLine.arguments.dropFirst()))
            let runner = CheckRunner(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            try runner.run(command)
        } catch {
            FileHandle.standardError.write(Data(("tessel-check: \(error)\n").utf8))
            exit(1)
        }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum CheckCommand: Equatable {
    case layers, determinism(Int), simulatorEvidence(base: String, bodyFile: String)

    init(_ arguments: [String]) throws {
        if arguments == ["layers"] { self = .layers }
        else if arguments.count == 3, arguments.prefix(2) == ["determinism", "--runs"], let count = Int(arguments[2]), count > 0 {
            self = .determinism(count)
        } else if arguments.count == 5, arguments[0] == "simulator-evidence", arguments[1] == "--base", arguments[3] == "--body-file",
                  !arguments[2].isEmpty, !arguments[4].isEmpty {
            self = .simulatorEvidence(base: arguments[2], bodyFile: arguments[4])
        } else {
            throw CheckFailure("usage: tessel-check layers | determinism --runs N | simulator-evidence --base REF --body-file PATH")
        }
    }
}
