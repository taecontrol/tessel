import Foundation
import Testing

enum AcceptanceWaits {
    struct Violation {
        let line: Int
        let spelling: String
    }

    static func violations(in source: String) -> [Violation] {
        let code = PolicyPurity.codeOnly(source) as NSString
        // Retired spellings stay guarded so a shorter deadline cannot return.
        let labels = try! NSRegularExpression(pattern: #"\b(since|within|timeout|deadline|until|seconds)\s*:"#)
        var consumed = 0, line = 1
        let explicit: [Violation] = labels.matches(in: code as String, range: NSRange(location: 0, length: code.length)).compactMap { match in
            line += code.substring(with: NSRange(location: consumed, length: match.range.location - consumed)).filter { $0 == "\n" }.count
            consumed = match.range.location
            let spelling = code.substring(with: match.range(at: 1))
            let call = containingCall(before: match.range.location, code: code)
            if spelling == "seconds", call?.name != "setTimeout" { return nil }
            let expression = argument(after: NSMaxRange(match.range), code: code)
            if let call, ["run", "setTimeout", "init"].contains(call.name),
               code.substring(to: call.open).range(of: #"\b(?:func\s+\w+|init)\s*$"#, options: .regularExpression) != nil,
               ["Double", "Double = margin"].contains(expression) { return nil }
            // Transport primitives forward the caller's checked limit. Their
            // declarations may default only to margin; all call sites are scanned.
            if call?.name == "wait", expression.range(of: #"^\.now\(\)\s*\+\s*timeout$"#, options: .regularExpression) != nil,
               insideWrapper("func run", at: match.range.location, code: code) { return nil }
            if call?.name == "setTimeout", expression == "timeout",
               insideWrapper("init", at: match.range.location, code: code) { return nil }
            if let call, call.name == "run" {
                let arguments = (source as NSString).substring(from: call.open + 1)
                // Compiler and CI permission provisioning process limits do not
                // judge a real-system state. All app/CLI waits still use margin.
                if nonStateProcess(arguments) { return nil }
            }
            if spelling != "since", expression == "margin" || expression.range(of: #"^\.now\(\)\s*\+\s*margin$"#, options: .regularExpression) != nil { return nil }
            return Violation(line: line, spelling: spelling + ": " + expression)
        }
        let calls = try! NSRegularExpression(pattern: #"\b(eventually|eventualValue|converges|run)\s*([({])"#)
        let implicit: [Violation] = calls.matches(in: code as String, range: NSRange(location: 0, length: code.length)).compactMap { match in
            let prefix = code.substring(with: NSRange(location: max(0, match.range.location - 16), length: min(16, match.range.location)))
            if prefix.range(of: #"\bfunc\s*$"#, options: .regularExpression) != nil { return nil }
            let name = code.substring(with: match.range(at: 1))
            if name == "run", prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".") { return nil }
            let open = match.range(at: 2).location
            if name == "run", nonStateProcess((source as NSString).substring(from: open + 1)) { return nil }
            let label = name == "run" ? "timeout" : "within"
            var end = open + 1, depth = 0, argumentStart = open + 1, hasLabel = false
            if code.character(at: open) == 40 {
                while end < code.length {
                    let unit = code.character(at: end)
                    if depth == 0 && unit == 41 { break }
                    if depth == 0 && unit == 44 { argumentStart = end + 1 }
                    if depth == 0 && unit == 58,
                       code.substring(with: NSRange(location: argumentStart, length: end - argumentStart)).trimmingCharacters(in: .whitespacesAndNewlines) == label {
                        hasLabel = true
                    }
                    if [UInt16(40), 91, 123].contains(unit) { depth += 1 }
                    if [UInt16(41), 93, 125].contains(unit) { depth -= 1 }
                    end += 1
                }
            }
            if hasLabel { return nil }
            return Violation(line: code.substring(to: match.range.location).filter { $0 == "\n" }.count + 1,
                             spelling: "\(name) omits \(label): margin and inherits a legacy default")
        }
        return (explicit + implicit).sorted { $0.line < $1.line }
    }

    private static func nonStateProcess(_ arguments: String) -> Bool {
        arguments.range(of: #"^\s*\[\s*(?:buildTool\.path\b|provision\b|"xcrun")"#, options: .regularExpression) != nil
    }

    private static func insideWrapper(_ name: String, at location: Int, code: NSString) -> Bool {
        let declarations = try! NSRegularExpression(pattern: #"\b"# + name + #"\s*\("#)
        for declaration in declarations.matches(in: code as String, range: NSRange(location: 0, length: location)) {
            let open = code.range(of: "{", range: NSRange(location: NSMaxRange(declaration.range), length: code.length - NSMaxRange(declaration.range))).location
            guard open != NSNotFound, open < location else { continue }
            var depth = 1, end = open + 1
            while end < code.length && depth > 0 {
                if code.character(at: end) == 123 { depth += 1 }
                if code.character(at: end) == 125 { depth -= 1 }
                end += 1
            }
            if location < end { return true }
        }
        return false
    }

    private static func argument(after start: Int, code: NSString) -> String {
        var index = start, depth = 0
        while index < code.length {
            let unit = code.character(at: index)
            if depth == 0 && [UInt16(44), 41, 93, 125, 123].contains(unit) { break }
            if [UInt16(40), 91, 123].contains(unit) { depth += 1 }
            if [UInt16(41), 93, 125].contains(unit) { depth -= 1 }
            index += 1
        }
        return code.substring(with: NSRange(location: start, length: index - start)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containingCall(before end: Int, code: NSString) -> (name: String, open: Int)? {
        var depth = 0
        for index in (0..<end).reversed() {
            let unit = code.character(at: index)
            if unit == 41 { depth += 1 }
            if unit == 40 {
                if depth > 0 { depth -= 1; continue }
                var end = index
                while end > 0 && [UInt16(32), 9, 10, 13].contains(code.character(at: end - 1)) { end -= 1 }
                var start = end
                while start > 0 {
                    let character = code.character(at: start - 1)
                    guard (65...90).contains(character) || (97...122).contains(character) || (48...57).contains(character) || character == 95 else { break }
                    start -= 1
                }
                guard start < end else { return nil }
                return (code.substring(with: NSRange(location: start, length: end - start)), index)
            }
        }
        return nil
    }
}

@Suite struct AcceptanceWaitIntegrity {
    @Test("E17: the wait checker rejects each old deadline spelling")
    func negativeControls() {
        for source in ["focus(1, since: start)", "eventually(within: 0.5) { true }", "wait(until: deadline, for: predicate)",
                       "wait(timeout: .now() + 0.2)", "expectShown(1, within: remaining)", "poll(deadline: end)",
                       "run([cli.path], timeout: 1)", "setTimeout(socket, seconds: 0.9)", "eventually { true }",
                       "eventualValue { 1 }", "eventually({ true })", "converges { $0.isEmpty }", "run([cli.path])",
                       "run(command(timeout: margin))", "run([cli.path], check: try run([cli.path], timeout: margin).status == 0)",
                       "func run(_ command: [String], timeout: Double = 1) {}",
                       "exited.wait(timeout: .now() + timeout)", "setTimeout(socket, seconds: timeout)"] {
            #expect(!AcceptanceWaits.violations(in: source).isEmpty, "Accepted \(source)")
        }
        for source in ["eventually(within: margin) { true }", "wait(timeout: .now() + margin)", "setTimeout(socket, seconds: margin)",
                       "finalState { true }", "run([buildTool.path], timeout: 600)", "run([provision], timeout: 30)",
                       "run([\"xcrun\", \"swiftc\"], timeout: 120)", "run([cli.path], timeout: margin)", "try process.run()",
                       "run(commands.map { $0 }, timeout: margin)",
                       "func run(_ command: [String], timeout: Double = margin) throws -> ProcessResult { exited.wait(timeout: .now() + timeout) }",
                       "init(path: String, timeout: Double) throws { setTimeout(socket, seconds: timeout) }",
                       "// focus(1, since: start)\nlet text = \"within: 0.5\""] {
            #expect(AcceptanceWaits.violations(in: source).isEmpty, "Rejected \(source)")
        }
        #expect(AcceptanceWaits.violations(in: "// 🧶\nfocus(1, since: start)").first?.line == 2)
    }

    @Test("E17: only latency judges real-system elapsed time")
    func sourceWaits() throws {
        var current: [String] = []
        for file in try IntegritySources.files(in: "Tests/Acceptance") where URL(fileURLWithPath: file.path).lastPathComponent != "Latency.swift" {
            for violation in AcceptanceWaits.violations(in: file.source) {
                let message = "\(file.path):\(violation.line): \(violation.spelling)"
                current.append(message)
            }
        }
        #expect(current.isEmpty, "Real-system waits must use margin:\n\(current.joined(separator: "\n"))")
    }
}
