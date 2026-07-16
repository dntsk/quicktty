import AppKit
import Testing

@testable import GhostTerm

@MainActor
private final class NewTabMenuActionTarget: NSObject {
    private(set) var invocationCount = 0

    @objc func createNewTab() {
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
struct AppDelegateLifecycleTests {
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
}
