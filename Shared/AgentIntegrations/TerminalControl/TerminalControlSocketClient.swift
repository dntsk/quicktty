import Darwin
import Foundation

public struct TerminalControlSocketClient: Sendable {
    typealias NonceGenerator = @Sendable () -> Data

    private static let ordinaryTimeoutMilliseconds = 65_000
    private static let waitTransportMarginMilliseconds = 5_000

    public let socketPath: String
    public let instanceID: UUID
    public let paneID: UUID

    private let paneToken: String
    private let nonceGenerator: NonceGenerator
    private let timeoutMilliseconds: Int?

    public init(
        socketPath: String,
        instanceID: UUID,
        paneID: UUID,
        paneToken: String
    ) throws {
        try self.init(
            socketPath: socketPath,
            instanceID: instanceID,
            paneID: paneID,
            paneToken: paneToken,
            nonceGenerator: Self.randomNonce,
            timeoutMilliseconds: nil
        )
    }

    init(
        socketPath: String,
        instanceID: UUID,
        paneID: UUID,
        paneToken: String,
        nonceGenerator: @escaping NonceGenerator,
        timeoutMilliseconds: Int?
    ) throws {
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(socketPath),
            (try? AgentUnixSocketAddress(path: socketPath)) != nil
        else {
            throw TerminalControlSocketClientError.invalidConfiguration
        }
        guard (try? AgentIPCValueValidator.validatePaneToken(paneToken)) != nil else {
            throw TerminalControlSocketClientError.invalidConfiguration
        }
        if let timeoutMilliseconds {
            guard (1...120_000).contains(timeoutMilliseconds) else {
                throw TerminalControlSocketClientError.invalidConfiguration
            }
        }
        self.socketPath = socketPath
        self.instanceID = instanceID
        self.paneID = paneID
        self.paneToken = paneToken
        self.nonceGenerator = nonceGenerator
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func send(_ request: TerminalControlRequest) throws -> TerminalControlResponse {
        do {
            return try sendAuthenticated(request)
        } catch let error as TerminalControlSocketClientError {
            throw error
        } catch AgentSocketClientError.timedOut {
            throw TerminalControlSocketClientError.timedOut
        } catch {
            throw TerminalControlSocketClientError.transportFailure
        }
    }

    private func sendAuthenticated(
        _ request: TerminalControlRequest
    ) throws -> TerminalControlResponse {
        let deadline = try AgentSocketDeadline(
            timeoutMilliseconds: timeoutMilliseconds ?? Self.timeout(for: request)
        )
        let preflight = try TerminalControlPreflight(
            instanceID: instanceID,
            paneID: paneID,
            nonce: nonceGenerator()
        )
        let preflightData = try TerminalControlProtocol.encodePreflight(preflight)

        var address: AgentUnixSocketAddress
        do {
            address = try AgentUnixSocketAddress(path: socketPath)
        } catch {
            throw TerminalControlSocketClientError.invalidConfiguration
        }
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw TerminalControlSocketClientError.transportFailure
        }
        defer { Darwin.close(fileDescriptor) }

        try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
        try AgentSocketIO.makeNonblocking(fileDescriptor)
        try AgentSocketIO.connect(fileDescriptor, to: &address, deadline: deadline)
        try AgentSocketIO.writeAll(preflightData, to: fileDescriptor, deadline: deadline)

        guard
            let challengeStatus = try AgentSocketIO.readByte(
                from: fileDescriptor,
                deadline: deadline
            ),
            challengeStatus == 1,
            let challenge = try AgentSocketIO.readExactly(
                TerminalControlProtocol.challengeSize,
                from: fileDescriptor,
                deadline: deadline
            ),
            let proof = try AgentSocketIO.readExactly(
                TerminalControlProtocol.authenticationCodeSize,
                from: fileDescriptor,
                deadline: deadline
            ),
            TerminalControlProtocol.verifyServerProof(
                proof,
                for: preflight,
                challenge: challenge,
                paneToken: paneToken
            )
        else {
            throw TerminalControlSocketClientError.serverAuthenticationFailed
        }

        let requestFrame = try TerminalControlProtocol.encodeRequestFrame(
            request,
            for: preflight,
            challenge: challenge,
            paneToken: paneToken
        )
        try AgentSocketIO.writeAll(requestFrame, to: fileDescriptor, deadline: deadline)
        try AgentSocketIO.shutdownWrite(fileDescriptor, deadline: deadline)
        let responseFrame = try readResponseFrame(
            from: fileDescriptor,
            deadline: deadline
        )
        let response: TerminalControlResponse
        do {
            response = try TerminalControlProtocol.decodeResponseFrame(
                responseFrame,
                for: preflight,
                challenge: challenge,
                request: request,
                paneToken: paneToken
            )
        } catch TerminalControlProtocolError.authenticationFailed {
            throw TerminalControlSocketClientError.responseAuthenticationFailed
        } catch {
            throw TerminalControlSocketClientError.invalidResponse
        }
        guard try AgentSocketIO.readByte(from: fileDescriptor, deadline: deadline) == nil else {
            throw TerminalControlSocketClientError.invalidResponse
        }
        return response
    }

    private func readResponseFrame(
        from fileDescriptor: Int32,
        deadline: AgentSocketDeadline
    ) throws -> Data {
        let headerSize = MemoryLayout<UInt32>.size
        guard
            let header = try AgentSocketIO.readExactly(
                headerSize,
                from: fileDescriptor,
                deadline: deadline
            )
        else {
            throw TerminalControlSocketClientError.transportFailure
        }
        let declaredLength = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard declaredLength > 0,
            declaredLength <= UInt32(TerminalControlProtocol.maximumResponsePayloadSize)
        else {
            throw TerminalControlSocketClientError.invalidResponse
        }
        let bodySize = Int(declaredLength) + TerminalControlProtocol.authenticationCodeSize
        guard
            let body = try AgentSocketIO.readExactly(
                bodySize,
                from: fileDescriptor,
                deadline: deadline
            )
        else {
            throw TerminalControlSocketClientError.transportFailure
        }
        var frame = Data(capacity: header.count + body.count)
        frame.append(header)
        frame.append(body)
        return frame
    }

    private static func timeout(for request: TerminalControlRequest) -> Int {
        if case .wait(_, _, let timeoutMilliseconds) = request.operation {
            return timeoutMilliseconds + waitTransportMarginMilliseconds
        }
        return ordinaryTimeoutMilliseconds
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<TerminalControlProtocol.nonceSize).map { _ in
                UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
        )
    }
}

public enum TerminalControlSocketClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case timedOut
    case serverAuthenticationFailed
    case responseAuthenticationFailed
    case invalidResponse
    case transportFailure
}
