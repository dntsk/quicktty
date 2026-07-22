struct TerminalPaneDescriptor: Codable, Equatable, Sendable {
    let id: PaneID
    var cwd: String
    var startupCommand: StartupCommand

    init(
        id: PaneID = PaneID(),
        cwd: String,
        startupCommand: StartupCommand = .shell
    ) {
        self.id = id
        self.cwd = cwd
        self.startupCommand = startupCommand
    }
}
