import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct CommandPaletteTests {
    @Test
    func catalogHasOneDescriptorForEveryCommandAndNoTerminalRoutes() {
        let descriptors = CommandPaletteCatalog.commands
        let ids = descriptors.map(\.id)

        #expect(Set(ids) == Set(CommandPaletteCommandID.allCases))
        #expect(ids.count == Set(ids).count)
        #expect(
            descriptors.compactMap(\.shortcutAction).allSatisfy {
                if case .terminal = $0.executionRoute { return false }
                return $0 != .commandPalette && $0.index == nil
            }
        )
    }

    @Test
    func matcherRanksExactPrefixAndFuzzyMatchesDeterministically() {
        let items = [
            item(.newTab, title: "New Tab", aliases: ["create tab"], order: 0),
            item(.newWorkspace, title: "New Workspace", aliases: ["create workspace"], order: 1),
            item(.togglePaneZoom, title: "Zoom Pane", aliases: ["maximize"], order: 2),
        ]

        #expect(
            CommandPaletteMatcher.matches(items, query: "new tab").map(\.title).first == "New Tab")
        #expect(
            CommandPaletteMatcher.matches(items, query: "new").map(\.title)
                == ["New Tab", "New Workspace"]
        )
        #expect(
            CommandPaletteMatcher.matches(items, query: "nws").map(\.title) == ["New Workspace"])
        #expect(
            CommandPaletteMatcher.matches(items, query: "maximize").map(\.title) == ["Zoom Pane"])
    }

    @Test
    func matcherFoldsCaseDiacriticsAndSearchesEveryToken() {
        let workspace = CommandPaletteItem(
            id: .workspace(WorkspaceID()),
            target: .workspace(WorkspaceID()),
            category: .workspaces,
            title: "Développement",
            subtitle: "Workspace",
            aliases: ["workspace"],
            symbolName: "square.stack.3d.up",
            shortcut: nil,
            isActive: false,
            availability: .enabled,
            sourceOrder: 0
        )

        #expect(CommandPaletteMatcher.matches([workspace], query: "DEV workspace").count == 1)
        #expect(CommandPaletteMatcher.matches([workspace], query: "dev missing").isEmpty)
    }

    @Test
    func emptyQueryPreservesCategoriesAndSourceOrderIncludingDisabledItems() {
        let disabled = item(
            .closePane,
            title: "Close Pane",
            availability: .disabled(reason: "No active pane"),
            order: 1
        )
        let first = item(.newTab, title: "New Tab", order: 0)
        let workspaceID = WorkspaceID()
        let workspace = CommandPaletteItem(
            id: .workspace(workspaceID),
            target: .workspace(workspaceID),
            category: .workspaces,
            title: "Default",
            subtitle: "Workspace",
            aliases: [],
            symbolName: "square.stack.3d.up",
            shortcut: nil,
            isActive: true,
            availability: .enabled,
            sourceOrder: 0
        )

        #expect(
            CommandPaletteMatcher.matches([workspace, disabled, first], query: "").map(\.id)
                == [first.id, disabled.id, workspace.id]
        )
    }

    @Test
    func shortcutDisplayUsesNativeModifierAndKeyGlyphOrder() {
        #expect(
            ShortcutChord(
                key: .p,
                modifiers: [.command, .option, .control, .shift]
            ).displayString == "⌃⌥⇧⌘P"
        )
        #expect(ShortcutChord(key: .left, modifiers: [.command, .shift]).displayString == "⇧⌘←")
        #expect(ShortcutChord(key: .pageDown).displayString == "⇟")
    }

    @Test
    func controllerFiltersMovesAcrossEnabledRowsAndExecutesTypedTarget() throws {
        let disabled = item(
            .closePane,
            title: "Close Pane",
            availability: .disabled(reason: "No active pane"),
            order: 0
        )
        let enabled = item(.newTab, title: "New Tab", order: 1)
        let controller = CommandPaletteViewController(chromeHeight: 28)
        var executed: [CommandPaletteTarget] = []
        var dismissCount = 0
        controller.onExecute = { executed.append($0) }
        controller.onDismiss = { dismissCount += 1 }
        controller.apply(items: [disabled, enabled], palette: .fallback)

        #expect(controller.displayedItemsForTesting.count == 2)
        #expect(controller.selectedItemIDForTesting == enabled.id)
        #expect(
            controller.handleTextCommandForTesting(
                #selector(NSResponder.moveDown(_:))
            )
        )
        #expect(controller.selectedItemIDForTesting == enabled.id)
        #expect(
            controller.handleTextCommandForTesting(
                #selector(NSResponder.insertNewline(_:))
            )
        )
        #expect(executed == [enabled.target])
        controller.activateRowForTesting(0)
        controller.activateRowForTesting(1)
        #expect(executed == [enabled.target, enabled.target])
        #expect(
            controller.handleTextCommandForTesting(
                #selector(NSResponder.cancelOperation(_:))
            )
        )
        #expect(dismissCount == 1)

        controller.setQueryForTesting("close")
        #expect(controller.displayedItemsForTesting == [disabled])
        #expect(controller.selectedItemIDForTesting == nil)
        controller.performSelectionForTesting()
        #expect(executed == [enabled.target, enabled.target])
    }

    @Test
    func workspaceHostsPaletteAboveContentAndDismissesWithoutReplacingIt() {
        let workspaceController = WorkspaceViewController()
        let window = mount(workspaceController)
        defer { window.orderOut(nil) }
        let item = item(.newTab, title: "New Tab", order: 0)
        var dismissRestoration: [Bool] = []

        workspaceController.presentCommandPalette(
            items: [item],
            onExecute: { _ in },
            onDismiss: { dismissRestoration.append($0) }
        )
        window.contentView?.layoutSubtreeIfNeeded()
        workspaceController.view.layoutSubtreeIfNeeded()

        #expect(workspaceController.commandPaletteIsPresentedForTesting)
        #expect(
            workspaceController.commandPaletteViewControllerForTesting?.view.superview
                === workspaceController.view)
        #expect(
            workspaceController.commandPaletteViewControllerForTesting?.displayedItemsForTesting
                == [item])

        #expect(!workspaceController.dismissCommandPalette(restorePreviousResponder: false))
        #expect(!workspaceController.commandPaletteIsPresentedForTesting)
        #expect(dismissRestoration.isEmpty)
    }

    private func item(
        _ id: CommandPaletteCommandID,
        title: String,
        aliases: [String] = [],
        availability: CommandPaletteAvailability = .enabled,
        order: Int
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: .command(id),
            target: .command(id),
            category: .commands,
            title: title,
            subtitle: nil,
            aliases: aliases,
            symbolName: "command",
            shortcut: nil,
            isActive: false,
            availability: availability,
            sourceOrder: order
        )
    }

    private func mount(_ controller: WorkspaceViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = window.contentView!
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentView.addSubview(controller.view)
        controller.apply(WorkspaceStore())
        contentView.layoutSubtreeIfNeeded()
        return window
    }
}
