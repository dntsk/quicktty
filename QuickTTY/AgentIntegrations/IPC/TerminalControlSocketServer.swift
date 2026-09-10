import Darwin
import Foundation
import Synchronization

struct TerminalControlSocketRequest: Equatable, Sendable {
    let instanceID: UUID
    let paneID: UUID
    let request: TerminalControlRequest
}

struct TerminalControlSocketRequestContext: Sendable {
    private let cancellationLease: AuthenticatedLocalSocketCancellationLease
    private let credentialIsCurrent: @Sendable () -> Bool

    fileprivate init(
        cancellationLease: AuthenticatedLocalSocketCancellationLease,
        credentialIsCurrent: @escaping @Sendable () -> Bool
    ) {
        self.cancellationLease = cancellationLease
        self.credentialIsCurrent = credentialIsCurrent
    }

    // Cancellation cannot stop arbitrary async code. Coordinators must recheck this lease
    // immediately before every externally visible mutation to fail closed after transport loss.
    var isActive: Bool {
        cancellationLease.isActive && credentialIsCurrent()
    }
}

final class TerminalControlSocketServer: Sendable {
    typealias Handler =
        @Sendable (TerminalControlSocketRequest, TerminalControlSocketRequestContext) async ->
        TerminalControlResponse
    typealias CredentialProvider = @Sendable (TerminalControlPreflight) -> String?
    typealias PeerValidator = AuthenticatedLocalSocketServer.PeerValidator
    typealias AcceptFunction = AuthenticatedLocalSocketServer.AcceptFunction
    typealias AcceptRetryBackoff = AuthenticatedLocalSocketServer.AcceptRetryBackoff
    typealias ChallengeGenerator = @Sendable () -> Data
    typealias MonotonicMilliseconds = @Sendable () -> UInt64
    typealias RequestFrameReadObserver = @Sendable () -> Void
    typealias HandlerCancellationEnqueueObserver = @Sendable () -> Void
    typealias HandlerCancellationDeliveryObserver = @Sendable () -> Void
    typealias DisconnectMonitorIdleObserver = @Sendable () -> Void
    typealias HandlerWaiterRegistrationObserver = @Sendable () -> Void
    typealias HandlerCancellationTransitionObserver =
        @Sendable (AuthenticatedLocalSocketHandlerCancellationReason) -> Void
    typealias HandlerClientCloseObserver = @Sendable () -> Void
    typealias ResponseWriteObserver = @Sendable () -> Void
    typealias StopClientShutdownObserver = @Sendable () -> Void
    typealias ClientShutdownFunction = AuthenticatedLocalSocketServer.ClientShutdownFunction
    typealias ClientCloseFunction = AuthenticatedLocalSocketServer.ClientCloseFunction

    private static let ordinaryHandlerTimeoutMilliseconds = 60_000
    private static let responseWriteTimeoutMilliseconds = 5_000

    private let runtime: AuthenticatedLocalSocketServer

    init(
        temporaryBaseDirectory: String = "/tmp",
        expectedUID: uid_t = geteuid(),
        peerValidator: @escaping PeerValidator = AuthenticatedLocalSocketServer.validatePeer,
        maximumConnections: Int = 64,
        maximumExecutingHandlers: Int = 64,
        connectionTimeoutMilliseconds: Int = 5_000,
        handlerTransportMarginMilliseconds: Int = 2_000,
        nonceCacheCapacity: Int = 4_096,
        nonceRetentionMilliseconds: UInt64 = 300_000,
        challengeGenerator: @escaping ChallengeGenerator = TerminalControlSocketServer
            .randomChallenge,
        monotonicMilliseconds: @escaping MonotonicMilliseconds =
            TerminalControlSocketServer.monotonicMilliseconds,
        requestFrameReadObserver: @escaping RequestFrameReadObserver = {},
        handlerExecutionReleaseObserver: @escaping @Sendable () -> Void = {},
        handlerCancellationEnqueueObserver: @escaping HandlerCancellationEnqueueObserver = {},
        handlerCancellationDeliveryObserver: @escaping HandlerCancellationDeliveryObserver = {},
        disconnectMonitorIdleObserver: @escaping DisconnectMonitorIdleObserver = {},
        handlerWaiterRegistrationObserver: @escaping HandlerWaiterRegistrationObserver = {},
        handlerCancellationTransitionObserver: @escaping HandlerCancellationTransitionObserver = {
            _ in
        },
        handlerClientCloseObserver: @escaping HandlerClientCloseObserver = {},
        responseWriteObserver: @escaping ResponseWriteObserver = {},
        stopClientShutdownObserver: @escaping StopClientShutdownObserver = {},
        clientShutdownFunction: @escaping ClientShutdownFunction = {
            _ = Darwin.shutdown($0, $1)
        },
        clientCloseFunction: @escaping ClientCloseFunction = { _ = Darwin.close($0) },
        acceptFunction: @escaping AcceptFunction = AuthenticatedLocalSocketAcceptResult.accept,
        acceptRetryBackoff: @escaping AcceptRetryBackoff = { _ = Darwin.usleep(10_000) },
        credentialProvider: @escaping CredentialProvider,
        handler: @escaping Handler
    ) {
        precondition((1...5_000).contains(handlerTransportMarginMilliseconds))
        precondition((1...65_536).contains(nonceCacheCapacity))
        precondition(nonceRetentionMilliseconds > 0)
        let nonceCache = TerminalControlNonceCache(
            capacity: nonceCacheCapacity,
            retentionMilliseconds: nonceRetentionMilliseconds,
            monotonicMilliseconds: monotonicMilliseconds
        )
        runtime = AuthenticatedLocalSocketServer(
            serviceName: "terminal-control-socket",
            socketFileName: "control.sock",
            temporaryBaseDirectory: temporaryBaseDirectory,
            expectedUID: expectedUID,
            peerValidator: peerValidator,
            maximumConnections: maximumConnections,
            connectionTimeoutMilliseconds: connectionTimeoutMilliseconds,
            acceptFunction: acceptFunction,
            acceptRetryBackoff: acceptRetryBackoff,
            rejectedConnectionResponse: Data(),
            handlerStopPolicy: .cancel,
            maximumExecutingHandlers: maximumExecutingHandlers,
            handlerExecutionReleaseObserver: handlerExecutionReleaseObserver,
            handlerCancellationEnqueueObserver: handlerCancellationEnqueueObserver,
            handlerCancellationDeliveryObserver: handlerCancellationDeliveryObserver,
            disconnectMonitorIdleObserver: disconnectMonitorIdleObserver,
            handlerWaiterRegistrationObserver: handlerWaiterRegistrationObserver,
            handlerCancellationTransitionObserver: handlerCancellationTransitionObserver,
            handlerClientCloseObserver: handlerClientCloseObserver,
            responseWriteObserver: responseWriteObserver,
            stopClientShutdownObserver: stopClientShutdownObserver,
            clientShutdownFunction: clientShutdownFunction,
            clientCloseFunction: clientCloseFunction
        ) { connection in
            Self.processConnection(
                connection,
                handlerTransportMarginMilliseconds: handlerTransportMarginMilliseconds,
                challengeGenerator: challengeGenerator,
                requestFrameReadObserver: requestFrameReadObserver,
                nonceCache: nonceCache,
                credentialProvider: credentialProvider,
                handler: handler
            )
        }
    }

    deinit {
        runtime.stopImmediately()
    }

    var socketPath: String? {
        runtime.socketPath
    }

    @discardableResult
    func start() throws -> String {
        do {
            return try runtime.start()
        } catch let error as AuthenticatedLocalSocketServerError {
            throw TerminalControlSocketServerError(error)
        }
    }

    func stop() async {
        await runtime.stop()
    }

    func stopImmediately() {
        runtime.stopImmediately()
    }

    private static func processConnection(
        _ connection: AuthenticatedLocalSocketConnection,
        handlerTransportMarginMilliseconds: Int,
        challengeGenerator: @escaping ChallengeGenerator,
        requestFrameReadObserver: @escaping RequestFrameReadObserver,
        nonceCache: TerminalControlNonceCache,
        credentialProvider: @escaping CredentialProvider,
        handler: @escaping Handler
    ) {
        do {
            guard
                let preflightData = try connection.readExactly(
                    TerminalControlProtocol.preflightSize
                )
            else {
                throw TerminalControlProtocolError.invalidPreflight
            }
            let preflight = try TerminalControlProtocol.decodePreflight(preflightData)
            let challenge = challengeGenerator()
            guard let paneToken = credentialProvider(preflight),
                challenge.count == TerminalControlProtocol.challengeSize,
                let proof = try? TerminalControlProtocol.makeServerProof(
                    for: preflight,
                    challenge: challenge,
                    paneToken: paneToken
                )
            else {
                connection.finishWithoutResponse()
                return
            }

            var serverProofFrame = Data([1])
            serverProofFrame.append(challenge)
            serverProofFrame.append(proof)
            try connection.write(serverProofFrame)

            let frame = try connection.readFrame(
                maximumPayloadSize: TerminalControlProtocol.maximumRequestPayloadSize,
                authenticationCodeSize: TerminalControlProtocol.authenticationCodeSize,
                requireEndOfStream: true,
                frameBodyReadObserver: requestFrameReadObserver
            )
            guard let currentPaneToken = credentialProvider(preflight) else {
                connection.finishWithoutResponse()
                return
            }
            let request = try TerminalControlProtocol.decodeRequestFrame(
                frame,
                for: preflight,
                challenge: challenge,
                paneToken: currentPaneToken
            )
            guard nonceCache.reserve(nonceKey(for: preflight)) else {
                connection.finishWithoutResponse()
                return
            }

            let timeoutMilliseconds = handlerTimeout(
                for: request,
                transportMarginMilliseconds: handlerTransportMarginMilliseconds
            )
            let timeoutResponse = try TerminalControlProtocol.encodeResponseFrame(
                timeoutFailureResponse(),
                for: preflight,
                challenge: challenge,
                request: request,
                paneToken: currentPaneToken
            )
            let authenticatedRequest = TerminalControlSocketRequest(
                instanceID: preflight.instanceID,
                paneID: preflight.paneID,
                request: request
            )
            guard
                connection.runHandler(
                    timeoutMilliseconds: timeoutMilliseconds,
                    timeoutResponse: timeoutResponse,
                    monitorDisconnect: true,
                    responseWriteTimeoutMilliseconds: responseWriteTimeoutMilliseconds,
                    operation: { cancellationLease in
                        let context = TerminalControlSocketRequestContext(
                            cancellationLease: cancellationLease,
                            // WHY: Looking up a new token at dispatch cannot authenticate an old frame.
                            credentialIsCurrent: {
                                credentialProvider(preflight) == currentPaneToken
                            }
                        )
                        let response = await handler(authenticatedRequest, context)
                        if let frame = try? TerminalControlProtocol.encodeResponseFrame(
                            response,
                            for: preflight,
                            challenge: challenge,
                            request: request,
                            paneToken: currentPaneToken
                        ) {
                            return frame
                        }
                        return try? TerminalControlProtocol.encodeResponseFrame(
                            internalFailureResponse(),
                            for: preflight,
                            challenge: challenge,
                            request: request,
                            paneToken: currentPaneToken
                        )
                    }
                )
            else {
                connection.finishWithoutResponse()
                return
            }
        } catch {
            connection.finishWithoutResponse()
        }
    }

    private static func handlerTimeout(
        for request: TerminalControlRequest,
        transportMarginMilliseconds: Int
    ) -> Int {
        if case .wait(_, _, let timeoutMilliseconds) = request.operation {
            return timeoutMilliseconds + transportMarginMilliseconds
        }
        return ordinaryHandlerTimeoutMilliseconds
    }

    private static func timeoutFailureResponse() throws -> TerminalControlResponse {
        TerminalControlResponse(
            result: .failure(
                try TerminalControlError(
                    code: .timeout,
                    message: "Terminal control request timed out"
                )
            )
        )
    }

    private static func internalFailureResponse() -> TerminalControlResponse {
        TerminalControlResponse(
            result: .failure(
                try! TerminalControlError(
                    code: .internalFailure,
                    message: "Terminal control request failed"
                )
            )
        )
    }

    private static func nonceKey(
        for preflight: TerminalControlPreflight
    ) -> AuthenticatedLocalSocketNonceKey {
        var identity = Data()
        appendUUID(preflight.instanceID, to: &identity)
        appendUUID(preflight.paneID, to: &identity)
        return AuthenticatedLocalSocketNonceKey(identity: identity, nonce: preflight.nonce)
    }

    private static func appendUUID(_ value: UUID, to data: inout Data) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    private static func randomChallenge() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<TerminalControlProtocol.challengeSize).map { _ in
                UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
        )
    }

    private static func monotonicMilliseconds() -> UInt64 {
        var currentTime = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &currentTime) == 0 else { return 0 }
        return UInt64(currentTime.tv_sec) * 1_000 + UInt64(currentTime.tv_nsec) / 1_000_000
    }
}

private final class TerminalControlNonceCache: Sendable {
    private struct Entry: Sendable {
        let acceptedAtMilliseconds: UInt64
        let sequence: UInt64
    }

    private struct State: Sendable {
        var entries: [AuthenticatedLocalSocketNonceKey: Entry] = [:]
        var nextSequence: UInt64 = 0
    }

    private let capacity: Int
    private let retentionMilliseconds: UInt64
    private let monotonicMilliseconds: TerminalControlSocketServer.MonotonicMilliseconds
    private let state = Mutex(State())

    init(
        capacity: Int,
        retentionMilliseconds: UInt64,
        monotonicMilliseconds: @escaping TerminalControlSocketServer.MonotonicMilliseconds
    ) {
        self.capacity = capacity
        self.retentionMilliseconds = retentionMilliseconds
        self.monotonicMilliseconds = monotonicMilliseconds
    }

    func reserve(_ key: AuthenticatedLocalSocketNonceKey) -> Bool {
        let now = monotonicMilliseconds()
        return state.withLock { state in
            state.entries = state.entries.filter { _, entry in
                now < entry.acceptedAtMilliseconds
                    || now - entry.acceptedAtMilliseconds < retentionMilliseconds
            }
            guard state.entries[key] == nil else { return false }
            if state.entries.count == capacity,
                let oldest = state.entries.min(by: { $0.value.sequence < $1.value.sequence })?.key
            {
                state.entries.removeValue(forKey: oldest)
            }
            state.nextSequence &+= 1
            state.entries[key] = Entry(
                acceptedAtMilliseconds: now,
                sequence: state.nextSequence
            )
            return true
        }
    }
}

enum TerminalControlSocketServerError: Error, Equatable, Sendable {
    case connectionTimedOut
    case invalidTemporaryBaseDirectory
    case invalidSocketPath
    case stopInProgress
    case internalFailure

    init(_ error: AuthenticatedLocalSocketServerError) {
        switch error {
        case .connectionTimedOut:
            self = .connectionTimedOut
        case .invalidTemporaryBaseDirectory:
            self = .invalidTemporaryBaseDirectory
        case .invalidSocketPath:
            self = .invalidSocketPath
        case .stopInProgress:
            self = .stopInProgress
        case .invalidFrame, .systemCall:
            self = .internalFailure
        }
    }
}
