import Foundation

enum WorkspaceCommand: Sendable {
    case workspace(Int), send(Int), next, previous, recent, focus(Direction), move(Direction), cycleWidth
    case toggleLayer, toggleFloat

    enum Direction: String, Sendable { case left, right, up, down }

    init?(_ text: String) {
        switch text {
        case "toggle layer": self = .toggleLayer
        case "toggle float": self = .toggleFloat
        case "cycle width": self = .cycleWidth
        case "focus next": self = .next
        case "focus previous": self = .previous
        case "focus recent": self = .recent
        default:
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            if words.count == 2, let direction = Direction(rawValue: String(words[1])) {
                if words[0] == "focus" { self = .focus(direction); return }
                if words[0] == "move" { self = .move(direction); return }
            }
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
        "o":31, "u":32, "i":34, "p":35, "l":37, "j":38, "k":40, "n":45, "m":46, "tab":48,
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

    static var carouselDefaults: [String:String] {
        var keys = defaults
        keys["alt-r"] = "cycle width"
        for (key,direction) in [("h","left"),("j","down"),("k","up"),("l","right")] {
            keys["alt-"+key] = "focus "+direction
            keys["alt-shift-"+key] = "move "+direction
        }
        return keys
    }

    static var layerDefaults: [String:String] {
        carouselDefaults.merging(["alt-z": "toggle layer", "alt-f": "toggle float"]) { _, new in new }
    }

    static let defaults: [String: String] = {
        var keys = ["alt-j": "focus next", "alt-k": "focus previous", "alt-tab": "focus recent"]
        for number in 1...10 {
            let digit = number == 10 ? 0 : number
            keys["alt-\(digit)"] = "workspace \(number)"
            keys["alt-shift-\(digit)"] = "send \(number)"
        }
        return keys
    }()
}
