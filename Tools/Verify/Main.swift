import Foundation

/// Listing discovers tests without entering any suite's execution scope.
@main
struct VerifySelection {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let root = arguments.first else { throw Failure("missing package path") }
            var includes: [NSRegularExpression] = [], excludes: [NSRegularExpression] = []
            var index = 1
            while index < arguments.count {
                guard index + 1 < arguments.count else { throw Failure("missing test filter") }
                let expression = try NSRegularExpression(pattern: arguments[index + 1])
                switch arguments[index] {
                case "--filter": includes.append(expression)
                case "--skip": excludes.append(expression)
                default: throw Failure("unknown test selection option")
                }
                index += 2
            }
            let listing = Process()
            listing.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            listing.arguments = ["swift", "test", "--package-path", root, "list"]
            listing.standardInput = FileHandle.nullDevice
            let output = Pipe()
            listing.standardOutput = output
            try listing.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            listing.waitUntilExit()
            guard listing.terminationStatus == 0 else { exit(listing.terminationStatus) }
            let tests = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
                .filter { $0.hasPrefix("Acceptance.") }
            func matches(_ expressions: [NSRegularExpression], _ test: String) -> Bool {
                expressions.contains { $0.firstMatch(in: test, range: NSRange(test.startIndex..., in: test)) != nil }
            }
            guard tests.contains(where: { (includes.isEmpty || matches(includes, $0)) && !matches(excludes, $0) }) else {
                throw Failure("no tests match the requested filters")
            }
        } catch {
            FileHandle.standardError.write(Data(("scripts/verify: \(error)\n").utf8))
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
