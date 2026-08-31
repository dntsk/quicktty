import Foundation

public struct AgentInvocationPayload: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil
    ) throws {
        try Self.validateExecutable(executable)
        try Self.validateArguments(arguments)
        if let workingDirectory {
            do {
                try AgentIPCValueValidator.validateWorkingDirectory(workingDirectory)
            } catch {
                throw AgentInvocationPayloadError.invalidWorkingDirectory
            }
        }

        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    private static func validateExecutable(_ executable: String) throws {
        guard (1...4_096).contains(executable.utf8.count),
            executable.hasPrefix("/"),
            !executable.containsIPCControlCharacter
        else {
            throw AgentInvocationPayloadError.invalidExecutable
        }
    }

    private static func validateArguments(_ arguments: [String]) throws {
        guard arguments.count <= 64 else {
            throw AgentInvocationPayloadError.invalidArguments
        }

        var totalBytes = 0
        for argument in arguments {
            guard argument.utf8.count <= 4_096, !argument.contains("\0") else {
                throw AgentInvocationPayloadError.invalidArguments
            }
            totalBytes += argument.utf8.count
        }

        guard totalBytes <= 32_768 else {
            throw AgentInvocationPayloadError.invalidArguments
        }
    }
}

public enum AgentInvocationPayloadEnvironment {
    public static let payloadKey = "QUICKTTY_LAUNCH_PAYLOAD"
    public static let helperKey = "QUICKTTY_AGENT_HELPER"
}

public enum AgentInvocationPayloadCodec {
    public static let maximumPayloadSize = 65_536
    public static let maximumBase64Size = ((maximumPayloadSize + 2) / 3) * 4

    public static func encode(_ payload: AgentInvocationPayload) throws -> Data {
        let data: Data
        do {
            data = try encodeCanonical(AgentInvocationWirePayload(payload: payload))
        } catch {
            throw AgentInvocationPayloadCodecError.invalidPayload
        }

        guard !data.isEmpty else {
            throw AgentInvocationPayloadCodecError.emptyPayload
        }
        guard data.count <= maximumPayloadSize else {
            throw AgentInvocationPayloadCodecError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> AgentInvocationPayload {
        guard !data.isEmpty else {
            throw AgentInvocationPayloadCodecError.emptyPayload
        }
        guard data.count <= maximumPayloadSize else {
            throw AgentInvocationPayloadCodecError.payloadTooLarge
        }

        do {
            let wirePayload = try JSONDecoder().decode(AgentInvocationWirePayload.self, from: data)
            guard try encodeCanonical(wirePayload) == data else {
                throw AgentInvocationPayloadCodecError.invalidPayload
            }
            return wirePayload.payload
        } catch {
            throw AgentInvocationPayloadCodecError.invalidPayload
        }
    }

    public static func encodeBase64(_ payload: AgentInvocationPayload) throws -> String {
        let encoded = try encode(payload).base64EncodedString()
        guard encoded.utf8.count <= maximumBase64Size else {
            throw AgentInvocationPayloadCodecError.payloadTooLarge
        }
        return encoded
    }

    public static func decodeBase64(_ encoded: String) throws -> AgentInvocationPayload {
        guard encoded.utf8.count <= maximumBase64Size else {
            throw AgentInvocationPayloadCodecError.payloadTooLarge
        }
        guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else {
            throw AgentInvocationPayloadCodecError.invalidPayload
        }
        return try decode(data)
    }

    private static func encodeCanonical(_ payload: AgentInvocationWirePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

public enum AgentInvocationPayloadError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidArguments
    case invalidWorkingDirectory
}

public enum AgentInvocationPayloadCodecError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
    case invalidPayload
}

private struct AgentInvocationWirePayload: Codable {
    let payload: AgentInvocationPayload

    init(payload: AgentInvocationPayload) {
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AgentInvocationRawCodingKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))
        guard actualKeys == expectedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected agent invocation fields"
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            payload = try AgentInvocationPayload(
                executable: container.decode(String.self, forKey: .executable),
                arguments: container.decode([String].self, forKey: .arguments),
                workingDirectory: container.decodeIfPresent(
                    String.self,
                    forKey: .workingDirectory
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid agent invocation payload",
                    underlyingError: error
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payload.executable, forKey: .executable)
        try container.encode(payload.arguments, forKey: .arguments)
        if let workingDirectory = payload.workingDirectory {
            try container.encode(workingDirectory, forKey: .workingDirectory)
        } else {
            try container.encodeNil(forKey: .workingDirectory)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case executable
        case arguments
        case workingDirectory
    }
}

private struct AgentInvocationRawCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
