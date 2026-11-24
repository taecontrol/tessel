/// The value of `tessel log --last`: a positive whole number of minutes, hours or days.
enum LogWindow {
    /// The window in seconds, or nil for any other spelling or a product that overflows.
    static func seconds(_ value: String) -> Int? {
        guard let unit = value.last, let multiplier = ["m": 60, "h": 3_600, "d": 86_400][unit] else { return nil }
        let digits = value.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let count = Int(digits), count > 0 else { return nil }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : seconds
    }
}
