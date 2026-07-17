import AppKit
import Testing

@testable import GhostTerm

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
    func workspaceSelectorKeepsStoreOrderAndActiveSelection() throws {
        var store = WorkspaceStore()
        let backendID = try store.createWorkspace(named: "Backend")
        try store.activateWorkspace(backendID)
        let selector = WorkspaceSelector()

        selector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )

        #expect(selector.displayedWorkspaceNames == ["Default", "Backend"])
        #expect(selector.selectedWorkspaceID == backendID)
    }

    @Test
    func workspaceSelectorSeparatesActionsAndReselectsTheActiveWorkspace() throws {
        var store = WorkspaceStore()
        let backendID = try store.createWorkspace(named: "Backend")
        try store.activateWorkspace(backendID)
        let selector = WorkspaceSelector()
        var requestedActions: [WorkspaceSelector.Action] = []
        selector.onCreateWorkspace = { requestedActions.append(.new) }
        selector.onRenameWorkspace = { requestedActions.append(.rename) }
        selector.onDeleteWorkspace = { requestedActions.append(.delete) }

        selector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )

        #expect(selector.displayedWorkspaceNames == ["Default", "Backend"])
        #expect(
            selector.itemDescriptorsForTesting
                == [
                    .init(
                        title: "Default",
                        isSeparator: false,
                        action: nil,
                        isEnabled: true
                    ),
                    .init(
                        title: "Backend",
                        isSeparator: false,
                        action: nil,
                        isEnabled: true
                    ),
                    .init(
                        title: "",
                        isSeparator: true,
                        action: nil,
                        isEnabled: false
                    ),
                    .init(
                        title: "New Workspace…",
                        isSeparator: false,
                        action: .new,
                        isEnabled: true
                    ),
                    .init(
                        title: "Rename Workspace…",
                        isSeparator: false,
                        action: .rename,
                        isEnabled: true
                    ),
                    .init(
                        title: "Delete Workspace…",
                        isSeparator: false,
                        action: .delete,
                        isEnabled: true
                    ),
                ]
        )

        selector.triggerActionForTesting(.new)
        selector.triggerActionForTesting(.rename)
        selector.triggerActionForTesting(.delete)

        #expect(selector.selectedWorkspaceID == backendID)
        #expect(requestedActions == [.new, .rename, .delete])

        selector.apply(workspaces: [store.workspaces[0]], activeWorkspaceID: store.workspaces[0].id)
        #expect(
            selector.itemDescriptorsForTesting.last
                == .init(
                    title: "Delete Workspace…",
                    isSeparator: false,
                    action: .delete,
                    isEnabled: false
                )
        )
    }

    @Test
    func workspaceViewControllerForwardsWorkspaceSelectorActions() {
        let controller = WorkspaceViewController()
        var actions: [String] = []
        controller.onCreateWorkspace = { actions.append("create") }
        controller.onRenameWorkspace = { actions.append("rename") }
        controller.onDeleteWorkspace = { actions.append("delete") }
        controller.apply(WorkspaceStore())

        controller.workspaceSelector.triggerActionForTesting(.new)
        controller.workspaceSelector.triggerActionForTesting(.rename)
        controller.workspaceSelector.triggerActionForTesting(.delete)

        #expect(actions == ["create", "rename"])
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

    private func containsNewTabControl(in view: NSView) -> Bool {
        if view.identifier?.rawValue == "new-tab-button"
            || (view as? NSButton)?.accessibilityLabel() == "New Tab"
        {
            return true
        }
        return view.subviews.contains { containsNewTabControl(in: $0) }
    }
}
