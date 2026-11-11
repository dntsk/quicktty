import AppKit
import Testing

@testable import QuickTTY

@MainActor
@Suite(.serialized)
struct TelegramChannelControlsTests {
    @Test
    func globalShortcutIsRegisteredAndCanBeRemapped() throws {
        let target = TelegramMenuTarget()
        let shortcuts = ShortcutController()
        var menu = AppDelegate.installToggleTelegramMenuItem(
            in: nil, target: target, shortcutController: shortcuts)
        menu = AppDelegate.installToggleTelegramMenuItem(
            in: menu, target: target, shortcutController: shortcuts)
        let items = try #require(menu.item(withTitle: "QuickTTY")?.submenu?.items)
        #expect(items.filter { $0.title == "Use Telegram for Agents" }.count == 1)
        let item = try #require(shortcuts.menuItem(for: .toggleTelegram))
        #expect(item.action == AppDelegate.toggleTelegramMenuItemAction)
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(ShortcutAction.toggleTelegram.scope == .application)
        #expect(ShortcutAction.toggleTelegram.targetPolicy == .application)
        #expect(ShortcutAction.toggleTelegram.defaultChord?.stringValue == "cmd+opt+t")
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        #expect(target.toggles == 1)

        var configuration = ShortcutConfiguration.defaults
        _ = configuration.assign(try ShortcutChord(parsing: "ctrl+shift+t"), to: .toggleTelegram)
        shortcuts.apply(configuration)
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.control, .shift])
    }

    @Test
    func indicatorNamesEveryStateAndIsClickable() {
        var toggles = 0
        let button = TelegramChannelButton { toggles += 1 }
        for state in [TelegramChannelState.off, .connecting, .active, .setup, .failed] {
            button.apply(state)
            #expect(button.title == state.title)
            #expect(button.accessibilityValue() as? String == state.accessibilityValue)
            #expect(button.isEnabled)
            #expect(button.image != nil)
            #expect(button.toolTip?.contains("all agents") == true)
        }
        button.apply(.active)
        button.performClick(nil)
        #expect(toggles == 1)
        if AgentMessagingService.current == nil {
            NotificationCenter.default.post(
                name: AgentMessagingService.didChangeNotification, object: nil)
            #expect(button.channelState == .unavailable)
        }
        button.apply(.unavailable)
        #expect(!button.isEnabled)
        #expect(button.title == "Telegram —")
    }

    @Test
    func indicatorIsPresentInSharedWorkspaceChrome() {
        let controller = WorkspaceViewController()
        controller.loadViewIfNeeded()
        #expect(controller.telegramChannelButton.superview != nil)
        #expect(
            controller.telegramChannelButton.superview === controller.workspaceSelector.superview)
        #expect(!controller.telegramChannelButton.isHidden)
    }
}

@MainActor
private final class TelegramMenuTarget: NSObject {
    var toggles = 0
    @objc func toggleTelegram() { toggles += 1 }
}
