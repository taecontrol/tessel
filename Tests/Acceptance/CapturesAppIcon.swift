import AppKit
import Foundation
import Testing

extension Acceptance {
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_APP_ICON"] == "1", "owner review of the app icons"))
    @MainActor struct AppIconCaptures {
        /// Renders the signed bundles' icons as the system resolves them, at the
        /// sizes Finder and System Settings use, on light and dark backgrounds.
        @Test("#59 E6; #59 E7: the system renders the Tessel and Tessel Dev icons as the accepted mark")
        func captureAppIcons() throws {
            let apps = root.appending(path: ".build/apps")
            let bundles = ["Tessel.app", "Tessel Dev.app"].map { apps.appending(path: $0) }
            for bundle in bundles {
                try #require(FileManager.default.fileExists(atPath: bundle.path),
                             "build \(bundle.lastPathComponent) first: scripts/build --variant daily, then scripts/build")
            }
            let directory = root.appending(path: ".work/captures/app-icon")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, background, ink) in [("light", NSColor(white: 0.96, alpha: 1), NSColor.black), ("dark", NSColor(white: 0.12, alpha: 1), NSColor.white)] {
                let size = NSSize(width: 480, height: 300 * CGFloat(bundles.count))
                let image = NSImage(size: size, flipped: true) { rect in
                    background.setFill()
                    rect.fill()
                    for (row, bundle) in bundles.enumerated() {
                        let icon = NSWorkspace.shared.icon(forFile: bundle.path)
                        let top = CGFloat(row) * 300 + 20
                        icon.draw(in: NSRect(x: 20, y: top, width: 256, height: 256))
                        icon.draw(in: NSRect(x: 300, y: top + 20, width: 128, height: 128))
                        icon.draw(in: NSRect(x: 300, y: top + 170, width: 32, height: 32))
                        icon.draw(in: NSRect(x: 350, y: top + 178, width: 16, height: 16))
                        (bundle.deletingPathExtension().lastPathComponent as NSString)
                            .draw(at: NSPoint(x: 300, y: top + 220), withAttributes: [.foregroundColor: ink, .font: NSFont.systemFont(ofSize: 15)])
                    }
                    return true
                }
                for scale in [1, 2] {
                    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    rep.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    image.draw(in: NSRect(origin: .zero, size: size))
                    NSGraphicsContext.restoreGraphicsState()
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appending(path: "app-icons-\(name)@\(scale)x.png"), options: .atomic)
                }
            }
            print("App icon captures for owner review: \(directory.path)")
        }
    }
}
