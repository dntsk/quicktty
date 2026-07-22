import AppKit
import Testing

@testable import QuickTTY

@MainActor
private final class BroadcastMenuActionTarget: NSObject {
    private(set) var invocationCount = 0

    @objc func toggleBroadcast() {
        invocationCount += 1
    }
}

@Suite(.serialized)
@MainActor
struct BroadcastInputTests {
    @Test
    func coordinatorTogglesActiveTabWithoutRecreatingSurfacesAndPreservesFocus() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            try coordinator.start()
            let activeSurface = try #require(coordinator.activeSurfaceForTesting)
            let surfaceIDs = coordinator.surfaceIDsForTesting
            let initialCount = bridge.activeSurfaceCount

            #expect(coordinator.canToggleBroadcast)
            #expect(!coordinator.isBroadcastingActiveTab)
            coordinator.toggleBroadcast()

            #expect(coordinator.isBroadcastingActiveTab)
            #expect(activeTab(of: coordinator).isBroadcasting)
            #expect(
                coordinator.workspaceViewControllerForTesting.tabBarViewController
                    .displayedTabsForTesting.first?.isBroadcasting == true)
            #expect(bridge.activeSurfaceCount == initialCount)
            #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
            #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)

            coordinator.toggleBroadcast()

            #expect(!coordinator.isBroadcastingActiveTab)
            #expect(!activeTab(of: coordinator).isBroadcasting)
            #expect(bridge.activeSurfaceCount == initialCount)
            #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)
        }
    }

    @Test
    func coordinatorDisablesBroadcastToggleWhenActiveWorkspaceHasNoTabs() throws {
        let emptyWorkspace = Workspace(name: "Empty")
        let store = try WorkspaceStore(workspaces: [emptyWorkspace])
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
                initialWorkspaceStore: store
            )

            #expect(!coordinator.canToggleBroadcast)
            #expect(!coordinator.isBroadcastingActiveTab)
            coordinator.toggleBroadcast()
            #expect(!coordinator.isBroadcastingActiveTab)
            #expect(bridge.activeSurfaceCount == 0)
        }
    }

    @Test
    func broadcastMenuInstallerUsesExactCommandBDispatchesAndNormalizesDuplicates() throws {
        let target = BroadcastMenuActionTarget()
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let canonical = NSMenuItem(title: "Foreign Broadcast", action: nil, keyEquivalent: "B")
        canonical.keyEquivalentModifierMask = [.command]
        let duplicate = NSMenuItem(title: "Toggle Broadcast Input", action: nil, keyEquivalent: "x")
        let foreignShift = NSMenuItem(title: "Foreign Shift", action: nil, keyEquivalent: "b")
        foreignShift.keyEquivalentModifierMask = [.command, .shift]
        let foreignOption = NSMenuItem(title: "Foreign Option", action: nil, keyEquivalent: "b")
        foreignOption.keyEquivalentModifierMask = [.command, .option]
        let foreignControl = NSMenuItem(title: "Foreign Control", action: nil, keyEquivalent: "b")
        foreignControl.keyEquivalentModifierMask = [.command, .control]
        [canonical, duplicate, foreignShift, foreignOption, foreignControl].forEach(
            viewMenu.addItem)

        AppDelegate.installToggleBroadcastMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(BroadcastMenuActionTarget.toggleBroadcast)
        )
        AppDelegate.installToggleBroadcastMenuItem(
            in: mainMenu,
            target: target,
            action: #selector(BroadcastMenuActionTarget.toggleBroadcast)
        )

        let item = try #require(viewMenu.item(withTitle: "Toggle Broadcast Input"))
        #expect(viewMenu.items.filter { $0.title == "Toggle Broadcast Input" }.count == 1)
        #expect(item === canonical)
        #expect(item.keyEquivalent == "b")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.target === target)
        #expect(item.action == #selector(BroadcastMenuActionTarget.toggleBroadcast))
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        #expect(target.invocationCount == 1)
        #expect(viewMenu.items.contains { $0 === foreignShift })
        #expect(viewMenu.items.contains { $0 === foreignOption })
        #expect(viewMenu.items.contains { $0 === foreignControl })
    }

    @Test
    func broadcastMenuValidationReflectsAvailabilityAndState() {
        let item = AppDelegate.makeToggleBroadcastMenuItem(target: BroadcastMenuActionTarget())

        #expect(
            !AppDelegate.validateToggleBroadcastMenuItem(
                item,
                canToggleBroadcast: false,
                isBroadcastingActiveTab: true
            ))
        #expect(item.state == NSControl.StateValue.on)
        #expect(
            AppDelegate.validateToggleBroadcastMenuItem(
                item,
                canToggleBroadcast: true,
                isBroadcastingActiveTab: false
            ))
        #expect(item.state == NSControl.StateValue.off)
    }

    @Test
    func tabContextMenuActivatesRightClickedTabAndTogglesTheActiveTab() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            try coordinator.start()
            let firstTabID = activeTab(of: coordinator).id
            coordinator.createNewTab()
            let secondTabID = activeTab(of: coordinator).id

            let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController
            let firstMenu = tabBar.contextMenu(for: firstTabID)
            let firstItem = try #require(firstMenu.item(withTitle: "Broadcast Input"))
            #expect(activeTab(of: coordinator).id == firstTabID)
            #expect(firstItem.state == .off)
            #expect(NSApp.sendAction(firstItem.action!, to: firstItem.target, from: firstItem))
            #expect(coordinator.isBroadcastingActiveTab)

            let secondMenu = tabBar.contextMenu(for: secondTabID)
            let secondItem = try #require(secondMenu.item(withTitle: "Broadcast Input"))
            #expect(activeTab(of: coordinator).id == secondTabID)
            #expect(secondItem.state == .off)
            #expect(!coordinator.isBroadcastingActiveTab)

            let currentMenu = tabBar.contextMenu(for: secondTabID)
            let currentItem = try #require(currentMenu.item(withTitle: "Broadcast Input"))
            #expect(
                NSApp.sendAction(currentItem.action!, to: currentItem.target, from: currentItem))
            let checkedMenu = tabBar.contextMenu(for: secondTabID)
            #expect(checkedMenu.item(withTitle: "Broadcast Input")?.state == .on)
        }
    }

    private func activeTab(of coordinator: WindowCoordinator) -> TerminalTab {
        let store = coordinator.workspaceStoreForTesting
        let workspace = store.workspace(id: store.activeWorkspaceID)!
        return store.tab(id: workspace.activeTabID!)!
    }
}
