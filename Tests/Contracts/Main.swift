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
        // Another Unix user runs this to show the endpoint refuses it: 0 means denied.
        if CommandLine.arguments.dropFirst().first == "connect", CommandLine.arguments.count == 3 {
            exit(connection(to: CommandLine.arguments[2]))
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

    private static func connection(to path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return 2 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return 1 }
        return errno == EACCES || errno == EPERM ? 0 : 2
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
