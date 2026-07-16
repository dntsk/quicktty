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
    private var configController: ConfigController?
    private var stateStore: StateStore?
    private var applicationState: ApplicationState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ApplicationEnvironment.isRunningHostedTests else { return }

        let applicationState = loadApplicationState()
        self.applicationState = applicationState

        do {
            let ghosttyBridge = try GhosttyBridge()
            ghosttyBridge.setApplicationFocused(NSApp.isActive)
            self.ghosttyBridge = ghosttyBridge

            let config = startConfigController(using: ghosttyBridge)
            let windowCoordinator = WindowCoordinator(
                ghosttyBridge: ghosttyBridge,
                presentationMode: config.presentationMode,
                normalWindowFrame: applicationState.normalWindowFrame,
                quakeConfiguration: quakeConfiguration(for: config),
                persistPresentationMode: { [weak self] mode in
                    do {
                        try self?.configController?.updatePresentationMode(mode)
                    } catch {
                        self?.logConfigurationError(error)
                    }
                },
                persistQuakeHeight: { [weak self] height in
                    do {
                        try self?.configController?.updateQuakeHeight(height)
                    } catch {
                        self?.logConfigurationError(error)
                    }
                },
                onError: { [weak self] error in
                    self?.logConfigurationError(error)
                }
            )
            self.windowCoordinator = windowCoordinator
            windowCoordinator.applyConfiguration(config)
            try windowCoordinator.start()
            installNewTabMenuItem()
            installPresentationMenuItem()

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
        configController?.stop()
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
        Self.shouldTerminateAfterLastWindowClosed(
            isRunningHostedTests: ApplicationEnvironment.isRunningHostedTests,
            presentationMode: windowCoordinator?.presentationMode
        )
    }

    static func shouldTerminateAfterLastWindowClosed(
        isRunningHostedTests: Bool,
        presentationMode: PresentationMode?
    ) -> Bool {
        guard !isRunningHostedTests else { return false }
        return presentationMode != .quake
    }

    static let newTabMenuItemAction = #selector(AppDelegate.createNewTab)

    static func makeNewTabMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(
            title: "New Tab",
            action: newTabMenuItemAction,
            keyEquivalent: "t"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    @objc private func createNewTab() {
        windowCoordinator?.createNewTab()
    }

    @objc private func togglePresentationMode() {
        windowCoordinator?.togglePresentationMode()
    }

    private func loadApplicationState() -> ApplicationState {
        do {
            let stateStore = try StateStore.production()
            let applicationState = try stateStore.load()
            self.stateStore = stateStore
            return applicationState
        } catch {
            logger.error("State load failed: \(error.localizedDescription, privacy: .public)")
            return ApplicationState()
        }
    }

    private func startConfigController(using ghosttyBridge: GhosttyBridge) -> GhostTermConfig {
        do {
            let configController = try ConfigController.production(
                reloadGhostty: { try ghosttyBridge.reloadConfig(at: $0) },
                onUpdate: { [weak self] config in
                    self?.windowCoordinator?.applyConfiguration(config)
                },
                onError: { [weak self] error in
                    self?.logConfigurationError(error)
                }
            )
            self.configController = configController
            do {
                try configController.start()
            } catch {
                logConfigurationError(error)
            }
            return configController.activeConfig
        } catch {
            logConfigurationError(error)
            return GhostTermConfig()
        }
    }

    private func quakeConfiguration(for config: GhostTermConfig) -> QuakeWindowConfiguration {
        let geometry =
            QuakeWindowGeometry(
                heightFraction: config.quakeHeight,
                padding: config.quakePadding
            ) ?? QuakeWindowConfiguration().geometry
        return QuakeWindowConfiguration(
            geometry: geometry,
            animationDuration: config.quakeAnimationDuration,
            hideOnFocusLoss: config.hideOnFocusLoss
        )
    }

    private func installNewTabMenuItem() {
        let mainMenu: NSMenu
        if let existingMainMenu = NSApp.mainMenu {
            mainMenu = existingMainMenu
        } else {
            let newMainMenu = NSMenu()
            NSApp.mainMenu = newMainMenu
            mainMenu = newMainMenu
        }

        let fileMenu: NSMenu
        if let fileItem = mainMenu.item(withTitle: "File") {
            if let existingFileMenu = fileItem.submenu {
                fileMenu = existingFileMenu
            } else {
                let newFileMenu = NSMenu(title: "File")
                fileItem.submenu = newFileMenu
                fileMenu = newFileMenu
            }
        } else {
            let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
            let newFileMenu = NSMenu(title: "File")
            fileItem.submenu = newFileMenu
            mainMenu.addItem(fileItem)
            fileMenu = newFileMenu
        }

        guard
            !fileMenu.items.contains(where: {
                $0.action == Self.newTabMenuItemAction && $0.target === self
            })
        else { return }
        fileMenu.addItem(Self.makeNewTabMenuItem(target: self))
    }

    private func installPresentationMenuItem() {
        let menu =
            NSApp.mainMenu?.item(withTitle: "View")?.submenu
            ?? {
                let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
                let menu = NSMenu(title: "View")
                item.submenu = menu
                NSApp.mainMenu?.addItem(item)
                return menu
            }()
        let item = NSMenuItem(
            title: "Toggle Presentation Mode",
            action: #selector(togglePresentationMode),
            keyEquivalent: "p"
        )
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menu.addItem(item)
    }

    private func logConfigurationError(_ error: Error) {
        logger.error("Configuration update failed: \(error.localizedDescription, privacy: .public)")
    }
}
