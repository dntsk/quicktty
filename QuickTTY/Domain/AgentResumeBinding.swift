import Foundation

struct AgentAdapterID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let bytes = rawValue.utf8
        guard (1...64).contains(bytes.count),
            bytes.allSatisfy({ byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-")
            }),
            bytes.first != UInt8(ascii: "-"),
            bytes.last != UInt8(ascii: "-")
        else {
            throw AgentResumeBindingValidationError.invalidAdapterID
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue: rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid agent adapter ID"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentResumeDiagnosticCode: String, Codable, CaseIterable, Equatable, Sendable {
    case missingAdapter
    case unsupportedVersion
    case invalidSessionID
    case invalidMetadata
    case duplicateBinding
    case missingExecutable
    case surfaceCreation
    case immediateExit
    case interruptedRestore
}

enum AgentResumeState: Codable, Equatable, Sendable {
    case active
    case restoring
    case unverified
    case failed(diagnosticCode: AgentResumeDiagnosticCode, failedAt: Date)

    private enum Kind: String, Codable {
        case active
        case restoring
        case unverified
        case failed
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case diagnosticCode
        case failedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let expectedKeys: Set<String>

        switch kind {
        case .active:
            self = .active
            expectedKeys = [CodingKeys.kind.rawValue]
        case .restoring:
            self = .restoring
            expectedKeys = [CodingKeys.kind.rawValue]
        case .unverified:
            self = .unverified
            expectedKeys = [CodingKeys.kind.rawValue]
        case .failed:
            self = .failed(
                diagnosticCode: try container.decode(
                    AgentResumeDiagnosticCode.self,
                    forKey: .diagnosticCode
                ),
                failedAt: try container.decode(Date.self, forKey: .failedAt)
            )
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.diagnosticCode.rawValue,
                CodingKeys.failedAt.rawValue,
            ]
        }

        let rawContainer = try decoder.container(keyedBy: AgentResumeRawCodingKey.self)
        let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))
        guard actualKeys == expectedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected agent resume state fields"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode(Kind.active, forKey: .kind)
        case .restoring:
            try container.encode(Kind.restoring, forKey: .kind)
        case .unverified:
            try container.encode(Kind.unverified, forKey: .kind)
        case .failed(let diagnosticCode, let failedAt):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(diagnosticCode, forKey: .diagnosticCode)
            try container.encode(failedAt, forKey: .failedAt)
        }
    }
}

struct AgentResumeBinding: Codable, Equatable, Sendable {
    let adapterID: AgentAdapterID
    let sessionID: String
    let workingDirectory: String
    let registeredAt: Date
    let launchMetadata: [String: String]
    private(set) var restoreState: AgentResumeState

    private enum CodingKeys: String, CodingKey {
        case adapterID
        case sessionID
        case workingDirectory
        case registeredAt
        case launchMetadata
        case restoreState
    }

    init(
        adapterID: AgentAdapterID,
        sessionID: String,
        workingDirectory: String,
        registeredAt: Date,
        launchMetadata: [String: String],
        restoreState: AgentResumeState
    ) throws {
        try Self.validateSessionID(sessionID)
        try Self.validateWorkingDirectory(workingDirectory)
        try Self.validateLaunchMetadata(launchMetadata)

        self.adapterID = adapterID
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.registeredAt = registeredAt
        self.launchMetadata = launchMetadata
        self.restoreState = restoreState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                adapterID: container.decode(AgentAdapterID.self, forKey: .adapterID),
                sessionID: container.decode(String.self, forKey: .sessionID),
                workingDirectory: container.decode(String.self, forKey: .workingDirectory),
                registeredAt: container.decode(Date.self, forKey: .registeredAt),
                launchMetadata: container.decode(
                    [String: String].self,
                    forKey: .launchMetadata
                ),
                restoreState: container.decode(AgentResumeState.self, forKey: .restoreState)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid persisted agent resume binding",
                    underlyingError: error
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(registeredAt, forKey: .registeredAt)
        try container.encode(launchMetadata, forKey: .launchMetadata)
        try container.encode(restoreState, forKey: .restoreState)
    }

    func updatingRestoreState(_ restoreState: AgentResumeState) -> AgentResumeBinding {
        var binding = self
        binding.restoreState = restoreState
        return binding
    }

    private static func validateSessionID(_ sessionID: String) throws {
        guard (1...512).contains(sessionID.utf8.count), !sessionID.containsControlCharacter
        else {
            throw AgentResumeBindingValidationError.invalidSessionID
        }
    }

    private static func validateWorkingDirectory(_ workingDirectory: String) throws {
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(workingDirectory) else {
            throw AgentResumeBindingValidationError.invalidWorkingDirectory
        }
    }

    private static func validateLaunchMetadata(_ launchMetadata: [String: String]) throws {
        guard launchMetadata.count <= 16 else {
            throw AgentResumeBindingValidationError.invalidLaunchMetadata
        }

        var payloadBytes = 0
        for (key, value) in launchMetadata {
            let keyBytes = key.utf8
            guard (1...64).contains(keyBytes.count),
                keyBytes.allSatisfy(Self.isValidMetadataKeyByte),
                !Self.isSecretLikeMetadataKey(key),
                value.utf8.count <= 1_024,
                !value.containsControlCharacter
            else {
                throw AgentResumeBindingValidationError.invalidLaunchMetadata
            }
            payloadBytes += keyBytes.count + value.utf8.count
        }

        guard payloadBytes <= 8_192 else {
            throw AgentResumeBindingValidationError.invalidLaunchMetadata
        }
    }

    private static func isValidMetadataKeyByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")].contains(byte)
    }

    private static func isSecretLikeMetadataKey(_ key: String) -> Bool {
        let normalizedKey = key.lowercased().filter { character in
            character != "." && character != "_" && character != "-"
        }
        return [
            "token", "secret", "password", "credential", "apikey", "socket", "instance", "argv",
            "environment",
        ].contains {
            normalizedKey.contains($0)
        }
    }
}

private enum AgentResumeBindingValidationError: Error {
    case invalidAdapterID
    case invalidSessionID
    case invalidWorkingDirectory
    case invalidLaunchMetadata
}

private struct AgentResumeRawCodingKey: CodingKey {
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

extension String {
    fileprivate var containsControlCharacter: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
