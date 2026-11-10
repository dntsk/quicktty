import Foundation

struct AgentInteractionOrigin: Hashable, Sendable {
    let instanceID: UUID
    let workspaceID: UUID
    let paneID: UUID
    let adapterID: String
    let sessionID: String
    let generation: UInt64

    init(
        instanceID: UUID,
        workspaceID: UUID,
        paneID: UUID,
        adapterID: String,
        sessionID: String,
        generation: UInt64
    ) throws {
        guard (1...64).contains(adapterID.utf8.count),
            adapterID.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }),
            (1...512).contains(sessionID.utf8.count),
            !sessionID.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw AgentInteractionError.invalidOrigin }
        self.instanceID = instanceID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.adapterID = adapterID
        self.sessionID = sessionID
        self.generation = generation
    }
}

enum AgentInteractionRisk: Equatable, Sendable {
    case standard
    case elevated
}

struct AgentInteractionAction: Equatable, Sendable {
    let operation: String
    let resources: String
    let consequences: String
    let risk: AgentInteractionRisk

    init(
        operation: String,
        resources: String,
        consequences: String,
        risk: AgentInteractionRisk
    ) throws {
        try AgentInteractionText.validate(operation, maximumBytes: 1_024)
        try AgentInteractionText.validate(resources, maximumBytes: 768)
        try AgentInteractionText.validate(consequences, maximumBytes: 768)
        self.operation = operation
        self.resources = resources
        self.consequences = consequences
        self.risk = risk
    }
}

enum AgentInteractionPrompt: Equatable, Sendable {
    case question(text: String, choices: [String])
    case action(AgentInteractionAction)
}

struct AgentInteractionRequest: Equatable, Sendable {
    let id: UUID
    let origin: AgentInteractionOrigin
    let prompt: AgentInteractionPrompt
    let timeoutMilliseconds: UInt64

    init(
        id: UUID,
        origin: AgentInteractionOrigin,
        prompt: AgentInteractionPrompt,
        timeoutMilliseconds: UInt64 = 900_000
    ) throws {
        guard (1_000...1_800_000).contains(timeoutMilliseconds) else {
            throw AgentInteractionError.invalidRequest
        }
        if case .question(let text, let choices) = prompt {
            try AgentInteractionText.validate(text, maximumBytes: 2_304)
            guard choices.count <= 8, Set(choices).count == choices.count else {
                throw AgentInteractionError.invalidChoices
            }
            for choice in choices {
                try AgentInteractionText.validate(choice, maximumBytes: 64, multiline: false)
            }
        }
        self.id = id
        self.origin = origin
        self.prompt = prompt
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    var confirmationPhrase: String {
        "CONFIRM \(id.uuidString.lowercased())"
    }
}

enum AgentInteractionAnswer: Equatable, Sendable {
    case text(String)
    case choice(Int)
    case approve
    case deny
    case cancel
}

enum AgentInteractionResolution: Equatable, Sendable {
    case text(String)
    case choice(index: Int, label: String)
    case approved
    case denied
    case cancelled
    case expired
    case revoked
}

enum AgentInteractionState: Equatable, Sendable {
    case pending
    case resolved(AgentInteractionResolution)
}

struct AgentInteractionPresentation: Equatable, Sendable {
    let workspaceName: String
    let agentName: String

    init(workspaceName: String, agentName: String) throws {
        try AgentInteractionText.validate(workspaceName, maximumBytes: 128, multiline: false)
        try AgentInteractionText.validate(agentName, maximumBytes: 64, multiline: false)
        self.workspaceName = workspaceName
        self.agentName = agentName
    }
}

struct AgentInteractionSnapshot: Equatable, Sendable {
    let request: AgentInteractionRequest
    let presentation: AgentInteractionPresentation
    let expiresAtMilliseconds: UInt64
    fileprivate(set) var state: AgentInteractionState
    fileprivate(set) var telegramMessage: TelegramMessageReference?

    mutating func resolve(_ resolution: AgentInteractionResolution) {
        state = .resolved(resolution)
    }

    mutating func bind(_ message: TelegramMessageReference) {
        telegramMessage = message
    }
}

enum AgentInteractionError: Error, Equatable, Sendable {
    case invalidOrigin
    case invalidRequest
    case invalidText
    case invalidChoices
    case notAuthorized
    case requestIDConflict
    case requestUnavailable
    case capacityExceeded
    case invalidAnswer
    case messageAlreadyBound
    case invalidTelegramMessage
    case clockExhausted
}

enum AgentInteractionText {
    static func validate(
        _ value: String,
        maximumBytes: Int,
        multiline: Bool = true
    ) throws {
        guard (1...maximumBytes).contains(value.utf8.count),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.unicodeScalars.contains(where: { scalar in
                if scalar.value == 10 { return !multiline }
                return CharacterSet.controlCharacters.contains(scalar)
                    || (0x202A...0x202E).contains(scalar.value)
                    || (0x2066...0x2069).contains(scalar.value)
            })
        else { throw AgentInteractionError.invalidText }
    }
}
