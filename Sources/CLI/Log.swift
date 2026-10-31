import Foundation
import OSLog

enum Log {
    struct InvalidArguments: Error {}

    private struct Options {
        var json = false
        var last: TimeInterval = 3_600
        var reports = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")

        init(_ arguments: [String]) throws {
            var arguments = arguments.makeIterator()
            var seen: Set<String> = []
            while let argument = arguments.next() {
                guard seen.insert(argument).inserted else { throw InvalidArguments() }
                switch argument {
                case "--json": json = true
                case "--last":
                    guard let value = arguments.next(), let unit = value.last,
                          let multiplier = [Character("m"): 60, "h": 3_600, "d": 86_400][unit] else { throw InvalidArguments() }
                    let digits = value.dropLast()
                    guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                          let count = Int(digits), count > 0 else { throw InvalidArguments() }
                    let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
                    guard !overflow else { throw InvalidArguments() }
                    last = TimeInterval(seconds)
                #if TESSEL_DEVELOPMENT
                case "--reports":
                    guard let path = arguments.next(), !path.isEmpty, !path.hasPrefix("--") else { throw InvalidArguments() }
                    reports = URL(fileURLWithPath: path, isDirectory: true)
                #endif
                default: throw InvalidArguments()
                }
            }
        }
    }

    private struct Entry: Encodable {
        let date: Date
        let level: String
        let category: String
        let pid: Int32
        let message: String
    }

    private struct Report: Encodable {
        let path: String
        let date: Date
    }

    private struct Output: Encodable {
        let entries: [Entry]
        let crashReports: [Report]
    }

    static func run(_ arguments: [String]) throws {
        let options = try Options(arguments)
        let end = Date(), start = end.addingTimeInterval(-options.last)
        let store = try OSLogStore.local()
        let records = try store.getEntries(at: store.position(date: start), matching: NSPredicate(format: "subsystem == %@", Instance.bundleID))
        let entries = records.compactMap { record -> Entry? in
            guard let record = record as? OSLogEntryLog, record.date >= start, record.date <= end else { return nil }
            let level: String
            switch record.level {
            case .notice: level = "notice"
            case .error: level = "error"
            default: return nil
            }
            return Entry(date: record.date, level: level, category: record.category, pid: record.processIdentifier, message: record.composedMessage)
        }
        let reports = crashReports(in: options.reports, from: start, through: end)
        if options.json { try Main.printJSON(Output(entries: entries, crashReports: reports)); return }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss"
        for entry in entries { print("\(time.string(from: entry.date)) \(entry.level) \(entry.category) \(entry.message)") }
        if !reports.isEmpty {
            print("Crash reports:")
            let date = ISO8601DateFormatter()
            for report in reports { print("\(date.string(from: report.date)) \(report.path)") }
        }
    }

    private static func crashReports(in directory: URL, from start: Date, through end: Date) -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        timestamp.isLenient = false
        return files.filter { $0.pathExtension == "ips" }.compactMap { file in
            guard let header = reportHeader(file), header.bundleID == Instance.bundleID,
                  let date = timestamp.date(from: header.timestamp), date >= start, date <= end else { return nil }
            return Report(path: file.path, date: date)
        }.sorted { ($0.date, $0.path) < ($1.date, $1.path) }
    }

    private struct ReportHeader: Decodable {
        let bundleID: String
        let timestamp: String
    }

    /// Read the metadata line only; the crash body is neither parsed nor printed.
    private static func reportHeader(_ file: URL) -> ReportHeader? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            var header = Data()
            while let chunk = try handle.read(upToCount: 4_096), !chunk.isEmpty {
                if let newline = chunk.firstIndex(of: 10) { header.append(chunk[..<newline]); break }
                header.append(chunk)
            }
            return try JSONDecoder().decode(ReportHeader.self, from: header)
        } catch { return nil }
    }
}
