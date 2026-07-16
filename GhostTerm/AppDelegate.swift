import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.dntsk.GhostTerm",
        category: "ApplicationLifecycle"
    )
    private var ghosttyBridge: GhosttyBridge?
    private var windowCoordinator: WindowCoordinator?
    private var stateStore: StateStore?
    private var applicationState: ApplicationState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ApplicationEnvironment.isRunningHostedTests else { return }

        do {
            let stateStore = try StateStore.production()
            let applicationState = try stateStore.load()
            self.stateStore = stateStore
            self.applicationState = applicationState

            let ghosttyBridge = try GhosttyBridge()
            ghosttyBridge.setApplicationFocused(NSApp.isActive)
            self.ghosttyBridge = ghosttyBridge

            let windowCoordinator = WindowCoordinator(
                ghosttyBridge: ghosttyBridge,
                normalWindowFrame: applicationState.normalWindowFrame
            )
            try windowCoordinator.start()
            self.windowCoordinator = windowCoordinator

            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "GhostTerm could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ghosttyBridge?.setApplicationFocused(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        ghosttyBridge?.setApplicationFocused(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if var applicationState, let stateStore {
            if let normalWindowFrame = windowCoordinator?.normalWindowFrame {
                applicationState.normalWindowFrame = normalWindowFrame
            }
            self.applicationState = applicationState
            stateStore.scheduleSave(applicationState)
            do {
                try stateStore.flushPendingSave()
            } catch {
                logger.error(
                    "Final state save failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        ghosttyBridge?.shutdown()
    }

    func workspaceStoreDidChange(_ workspaceStore: WorkspaceStore) {
        guard var applicationState, let stateStore else { return }
        applicationState.workspaceStore = workspaceStore
        self.applicationState = applicationState
        stateStore.scheduleSave(applicationState)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ApplicationEnvironment.isRunningHostedTests
    }
}
