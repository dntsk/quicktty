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
    func newTabMenuInstallerCreatesFileMenuWhenMainMenuIsAbsent() {
        let target = NewTabMenuActionTarget()
        let mainMenu = AppDelegate.installNewTabMenuItem(
            in: nil,
            target: target,
            action: #selector(NewTabMenuActionTarget.createNewTab)
        )
        let fileMenu = mainMenu.item(withTitle: "File")?.submenu
        let item = fileMenu?.item(withTitle: "New Tab")

        #expect(fileMenu != nil)
        #expect(fileMenu?.items.count == 1)
        #expect(item?.title == "New Tab")
        #expect(item?.action == #selector(NewTabMenuActionTarget.createNewTab))
        #expect(item?.keyEquivalent == "t")
        #expect(item?.keyEquivalentModifierMask == [.command])
        #expect(item?.target === target)

        target.perform(#selector(NewTabMenuActionTarget.createNewTab), with: item)
        #expect(target.invocationCount == 1)
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
        #expect(existingItem.target === existingTarget)
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
}
