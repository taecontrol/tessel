import Foundation

enum WorkspaceCommand: Sendable {
    case workspace(Int), send(Int), next, previous

    init?(_ text: String) {
        switch text {
        case "focus next": self = .next
        case "focus previous": self = .previous
        default:
            let parts = text.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, let number = Int(parts[1]), (1...10).contains(number), String(number) == parts[1] else { return nil }
            switch parts[0] {
            case "workspace": self = .workspace(number)
            case "send": self = .send(number)
            default: return nil
            }
        }
    }
}

/// Physical ANSI key positions, independent of the input source's Option text.
struct KeyChord: Sendable {
    static let codes: [String: UInt32] = [
        "a":0, "s":1, "d":2, "f":3, "h":4, "g":5, "z":6, "x":7, "c":8, "v":9,
        "b":11, "q":12, "w":13, "e":14, "r":15, "y":16, "t":17,
        "1":18, "2":19, "3":20, "4":21, "6":22, "5":23, "9":25, "7":26, "8":28, "0":29,
        "o":31, "u":32, "i":34, "p":35, "l":37, "j":38, "k":40, "n":45, "m":46,
    ]
    static let modifierOrder = ["alt", "shift", "ctrl", "cmd"]
    let code: UInt32
    let modifiers: Set<String>
    let name: String

    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, let code = Self.codes[key] else { return nil }
        let modifiers = Set(parts.dropLast())
        guard modifiers.count == parts.count - 1, modifiers.isSubset(of: Set(Self.modifierOrder)) else { return nil }
        self.code = code
        self.modifiers = modifiers
        name = (Self.modifierOrder.filter { modifiers.contains($0) } + [key]).joined(separator: "-")
    }

    static let defaults: [String: String] = {
        var keys = ["alt-j": "focus next", "alt-k": "focus previous"]
        for number in 1...10 {
            let digit = number == 10 ? 0 : number
            keys["alt-\(digit)"] = "workspace \(number)"
            keys["alt-shift-\(digit)"] = "send \(number)"
        }
        return keys
    }()
}
