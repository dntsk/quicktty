import CryptoKit
import Foundation

public struct TerminalControlPreflight: Equatable, Sendable {
    public let version: Int
    public let instanceID: UUID
    public let paneID: UUID
    public let nonce: Data

    public init(instanceID: UUID, paneID: UUID, nonce: Data) throws {
        guard nonce.count == TerminalControlProtocol.nonceSize else {
            throw TerminalControlProtocolError.invalidPreflight
        }
        version = TerminalControlProtocol.version
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

public enum TerminalControlProtocol {
    public static let version = 1
    public static let maximumRequestSize = 128 * 1_024
    public static let maximumResponseSize = 512 * 1_024
    public static let maximumArgumentCount = 256
    public static let maximumArgumentSize = 4_096
    public static let maximumAggregateArgumentSize = 32_768
    public static let maximumPathSize = AgentWorkingDirectoryValidator.maximumPathSize
    public static let maximumTextSize = 4_096
    public static let maximumSnapshotSize = 64 * 1_024
    public static let minimumTimeoutMilliseconds = 100
    public static let maximumTimeoutMilliseconds = 30_000
    public static let minimumRatio = 0.1
    public static let maximumRatio = 0.9
    public static let nonceSize = 32
    public static let challengeSize = 32
    public static let authenticationCodeSize = 32
    public static let preflightSize = 76
    static let authenticatedFrameOverhead =
        MemoryLayout<UInt32>.size + authenticationCodeSize
    static let maximumRequestPayloadSize = maximumRequestSize - authenticatedFrameOverhead
    static let maximumResponsePayloadSize = maximumResponseSize - authenticatedFrameOverhead

    public static let preflightMagic = Data([
        0x51, 0x54, 0x54, 0x59, 0x43, 0x54, 0x4C, 0x00,
    ])
    public static let serverProofDomain = Data("QuickTTY.TerminalControl.ServerProof.v1\0".utf8)
    public static let requestFrameMACDomain = Data(
        "QuickTTY.TerminalControl.RequestFrameMAC.v1\0".utf8
    )
    public static let responseFrameMACDomain = Data(
        "QuickTTY.TerminalControl.ResponseFrameMAC.v1\0".utf8
    )

    public static func encodeRequest(_ request: TerminalControlRequest) throws -> Data {
        guard request.version == version else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let data = try encodeCanonical(TerminalControlRequestWire(request))
        guard !data.isEmpty else {
            throw TerminalControlProtocolError.emptyPayload
        }
        guard data.count <= maximumRequestPayloadSize else {
            throw TerminalControlProtocolError.requestTooLarge
        }
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> TerminalControlRequest {
        guard !data.isEmpty else {
            throw TerminalControlProtocolError.emptyPayload
        }
        guard data.count <= maximumRequestPayloadSize else {
            throw TerminalControlProtocolError.requestTooLarge
        }

        do {
            let wire = try JSONDecoder().decode(TerminalControlRequestWire.self, from: data)
            guard try encodeCanonical(wire) == data else {
                throw TerminalControlProtocolError.invalidPayload
            }
            return wire.request
        } catch let error as TerminalControlProtocolError {
            throw error
        } catch {
            throw TerminalControlProtocolError.invalidPayload
        }
    }

    public static func encodeResponse(_ response: TerminalControlResponse) throws -> Data {
        guard response.version == version else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let data = try encodeCanonical(TerminalControlResponseWire(response))
        guard !data.isEmpty else {
            throw TerminalControlProtocolError.emptyPayload
        }
        guard data.count <= maximumResponsePayloadSize else {
            throw TerminalControlProtocolError.responseTooLarge
        }
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> TerminalControlResponse {
        guard !data.isEmpty else {
            throw TerminalControlProtocolError.emptyPayload
        }
        guard data.count <= maximumResponsePayloadSize else {
            throw TerminalControlProtocolError.responseTooLarge
        }

        do {
            let wire = try JSONDecoder().decode(TerminalControlResponseWire.self, from: data)
            guard try encodeCanonical(wire) == data else {
                throw TerminalControlProtocolError.invalidPayload
            }
            return wire.response
        } catch let error as TerminalControlProtocolError {
            throw error
        } catch {
            throw TerminalControlProtocolError.invalidPayload
        }
    }

    public static func encodePreflight(_ preflight: TerminalControlPreflight) throws -> Data {
        guard preflight.version == version, preflight.nonce.count == nonceSize else {
            throw TerminalControlProtocolError.invalidPreflight
        }

        var data = Data(capacity: preflightSize)
        data.append(preflightMagic)
        appendBigEndian(UInt32(preflight.version), to: &data)
        appendUUID(preflight.instanceID, to: &data)
        appendUUID(preflight.paneID, to: &data)
        data.append(preflight.nonce)
        return data
    }

    public static func decodePreflight(_ data: Data) throws -> TerminalControlPreflight {
        guard data.count == preflightSize,
            data.prefix(preflightMagic.count) == preflightMagic
        else {
            throw TerminalControlProtocolError.invalidPreflight
        }

        var offset = preflightMagic.count
        let decodedVersion = Int(readUInt32(from: data, at: offset))
        offset += MemoryLayout<UInt32>.size
        guard decodedVersion == version else {
            throw TerminalControlProtocolError.invalidPreflight
        }
        let instanceID = try readUUID(from: data, at: offset)
        offset += 16
        let paneID = try readUUID(from: data, at: offset)
        offset += 16
        let nonce = Data(data[offset..<(offset + nonceSize)])
        return TerminalControlPreflight(
            version: decodedVersion,
            instanceID: instanceID,
            paneID: paneID,
            nonce: nonce
        )
    }

    public static func serverProofAuthenticationData(
        for preflight: TerminalControlPreflight,
        challenge: Data
    ) throws -> Data {
        var data = Data(capacity: serverProofDomain.count + 100)
        data.append(serverProofDomain)
        try appendAuthenticationContext(preflight, to: &data)
        try appendChallenge(challenge, to: &data)
        return data
    }

    public static func makeServerProof(
        for preflight: TerminalControlPreflight,
        challenge: Data,
        paneToken: String
    ) throws -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: try serverProofAuthenticationData(
                    for: preflight,
                    challenge: challenge
                ),
                using: try paneTokenKey(paneToken)
            )
        )
    }

    public static func verifyServerProof(
        _ proof: Data,
        for preflight: TerminalControlPreflight,
        challenge: Data,
        paneToken: String
    ) -> Bool {
        guard proof.count == authenticationCodeSize,
            let key = try? paneTokenKey(paneToken),
            let authenticationData = try? serverProofAuthenticationData(
                for: preflight,
                challenge: challenge
            )
        else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: authenticationData,
            using: key
        )
    }

    public static func requestFrameAuthenticationData(
        for preflight: TerminalControlPreflight,
        challenge: Data,
        canonicalRequest: Data
    ) throws -> Data {
        _ = try decodeRequest(canonicalRequest)
        var data = Data(capacity: requestFrameMACDomain.count + 104 + canonicalRequest.count)
        data.append(requestFrameMACDomain)
        try appendAuthenticationContext(preflight, to: &data)
        try appendChallenge(challenge, to: &data)
        appendBigEndian(UInt32(canonicalRequest.count), to: &data)
        data.append(canonicalRequest)
        return data
    }

    public static func responseFrameAuthenticationData(
        for preflight: TerminalControlPreflight,
        challenge: Data,
        canonicalRequest: Data,
        canonicalResponse: Data
    ) throws -> Data {
        let request = try decodeRequest(canonicalRequest)
        _ = try decodeResponse(canonicalResponse)
        let requestDigest = SHA256.hash(data: canonicalRequest)
        var data = Data(
            capacity: responseFrameMACDomain.count + 137 + canonicalResponse.count
        )
        data.append(responseFrameMACDomain)
        try appendAuthenticationContext(preflight, to: &data)
        try appendChallenge(challenge, to: &data)
        if let requestID = request.requestID {
            data.append(1)
            appendUUID(requestID, to: &data)
        } else {
            data.append(0)
        }
        data.append(contentsOf: requestDigest)
        appendBigEndian(UInt32(canonicalResponse.count), to: &data)
        data.append(canonicalResponse)
        return data
    }

    public static func encodeRequestFrame(
        _ request: TerminalControlRequest,
        for preflight: TerminalControlPreflight,
        challenge: Data,
        paneToken: String
    ) throws -> Data {
        let payload = try encodeRequest(request)
        let authenticationCode = Data(
            HMAC<SHA256>.authenticationCode(
                for: try requestFrameAuthenticationData(
                    for: preflight,
                    challenge: challenge,
                    canonicalRequest: payload
                ),
                using: try paneTokenKey(paneToken)
            )
        )
        return try lengthPrefixedFrame(
            payload: payload,
            authenticationCode: authenticationCode,
            maximumFrameSize: maximumRequestSize
        )
    }

    public static func decodeRequestFrame(
        _ frame: Data,
        for preflight: TerminalControlPreflight,
        challenge: Data,
        paneToken: String
    ) throws -> TerminalControlRequest {
        let payloadAndCode = try decodeFrame(frame, maximumFrameSize: maximumRequestSize)
        let authenticationData = try requestFrameAuthenticationData(
            for: preflight,
            challenge: challenge,
            canonicalRequest: payloadAndCode.payload
        )
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                payloadAndCode.authenticationCode,
                authenticating: authenticationData,
                using: try paneTokenKey(paneToken)
            )
        else {
            throw TerminalControlProtocolError.authenticationFailed
        }
        return try decodeRequest(payloadAndCode.payload)
    }

    public static func encodeResponseFrame(
        _ response: TerminalControlResponse,
        for preflight: TerminalControlPreflight,
        challenge: Data,
        request: TerminalControlRequest,
        paneToken: String
    ) throws -> Data {
        let canonicalRequest = try encodeRequest(request)
        let payload = try encodeResponse(response)
        let authenticationCode = Data(
            HMAC<SHA256>.authenticationCode(
                for: try responseFrameAuthenticationData(
                    for: preflight,
                    challenge: challenge,
                    canonicalRequest: canonicalRequest,
                    canonicalResponse: payload
                ),
                using: try paneTokenKey(paneToken)
            )
        )
        return try lengthPrefixedFrame(
            payload: payload,
            authenticationCode: authenticationCode,
            maximumFrameSize: maximumResponseSize
        )
    }

    public static func decodeResponseFrame(
        _ frame: Data,
        for preflight: TerminalControlPreflight,
        challenge: Data,
        request: TerminalControlRequest,
        paneToken: String
    ) throws -> TerminalControlResponse {
        let payloadAndCode = try decodeFrame(frame, maximumFrameSize: maximumResponseSize)
        let authenticationData = try responseFrameAuthenticationData(
            for: preflight,
            challenge: challenge,
            canonicalRequest: encodeRequest(request),
            canonicalResponse: payloadAndCode.payload
        )
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                payloadAndCode.authenticationCode,
                authenticating: authenticationData,
                using: try paneTokenKey(paneToken)
            )
        else {
            throw TerminalControlProtocolError.authenticationFailed
        }
        return try decodeResponse(payloadAndCode.payload)
    }

    private static func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func lengthPrefixedFrame(
        payload: Data,
        authenticationCode: Data,
        maximumFrameSize: Int
    ) throws -> Data {
        guard authenticationCode.count == authenticationCodeSize,
            !payload.isEmpty,
            payload.count <= maximumFrameSize - authenticatedFrameOverhead
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: authenticatedFrameOverhead + payload.count)
        Swift.withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        frame.append(authenticationCode)
        return frame
    }

    private static func decodeFrame(
        _ frame: Data,
        maximumFrameSize: Int
    ) throws -> (payload: Data, authenticationCode: Data) {
        let headerSize = MemoryLayout<UInt32>.size
        guard frame.count >= authenticatedFrameOverhead,
            frame.count <= maximumFrameSize
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let declaredLength = frame.prefix(headerSize).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard declaredLength > 0,
            declaredLength <= UInt32(maximumFrameSize - authenticatedFrameOverhead)
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let payloadCount = Int(declaredLength)
        guard frame.count == authenticatedFrameOverhead + payloadCount else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let payloadStart = frame.index(frame.startIndex, offsetBy: headerSize)
        let payloadEnd = frame.index(payloadStart, offsetBy: payloadCount)
        return (
            Data(frame[payloadStart..<payloadEnd]),
            Data(frame[payloadEnd..<frame.endIndex])
        )
    }

    private static func paneTokenKey(_ paneToken: String) throws -> SymmetricKey {
        try AgentIPCValueValidator.validatePaneToken(paneToken)
        var key = Data(capacity: 32)
        let bytes = Array(paneToken.utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexadecimalValue(bytes[index]),
                let low = hexadecimalValue(bytes[index + 1])
            else {
                throw TerminalControlProtocolError.invalidPayload
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

    private static func appendAuthenticationContext(
        _ preflight: TerminalControlPreflight,
        to data: inout Data
    ) throws {
        guard preflight.version == version, preflight.nonce.count == nonceSize else {
            throw TerminalControlProtocolError.invalidPreflight
        }
        appendBigEndian(UInt32(preflight.version), to: &data)
        appendUUID(preflight.instanceID, to: &data)
        appendUUID(preflight.paneID, to: &data)
        data.append(preflight.nonce)
    }

    private static func appendChallenge(_ challenge: Data, to data: inout Data) throws {
        guard challenge.count == challengeSize else {
            throw TerminalControlProtocolError.invalidPayload
        }
        data.append(challenge)
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
            throw TerminalControlProtocolError.invalidPreflight
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

public enum TerminalControlProtocolError: Error, Equatable, Sendable {
    case invalidPreflight
    case emptyPayload
    case requestTooLarge
    case responseTooLarge
    case invalidPayload
    case authenticationFailed
}

private enum TerminalControlOperationName: String, Codable {
    case list
    case createTab = "create-tab"
    case split
    case read
    case wait
    case sendText = "send-text"
    case sendKey = "send-key"
    case requestUserInput = "request-user-input"
    case focus
    case resize
    case interrupt
    case close
}

private struct TerminalControlRequestWire: Codable {
    let request: TerminalControlRequest

    init(_ request: TerminalControlRequest) {
        self.request = request
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: TerminalControlRawCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operationName = try container.decode(
            TerminalControlOperationName.self, forKey: .operation)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == TerminalControlProtocol.version else {
            throw TerminalControlProtocolError.invalidPayload
        }

        let operation: TerminalControlRequest.Operation
        switch operationName {
        case .list:
            operation = .list
        case .createTab:
            operation = .createTab(
                launch: try container.decode(TerminalControlLaunchWire.self, forKey: .launch)
                    .launch,
                policy: try container.decode(TerminalTaskLifecyclePolicy.self, forKey: .policy),
                focus: try container.decode(Bool.self, forKey: .focus)
            )
        case .split:
            operation = .split(
                anchorPaneID: try Self.decodeOptionalUUID(from: container, forKey: .anchorPaneID),
                direction: try container.decode(TerminalSplitDirection.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                launch: try container.decode(TerminalControlLaunchWire.self, forKey: .launch)
                    .launch,
                policy: try container.decode(TerminalTaskLifecyclePolicy.self, forKey: .policy),
                focus: try container.decode(Bool.self, forKey: .focus)
            )
        case .read:
            operation = .read(taskID: try Self.decodeUUID(from: container, forKey: .taskID))
        case .wait:
            operation = .wait(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID),
                revision: try container.decode(UInt64.self, forKey: .revision),
                timeoutMilliseconds: try container.decode(Int.self, forKey: .timeoutMilliseconds)
            )
        case .sendText:
            operation = .sendText(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID),
                expectedRevision: try container.decode(UInt64.self, forKey: .expectedRevision),
                text: try container.decode(String.self, forKey: .text)
            )
        case .sendKey:
            operation = .sendKey(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID),
                expectedRevision: try container.decode(UInt64.self, forKey: .expectedRevision),
                key: try container.decode(TerminalControlKey.self, forKey: .key)
            )
        case .requestUserInput:
            operation = .requestUserInput(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID)
            )
        case .focus:
            operation = .focus(taskID: try Self.decodeUUID(from: container, forKey: .taskID))
        case .resize:
            operation = .resize(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID),
                ratio: try container.decode(Double.self, forKey: .ratio)
            )
        case .interrupt:
            operation = .interrupt(
                taskID: try Self.decodeUUID(from: container, forKey: .taskID),
                expectedRevision: try container.decode(UInt64.self, forKey: .expectedRevision)
            )
        case .close:
            operation = .close(taskID: try Self.decodeUUID(from: container, forKey: .taskID))
        }

        guard
            Set(rawContainer.allKeys.map(\.stringValue))
                == Self.expectedKeys(
                    for: operationName,
                    requiresRequestID: operation.requiresRequestID
                )
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let requestID =
            operation.requiresRequestID
            ? try Self.decodeUUID(from: container, forKey: .requestID)
            : nil
        request = try TerminalControlRequest(operation: operation, requestID: requestID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request.version, forKey: .version)
        if let requestID = request.requestID {
            try container.encode(requestID.uuidString, forKey: .requestID)
        }

        switch request.operation {
        case .list:
            try container.encode(TerminalControlOperationName.list, forKey: .operation)
        case .createTab(let launch, let policy, let focus):
            try container.encode(TerminalControlOperationName.createTab, forKey: .operation)
            try container.encode(TerminalControlLaunchWire(launch), forKey: .launch)
            try container.encode(policy, forKey: .policy)
            try container.encode(focus, forKey: .focus)
        case .split(let anchorPaneID, let direction, let ratio, let launch, let policy, let focus):
            try container.encode(TerminalControlOperationName.split, forKey: .operation)
            if let anchorPaneID {
                try container.encode(anchorPaneID.uuidString, forKey: .anchorPaneID)
            } else {
                try container.encodeNil(forKey: .anchorPaneID)
            }
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(TerminalControlLaunchWire(launch), forKey: .launch)
            try container.encode(policy, forKey: .policy)
            try container.encode(focus, forKey: .focus)
        case .read(let taskID):
            try container.encode(TerminalControlOperationName.read, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
        case .wait(let taskID, let revision, let timeoutMilliseconds):
            try container.encode(TerminalControlOperationName.wait, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(revision, forKey: .revision)
            try container.encode(timeoutMilliseconds, forKey: .timeoutMilliseconds)
        case .sendText(let taskID, let expectedRevision, let text):
            try container.encode(TerminalControlOperationName.sendText, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(text, forKey: .text)
        case .sendKey(let taskID, let expectedRevision, let key):
            try container.encode(TerminalControlOperationName.sendKey, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(key, forKey: .key)
        case .requestUserInput(let taskID):
            try container.encode(TerminalControlOperationName.requestUserInput, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
        case .focus(let taskID):
            try container.encode(TerminalControlOperationName.focus, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
        case .resize(let taskID, let ratio):
            try container.encode(TerminalControlOperationName.resize, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(ratio, forKey: .ratio)
        case .interrupt(let taskID, let expectedRevision):
            try container.encode(TerminalControlOperationName.interrupt, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(expectedRevision, forKey: .expectedRevision)
        case .close(let taskID):
            try container.encode(TerminalControlOperationName.close, forKey: .operation)
            try container.encode(taskID.uuidString, forKey: .taskID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case operation
        case requestID
        case launch
        case policy
        case focus
        case anchorPaneID
        case direction
        case ratio
        case taskID
        case revision
        case timeoutMilliseconds
        case expectedRevision
        case text
        case key
    }

    private static let commonKeys: Set<String> = ["version", "operation"]

    private static func expectedKeys(
        for operation: TerminalControlOperationName,
        requiresRequestID: Bool
    ) -> Set<String> {
        var keys = commonKeys
        if requiresRequestID {
            keys.insert("requestID")
        }
        switch operation {
        case .list:
            return keys
        case .createTab:
            return keys.union(["launch", "policy", "focus"])
        case .split:
            return keys.union(["anchorPaneID", "direction", "ratio", "launch", "policy", "focus"])
        case .read:
            return keys.union(["taskID"])
        case .wait:
            return keys.union(["taskID", "revision", "timeoutMilliseconds"])
        case .sendText:
            return keys.union(["taskID", "expectedRevision", "text"])
        case .sendKey:
            return keys.union(["taskID", "expectedRevision", "key"])
        case .requestUserInput, .focus, .close:
            return keys.union(["taskID"])
        case .resize:
            return keys.union(["taskID", "ratio"])
        case .interrupt:
            return keys.union(["taskID", "expectedRevision"])
        }
    }

    private static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        try TerminalControlUUIDCodec.decode(container.decode(String.self, forKey: key))
    }

    private static func decodeOptionalUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID? {
        guard try !container.decodeNil(forKey: key) else { return nil }
        return try decodeUUID(from: container, forKey: key)
    }
}

private struct TerminalControlLaunchWire: Codable {
    let launch: TerminalControlLaunch

    init(_ launch: TerminalControlLaunch) {
        self.launch = launch
    }

    init(from decoder: Decoder) throws {
        try TerminalControlCodingValidator.requireExactKeys(
            decoder,
            expected: ["executable", "arguments", "cwd"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launch = try TerminalControlLaunch(
            executable: container.decode(String.self, forKey: .executable),
            arguments: container.decode([String].self, forKey: .arguments),
            cwd: container.decode(String.self, forKey: .cwd)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launch.executable, forKey: .executable)
        try container.encode(launch.arguments, forKey: .arguments)
        try container.encode(launch.cwd, forKey: .cwd)
    }

    private enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case cwd
    }
}

private enum TerminalControlResponseName: String, Codable {
    case list
    case task
    case snapshot
    case acknowledged
    case error
}

private struct TerminalControlResponseWire: Codable {
    let response: TerminalControlResponse

    init(_ response: TerminalControlResponse) throws {
        if case .list(_, let tasks) = response.result,
            tasks.count > TerminalControlLimits.maximumRetainedTaskCount
        {
            throw TerminalControlValidationError.tooManyTasks
        }
        self.response = response
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: TerminalControlRawCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseName = try container.decode(TerminalControlResponseName.self, forKey: .response)
        guard Set(rawContainer.allKeys.map(\.stringValue)) == Self.expectedKeys(for: responseName)
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard version == TerminalControlProtocol.version else {
            throw TerminalControlProtocolError.invalidPayload
        }

        let result: TerminalControlResponse.Result
        switch responseName {
        case .list:
            let tasks = try container.decode([TerminalControlTaskWire].self, forKey: .tasks).map(
                \.task)
            guard tasks.count <= TerminalControlLimits.maximumRetainedTaskCount else {
                throw TerminalControlValidationError.tooManyTasks
            }
            result = .list(
                workspace: try container.decode(
                    TerminalControlWorkspaceMetadataWire.self,
                    forKey: .workspace
                ).metadata,
                tasks: tasks
            )
        case .task:
            result = .task(try container.decode(TerminalControlTaskWire.self, forKey: .task).task)
        case .snapshot:
            result = .snapshot(
                try container.decode(TerminalControlSnapshotWire.self, forKey: .snapshot).snapshot
            )
        case .acknowledged:
            result = .acknowledged(
                taskID: try TerminalControlUUIDCodec.decode(
                    container.decode(String.self, forKey: .taskID)
                ),
                revision: try container.decode(UInt64.self, forKey: .revision)
            )
        case .error:
            result = .failure(
                try container.decode(TerminalControlErrorWire.self, forKey: .error).error
            )
        }
        response = TerminalControlResponse(result: result)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(response.version, forKey: .version)
        switch response.result {
        case .list(let workspace, let tasks):
            try container.encode(TerminalControlResponseName.list, forKey: .response)
            try container.encode(
                TerminalControlWorkspaceMetadataWire(workspace), forKey: .workspace)
            try container.encode(tasks.map(TerminalControlTaskWire.init), forKey: .tasks)
        case .task(let task):
            try container.encode(TerminalControlResponseName.task, forKey: .response)
            try container.encode(TerminalControlTaskWire(task), forKey: .task)
        case .snapshot(let snapshot):
            try container.encode(TerminalControlResponseName.snapshot, forKey: .response)
            try container.encode(TerminalControlSnapshotWire(snapshot), forKey: .snapshot)
        case .acknowledged(let taskID, let revision):
            try container.encode(TerminalControlResponseName.acknowledged, forKey: .response)
            try container.encode(taskID.uuidString, forKey: .taskID)
            try container.encode(revision, forKey: .revision)
        case .failure(let error):
            try container.encode(TerminalControlResponseName.error, forKey: .response)
            try container.encode(TerminalControlErrorWire(error), forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case response
        case workspace
        case tasks
        case task
        case snapshot
        case taskID
        case revision
        case error
    }

    private static func expectedKeys(for response: TerminalControlResponseName) -> Set<String> {
        let common: Set<String> = ["version", "response"]
        switch response {
        case .list:
            return common.union(["workspace", "tasks"])
        case .task:
            return common.union(["task"])
        case .snapshot:
            return common.union(["snapshot"])
        case .acknowledged:
            return common.union(["taskID", "revision"])
        case .error:
            return common.union(["error"])
        }
    }
}

private struct TerminalControlTaskWire: Codable {
    let task: TerminalControlTask

    init(_ task: TerminalControlTask) {
        self.task = task
    }

    init(from decoder: Decoder) throws {
        try TerminalControlCodingValidator.requireExactKeys(
            decoder,
            expected: [
                "taskID", "paneID", "tabID", "workspaceID", "state", "owner", "policy",
                "revision", "exitCode",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = TerminalControlTask(
            taskID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .taskID)
            ),
            paneID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .paneID)
            ),
            tabID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .tabID)
            ),
            workspaceID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .workspaceID)
            ),
            state: try container.decode(TerminalTaskState.self, forKey: .state),
            owner: try container.decode(TerminalPaneControlOwner.self, forKey: .owner),
            policy: try container.decode(TerminalTaskLifecyclePolicy.self, forKey: .policy),
            revision: try container.decode(UInt64.self, forKey: .revision),
            exitCode: try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task.taskID.uuidString, forKey: .taskID)
        try container.encode(task.paneID.uuidString, forKey: .paneID)
        try container.encode(task.tabID.uuidString, forKey: .tabID)
        try container.encode(task.workspaceID.uuidString, forKey: .workspaceID)
        try container.encode(task.state, forKey: .state)
        try container.encode(task.owner, forKey: .owner)
        try container.encode(task.policy, forKey: .policy)
        try container.encode(task.revision, forKey: .revision)
        if let exitCode = task.exitCode {
            try container.encode(exitCode, forKey: .exitCode)
        } else {
            try container.encodeNil(forKey: .exitCode)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case paneID
        case tabID
        case workspaceID
        case state
        case owner
        case policy
        case revision
        case exitCode
    }
}

private struct TerminalControlSnapshotWire: Codable {
    let snapshot: TerminalControlSnapshot

    init(_ snapshot: TerminalControlSnapshot) {
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        try TerminalControlCodingValidator.requireExactKeys(
            decoder,
            expected: ["task", "text", "isTruncated"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try TerminalControlSnapshot(
            task: container.decode(TerminalControlTaskWire.self, forKey: .task).task,
            text: container.decode(String.self, forKey: .text),
            isTruncated: container.decode(Bool.self, forKey: .isTruncated)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TerminalControlTaskWire(snapshot.task), forKey: .task)
        try container.encode(snapshot.text, forKey: .text)
        try container.encode(snapshot.isTruncated, forKey: .isTruncated)
    }

    private enum CodingKeys: String, CodingKey {
        case task
        case text
        case isTruncated
    }
}

private struct TerminalControlWorkspaceMetadataWire: Codable {
    let metadata: TerminalControlWorkspaceMetadata

    init(_ metadata: TerminalControlWorkspaceMetadata) {
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        try TerminalControlCodingValidator.requireExactKeys(
            decoder,
            expected: [
                "workspaceID", "name", "originPaneID", "activeTabID", "tabCount", "paneCount",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try TerminalControlWorkspaceMetadata(
            workspaceID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .workspaceID)
            ),
            name: container.decode(String.self, forKey: .name),
            originPaneID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .originPaneID)
            ),
            activeTabID: try TerminalControlUUIDCodec.decode(
                container.decode(String.self, forKey: .activeTabID)
            ),
            tabCount: container.decode(Int.self, forKey: .tabCount),
            paneCount: container.decode(Int.self, forKey: .paneCount)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata.workspaceID.uuidString, forKey: .workspaceID)
        try container.encode(metadata.name, forKey: .name)
        try container.encode(metadata.originPaneID.uuidString, forKey: .originPaneID)
        try container.encode(metadata.activeTabID.uuidString, forKey: .activeTabID)
        try container.encode(metadata.tabCount, forKey: .tabCount)
        try container.encode(metadata.paneCount, forKey: .paneCount)
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case name
        case originPaneID
        case activeTabID
        case tabCount
        case paneCount
    }
}

private struct TerminalControlErrorWire: Codable {
    let error: TerminalControlError

    init(_ error: TerminalControlError) {
        self.error = error
    }

    init(from decoder: Decoder) throws {
        try TerminalControlCodingValidator.requireExactKeys(
            decoder,
            expected: ["code", "message"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try TerminalControlError(
            code: container.decode(TerminalControlErrorCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(error.code, forKey: .code)
        try container.encode(error.message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }
}

private enum TerminalControlCodingValidator {
    static func requireExactKeys(
        _ decoder: Decoder,
        expected: Set<String>
    ) throws {
        let container = try decoder.container(keyedBy: TerminalControlRawCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw TerminalControlProtocolError.invalidPayload
        }
    }
}

private enum TerminalControlUUIDCodec {
    static func decode(_ rawValue: String) throws -> UUID {
        guard rawValue.utf8.count == 36,
            let value = UUID(uuidString: rawValue),
            rawValue == value.uuidString
        else {
            throw TerminalControlProtocolError.invalidPayload
        }
        return value
    }
}

private struct TerminalControlRawCodingKey: CodingKey {
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
