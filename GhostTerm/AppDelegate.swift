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
                persistNormalWindowFrame: { [weak self] frame in
                    self?.normalWindowFrameDidChange(frame)
                },
                onError: { [weak self] error in
                    self?.logConfigurationError(error)
                }
            )
            self.windowCoordinator = windowCoordinator
            windowCoordinator.applyConfiguration(config)
            try windowCoordinator.start()
            installNewTabMenuItem()
            installOpenConfigurationMenuItem()
            installSplitPaneMenuItems()
            installPresentationMenuItem()
            installTabSelectionMenuItems()
            installWorkspaceMenuItems()
            installPaneNavigationMenuItems()
            installToggleBroadcastMenuItem()

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
        config: GhostTermConfig
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

    static let newTabMenuItemAction = #selector(AppDelegate.createNewTab)
    static let openConfigurationMenuItemAction = #selector(AppDelegate.openConfiguration)
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
        action: Selector = newTabMenuItemAction
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let fileMenu = fileMenu(in: mainMenu)

        let canonicalItems = fileMenu.items.filter(isCanonicalNewTabMenuItem)
        guard let canonicalItem = canonicalItems.first else {
            fileMenu.addItem(makeNewTabMenuItem(target: target, action: action))
            return mainMenu
        }

        canonicalItem.title = "New Tab"
        canonicalItem.action = action
        canonicalItem.keyEquivalent = "t"
        canonicalItem.keyEquivalentModifierMask = [.command]
        canonicalItem.target = target
        for duplicate in canonicalItems.dropFirst() {
            fileMenu.removeItem(duplicate)
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
        action: Selector = openConfigurationMenuItemAction
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let applicationMenu = applicationMenu(in: mainMenu)
        let canonicalItems = applicationMenu.items.filter(isCanonicalOpenConfigurationMenuItem)
        guard let canonicalItem = canonicalItems.first else {
            applicationMenu.addItem(makeOpenConfigurationMenuItem(target: target, action: action))
            return mainMenu
        }

        canonicalItem.title = "Open Configuration…"
        canonicalItem.action = action
        canonicalItem.keyEquivalent = ","
        canonicalItem.keyEquivalentModifierMask = [.command]
        canonicalItem.target = target
        for duplicate in canonicalItems.dropFirst() {
            applicationMenu.removeItem(duplicate)
        }
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
        splitDownAction: Selector = splitDownMenuItemAction
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
        downAction: Selector = focusDownPaneMenuItemAction
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
        for item in items where !viewMenu.items.contains(where: { $0 === item }) {
            viewMenu.addItem(item)
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
        action: Selector = toggleBroadcastMenuItemAction
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let viewMenu = viewMenu(in: mainMenu)
        let canonicalItems = viewMenu.items.filter(isCanonicalToggleBroadcastMenuItem)
        guard let canonicalItem = canonicalItems.first else {
            viewMenu.addItem(makeToggleBroadcastMenuItem(target: target, action: action))
            return mainMenu
        }

        canonicalItem.title = "Toggle Broadcast Input"
        canonicalItem.action = action
        canonicalItem.keyEquivalent = "b"
        canonicalItem.keyEquivalentModifierMask = [.command]
        canonicalItem.target = target
        for duplicate in canonicalItems.dropFirst() {
            viewMenu.removeItem(duplicate)
        }
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
        if let applicationItem = mainMenu.item(withTitle: "GhostTerm") {
            if let existingApplicationMenu = applicationItem.submenu {
                return existingApplicationMenu
            }
            let newApplicationMenu = NSMenu(title: "GhostTerm")
            applicationItem.submenu = newApplicationMenu
            return newApplicationMenu
        }

        let applicationItem = NSMenuItem(title: "GhostTerm", action: nil, keyEquivalent: "")
        let newApplicationMenu = NSMenu(title: "GhostTerm")
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
        action: Selector = tabSelectionMenuItemAction
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let viewMenu = viewMenu(in: mainMenu)

        for index in 1...9 {
            let canonicalItems = viewMenu.items.filter {
                $0.title == "Select Tab \(index)"
                    || ($0.keyEquivalent == "\(index)"
                        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                            == [.command])
            }
            guard let canonicalItem = canonicalItems.first else {
                viewMenu.addItem(
                    makeTabSelectionMenuItem(index: index, target: target, action: action))
                continue
            }

            canonicalItem.title = "Select Tab \(index)"
            canonicalItem.action = action
            canonicalItem.keyEquivalent = "\(index)"
            canonicalItem.keyEquivalentModifierMask = [.command]
            canonicalItem.representedObject = NSNumber(value: index)
            canonicalItem.target = target
            for duplicate in canonicalItems.dropFirst() {
                viewMenu.removeItem(duplicate)
            }
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
        selectionAction: Selector = workspaceSelectionMenuItemAction
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
        _ = installWorkspaceSelectionMenuItems(
            in: mainMenu,
            target: target,
            action: selectionAction
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
        action: Selector = workspaceSelectionMenuItemAction
    ) -> NSMenu {
        let mainMenu = existingMainMenu ?? NSMenu()
        let menu = workspaceMenu(in: mainMenu)
        removeLegacyWorkspaceSelectionItems(from: mainMenu, excluding: menu)

        for index in 1...9 {
            let canonicalItems = menu.items.filter {
                $0.title == "Select Workspace \(index)"
                    || ($0.keyEquivalent == "\(index)"
                        && normalizedShortcutModifiers(for: $0) == [.command, .option])
            }
            guard let canonicalItem = canonicalItems.first else {
                menu.addItem(
                    makeWorkspaceSelectionMenuItem(index: index, target: target, action: action))
                continue
            }

            canonicalItem.title = "Select Workspace \(index)"
            canonicalItem.action = action
            canonicalItem.keyEquivalent = "\(index)"
            canonicalItem.keyEquivalentModifierMask = [.command, .option]
            canonicalItem.representedObject = NSNumber(value: index)
            canonicalItem.target = target
            for duplicate in canonicalItems.dropFirst() {
                menu.removeItem(duplicate)
            }
        }
        return mainMenu
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
        return Self.validateWorkspaceMenuItem(
            menuItem,
            coordinatorAvailable: windowCoordinator != nil,
            hasActiveWorkspace: windowCoordinator?.hasActiveWorkspace ?? false,
            canDeleteActiveWorkspace: windowCoordinator?.canDeleteActiveWorkspace ?? false
        )
    }

    @objc private func createNewTab() {
        windowCoordinator?.createNewTab()
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
        let mainMenu = Self.installNewTabMenuItem(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installOpenConfigurationMenuItem() {
        let mainMenu = Self.installOpenConfigurationMenuItem(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installSplitPaneMenuItems() {
        let mainMenu = Self.installSplitPaneMenuItems(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installPaneNavigationMenuItems() {
        let mainMenu = Self.installPaneNavigationMenuItems(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installToggleBroadcastMenuItem() {
        let mainMenu = Self.installToggleBroadcastMenuItem(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
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

    private func installTabSelectionMenuItems() {
        let mainMenu = Self.installTabSelectionMenuItems(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func installWorkspaceMenuItems() {
        let mainMenu = Self.installWorkspaceMenuItems(in: NSApp.mainMenu, target: self)
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }
    }

    private func logConfigurationError(_ error: Error) {
        logger.error("Configuration update failed: \(error.localizedDescription, privacy: .public)")
    }
}
