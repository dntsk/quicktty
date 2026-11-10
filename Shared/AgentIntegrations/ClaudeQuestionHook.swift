import CryptoKit
import Foundation

struct ClaudeQuestionHook: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidInput
        case invalidAnswer
    }

    private struct Option: Codable, Sendable {
        let label: String
        let description: String
    }

    private struct Question: Codable, Sendable {
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool?
    }

    private struct Input: Codable, Sendable {
        let questions: [Question]
    }

    private struct Envelope: Decodable {
        let sessionID: String
        let toolUseID: String
        let event: String
        let toolName: String
        let input: Input

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case toolUseID = "tool_use_id"
            case event = "hook_event_name"
            case toolName = "tool_name"
            case input = "tool_input"
        }
    }

    private struct Output: Encodable {
        struct Specific: Encodable {
            struct UpdatedInput: Encodable {
                let questions: [Question]
                let answers: [String: String]
            }
            let hookEventName = "PreToolUse"
            let permissionDecision = "allow"
            let updatedInput: UpdatedInput
        }
        let hookSpecificOutput: Specific
    }

    private let sessionID: String
    private let toolUseID: String
    private let questions: [Question]

    init(input: Data) throws {
        do {
            guard !input.isEmpty, input.count <= AgentMessagingProtocol.maximumRequestBytes else {
                throw Failure.invalidInput
            }
            try StrictJSON.validate(input)
            let envelope = try JSONDecoder().decode(Envelope.self, from: input)
            guard envelope.event == "PreToolUse", envelope.toolName == "AskUserQuestion",
                let root = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                root["agent_id"] == nil, root["agent_type"] == nil,
                let originalInput = root["tool_input"] as? NSDictionary,
                let projectedInput = try JSONSerialization.jsonObject(
                    with: AgentMessagingProtocol.encode(envelope.input)) as? NSDictionary,
                originalInput == projectedInput,
                Self.validText(envelope.sessionID, maximum: 512),
                Self.validText(envelope.toolUseID, maximum: 512),
                !envelope.sessionID.hasPrefix("-"),
                (1...4).contains(envelope.input.questions.count)
            else { throw Failure.invalidInput }
            let questions = envelope.input.questions
            guard Set(questions.map(\.question)).count == questions.count else {
                throw Failure.invalidInput
            }
            for question in questions {
                guard question.multiSelect != true,
                    Self.validText(question.question, maximum: 2_304, multiline: true),
                    Self.validText(question.header, maximum: 64),
                    (2...4).contains(question.options.count),
                    Set(question.options.map(\.label)).count == question.options.count,
                    question.options.allSatisfy({
                        Self.validText($0.label, maximum: 64)
                            && Self.validText($0.description, maximum: 768, multiline: true)
                    })
                else { throw Failure.invalidInput }
            }
            sessionID = envelope.sessionID
            toolUseID = envelope.toolUseID
            self.questions = questions
            _ = try requests()
        } catch { throw Failure.invalidInput }
    }

    func requests() throws -> [AgentMessagingRequest] {
        try questions.enumerated().map { index, question in
            let context = question.options.map { "\($0.label): \($0.description)" }.joined(
                separator: "\n")
            let text = "\(question.header)\n\(question.question)\n\n\(context)"
            let request = AgentMessagingRequest(
                version: 1, operation: .question, requestID: requestID(index: index),
                text: text, choices: question.options.map(\.label),
                timeoutMilliseconds: 900_000, sessionID: sessionID)
            try request.validate()
            return request
        }
    }

    func output(answers: [AgentMessagingResponse]) throws -> Data {
        do {
            guard answers.count == questions.count else { throw Failure.invalidAnswer }
            let requests = try requests()
            var values: [String: String] = [:]
            for (index, response) in answers.enumerated() {
                try response.validate(for: requests[index])
                guard let text = response.text,
                    Self.validText(text, maximum: 4_096, multiline: true)
                else { throw Failure.invalidAnswer }
                switch response.state {
                case "text":
                    guard questions[index].options.contains(where: { $0.label == text }) else {
                        throw Failure.invalidAnswer
                    }
                case "choice":
                    guard let choice = response.choiceIndex,
                        questions[index].options.indices.contains(choice),
                        questions[index].options[choice].label == text
                    else { throw Failure.invalidAnswer }
                default: throw Failure.invalidAnswer
                }
                values[questions[index].question] = text
            }
            return try AgentMessagingProtocol.encode(
                Output(
                    hookSpecificOutput: .init(
                        updatedInput: .init(questions: questions, answers: values))))
        } catch { throw Failure.invalidAnswer }
    }

    private func requestID(index: Int) -> UUID {
        // Payload changes must reuse the identity so that the ledger detects a conflict.
        let name = "QuickTTY.ClaudeQuestion.v1\0\(sessionID)\0\(toolUseID)\0\(index)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private static func validText(_ value: String, maximum: Int, multiline: Bool = false) -> Bool {
        (1...maximum).contains(value.utf8.count)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.elementsEqual(value.precomposedStringWithCanonicalMapping.utf8)
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) && !(multiline && $0.value == 10)
            }
    }
}
