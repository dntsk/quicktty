import Darwin
import Foundation

struct AgentMessagingSocketContext: Sendable {
    let instanceID: UUID
    let paneID: UUID
    private let lease: AuthenticatedLocalSocketCancellationLease
    private let credentialIsCurrent: @Sendable () -> Bool

    fileprivate init(
        instanceID: UUID, paneID: UUID, lease: AuthenticatedLocalSocketCancellationLease,
        credentialIsCurrent: @escaping @Sendable () -> Bool
    ) {
        self.instanceID = instanceID
        self.paneID = paneID
        self.lease = lease
        self.credentialIsCurrent = credentialIsCurrent
    }

    var isActive: Bool { lease.isActive && credentialIsCurrent() }
}

final class AgentMessagingSocketServer: Sendable {
    typealias Credentials = @Sendable (TerminalControlPreflight) -> String?
    typealias Handler =
        @Sendable (AgentMessagingRequest, AgentMessagingSocketContext) async ->
        AgentMessagingResponse
    private let runtime: AuthenticatedLocalSocketServer

    init(credentialProvider: @escaping Credentials, handler: @escaping Handler) {
        runtime = AuthenticatedLocalSocketServer(
            serviceName: "agent-messaging", socketFileName: "messaging.sock",
            temporaryBaseDirectory: "/tmp", expectedUID: geteuid(), maximumConnections: 32,
            connectionTimeoutMilliseconds: 5_000,
            acceptFunction: AuthenticatedLocalSocketAcceptResult.accept,
            acceptRetryBackoff: { _ = Darwin.usleep(10_000) },
            rejectedConnectionResponse: Data(), handlerStopPolicy: .cancel,
            maximumExecutingHandlers: 32,
            connectionProcessor: { connection in
                Self.process(connection, credentialProvider: credentialProvider, handler: handler)
            }
        )
    }

    deinit { runtime.stopImmediately() }
    func start() throws -> String { try runtime.start() }
    func stopImmediately() { runtime.stopImmediately() }
    func stop() async { await runtime.stop() }

    private static func process(
        _ connection: AuthenticatedLocalSocketConnection, credentialProvider: @escaping Credentials,
        handler: @escaping Handler
    ) {
        do {
            guard let bytes = try connection.readExactly(TerminalControlProtocol.preflightSize)
            else {
                throw AgentMessagingProtocolError.invalidPayload
            }
            let preflight = try TerminalControlProtocol.decodePreflight(bytes)
            let challenge = AgentMessagingProtocol.randomBytes()
            guard let token = credentialProvider(preflight) else {
                connection.finishWithoutResponse()
                return
            }
            let proof = try AgentMessagingProtocol.serverProof(
                preflight, challenge: challenge, token: token)
            try connection.write(Data([1]) + challenge + proof)
            let frame = try connection.readFrame(
                maximumPayloadSize: AgentMessagingProtocol.maximumRequestBytes,
                authenticationCodeSize: 32, requireEndOfStream: true
            )
            guard credentialProvider(preflight) == token else {
                connection.finishWithoutResponse()
                return
            }
            let request = try AgentMessagingProtocol.decodeRequestFrame(
                frame, preflight: preflight, challenge: challenge, token: token)
            guard
                connection.reserveNonce(
                    AuthenticatedLocalSocketNonceKey(
                        identity: Data(bytes.prefix(44)), nonce: preflight.nonce))
            else {
                connection.finishWithoutResponse()
                return
            }
            let timeout =
                request.operation == .wait ? Int(request.timeoutMilliseconds!) + 2_000 : 10_000
            let timeoutFrame = try AgentMessagingProtocol.responseFrame(
                .failure("timedOut", requestID: request.requestID), request: request,
                preflight: preflight, challenge: challenge, token: token
            )
            guard
                connection.runHandler(
                    timeoutMilliseconds: timeout, timeoutResponse: timeoutFrame,
                    monitorDisconnect: true,
                    responseWriteTimeoutMilliseconds: 5_000,
                    operation: { lease in
                        let context = AgentMessagingSocketContext(
                            instanceID: preflight.instanceID, paneID: preflight.paneID,
                            lease: lease,
                            credentialIsCurrent: { credentialProvider(preflight) == token }
                        )
                        guard context.isActive else { return nil }
                        let response = await handler(request, context)
                        guard context.isActive else { return nil }
                        return try? AgentMessagingProtocol.responseFrame(
                            response, request: request, preflight: preflight, challenge: challenge,
                            token: token)
                    }
                )
            else {
                connection.finishWithoutResponse()
                return
            }
        } catch { connection.finishWithoutResponse() }
    }
}
