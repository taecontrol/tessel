import Foundation

/// The caller serializes changes on the element owner's lane.
struct ElementSubscriptions<Element, Name: Hashable> {
    private struct Entry {
        let element: Element
        var names: Set<Name> = []
    }
    private let names: [Name]
    private var entries: [Entry] = []
    init(_ names: [Name]) { self.names = names }

    mutating func update(_ elements: [Element], equal: (Element, Element) -> Bool,
                         add: (Element, Name) -> Bool, remove: (Element, Name) -> Void) {
        for old in entries where !elements.contains(where: { equal(old.element, $0) }) {
            for name in old.names { remove(old.element, name) }
        }
        var next: [Entry] = []
        for element in elements {
            guard !next.contains(where: { equal($0.element, element) }) else { continue }
            var entry = entries.first(where: { equal($0.element, element) }) ?? Entry(element: element)
            for name in names where !entry.names.contains(name) {
                if add(element, name) { entry.names.insert(name) }
            }
            next.append(entry)
        }
        entries = next
    }

    mutating func removeAll() { entries.removeAll() }
}
