import ApplicationServices
import Darwin
import Foundation

@main
struct NativeContracts {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "namespace" {
            print(Endpoint().path)
            return
        }

        // These handles are never queried. Only their local CF identity matters.
        let first = AXUIElementCreateApplication(getpid())
        let same = AXUIElementCreateApplication(getpid())
        let names = ["created", "already", "unsupported", "transient", "disabled", "gone"]
        var subscriptions = AXSubscriptions(names)
        var attempts: [String: Int] = [:]
        var removed: Set<String> = []
        let add: (AXUIElement, String) -> AXError = { _, name in
            attempts[name, default: 0] += 1
            switch name {
            case "already": return .notificationAlreadyRegistered
            case "unsupported": return .notificationUnsupported
            case "transient" where attempts[name] == 1: return .cannotComplete
            case "disabled" where attempts[name] == 1: return .apiDisabled
            case "gone" where attempts[name] == 1: return .invalidUIElement
            default: return .success
            }
        }
        let remove: (AXUIElement, String) -> Void = { _, name in removed.insert(name) }

        subscriptions.update([first, same], add: add, remove: remove)
        check(names.allSatisfy { attempts[$0] == 1 }, "Equivalent AX handles were registered twice")
        subscriptions.update([same], add: add, remove: remove)
        subscriptions.update([first], add: add, remove: remove)
        for name in ["transient", "disabled", "gone"] {
            check(attempts[name] == 2, "Transient AX registration failure was not retried")
        }
        for name in ["created", "already", "unsupported"] {
            check(attempts[name] == 1, "Completed AX registration was repeated")
        }
        subscriptions.update([], add: add, remove: remove)
        check(removed.isSuperset(of: ["created", "already", "transient", "disabled", "gone"]),
              "Retired AX elements kept their registrations")
        subscriptions.update([first], add: add, remove: remove)
        check(attempts["created"] == 2, "A returning AX element was not registered again")
        print("Native subscription contracts passed")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
