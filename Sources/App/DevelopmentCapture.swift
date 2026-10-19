#if TESSEL_DEVELOPMENT
import AppKit

/// Export the running app's own views for E37. No screen recording, other app
/// windows, or WindowServer screenshots are involved. Created only with both
/// --test-fixture-only and --test-capture-ui in the development build.
@MainActor
final class DevelopmentCapture: NSObject, NSMenuDelegate {
    private let directory = ConfigLocation.file.deletingLastPathComponent().appending(path: "ui-captures")
    private var generation: UInt64 = 0
    private var enabled = false

    func update(button: NSStatusBarButton, menu: NSMenu, status: WorkspaceStatus) {
        generation += 1
        let token = generation
        enabled = status.enabled
        menu.delegate = self
        guard status.enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self, weak button] in
            guard let self, let button, self.generation == token else { return }
            self.export(button, name: status.layout == "carousel" ? "E26-workspace-\(status.active)-rail-\(status.rail ?? 0)" : "E37-workspace-\(status.active)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, !self.enabled else { return }
            // NSApp.windows contains only this process's own windows. AppKit's
            // popup menu has a public NSWindow/NSView surface at this level.
            for window in NSApp.windows where window.isVisible && window.level == .popUpMenu {
                if let view = window.contentView { self.export(view, name: "E37-disabled-menu") }
            }
        }
    }

    private func export(_ view: NSView, name: String) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name + ".png"), options: .atomic)
        } catch { /* The capture harness reports a missing artifact. */ }
    }
}
#endif
