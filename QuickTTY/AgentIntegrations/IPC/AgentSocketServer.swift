import Darwin
import Foundation

final class AgentSocketServer: Sendable {
    typealias Handler = @Sendable (AgentIPCMessage) async -> Bool
    typealias CredentialProvider = @Sendable (AgentIPCPreflight) -> String?
    typealias PeerValidator = @Sendable (_ fileDescriptor: Int32, _ expectedUID: uid_t) -> Bool
    typealias AcceptFunction = AuthenticatedLocalSocketServer.AcceptFunction
    typealias AcceptRetryBackoff = @Sendable () -> Void
    typealias InstanceDirectoryOpenFunction =
        AuthenticatedLocalSocketServer.InstanceDirectoryOpenFunction
    typealias InstanceDirectoryFstatFunction =
        AuthenticatedLocalSocketServer.InstanceDirectoryFstatFunction
    typealias ListenerShutdownFunction = AuthenticatedLocalSocketServer.ListenerShutdownFunction
    typealias ListenerCloseFunction = AuthenticatedLocalSocketServer.ListenerCloseFunction
    typealias ListenerCloseObserver = AuthenticatedLocalSocketServer.ListenerCloseObserver
    typealias AcceptFileDescriptorCloseObserver =
        AuthenticatedLocalSocketServer.AcceptFileDescriptorCloseObserver

    private let runtime: AuthenticatedLocalSocketServer

    init(
        temporaryBaseDirectory: String = "/tmp",
        expectedUID: uid_t = geteuid(),
        peerValidator: @escaping PeerValidator = AgentSocketServer.validatePeer,
        maximumConnections: Int = 64,
        connectionTimeoutMilliseconds: Int = 5_000,
        acceptFunction: @escaping AcceptFunction = AuthenticatedLocalSocketAcceptResult.accept,
        acceptRetryBackoff: @escaping AcceptRetryBackoff = { _ = Darwin.usleep(10_000) },
        instanceDirectoryOpenFunction: @escaping InstanceDirectoryOpenFunction = {
            Darwin.open($0, $1)
        },
        instanceDirectoryFstatFunction: @escaping InstanceDirectoryFstatFunction = {
            Darwin.fstat($0, $1)
        },
        listenerShutdownFunction: @escaping ListenerShutdownFunction = {
            _ = Darwin.shutdown($0, $1)
        },
        listenerCloseFunction: @escaping ListenerCloseFunction = { _ = Darwin.close($0) },
        listenerCloseObserver: @escaping ListenerCloseObserver = { _ in },
        acceptFileDescriptorCloseObserver: @escaping AcceptFileDescriptorCloseObserver = { _ in },
        credentialProvider: @escaping CredentialProvider = { _ in nil },
        handler: @escaping Handler
    ) {
        runtime = AuthenticatedLocalSocketServer(
            serviceName: "agent-socket",
            socketFileName: "agent.sock",
            temporaryBaseDirectory: temporaryBaseDirectory,
            expectedUID: expectedUID,
            peerValidator: peerValidator,
            maximumConnections: maximumConnections,
            connectionTimeoutMilliseconds: connectionTimeoutMilliseconds,
            acceptFunction: acceptFunction,
            acceptRetryBackoff: acceptRetryBackoff,
            instanceDirectoryOpenFunction: instanceDirectoryOpenFunction,
            instanceDirectoryFstatFunction: instanceDirectoryFstatFunction,
            rejectedConnectionResponse: Data([0]),
            handlerStopPolicy: .waitForCompletion,
            maximumExecutingHandlers: maximumConnections,
            listenerShutdownFunction: listenerShutdownFunction,
            listenerCloseFunction: listenerCloseFunction,
            listenerCloseObserver: listenerCloseObserver,
            acceptFileDescriptorCloseObserver: acceptFileDescriptorCloseObserver
        ) { connection in
            Self.processConnection(
                connection,
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
            throw Self.map(error)
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
        credentialProvider: @escaping CredentialProvider,
        handler: @escaping Handler
    ) {
        do {
            guard
                let preflightData = try connection.readExactly(AgentIPCProtocol.preflightSize)
            else {
                throw AgentIPCProtocolError.invalidPreflight
            }
            let preflight = try AgentIPCProtocol.decodePreflight(preflightData)
            guard let paneToken = credentialProvider(preflight),
                let proof = try? AgentIPCProtocol.makeServerProof(
                    for: preflight,
                    paneToken: paneToken
                )
            else {
                connection.finish(with: Data([0]))
                return
            }

            var challenge = Data([1])
            challenge.append(proof)
            try connection.write(challenge)

            let frame = try connection.readFrame(
                maximumPayloadSize: AgentIPCProtocol.maximumPayloadSize,
                requireEndOfStream: true
            )
            guard let currentPaneToken = credentialProvider(preflight) else {
                connection.finish(with: Data([0]))
                return
            }
            let message = try AgentIPCProtocol.decodeFrame(
                frame,
                for: preflight,
                paneToken: currentPaneToken
            )
            guard message.identity.instanceID == preflight.instanceID,
                message.identity.paneID == preflight.paneID,
                connection.reserveNonce(nonceKey(for: preflight))
            else {
                connection.finish(with: Data([0]))
                return
            }

            guard
                connection.runHandler(
                    timeoutMilliseconds: nil,
                    timeoutResponse: nil,
                    monitorDisconnect: false,
                    responseWriteTimeoutMilliseconds: nil,
                    operation: { _ in
                        Data([await handler(message) ? 1 : 0])
                    }
                )
            else {
                connection.finish(with: Data([0]))
                return
            }
        } catch {
            connection.finish(with: Data([0]))
        }
    }

    private static func nonceKey(
        for preflight: AgentIPCPreflight
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

    private static func validatePeer(_ fileDescriptor: Int32, expectedUID: uid_t) -> Bool {
        AuthenticatedLocalSocketServer.validatePeer(fileDescriptor, expectedUID: expectedUID)
    }

    private static func map(
        _ error: AuthenticatedLocalSocketServerError
    ) -> AgentSocketServerError {
        switch error {
        case .connectionTimedOut:
            .connectionTimedOut
        case .invalidTemporaryBaseDirectory:
            .invalidTemporaryBaseDirectory
        case .invalidSocketPath:
            .invalidSocketPath
        case .stopInProgress:
            .stopInProgress
        case .invalidFrame:
            .systemCall("frame", EINVAL)
        case .systemCall(let operation, let code):
            .systemCall(operation, code)
        }
    }
}

enum AgentSocketServerError: Error, Equatable, Sendable {
    case connectionTimedOut
    case invalidTemporaryBaseDirectory
    case invalidSocketPath
    case stopInProgress
    case systemCall(String, Int32)
}
