import AppKit
import Testing

@testable import QuickTTY

@MainActor
private final class NewTabMenuActionTarget: NSObject {
    private(set) var invocationCount = 0

    @objc func createNewTab() {
        invocationCount += 1
    }
}

@MainActor
private final class OpenConfigurationMenuActionTarget: NSObject {
    private(set) var invocationCount = 0

    @objc func openConfiguration() {
        invocationCount += 1
    }
}

@MainActor
private final class TabSelectionMenuActionTarget: NSObject {
    private(set) var selectedIndices: [Int] = []

    @objc func activateTab(_ sender: NSMenuItem) {
        selectedIndices.append((sender.representedObject as? NSNumber)?.intValue ?? -1)
    }
}

@MainActor
private final class WorkspaceSelectionMenuActionTarget: NSObject {
    private(set) var selectedIndices: [Int] = []

    @objc func activateWorkspace(_ sender: NSMenuItem) {
        selectedIndices.append((sender.representedObject as? NSNumber)?.intValue ?? -1)
    }
}

@MainActor
private final class WorkspaceMenuActionTarget: NSObject {
    private(set) var invocations: [String] = []
    private(set) var selectedIndices: [Int] = []

    @objc func createWorkspace() {
        invocations.append("new")
    }

    @objc func renameWorkspace() {
        invocations.append("rename")
    }

    @objc func deleteWorkspace() {
        invocations.append("delete")
    }

    @objc func activateWorkspace(_ sender: NSMenuItem) {
        selectedIndices.append((sender.representedObject as? NSNumber)?.intValue ?? -1)
    }
}

@MainActor
private final class CloseMenuActionTarget: NSObject {
    private(set) var closePaneInvocationCount = 0
    private(set) var closeTabInvocationCount = 0

    @objc func closePane() {
        closePaneInvocationCount += 1
    }

    @objc func closeTab() {
        closeTabInvocationCount += 1
    }
}

@MainActor
private final class SplitPaneMenuActionTarget: NSObject {
    private(set) var splitRightInvocationCount = 0
    private(set) var splitDownInvocationCount = 0

    @objc func splitRight() {
        splitRightInvocationCount += 1
    }

    @objc func splitDown() {
        splitDownInvocationCount += 1
    }
}

@MainActor
private final class PaneNavigationMenuActionTarget: NSObject {
    private(set) var invocations: [String] = []

    @objc func focusPreviousPane() {
        invocations.append("previous")
    }

    @objc func focusNextPane() {
        invocations.append("next")
    }

    @objc func focusLeftPane() {
        invocations.append("left")
    }

    @objc func focusRightPane() {
        invocations.append("right")
    }

    @objc func focusUpPane() {
        invocations.append("up")
    }

    @objc func focusDownPane() {
        invocations.append("down")
    }
}

@MainActor
struct AppDelegateLifecycleTests {
    @Test
    func startupErrorUsesQuickTTYName() {
        #expect(AppDelegate.startupErrorMessage == "QuickTTY could not start")
    }

    @Test
    func terminationPolicyKeepsQuakeAliveAndPreservesNormalBehavior() {
        #expect(
            AppDelegate.shouldTerminateAfterLastWindowClosed(
                isRunningHostedTests: false,
                presentationMode: .normal
            )
        )
        #expect(
            AppDelegate.shouldTerminateAfterLastWindowClosed(
                isRunningHostedTests: false,
                presentationMode: nil
            )
        )
        #expect(
            !AppDelegate.shouldTerminateAfterLastWindowClosed(
                isRunningHostedTests: false,
                presentationMode: .quake
            )
        )
    }

    @Test
    func configurationDiagnosticsMapToPathAwarePresentationAndClearWhenEmpty() {
        let configURL = URL(fileURLWithPath: "/tmp/quicktty/config")
        let diagnostics = [
            ConfigDiagnostic(
                line: 4,
                key: "quicktty-quake-height",
                reason: .invalidNumber(expected: "a value in 0...1 or 1%...100%")
            ),
            ConfigDiagnostic(
                line: 9,
                key: "quicktty-restore-workspaces",
                reason: .invalidBoolean
            ),
        ]

        let presentation = AppDelegate.configurationDiagnosticsPresentation(
            configURL: configURL,
            diagnostics: diagnostics
        )

        #expect(presentation?.path == configURL.path)
        #expect(presentation?.messages == diagnostics.map(\.localizedDescription))
        #expect(
            AppDelegate.configurationDiagnosticsPresentation(configURL: configURL, diagnostics: [])
                == nil
        )

        let error = ConfigControllerError.sourceReadFailed("permission denied")
        #expect(
            AppDelegate.configurationErrorPresentation(configURL: configURL, error: error)
                == ConfigDiagnosticPresentation(
                    path: configURL.path,
                    messages: [error.localizedDescription]
                )
        )
    }

    @Test
    func configurationDiagnosticsReceivedBeforeCoordinatorAreRetainedAndForwarded() throws {
        let delegate = AppDelegate()
        let configURL = URL(fileURLWithPath: "/tmp/quicktty/config")
        let diagnostics = [
            ConfigDiagnostic(
                line: 4,
                key: "quicktty-quake-height",
                reason: .invalidNumber(expected: "a value in 0...1 or 1%...100%")
            )
        ]
        let expectedPresentation = try #require(
            AppDelegate.configurationDiagnosticsPresentation(
                configURL: configURL,
                diagnostics: diagnostics
            )
        )

        delegate.receiveConfigurationDiagnosticsForTesting(diagnostics, configURL: configURL)

        #expect(delegate.configurationDiagnosticsPresentationForTesting == expectedPresentation)

        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        delegate.installWindowCoordinatorForTesting(coordinator)
        delegate.applyPendingConfigurationDiagnosticsForTesting()

        #expect(
            coordinator.workspaceViewControllerForTesting.configurationDiagnosticTextForTesting
                == "\(configURL.path)\n\(diagnostics[0].localizedDescription)"
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.configurationDiagnosticIsVisibleForTesting
        )

        delegate.receiveConfigurationDiagnosticsForTesting([], configURL: configURL)

        #expect(delegate.configurationDiagnosticsPresentationForTesting == nil)
        #expect(
            !coordinator.workspaceViewControllerForTesting
                .configurationDiagnosticIsVisibleForTesting
        )
    }

    @Test
    func terminationPolicyKeepsHostedTestsAlive() {
        #expect(
            !AppDelegate.shouldTerminateAfterLastWindowClosed(
                isRunningHostedTests: true,
                presentationMode: .normal
            )
        )
        #expect(
            !AppDelegate.shouldTerminateAfterLastWindowClosed(
                isRunningHostedTests: true,
                presentationMode: .quake
            )
        )
    }

    @Test
    func updatingNormalWindowFramePreservesOtherApplicationState() throws {
        let workspaceStore = WorkspaceStore()
        let frame = try #require(NormalWindowFrame(x: 12, y: 34, width: 900, height: 600))
        let initialState = ApplicationState(workspaceStore: workspaceStore)

        let updatedState = AppDelegate.applicationState(
            initialState,
            updatingNormalWindowFrame: frame
        )

        #expect(updatedState.workspaceStore == workspaceStore)
        #expect(updatedState.normalWindowFrame == frame)
    }

    @Test
    func startupWorkspaceSelectionFollowsConfigWithoutChangingSavedFrame() throws {
        let paneID = PaneID()
        let tab = TerminalTab(
            title: "Saved",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp/saved")
        )
        let workspace = Workspace(name: "Saved", tabs: [tab], activeTabID: tab.id)
        let savedStore = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let frame = try #require(NormalWindowFrame(x: 12, y: 34, width: 900, height: 600))
        let applicationState = ApplicationState(
            workspaceStore: savedStore,
            normalWindowFrame: frame
        )
        var restoringConfig = QuickTTYConfig()
        restoringConfig.restoreWorkspaces = true
        var freshConfig = restoringConfig
        freshConfig.restoreWorkspaces = false

        #expect(
            AppDelegate.initialWorkspaceStore(
                applicationState: applicationState,
                config: restoringConfig
            ) == savedStore
        )
        #expect(
            AppDelegate.initialWorkspaceStore(
                applicationState: applicationState,
                config: freshConfig
            ) != savedStore
        )
        #expect(applicationState.normalWindowFrame == frame)
    }

    @Test
    func workspaceCallbackAndTerminationMergePreserveLatestWorkspaceAndFrame() throws {
        let savedFrame = try #require(NormalWindowFrame(x: 1, y: 2, width: 800, height: 600))
        let latestFrame = try #require(NormalWindowFrame(x: 12, y: 34, width: 900, height: 700))
        let savedWorkspace = Workspace(name: "Saved")
        let runtimeWorkspace = Workspace(name: "Runtime")
        let savedStore = try WorkspaceStore(
            workspaces: [savedWorkspace],
            activeWorkspaceID: savedWorkspace.id
        )
        let runtimeStore = try WorkspaceStore(
            workspaces: [runtimeWorkspace],
            activeWorkspaceID: runtimeWorkspace.id
        )
        let savedState = ApplicationState(
            workspaceStore: savedStore,
            normalWindowFrame: savedFrame
        )

        let callbackState = AppDelegate.applicationState(
            savedState,
            updatingWorkspaceStore: runtimeStore
        )
        let terminationState = AppDelegate.applicationState(
            callbackState,
            merging: runtimeStore,
            normalWindowFrame: latestFrame
        )

        #expect(callbackState.workspaceStore == runtimeStore)
        #expect(callbackState.normalWindowFrame == savedFrame)
        #expect(terminationState.workspaceStore == runtimeStore)
        #expect(terminationState.normalWindowFrame == latestFrame)
    }

    @Test
    func terminationCapturesFinalSnapshotBeforeDetachAndShutsDownAfterSaveFailure() throws {
        enum SaveFailure: Error {
            case expected
        }

        let savedWorkspace = Workspace(name: "Saved")
        let finalWorkspace = Workspace(name: "Final")
        let savedStore = try WorkspaceStore(
            workspaces: [savedWorkspace],
            activeWorkspaceID: savedWorkspace.id
        )
        let finalStore = try WorkspaceStore(
            workspaces: [finalWorkspace],
            activeWorkspaceID: finalWorkspace.id
        )
        let savedFrame = try #require(NormalWindowFrame(x: 1, y: 2, width: 800, height: 600))
        let finalFrame = try #require(NormalWindowFrame(x: 12, y: 34, width: 900, height: 700))
        let applicationState = ApplicationState(
            workspaceStore: savedStore,
            normalWindowFrame: savedFrame
        )
        var events: [String] = []
        var scheduledState: ApplicationState?

        AppDelegate.performApplicationTermination(
            stopConfiguration: {
                events.append("stop configuration")
            },
            persistFinalState: {
                events.append("snapshot")
                let finalState = AppDelegate.applicationState(
                    applicationState,
                    merging: finalStore,
                    normalWindowFrame: finalFrame
                )
                scheduledState = finalState
                events.append("schedule and flush")
                throw SaveFailure.expected
            },
            logSaveError: { _ in
                events.append("save failed")
            },
            prepareForTermination: {
                events.append("detach")
            },
            shutdownRuntime: {
                events.append("shutdown")
            }
        )

        #expect(
            events
                == [
                    "stop configuration",
                    "snapshot",
                    "schedule and flush",
                    "save failed",
                    "detach",
                    "shutdown",
                ]
        )
        #expect(scheduledState?.workspaceStore == finalStore)
        #expect(scheduledState?.normalWindowFrame == finalFrame)
    }

    @Test
    func newTabMenuItemUsesCommandTAndAppDelegateAction() {
        let delegate = AppDelegate()
        let item = AppDelegate.makeNewTabMenuItem(target: delegate)

        #expect(item.title == "New Tab")
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.target === delegate)
        #expect(item.action == AppDelegate.newTabMenuItemAction)
    }

    @Test
    func openConfigurationMenuItemUsesCommandCommaAndAppDelegateAction() {
        let delegate = AppDelegate()
        let item = AppDelegate.makeOpenConfigurationMenuItem(target: delegate)

        #expect(item.title == "Open Configuration…")
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.target === delegate)
        #expect(item.action == AppDelegate.openConfigurationMenuItemAction)
    }

    @Test
    func openConfigurationMenuInstallerCreatesApplicationMenuAndDispatchesAction() throws {
        let target = OpenConfigurationMenuActionTarget()
        let mainMenu = AppDelegate.installOpenConfigurationMenuItem(
            in: nil,
            target: target,
            action: #selector(OpenConfigurationMenuActionTarget.openConfiguration)
        )
        let applicationMenu = mainMenu.item(withTitle: "QuickTTY")?.submenu
        let item = try #require(applicationMenu?.item(withTitle: "Open Configuration…"))

        #expect(applicationMenu?.items.count == 1)
        #expect(item.action == #selector(OpenConfigurationMenuActionTarget.openConfiguration))
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.target === target)
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        #expect(target.invocationCount == 1)
    }

    @Test
    func openConfigurationMenuInstallerIsIdempotentAndPreservesForeignModifiedCommas() throws {
        let target = OpenConfigurationMenuActionTarget()
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(title: "QuickTTY", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "QuickTTY")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let commandCapsLockComma = NSMenuItem(title: "Foreign", action: nil, keyEquivalent: ",")
        commandCapsLockComma.keyEquivalentModifierMask = [.command, .capsLock]
        let titledDuplicate = NSMenuItem(
            title: "Open Configuration…",
            action: nil,
            keyEquivalent: "x"
        )
        let commandShiftComma = NSMenuItem(title: "Shift", action: nil, keyEquivalent: ",")
        commandShiftComma.keyEquivalentModifierMask = [.command, .shift]
        let commandOptionComma = NSMenuItem(title: "Option", action: nil, keyEquivalent: ",")
        commandOptionComma.keyEquivalentModifierMask = [.command, .option]
        let commandControlComma = NSMenuItem(title: "Control", action: nil, keyEquivalent: ",")
        commandControlComma.keyEquivalentModifierMask = [.command, .control]
        let commandNumericPadComma = NSMenuItem(
            title: "Numeric Pad", action: nil, keyEquivalent: ",")
        commandNumericPadComma.keyEquivalentModifierMask = [.command, .numericPad]
        let commandHelpComma = NSMenuItem(title: "Help", action: nil, keyEquivalent: ",")
        commandHelpComma.keyEquivalentModifierMask = [.command, .help]
        [
            commandCapsLockComma,
            titledDuplicate,
            commandShiftComma,
            commandOptionComma,
            commandControlComma,
            commandNumericPadComma,
            commandHelpComma,
        ].forEach(applicationMenu.addItem)

        for _ in 0..<2 {
            AppDelegate.installOpenConfigurationMenuItem(
                in: mainMenu,
                target: target,
                action: #selector(OpenConfigurationMenuActionTarget.openConfiguration)
            )
        }

        let item = try #require(applicationMenu.item(withTitle: "Open Configuration…"))
        #expect(applicationMenu.items.count == 6)
        #expect(applicationMenu.items.filter { $0.title == "Open Configuration…" }.count == 1)
        #expect(item === commandCapsLockComma)
        #expect(item.action == #selector(OpenConfigurationMenuActionTarget.openConfiguration))
        #expect(item.keyEquivalent == ",")
        #expect(AppDelegate.hasExactCommandShortcutModifiers(item.keyEquivalentModifierMask))
        #expect(item.target === target)

        let foreignItems = [
            commandShiftComma,
            commandOptionComma,
            commandControlComma,
            commandNumericPadComma,
            commandHelpComma,
        ]
        for foreignItem in foreignItems {
            #expect(applicationMenu.items.contains { $0 === foreignItem })
            #expect(
                !AppDelegate.hasExactCommandShortcutModifiers(foreignItem.keyEquivalentModifierMask)
            )
        }
        #expect(!AppDelegate.hasExactCommandShortcutModifiers([.command, .function]))
    }

    @Test
    func newTabMenuInstallerCreatesFileMenuWhenMainMenuIsAbsent() throws {
        let target = NewTabMenuActionTarget()
        let mainMenu = AppDelegate.installNewTabMenuItem(
            in: nil,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        let fileMenu = mainMenu.item(withTitle: "File")?.submenu
        let item = try #require(fileMenu?.item(withTitle: "New Tab"))

        #expect(fileMenu != nil)
        #expect(fileMenu?.items.count == 1)
        #expect(item.title == "New Tab")
        #expect(item.action == #selector(NewTabMenuActionTarget.createNewTab))
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.target === target)

        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        #expect(target.invocationCount == 1)
    }

    @Test
    func newTabMenuInstallerAttachesSubmenuToExistingFileItem() {
        let target = NewTabMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)

        let installedMainMenu = AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        let fileMenu = fileItem.submenu

        #expect(installedMainMenu === mainMenu)
        #expect(mainMenu.item(withTitle: "File") === fileItem)
        #expect(fileMenu != nil)
        #expect(fileMenu?.items.count == 1)
        #expect(fileMenu?.item(withTitle: "New Tab") != nil)
    }

    @Test
    func newTabMenuInstallerIsIdempotentAndPreservesOtherMenus() {
        let target = NewTabMenuActionTarget()
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = NSMenu(title: "View")
        mainMenu.addItem(viewItem)

        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )

        #expect(mainMenu.item(withTitle: "View") === viewItem)
        #expect(mainMenu.item(withTitle: "File")?.submenu?.items.count == 1)
    }

    @Test
    func newTabMenuInstallerRespectsExistingCanonicalItemWithAnotherTarget() {
        let installedTarget = NewTabMenuActionTarget()
        let existingTarget = NewTabMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let existingItem = NSMenuItem(
            title: "New Tab",
            action: #selector(NewTabMenuActionTarget.createNewTab),
            keyEquivalent: "t"
        )
        existingItem.keyEquivalentModifierMask = [.command]
        existingItem.target = existingTarget
        fileMenu.addItem(existingItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: installedTarget,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )

        #expect(fileMenu.items.count == 1)
        #expect(fileMenu.item(withTitle: "New Tab") === existingItem)
        #expect(existingItem.action == #selector(NewTabMenuActionTarget.createNewTab))
        #expect(existingItem.keyEquivalent == "t")
        #expect(existingItem.keyEquivalentModifierMask == [.command])
        #expect(existingItem.target === installedTarget)
        #expect(NSApp.sendAction(existingItem.action!, to: existingItem.target, from: existingItem))
        #expect(installedTarget.invocationCount == 1)
        #expect(existingTarget.invocationCount == 0)
    }

    @Test
    func newTabMenuInstallerNormalizesAndDeduplicatesCanonicalItems() {
        let target = NewTabMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let commandTItem = NSMenuItem(title: "Foreign Tab", action: nil, keyEquivalent: "T")
        commandTItem.keyEquivalentModifierMask = [.command]
        let titledItem = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "n")
        let modifiedItem = NSMenuItem(title: "Reopen Tab", action: nil, keyEquivalent: "t")
        modifiedItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(commandTItem)
        fileMenu.addItem(titledItem)
        fileMenu.addItem(modifiedItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )

        #expect(fileMenu.items.count == 2)
        #expect(fileMenu.items.filter { $0.title == "New Tab" }.count == 1)
        #expect(commandTItem.title == "New Tab")
        #expect(commandTItem.action == #selector(NewTabMenuActionTarget.createNewTab))
        #expect(commandTItem.keyEquivalent == "t")
        #expect(commandTItem.keyEquivalentModifierMask == [.command])
        #expect(commandTItem.target === target)
        #expect(fileMenu.items.contains { $0 === modifiedItem })
    }

    @Test
    func newTabMenuInstallerDoesNotTreatModifiedCommandTAsCanonical() {
        let target = NewTabMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let modifiedItem = NSMenuItem(title: "Reopen Tab", action: nil, keyEquivalent: "t")
        modifiedItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(modifiedItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )

        #expect(fileMenu.items.count == 2)
    }

    @Test
    func splitPaneMenuInstallerCreatesExactShortcutsAfterNewTabAndDispatchesActions() throws {
        let newTabTarget = NewTabMenuActionTarget()
        let splitTarget = SplitPaneMenuActionTarget()
        let mainMenu = AppDelegate.installNewTabMenuItem(
            in: nil,
            target: newTabTarget,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )

        let installedMainMenu = AppDelegate.installSplitPaneMenuItems(
            in: mainMenu,
            target: splitTarget,
            splitRightAction: #selector(SplitPaneMenuActionTarget.splitRight),
            splitDownAction: #selector(SplitPaneMenuActionTarget.splitDown)
        )
        let fileMenu = try #require(installedMainMenu.item(withTitle: "File")?.submenu)
        let newTabIndex = fileMenu.indexOfItem(withTitle: "New Tab")
        let splitRight = try #require(fileMenu.item(withTitle: "Split Right"))
        let splitDown = try #require(fileMenu.item(withTitle: "Split Down"))

        #expect(newTabIndex >= 0)
        #expect(fileMenu.items.count == 3)
        #expect(fileMenu.items[newTabIndex + 1] === splitRight)
        #expect(fileMenu.items[newTabIndex + 2] === splitDown)
        #expect(splitRight.keyEquivalent == "d")
        #expect(splitRight.keyEquivalentModifierMask == [.command])
        #expect(splitDown.keyEquivalent == "d")
        #expect(splitDown.keyEquivalentModifierMask == [.command, .shift])
        #expect(NSApp.sendAction(splitRight.action!, to: splitRight.target, from: splitRight))
        #expect(NSApp.sendAction(splitDown.action!, to: splitDown.target, from: splitDown))
        #expect(splitTarget.splitRightInvocationCount == 1)
        #expect(splitTarget.splitDownInvocationCount == 1)
    }

    @Test
    func splitPaneMenuInstallerNormalizesDuplicatesAndPreservesModifiedForeignItems() throws {
        let target = SplitPaneMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let commandTItem = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "t")
        commandTItem.keyEquivalentModifierMask = [.command]
        let commandDItem = NSMenuItem(title: "Foreign Right", action: nil, keyEquivalent: "D")
        commandDItem.keyEquivalentModifierMask = [.command]
        let titledRightItem = NSMenuItem(title: "Split Right", action: nil, keyEquivalent: "x")
        let commandShiftDItem = NSMenuItem(title: "Foreign Down", action: nil, keyEquivalent: "D")
        commandShiftDItem.keyEquivalentModifierMask = [.command, .shift]
        let titledDownItem = NSMenuItem(title: "Split Down", action: nil, keyEquivalent: "x")
        let commandOptionDItem = NSMenuItem(
            title: "Foreign Option", action: nil, keyEquivalent: "d")
        commandOptionDItem.keyEquivalentModifierMask = [.command, .option]
        let commandControlDItem = NSMenuItem(
            title: "Foreign Control", action: nil, keyEquivalent: "d")
        commandControlDItem.keyEquivalentModifierMask = [.command, .control]
        [
            commandTItem,
            commandDItem,
            titledRightItem,
            commandShiftDItem,
            titledDownItem,
            commandOptionDItem,
            commandControlDItem,
        ].forEach(fileMenu.addItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: NewTabMenuActionTarget(),
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        AppDelegate.installSplitPaneMenuItems(
            in: mainMenu,
            target: target,
            splitRightAction: #selector(SplitPaneMenuActionTarget.splitRight),
            splitDownAction: #selector(SplitPaneMenuActionTarget.splitDown)
        )
        AppDelegate.installSplitPaneMenuItems(
            in: mainMenu,
            target: target,
            splitRightAction: #selector(SplitPaneMenuActionTarget.splitRight),
            splitDownAction: #selector(SplitPaneMenuActionTarget.splitDown)
        )

        let newTabIndex = fileMenu.indexOfItem(withTitle: "New Tab")
        let splitRight = try #require(fileMenu.item(withTitle: "Split Right"))
        let splitDown = try #require(fileMenu.item(withTitle: "Split Down"))
        #expect(fileMenu.items.count == 5)
        #expect(fileMenu.items.filter { $0.title == "Split Right" }.count == 1)
        #expect(fileMenu.items.filter { $0.title == "Split Down" }.count == 1)
        #expect(fileMenu.items[newTabIndex + 1] === splitRight)
        #expect(fileMenu.items[newTabIndex + 2] === splitDown)
        #expect(splitRight === commandDItem)
        #expect(splitDown === commandShiftDItem)
        #expect(splitRight.action == #selector(SplitPaneMenuActionTarget.splitRight))
        #expect(splitDown.action == #selector(SplitPaneMenuActionTarget.splitDown))
        #expect(splitRight.target === target)
        #expect(splitDown.target === target)
        #expect(fileMenu.items.contains { $0 === commandOptionDItem })
        #expect(fileMenu.items.contains { $0 === commandControlDItem })
    }

    @Test
    func paneNavigationMenuItemsUsePinnedShortcutsAndDispatchActions() throws {
        let target = PaneNavigationMenuActionTarget()
        let mainMenu = AppDelegate.installPaneNavigationMenuItems(
            in: nil,
            target: target,
            previousAction: #selector(PaneNavigationMenuActionTarget.focusPreviousPane),
            nextAction: #selector(PaneNavigationMenuActionTarget.focusNextPane),
            leftAction: #selector(PaneNavigationMenuActionTarget.focusLeftPane),
            rightAction: #selector(PaneNavigationMenuActionTarget.focusRightPane),
            upAction: #selector(PaneNavigationMenuActionTarget.focusUpPane),
            downAction: #selector(PaneNavigationMenuActionTarget.focusDownPane)
        )
        let viewMenu = try #require(mainMenu.item(withTitle: "View")?.submenu)
        let expected = [
            ("Previous Pane", "[", NSEvent.ModifierFlags.command),
            ("Next Pane", "]", .command),
            (
                "Focus Left Pane", String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                [.command, .option]
            ),
            (
                "Focus Right Pane", String(UnicodeScalar(NSRightArrowFunctionKey)!),
                [.command, .option]
            ),
            (
                "Focus Up Pane", String(UnicodeScalar(NSUpArrowFunctionKey)!),
                [.command, .option]
            ),
            (
                "Focus Down Pane", String(UnicodeScalar(NSDownArrowFunctionKey)!),
                [.command, .option]
            ),
        ]

        #expect(viewMenu.items.count == expected.count)
        for (title, keyEquivalent, modifierMask) in expected {
            let item = try #require(viewMenu.item(withTitle: title))
            #expect(item.keyEquivalent == keyEquivalent)
            #expect(item.keyEquivalentModifierMask == modifierMask)
            #expect(item.target === target)
            #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        #expect(target.invocations == ["previous", "next", "left", "right", "up", "down"])
    }

    @Test
    func paneNavigationMenuInstallerNormalizesDuplicatesAndPreservesForeignShortcuts() throws {
        let target = PaneNavigationMenuActionTarget()
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let commandBracket = NSMenuItem(title: "Foreign Previous", action: nil, keyEquivalent: "[")
        commandBracket.keyEquivalentModifierMask = [.command]
        let titledPrevious = NSMenuItem(title: "Previous Pane", action: nil, keyEquivalent: "x")
        let commandOptionLeft = NSMenuItem(
            title: "Foreign Left",
            action: nil,
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        commandOptionLeft.keyEquivalentModifierMask = [.command, .option]
        let titledLeft = NSMenuItem(title: "Focus Left Pane", action: nil, keyEquivalent: "x")
        let commandShiftBracket = NSMenuItem(
            title: "Foreign Shift", action: nil, keyEquivalent: "[")
        commandShiftBracket.keyEquivalentModifierMask = [.command, .shift]
        let commandControlOptionLeft = NSMenuItem(
            title: "Foreign Control",
            action: nil,
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        commandControlOptionLeft.keyEquivalentModifierMask = [.command, .option, .control]
        [
            commandBracket,
            titledPrevious,
            commandOptionLeft,
            titledLeft,
            commandShiftBracket,
            commandControlOptionLeft,
        ].forEach(viewMenu.addItem)

        for _ in 0..<2 {
            AppDelegate.installPaneNavigationMenuItems(
                in: mainMenu,
                target: target,
                previousAction: #selector(PaneNavigationMenuActionTarget.focusPreviousPane),
                nextAction: #selector(PaneNavigationMenuActionTarget.focusNextPane),
                leftAction: #selector(PaneNavigationMenuActionTarget.focusLeftPane),
                rightAction: #selector(PaneNavigationMenuActionTarget.focusRightPane),
                upAction: #selector(PaneNavigationMenuActionTarget.focusUpPane),
                downAction: #selector(PaneNavigationMenuActionTarget.focusDownPane)
            )
        }

        #expect(viewMenu.items.count == 8)
        #expect(viewMenu.items.filter { $0.title == "Previous Pane" }.count == 1)
        #expect(viewMenu.items.filter { $0.title == "Focus Left Pane" }.count == 1)
        #expect(commandBracket.title == "Previous Pane")
        #expect(
            commandBracket.action == #selector(PaneNavigationMenuActionTarget.focusPreviousPane))
        #expect(commandBracket.target === target)
        #expect(commandOptionLeft.title == "Focus Left Pane")
        #expect(commandOptionLeft.action == #selector(PaneNavigationMenuActionTarget.focusLeftPane))
        #expect(commandOptionLeft.target === target)
        #expect(viewMenu.items.contains { $0 === commandShiftBracket })
        #expect(viewMenu.items.contains { $0 === commandControlOptionLeft })
    }

    @Test
    func workspaceMenuInstallerCreatesManagementAndSelectionItemsThatDispatchOnce() throws {
        let target = WorkspaceMenuActionTarget()
        let mainMenu = AppDelegate.installWorkspaceMenuItems(
            in: nil,
            target: target,
            createAction: #selector(WorkspaceMenuActionTarget.createWorkspace),
            renameAction: #selector(WorkspaceMenuActionTarget.renameWorkspace),
            deleteAction: #selector(WorkspaceMenuActionTarget.deleteWorkspace),
            selectionAction: #selector(WorkspaceMenuActionTarget.activateWorkspace(_:))
        )
        let workspaceMenu = try #require(mainMenu.item(withTitle: "Workspace")?.submenu)
        let managementItems = workspaceMenu.items.filter { !$0.isSeparatorItem }.prefix(3)
        let selectionItems = workspaceMenu.items.filter {
            $0.title.hasPrefix("Select Workspace ")
        }

        #expect(mainMenu.items.filter { $0.title == "Workspace" }.count == 1)
        #expect(
            managementItems.map(\.title) == [
                "New Workspace…", "Rename Workspace…", "Delete Workspace…",
            ])
        #expect(workspaceMenu.items[3].isSeparatorItem)
        #expect(selectionItems.count == 9)
        #expect(workspaceMenu.items.count == 13)
        #expect(
            NSApp.sendAction(
                managementItems[0].action!, to: managementItems[0].target, from: managementItems[0])
        )
        #expect(
            NSApp.sendAction(
                managementItems[1].action!, to: managementItems[1].target, from: managementItems[1])
        )
        #expect(
            NSApp.sendAction(
                managementItems[2].action!, to: managementItems[2].target, from: managementItems[2])
        )
        #expect(
            NSApp.sendAction(
                selectionItems[1].action!, to: selectionItems[1].target, from: selectionItems[1]))
        #expect(target.invocations == ["new", "rename", "delete"])
        #expect(target.selectedIndices == [2])
    }

    @Test
    func workspaceMenuInstallerIsIdempotentAndRemovesViewShortcutDuplicates() throws {
        let target = WorkspaceMenuActionTarget()
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let legacySelection = NSMenuItem(
            title: "Select Workspace 1",
            action: #selector(WorkspaceMenuActionTarget.activateWorkspace(_:)),
            keyEquivalent: "1"
        )
        legacySelection.keyEquivalentModifierMask = [.command, .option]
        legacySelection.target = target
        viewMenu.addItem(legacySelection)
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspaceItem.submenu = NSMenu(title: "Workspace")
        let duplicateWorkspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        duplicateWorkspaceItem.submenu = NSMenu(title: "Workspace")
        mainMenu.addItem(workspaceItem)
        mainMenu.addItem(duplicateWorkspaceItem)

        for _ in 0..<2 {
            AppDelegate.installWorkspaceMenuItems(
                in: mainMenu,
                target: target,
                createAction: #selector(WorkspaceMenuActionTarget.createWorkspace),
                renameAction: #selector(WorkspaceMenuActionTarget.renameWorkspace),
                deleteAction: #selector(WorkspaceMenuActionTarget.deleteWorkspace),
                selectionAction: #selector(WorkspaceMenuActionTarget.activateWorkspace(_:))
            )
        }

        let workspaceMenu = try #require(mainMenu.item(withTitle: "Workspace")?.submenu)
        let selectionItems = workspaceMenu.items.filter {
            $0.title.hasPrefix("Select Workspace ")
        }
        #expect(mainMenu.items.filter { $0.title == "Workspace" }.count == 1)
        #expect(viewMenu.items.allSatisfy { !$0.title.hasPrefix("Select Workspace ") })
        #expect(selectionItems.count == 9)
        #expect(
            selectionItems.allSatisfy {
                $0.keyEquivalentModifierMask == [.command, .option]
                    && $0.action == #selector(WorkspaceMenuActionTarget.activateWorkspace(_:))
                    && $0.target === target
            })
    }

    @Test
    func workspaceMenuValidationRequiresCoordinatorAndEligibleActiveWorkspace() {
        let newItem = NSMenuItem(
            title: "New Workspace…",
            action: AppDelegate.newWorkspaceMenuItemAction,
            keyEquivalent: ""
        )
        let renameItem = NSMenuItem(
            title: "Rename Workspace…",
            action: AppDelegate.renameWorkspaceMenuItemAction,
            keyEquivalent: ""
        )
        let deleteItem = NSMenuItem(
            title: "Delete Workspace…",
            action: AppDelegate.deleteWorkspaceMenuItemAction,
            keyEquivalent: ""
        )

        #expect(
            !AppDelegate.validateWorkspaceMenuItem(
                newItem,
                coordinatorAvailable: false,
                hasActiveWorkspace: false,
                canDeleteActiveWorkspace: false
            ))
        #expect(
            AppDelegate.validateWorkspaceMenuItem(
                newItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: false,
                canDeleteActiveWorkspace: false
            ))
        #expect(
            !AppDelegate.validateWorkspaceMenuItem(
                renameItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: false,
                canDeleteActiveWorkspace: true
            ))
        #expect(
            AppDelegate.validateWorkspaceMenuItem(
                renameItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: true,
                canDeleteActiveWorkspace: false
            ))
        #expect(
            !AppDelegate.validateWorkspaceMenuItem(
                deleteItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: false,
                canDeleteActiveWorkspace: true
            ))
        #expect(
            !AppDelegate.validateWorkspaceMenuItem(
                deleteItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: true,
                canDeleteActiveWorkspace: false
            ))
        #expect(
            AppDelegate.validateWorkspaceMenuItem(
                deleteItem,
                coordinatorAvailable: true,
                hasActiveWorkspace: true,
                canDeleteActiveWorkspace: true
            ))
    }

    @Test
    func workspaceSelectionMenuItemsUseExactCommandOptionDigitsWithoutCollidingWithTabs()
        throws
    {
        let tabTarget = TabSelectionMenuActionTarget()
        let workspaceTarget = WorkspaceSelectionMenuActionTarget()
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let foreignModifiedDigit = NSMenuItem(title: "Foreign", action: nil, keyEquivalent: "1")
        foreignModifiedDigit.keyEquivalentModifierMask = [.command, .option, .shift]
        let foreignShortcut = NSMenuItem(title: "Foreign", action: nil, keyEquivalent: "p")
        foreignShortcut.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(foreignModifiedDigit)
        viewMenu.addItem(foreignShortcut)

        AppDelegate.installTabSelectionMenuItems(
            in: mainMenu,
            target: tabTarget,
            action: #selector(TabSelectionMenuActionTarget.activateTab(_:))
        )
        for _ in 0..<2 {
            AppDelegate.installWorkspaceSelectionMenuItems(
                in: mainMenu,
                target: workspaceTarget,
                action: #selector(WorkspaceSelectionMenuActionTarget.activateWorkspace(_:))
            )
        }

        let workspaceMenu = try #require(mainMenu.item(withTitle: "Workspace")?.submenu)
        let workspaceItems = workspaceMenu.items.filter { $0.title.hasPrefix("Select Workspace ") }
        let tabItems = viewMenu.items.filter { $0.title.hasPrefix("Select Tab ") }
        #expect(workspaceItems.count == 9)
        #expect(tabItems.count == 9)
        for (offset, item) in workspaceItems.enumerated() {
            let index = offset + 1
            #expect(item.title == "Select Workspace \(index)")
            #expect(item.keyEquivalent == "\(index)")
            #expect(item.keyEquivalentModifierMask == [.command, .option])
            #expect((item.representedObject as? NSNumber)?.intValue == index)
            #expect(item.target === workspaceTarget)
            #expect(
                item.action == #selector(WorkspaceSelectionMenuActionTarget.activateWorkspace(_:)))
        }
        #expect(foreignModifiedDigit.keyEquivalentModifierMask == [.command, .option, .shift])
        #expect(viewMenu.items.contains { $0 === foreignModifiedDigit })
        #expect(viewMenu.items.contains { $0 === foreignShortcut })
        #expect(viewMenu.items.allSatisfy { !$0.title.hasPrefix("Select Workspace ") })

        let secondWorkspace = try #require(workspaceItems.dropFirst().first)
        let ninthTab = try #require(tabItems.last)
        #expect(
            NSApp.sendAction(
                secondWorkspace.action!, to: secondWorkspace.target, from: secondWorkspace))
        #expect(NSApp.sendAction(ninthTab.action!, to: ninthTab.target, from: ninthTab))
        #expect(workspaceTarget.selectedIndices == [2])
        #expect(tabTarget.selectedIndices == [9])
    }

    @Test
    func tabSelectionMenuItemsUseExactCommandDigitsAndInstallIdempotently() throws {
        let target = TabSelectionMenuActionTarget()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = NSMenu(title: "File")
        mainMenu.addItem(fileItem)

        AppDelegate.installTabSelectionMenuItems(
            in: mainMenu,
            target: target,
            action: #selector(TabSelectionMenuActionTarget.activateTab(_:))
        )
        AppDelegate.installTabSelectionMenuItems(
            in: mainMenu,
            target: target,
            action: #selector(TabSelectionMenuActionTarget.activateTab(_:))
        )

        let viewMenu = try #require(mainMenu.item(withTitle: "View")?.submenu)
        let items = viewMenu.items.filter { $0.title.hasPrefix("Select Tab ") }
        #expect(items.count == 9)
        for (offset, item) in items.enumerated() {
            let index = offset + 1
            #expect(item.title == "Select Tab \(index)")
            #expect(item.keyEquivalent == "\(index)")
            #expect(item.keyEquivalentModifierMask == [.command])
            #expect((item.representedObject as? NSNumber)?.intValue == index)
            #expect(item.target === target)
            #expect(item.action == #selector(TabSelectionMenuActionTarget.activateTab(_:)))
        }

        let seventhItem = try #require(items.last)
        #expect(NSApp.sendAction(seventhItem.action!, to: seventhItem.target, from: seventhItem))
        #expect(target.selectedIndices == [9])
        #expect(fileItem.submenu?.item(withTitle: "New Tab") == nil)
    }

    @Test
    func closeMenuRoutesHotReloadOldNewAndDisabledChordsExactlyOnce() throws {
        let target = CloseMenuActionTarget()
        let controller = ShortcutController()
        let mainMenu = AppDelegate.installCloseMenuItems(
            in: nil,
            target: target,
            closePaneAction: #selector(CloseMenuActionTarget.closePane),
            closeTabAction: #selector(CloseMenuActionTarget.closeTab),
            shortcutController: controller
        )
        let fileMenu = try #require(mainMenu.item(withTitle: "File")?.submenu)
        let closePane = try #require(fileMenu.item(withTitle: "Close Pane"))
        let closeTab = try #require(fileMenu.item(withTitle: "Close Tab"))
        let oldEvent = try menuShortcutEvent(key: "w", modifiers: [.command])
        let newEvent = try menuShortcutEvent(key: "x", modifiers: [.control])

        #expect(mainMenu.performKeyEquivalent(with: oldEvent))
        #expect(target.closePaneInvocationCount == 1)
        #expect(target.closeTabInvocationCount == 0)

        var configuration = ShortcutConfiguration.defaults
        configuration.assign(ShortcutChord(key: .x, modifiers: [.control]), to: .closePane)
        controller.apply(configuration)

        #expect(!mainMenu.performKeyEquivalent(with: oldEvent))
        #expect(mainMenu.performKeyEquivalent(with: newEvent))
        #expect(target.closePaneInvocationCount == 2)
        #expect(closePane.keyEquivalent == "x")
        #expect(closePane.keyEquivalentModifierMask == [.control])
        #expect(closeTab.action == #selector(CloseMenuActionTarget.closeTab))

        configuration.disable(.closePane)
        controller.apply(configuration)

        #expect(!mainMenu.performKeyEquivalent(with: newEvent))
        #expect(target.closePaneInvocationCount == 2)
        #expect(closePane.keyEquivalent.isEmpty)
        #expect(closePane.keyEquivalentModifierMask.isEmpty)
    }

    @Test
    func everyStructuralShortcutHasRegisteredMenuRoute() {
        let delegate = AppDelegate()
        let controller = ShortcutController()
        var mainMenu = AppDelegate.installOpenConfigurationMenuItem(
            in: nil,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installQuitMenuItem(
            in: mainMenu,
            target: NSApp,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installCloseMenuItems(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installSplitPaneMenuItems(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installPresentationMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installTabSelectionMenuItems(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installWorkspaceMenuItems(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installPaneNavigationMenuItems(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        _ = AppDelegate.installToggleBroadcastMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )

        let structuralActions = ShortcutAction.allCases.filter {
            if case .terminal = $0.executionRoute { return false }
            return true
        }
        #expect(structuralActions.allSatisfy { controller.menuItem(for: $0) != nil })
    }

    @Test
    func structuralValidationDisablesUnavailableAndOutOfRangeRoutes() {
        let closePane = NSMenuItem(
            title: "Close Pane",
            action: AppDelegate.closePaneMenuItemAction,
            keyEquivalent: ""
        )
        let split = NSMenuItem(
            title: "Split Right",
            action: AppDelegate.splitRightMenuItemAction,
            keyEquivalent: ""
        )
        let selectTab = AppDelegate.makeTabSelectionMenuItem(index: 3, target: AppDelegate())
        let selectWorkspace = AppDelegate.makeWorkspaceSelectionMenuItem(
            index: 2,
            target: AppDelegate()
        )

        #expect(
            !AppDelegate.validateStructuralMenuItem(
                closePane,
                coordinatorAvailable: true,
                canOpenConfig: true,
                canCreateTab: true,
                canClosePane: false,
                canCloseTab: false,
                canSplitPane: false,
                canNavigatePanes: false,
                activeTabCount: 2,
                workspaceCount: 1
            )
        )
        #expect(
            !AppDelegate.validateStructuralMenuItem(
                split,
                coordinatorAvailable: true,
                canOpenConfig: true,
                canCreateTab: true,
                canClosePane: true,
                canCloseTab: true,
                canSplitPane: false,
                canNavigatePanes: true,
                activeTabCount: 2,
                workspaceCount: 1
            )
        )
        #expect(
            !AppDelegate.validateStructuralMenuItem(
                selectTab,
                coordinatorAvailable: true,
                canOpenConfig: true,
                canCreateTab: true,
                canClosePane: true,
                canCloseTab: true,
                canSplitPane: true,
                canNavigatePanes: true,
                activeTabCount: 2,
                workspaceCount: 1
            )
        )
        #expect(
            !AppDelegate.validateStructuralMenuItem(
                selectWorkspace,
                coordinatorAvailable: true,
                canOpenConfig: true,
                canCreateTab: true,
                canClosePane: true,
                canCloseTab: true,
                canSplitPane: true,
                canNavigatePanes: true,
                activeTabCount: 3,
                workspaceCount: 1
            )
        )
    }

    @Test
    func shortcutControllerAppliesActiveConfigurationToLateRegistration() throws {
        var configuration = ShortcutConfiguration.defaults
        let customChord = try ShortcutChord(parsing: "ctrl+shift+f20")
        configuration.assign(customChord, to: .newTab)
        let controller = ShortcutController(configuration: configuration)
        let item = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "x")
        item.keyEquivalentModifierMask = [.command, .numericPad]

        controller.register(item, for: .newTab)

        #expect(controller.menuItem(for: .newTab) === item)
        #expect(item.keyEquivalent == String(UnicodeScalar(NSF20FunctionKey)!))
        #expect(item.keyEquivalentModifierMask == [.control, .shift])
    }

    @Test
    func shortcutHotReloadUpdatesSameItemWithoutChangingRouteMetadata() throws {
        let controller = ShortcutController()
        let target = NewTabMenuActionTarget()
        let representedObject = NSNumber(value: 7)
        let item = NSMenuItem(
            title: "New Tab",
            action: #selector(NewTabMenuActionTarget.createNewTab),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = representedObject
        item.tag = 42
        controller.register(item, for: .newTab)
        var configuration = ShortcutConfiguration.defaults
        configuration.assign(try ShortcutChord(parsing: "opt+ctrl+n"), to: .newTab)

        controller.apply(configuration)

        #expect(controller.menuItem(for: .newTab) === item)
        #expect(item.keyEquivalent == "n")
        #expect(item.keyEquivalentModifierMask == [.option, .control])
        #expect(item.action == #selector(NewTabMenuActionTarget.createNewTab))
        #expect(item.target === target)
        #expect((item.representedObject as AnyObject?) === representedObject)
        #expect(item.tag == 42)
    }

    @Test
    func shortcutDisableAndConflictDisabledOwnerClearMenuEquivalent() throws {
        let controller = ShortcutController()
        let newTabItem = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: nil, keyEquivalent: "")
        controller.register(newTabItem, for: .newTab)
        controller.register(pasteItem, for: .paste)
        var configuration = ShortcutConfiguration.defaults

        configuration.disable(.newTab)
        controller.apply(configuration)
        #expect(newTabItem.keyEquivalent.isEmpty)
        #expect(newTabItem.keyEquivalentModifierMask.isEmpty)

        let newTabChord = try #require(ShortcutAction.newTab.defaultChord)
        configuration.assign(newTabChord, to: .newTab)
        configuration.assign(newTabChord, to: .paste)
        controller.apply(configuration)

        #expect(newTabItem.keyEquivalent.isEmpty)
        #expect(newTabItem.keyEquivalentModifierMask.isEmpty)
        #expect(pasteItem.keyEquivalent == "t")
        #expect(pasteItem.keyEquivalentModifierMask == [.command])
    }

    @Test
    func shortcutApplicationReplacesDeviceDependentFlagsWithExactModifiers() throws {
        let controller = ShortcutController()
        let item = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "")
        item.keyEquivalentModifierMask = [.capsLock, .numericPad, .command]
        controller.register(item, for: .newTab)
        var configuration = ShortcutConfiguration.defaults
        configuration.assign(
            try ShortcutChord(parsing: "cmd+opt+ctrl+shift+home"),
            to: .newTab
        )

        controller.apply(configuration)

        #expect(item.keyEquivalent == String(UnicodeScalar(NSHomeFunctionKey)!))
        #expect(item.keyEquivalentModifierMask == [.command, .option, .control, .shift])
        #expect(
            item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                == [.command, .option, .control, .shift]
        )
    }

    @Test
    func shortcutKeyConversionCoversPrintableAndSpecialKeys() {
        #expect(ShortcutController.keyEquivalent(for: .a) == "a")
        #expect(ShortcutController.keyEquivalent(for: .grave) == "`")
        #expect(ShortcutController.keyEquivalent(for: .leftBracket) == "[")
        #expect(
            ShortcutController.keyEquivalent(for: .left)
                == String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        #expect(
            ShortcutController.keyEquivalent(for: .f1) == String(UnicodeScalar(NSF1FunctionKey)!))
        #expect(
            ShortcutController.keyEquivalent(for: .f20) == String(UnicodeScalar(NSF20FunctionKey)!))
        #expect(ShortcutController.keyEquivalent(for: .delete) == "\u{8}")
        #expect(
            ShortcutController.keyEquivalent(for: .forwardDelete)
                == String(UnicodeScalar(NSDeleteFunctionKey)!)
        )
        #expect(
            ShortcutKey.allCases.allSatisfy { !ShortcutController.keyEquivalent(for: $0).isEmpty })
    }

    @Test
    func responderOnlyMenuItemNeverGetsConsumingEquivalent() throws {
        var configuration = ShortcutConfiguration.defaults
        configuration.assign(try ShortcutChord(parsing: "cmd+shift+c"), to: .copy)
        let controller = ShortcutController(configuration: configuration)
        let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "x")
        copyItem.keyEquivalentModifierMask = [.command]

        controller.register(copyItem, for: .copy)

        #expect(copyItem.keyEquivalent.isEmpty)
        #expect(copyItem.keyEquivalentModifierMask.isEmpty)
    }

    @Test
    func registeredInstallerReusesItemAndAppliesHotReloadWithoutDuplicates() throws {
        let target = NewTabMenuActionTarget()
        let controller = ShortcutController()
        let mainMenu = AppDelegate.installNewTabMenuItem(
            in: nil,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab),
            shortcutController: controller
        )
        let fileMenu = try #require(mainMenu.item(withTitle: "File")?.submenu)
        let initialItem = try #require(fileMenu.item(withTitle: "New Tab"))
        var configuration = ShortcutConfiguration.defaults
        configuration.assign(try ShortcutChord(parsing: "ctrl+n"), to: .newTab)

        controller.apply(configuration)
        AppDelegate.installNewTabMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab),
            shortcutController: controller
        )

        let reinstalledItem = try #require(fileMenu.item(withTitle: "New Tab"))
        #expect(reinstalledItem === initialItem)
        #expect(fileMenu.items.filter { $0.title == "New Tab" }.count == 1)
        #expect(reinstalledItem.keyEquivalent == "n")
        #expect(reinstalledItem.keyEquivalentModifierMask == [.control])
    }

    @Test
    func applicationShortcutItemsKeepNativePlacementAndIdentityAcrossInstallation() throws {
        let delegate = AppDelegate()
        let controller = ShortcutController()
        var mainMenu = AppDelegate.installOpenConfigurationMenuItem(
            in: nil,
            target: delegate,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installQuitMenuItem(
            in: mainMenu,
            target: NSApp,
            shortcutController: controller
        )
        mainMenu = AppDelegate.installPresentationMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        let applicationMenu = try #require(mainMenu.item(withTitle: "QuickTTY")?.submenu)
        let viewMenu = try #require(mainMenu.item(withTitle: "View")?.submenu)
        let openItem = try #require(applicationMenu.item(withTitle: "Open Configuration…"))
        let quitItem = try #require(applicationMenu.item(withTitle: "Quit QuickTTY"))
        let presentationItem = try #require(viewMenu.item(withTitle: "Toggle Presentation Mode"))

        AppDelegate.installOpenConfigurationMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )
        AppDelegate.installQuitMenuItem(
            in: mainMenu,
            target: NSApp,
            shortcutController: controller
        )
        AppDelegate.installPresentationMenuItem(
            in: mainMenu,
            target: delegate,
            shortcutController: controller
        )

        #expect(applicationMenu.items.filter { $0.title == "Open Configuration…" }.count == 1)
        #expect(applicationMenu.items.filter { $0.title == "Quit QuickTTY" }.count == 1)
        #expect(viewMenu.items.filter { $0.title == "Toggle Presentation Mode" }.count == 1)
        #expect(applicationMenu.item(withTitle: "Open Configuration…") === openItem)
        #expect(applicationMenu.item(withTitle: "Quit QuickTTY") === quitItem)
        #expect(viewMenu.item(withTitle: "Toggle Presentation Mode") === presentationItem)
        #expect(openItem.action == AppDelegate.openConfigurationMenuItemAction)
        #expect(quitItem.action == AppDelegate.quitMenuItemAction)
        #expect(presentationItem.action == AppDelegate.togglePresentationMenuItemAction)
    }

    @Test
    func indexedShortcutReloadKeepsIndependentItemsAndRepresentedIndices() throws {
        let target = TabSelectionMenuActionTarget()
        let controller = ShortcutController()
        let mainMenu = AppDelegate.installTabSelectionMenuItems(
            in: nil,
            target: target,
            action: #selector(TabSelectionMenuActionTarget.activateTab(_:)),
            shortcutController: controller
        )
        let viewMenu = try #require(mainMenu.item(withTitle: "View")?.submenu)
        let firstItem = try #require(viewMenu.item(withTitle: "Select Tab 1"))
        let secondItem = try #require(viewMenu.item(withTitle: "Select Tab 2"))
        var configuration = ShortcutConfiguration.defaults
        configuration.disable(.selectTab1)
        configuration.assign(try ShortcutChord(parsing: "ctrl+f2"), to: .selectTab2)

        controller.apply(configuration)

        #expect(firstItem.keyEquivalent.isEmpty)
        #expect(firstItem.keyEquivalentModifierMask.isEmpty)
        #expect(secondItem.keyEquivalent == String(UnicodeScalar(NSF2FunctionKey)!))
        #expect(secondItem.keyEquivalentModifierMask == [.control])
        #expect((firstItem.representedObject as? NSNumber)?.intValue == 1)
        #expect((secondItem.representedObject as? NSNumber)?.intValue == 2)
        #expect(controller.menuItem(for: .selectTab1) === firstItem)
        #expect(controller.menuItem(for: .selectTab2) === secondItem)
    }

    @Test
    func terminalMenuUsesResponderChainAndLeavesConditionalCopyNonConsuming() throws {
        var configuration = ShortcutConfiguration.defaults
        configuration.assign(try ShortcutChord(parsing: "cmd+shift+c"), to: .copy)
        configuration.assign(try ShortcutChord(parsing: "ctrl+v"), to: .paste)
        let controller = ShortcutController(configuration: configuration)
        let mainMenu = AppDelegate.installTerminalMenuItems(
            in: nil,
            shortcutController: controller
        )
        AppDelegate.installTerminalMenuItems(
            in: mainMenu,
            shortcutController: controller
        )
        let editMenu = try #require(mainMenu.item(withTitle: "Edit")?.submenu)
        let copyItem = try #require(editMenu.item(withTitle: "Copy"))
        let pasteItem = try #require(editMenu.item(withTitle: "Paste"))
        let selectAllItem = try #require(editMenu.item(withTitle: "Select All"))

        #expect(editMenu.items.filter { $0.title == "Copy" }.count == 1)
        #expect(editMenu.items.filter { $0.title == "Paste" }.count == 1)
        #expect(editMenu.items.filter { $0.title == "Select All" }.count == 1)
        #expect(copyItem.action == AppDelegate.copyMenuItemAction)
        #expect(copyItem.keyEquivalent.isEmpty)
        #expect(copyItem.keyEquivalentModifierMask.isEmpty)
        #expect(pasteItem.action == AppDelegate.pasteMenuItemAction)
        #expect(pasteItem.keyEquivalent == "v")
        #expect(pasteItem.keyEquivalentModifierMask == [.control])
        #expect(selectAllItem.action == AppDelegate.selectAllMenuItemAction)
        #expect(copyItem.target == nil)
        #expect(pasteItem.target == nil)
        #expect(selectAllItem.target == nil)
    }
}

@MainActor
private func menuShortcutEvent(
    key: String,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        )
    )
}
