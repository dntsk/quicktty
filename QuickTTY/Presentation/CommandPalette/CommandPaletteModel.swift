import Foundation

enum CommandPaletteCommandID: String, CaseIterable, Equatable, Hashable, Sendable {
    case quit
    case openConfiguration = "open-configuration"
    case agentIntegrations = "agent-integrations"
    case checkForUpdates = "check-for-updates"
    case togglePresentation = "toggle-presentation"
    case newTab = "new-tab"
    case closePane = "close-pane"
    case closeTab = "close-tab"
    case splitRight = "split-right"
    case splitDown = "split-down"
    case previousPane = "previous-pane"
    case nextPane = "next-pane"
    case togglePaneZoom = "toggle-pane-zoom"
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case focusUp = "focus-up"
    case focusDown = "focus-down"
    case toggleBroadcast = "toggle-broadcast"
    case newWorkspace = "new-workspace"
    case renameWorkspace = "rename-workspace"
    case deleteWorkspace = "delete-workspace"
}

enum CommandPaletteTarget: Equatable, Hashable, Sendable {
    case command(CommandPaletteCommandID)
    case workspace(WorkspaceID)
    case tab(workspaceID: WorkspaceID, tabID: TabID)
}

enum CommandPaletteItemID: Equatable, Hashable, Sendable {
    case command(CommandPaletteCommandID)
    case workspace(WorkspaceID)
    case tab(TabID)
}

enum CommandPaletteCategory: Int, CaseIterable, Equatable, Hashable, Sendable {
    case commands
    case workspaces
    case tabs

    var title: String {
        switch self {
        case .commands: "Commands"
        case .workspaces: "Workspaces"
        case .tabs: "Tabs"
        }
    }
}

enum CommandPaletteAvailability: Equatable, Hashable, Sendable {
    case enabled
    case disabled(reason: String)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var disabledReason: String? {
        guard case .disabled(let reason) = self else { return nil }
        return reason
    }
}

struct CommandPaletteItem: Equatable, Hashable, Sendable {
    let id: CommandPaletteItemID
    let target: CommandPaletteTarget
    let category: CommandPaletteCategory
    let title: String
    let subtitle: String?
    let aliases: [String]
    let symbolName: String
    let shortcut: String?
    let isActive: Bool
    let availability: CommandPaletteAvailability
    let sourceOrder: Int

    var stableSortKey: String {
        switch id {
        case .command(let commandID): "command:\(commandID.rawValue)"
        case .workspace(let workspaceID): "workspace:\(workspaceID.rawValue.uuidString)"
        case .tab(let tabID): "tab:\(tabID.rawValue.uuidString)"
        }
    }
}
