enum AgentMessagingCapability: Equatable, Sendable {
    case piTools
    case claudeQuestions
    case cli
    case blocked(AgentIntegrationBlockedReason)

    var label: String {
        switch self {
        case .piTools: "Pi tools"
        case .claudeQuestions: "Claude 2.1.318 / CLI"
        case .cli: "CLI"
        case .blocked: "blocked"
        }
    }

    var explanation: String {
        switch self {
        case .piTools:
            "Explicit QuickTTY question, action and status tools require the updated Pi integration. Native dialogs are not intercepted."
        case .claudeQuestions:
            "Owned integration update forwards main-session single-select questions only for the verified arm64 Claude Code 2.1.318 binary. Other builds keep native prompts and the common CLI. Native action permissions are not intercepted."
        case .cli:
            "Registered agents can use the common CLI after a Telegram grant. Codex/Gemini receive instructions on accepted SessionStart; otherwise provide the copied instructions. Native prompts are not intercepted."
        case .blocked(let reason):
            "Messaging requires a live registered origin. The existing lifecycle blocker is: \(reason.rawValue)."
        }
    }
}

extension AgentIntegrationDefinition {
    var messagingCapability: AgentMessagingCapability {
        if case .blocked(let reason) = capability { return .blocked(reason) }
        switch id.rawValue {
        case "pi": return .piTools
        case "claude": return .claudeQuestions
        default: return .cli
        }
    }
}
