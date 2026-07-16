import AppKit

@main
@MainActor
enum GhostTermApplication {
    static func main() {
        guard GhosttyBridge.bootstrapRuntime() else {
            fatalError("Ghostty runtime initialization failed.")
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()

        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
