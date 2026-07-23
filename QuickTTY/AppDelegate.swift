import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let startupErrorMessage = "QuickTTY could not start"

    private let logger = Logger(
        subsystem: "com.dntsk.QuickTTY",
        category: "ApplicationLifecycle"
    )
    private var ghosttyBridge: GhosttyBridge?
    private var windowCoordinator: WindowCoordinator?
    private var configController: ConfigController?
    private let shortcutController = ShortcutController()
    private var configurationDiagnosticsPresentation: ConfigDiagnosticPresentation?
    private var stateStore: StateStore?
    private var applicationState: ApplicationState?
    private var isTerminating = false

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
                initialWorkspaceStore: Self.initialWorkspaceStore(
                    applicationState: applicationState,
                    config: config
                ),
                persistWorkspaceStore: { [weak self] workspaceStore in
                    self?.workspaceStoreDidChange(workspaceStore)
                },
                persistPresentationMode: { [weak self] mode in
                    do {
                        try self?.configController?.updatePresentationMode(mode)
                    } catch {
                        self?.handleConfigurationOperationError(error)
                    }
                },
                persistQuakeHeight: { [weak self] height in
                    do {
                        try self?.configController?.updateQuakeHeight(height)
                    } catch {
                        self?.handleConfigurationOperationError(error)
                    }
                },
                persistNormalWindowFrame: { [weak self] frame in
                    self?.normalWindowFrameDidChange(frame)
                },
                onError: { [weak self] error in
                    self?.logConfigurationError(error)
                }
            )
            self.windowCoordinator = windowCoordinator
            windowCoordinator.applyConfiguration(config)
            Self.applyRuntimeShortcutConfiguration(
                config.shortcuts,
                registeredGlobalChord: windowCoordinator.registeredGlobalChord,
                shortcutController: shortcutController,
                ghosttyBridge: ghosttyBridge
            )
            try windowCoordinator.start()
            applyPendingConfigurationDiagnostics()
            installApplicationMenuItems()
            installNewTabMenuItem()
            installSplitPaneMenuItems()
            installCloseMenuItems()
            installPresentationMenuItem()
            installTabSelectionMenuItems()
            installWorkspaceMenuItems()
            installPaneNavigationMenuItems()
            installToggleBroadcastMenuItem()
            installTerminalMenuItems()

            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = Self.startupErrorMessage
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
        Self.performApplicationTermination(
            stopConfiguration: {
                self.configController?.stop()
                self.isTerminating = true
            },
            persistFinalState: {
                guard let applicationState = self.applicationState, let stateStore = self.stateStore
                else {
                    return
                }
                let finalState = Self.applicationState(
                    applicationState,
                    merging: self.windowCoordinator?.workspaceStoreForPersistence
                        ?? applicationState.workspaceStore,
                    normalWindowFrame: self.windowCoordinator?.normalWindowFrame
                )
                self.applicationState = finalState
                stateStore.scheduleSave(finalState)
                try stateStore.flushPendingSave()
            },
            logSaveError: { error in
                self.logger.error(
                    "Final state save failed: \(error.localizedDescription, privacy: .public)"
                )
            },
            prepareForTermination: {
                self.windowCoordinator?.prepareForApplicationTermination()
            },
            shutdownRuntime: { self.ghosttyBridge?.shutdown() }
        )
    }

    func workspaceStoreDidChange(_ workspaceStore: WorkspaceStore) {
        guard !isTerminating, let applicationState, let stateStore else { return }
        let updatedState = Self.applicationState(
            applicationState,
            updatingWorkspaceStore: workspaceStore
        )
        self.applicationState = updatedState
        stateStore.scheduleSave(updatedState)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.shouldTerminateAfterLastWindowClosed(
            isRunningHostedTests: ApplicationEnvironment.isRunningHostedTests,
            presentationMode: windowCoordinator?.presentationMode
        )
    }

    static func applicationState(
        _ applicationState: ApplicationState,
        updatingWorkspaceStore workspaceStore: WorkspaceStore
    ) -> ApplicationState {
        var updatedState = applicationState
        updatedState.workspaceStore = workspaceStore
        return updatedState
    }

    static func applicationState(
        _ applicationState: ApplicationState,
        updatingNormalWindowFrame normalWindowFrame: NormalWindowFrame
    ) -> ApplicationState {
        var updatedState = applicationState
        updatedState.normalWindowFrame = normalWindowFrame
        return updatedState
    }

    static func applicationState(
        _ applicationState: ApplicationState,
        merging workspaceStore: WorkspaceStore,
        normalWindowFrame: NormalWindowFrame?
    ) -> ApplicationState {
        var updatedState = Self.applicationState(
            applicationState,
            updatingWorkspaceStore: workspaceStore
        )
        if let normalWindowFrame {
            updatedState = Self.applicationState(
                updatedState,
                updatingNormalWindowFrame: normalWindowFrame
            )
        }
        return updatedState
    }

    static func initialWorkspaceStore(
        applicationState: ApplicationState,
        config: QuickTTYConfig
    ) -> WorkspaceStore {
        config.restoreWorkspaces ? applicationState.workspaceStore : WorkspaceStore()
    }

    static func shouldTerminateAfterLastWindowClosed(
        isRunningHostedTests: Bool,
        presentationMode: PresentationMode?
    ) -> Bool {
        guard !isRunningHostedTests else { return false }
        return presentationMode != .quake
    }

    static func configurationDiagnosticsPresentation(
        configURL: URL,
        diagnostics: [ConfigDiagnostic]
    ) -> ConfigDiagnosticPresentation? {
        guard !diagnostics.isEmpty else { return nil }
        return ConfigDiagnosticPresentation(
            path: configURL.path,
            messages: diagnostics.map(\.localizedDescription)
        )
    }

    static func configurationErrorPresentation(
        configURL: URL,
        error: ConfigControllerError
    ) -> ConfigDiagnosticPresentation {
        ConfigDiagnosticPresentation(path: configURL.path, messages: [error.localizedDescription])
    }

    static func performApplicationTermination(
        stopConfiguration: () -> Void,
        persistFinalState: () throws -> Void,
        logSaveError: (Error) -> Void,
        prepareForTermination: () -> Void,
        shutdownRuntime: () -> Void
    ) {
        stopConfiguration()
        do {
            try persistFinalState()
        } catch {
            logSaveError(error)
        }
        prepareForTermination()
        shutdownRuntime()
    }

    @discardableResult
    static func applyRuntimeShortcutConfiguration(
        _ configuration: ShortcutConfiguration,
        registeredGlobalChord: ShortcutChord?,
        shortcutController: ShortcutController,
        ghosttyBridge: GhosttyBridge
    ) -> ShortcutConfiguration {
        let resolved = configuration.resolvingGlobalPrecedence(registeredGlobalChord)
        shortcutController.apply(resolved)
        ghosttyBridge.applyShortcutConfiguration(resolved)
        return resolved
    }

    static let quitMenuItemAction = #selector(NSApplication.terminate(_:))
    static let newTabMenuItemAction = #selector(AppDelegate.createNewTab)
    static let closePaneMenuItemAction = #selector(AppDelegate.closeActivePane)
    static let closeTabMenuItemAction = #selector(AppDelegate.closeActiveTab)
    static let openConfigurationMenuItemAction = #selector(AppDelegate.openConfiguration)
    static let togglePresentationMenuItemAction = #selector(AppDelegate.togglePresentationMode)
    static let splitRightMenuItemAction = #selector(AppDelegate.splitRight)
    static let splitDownMenuItemAction = #selector(AppDelegate.splitDown)
    static let tabSelectionMenuItemAction = #selector(AppDelegate.activateTab(_:))
    static let workspaceSelectionMenuItemAction = #selector(AppDelegate.activateWorkspace(_:))
    static let newWorkspaceMenuItemAction = #selector(AppDelegate.createWorkspace)
    static let renameWorkspaceMenuItemAction = #selector(AppDelegate.renameWorkspace)
    static let deleteWorkspaceMenuItemAction = #selector(AppDelegate.deleteWorkspace)
    static let previousPaneMenuItemAction = #selector(AppDelegate.focusPreviousPane)
    static let nextPaneMenuItemAction = #selector(AppDelegate.focusNextPane)
    static let focusLeftPaneMenuItemAction = #selector(AppDelegate.focusLeftPane)
    static let focusRightPaneMenuItemAction = #selector(AppDelegate.focusRightPane)
    static let focusUpPaneMenuItemAction = #selector(AppDelegate.focusUpPane)
    static let focusDownPaneMenuItemAction = #selector(AppDelegate.focusDownPane)
    static let toggleBroadcastMenuItemAction = #selector(AppDelegate.toggleBroadcast)
    static let copyMenuItemAction = #selector(NSText.copy(_:))
    static let pasteMenuItemAction = #selector(NSText.paste(_:))
    static let selectAllMenuItemAction = #selector(NSText.selectAll(_:))

    static func makeQuitMenuItem(
        target: AnyObject,
        action: Selector = quitMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Quit QuickTTY", action: action, keyEquivalent: "q")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    @discardableResult
    static func installQuitMenuItem(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = quitMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = applicationMenu(in: mainMenu)
        let canonicalItems = menu.items.filter { $0.title == "Quit QuickTTY" }
        let item = canonicalItems.first ?? makeQuitMenuItem(target: target, action: action)
        item.title = "Quit QuickTTY"
        item.action = action
        item.keyEquivalent = "q"
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        if canonicalItems.isEmpty {
            menu.addItem(item)
        } else {
            for duplicate in canonicalItems.dropFirst() {
                menu.removeItem(duplicate)
            }
        }
        shortcutController?.register(item, for: .quit)
        return mainMenu
    }

    static func makeNewTabMenuItem(
        target: AnyObject,
        action: Selector = newTabMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "New Tab", action: action, keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    @discardableResult
    static func installNewTabMenuItem(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = newTabMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let fileMenu = fileMenu(in: mainMenu)
        let canonicalItems = fileMenu.items.filter(isCanonicalNewTabMenuItem)
        let canonicalItem: NSMenuItem

        if let existingItem = canonicalItems.first {
            canonicalItem = existingItem
            canonicalItem.title = "New Tab"
            canonicalItem.action = action
            canonicalItem.keyEquivalent = "t"
            canonicalItem.keyEquivalentModifierMask = [.command]
            canonicalItem.target = target
            for duplicate in canonicalItems.dropFirst() {
                fileMenu.removeItem(duplicate)
            }
        } else {
            canonicalItem = makeNewTabMenuItem(target: target, action: action)
            fileMenu.addItem(canonicalItem)
        }

        shortcutController?.register(canonicalItem, for: .newTab)
        return mainMenu
    }

    @discardableResult
    static func installCloseMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        closePaneAction: Selector = closePaneMenuItemAction,
        closeTabAction: Selector = closeTabMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = fileMenu(in: mainMenu)
        let registrations: [(ShortcutAction, String, Selector, String, NSEvent.ModifierFlags)] = [
            (.closePane, "Close Pane", closePaneAction, "w", [.command]),
            (.closeTab, "Close Tab", closeTabAction, "w", [.command, .option]),
        ]
        var items: [NSMenuItem] = []

        for (shortcutAction, title, action, keyEquivalent, modifierMask) in registrations {
            let canonicalItems = menu.items.filter { $0.title == title }
            let item =
                canonicalItems.first
                ?? NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.title = title
            item.action = action
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = modifierMask
            item.target = target
            for duplicate in canonicalItems.dropFirst() {
                menu.removeItem(duplicate)
            }
            shortcutController?.register(item, for: shortcutAction)
            items.append(item)
        }

        for item in items where menu.items.contains(where: { $0 === item }) {
            menu.removeItem(item)
        }
        let newTabIndex = menu.indexOfItem(withTitle: "New Tab")
        if newTabIndex >= 0 {
            for (offset, item) in items.enumerated() {
                menu.insertItem(item, at: newTabIndex + offset + 1)
            }
        } else {
            for item in items {
                menu.addItem(item)
            }
        }
        return mainMenu
    }

    private static func isCanonicalNewTabMenuItem(_ item: NSMenuItem) -> Bool {
        item.title == "New Tab"
            || (item.keyEquivalent.lowercased() == "t"
                && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                    == [.command])
    }

    static func makeOpenConfigurationMenuItem(
        target: AnyObject,
        action: Selector = openConfigurationMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Open Configuration…", action: action, keyEquivalent: ",")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    @discardableResult
    static func installOpenConfigurationMenuItem(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = openConfigurationMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let applicationMenu = applicationMenu(in: mainMenu)
        let canonicalItems = applicationMenu.items.filter(isCanonicalOpenConfigurationMenuItem)
        let canonicalItem: NSMenuItem

        if let existingItem = canonicalItems.first {
            canonicalItem = existingItem
            canonicalItem.title = "Open Configuration…"
            canonicalItem.action = action
            canonicalItem.keyEquivalent = ","
            canonicalItem.keyEquivalentModifierMask = [.command]
            canonicalItem.target = target
            for duplicate in canonicalItems.dropFirst() {
                applicationMenu.removeItem(duplicate)
            }
        } else {
            canonicalItem = makeOpenConfigurationMenuItem(target: target, action: action)
            applicationMenu.addItem(canonicalItem)
        }

        shortcutController?.register(canonicalItem, for: .openConfig)
        return mainMenu
    }

    private static func isCanonicalOpenConfigurationMenuItem(_ item: NSMenuItem) -> Bool {
        item.title == "Open Configuration…"
            || (item.keyEquivalent == ","
                && hasExactCommandShortcutModifiers(item.keyEquivalentModifierMask))
    }

    static func hasExactCommandShortcutModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == [.command]
    }

    static func makeSplitPaneMenuItem(
        title: String,
        modifierMask: NSEvent.ModifierFlags,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "d")
        item.keyEquivalentModifierMask = modifierMask
        item.target = target
        return item
    }

    @discardableResult
    static func installSplitPaneMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        splitRightAction: Selector = splitRightMenuItemAction,
        splitDownAction: Selector = splitDownMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let fileMenu = fileMenu(in: mainMenu)
        let splitRight = canonicalSplitPaneMenuItem(
            in: fileMenu,
            title: "Split Right",
            modifierMask: [.command],
            target: target,
            action: splitRightAction
        )
        let splitDown = canonicalSplitPaneMenuItem(
            in: fileMenu,
            title: "Split Down",
            modifierMask: [.command, .shift],
            target: target,
            action: splitDownAction
        )
        shortcutController?.register(splitRight, for: .splitRight)
        shortcutController?.register(splitDown, for: .splitDown)

        if fileMenu.items.contains(where: { $0 === splitRight }) {
            fileMenu.removeItem(splitRight)
        }
        if fileMenu.items.contains(where: { $0 === splitDown }) {
            fileMenu.removeItem(splitDown)
        }
        let newTabIndex = fileMenu.indexOfItem(withTitle: "New Tab")
        guard newTabIndex >= 0 else {
            fileMenu.addItem(splitRight)
            fileMenu.addItem(splitDown)
            return mainMenu
        }

        fileMenu.insertItem(splitRight, at: newTabIndex + 1)
        fileMenu.insertItem(splitDown, at: newTabIndex + 2)
        return mainMenu
    }

    private static func canonicalSplitPaneMenuItem(
        in menu: NSMenu,
        title: String,
        modifierMask: NSEvent.ModifierFlags,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let canonicalItems = menu.items.filter {
            $0.title == title
                || ($0.keyEquivalent.lowercased() == "d"
                    && normalizedShortcutModifiers(for: $0) == modifierMask)
        }
        let canonicalItem =
            canonicalItems.first
            ?? makeSplitPaneMenuItem(
                title: title,
                modifierMask: modifierMask,
                target: target,
                action: action
            )
        canonicalItem.title = title
        canonicalItem.action = action
        canonicalItem.keyEquivalent = "d"
        canonicalItem.keyEquivalentModifierMask = modifierMask
        canonicalItem.target = target
        for duplicate in canonicalItems.dropFirst() {
            menu.removeItem(duplicate)
        }
        return canonicalItem
    }

    static func makePaneNavigationMenuItem(
        title: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifierMask
        item.target = target
        return item
    }

    @discardableResult
    static func installPaneNavigationMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        previousAction: Selector = previousPaneMenuItemAction,
        nextAction: Selector = nextPaneMenuItemAction,
        leftAction: Selector = focusLeftPaneMenuItemAction,
        rightAction: Selector = focusRightPaneMenuItemAction,
        upAction: Selector = focusUpPaneMenuItemAction,
        downAction: Selector = focusDownPaneMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let viewMenu = viewMenu(in: mainMenu)
        let items = [
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Previous Pane",
                keyEquivalent: "[",
                modifierMask: [.command],
                target: target,
                action: previousAction
            ),
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Next Pane",
                keyEquivalent: "]",
                modifierMask: [.command],
                target: target,
                action: nextAction
            ),
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Focus Left Pane",
                keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifierMask: [.command, .option],
                target: target,
                action: leftAction
            ),
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Focus Right Pane",
                keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                modifierMask: [.command, .option],
                target: target,
                action: rightAction
            ),
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Focus Up Pane",
                keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                modifierMask: [.command, .option],
                target: target,
                action: upAction
            ),
            canonicalPaneNavigationMenuItem(
                in: viewMenu,
                title: "Focus Down Pane",
                keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                modifierMask: [.command, .option],
                target: target,
                action: downAction
            ),
        ]
        let shortcutActions: [ShortcutAction] = [
            .previousPane, .nextPane, .focusLeft, .focusRight, .focusUp, .focusDown,
        ]
        for (shortcutAction, item) in zip(shortcutActions, items) {
            shortcutController?.register(item, for: shortcutAction)
            if !viewMenu.items.contains(where: { $0 === item }) {
                viewMenu.addItem(item)
            }
        }
        return mainMenu
    }

    private static func canonicalPaneNavigationMenuItem(
        in menu: NSMenu,
        title: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let canonicalItems = menu.items.filter {
            $0.title == title
                || ($0.keyEquivalent == keyEquivalent
                    && normalizedShortcutModifiers(for: $0) == modifierMask)
        }
        let canonicalItem =
            canonicalItems.first
            ?? makePaneNavigationMenuItem(
                title: title,
                keyEquivalent: keyEquivalent,
                modifierMask: modifierMask,
                target: target,
                action: action
            )
        canonicalItem.title = title
        canonicalItem.action = action
        canonicalItem.keyEquivalent = keyEquivalent
        canonicalItem.keyEquivalentModifierMask = modifierMask
        canonicalItem.target = target
        for duplicate in canonicalItems.dropFirst() {
            menu.removeItem(duplicate)
        }
        return canonicalItem
    }

    static func makeToggleBroadcastMenuItem(
        target: AnyObject,
        action: Selector = toggleBroadcastMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Toggle Broadcast Input",
            action: action,
            keyEquivalent: "b"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        return item
    }

    @discardableResult
    static func installToggleBroadcastMenuItem(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = toggleBroadcastMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let viewMenu = viewMenu(in: mainMenu)
        let canonicalItems = viewMenu.items.filter(isCanonicalToggleBroadcastMenuItem)
        let canonicalItem: NSMenuItem

        if let existingItem = canonicalItems.first {
            canonicalItem = existingItem
            canonicalItem.title = "Toggle Broadcast Input"
            canonicalItem.action = action
            canonicalItem.keyEquivalent = "b"
            canonicalItem.keyEquivalentModifierMask = [.command]
            canonicalItem.target = target
            for duplicate in canonicalItems.dropFirst() {
                viewMenu.removeItem(duplicate)
            }
        } else {
            canonicalItem = makeToggleBroadcastMenuItem(target: target, action: action)
            viewMenu.addItem(canonicalItem)
        }

        shortcutController?.register(canonicalItem, for: .toggleBroadcast)
        return mainMenu
    }

    static func validateToggleBroadcastMenuItem(
        _ item: NSMenuItem,
        canToggleBroadcast: Bool,
        isBroadcastingActiveTab: Bool
    ) -> Bool {
        item.state = isBroadcastingActiveTab ? .on : .off
        return canToggleBroadcast
    }

    private static func isCanonicalToggleBroadcastMenuItem(_ item: NSMenuItem) -> Bool {
        item.title == "Toggle Broadcast Input"
            || (item.keyEquivalent.lowercased() == "b"
                && normalizedShortcutModifiers(for: item) == [.command])
    }

    private static func applicationMenu(in mainMenu: NSMenu) -> NSMenu {
        if let applicationItem = mainMenu.item(withTitle: "QuickTTY") {
            if let existingApplicationMenu = applicationItem.submenu {
                return existingApplicationMenu
            }
            let newApplicationMenu = NSMenu(title: "QuickTTY")
            applicationItem.submenu = newApplicationMenu
            return newApplicationMenu
        }

        let applicationItem = NSMenuItem(title: "QuickTTY", action: nil, keyEquivalent: "")
        let newApplicationMenu = NSMenu(title: "QuickTTY")
        applicationItem.submenu = newApplicationMenu
        mainMenu.insertItem(applicationItem, at: 0)
        return newApplicationMenu
    }

    private static func fileMenu(in mainMenu: NSMenu) -> NSMenu {
        if let fileItem = mainMenu.item(withTitle: "File") {
            if let existingFileMenu = fileItem.submenu {
                return existingFileMenu
            }
            let newFileMenu = NSMenu(title: "File")
            fileItem.submenu = newFileMenu
            return newFileMenu
        }

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let newFileMenu = NSMenu(title: "File")
        fileItem.submenu = newFileMenu
        mainMenu.addItem(fileItem)
        return newFileMenu
    }

    private static func normalizedShortcutModifiers(for item: NSMenuItem) -> NSEvent.ModifierFlags {
        item.keyEquivalentModifierMask
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
    }

    private static func workspaceMenu(in mainMenu: NSMenu) -> NSMenu {
        let workspaceItems = mainMenu.items.filter { $0.title == "Workspace" }
        if let workspaceItem = workspaceItems.first {
            let menu = workspaceItem.submenu ?? NSMenu(title: "Workspace")
            workspaceItem.submenu = menu
            for duplicate in workspaceItems.dropFirst() {
                mainMenu.removeItem(duplicate)
            }
            return menu
        }

        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Workspace")
        workspaceItem.submenu = menu
        mainMenu.addItem(workspaceItem)
        return menu
    }

    private static func canonicalWorkspaceManagementMenuItem(
        in menu: NSMenu,
        title: String,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let canonicalItems = menu.items.filter { $0.title == title }
        let item =
            canonicalItems.first ?? NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.title = title
        item.action = action
        item.target = target
        for duplicate in canonicalItems.dropFirst() {
            menu.removeItem(duplicate)
        }
        return item
    }

    private static func canonicalWorkspaceSelectionSeparator(in menu: NSMenu) -> NSMenuItem {
        let tag = -1_001
        let canonicalItems = menu.items.filter { $0.tag == tag }
        let item = canonicalItems.first ?? NSMenuItem.separator()
        item.tag = tag
        for duplicate in canonicalItems.dropFirst() {
            menu.removeItem(duplicate)
        }
        return item
    }

    private static func removeLegacyWorkspaceSelectionItems(
        from mainMenu: NSMenu,
        excluding workspaceMenu: NSMenu
    ) {
        for menuItem in mainMenu.items {
            guard let submenu = menuItem.submenu, submenu !== workspaceMenu else { continue }
            for item in submenu.items
            where item.title.hasPrefix("Select Workspace ")
                || ((1...9).contains(Int(item.keyEquivalent) ?? 0)
                    && normalizedShortcutModifiers(for: item) == [.command, .option])
            {
                submenu.removeItem(item)
            }
        }
    }

    private static func editMenu(in mainMenu: NSMenu) -> NSMenu {
        if let editItem = mainMenu.item(withTitle: "Edit") {
            if let existingEditMenu = editItem.submenu {
                return existingEditMenu
            }
            let newEditMenu = NSMenu(title: "Edit")
            editItem.submenu = newEditMenu
            return newEditMenu
        }

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let newEditMenu = NSMenu(title: "Edit")
        editItem.submenu = newEditMenu
        mainMenu.addItem(editItem)
        return newEditMenu
    }

    private static func viewMenu(in mainMenu: NSMenu) -> NSMenu {
        if let viewItem = mainMenu.item(withTitle: "View") {
            if let existingViewMenu = viewItem.submenu {
                return existingViewMenu
            }
            let newViewMenu = NSMenu(title: "View")
            viewItem.submenu = newViewMenu
            return newViewMenu
        }

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let newViewMenu = NSMenu(title: "View")
        viewItem.submenu = newViewMenu
        mainMenu.addItem(viewItem)
        return newViewMenu
    }

    @discardableResult
    static func installPresentationMenuItem(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = togglePresentationMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = viewMenu(in: mainMenu)
        let canonicalItems = menu.items.filter { $0.title == "Toggle Presentation Mode" }
        let item =
            canonicalItems.first
            ?? NSMenuItem(title: "Toggle Presentation Mode", action: action, keyEquivalent: "p")
        item.title = "Toggle Presentation Mode"
        item.action = action
        item.keyEquivalent = "p"
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = target
        if canonicalItems.isEmpty {
            menu.addItem(item)
        } else {
            for duplicate in canonicalItems.dropFirst() {
                menu.removeItem(duplicate)
            }
        }
        shortcutController?.register(item, for: .togglePresentation)
        return mainMenu
    }

    @discardableResult
    static func installTerminalMenuItems(
        in existingMainMenu: NSMenu?,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = editMenu(in: mainMenu)
        let registrations: [(ShortcutAction, String, Selector, String, NSEvent.ModifierFlags)] = [
            (.copy, "Copy", copyMenuItemAction, "", []),
            (.paste, "Paste", pasteMenuItemAction, "v", [.command]),
            (.selectAll, "Select All", selectAllMenuItemAction, "a", [.command]),
        ]

        for (shortcutAction, title, action, keyEquivalent, modifierMask) in registrations {
            let canonicalItems = menu.items.filter { $0.title == title }
            let item =
                canonicalItems.first
                ?? NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.title = title
            item.action = action
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = modifierMask
            item.target = nil
            if canonicalItems.isEmpty {
                menu.addItem(item)
            } else {
                for duplicate in canonicalItems.dropFirst() {
                    menu.removeItem(duplicate)
                }
            }
            shortcutController?.register(item, for: shortcutAction)
        }
        return mainMenu
    }

    static func makeTabSelectionMenuItem(
        index: Int,
        target: AnyObject,
        action: Selector = tabSelectionMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Select Tab \(index)",
            action: action,
            keyEquivalent: "\(index)"
        )
        item.keyEquivalentModifierMask = [.command]
        item.representedObject = NSNumber(value: index)
        item.target = target
        return item
    }

    @discardableResult
    static func installTabSelectionMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = tabSelectionMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let viewMenu = viewMenu(in: mainMenu)
        let shortcutActions: [ShortcutAction] = [
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
            .selectTab6, .selectTab7, .selectTab8, .selectTab9,
        ]

        for (index, shortcutAction) in zip(1...9, shortcutActions) {
            let canonicalItems = viewMenu.items.filter {
                $0.title == "Select Tab \(index)"
                    || ($0.keyEquivalent == "\(index)"
                        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                            == [.command])
            }
            let canonicalItem: NSMenuItem
            if let existingItem = canonicalItems.first {
                canonicalItem = existingItem
                canonicalItem.title = "Select Tab \(index)"
                canonicalItem.action = action
                canonicalItem.keyEquivalent = "\(index)"
                canonicalItem.keyEquivalentModifierMask = [.command]
                canonicalItem.representedObject = NSNumber(value: index)
                canonicalItem.target = target
                for duplicate in canonicalItems.dropFirst() {
                    viewMenu.removeItem(duplicate)
                }
            } else {
                canonicalItem = makeTabSelectionMenuItem(
                    index: index,
                    target: target,
                    action: action
                )
                viewMenu.addItem(canonicalItem)
            }
            shortcutController?.register(canonicalItem, for: shortcutAction)
        }
        return mainMenu
    }

    static func makeWorkspaceSelectionMenuItem(
        index: Int,
        target: AnyObject,
        action: Selector = workspaceSelectionMenuItemAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Select Workspace \(index)",
            action: action,
            keyEquivalent: "\(index)"
        )
        item.keyEquivalentModifierMask = [.command, .option]
        item.representedObject = NSNumber(value: index)
        item.target = target
        return item
    }

    @discardableResult
    static func installWorkspaceMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        createAction: Selector = newWorkspaceMenuItemAction,
        renameAction: Selector = renameWorkspaceMenuItemAction,
        deleteAction: Selector = deleteWorkspaceMenuItemAction,
        selectionAction: Selector = workspaceSelectionMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = workspaceMenu(in: mainMenu)
        let managementItems = [
            canonicalWorkspaceManagementMenuItem(
                in: menu,
                title: "New Workspace…",
                target: target,
                action: createAction
            ),
            canonicalWorkspaceManagementMenuItem(
                in: menu,
                title: "Rename Workspace…",
                target: target,
                action: renameAction
            ),
            canonicalWorkspaceManagementMenuItem(
                in: menu,
                title: "Delete Workspace…",
                target: target,
                action: deleteAction
            ),
        ]
        for (shortcutAction, item) in zip(
            [ShortcutAction.newWorkspace, .renameWorkspace, .deleteWorkspace],
            managementItems
        ) {
            shortcutController?.register(item, for: shortcutAction)
        }
        _ = installWorkspaceSelectionMenuItems(
            in: mainMenu,
            target: target,
            action: selectionAction,
            shortcutController: shortcutController
        )
        let selectionItems = (1...9).compactMap { index in
            menu.item(withTitle: "Select Workspace \(index)")
        }
        let separator = canonicalWorkspaceSelectionSeparator(in: menu)
        let orderedItems = managementItems + [separator] + selectionItems
        for item in orderedItems where menu.items.contains(where: { $0 === item }) {
            menu.removeItem(item)
        }
        for item in orderedItems {
            menu.addItem(item)
        }
        return mainMenu
    }

    @discardableResult
    static func installWorkspaceSelectionMenuItems(
        in existingMainMenu: NSMenu?,
        target: AnyObject,
        action: Selector = workspaceSelectionMenuItemAction,
        shortcutController: ShortcutController? = nil
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = workspaceMenu(in: mainMenu)
        removeLegacyWorkspaceSelectionItems(from: mainMenu, excluding: menu)
        let shortcutActions: [ShortcutAction] = [
            .selectWorkspace1, .selectWorkspace2, .selectWorkspace3, .selectWorkspace4,
            .selectWorkspace5, .selectWorkspace6, .selectWorkspace7, .selectWorkspace8,
            .selectWorkspace9,
        ]

        for (index, shortcutAction) in zip(1...9, shortcutActions) {
            let canonicalItems = menu.items.filter {
                $0.title == "Select Workspace \(index)"
                    || ($0.keyEquivalent == "\(index)"
                        && normalizedShortcutModifiers(for: $0) == [.command, .option])
            }
            let canonicalItem: NSMenuItem
            if let existingItem = canonicalItems.first {
                canonicalItem = existingItem
                canonicalItem.title = "Select Workspace \(index)"
                canonicalItem.action = action
                canonicalItem.keyEquivalent = "\(index)"
                canonicalItem.keyEquivalentModifierMask = [.command, .option]
                canonicalItem.representedObject = NSNumber(value: index)
                canonicalItem.target = target
                for duplicate in canonicalItems.dropFirst() {
                    menu.removeItem(duplicate)
                }
            } else {
                canonicalItem = makeWorkspaceSelectionMenuItem(
                    index: index,
                    target: target,
                    action: action
                )
                menu.addItem(canonicalItem)
            }
            shortcutController?.register(canonicalItem, for: shortcutAction)
        }
        return mainMenu
    }

    static func validateStructuralMenuItem(
        _ menuItem: NSMenuItem,
        coordinatorAvailable: Bool,
        canOpenConfig: Bool,
        canCreateTab: Bool,
        canClosePane: Bool,
        canCloseTab: Bool,
        canSplitPane: Bool,
        canNavigatePanes: Bool,
        activeTabCount: Int,
        workspaceCount: Int
    ) -> Bool {
        switch menuItem.action {
        case quitMenuItemAction:
            return true
        case openConfigurationMenuItemAction:
            return canOpenConfig
        case togglePresentationMenuItemAction:
            return coordinatorAvailable
        case newTabMenuItemAction:
            return canCreateTab
        case closePaneMenuItemAction:
            return canClosePane
        case closeTabMenuItemAction:
            return canCloseTab
        case splitRightMenuItemAction, splitDownMenuItemAction:
            return canSplitPane
        case previousPaneMenuItemAction, nextPaneMenuItemAction,
            focusLeftPaneMenuItemAction, focusRightPaneMenuItemAction,
            focusUpPaneMenuItemAction, focusDownPaneMenuItemAction:
            return canNavigatePanes
        case tabSelectionMenuItemAction:
            guard let index = (menuItem.representedObject as? NSNumber)?.intValue else {
                return false
            }
            return index >= 1 && index <= activeTabCount
        case workspaceSelectionMenuItemAction:
            guard let index = (menuItem.representedObject as? NSNumber)?.intValue else {
                return false
            }
            return index >= 1 && index <= workspaceCount
        default:
            return true
        }
    }

    static func validateWorkspaceMenuItem(
        _ menuItem: NSMenuItem,
        coordinatorAvailable: Bool,
        hasActiveWorkspace: Bool,
        canDeleteActiveWorkspace: Bool
    ) -> Bool {
        switch menuItem.action {
        case newWorkspaceMenuItemAction:
            return coordinatorAvailable
        case renameWorkspaceMenuItemAction:
            return coordinatorAvailable && hasActiveWorkspace
        case deleteWorkspaceMenuItemAction:
            return coordinatorAvailable && hasActiveWorkspace && canDeleteActiveWorkspace
        default:
            return true
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == Self.toggleBroadcastMenuItemAction {
            return Self.validateToggleBroadcastMenuItem(
                menuItem,
                canToggleBroadcast: windowCoordinator?.canToggleBroadcast ?? false,
                isBroadcastingActiveTab: windowCoordinator?.isBroadcastingActiveTab ?? false
            )
        }
        let workspaceItemIsValid = Self.validateWorkspaceMenuItem(
            menuItem,
            coordinatorAvailable: windowCoordinator != nil,
            hasActiveWorkspace: windowCoordinator?.hasActiveWorkspace ?? false,
            canDeleteActiveWorkspace: windowCoordinator?.canDeleteActiveWorkspace ?? false
        )
        guard workspaceItemIsValid else { return false }
        return Self.validateStructuralMenuItem(
            menuItem,
            coordinatorAvailable: windowCoordinator != nil,
            canOpenConfig: configController != nil && windowCoordinator != nil,
            canCreateTab: windowCoordinator?.hasActiveWorkspace ?? false,
            canClosePane: windowCoordinator?.canCloseActivePane ?? false,
            canCloseTab: windowCoordinator?.canCloseActiveTab ?? false,
            canSplitPane: windowCoordinator?.canSplitActivePane ?? false,
            canNavigatePanes: windowCoordinator?.canNavigateActivePanes ?? false,
            activeTabCount: windowCoordinator?.activeTabCount ?? 0,
            workspaceCount: windowCoordinator?.workspaceCount ?? 0
        )
    }

    @objc private func createNewTab() {
        windowCoordinator?.createNewTab()
    }

    @objc private func closeActivePane() {
        windowCoordinator?.requestCloseActivePane()
    }

    @objc private func closeActiveTab() {
        windowCoordinator?.requestCloseActiveTab()
    }

    @objc private func createWorkspace() {
        windowCoordinator?.createWorkspace()
    }

    @objc private func renameWorkspace() {
        windowCoordinator?.renameActiveWorkspace()
    }

    @objc private func deleteWorkspace() {
        windowCoordinator?.deleteActiveWorkspace()
    }

    @objc private func openConfiguration() {
        guard let configURL = configController?.configURL else { return }
        do {
            try windowCoordinator?.openConfiguration(at: configURL)
        } catch {
            logConfigurationError(error)
        }
    }

    @objc private func splitRight() {
        do {
            try windowCoordinator?.splitActivePane(axis: .horizontal)
        } catch {
            logConfigurationError(error)
        }
    }

    @objc private func splitDown() {
        do {
            try windowCoordinator?.splitActivePane(axis: .vertical)
        } catch {
            logConfigurationError(error)
        }
    }

    @objc private func activateTab(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        windowCoordinator?.activateTab(at: index)
    }

    @objc private func activateWorkspace(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        windowCoordinator?.activateWorkspace(at: index)
    }

    @objc private func focusPreviousPane() {
        windowCoordinator?.focusPreviousPane()
    }

    @objc private func focusNextPane() {
        windowCoordinator?.focusNextPane()
    }

    @objc private func focusLeftPane() {
        windowCoordinator?.focusPane(direction: .left)
    }

    @objc private func focusRightPane() {
        windowCoordinator?.focusPane(direction: .right)
    }

    @objc private func focusUpPane() {
        windowCoordinator?.focusPane(direction: .up)
    }

    @objc private func focusDownPane() {
        windowCoordinator?.focusPane(direction: .down)
    }

    @objc private func toggleBroadcast() {
        windowCoordinator?.toggleBroadcast()
    }

    @objc private func togglePresentationMode() {
        windowCoordinator?.togglePresentationMode()
    }

    private func normalWindowFrameDidChange(_ normalWindowFrame: NormalWindowFrame) {
        guard !isTerminating, let applicationState, let stateStore else { return }
        let updatedState = Self.applicationState(
            applicationState,
            updatingNormalWindowFrame: normalWindowFrame
        )
        self.applicationState = updatedState
        stateStore.scheduleSave(updatedState)
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

    private func startConfigController(using ghosttyBridge: GhosttyBridge) -> QuickTTYConfig {
        do {
            let configController = try ConfigController.production(
                reloadGhostty: { try ghosttyBridge.reloadConfig(at: $0) },
                onUpdate: { [weak self, weak ghosttyBridge] config in
                    guard let self, let ghosttyBridge,
                        let windowCoordinator = self.windowCoordinator
                    else { return }
                    windowCoordinator.applyConfiguration(config)
                    Self.applyRuntimeShortcutConfiguration(
                        config.shortcuts,
                        registeredGlobalChord: windowCoordinator.registeredGlobalChord,
                        shortcutController: shortcutController,
                        ghosttyBridge: ghosttyBridge
                    )
                },
                onDiagnostics: { [weak self] diagnostics in
                    self?.handleConfigControllerDiagnostics(diagnostics)
                },
                onError: { [weak self] error in
                    self?.handleConfigControllerError(error)
                }
            )
            self.configController = configController
            do {
                try configController.start()
            } catch let error as ConfigControllerError {
                handleConfigControllerError(error)
            } catch {
                logConfigurationError(error)
            }
            return configController.activeConfig
        } catch {
            logConfigurationError(error)
            return QuickTTYConfig()
        }
    }

    private func handleConfigControllerDiagnostics(_ diagnostics: [ConfigDiagnostic]) {
        guard let configController else { return }
        applyConfigurationDiagnostics(
            Self.configurationDiagnosticsPresentation(
                configURL: configController.configURL,
                diagnostics: diagnostics
            )
        )
    }

    private func handleConfigControllerError(_ error: ConfigControllerError) {
        logConfigurationError(error)
        guard let configController else { return }
        applyConfigurationDiagnostics(
            Self.configurationErrorPresentation(configURL: configController.configURL, error: error)
        )
    }

    private func handleConfigurationOperationError(_ error: Error) {
        if let error = error as? ConfigControllerError {
            handleConfigControllerError(error)
        } else {
            logConfigurationError(error)
        }
    }

    private func applyConfigurationDiagnostics(_ presentation: ConfigDiagnosticPresentation?) {
        configurationDiagnosticsPresentation = presentation
        applyPendingConfigurationDiagnostics()
    }

    private func applyPendingConfigurationDiagnostics() {
        windowCoordinator?.applyConfigurationDiagnostics(configurationDiagnosticsPresentation)
    }

    #if DEBUG
        var configurationDiagnosticsPresentationForTesting: ConfigDiagnosticPresentation? {
            configurationDiagnosticsPresentation
        }

        func receiveConfigurationDiagnosticsForTesting(
            _ diagnostics: [ConfigDiagnostic],
            configURL: URL
        ) {
            applyConfigurationDiagnostics(
                Self.configurationDiagnosticsPresentation(
                    configURL: configURL, diagnostics: diagnostics)
            )
        }

        func installWindowCoordinatorForTesting(_ windowCoordinator: WindowCoordinator) {
            self.windowCoordinator = windowCoordinator
        }

        func applyPendingConfigurationDiagnosticsForTesting() {
            applyPendingConfigurationDiagnostics()
        }
    #endif

    private func quakeConfiguration(for config: QuickTTYConfig) -> QuakeWindowConfiguration {
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
        let mainMenu = Self.installNewTabMenuItem(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installApplicationMenuItems() {
        var mainMenu = Self.installOpenConfigurationMenuItem(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        mainMenu = Self.installQuitMenuItem(
            in: mainMenu,
            target: NSApp,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installCloseMenuItems() {
        let mainMenu = Self.installCloseMenuItems(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installSplitPaneMenuItems() {
        let mainMenu = Self.installSplitPaneMenuItems(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installPaneNavigationMenuItems() {
        let mainMenu = Self.installPaneNavigationMenuItems(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installToggleBroadcastMenuItem() {
        let mainMenu = Self.installToggleBroadcastMenuItem(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installPresentationMenuItem() {
        let mainMenu = Self.installPresentationMenuItem(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installTabSelectionMenuItems() {
        let mainMenu = Self.installTabSelectionMenuItems(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installWorkspaceMenuItems() {
        let mainMenu = Self.installWorkspaceMenuItems(
            in: NSApp.mainMenu,
            target: self,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installTerminalMenuItems() {
        let mainMenu = Self.installTerminalMenuItems(
            in: NSApp.mainMenu,
            shortcutController: shortcutController
        )
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func logConfigurationError(_ error: Error) {
        logger.error("Configuration update failed: \(error.localizedDescription, privacy: .public)")
    }
}
