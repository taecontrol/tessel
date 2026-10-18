import ApplicationServices

/// Owns notification registrations for a changing set of AX elements.
/// The caller serializes updates on its app's AX queue.
struct AXSubscriptions {
    private var subscriptions: ElementSubscriptions<AXUIElement, String>
    init(_ names: [String]) { subscriptions = ElementSubscriptions(names) }

    mutating func update(_ elements: [AXUIElement],
                         add: (AXUIElement, String) -> AXError,
                         remove: (AXUIElement, String) -> Void) {
        subscriptions.update(elements, equal: { CFEqual($0, $1) }, add: { element, name in
            let result = add(element, name)
            return result == .success || result == .notificationAlreadyRegistered || result == .notificationUnsupported
        }, remove: remove)
    }

    mutating func removeAll() { subscriptions.removeAll() }
}
