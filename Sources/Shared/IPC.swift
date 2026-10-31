import CryptoKit
import Darwin
import Foundation

enum Instance {
    static let bundleID: String = {
        // Foundation loses the containing bundle when a secondary executable is
        // reached through a symlink. Resolve the real Contents/MacOS location.
        let bundleURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = Bundle.main.bundleIdentifier ?? bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            ?? "com.taecontrol.tessel.dev"
        return bundle.hasSuffix(".cli") ? String(bundle.dropLast(4)) : bundle
    }()
}

struct Endpoint {
    let directory: String
    let path: String

    init() {
        directory = "/tmp/tessel-\(getuid())"
        let key = Instance.bundleID + ":" + ConfigLocation.file.path
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        path = directory + "/" + hash + ".sock"
    }

    func prepareDirectory() throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST { throw IPCError.unsafeEndpoint }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw IPCError.unsafeEndpoint }
    }

    func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError.unsafeEndpoint }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

enum SocketIO {
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func wait(_ fd: Int32, for events: Int16, until deadline: UInt64) throws {
        try SocketDeadline(until: deadline, now: { DispatchTime.now().uptimeNanoseconds }).wait {
            readiness(fd, for: events, milliseconds: $0)
        }
    }

    private static func readiness(_ fd: Int32, for events: Int16, milliseconds: Int32) -> SocketDeadline.Readiness {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, milliseconds)
        if result > 0 { return descriptor.revents & events != 0 ? .ready : .unavailable }
        if result == 0 { return .timeout }
        return errno == EINTR ? .interrupted : .unavailable
    }

    static func readLine(_ fd: Int32, limit: Int, until deadline: UInt64) throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: min(4096, limit))
        while data.count <= limit {
            try wait(fd, for: Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                if let newline = bytes.prefix(count).firstIndex(of: 10) {
                    data.append(contentsOf: bytes[..<newline])
                    guard data.count <= limit else { throw IPCError.invalidMessage }
                    return data
                }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                throw IPCError.unavailable
            } else if errno != EINTR, errno != EAGAIN { throw IPCError.unavailable }
        }
        throw IPCError.invalidMessage
    }

    static func writeLine(_ value: Data, to fd: Int32, until deadline: UInt64) throws {
        let data = value + Data([10])
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, for: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count == 0 || (errno != EINTR && errno != EAGAIN) { throw IPCError.unavailable }
            }
        }
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func request(_ command: String) throws -> Reply {
        let timing = SocketDeadline.request(now: { DispatchTime.now().uptimeNanoseconds })
        let deadline = timing.nanoseconds
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.unavailable }
        defer { close(fd) }
        configure(fd)
        let result = try Endpoint().withAddress { Darwin.connect(fd, $0, $1) }
        let connection: SocketDeadline.Connection = result == 0 ? .connected : errno == EINPROGRESS ? .pending : .unavailable
        try timing.connect(connection) { readiness(fd, for: Int16(POLLOUT), milliseconds: $0) }
        if result != 0 {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw IPCError.unavailable }
        }
        guard sameUser(fd) else { throw IPCError.unsafeEndpoint }
        try writeLine(Data(command.utf8), to: fd, until: deadline)
        return try JSONDecoder().decode(Reply.self, from: readLine(fd, limit: 1_048_576, until: deadline))
    }
}
