import Darwin
import Foundation

@MainActor
final class ConfigFile {
    let file = ConfigLocation.file
    private var watchers: [String: (source: DispatchSourceFileSystemObject, device: dev_t, inode: ino_t)] = [:]
    var onChange: (() -> Void)?

    init() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func load() throws -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            return try handle.read(upToCount: 65_537) ?? Data()
        }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch CocoaError.fileNoSuchFile { return nil }
    }

    func watch() {
        let directory = file.deletingLastPathComponent()
        var ancestor = directory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        let paths = Set([file.path, directory.path, ancestor.path])
        for path in watchers.keys where !paths.contains(path) {
            watchers.removeValue(forKey: path)?.source.cancel()
        }
        for path in paths {
            var info = stat()
            if stat(path, &info) == 0, let previous = watchers[path], previous.device == info.st_dev, previous.inode == info.st_ino {
                continue // Keep the existing descriptor across temporary permission errors.
            }
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            guard fstat(fd, &info) == 0 else { close(fd); continue }
            watchers.removeValue(forKey: path)?.source.cancel()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[path] = (source, info.st_dev, info.st_ino)
        }
    }

}
