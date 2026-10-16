import ApplicationServices

/// Owns notification registrations for a changing set of AX elements.
/// The caller serializes updates on its app's AX queue.
struct AXSubscriptions {
    private struct Entry {
        let element: AXUIElement
        var names: Set<String> = []
    }

    private let names: [String]
    private var entries: [Entry] = []

    init(_ names: [String]) { self.names = names }

    mutating func update(_ elements: [AXUIElement],
                         add: (AXUIElement, String) -> AXError,
                         remove: (AXUIElement, String) -> Void) {
        for old in entries where !elements.contains(where: { CFEqual(old.element, $0) }) {
            for name in old.names { remove(old.element, name) }
        }
        var next: [Entry] = []
        for element in elements {
            guard !next.contains(where: { CFEqual($0.element, element) }) else { continue }
            var entry = entries.first(where: { CFEqual($0.element, element) }) ?? Entry(element: element)
            for name in names where !entry.names.contains(name) {
                _ = add(element, name)
                entry.names.insert(name)
            }
            next.append(entry)
        }
        entries = next
    }

    mutating func removeAll() { entries.removeAll() }
}
