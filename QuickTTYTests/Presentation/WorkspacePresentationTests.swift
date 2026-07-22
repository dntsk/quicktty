import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct WorkspacePresentationTests {
    @Test
    func chromePaletteClassifiesDarkAndLightBackgrounds() {
        #expect(
            GhosttyChromePalette(
                background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
                foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
            ).usesDarkAppearance
        )
        #expect(
            !GhosttyChromePalette(
                background: GhosttyRGB(red: 0xEE, green: 0xEE, blue: 0xEE),
                foreground: GhosttyRGB(red: 0x11, green: 0x11, blue: 0x11)
            ).usesDarkAppearance
        )
    }

    @Test
    func workspaceSelectorUsesStandaloneMenuAndKeepsActiveWorkspaceUntilApply() throws {
        var store = WorkspaceStore()
        let testID = try store.createWorkspace(named: "Test")
        try store.activateWorkspace(testID)
        let selector = WorkspaceSelector()
        var selectedWorkspaceIDs: [WorkspaceID] = []
        selector.onSelection = { selectedWorkspaceIDs.append($0) }

        selector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )

        let items = selector.menuItemsForTesting
        #expect(selector.displayedWorkspaceNames == ["Default", "Test"])
        #expect(selector.buttonTitleForTesting == "Test")
        #expect(selector.selectedWorkspaceID == testID)
        #expect(
            items.map(\.title) == [
                "Default", "Test", "", "New Workspace…", "Rename Workspace…", "Delete Workspace…",
            ])
        #expect(items[0].target === selector)
        #expect(items[1].target === selector)
        #expect(items[3].target === selector)
        #expect(items[4].target === selector)
        #expect(items[5].target === selector)
        #expect(items[0].action == WorkspaceSelector.workspaceMenuItemAction)
        #expect(items[1].action == WorkspaceSelector.workspaceMenuItemAction)
        #expect(items[3].action == WorkspaceSelector.workspaceManagementMenuItemAction)
        #expect(items[4].action == WorkspaceSelector.workspaceManagementMenuItemAction)
        #expect(items[5].action == WorkspaceSelector.workspaceManagementMenuItemAction)
        #expect(items[0].state == .off)
        #expect(items[1].state == .on)
        #expect(items[0].keyEquivalent == "1")
        #expect(items[0].keyEquivalentModifierMask == [.command, .option])
        #expect(items[1].keyEquivalent == "2")
        #expect(items[1].keyEquivalentModifierMask == [.command, .option])
        #expect(selector.allRealItemsHaveExplicitTargetAndActionForTesting)

        let defaultID = store.workspaces[0].id
        selector.performWorkspaceSelectionForTesting(defaultID)

        #expect(selectedWorkspaceIDs == [defaultID])
        #expect(selector.selectedWorkspaceID == testID)
        #expect(selector.buttonTitleForTesting == "Test")

        selector.apply(workspaces: store.workspaces, activeWorkspaceID: defaultID)
        #expect(selector.selectedWorkspaceID == defaultID)
        #expect(selector.buttonTitleForTesting == "Default")
        #expect(selector.menuItemsForTesting[0].state == .on)
    }

    @Test
    func workspaceSelectorDispatchesManagementActionsOnceAndDoesNotDispatchDisabledDelete() throws {
        var store = WorkspaceStore()
        let testID = try store.createWorkspace(named: "Test")
        try store.activateWorkspace(testID)
        let selector = WorkspaceSelector()
        var requestedActions: [WorkspaceSelector.Action] = []
        var selectedWorkspaceIDsDuringAction: [WorkspaceID?] = []
        selector.onCreateWorkspace = {
            requestedActions.append(.new)
            selectedWorkspaceIDsDuringAction.append(selector.selectedWorkspaceID)
        }
        selector.onRenameWorkspace = {
            requestedActions.append(.rename)
            selectedWorkspaceIDsDuringAction.append(selector.selectedWorkspaceID)
        }
        selector.onDeleteWorkspace = {
            requestedActions.append(.delete)
            selectedWorkspaceIDsDuringAction.append(selector.selectedWorkspaceID)
        }

        selector.apply(workspaces: store.workspaces, activeWorkspaceID: testID)
        selector.triggerActionForTesting(.new)
        selector.triggerActionForTesting(.rename)
        selector.triggerActionForTesting(.delete)

        #expect(requestedActions == [.new, .rename, .delete])
        #expect(selectedWorkspaceIDsDuringAction == [testID, testID, testID])
        #expect(selector.selectedWorkspaceID == testID)
        #expect(selector.buttonTitleForTesting == "Test")

        selector.apply(workspaces: [store.workspaces[0]], activeWorkspaceID: store.workspaces[0].id)
        requestedActions = []
        selector.triggerActionForTesting(.delete)
        #expect(selector.selectedWorkspaceID == store.workspaces[0].id)
        #expect(requestedActions.isEmpty)
        #expect(!selector.menuItemsForTesting.last!.isEnabled)
    }

    @Test
    func workspaceSelectorIsLaidOutAndHitTestableInsideWindow() throws {
        let controller = WorkspaceViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        let controllerView = controller.view
        controllerView.frame = contentView.bounds
        controllerView.autoresizingMask = [.width, .height]
        contentView.addSubview(controllerView)
        controller.apply(WorkspaceStore())
        contentView.layoutSubtreeIfNeeded()
        controllerView.layoutSubtreeIfNeeded()

        let selector = controller.workspaceSelector
        let button = selector.buttonForTesting
        let frameView = try #require(contentView.superview)
        let hitPoint = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: frameView
        )
        let hitView = contentView.hitTest(hitPoint)

        #expect(selector.frame.height > 0)
        #expect(selector.bounds.height > 0)
        #expect(button.frame.height > 0)
        #expect(selector.bounds.contains(button.frame))
        #expect(hitView === button || hitView?.isDescendant(of: button) == true)
    }

    @Test
    func workspaceSelectorButtonActionUsesItsOwnedMenuThroughTestPresenter() {
        let selector = WorkspaceSelector()
        var presentedMenu: NSMenu?
        var presentedButton: NSButton?
        selector.menuPresenterForTesting = { menu, button in
            presentedMenu = menu
            presentedButton = button
            menu.delegate?.menuDidClose?(menu)
        }

        selector.performButtonActionForTesting()

        #expect(presentedMenu === selector.menuForTesting)
        #expect(presentedButton === selector.buttonForTesting)
    }

    @Test
    func workspaceSelectorKeepsMenuTrackingUntilMenuDelegateClosesAndDispatchesAction() throws {
        let store = WorkspaceStore()
        let selectedID = store.activeWorkspaceID
        let selector = WorkspaceSelector()
        var trackingStates: [Bool] = []
        var trackingStatesDuringSelection: [Bool] = []
        var selectedWorkspaceIDs: [WorkspaceID] = []
        selector.onMenuTrackingChanged = { trackingStates.append($0) }
        selector.onSelection = {
            selectedWorkspaceIDs.append($0)
            trackingStatesDuringSelection = trackingStates
        }
        selector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )
        selector.menuPresenterForTesting = { menu, _ in
            menu.delegate?.menuWillOpen?(menu)
            #expect(trackingStates == [true])
            guard let item = menu.items.first(where: { !$0.isSeparatorItem }),
                let action = item.action
            else { return }
            NSApp.sendAction(action, to: item.target, from: item)
            #expect(trackingStates == [true])
        }

        selector.performButtonActionForTesting()
        #expect(trackingStates == [true])
        selector.menuForTesting.delegate?.menuDidClose?(selector.menuForTesting)

        #expect(trackingStates == [true, false])
        #expect(trackingStatesDuringSelection == [true])
        #expect(selectedWorkspaceIDs == [selectedID])
    }

    @Test
    func workspaceViewControllerForwardsWorkspaceSelectorActions() {
        let controller = WorkspaceViewController()
        var actions: [String] = []
        var trackingStates: [Bool] = []
        controller.onCreateWorkspace = { actions.append("create") }
        controller.onRenameWorkspace = { actions.append("rename") }
        controller.onDeleteWorkspace = { actions.append("delete") }
        controller.onWorkspaceMenuTrackingChanged = { trackingStates.append($0) }
        var store = WorkspaceStore()
        _ = try? store.createWorkspace(named: "Backend")
        controller.apply(store)

        controller.workspaceSelector.triggerActionForTesting(.new)
        controller.workspaceSelector.triggerActionForTesting(.rename)
        controller.workspaceSelector.triggerActionForTesting(.delete)
        controller.workspaceSelector.onMenuTrackingChanged?(true)
        controller.workspaceSelector.onMenuTrackingChanged?(false)

        #expect(actions == ["create", "rename", "delete"])
        #expect(trackingStates == [true, false])
    }

    @Test
    func workspaceNameEditorConfiguresRenameAndLeavesAnUnchangedNameAsASuccessfulNoOp() {
        var submittedNames: [String] = []
        let controller = CreateWorkspaceController(
            title: "Rename Workspace",
            initialName: "Backend",
            buttonTitle: "Rename",
            errorMessage: "The workspace could not be renamed.",
            existingNames: { ["Default"] },
            submit: { name in
                submittedNames.append(name)
                return .success(())
            }
        )

        controller.submitForTesting(name: "Backend")

        #expect(controller.window?.title == "Rename Workspace")
        #expect(controller.nameForTesting == "Backend")
        #expect(controller.submitButtonTitleForTesting == "Rename")
        #expect(submittedNames == ["Backend"])
        #expect(controller.errorMessageForTesting.isEmpty)
    }

    @Test
    func workspaceNameValidationTrimsAndRejectsCaseInsensitiveDuplicates() throws {
        let trimmed = try WorkspaceNameValidator.validate(
            "  Backend\n",
            existingNames: ["Default"]
        )
        #expect(trimmed == "Backend")

        #expect(throws: WorkspaceNameValidator.ValidationError.empty) {
            try WorkspaceNameValidator.validate(" \n", existingNames: ["Default"])
        }
        #expect(throws: WorkspaceNameValidator.ValidationError.duplicate) {
            try WorkspaceNameValidator.validate(" default ", existingNames: ["Default"])
        }
    }

    @Test
    func workspaceControllerHostsSplitTreeDirectlyBelowChromeWithoutSeparator() throws {
        let controller = WorkspaceViewController()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(
            root: .pane(PaneID()),
            surfaces: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )

        let terminalContent = try #require(
            controller.view.subviews.first { $0.identifier?.rawValue == "terminal-content" })
        let chrome = try #require(controller.view.subviews.first)
        let terminalIsAdjacentToChrome = controller.view.constraints.contains { constraint in
            guard
                let firstItem = constraint.firstItem as? NSView,
                let secondItem = constraint.secondItem as? NSView
            else { return false }
            return firstItem === terminalContent
                && constraint.firstAttribute == .top
                && secondItem === chrome
                && constraint.secondAttribute == .bottom
                && constraint.constant == 0
        }

        #expect(controller.workspaceSelector.displayedWorkspaceNames == ["Default"])
        #expect(controller.splitHostingControllerIdentifierForTesting != nil)
        #expect(controller.view.subviews.count == 2)
        #expect(terminalIsAdjacentToChrome)
    }

    @Test
    func workspaceChromeAndTerminalFallbackUsePaletteAndLocalAppearance() {
        let palette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
            foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
        )
        let controller = WorkspaceViewController()

        controller.applyChromePalette(palette)

        #expect(controller.chromePaletteForTesting == palette)
        #expect(controller.chromeAppearanceNameForTesting == .darkAqua)
        #expect(
            controller.chromeBackgroundColorForTesting == NSColor(ghosttyRGB: palette.background))
        #expect(
            controller.terminalFallbackColorForTesting == NSColor(ghosttyRGB: palette.background))
    }

    @Test
    func configurationDiagnosticPaletteMatchesDarkAndLightChrome() throws {
        let darkPalette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
            foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
        )
        let lightPalette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0xEE, green: 0xEE, blue: 0xEE),
            foreground: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33)
        )
        let controller = WorkspaceViewController()

        controller.applyChromePalette(darkPalette)
        let darkAppearance = controller.configurationDiagnosticAppearanceNameForTesting
        let darkForeground = try #require(
            controller.configurationDiagnosticForegroundRGBAForTesting)
        let darkBackground = try #require(
            controller.configurationDiagnosticBackgroundRGBAForTesting)

        controller.applyChromePalette(lightPalette)
        let lightAppearance = controller.configurationDiagnosticAppearanceNameForTesting
        let lightForeground = try #require(
            controller.configurationDiagnosticForegroundRGBAForTesting)
        let lightBackground = try #require(
            controller.configurationDiagnosticBackgroundRGBAForTesting)

        #expect(darkAppearance == .darkAqua)
        #expect(lightAppearance == .aqua)
        #expect(darkAppearance != lightAppearance)
        #expect(darkForeground == Self.normalizedRGBA(darkPalette.foreground, alpha: 1))
        #expect(darkBackground == Self.normalizedRGBA(darkPalette.foreground, alpha: 0.2))
        #expect(lightForeground == Self.normalizedRGBA(lightPalette.foreground, alpha: 1))
        #expect(lightBackground == Self.normalizedRGBA(lightPalette.foreground, alpha: 0.2))
        #expect(darkForeground != lightForeground)
        #expect(darkBackground != lightBackground)
    }

    @Test
    func configurationDiagnosticsStayHiddenWithoutMessages() {
        let controller = WorkspaceViewController()

        controller.applyConfigurationDiagnostics(nil)
        #expect(!controller.configurationDiagnosticIsVisibleForTesting)

        controller.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(path: "/tmp/quicktty/config", messages: [])
        )
        #expect(!controller.configurationDiagnosticIsVisibleForTesting)
    }

    @Test
    func configurationDiagnosticsDisplayPathAndMessages() {
        let controller = WorkspaceViewController()

        controller.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(
                path: "/tmp/quicktty/config",
                messages: ["line 4: invalid quake height", "line 9: unknown option"]
            )
        )

        #expect(controller.configurationDiagnosticIsVisibleForTesting)
        #expect(
            controller.configurationDiagnosticTextForTesting
                == "/tmp/quicktty/config\nline 4: invalid quake height\nline 9: unknown option"
        )
    }

    @Test
    func configurationDiagnosticsCapMessagesAndShowRemainingCount() {
        let controller = WorkspaceViewController()
        let messages = (1...10).map { "line \($0): invalid option" }

        controller.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(path: "/tmp/quicktty/config", messages: messages)
        )

        let text = controller.configurationDiagnosticTextForTesting
        #expect(text.contains("line 1: invalid option"))
        #expect(text.contains("line 8: invalid option"))
        #expect(!text.contains("line 9: invalid option"))
        #expect(!text.contains("line 10: invalid option"))
        #expect(text.contains("… and 2 more"))
    }

    @Test
    func configurationDiagnosticsBoundVisualOutputAndNormalizeMultilineMessages() throws {
        let controller = WorkspaceViewController()
        let window = Self.mountWorkspace(controller, size: NSSize(width: 180, height: 100))
        defer { window.orderOut(nil) }
        let messages = (1...10).map { index in
            "line \(index): first\nsecond\r\nthird\rfourth "
                + String(repeating: "very long diagnostic detail ", count: 120)
        }

        controller.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(path: "/tmp/quicktty/config", messages: messages)
        )
        Self.layoutWorkspace(controller, in: window)

        let diagnosticView = try #require(
            controller.configurationDiagnosticViewForTesting as? ConfigDiagnosticView)
        let text = controller.configurationDiagnosticTextForTesting

        #expect(diagnosticView.maximumNumberOfLinesForTesting == 10)
        #expect(text.components(separatedBy: "\n").count == 10)
        #expect(!text.contains("\r"))
        #expect(text.contains("line 1: first second third fourth"))
        #expect(diagnosticView.frame.height <= diagnosticView.maximumHeightForTesting)
    }

    @Test
    func configurationDiagnosticsAnnounceOnlyChangedNonemptyPresentation() throws {
        let controller = WorkspaceViewController()
        let diagnosticView = try #require(
            controller.configurationDiagnosticViewForTesting as? ConfigDiagnosticView)
        let presentation = ConfigDiagnosticPresentation(
            path: "/tmp/quicktty/config",
            messages: ["line 4: invalid quake height"]
        )
        let changedPresentation = ConfigDiagnosticPresentation(
            path: "/tmp/quicktty/config",
            messages: ["line 9: unknown option"]
        )
        var announcements: [String] = []
        diagnosticView.announcementObserverForTesting = { announcements.append($0) }

        controller.applyConfigurationDiagnostics(nil)
        controller.applyConfigurationDiagnostics(presentation)
        controller.applyConfigurationDiagnostics(presentation)
        controller.applyConfigurationDiagnostics(nil)
        controller.applyConfigurationDiagnostics(nil)
        controller.applyConfigurationDiagnostics(presentation)
        controller.applyConfigurationDiagnostics(changedPresentation)
        controller.applyConfigurationDiagnostics(changedPresentation)

        #expect(announcements.count == 3)
        #expect(announcements.allSatisfy { $0 == "Configuration diagnostics available" })
        #expect(diagnosticView.isAccessibilityElement())
        #expect(diagnosticView.accessibilityRole() == .group)
        #expect(diagnosticView.accessibilityLabel() == "Configuration diagnostics")
        #expect(
            diagnosticView.accessibilityValue() as? String
                == "/tmp/quicktty/config\nline 9: unknown option"
        )
    }

    @Test
    func configurationDiagnosticsPreserveMountedSplitSurfacesAndPassThroughHits() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let controller = WorkspaceViewController()
        let window = Self.mountWorkspace(controller)
        defer { window.orderOut(nil) }
        let firstSurface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let secondSurface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let splitRoot = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .pane(firstSurface.paneID),
            second: .pane(secondSurface.paneID)
        )

        controller.displayTerminal(
            root: splitRoot,
            surfaces: [
                firstSurface.paneID: firstSurface,
                secondSurface.paneID: secondSurface,
            ],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        Self.layoutWorkspace(controller, in: window)
        await Task.yield()
        Self.layoutWorkspace(controller, in: window)
        #expect(window.makeFirstResponder(secondSurface))

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let splitHostIdentifier = ObjectIdentifier(splitHost)
        let splitHostFrame = splitHost.frame
        let splitHostConstraintIdentifiers = controller.splitHostingConstraintIdentifiersForTesting
        let hostedSurfaceIdentifiers = controller.hostedSurfaceIdentifiersForTesting
        let renderedSurfaceIdentifiers = controller.renderedSurfaceIdentifiersForTesting
        let firstResponder = try #require(window.firstResponder)
        let diagnosticView = controller.configurationDiagnosticViewForTesting
        let subviewIdentifiers = controller.terminalContentSubviewIdentifiersForTesting
        let diagnosticIndex = try #require(
            subviewIdentifiers.firstIndex(of: ObjectIdentifier(diagnosticView)))
        let splitHostIndex = try #require(
            subviewIdentifiers.firstIndex(of: splitHostIdentifier))

        #expect(splitHostFrame.width > 0)
        #expect(splitHostFrame.height > 0)
        #expect(diagnosticIndex > splitHostIndex)
        #expect(
            hostedSurfaceIdentifiers
                == [
                    firstSurface.paneID: ObjectIdentifier(firstSurface),
                    secondSurface.paneID: ObjectIdentifier(secondSurface),
                ])
        #expect(
            Set(renderedSurfaceIdentifiers)
                == Set([ObjectIdentifier(firstSurface), ObjectIdentifier(secondSurface)]))
        #expect(firstResponder === secondSurface)

        controller.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(
                path: "/tmp/quicktty/config",
                messages: ["line 4: invalid quake height"]
            )
        )
        Self.layoutWorkspace(controller, in: window)

        let overlayPoint = diagnosticView.convert(
            NSPoint(x: diagnosticView.bounds.midX, y: diagnosticView.bounds.midY),
            to: controller.view
        )
        let hitView = controller.view.hitTest(overlayPoint)

        #expect(controller.configurationDiagnosticIsVisibleForTesting)
        #expect(diagnosticView.frame.height > 0)
        #expect(hitView !== diagnosticView)
        #expect(hitView?.isDescendant(of: diagnosticView) != true)
        #expect(hitView === splitHost || hitView?.isDescendant(of: splitHost) == true)
        #expect(
            ObjectIdentifier(try #require(controller.splitHostingViewForTesting))
                == splitHostIdentifier)
        #expect(try #require(controller.splitHostingViewForTesting).frame == splitHostFrame)
        #expect(
            controller.splitHostingConstraintIdentifiersForTesting == splitHostConstraintIdentifiers
        )
        #expect(controller.splitHostingConstraintsAreActiveForTesting)
        #expect(controller.hostedSurfaceIdentifiersForTesting == hostedSurfaceIdentifiers)
        #expect(controller.renderedSurfaceIdentifiersForTesting == renderedSurfaceIdentifiers)
        #expect(window.firstResponder === firstResponder)

        controller.applyConfigurationDiagnostics(nil)
        Self.layoutWorkspace(controller, in: window)

        #expect(!controller.configurationDiagnosticIsVisibleForTesting)
        #expect(
            ObjectIdentifier(try #require(controller.splitHostingViewForTesting))
                == splitHostIdentifier)
        #expect(try #require(controller.splitHostingViewForTesting).frame == splitHostFrame)
        #expect(
            controller.splitHostingConstraintIdentifiersForTesting == splitHostConstraintIdentifiers
        )
        #expect(controller.splitHostingConstraintsAreActiveForTesting)
        #expect(controller.hostedSurfaceIdentifiersForTesting == hostedSurfaceIdentifiers)
        #expect(controller.renderedSurfaceIdentifiersForTesting == renderedSurfaceIdentifiers)
        #expect(window.firstResponder === firstResponder)
    }

    @Test
    func tabBarHasNoNewTabControl() {
        let workspaceController = WorkspaceViewController()
        workspaceController.apply(WorkspaceStore())

        #expect(
            !containsNewTabControl(in: workspaceController.tabBarViewController.view)
        )
    }

    @Test(arguments: [1, 2, 5, 24])
    func equalTabWidthsFillAvailableWidthWithoutOverflow(tabCount: Int) {
        let availableWidth: CGFloat = 500
        let metrics = TabBarEqualWidthLayout.metrics(
            availableWidth: availableWidth,
            tabCount: tabCount
        )

        #expect(metrics.itemWidth >= 0)
        #expect(metrics.occupiedWidth == availableWidth)
    }

    @Test
    func equalTabWidthsShrinkAsTabCountIncreasesWithoutMinimumWidth() {
        let oneTab = TabBarEqualWidthLayout.metrics(availableWidth: 500, tabCount: 1)
        let fiveTabs = TabBarEqualWidthLayout.metrics(availableWidth: 500, tabCount: 5)
        let manyTabs = TabBarEqualWidthLayout.metrics(availableWidth: 500, tabCount: 200)

        #expect(oneTab.itemWidth > fiveTabs.itemWidth)
        #expect(fiveTabs.itemWidth > manyTabs.itemWidth)
        #expect(manyTabs.itemWidth < 10)
    }

    @Test
    func tabPresentationKeepsShortcutRightAndHoverCloseLeft() {
        let idle = TabItemView.displayState(
            tabIndex: 0,
            isActive: false,
            isSelected: false,
            isHovered: false,
            isBroadcasting: false
        )
        let hoveredBroadcasting = TabItemView.displayState(
            tabIndex: 0,
            isActive: true,
            isSelected: false,
            isHovered: true,
            isBroadcasting: true
        )
        let afterNinthTab = TabItemView.displayState(
            tabIndex: 9,
            isActive: false,
            isSelected: false,
            isHovered: false,
            isBroadcasting: false
        )

        #expect(idle.backgroundStyle == .transparent)
        #expect(idle.shortcut == "⌘1")
        #expect(!idle.showsCloseButton)
        #expect(hoveredBroadcasting.backgroundStyle == .activeCapsule)
        #expect(hoveredBroadcasting.showsCloseButton)
        #expect(!hoveredBroadcasting.showsBroadcastIndicator)
        #expect(hoveredBroadcasting.shortcut == "⌘1")
        #expect(afterNinthTab.shortcut == nil)
    }

    @Test
    func compactTabChromeUsesExactHeights() {
        #expect(WorkspaceViewController.chromeHeight == 28)
        #expect(TabBarViewController.itemHeight == 28)
    }

    @Test
    func tabBarCollectionFillsRootWidthWithoutScrollView() throws {
        let tabBar = TabBarViewController()
        tabBar.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 500,
            height: TabBarViewController.itemHeight
        )
        tabBar.view.layoutSubtreeIfNeeded()

        let collectionViews = tabBar.view.subviews.compactMap { $0 as? NSCollectionView }

        #expect(collectionViews.count == 1)
        #expect(collectionViews[0].frame.minX == tabBar.view.bounds.minX)
        #expect(collectionViews[0].frame.maxX == tabBar.view.bounds.maxX)
        #expect(collectionViews[0].frame.minY == tabBar.view.bounds.minY)
        #expect(collectionViews[0].frame.maxY == tabBar.view.bounds.maxY)
        #expect(!(collectionViews[0].superview is NSScrollView))

        let layout = try #require(
            collectionViews[0].collectionViewLayout as? NSCollectionViewFlowLayout)
        #expect(layout.sectionInset.top == 0)
        #expect(layout.sectionInset.bottom == 0)
    }

    @Test
    func tabBarOnlyValidatesCurrentLocalTabDragsBeforeItems() throws {
        let tabs = [
            TerminalTab(
                title: "One",
                pane: TerminalPaneDescriptor(id: PaneID(), cwd: "/tmp")
            ),
            TerminalTab(
                title: "Two",
                pane: TerminalPaneDescriptor(id: PaneID(), cwd: "/tmp")
            ),
        ]
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[0].id, destinations: [])
        let collectionView = try #require(tabBar.view.subviews.first as? NSCollectionView)

        var proposedIndexPath = NSIndexPath(forItem: 1, inSection: 0)
        var dropOperation = NSCollectionView.DropOperation.on
        let validDrag = TabDraggingInfo(
            source: collectionView,
            payload: tabs[0].id.rawValue.uuidString
        )
        #expect(
            tabBar.collectionView(
                collectionView,
                validateDrop: validDrag,
                proposedIndexPath: &proposedIndexPath,
                dropOperation: &dropOperation
            ) == .move
        )
        #expect(dropOperation == .before)

        for invalidDrag in [
            TabDraggingInfo(source: nil, payload: tabs[0].id.rawValue.uuidString),
            TabDraggingInfo(source: collectionView, payload: TabID().rawValue.uuidString),
            TabDraggingInfo(source: collectionView, payload: "not-a-tab-id"),
        ] {
            #expect(
                tabBar.collectionView(
                    collectionView,
                    validateDrop: invalidDrag,
                    proposedIndexPath: &proposedIndexPath,
                    dropOperation: &dropOperation
                ) == []
            )
        }
    }

    @Test
    func tabBarKeepsMountedItemAndNativeSelectionDuringBeginMouseDown() throws {
        let tabs = Self.makeTabs(count: 3)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        let collectionView = tabBar.collectionViewForTesting
        let item = tabBar.tabItemForTesting(at: 2)
        let background = item.backgroundViewForTesting
        let forwardingResponder = MouseDownForwardingResponder()
        let originalNextResponder = background.nextResponder
        defer { background.nextResponder = originalNextResponder }
        background.nextResponder = forwardingResponder
        let reloadGeneration = tabBar.dataReloadGenerationForTesting
        var selectedIDsWhileForwarded: [TabID] = []
        var nativeSelectionWhileForwarded: Set<IndexPath> = []
        var reloadGenerationWhileForwarded: Int?
        var backgroundWindowWhileForwarded: NSWindow?
        var activatedTabIDs: [TabID] = []
        var activatedTabIDsWhileForwarded: [TabID] = []
        tabBar.onActivateTab = { tabID in
            activatedTabIDs.append(tabID)
            tabBar.apply(tabs: tabs, activeTabID: tabID, destinations: [])
        }
        forwardingResponder.onMouseDown = {
            selectedIDsWhileForwarded = tabBar.selectedTabIDsInOrderForTesting
            nativeSelectionWhileForwarded = collectionView.selectionIndexPaths
            reloadGenerationWhileForwarded = tabBar.dataReloadGenerationForTesting
            backgroundWindowWhileForwarded = background.window
            activatedTabIDsWhileForwarded = activatedTabIDs
        }

        background.mouseDown(with: try Self.mouseDownEvent())

        #expect(collectionView.isSelectable)
        #expect(collectionView.allowsMultipleSelection)
        #expect(forwardingResponder.mouseDownCount == 1)
        #expect(selectedIDsWhileForwarded == [tabs[2].id])
        #expect(nativeSelectionWhileForwarded == [IndexPath(item: 2, section: 0)])
        #expect(reloadGenerationWhileForwarded == reloadGeneration)
        #expect(backgroundWindowWhileForwarded === fixture.window)
        #expect(activatedTabIDsWhileForwarded.isEmpty)
        #expect(activatedTabIDs == [tabs[2].id])
        #expect(tabBar.dataReloadGenerationForTesting == reloadGeneration + 1)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[2].id])
        #expect(tabBar.activeTabIDForTesting == tabs[2].id)
    }

    @Test
    func tabBarCommandMouseDownSanitizesForwardedModifiersAfterCustomSelection() throws {
        let tabs = Self.makeTabs(count: 3)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        let collectionView = tabBar.collectionViewForTesting
        let background = tabBar.tabItemForTesting(at: 2).backgroundViewForTesting
        let forwardingResponder = MouseDownForwardingResponder()
        let originalNextResponder = background.nextResponder
        defer { background.nextResponder = originalNextResponder }
        background.nextResponder = forwardingResponder
        let reloadGeneration = tabBar.dataReloadGenerationForTesting
        var selectedIDsWhileForwarded: [TabID] = []
        var nativeSelectionWhileForwarded: Set<IndexPath> = []
        var activatedTabIDs: [TabID] = []
        var activatedTabIDsWhileForwarded: [TabID] = []
        tabBar.onActivateTab = { activatedTabIDs.append($0) }
        forwardingResponder.onMouseDown = {
            selectedIDsWhileForwarded = tabBar.selectedTabIDsInOrderForTesting
            nativeSelectionWhileForwarded = collectionView.selectionIndexPaths
            activatedTabIDsWhileForwarded = activatedTabIDs
        }

        background.mouseDown(with: try Self.mouseDownEvent(modifierFlags: [.command, .option]))

        #expect(forwardingResponder.mouseDownCount == 1)
        #expect(selectedIDsWhileForwarded == [tabs[0].id, tabs[2].id])
        #expect(
            nativeSelectionWhileForwarded == [
                IndexPath(item: 0, section: 0),
                IndexPath(item: 2, section: 0),
            ])
        #expect(forwardingResponder.lastMouseDownEvent?.modifierFlags == [.option])
        #expect(tabBar.dataReloadGenerationForTesting == reloadGeneration + 1)
        #expect(activatedTabIDsWhileForwarded.isEmpty)
        #expect(activatedTabIDs == [tabs[2].id])
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[0].id, tabs[2].id])
        #expect(tabBar.activeTabIDForTesting == tabs[2].id)
    }

    @Test
    func tabBarShiftMouseDownSanitizesForwardedModifiersAfterCustomSelection() throws {
        let tabs = Self.makeTabs(count: 3)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        let background = tabBar.tabItemForTesting(at: 2).backgroundViewForTesting
        let forwardingResponder = MouseDownForwardingResponder()
        let originalNextResponder = background.nextResponder
        defer { background.nextResponder = originalNextResponder }
        background.nextResponder = forwardingResponder
        var selectedIDsWhileForwarded: [TabID] = []
        forwardingResponder.onMouseDown = {
            selectedIDsWhileForwarded = tabBar.selectedTabIDsInOrderForTesting
        }

        background.mouseDown(with: try Self.mouseDownEvent(modifierFlags: [.shift, .option]))

        #expect(selectedIDsWhileForwarded == tabs.map(\.id))
        #expect(forwardingResponder.lastMouseDownEvent?.modifierFlags == [.option])
        #expect(tabBar.selectedTabIDsInOrderForTesting == tabs.map(\.id))
        #expect(tabBar.activeTabIDForTesting == tabs[2].id)
    }

    @Test
    func tabBarClearSelectionSynchronizesNativeIndexesAfterReload() {
        let tabs = Self.makeTabs(count: 3)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        let collectionView = tabBar.collectionViewForTesting

        tabBar.beginSelectionForTesting(tabs[2].id, gesture: .commandClick)
        tabBar.finishSelectionForTesting()
        tabBar.clearSelectionAfterMove()

        #expect(collectionView.selectionIndexPaths.isEmpty)
        #expect(tabBar.selectedTabIDsInOrderForTesting.isEmpty)
    }

    @Test
    func tabBarPlainMouseDownOnMultiSelectedTabCollapsesAfterForwardingWithoutDrag() throws {
        let tabs = Self.makeTabs(count: 5)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        Self.selectMultipleTabs([1, 3], in: tabBar, tabs: tabs)
        let background = tabBar.tabItemForTesting(at: 1).backgroundViewForTesting
        let forwardingResponder = MouseDownForwardingResponder()
        let originalNextResponder = background.nextResponder
        defer { background.nextResponder = originalNextResponder }
        background.nextResponder = forwardingResponder
        var selectedIDsWhileForwarded: [TabID] = []
        forwardingResponder.onMouseDown = {
            selectedIDsWhileForwarded = tabBar.selectedTabIDsInOrderForTesting
        }

        background.mouseDown(with: try Self.mouseDownEvent())

        #expect(forwardingResponder.mouseDownCount == 1)
        #expect(selectedIDsWhileForwarded == [tabs[0].id, tabs[1].id, tabs[3].id])
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[1].id])
        #expect(tabBar.activeTabIDForTesting == tabs[1].id)
    }

    @Test
    func tabBarPlainMouseDownOnMultiSelectedTabPreservesBlockWhenDragBeginsWhileForwarded() throws {
        let tabs = Self.makeTabs(count: 5)
        let fixture = Self.makeMountedTabBar(tabs: tabs, activeTabID: tabs[0].id)
        defer { fixture.window.orderOut(nil) }
        let tabBar = fixture.tabBar
        Self.selectMultipleTabs([1, 3], in: tabBar, tabs: tabs)
        let background = tabBar.tabItemForTesting(at: 1).backgroundViewForTesting
        let forwardingResponder = MouseDownForwardingResponder()
        let originalNextResponder = background.nextResponder
        defer { background.nextResponder = originalNextResponder }
        background.nextResponder = forwardingResponder
        forwardingResponder.onMouseDown = {
            tabBar.recordDragSessionStartForTesting()
        }

        background.mouseDown(with: try Self.mouseDownEvent())

        #expect(forwardingResponder.mouseDownCount == 1)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[0].id, tabs[1].id, tabs[3].id])
        #expect(tabBar.activeTabIDForTesting == tabs[3].id)
    }

    @Test
    func tabBarDragSessionDelegateAdvancesGeneration() {
        let tabBar = TabBarViewController()
        let collectionView = tabBar.collectionViewForTesting
        let generation = tabBar.dragSessionGenerationForTesting

        tabBar.collectionView(
            collectionView,
            draggingSession: NSDraggingSession(),
            willBeginAt: .zero,
            forItemsAt: []
        )

        #expect(tabBar.dragSessionGenerationForTesting == generation + 1)
    }

    @Test
    func tabBarRejectsDropWithoutCallbackAndRestoresSelection() {
        let tabs = Self.makeTabs(count: 3)
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[0].id, destinations: [])
        let collectionView = tabBar.collectionViewForTesting

        #expect(
            !tabBar.collectionView(
                collectionView,
                acceptDrop: TabDraggingInfo(
                    source: collectionView,
                    payload: tabs[2].id.rawValue.uuidString
                ),
                indexPath: IndexPath(item: 0, section: 0),
                dropOperation: .before
            )
        )
        #expect(tabBar.displayedTabsForTesting.map(\.id) == tabs.map(\.id))
        #expect(tabBar.orderedTabIDsForTesting == tabs.map(\.id))
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[0].id])
        #expect(tabBar.activeTabIDForTesting == tabs[0].id)
    }

    @Test
    func tabBarRejectsDropWhenCallbackRejectsAndRestoresSelection() {
        let tabs = Self.makeTabs(count: 3)
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[0].id, destinations: [])
        let collectionView = tabBar.collectionViewForTesting
        var proposedOrders: [[TabID]] = []
        tabBar.onReorderTabs = { orderedTabIDs, _ in
            proposedOrders.append(orderedTabIDs)
            return false
        }

        #expect(
            !tabBar.collectionView(
                collectionView,
                acceptDrop: TabDraggingInfo(
                    source: collectionView,
                    payload: tabs[2].id.rawValue.uuidString
                ),
                indexPath: IndexPath(item: 0, section: 0),
                dropOperation: .before
            )
        )
        #expect(proposedOrders == [[tabs[2].id, tabs[0].id, tabs[1].id]])
        #expect(tabBar.displayedTabsForTesting.map(\.id) == tabs.map(\.id))
        #expect(tabBar.orderedTabIDsForTesting == tabs.map(\.id))
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[0].id])
        #expect(tabBar.activeTabIDForTesting == tabs[0].id)
    }

    @Test
    func tabBarDefersAcceptedLocalSelectedBlockPresentationUntilDragSessionEnds() throws {
        let tabs = Self.makeTabs(count: 5)
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[0].id, destinations: [])
        let collectionView = tabBar.collectionViewForTesting
        Self.selectMultipleTabs([1, 3], in: tabBar, tabs: tabs)
        var reorderedOrders: [[TabID]] = []
        var reorderedActiveTabIDs: [TabID] = []
        var completionCount = 0
        tabBar.onReorderTabs = { orderedTabIDs, activeTabID in
            reorderedOrders.append(orderedTabIDs)
            reorderedActiveTabIDs.append(activeTabID)
            return true
        }
        tabBar.onFinishReorderTabs = { completionCount += 1 }
        let reloadGeneration = tabBar.dataReloadGenerationForTesting

        #expect(
            tabBar.collectionView(
                collectionView,
                acceptDrop: TabDraggingInfo(
                    source: collectionView,
                    payload: tabs[1].id.rawValue.uuidString
                ),
                indexPath: IndexPath(item: tabs.count, section: 0),
                dropOperation: .before
            )
        )

        let expectedOrder = [tabs[2].id, tabs[4].id, tabs[0].id, tabs[1].id, tabs[3].id]
        #expect(tabBar.displayedTabsForTesting.map(\.id) == tabs.map(\.id))
        #expect(tabBar.dataReloadGenerationForTesting == reloadGeneration)
        #expect(reorderedOrders == [expectedOrder])
        #expect(reorderedActiveTabIDs == [tabs[3].id])
        #expect(completionCount == 0)

        tabBar.collectionView(
            collectionView,
            draggingSession: NSDraggingSession(),
            endedAt: .zero,
            dragOperation: .move
        )

        #expect(tabBar.displayedTabsForTesting.map(\.id) == expectedOrder)
        #expect(tabBar.orderedTabIDsForTesting == expectedOrder)
        #expect(tabBar.dataReloadGenerationForTesting == reloadGeneration + 1)
        #expect(completionCount == 1)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[0].id, tabs[1].id, tabs[3].id])
        #expect(tabBar.activeTabIDForTesting == tabs[3].id)
    }

    @Test
    func tabBarSelectsDraggedInactiveTabAndFinalizesItsOrderAndActivationAfterDragSession() throws {
        let tabs = Self.makeTabs(count: 3)
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[0].id, destinations: [])
        let collectionView = tabBar.collectionViewForTesting
        var reorderedOrders: [[TabID]] = []
        var reorderedActiveTabIDs: [TabID] = []
        tabBar.onReorderTabs = { orderedTabIDs, activeTabID in
            reorderedOrders.append(orderedTabIDs)
            reorderedActiveTabIDs.append(activeTabID)
            return true
        }
        let expectedOrder = [tabs[2].id, tabs[0].id, tabs[1].id]
        var activatedTabIDs: [TabID] = []
        tabBar.onActivateTab = { activatedTabIDs.append($0) }

        #expect(
            tabBar.collectionView(
                collectionView,
                acceptDrop: TabDraggingInfo(
                    source: collectionView,
                    payload: tabs[2].id.rawValue.uuidString
                ),
                indexPath: IndexPath(item: 0, section: 0),
                dropOperation: .before
            )
        )
        #expect(tabBar.displayedTabsForTesting.map(\.id) == tabs.map(\.id))
        #expect(reorderedOrders == [expectedOrder])
        #expect(reorderedActiveTabIDs == [tabs[2].id])

        tabBar.collectionView(
            collectionView,
            draggingSession: NSDraggingSession(),
            endedAt: .zero,
            dragOperation: .move
        )

        #expect(tabBar.displayedTabsForTesting.map(\.id) == expectedOrder)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [tabs[2].id])
        #expect(tabBar.activeTabIDForTesting == tabs[2].id)

        tabBar.finishSelectionForTesting()

        #expect(activatedTabIDs.isEmpty)
    }

    @Test
    func tabBarRejectsInvalidDropsAndDoesNotNotifyForEffectiveNoOp() throws {
        let tabs = Self.makeTabs(count: 3)
        let tabBar = TabBarViewController()
        tabBar.apply(tabs: tabs, activeTabID: tabs[1].id, destinations: [])
        let collectionView = tabBar.collectionViewForTesting
        let validDrag = TabDraggingInfo(
            source: collectionView,
            payload: tabs[1].id.rawValue.uuidString
        )
        var reorderedOrders: [[TabID]] = []
        var completionCount = 0
        tabBar.onReorderTabs = { orderedTabIDs, _ in
            reorderedOrders.append(orderedTabIDs)
            return true
        }
        tabBar.onFinishReorderTabs = { completionCount += 1 }
        let reloadGeneration = tabBar.dataReloadGenerationForTesting

        for (indexPath, dropOperation) in [
            (IndexPath(item: 0, section: 1), NSCollectionView.DropOperation.before),
            (IndexPath(item: tabs.count + 1, section: 0), .before),
            (IndexPath(item: 1, section: 0), .on),
        ] {
            #expect(
                !tabBar.collectionView(
                    collectionView,
                    acceptDrop: validDrag,
                    indexPath: indexPath,
                    dropOperation: dropOperation
                )
            )
        }
        for invalidDrag in [
            TabDraggingInfo(source: nil, payload: tabs[1].id.rawValue.uuidString),
            TabDraggingInfo(source: collectionView, payload: TabID().rawValue.uuidString),
        ] {
            #expect(
                !tabBar.collectionView(
                    collectionView,
                    acceptDrop: invalidDrag,
                    indexPath: IndexPath(item: 0, section: 0),
                    dropOperation: .before
                )
            )
        }

        #expect(
            tabBar.collectionView(
                collectionView,
                acceptDrop: validDrag,
                indexPath: IndexPath(item: 2, section: 0),
                dropOperation: .before
            )
        )
        #expect(tabBar.displayedTabsForTesting.map(\.id) == tabs.map(\.id))
        #expect(reorderedOrders.isEmpty)

        tabBar.collectionView(
            collectionView,
            draggingSession: NSDraggingSession(),
            endedAt: .zero,
            dragOperation: []
        )

        #expect(tabBar.dataReloadGenerationForTesting == reloadGeneration)
        #expect(completionCount == 0)
    }

    private static func normalizedRGBA(_ color: GhosttyRGB, alpha: CGFloat) -> [CGFloat] {
        [
            CGFloat(color.red) / 255,
            CGFloat(color.green) / 255,
            CGFloat(color.blue) / 255,
            alpha,
        ]
    }

    private static func layoutWorkspace(_ controller: WorkspaceViewController, in window: NSWindow)
    {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    private static func mountWorkspace(
        _ controller: WorkspaceViewController,
        size: NSSize = NSSize(width: 800, height: 600)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        guard let contentView = window.contentView else {
            preconditionFailure("Expected test window content view")
        }
        let controllerView = controller.view
        controllerView.frame = contentView.bounds
        controllerView.autoresizingMask = [.width, .height]
        contentView.addSubview(controllerView)
        controller.apply(WorkspaceStore())
        contentView.layoutSubtreeIfNeeded()
        controllerView.layoutSubtreeIfNeeded()
        return window
    }

    @Test
    func tabDraggingUsesQuickTTYPasteboardType() {
        #expect(NSPasteboard.PasteboardType.quickTTYTab.rawValue == "com.dntsk.QuickTTY.tab")
    }

    private static func makeMountedTabBar(
        tabs: [TerminalTab],
        activeTabID: TabID
    ) -> (tabBar: TabBarViewController, window: NSWindow) {
        let tabBar = TabBarViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: TabBarViewController.itemHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        guard let contentView = window.contentView else {
            preconditionFailure("Expected test window content view")
        }
        let tabBarView = tabBar.view
        tabBarView.frame = contentView.bounds
        tabBarView.autoresizingMask = [.width, .height]
        contentView.addSubview(tabBarView)
        tabBar.apply(tabs: tabs, activeTabID: activeTabID, destinations: [])
        contentView.layoutSubtreeIfNeeded()
        tabBar.collectionViewForTesting.layoutSubtreeIfNeeded()
        return (tabBar, window)
    }

    private static func selectMultipleTabs(
        _ indexes: [Int],
        in tabBar: TabBarViewController,
        tabs: [TerminalTab]
    ) {
        for index in indexes {
            tabBar.beginSelectionForTesting(tabs[index].id, gesture: .commandClick)
            tabBar.finishSelectionForTesting()
        }
    }

    private static func mouseDownEvent(
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private static func makeTabs(count: Int) -> [TerminalTab] {
        (1...count).map { index in
            TerminalTab(
                title: "Tab \(index)",
                pane: TerminalPaneDescriptor(id: PaneID(), cwd: "/tmp")
            )
        }
    }

    private func containsNewTabControl(in view: NSView) -> Bool {
        if view.identifier?.rawValue == "new-tab-button"
            || (view as? NSButton)?.accessibilityLabel() == "New Tab"
        {
            return true
        }
        return view.subviews.contains { containsNewTabControl(in: $0) }
    }
}

@MainActor
private final class MouseDownForwardingResponder: NSResponder {
    private(set) var mouseDownCount = 0
    private(set) var lastMouseDownEvent: NSEvent?
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
        lastMouseDownEvent = event
        onMouseDown?()
    }
}

private final class TabDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    @MainActor
    init(source: AnyObject?, payload: String?) {
        draggingSource = source
        draggingPasteboard = NSPasteboard(
            name: NSPasteboard.Name("QuickTTYTests.TabDraggingInfo.\(UUID().uuidString)")
        )
        super.init()
        draggingPasteboard.clearContents()
        if let payload {
            draggingPasteboard.setString(payload, forType: .quickTTYTab)
        }
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
