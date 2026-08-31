struct TerminalPaneDescriptor: Codable, Equatable, Sendable {
    let id: PaneID
    var cwd: String
    var startupCommand: StartupCommand
    var agentResumeBinding: AgentResumeBinding?

    private enum CodingKeys: String, CodingKey {
        case id
        case cwd
        case startupCommand
        case agentResumeBinding
    }

    init(
        id: PaneID = PaneID(),
        cwd: String,
        startupCommand: StartupCommand = .shell,
        agentResumeBinding: AgentResumeBinding? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.startupCommand = startupCommand
        self.agentResumeBinding = agentResumeBinding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PaneID.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        startupCommand = try container.decode(StartupCommand.self, forKey: .startupCommand)
        agentResumeBinding = try? container.decodeIfPresent(
            AgentResumeBinding.self,
            forKey: .agentResumeBinding
        )
    }
}
