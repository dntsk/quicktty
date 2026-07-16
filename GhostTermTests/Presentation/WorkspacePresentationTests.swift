import AppKit
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WorkspacePresentationTests {
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
    func workspaceControllerHostsTerminalBelowVisibleChrome() {
        let controller = WorkspaceViewController()
        let terminal = NSView()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(terminal)

        #expect(controller.workspaceSelector.displayedWorkspaceNames == ["Default"])
        #expect(terminal.superview?.identifier?.rawValue == "terminal-content")
        #expect(controller.view.subviews.count == 3)
    }

    @Test
    func newTabButtonIsAccessibleAndInvokesCallbackOnceWithoutTabs() {
        let controller = WorkspaceViewController()
        var newTabCount = 0
        controller.onNewTab = { newTabCount += 1 }

        controller.apply(WorkspaceStore())
        let button = controller.tabBarViewController.newTabButtonForTesting
        button.performClick(nil)

        #expect(button.identifier?.rawValue == "new-tab-button")
        #expect(button.accessibilityLabel() == "New Tab")
        #expect(button.toolTip == "New Tab (Command+T)")
        #expect(newTabCount == 1)
    }

    @Test
    func workspaceControllerForwardsNewTabAction() {
        let controller = WorkspaceViewController()
        var newTabCount = 0
        controller.onNewTab = { newTabCount += 1 }

        controller.apply(WorkspaceStore())
        controller.tabBarViewController.newTabButtonForTesting.performClick(nil)

        #expect(newTabCount == 1)
    }

    @Test(arguments: [1, 2, 5, 24])
    func equalTabWidthsFillAvailableWidthWithoutOverflow(tabCount: Int) {
        let availableWidth: CGFloat = 500
        let metrics = TabBarEqualWidthLayout.metrics(
            availableWidth: availableWidth,
            tabCount: tabCount
        )

        #expect(metrics.itemWidth >= 0)
        #expect(metrics.occupiedWidth <= availableWidth)
        #expect(
            metrics.itemWidth * CGFloat(tabCount) + metrics.spacing * CGFloat(tabCount - 1)
                + metrics.horizontalInset * 2 <= availableWidth)
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
    func tabBarHasNoScrollViewAndUsesCircularAccessibleNewTabButton() {
        let workspaceController = WorkspaceViewController()
        workspaceController.apply(WorkspaceStore())
        let controller = workspaceController.tabBarViewController
        let button = controller.newTabButtonForTesting

        #expect(!controller.usesScrollViewForTesting)
        #expect(button.accessibilityLabel() == "New Tab")
        #expect(button.toolTip == "New Tab (Command+T)")
        #expect(controller.newTabButtonIsCircularForTesting)
    }
}
