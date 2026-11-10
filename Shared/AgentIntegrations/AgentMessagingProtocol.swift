import CryptoKit
import Foundation

struct AgentMessagingRequest: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case question, action, status, wait, cancel, notify
    }
    let version: Int
    let operation: Operation
    let requestID: UUID
    var text: String?
    var choices: [String]?
    var resources: String?
    var consequences: String?
    var elevated: Bool?
    var timeoutMilliseconds: UInt64?
    var status: String?
    var sessionID: String?

    func validate() throws {
        guard version == 1 else { throw AgentMessagingProtocolError.invalidPayload }
        if let sessionID {
            guard (1...512).contains(sessionID.utf8.count),
                !sessionID.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else { throw AgentMessagingProtocolError.invalidPayload }
        }
        let hasPrompt =
            text != nil || choices != nil || resources != nil || consequences != nil
            || elevated != nil || status != nil
        switch operation {
        case .question:
            guard let text, (1...2_304).contains(text.utf8.count), resources == nil,
                consequences == nil,
                elevated == nil, status == nil, (choices?.count ?? 0) <= 8
            else { throw AgentMessagingProtocolError.invalidPayload }
            if let choices, !choices.allSatisfy({ (1...64).contains($0.utf8.count) }) {
                throw AgentMessagingProtocolError.invalidPayload
            }
            guard (1_000...1_800_000).contains(timeoutMilliseconds ?? 900_000) else {
                throw AgentMessagingProtocolError.invalidPayload
            }
        case .action:
            guard let text, (1...1_024).contains(text.utf8.count), let resources,
                (1...768).contains(resources.utf8.count), let consequences,
                (1...768).contains(consequences.utf8.count), choices == nil, status == nil,
                (1_000...1_800_000).contains(timeoutMilliseconds ?? 900_000)
            else { throw AgentMessagingProtocolError.invalidPayload }
        case .status, .cancel:
            guard !hasPrompt, timeoutMilliseconds == nil else {
                throw AgentMessagingProtocolError.invalidPayload
            }
        case .wait:
            guard !hasPrompt, let timeoutMilliseconds, (100...30_000).contains(timeoutMilliseconds)
            else {
                throw AgentMessagingProtocolError.invalidPayload
            }
        case .notify:
            guard let status, ["working", "waiting", "completed", "failed"].contains(status),
                let text, (1...512).contains(text.utf8.count), choices == nil, resources == nil,
                consequences == nil, elevated == nil, timeoutMilliseconds == nil
            else { throw AgentMessagingProtocolError.invalidPayload }
        }
    }
}

struct AgentMessagingResponse: Codable, Equatable, Sendable {
    let version: Int
    let requestID: UUID?
    let state: String
    var text: String?
    var choiceIndex: Int?
    var code: String?

    func validate(for request: AgentMessagingRequest) throws {
        guard version == 1, requestID == request.requestID else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        if request.operation == .question, ["approved", "denied", "accepted"].contains(state) {
            throw AgentMessagingProtocolError.invalidPayload
        }
        if request.operation == .action, ["text", "choice", "accepted"].contains(state) {
            throw AgentMessagingProtocolError.invalidPayload
        }
        if request.operation == .notify, state != "accepted", state != "error" {
            throw AgentMessagingProtocolError.invalidPayload
        }
        if request.operation != .notify, state == "accepted" {
            throw AgentMessagingProtocolError.invalidPayload
        }
        switch state {
        case "pending", "accepted", "approved", "denied", "cancelled", "expired", "revoked":
            guard text == nil, choiceIndex == nil, code == nil else {
                throw AgentMessagingProtocolError.invalidPayload
            }
        case "text":
            guard let text, (1...4_096).contains(text.utf8.count), choiceIndex == nil, code == nil
            else { throw AgentMessagingProtocolError.invalidPayload }
        case "choice":
            guard let text, (1...64).contains(text.utf8.count), let choiceIndex,
                (0..<8).contains(choiceIndex), code == nil
            else { throw AgentMessagingProtocolError.invalidPayload }
        case "error":
            guard text == nil, choiceIndex == nil, let code, (1...64).contains(code.utf8.count),
                code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
            else { throw AgentMessagingProtocolError.invalidPayload }
        default: throw AgentMessagingProtocolError.invalidPayload
        }
    }

    static func failure(_ code: String, requestID: UUID? = nil) -> Self {
        Self(version: 1, requestID: requestID, state: "error", code: code)
    }
}

enum AgentMessagingProtocolError: Error, Equatable, Sendable {
    case invalidPayload
    case authenticationFailed
    case transportFailure
}

enum AgentMessagingProtocol {
    static let maximumRequestBytes = 65_536
    static let maximumResponseBytes = 65_536

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decodeRequest(_ data: Data, canonical: Bool = true) throws -> AgentMessagingRequest
    {
        guard !data.isEmpty, data.count <= maximumRequestBytes else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        do {
            try StrictJSON.validate(data)
            let value = try JSONDecoder().decode(AgentMessagingRequest.self, from: data)
            try value.validate()
            let encoded = try encode(value)
            if canonical {
                guard encoded == data else { throw AgentMessagingProtocolError.invalidPayload }
            } else {
                guard var input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let rawID = input["requestID"] as? String,
                    UUID(uuidString: rawID) == value.requestID,
                    let normalized = try JSONSerialization.jsonObject(with: encoded)
                        as? NSDictionary
                else { throw AgentMessagingProtocolError.invalidPayload }
                // CLI UUID spelling is not part of identity; signed frames remain byte-canonical.
                input["requestID"] = value.requestID.uuidString
                guard NSDictionary(dictionary: input) == normalized else {
                    throw AgentMessagingProtocolError.invalidPayload
                }
            }
            return value
        } catch { throw AgentMessagingProtocolError.invalidPayload }
    }

    static func serverProof(_ preflight: TerminalControlPreflight, challenge: Data, token: String)
        throws -> Data
    {
        try signature(
            domain: "Server", preflight: preflight, challenge: challenge, payload: Data(),
            token: token)
    }

    static func verifyServerProof(
        _ proof: Data, preflight: TerminalControlPreflight, challenge: Data, token: String
    ) -> Bool {
        verify(
            proof, domain: "Server", preflight: preflight, challenge: challenge, payload: Data(),
            token: token)
    }

    static func requestFrame(
        _ request: AgentMessagingRequest, preflight: TerminalControlPreflight, challenge: Data,
        token: String
    ) throws -> Data {
        try request.validate()
        return try frame(
            encode(request), domain: "Request", preflight: preflight, challenge: challenge,
            token: token)
    }

    static func decodeRequestFrame(
        _ data: Data, preflight: TerminalControlPreflight, challenge: Data, token: String
    ) throws -> AgentMessagingRequest {
        let payload = try unframe(
            data, maximum: maximumRequestBytes, domain: "Request", preflight: preflight,
            challenge: challenge, token: token)
        return try decodeRequest(payload)
    }

    static func responseFrame(
        _ response: AgentMessagingResponse, request: AgentMessagingRequest,
        preflight: TerminalControlPreflight, challenge: Data, token: String
    ) throws -> Data {
        try response.validate(for: request)
        let requestHash = Data(SHA256.hash(data: try encode(request)))
        return try frame(
            encode(response), domain: "Response", preflight: preflight,
            challenge: challenge + requestHash, token: token)
    }

    static func decodeResponseFrame(
        _ data: Data, request: AgentMessagingRequest, preflight: TerminalControlPreflight,
        challenge: Data, token: String
    ) throws -> AgentMessagingResponse {
        let requestHash = Data(SHA256.hash(data: try encode(request)))
        let payload = try unframe(
            data, maximum: maximumResponseBytes, domain: "Response", preflight: preflight,
            challenge: challenge + requestHash, token: token)
        do {
            let response = try JSONDecoder().decode(AgentMessagingResponse.self, from: payload)
            try response.validate(for: request)
            guard try encode(response) == payload else {
                throw AgentMessagingProtocolError.invalidPayload
            }
            return response
        } catch { throw AgentMessagingProtocolError.invalidPayload }
    }

    static func randomBytes() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func signature(
        domain: String, preflight: TerminalControlPreflight, challenge: Data, payload: Data,
        token: String
    ) throws -> Data {
        let context = try authenticationData(
            domain: domain, preflight: preflight, challenge: challenge, payload: payload)
        try AgentIPCValueValidator.validatePaneToken(token)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: context, using: SymmetricKey(data: Data(token.utf8))))
    }

    private static func verify(
        _ signature: Data, domain: String, preflight: TerminalControlPreflight, challenge: Data,
        payload: Data, token: String
    ) -> Bool {
        guard signature.count == 32,
            (try? AgentIPCValueValidator.validatePaneToken(token)) != nil,
            let context = try? authenticationData(
                domain: domain, preflight: preflight, challenge: challenge, payload: payload)
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: context, using: SymmetricKey(data: Data(token.utf8)))
    }

    private static func authenticationData(
        domain: String, preflight: TerminalControlPreflight, challenge: Data, payload: Data
    ) throws -> Data {
        guard challenge.count == (domain == "Response" ? 64 : 32) else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        return Data("QuickTTY.AgentMessaging.\(domain).v1\0".utf8)
            + (try TerminalControlProtocol.encodePreflight(preflight)) + challenge + payload
    }

    private static func frame(
        _ payload: Data, domain: String, preflight: TerminalControlPreflight, challenge: Data,
        token: String
    ) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumRequestBytes else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        var length = UInt32(payload.count).bigEndian
        var data = Swift.withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        data.append(
            try signature(
                domain: domain, preflight: preflight, challenge: challenge, payload: payload,
                token: token))
        return data
    }

    private static func unframe(
        _ data: Data, maximum: Int, domain: String, preflight: TerminalControlPreflight,
        challenge: Data, token: String
    ) throws -> Data {
        guard data.count >= 37, data.count <= maximum + 36 else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        let size = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(size) == data.count - 36 else { throw AgentMessagingProtocolError.invalidPayload }
        let payload = Data(data.dropFirst(4).dropLast(32))
        guard
            verify(
                Data(data.suffix(32)), domain: domain, preflight: preflight, challenge: challenge,
                payload: payload, token: token)
        else {
            throw AgentMessagingProtocolError.authenticationFailed
        }
        return payload
    }
}
