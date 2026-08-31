import CryptoKit
import Foundation

public enum AgentIPCEventName: String, Codable, Equatable, Sendable {
    case register
    case replaceSession
    case unregister
}

public struct AgentIPCIdentity: Equatable, Sendable {
    public let instanceID: UUID
    public let paneID: UUID
    public let paneToken: String
    public let adapterID: String

    public init(
        instanceID: UUID,
        paneID: UUID,
        paneToken: String,
        adapterID: String
    ) throws {
        try AgentIPCValueValidator.validatePaneToken(paneToken)
        try AgentIPCValueValidator.validateAdapterID(adapterID)

        self.instanceID = instanceID
        self.paneID = paneID
        self.paneToken = paneToken
        self.adapterID = adapterID
    }
}

public struct AgentIPCRegisterPayload: Equatable, Sendable {
    public let identity: AgentIPCIdentity
    public let sessionID: String
    public let cwd: String
    public let metadata: [String: String]

    public init(
        identity: AgentIPCIdentity,
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    ) throws {
        try AgentIPCValueValidator.validateSessionID(sessionID)
        try AgentIPCValueValidator.validateWorkingDirectory(cwd)
        try AgentIPCValueValidator.validateMetadata(metadata)

        self.identity = identity
        self.sessionID = sessionID
        self.cwd = cwd
        self.metadata = metadata
    }
}

public struct AgentIPCReplaceSessionPayload: Equatable, Sendable {
    public let identity: AgentIPCIdentity
    public let previousSessionID: String
    public let sessionID: String
    public let cwd: String
    public let metadata: [String: String]

    public init(
        identity: AgentIPCIdentity,
        previousSessionID: String,
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    ) throws {
        try AgentIPCValueValidator.validateSessionID(previousSessionID)
        try AgentIPCValueValidator.validateSessionID(sessionID)
        try AgentIPCValueValidator.validateWorkingDirectory(cwd)
        try AgentIPCValueValidator.validateMetadata(metadata)

        self.identity = identity
        self.previousSessionID = previousSessionID
        self.sessionID = sessionID
        self.cwd = cwd
        self.metadata = metadata
    }
}

public struct AgentIPCUnregisterPayload: Equatable, Sendable {
    public let identity: AgentIPCIdentity
    public let sessionID: String

    public init(identity: AgentIPCIdentity, sessionID: String) throws {
        try AgentIPCValueValidator.validateSessionID(sessionID)

        self.identity = identity
        self.sessionID = sessionID
    }
}

public enum AgentIPCEvent: Equatable, Sendable {
    case register(AgentIPCRegisterPayload)
    case replaceSession(AgentIPCReplaceSessionPayload)
    case unregister(AgentIPCUnregisterPayload)

    public var name: AgentIPCEventName {
        switch self {
        case .register:
            .register
        case .replaceSession:
            .replaceSession
        case .unregister:
            .unregister
        }
    }
}

public struct AgentIPCMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let event: AgentIPCEvent

    public var identity: AgentIPCIdentity {
        switch event {
        case .register(let payload):
            payload.identity
        case .replaceSession(let payload):
            payload.identity
        case .unregister(let payload):
            payload.identity
        }
    }

    public init(event: AgentIPCEvent) {
        version = AgentIPCProtocol.version
        self.event = event
    }

    public init(from decoder: Decoder) throws {
        do {
            let rawContainer = try decoder.container(keyedBy: AgentIPCRawCodingKey.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let eventName = try container.decode(AgentIPCEventName.self, forKey: .event)
            let expectedKeys = Self.expectedKeys(for: eventName)
            let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))

            guard actualKeys == expectedKeys else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unexpected agent IPC fields"
                    )
                )
            }

            let version = try container.decode(Int.self, forKey: .version)
            guard version == AgentIPCProtocol.version else {
                throw AgentIPCValidationError.unsupportedVersion
            }

            let identity = try AgentIPCIdentity(
                instanceID: Self.decodeUUID(from: container, forKey: .instanceID),
                paneID: Self.decodeUUID(from: container, forKey: .paneID),
                paneToken: container.decode(String.self, forKey: .paneToken),
                adapterID: container.decode(String.self, forKey: .adapterID)
            )

            self.version = version
            switch eventName {
            case .register:
                event = .register(
                    try AgentIPCRegisterPayload(
                        identity: identity,
                        sessionID: container.decode(String.self, forKey: .sessionID),
                        cwd: container.decode(String.self, forKey: .cwd),
                        metadata: container.decode([String: String].self, forKey: .metadata)
                    )
                )
            case .replaceSession:
                event = .replaceSession(
                    try AgentIPCReplaceSessionPayload(
                        identity: identity,
                        previousSessionID: container.decode(
                            String.self,
                            forKey: .previousSessionID
                        ),
                        sessionID: container.decode(String.self, forKey: .sessionID),
                        cwd: container.decode(String.self, forKey: .cwd),
                        metadata: container.decode([String: String].self, forKey: .metadata)
                    )
                )
            case .unregister:
                event = .unregister(
                    try AgentIPCUnregisterPayload(
                        identity: identity,
                        sessionID: container.decode(String.self, forKey: .sessionID)
                    )
                )
            }
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid agent IPC message",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(event.name, forKey: .event)

        switch event {
        case .register(let payload):
            try Self.encode(payload.identity, to: &container)
            try container.encode(payload.sessionID, forKey: .sessionID)
            try container.encode(payload.cwd, forKey: .cwd)
            try container.encode(payload.metadata, forKey: .metadata)
        case .replaceSession(let payload):
            try Self.encode(payload.identity, to: &container)
            try container.encode(payload.previousSessionID, forKey: .previousSessionID)
            try container.encode(payload.sessionID, forKey: .sessionID)
            try container.encode(payload.cwd, forKey: .cwd)
            try container.encode(payload.metadata, forKey: .metadata)
        case .unregister(let payload):
            try Self.encode(payload.identity, to: &container)
            try container.encode(payload.sessionID, forKey: .sessionID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case event
        case instanceID
        case paneID
        case paneToken
        case adapterID
        case previousSessionID
        case sessionID
        case cwd
        case metadata
    }

    private static let commonKeys: Set<String> = [
        CodingKeys.version.rawValue,
        CodingKeys.event.rawValue,
        CodingKeys.instanceID.rawValue,
        CodingKeys.paneID.rawValue,
        CodingKeys.paneToken.rawValue,
        CodingKeys.adapterID.rawValue,
    ]

    private static func expectedKeys(for event: AgentIPCEventName) -> Set<String> {
        switch event {
        case .register:
            commonKeys.union([
                CodingKeys.sessionID.rawValue,
                CodingKeys.cwd.rawValue,
                CodingKeys.metadata.rawValue,
            ])
        case .replaceSession:
            commonKeys.union([
                CodingKeys.previousSessionID.rawValue,
                CodingKeys.sessionID.rawValue,
                CodingKeys.cwd.rawValue,
                CodingKeys.metadata.rawValue,
            ])
        case .unregister:
            commonKeys.union([CodingKeys.sessionID.rawValue])
        }
    }

    private static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let rawValue = try container.decode(String.self, forKey: key)
        guard rawValue.utf8.count == 36,
            let value = UUID(uuidString: rawValue),
            rawValue.lowercased() == value.uuidString.lowercased()
        else {
            throw AgentIPCValidationError.invalidUUID
        }
        return value
    }

    private static func encode(
        _ identity: AgentIPCIdentity,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(identity.instanceID.uuidString, forKey: .instanceID)
        try container.encode(identity.paneID.uuidString, forKey: .paneID)
        try container.encode(identity.paneToken, forKey: .paneToken)
        try container.encode(identity.adapterID, forKey: .adapterID)
    }
}

public struct AgentIPCPreflight: Equatable, Sendable {
    public let version: Int
    public let instanceID: UUID
    public let paneID: UUID
    public let nonce: Data

    public init(instanceID: UUID, paneID: UUID, nonce: Data) throws {
        guard nonce.count == AgentIPCProtocol.nonceSize else {
            throw AgentIPCProtocolError.invalidPreflight
        }
        version = AgentIPCProtocol.version
        self.instanceID = instanceID
        self.paneID = paneID
        self.nonce = nonce
    }

    fileprivate init(version: Int, instanceID: UUID, paneID: UUID, nonce: Data) {
        self.version = version
        self.instanceID = instanceID
        self.paneID = paneID
        self.nonce = nonce
    }
}

private struct AgentIPCWireEnvelope: Codable {
    let frameMAC: Data
    let payload: AgentIPCWirePayload

    init(frameMAC: Data, payload: AgentIPCWirePayload) {
        self.frameMAC = frameMAC
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AgentIPCRawCodingKey.self)
        guard Set(rawContainer.allKeys.map(\.stringValue)) == ["frameMAC", "payload"] else {
            throw AgentIPCProtocolError.invalidPayload
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameMAC = try container.decode(Data.self, forKey: .frameMAC)
        payload = try container.decode(AgentIPCWirePayload.self, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case frameMAC
        case payload
    }
}

private struct AgentIPCWirePayload: Codable {
    let version: Int
    let event: AgentIPCEventName
    let instanceID: UUID
    let paneID: UUID
    let adapterID: String
    let previousSessionID: String?
    let sessionID: String
    let cwd: String?
    let metadata: [String: String]?

    init(_ message: AgentIPCMessage) {
        version = message.version
        event = message.event.name
        instanceID = message.identity.instanceID
        paneID = message.identity.paneID
        adapterID = message.identity.adapterID

        switch message.event {
        case .register(let payload):
            previousSessionID = nil
            sessionID = payload.sessionID
            cwd = payload.cwd
            metadata = payload.metadata
        case .replaceSession(let payload):
            previousSessionID = payload.previousSessionID
            sessionID = payload.sessionID
            cwd = payload.cwd
            metadata = payload.metadata
        case .unregister(let payload):
            previousSessionID = nil
            sessionID = payload.sessionID
            cwd = nil
            metadata = nil
        }
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AgentIPCRawCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(AgentIPCEventName.self, forKey: .event)
        guard Set(rawContainer.allKeys.map(\.stringValue)) == Self.expectedKeys(for: event) else {
            throw AgentIPCProtocolError.invalidPayload
        }

        let version = try container.decode(Int.self, forKey: .version)
        guard version == AgentIPCProtocol.version else {
            throw AgentIPCValidationError.unsupportedVersion
        }
        let adapterID = try container.decode(String.self, forKey: .adapterID)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        try AgentIPCValueValidator.validateAdapterID(adapterID)
        try AgentIPCValueValidator.validateSessionID(sessionID)

        self.version = version
        self.event = event
        instanceID = try container.decode(UUID.self, forKey: .instanceID)
        paneID = try container.decode(UUID.self, forKey: .paneID)
        self.adapterID = adapterID
        self.sessionID = sessionID

        switch event {
        case .register:
            previousSessionID = nil
            cwd = try container.decode(String.self, forKey: .cwd)
            metadata = try container.decode([String: String].self, forKey: .metadata)
        case .replaceSession:
            previousSessionID = try container.decode(String.self, forKey: .previousSessionID)
            cwd = try container.decode(String.self, forKey: .cwd)
            metadata = try container.decode([String: String].self, forKey: .metadata)
            try AgentIPCValueValidator.validateSessionID(previousSessionID!)
        case .unregister:
            previousSessionID = nil
            cwd = nil
            metadata = nil
        }

        if let cwd {
            try AgentIPCValueValidator.validateWorkingDirectory(cwd)
        }
        if let metadata {
            try AgentIPCValueValidator.validateMetadata(metadata)
        }
    }

    func message(paneToken: String) throws -> AgentIPCMessage {
        let identity = try AgentIPCIdentity(
            instanceID: instanceID,
            paneID: paneID,
            paneToken: paneToken,
            adapterID: adapterID
        )
        switch event {
        case .register:
            return AgentIPCMessage(
                event: .register(
                    try AgentIPCRegisterPayload(
                        identity: identity,
                        sessionID: sessionID,
                        cwd: cwd!,
                        metadata: metadata!
                    )))
        case .replaceSession:
            return AgentIPCMessage(
                event: .replaceSession(
                    try AgentIPCReplaceSessionPayload(
                        identity: identity,
                        previousSessionID: previousSessionID!,
                        sessionID: sessionID,
                        cwd: cwd!,
                        metadata: metadata!
                    )))
        case .unregister:
            return AgentIPCMessage(
                event: .unregister(
                    try AgentIPCUnregisterPayload(identity: identity, sessionID: sessionID)
                ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case event
        case instanceID
        case paneID
        case adapterID
        case previousSessionID
        case sessionID
        case cwd
        case metadata
    }

    private static let commonKeys: Set<String> = [
        "version", "event", "instanceID", "paneID", "adapterID", "sessionID",
    ]

    private static func expectedKeys(for event: AgentIPCEventName) -> Set<String> {
        switch event {
        case .register:
            commonKeys.union(["cwd", "metadata"])
        case .replaceSession:
            commonKeys.union(["previousSessionID", "cwd", "metadata"])
        case .unregister:
            commonKeys
        }
    }
}

public enum AgentIPCProtocol {
    public static let version = 1
    public static let maximumPayloadSize = 65_536
    public static let nonceSize = 32
    public static let proofSize = 32
    public static let preflightSize = 76

    private static let preflightMagic = Data([0x51, 0x54, 0x54, 0x59, 0x49, 0x50, 0x43, 0x00])
    private static let proofDomain = Data("QuickTTY.AgentIPC.ServerProof.v1\0".utf8)
    private static let frameMACDomain = Data("QuickTTY.AgentIPC.FrameMAC.v1\0".utf8)

    public static func encodeFrame(
        _ message: AgentIPCMessage,
        for preflight: AgentIPCPreflight
    ) throws -> Data {
        guard message.version == version,
            message.identity.instanceID == preflight.instanceID,
            message.identity.paneID == preflight.paneID
        else {
            throw AgentIPCProtocolError.invalidPayload
        }

        let wirePayload = AgentIPCWirePayload(message)
        let canonicalPayload = try encodeCanonical(wirePayload)
        let key = try paneTokenKey(message.identity.paneToken)
        let frameMAC = Data(
            HMAC<SHA256>.authenticationCode(
                for: try frameMACInput(preflight, canonicalPayload: canonicalPayload),
                using: key
            ))
        let payload = try encodeCanonical(
            AgentIPCWireEnvelope(frameMAC: frameMAC, payload: wirePayload)
        )

        guard !payload.isEmpty else {
            throw AgentIPCProtocolError.emptyPayload
        }
        guard payload.count <= maximumPayloadSize else {
            throw AgentIPCProtocolError.payloadTooLarge
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        Swift.withUnsafeBytes(of: &length) { bytes in
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        return frame
    }

    public static func encodePreflight(_ preflight: AgentIPCPreflight) throws -> Data {
        guard preflight.version == version, preflight.nonce.count == nonceSize else {
            throw AgentIPCProtocolError.invalidPreflight
        }

        var data = Data(capacity: preflightSize)
        data.append(preflightMagic)
        appendBigEndian(UInt32(preflight.version), to: &data)
        appendUUID(preflight.instanceID, to: &data)
        appendUUID(preflight.paneID, to: &data)
        data.append(preflight.nonce)
        return data
    }

    public static func decodePreflight(_ data: Data) throws -> AgentIPCPreflight {
        guard data.count == preflightSize, data.prefix(preflightMagic.count) == preflightMagic
        else {
            throw AgentIPCProtocolError.invalidPreflight
        }

        var offset = preflightMagic.count
        let decodedVersion = Int(readUInt32(from: data, at: offset))
        offset += MemoryLayout<UInt32>.size
        guard decodedVersion == version else {
            throw AgentIPCProtocolError.invalidPreflight
        }
        let instanceID = try readUUID(from: data, at: offset)
        offset += 16
        let paneID = try readUUID(from: data, at: offset)
        offset += 16
        let nonce = Data(data[offset..<(offset + nonceSize)])
        return AgentIPCPreflight(
            version: decodedVersion,
            instanceID: instanceID,
            paneID: paneID,
            nonce: nonce
        )
    }

    public static func makeServerProof(
        for preflight: AgentIPCPreflight,
        paneToken: String
    ) throws -> Data {
        let key = try paneTokenKey(paneToken)
        return Data(HMAC<SHA256>.authenticationCode(for: proofInput(preflight), using: key))
    }

    public static func verifyServerProof(
        _ proof: Data,
        for preflight: AgentIPCPreflight,
        paneToken: String
    ) -> Bool {
        guard proof.count == proofSize, let key = try? paneTokenKey(paneToken) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: proofInput(preflight),
            using: key
        )
    }

    public static func decodeFrame(
        _ frame: Data,
        for preflight: AgentIPCPreflight,
        paneToken: String
    ) throws -> AgentIPCMessage {
        let headerSize = MemoryLayout<UInt32>.size
        guard frame.count >= headerSize else {
            throw AgentIPCProtocolError.truncatedHeader
        }

        let declaredLength = frame.prefix(headerSize).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard declaredLength > 0 else {
            throw AgentIPCProtocolError.emptyPayload
        }
        guard declaredLength <= UInt32(maximumPayloadSize) else {
            throw AgentIPCProtocolError.payloadTooLarge
        }

        let expectedCount = headerSize + Int(declaredLength)
        guard frame.count >= expectedCount else {
            throw AgentIPCProtocolError.truncatedPayload
        }
        guard frame.count == expectedCount else {
            throw AgentIPCProtocolError.trailingBytes
        }

        let payloadStart = frame.index(frame.startIndex, offsetBy: headerSize)
        let payload = Data(frame[payloadStart...])
        do {
            let envelope = try JSONDecoder().decode(AgentIPCWireEnvelope.self, from: payload)
            guard envelope.frameMAC.count == proofSize,
                try encodeCanonical(envelope) == payload,
                envelope.payload.instanceID == preflight.instanceID,
                envelope.payload.paneID == preflight.paneID
            else {
                throw AgentIPCProtocolError.invalidPayload
            }

            let canonicalPayload = try encodeCanonical(envelope.payload)
            let key = try paneTokenKey(paneToken)
            guard
                HMAC<SHA256>.isValidAuthenticationCode(
                    envelope.frameMAC,
                    authenticating: try frameMACInput(
                        preflight,
                        canonicalPayload: canonicalPayload
                    ),
                    using: key
                )
            else {
                throw AgentIPCProtocolError.invalidPayload
            }
            return try envelope.payload.message(paneToken: paneToken)
        } catch {
            throw AgentIPCProtocolError.invalidPayload
        }
    }

    private static func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func proofInput(_ preflight: AgentIPCPreflight) -> Data {
        var data = Data(capacity: proofDomain.count + nonceSize + 36)
        data.append(proofDomain)
        data.append(preflight.nonce)
        appendBigEndian(UInt32(preflight.version), to: &data)
        appendUUID(preflight.instanceID, to: &data)
        appendUUID(preflight.paneID, to: &data)
        return data
    }

    private static func frameMACInput(
        _ preflight: AgentIPCPreflight,
        canonicalPayload: Data
    ) throws -> Data {
        var data = Data(capacity: frameMACDomain.count + preflightSize + canonicalPayload.count)
        data.append(frameMACDomain)
        data.append(try encodePreflight(preflight))
        data.append(canonicalPayload)
        return data
    }

    private static func paneTokenKey(_ paneToken: String) throws -> SymmetricKey {
        try AgentIPCValueValidator.validatePaneToken(paneToken)
        let bytes = Array(paneToken.utf8)
        var key = Data(capacity: 32)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexadecimalValue(bytes[index]),
                let low = hexadecimalValue(bytes[index + 1])
            else {
                throw AgentIPCValidationError.invalidPaneToken
            }
            key.append((high << 4) | low)
        }
        return SymmetricKey(data: key)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        default:
            nil
        }
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendUUID(_ value: UUID, to data: inout Data) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + MemoryLayout<UInt32>.size)].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private static func readUUID(from data: Data, at offset: Int) throws -> UUID {
        let bytes = Array(data[offset..<(offset + 16)])
        guard bytes.count == 16 else {
            throw AgentIPCProtocolError.invalidPreflight
        }
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

public enum AgentIPCProtocolError: Error, Equatable, Sendable {
    case invalidPreflight
    case truncatedHeader
    case emptyPayload
    case payloadTooLarge
    case truncatedPayload
    case trailingBytes
    case invalidPayload
}

public enum AgentIPCValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidUUID
    case invalidPaneToken
    case invalidAdapterID
    case invalidSessionID
    case invalidWorkingDirectory
    case invalidMetadata
}

enum AgentIPCValueValidator {
    static func validatePaneToken(_ paneToken: String) throws {
        let bytes = paneToken.utf8
        guard bytes.count == 64,
            bytes.allSatisfy({ byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            })
        else {
            throw AgentIPCValidationError.invalidPaneToken
        }
    }

    static func validateAdapterID(_ adapterID: String) throws {
        let bytes = adapterID.utf8
        guard (1...64).contains(bytes.count),
            bytes.allSatisfy(isValidStableIDByte),
            bytes.first != UInt8(ascii: "-"),
            bytes.last != UInt8(ascii: "-")
        else {
            throw AgentIPCValidationError.invalidAdapterID
        }
    }

    static func validateSessionID(_ sessionID: String) throws {
        guard (1...512).contains(sessionID.utf8.count), !sessionID.containsIPCControlCharacter
        else {
            throw AgentIPCValidationError.invalidSessionID
        }
    }

    static func validateWorkingDirectory(_ workingDirectory: String) throws {
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(workingDirectory) else {
            throw AgentIPCValidationError.invalidWorkingDirectory
        }
    }

    static func validateMetadata(_ metadata: [String: String]) throws {
        guard metadata.count <= 16 else {
            throw AgentIPCValidationError.invalidMetadata
        }

        var totalBytes = 0
        for (key, value) in metadata {
            let keyBytes = key.utf8
            guard (1...64).contains(keyBytes.count),
                keyBytes.allSatisfy(isValidMetadataKeyByte),
                !isForbiddenMetadataKey(key),
                value.utf8.count <= 1_024,
                !value.containsIPCControlCharacter
            else {
                throw AgentIPCValidationError.invalidMetadata
            }
            totalBytes += keyBytes.count + value.utf8.count
        }

        guard totalBytes <= 8_192 else {
            throw AgentIPCValidationError.invalidMetadata
        }
    }

    static func isValidStableID(_ value: String) -> Bool {
        (try? validateAdapterID(value)) != nil
    }

    private static func isValidStableIDByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-")
    }

    private static func isValidMetadataKeyByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")].contains(byte)
    }

    private static func isForbiddenMetadataKey(_ key: String) -> Bool {
        let normalizedKey = key.lowercased().filter { character in
            character != "." && character != "_" && character != "-"
        }
        return [
            "token", "secret", "password", "credential", "apikey", "socket", "instance",
            "command", "argv", "environment",
        ].contains { normalizedKey.contains($0) }
    }
}

private struct AgentIPCRawCodingKey: CodingKey {
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
    var containsIPCControlCharacter: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
