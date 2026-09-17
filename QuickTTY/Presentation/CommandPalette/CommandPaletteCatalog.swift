struct CommandPaletteCommandDescriptor: Equatable, Sendable {
    let id: CommandPaletteCommandID
    let title: String
    let aliases: [String]
    let symbolName: String
    let shortcutAction: ShortcutAction?
}

enum CommandPaletteCatalog {
    static let commands: [CommandPaletteCommandDescriptor] = [
        descriptor(.newTab, "New Tab", ["create tab"], "plus.rectangle", .newTab),
        descriptor(.closePane, "Close Pane", ["close split"], "xmark.rectangle", .closePane),
        descriptor(.closeTab, "Close Tab", ["remove tab"], "xmark.square", .closeTab),
        descriptor(
            .splitRight, "Split Right", ["horizontal split"], "rectangle.split.2x1", .splitRight),
        descriptor(.splitDown, "Split Down", ["vertical split"], "rectangle.split.1x2", .splitDown),
        descriptor(.previousPane, "Previous Pane", ["previous split"], "arrow.left", .previousPane),
        descriptor(.nextPane, "Next Pane", ["next split"], "arrow.right", .nextPane),
        descriptor(
            .focusLeft, "Focus Left Pane", ["navigate left split"], "arrow.left.to.line", .focusLeft
        ),
        descriptor(
            .focusRight, "Focus Right Pane", ["navigate right split"], "arrow.right.to.line",
            .focusRight),
        descriptor(.focusUp, "Focus Up Pane", ["navigate up split"], "arrow.up.to.line", .focusUp),
        descriptor(
            .focusDown, "Focus Down Pane", ["navigate down split"], "arrow.down.to.line", .focusDown
        ),
        descriptor(
            .togglePaneZoom, "Zoom Pane", ["maximize pane exit zoom"],
            "arrow.up.left.and.arrow.down.right", .togglePaneZoom),
        descriptor(
            .toggleBroadcast, "Toggle Broadcast Input", ["broadcast typing all panes"],
            "dot.radiowaves.left.and.right", .toggleBroadcast),
        descriptor(
            .newWorkspace, "New Workspace…", ["create workspace"], "square.stack.3d.up.badge.plus",
            .newWorkspace),
        descriptor(
            .renameWorkspace, "Rename Workspace…", ["edit workspace name"], "pencil",
            .renameWorkspace),
        descriptor(
            .deleteWorkspace, "Delete Workspace…", ["remove workspace"], "trash", .deleteWorkspace),
        descriptor(
            .togglePresentation, "Toggle Presentation Mode", ["normal quake mode"],
            "macwindow.on.rectangle", .togglePresentation),
        descriptor(
            .openConfiguration, "Open Configuration…", ["settings config file"], "gearshape",
            .openConfig),
        descriptor(
            .agentIntegrations, "Agent Integrations…", ["agents pi claude codex"], "cpu", nil),
        descriptor(
            .checkForUpdates, "Check for Updates…", ["software update"],
            "arrow.triangle.2.circlepath", nil),
        descriptor(.quit, "Quit QuickTTY", ["exit application"], "power", .quit),
    ]

    private static func descriptor(
        _ id: CommandPaletteCommandID,
        _ title: String,
        _ aliases: [String],
        _ symbolName: String,
        _ shortcutAction: ShortcutAction?
    ) -> CommandPaletteCommandDescriptor {
        CommandPaletteCommandDescriptor(
            id: id,
            title: title,
            aliases: aliases,
            symbolName: symbolName,
            shortcutAction: shortcutAction
        )
    }
}
