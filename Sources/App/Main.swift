import AppKit

// The verification scaffold launches a real bundle before implementation begins.
@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
