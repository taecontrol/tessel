import Foundation
import Testing

@Suite struct Integrity {
    @Test("E13: policy uses only injected platform operations")
    func policyIsHeadless() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = ProcessInfo.processInfo.environment["TESSEL_PURITY_PATH"].map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "Sources/Policy")
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.map { directory.appending(path: $0) }.sorted { $0.path < $1.path }
        #expect(!files.isEmpty, "The purity check must inspect production policy")
        for file in files {
            for violation in try PolicyPurity.violations(in: String(contentsOf: file, encoding: .utf8)) {
                Issue.record("\(file.lastPathComponent):\(violation.line): \(violation.rule)")
            }
        }
    }

    @Test("E13: each forbidden category makes the purity check fail")
    func rejectsForbiddenOperations() {
        let examples = [
            "import AppKit", "sleep(1)", "Date()", "Thread.current", "Task {}",
            "DispatchSemaphore(value: 0)", "DispatchQueue.main.async {}", "NSLock()", "kill(7, 0)",
            "NSDate().timeIntervalSince1970", "NSDate.timeIntervalSinceReferenceDate", "ProcessInfo.processInfo.systemUptime"
        ]
        for example in examples {
            #expect(!PolicyPurity.violations(in: example).isEmpty, "Checker accepted \(example)")
        }
        #expect(PolicyPurity.violations(in: "// import AppKit\n/* Date() /* Thread.current */ */\nimport Foundation\nimport CoreGraphics\nimport Ports").isEmpty)
        #expect(PolicyPurity.violations(in: "let text = \"Date() // text\"\nlet raw = #\"NSLock()\"#").isEmpty)
        #expect(PolicyPurity.violations(in: "rails.select(1)\nmutating func select(_ id: Int) {}").isEmpty)
        #expect(PolicyPurity.violations(in: "// comment\n\nDate()").first?.line == 3)
        #expect(!PolicyPurity.violations(in: #"let text = "\(Date())""#).isEmpty)
    }
}

enum PolicyPurity {
    struct Violation { let line: Int; let rule: String }
    private static let rules = [
        ("sleep", #"\b(?:sleep|usleep|nanosleep)\s*\("#),
        ("wall clock", #"\b(?:Date|NSDate)\s*(?:\(|\.)|\bProcessInfo\s*\.\s*processInfo\s*\.\s*systemUptime\b|\b(?:DispatchTime|ContinuousClock|SuspendingClock|CFAbsoluteTimeGetCurrent|CACurrentMediaTime|clock_gettime\w*|gettimeofday|mach_absolute_time|mach_continuous_time)\b"#),
        ("Thread", #"\bThread\b"#),
        ("Task", #"\bTask\b"#),
        ("semaphore", #"\b(?:DispatchSemaphore|sem_\w+)\b"#),
        ("direct GCD", #"\b(?:Dispatch\w+|dispatch_\w+)\b"#),
        ("NSLock", #"\b(?:NSLock|NSRecursiveLock|NSCondition|NSConditionLock)\b"#),
        ("system call", #"(?<![\w.])(?:(?:Darwin|Glibc|Foundation)\s*\.\s*)?(?:kill|getpid|getppid|open|openat|close|read|write|stat|lstat|fstat|socket|connect|bind|listen|accept|poll|select|kqueue|kevent|sysctl|sysctlbyname|pthread_\w+|posix_\w+|fork|exec\w*|system)\s*\("#),
    ]

    static func violations(in source: String) -> [Violation] {
        let code = codeOnly(source)
        let range = NSRange(code.startIndex..., in: code)
        func line(_ match: NSTextCheckingResult) -> Int {
            (code as NSString).substring(to: match.range.location).filter { $0 == "\n" }.count + 1
        }
        var result: [Violation] = []
        let imports = try! NSRegularExpression(pattern: #"\bimport\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z_0-9]*)"#)
        for match in imports.matches(in: code, range: range) {
            let module = (code as NSString).substring(with: match.range(at: 1))
            if !["Foundation", "CoreGraphics", "Ports"].contains(module) {
                result.append(Violation(line: line(match), rule: "forbidden import \(module)"))
            }
        }
        for (rule, pattern) in rules {
            let expression = try! NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: code, range: range) {
                let prefix = (code as NSString).substring(to: match.range.location)
                if rule == "system call", prefix.range(of: #"\bfunc\s*$"#, options: .regularExpression) != nil { continue }
                result.append(Violation(line: line(match), rule: rule))
            }
        }
        return result.sorted { $0.line < $1.line }
    }

    // Mask comments and literals without changing line numbers. Interpolation
    // bodies remain code, including inside raw and multiline string literals.
    static func codeOnly(_ source: String) -> String {
        // NSString and regular expressions use UTF-16 offsets.
        let bytes = Array(source.utf16)
        var result = bytes
        var index = 0
        func matches(_ text: [UInt16]) -> Bool {
            index + text.count <= bytes.count && Array(bytes[index..<(index + text.count)]) == text
        }
        func mask(_ count: Int) {
            for _ in 0..<count where index < bytes.count {
                if bytes[index] != 10 { result[index] = 32 }
                index += 1
            }
        }
        func scan(interpolation: Bool = false) {
            var parentheses = 0
            while index < bytes.count {
                if matches([47, 47]) {
                    while index < bytes.count && bytes[index] != 10 { mask(1) }
                } else if matches([47, 42]) {
                    mask(2)
                    var depth = 1
                    while index < bytes.count && depth > 0 {
                        if matches([47, 42]) { depth += 1; mask(2) }
                        else if matches([42, 47]) { depth -= 1; mask(2) }
                        else { mask(1) }
                    }
                } else {
                    var hashes = 0
                    while index + hashes < bytes.count && bytes[index + hashes] == 35 { hashes += 1 }
                    if index + hashes < bytes.count && bytes[index + hashes] == 34 {
                        mask(hashes)
                        let quotes = matches([34, 34, 34]) ? 3 : 1
                        mask(quotes)
                        let suffix = Array(repeating: UInt16(34), count: quotes) + Array(repeating: UInt16(35), count: hashes)
                        let escape = [UInt16(92)] + Array(repeating: UInt16(35), count: hashes)
                        while index < bytes.count {
                            if matches(suffix) { mask(suffix.count); break }
                            if matches(escape) {
                                mask(escape.count)
                                if matches([40]) { mask(1); scan(interpolation: true) }
                                else { mask(1) }
                            } else { mask(1) }
                        }
                    } else if interpolation && bytes[index] == 41 && parentheses == 0 {
                        mask(1); return
                    } else {
                        if bytes[index] == 40 { parentheses += 1 }
                        if bytes[index] == 41 { parentheses -= 1 }
                        index += 1
                    }
                }
            }
        }
        scan()
        return String(decoding: result, as: UTF16.self)
    }
}
