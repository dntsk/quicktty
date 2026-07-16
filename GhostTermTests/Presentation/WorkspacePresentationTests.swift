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
    func tabBarCollectionFillsRootWidthWithoutScrollView() {
        let tabBar = TabBarViewController()
        tabBar.view.frame = NSRect(x: 0, y: 0, width: 500, height: 34)
        tabBar.view.layoutSubtreeIfNeeded()

        let collectionViews = tabBar.view.subviews.compactMap { $0 as? NSCollectionView }

        #expect(collectionViews.count == 1)
        #expect(collectionViews[0].frame.minX == tabBar.view.bounds.minX)
        #expect(collectionViews[0].frame.maxX == tabBar.view.bounds.maxX)
        #expect(!(collectionViews[0].superview is NSScrollView))
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
