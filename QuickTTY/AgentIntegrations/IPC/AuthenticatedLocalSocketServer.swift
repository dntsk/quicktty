import Darwin
import Dispatch
import Foundation
import Synchronization

struct AuthenticatedLocalSocketNonceKey: Hashable, Sendable {
    let identity: Data
    let nonce: Data
}

enum AuthenticatedLocalSocketHandlerStopPolicy: Equatable, Sendable {
    case waitForCompletion
    case cancel
}

enum AuthenticatedLocalSocketHandlerCancellationReason: Equatable, Sendable {
    case timeout
    case disconnected
    case cancelled
}

final class AuthenticatedLocalSocketCancellationLease: Sendable {
    private struct State {
        var isActive = true
        var invocationStarted = false
    }

    private let state = Mutex(State())

    var isActive: Bool {
        state.withLock(\.isActive)
    }

    fileprivate func beginInvocation() -> Bool {
        state.withLock { state in
            guard state.isActive, !state.invocationStarted else { return false }
            state.invocationStarted = true
            return true
        }
    }

    fileprivate func cancel() {
        state.withLock { $0.isActive = false }
    }
}

struct AuthenticatedLocalSocketConnection: Sendable {
    fileprivate let runtime: AuthenticatedLocalSocketServer
    fileprivate let fileDescriptor: Int32
    fileprivate let generation: UInt64
    fileprivate let deadlineNanoseconds: UInt64

    func readExactly(_ count: Int) throws -> Data? {
        try runtime.readExactly(
            count,
            from: fileDescriptor,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    func readFrame(
        maximumPayloadSize: Int,
        authenticationCodeSize: Int = 0,
        requireEndOfStream: Bool,
        frameBodyReadObserver: @Sendable () -> Void = {}
    ) throws -> Data {
        try runtime.readFrame(
            from: fileDescriptor,
            deadlineNanoseconds: deadlineNanoseconds,
            maximumPayloadSize: maximumPayloadSize,
            authenticationCodeSize: authenticationCodeSize,
            requireEndOfStream: requireEndOfStream,
            frameBodyReadObserver: frameBodyReadObserver
        )
    }

    func write(_ data: Data) throws {
        try runtime.writeAll(
            data,
            to: fileDescriptor,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    func reserveNonce(_ key: AuthenticatedLocalSocketNonceKey) -> Bool {
        runtime.reserveNonce(key, generation: generation)
    }

    func finish(with response: Data) {
        runtime.finishClientImmediately(
            fileDescriptor,
            generation: generation,
            response: response
        )
    }

    func finishWithoutResponse() {
        runtime.finishClientImmediately(
            fileDescriptor,
            generation: generation,
            response: Data()
        )
    }

    @discardableResult
    func runHandler(
        timeoutMilliseconds: Int?,
        timeoutResponse: Data?,
        monitorDisconnect: Bool,
        responseWriteTimeoutMilliseconds: Int?,
        operation: @escaping @Sendable (AuthenticatedLocalSocketCancellationLease) async -> Data?
    ) -> Bool {
        runtime.runHandler(
            fileDescriptor: fileDescriptor,
            generation: generation,
            timeoutMilliseconds: timeoutMilliseconds,
            timeoutResponse: timeoutResponse,
            monitorDisconnect: monitorDisconnect,
            responseWriteTimeoutMilliseconds: responseWriteTimeoutMilliseconds,
            operation: operation
        )
    }
}

struct AuthenticatedLocalSocketAcceptResult: Sendable {
    let fileDescriptor: Int32
    let errorCode: Int32

    static func accept(from listenerFileDescriptor: Int32) -> Self {
        let fileDescriptor = Darwin.accept(listenerFileDescriptor, nil, nil)
        let errorCode = errno
        return Self(fileDescriptor: fileDescriptor, errorCode: errorCode)
    }

    static func failure(_ errorCode: Int32) -> Self {
        Self(fileDescriptor: -1, errorCode: errorCode)
    }
}

final class AuthenticatedLocalSocketServer: Sendable {
    typealias PeerValidator = @Sendable (_ fileDescriptor: Int32, _ expectedUID: uid_t) -> Bool
    typealias AcceptFunction =
        @Sendable (_ listenerFileDescriptor: Int32) -> AuthenticatedLocalSocketAcceptResult
    typealias AcceptRetryBackoff = @Sendable () -> Void
    typealias InstanceDirectoryOpenFunction = @Sendable (_ path: String, _ flags: Int32) -> Int32
    typealias InstanceDirectoryFstatFunction =
        @Sendable (_ fileDescriptor: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32
    typealias SocketWriteFunction =
        @Sendable (_ fileDescriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int
    typealias ConnectionProcessor = @Sendable (AuthenticatedLocalSocketConnection) -> Void
    typealias DisconnectMonitorIdleObserver = @Sendable () -> Void
    typealias HandlerWaiterRegistrationObserver = @Sendable () -> Void
    typealias HandlerCancellationEnqueueObserver = @Sendable () -> Void
    typealias HandlerCancellationTransitionObserver =
        @Sendable (AuthenticatedLocalSocketHandlerCancellationReason) -> Void
    typealias HandlerClientCloseObserver = @Sendable () -> Void
    typealias ResponseWriteObserver = @Sendable () -> Void
    typealias StopClientShutdownObserver = @Sendable () -> Void
    typealias ClientShutdownFunction =
        @Sendable (_ fileDescriptor: Int32, _ direction: Int32) -> Void
    typealias ClientCloseFunction = @Sendable (_ fileDescriptor: Int32) -> Void
    typealias ListenerShutdownFunction =
        @Sendable (_ fileDescriptor: Int32, _ direction: Int32) -> Void
    typealias ListenerCloseFunction = @Sendable (_ fileDescriptor: Int32) -> Void
    typealias ListenerCloseObserver = @Sendable (_ fileDescriptor: Int32) -> Void
    typealias AcceptFileDescriptorCloseObserver =
        @Sendable (_ fileDescriptor: Int32) -> Void

    private enum ClientPhase: Equatable, Sendable {
        case handling
        case writing
    }

    private struct ClientRegistration: Sendable {
        let generation: UInt64
        var phase: ClientPhase
    }

    private struct State: Sendable {
        var generation: UInt64 = 0
        var listenerFileDescriptor: Int32?
        var clients: [Int32: ClientRegistration] = [:]
        var authenticatedNonces: Set<AuthenticatedLocalSocketNonceKey> = []
        var handlerReservations: [Int32: AuthenticatedLocalSocketHandlerReservation] = [:]
        var resources: AuthenticatedLocalSocketInstanceResources?
        var stopOperation: AuthenticatedLocalSocketStopOperation?
    }

    private struct FrozenInstance: Sendable {
        let operation: AuthenticatedLocalSocketStopOperation
        let resources: AuthenticatedLocalSocketInstanceResources?
        let listenerFileDescriptor: Int32?
        let stoppedOwnedClients: Bool
    }

    private static let directoryTemplate = "quicktty.XXXXXX"
    private static let maximumAuthenticatedNonces = 65_536
    private static let acceptReadinessPollMilliseconds: Int32 = 100

    private let socketFileName: String
    private let temporaryBaseDirectory: String
    private let expectedUID: uid_t
    private let peerValidator: PeerValidator
    private let maximumConnections: Int
    private let connectionTimeoutMilliseconds: Int
    private let acceptFunction: AcceptFunction
    private let acceptRetryBackoff: AcceptRetryBackoff
    private let instanceDirectoryOpenFunction: InstanceDirectoryOpenFunction
    private let instanceDirectoryFstatFunction: InstanceDirectoryFstatFunction
    private let socketWriteFunction: SocketWriteFunction
    private let rejectedConnectionResponse: Data
    private let handlerStopPolicy: AuthenticatedLocalSocketHandlerStopPolicy
    private let handlerExecutionPool: AuthenticatedLocalSocketHandlerExecutionPool
    private let handlerCancellationQueue: AuthenticatedLocalSocketHandlerCancellationQueue
    private let disconnectMonitorIdleObserver: DisconnectMonitorIdleObserver
    private let handlerWaiterRegistrationObserver: HandlerWaiterRegistrationObserver
    private let handlerCancellationTransitionObserver: HandlerCancellationTransitionObserver
    private let handlerClientCloseObserver: HandlerClientCloseObserver
    private let responseWriteObserver: ResponseWriteObserver
    private let stopClientShutdownObserver: StopClientShutdownObserver
    private let clientShutdownFunction: ClientShutdownFunction
    private let clientCloseFunction: ClientCloseFunction
    private let listenerShutdownFunction: ListenerShutdownFunction
    private let listenerCloseFunction: ListenerCloseFunction
    private let listenerCloseObserver: ListenerCloseObserver
    private let acceptFileDescriptorCloseObserver: AcceptFileDescriptorCloseObserver
    private let connectionProcessor: ConnectionProcessor
    private let lifecycle = Mutex(())
    private let state = Mutex(State())
    private let handlerGroup = DispatchGroup()
    private let acceptQueue: DispatchQueue
    private let connectionQueue: DispatchQueue
    private let cleanupQueue: DispatchQueue

    init(
        serviceName: String,
        socketFileName: String,
        temporaryBaseDirectory: String,
        expectedUID: uid_t,
        peerValidator: @escaping PeerValidator = AuthenticatedLocalSocketServer.validatePeer,
        maximumConnections: Int,
        connectionTimeoutMilliseconds: Int,
        acceptFunction: @escaping AcceptFunction,
        acceptRetryBackoff: @escaping AcceptRetryBackoff,
        instanceDirectoryOpenFunction: @escaping InstanceDirectoryOpenFunction = {
            Darwin.open($0, $1)
        },
        instanceDirectoryFstatFunction: @escaping InstanceDirectoryFstatFunction = {
            Darwin.fstat($0, $1)
        },
        socketWriteFunction: @escaping SocketWriteFunction = { Darwin.write($0, $1, $2) },
        rejectedConnectionResponse: Data,
        handlerStopPolicy: AuthenticatedLocalSocketHandlerStopPolicy,
        maximumExecutingHandlers: Int,
        handlerExecutionReleaseObserver: @escaping @Sendable () -> Void = {},
        handlerCancellationEnqueueObserver: @escaping @Sendable () -> Void = {},
        handlerCancellationDeliveryObserver: @escaping @Sendable () -> Void = {},
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
        listenerShutdownFunction: @escaping ListenerShutdownFunction = {
            _ = Darwin.shutdown($0, $1)
        },
        listenerCloseFunction: @escaping ListenerCloseFunction = { _ = Darwin.close($0) },
        listenerCloseObserver: @escaping ListenerCloseObserver = { _ in },
        acceptFileDescriptorCloseObserver: @escaping AcceptFileDescriptorCloseObserver = { _ in },
        connectionProcessor: @escaping ConnectionProcessor
    ) {
        precondition((1...256).contains(maximumConnections))
        precondition((1...256).contains(maximumExecutingHandlers))
        precondition((1...60_000).contains(connectionTimeoutMilliseconds))
        precondition(!socketFileName.isEmpty && !socketFileName.contains("/"))
        self.socketFileName = socketFileName
        self.temporaryBaseDirectory = temporaryBaseDirectory
        self.expectedUID = expectedUID
        self.peerValidator = peerValidator
        self.maximumConnections = maximumConnections
        self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
        self.acceptFunction = acceptFunction
        self.acceptRetryBackoff = acceptRetryBackoff
        self.instanceDirectoryOpenFunction = instanceDirectoryOpenFunction
        self.instanceDirectoryFstatFunction = instanceDirectoryFstatFunction
        self.socketWriteFunction = socketWriteFunction
        self.rejectedConnectionResponse = rejectedConnectionResponse
        self.handlerStopPolicy = handlerStopPolicy
        handlerExecutionPool = AuthenticatedLocalSocketHandlerExecutionPool(
            capacity: maximumExecutingHandlers,
            releaseObserver: handlerExecutionReleaseObserver
        )
        handlerCancellationQueue = AuthenticatedLocalSocketHandlerCancellationQueue(
            serviceName: serviceName,
            enqueueObserver: handlerCancellationEnqueueObserver,
            deliveryObserver: handlerCancellationDeliveryObserver
        )
        self.disconnectMonitorIdleObserver = disconnectMonitorIdleObserver
        self.handlerWaiterRegistrationObserver = handlerWaiterRegistrationObserver
        self.handlerCancellationTransitionObserver = handlerCancellationTransitionObserver
        self.handlerClientCloseObserver = handlerClientCloseObserver
        self.responseWriteObserver = responseWriteObserver
        self.stopClientShutdownObserver = stopClientShutdownObserver
        self.clientShutdownFunction = clientShutdownFunction
        self.clientCloseFunction = clientCloseFunction
        self.listenerShutdownFunction = listenerShutdownFunction
        self.listenerCloseFunction = listenerCloseFunction
        self.listenerCloseObserver = listenerCloseObserver
        self.acceptFileDescriptorCloseObserver = acceptFileDescriptorCloseObserver
        self.connectionProcessor = connectionProcessor
        acceptQueue = DispatchQueue(label: "com.dntsk.QuickTTY.\(serviceName).accept")
        connectionQueue = DispatchQueue(
            label: "com.dntsk.QuickTTY.\(serviceName).connections",
            attributes: .concurrent
        )
        cleanupQueue = DispatchQueue(label: "com.dntsk.QuickTTY.\(serviceName).cleanup")
    }

    deinit {
        stopImmediately()
    }

    var socketPath: String? {
        state.withLock { $0.resources?.socketPath }
    }

    @discardableResult
    func start() throws -> String {
        try lifecycle.withLock { _ in
            if let socketPath = state.withLock({ state -> String? in
                guard state.listenerFileDescriptor != nil, state.stopOperation == nil else {
                    return nil
                }
                return state.resources?.socketPath
            }) {
                return socketPath
            }

            try state.withLock { state in
                if let operation = state.stopOperation {
                    guard operation.completion.wait(timeout: .now()) == .success else {
                        throw AuthenticatedLocalSocketServerError.stopInProgress
                    }
                    state.stopOperation = nil
                }
            }

            let startedInstance = try createInstance(
                temporaryBaseDirectory: temporaryBaseDirectory,
                socketFileName: socketFileName
            )
            let generation = state.withLock { state in
                state.generation &+= 1
                state.listenerFileDescriptor = startedInstance.listenerFileDescriptor
                state.authenticatedNonces.removeAll(keepingCapacity: false)
                state.resources = startedInstance.resources
                return state.generation
            }

            acceptQueue.async { [self] in
                acceptConnections(
                    ownedAcceptFileDescriptor: startedInstance.acceptFileDescriptor,
                    listenerIdentityFileDescriptor: startedInstance.listenerFileDescriptor,
                    generation: generation
                )
            }
            return startedInstance.resources.socketPath
        }
    }

    func stop() async {
        guard let operation = freezeAndScheduleCleanup() else {
            return
        }
        let cleanupQueue = cleanupQueue
        await withCheckedContinuation { continuation in
            cleanupQueue.async {
                operation.completion.wait()
                continuation.resume()
            }
        }
    }

    func stopImmediately() {
        _ = freezeAndScheduleCleanup()
    }

    private func freezeAndScheduleCleanup(
        expectedListenerFileDescriptor: Int32? = nil,
        expectedGeneration: UInt64? = nil
    ) -> AuthenticatedLocalSocketStopOperation? {
        lifecycle.withLock { _ in
            let frozenInstance = state.withLock { state -> FrozenInstance? in
                if let expectedListenerFileDescriptor, let expectedGeneration {
                    guard state.generation == expectedGeneration,
                        state.listenerFileDescriptor == expectedListenerFileDescriptor
                    else {
                        return nil
                    }
                }
                if let operation = state.stopOperation {
                    return FrozenInstance(
                        operation: operation,
                        resources: nil,
                        listenerFileDescriptor: nil,
                        stoppedOwnedClients: false
                    )
                }
                guard
                    state.listenerFileDescriptor != nil || state.resources != nil
                        || !state.clients.isEmpty
                else {
                    return nil
                }

                state.generation &+= 1
                state.authenticatedNonces.removeAll(keepingCapacity: false)
                let operation = AuthenticatedLocalSocketStopOperation()
                state.stopOperation = operation

                let listenerFileDescriptor = state.listenerFileDescriptor
                state.listenerFileDescriptor = nil
                let clientFileDescriptors = Array(state.clients.keys)
                if handlerStopPolicy == .cancel {
                    for reservation in state.handlerReservations.values {
                        reservation.invalidateCancellationLease()
                    }
                }
                for fileDescriptor in clientFileDescriptors {
                    precondition(state.clients[fileDescriptor] != nil)
                    clientShutdownFunction(fileDescriptor, SHUT_WR)
                    clientShutdownFunction(fileDescriptor, SHUT_RD)
                }

                let resources = state.resources
                state.resources = nil
                return FrozenInstance(
                    operation: operation,
                    resources: resources,
                    listenerFileDescriptor: listenerFileDescriptor,
                    stoppedOwnedClients: !clientFileDescriptors.isEmpty
                )
            }

            guard let frozenInstance else {
                return nil
            }
            if frozenInstance.stoppedOwnedClients {
                stopClientShutdownObserver()
            }
            if let listenerFileDescriptor = frozenInstance.listenerFileDescriptor {
                listenerShutdownFunction(listenerFileDescriptor, SHUT_RDWR)
                listenerCloseFunction(listenerFileDescriptor)
                listenerCloseObserver(listenerFileDescriptor)
            }

            guard let resources = frozenInstance.resources else {
                return frozenInstance.operation
            }

            let socketEntryRemoved = Self.unlinkPinnedSocket(
                instanceDirectoryFileDescriptor: resources.instanceDirectoryFileDescriptor,
                socketFileName: resources.socketFileName,
                socketIdentity: resources.socketIdentity
            )
            assert(socketEntryRemoved, "Authenticated socket entry must be removed during stop")

            let acceptQueue = acceptQueue
            let connectionQueue = connectionQueue
            let handlerGroup = handlerGroup
            cleanupQueue.async { [self] in
                acceptQueue.sync {}
                connectionQueue.sync(flags: .barrier) {}
                handlerGroup.wait()
                assert(state.withLock { $0.clients.isEmpty })
                Self.cleanUp(resources)
                frozenInstance.operation.completion.leave()
            }
            return frozenInstance.operation
        }
    }

    private func acceptConnections(
        ownedAcceptFileDescriptor: Int32,
        listenerIdentityFileDescriptor: Int32,
        generation: UInt64
    ) {
        defer {
            Darwin.close(ownedAcceptFileDescriptor)
            acceptFileDescriptorCloseObserver(ownedAcceptFileDescriptor)
        }
        while isCurrentListener(listenerIdentityFileDescriptor, generation: generation) {
            var descriptor = pollfd(
                fd: ownedAcceptFileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Self.acceptReadinessPollMilliseconds
            )
            let pollError = errno
            guard
                isCurrentListener(
                    listenerIdentityFileDescriptor,
                    generation: generation
                )
            else {
                return
            }
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if pollError == EINTR {
                    continue
                }
                _ = freezeAndScheduleCleanup(
                    expectedListenerFileDescriptor: listenerIdentityFileDescriptor,
                    expectedGeneration: generation
                )
                return
            }

            let acceptResult = acceptFunction(ownedAcceptFileDescriptor)
            let clientFileDescriptor = acceptResult.fileDescriptor
            if clientFileDescriptor < 0 {
                guard
                    isCurrentListener(
                        listenerIdentityFileDescriptor,
                        generation: generation
                    )
                else {
                    return
                }
                switch acceptResult.errorCode {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    acceptRetryBackoff()
                    continue
                default:
                    _ = freezeAndScheduleCleanup(
                        expectedListenerFileDescriptor: listenerIdentityFileDescriptor,
                        expectedGeneration: generation
                    )
                    return
                }
            }

            guard configureAcceptedSocket(clientFileDescriptor),
                let deadlineNanoseconds = try? makeDeadlineNanoseconds(
                    timeoutMilliseconds: connectionTimeoutMilliseconds
                ),
                registerClient(clientFileDescriptor, generation: generation)
            else {
                Darwin.close(clientFileDescriptor)
                continue
            }

            connectionQueue.async { [self] in
                processConnection(
                    clientFileDescriptor,
                    generation: generation,
                    deadlineNanoseconds: deadlineNanoseconds
                )
            }
        }
    }

    private func processConnection(
        _ fileDescriptor: Int32,
        generation: UInt64,
        deadlineNanoseconds: UInt64
    ) {
        guard ownsClient(fileDescriptor, generation: generation) else {
            return
        }
        guard peerValidator(fileDescriptor, expectedUID) else {
            finishClientImmediately(
                fileDescriptor,
                generation: generation,
                response: rejectedConnectionResponse
            )
            return
        }
        connectionProcessor(
            AuthenticatedLocalSocketConnection(
                runtime: self,
                fileDescriptor: fileDescriptor,
                generation: generation,
                deadlineNanoseconds: deadlineNanoseconds
            )
        )
    }

    fileprivate func readFrame(
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64,
        maximumPayloadSize: Int,
        authenticationCodeSize: Int,
        requireEndOfStream: Bool,
        frameBodyReadObserver: @Sendable () -> Void
    ) throws -> Data {
        let headerSize = MemoryLayout<UInt32>.size
        guard
            let header = try readExactly(
                headerSize,
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
        else {
            throw AuthenticatedLocalSocketServerError.invalidFrame
        }
        let declaredLength = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard declaredLength > 0, declaredLength <= UInt32(maximumPayloadSize) else {
            throw AuthenticatedLocalSocketServerError.invalidFrame
        }
        let bodySize = Int(declaredLength) + authenticationCodeSize
        guard
            let body = try readExactly(
                bodySize,
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
        else {
            throw AuthenticatedLocalSocketServerError.invalidFrame
        }
        frameBodyReadObserver()
        if requireEndOfStream {
            guard
                try readByte(
                    from: fileDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                ) == nil
            else {
                throw AuthenticatedLocalSocketServerError.invalidFrame
            }
        } else if try hasBufferedTrailingByte(fileDescriptor) {
            throw AuthenticatedLocalSocketServerError.invalidFrame
        }

        var frame = Data(capacity: header.count + body.count)
        frame.append(header)
        frame.append(body)
        return frame
    }

    fileprivate func readExactly(
        _ count: Int,
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> Data? {
        guard count >= 0 else {
            throw AuthenticatedLocalSocketServerError.invalidFrame
        }
        if count == 0 {
            return Data()
        }
        var data = Data(count: count)
        let bytesRead = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < count {
                try waitUntilReadable(
                    fileDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                let result = Darwin.read(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    return offset
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw AuthenticatedLocalSocketServerError.systemCall("read", errno)
                }
            }
            return offset
        }
        return bytesRead == count ? data : nil
    }

    fileprivate func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try waitUntilWritable(
                    fileDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                let result = socketWriteFunction(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0,
                    errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
                {
                    continue
                } else {
                    throw AuthenticatedLocalSocketServerError.systemCall("write", errno)
                }
            }
        }
    }

    fileprivate func reserveNonce(
        _ key: AuthenticatedLocalSocketNonceKey,
        generation: UInt64
    ) -> Bool {
        state.withLock { state in
            guard state.generation == generation,
                state.authenticatedNonces.count < Self.maximumAuthenticatedNonces
            else {
                return false
            }
            return state.authenticatedNonces.insert(key).inserted
        }
    }

    fileprivate func runHandler(
        fileDescriptor: Int32,
        generation: UInt64,
        timeoutMilliseconds: Int?,
        timeoutResponse: Data?,
        monitorDisconnect: Bool,
        responseWriteTimeoutMilliseconds: Int?,
        operation: @escaping @Sendable (AuthenticatedLocalSocketCancellationLease) async -> Data?
    ) -> Bool {
        guard let executionCompletion = handlerExecutionPool.acquire() else {
            return false
        }
        let reservation = AuthenticatedLocalSocketHandlerReservation()
        let reserved = state.withLock { state in
            guard state.generation == generation,
                state.clients[fileDescriptor]?.generation == generation,
                state.clients[fileDescriptor]?.phase == .handling,
                state.handlerReservations[fileDescriptor] == nil
            else {
                return false
            }
            state.handlerReservations[fileDescriptor] = reservation
            handlerGroup.enter()
            return true
        }
        guard reserved else {
            executionCompletion.finish()
            return false
        }

        let cancellationLease = reservation.cancellationLease
        Task { [self] in
            let result = await Self.runBoundedHandler(
                fileDescriptor: fileDescriptor,
                timeoutMilliseconds: timeoutMilliseconds,
                timeoutResponse: timeoutResponse,
                monitorDisconnect: monitorDisconnect,
                cancellationLease: cancellationLease,
                executionCompletion: executionCompletion,
                cancellationQueue: handlerCancellationQueue,
                disconnectMonitorIdleObserver: disconnectMonitorIdleObserver,
                handlerWaiterRegistrationObserver: handlerWaiterRegistrationObserver,
                handlerCancellationTransitionObserver: handlerCancellationTransitionObserver,
                operation: operation
            )
            connectionQueue.async { [self] in
                completeHandler(
                    fileDescriptor: fileDescriptor,
                    generation: generation,
                    reservation: reservation,
                    response: result.response,
                    responseWriteTimeoutMilliseconds: responseWriteTimeoutMilliseconds,
                    cancellationRequest: result.cancellationRequest
                )
            }
        }
        return true
    }

    private static func runBoundedHandler(
        fileDescriptor: Int32,
        timeoutMilliseconds: Int?,
        timeoutResponse: Data?,
        monitorDisconnect: Bool,
        cancellationLease: AuthenticatedLocalSocketCancellationLease,
        executionCompletion: AuthenticatedLocalSocketHandlerExecutionCompletion,
        cancellationQueue: AuthenticatedLocalSocketHandlerCancellationQueue,
        disconnectMonitorIdleObserver: @escaping DisconnectMonitorIdleObserver,
        handlerWaiterRegistrationObserver: @escaping HandlerWaiterRegistrationObserver,
        handlerCancellationTransitionObserver: @escaping HandlerCancellationTransitionObserver,
        operation: @escaping @Sendable (AuthenticatedLocalSocketCancellationLease) async -> Data?
    ) async -> AuthenticatedLocalSocketHandlerTransportResult {
        guard timeoutMilliseconds != nil || monitorDisconnect else {
            guard cancellationLease.beginInvocation() else {
                executionCompletion.finish()
                return AuthenticatedLocalSocketHandlerTransportResult(
                    response: nil,
                    cancellationRequest: nil
                )
            }
            defer {
                cancellationLease.cancel()
                executionCompletion.finish()
            }
            return AuthenticatedLocalSocketHandlerTransportResult(
                response: await operation(cancellationLease),
                cancellationRequest: nil
            )
        }

        let relay = AuthenticatedLocalSocketHandlerRelay(
            cancellationLease: cancellationLease,
            waiterRegistrationObserver: handlerWaiterRegistrationObserver,
            cancellationTransitionObserver: handlerCancellationTransitionObserver
        )
        let executionLifetime = AuthenticatedLocalSocketHandlerExecutionLifetime(
            completion: executionCompletion
        )
        // This task may outlive the transport when arbitrary handler code ignores cancellation.
        // It therefore owns no server or socket, only immutable work and bounded release state.
        let handlerTask = Task {
            guard cancellationLease.beginInvocation() else {
                executionLifetime.handlerFinished()
                relay.resolveCancellation(.cancelled)
                return
            }
            defer {
                cancellationLease.cancel()
                executionLifetime.handlerFinished()
            }
            relay.resolveResponse(await operation(cancellationLease))
        }
        let timeoutTask: Task<Void, Never>? = timeoutMilliseconds.map { timeoutMilliseconds in
            Task {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000
                    )
                    relay.resolveCancellation(.timeout)
                } catch {}
            }
        }
        let disconnectTask: Task<Void, Never>? =
            monitorDisconnect
            ? Task {
                if await monitorClientDisconnect(
                    fileDescriptor,
                    idleObserver: disconnectMonitorIdleObserver
                ) {
                    relay.resolveCancellation(.disconnected)
                }
            } : nil

        let outcome = await withTaskCancellationHandler {
            await relay.wait()
        } onCancel: {
            relay.resolveCancellation(.cancelled)
        }
        let response: Data?
        let cancellationRequest: AuthenticatedLocalSocketHandlerCancellationRequest?
        switch outcome {
        case .response(let handlerResponse):
            response = handlerResponse
            cancellationRequest = nil
            executionLifetime.cancellationNotRequired()
        case .timeout:
            response = timeoutResponse
            cancellationRequest = AuthenticatedLocalSocketHandlerCancellationRequest(
                task: handlerTask,
                executionLifetime: executionLifetime,
                cancellationQueue: cancellationQueue
            )
        case .disconnected, .cancelled:
            response = nil
            cancellationRequest = AuthenticatedLocalSocketHandlerCancellationRequest(
                task: handlerTask,
                executionLifetime: executionLifetime,
                cancellationQueue: cancellationQueue
            )
        }

        timeoutTask?.cancel()
        disconnectTask?.cancel()
        if let timeoutTask {
            await timeoutTask.value
        }
        if let disconnectTask {
            await disconnectTask.value
        }
        return AuthenticatedLocalSocketHandlerTransportResult(
            response: response,
            cancellationRequest: cancellationRequest
        )
    }

    private static func monitorClientDisconnect(
        _ fileDescriptor: Int32,
        idleObserver: @escaping DisconnectMonitorIdleObserver
    ) async -> Bool {
        let queue = Darwin.kqueue()
        guard queue >= 0 else { return true }
        defer { Darwin.close(queue) }

        var change = kevent64_s(
            ident: UInt64(fileDescriptor),
            filter: Int16(EVFILT_WRITE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        while kevent64(queue, &change, 1, nil, 0, 0, nil) != 0 {
            guard errno == EINTR else { return true }
            guard !Task.isCancelled else { return false }
        }

        while !Task.isCancelled {
            var event = kevent64_s()
            var timeout = timespec(tv_sec: 0, tv_nsec: 50_000_000)
            let result = kevent64(queue, nil, 0, &event, 1, 0, &timeout)
            if result == 0 {
                idleObserver()
            }
            if result > 0, event.flags & UInt16(EV_EOF | EV_ERROR) != 0 {
                return true
            }
            if result < 0, errno != EINTR {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func completeHandler(
        fileDescriptor: Int32,
        generation: UInt64,
        reservation: AuthenticatedLocalSocketHandlerReservation,
        response: Data?,
        responseWriteTimeoutMilliseconds: Int?,
        cancellationRequest: AuthenticatedLocalSocketHandlerCancellationRequest?
    ) {
        let shouldRespond = state.withLock { state -> Bool? in
            guard state.handlerReservations[fileDescriptor] === reservation,
                state.clients[fileDescriptor]?.generation == generation,
                state.clients[fileDescriptor]?.phase == .handling
            else {
                return nil
            }
            reservation.invalidateCancellationLease()
            state.handlerReservations.removeValue(forKey: fileDescriptor)
            state.clients[fileDescriptor]?.phase = .writing
            return state.generation == generation
        }
        guard let shouldRespond else { return }

        if shouldRespond, let response {
            responseWriteObserver()
            if let responseWriteTimeoutMilliseconds,
                let deadline = try? makeDeadlineNanoseconds(
                    timeoutMilliseconds: responseWriteTimeoutMilliseconds
                )
            {
                try? writeAll(response, to: fileDescriptor, deadlineNanoseconds: deadline)
            } else {
                writeImmediatelyIfPossible(response, to: fileDescriptor)
            }
        }
        let shouldClose = state.withLock { state -> Bool in
            guard state.clients[fileDescriptor]?.generation == generation,
                state.clients[fileDescriptor]?.phase == .writing
            else {
                return false
            }
            state.clients.removeValue(forKey: fileDescriptor)
            return true
        }
        if shouldClose {
            clientCloseFunction(fileDescriptor)
            handlerClientCloseObserver()
        }
        reservation.finish()
        handlerGroup.leave()
        cancellationRequest?.deliver()
    }

    fileprivate func finishClientImmediately(
        _ fileDescriptor: Int32,
        generation: UInt64,
        response: Data
    ) {
        let shouldRespond = state.withLock { state -> Bool? in
            guard state.clients[fileDescriptor]?.generation == generation,
                state.clients[fileDescriptor]?.phase == .handling,
                state.handlerReservations[fileDescriptor] == nil
            else {
                return nil
            }
            state.clients[fileDescriptor]?.phase = .writing
            return state.generation == generation
        }
        guard let shouldRespond else { return }
        if shouldRespond {
            writeImmediatelyIfPossible(response, to: fileDescriptor)
        }
        let shouldClose = state.withLock { state -> Bool in
            guard state.clients[fileDescriptor]?.generation == generation,
                state.clients[fileDescriptor]?.phase == .writing
            else {
                return false
            }
            state.clients.removeValue(forKey: fileDescriptor)
            return true
        }
        if shouldClose {
            clientCloseFunction(fileDescriptor)
        }
    }

    private func writeImmediatelyIfPossible(_ data: Data, to fileDescriptor: Int32) {
        guard !data.isEmpty else { return }
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, 0)
            if result > 0 {
                guard descriptor.revents & Int16(POLLOUT) != 0 else { return }
                break
            }
            if result == 0 || errno != EINTR { return }
        }

        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = socketWriteFunction(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private func readByte(
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> UInt8? {
        var byte: UInt8 = 0
        while true {
            try waitUntilReadable(fileDescriptor, deadlineNanoseconds: deadlineNanoseconds)
            let result = Darwin.read(fileDescriptor, &byte, 1)
            if result == 1 { return byte }
            if result == 0 { return nil }
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw AuthenticatedLocalSocketServerError.systemCall("read", errno)
            }
        }
    }

    private func hasBufferedTrailingByte(_ fileDescriptor: Int32) throws -> Bool {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, 0)
            if result > 0 {
                guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
                var byte: UInt8 = 0
                let received = Darwin.recv(fileDescriptor, &byte, 1, MSG_PEEK)
                return received > 0
            }
            if result == 0 { return false }
            if errno != EINTR {
                throw AuthenticatedLocalSocketServerError.systemCall("poll", errno)
            }
        }
    }

    private func waitUntilReadable(
        _ fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws {
        try wait(
            fileDescriptor,
            events: Int16(POLLIN),
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    private func waitUntilWritable(
        _ fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws {
        try wait(
            fileDescriptor,
            events: Int16(POLLOUT),
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    private func wait(
        _ fileDescriptor: Int32,
        events: Int16,
        deadlineNanoseconds: UInt64
    ) throws {
        while true {
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let currentNanoseconds = try monotonicNanoseconds()
            guard currentNanoseconds < deadlineNanoseconds else {
                throw AuthenticatedLocalSocketServerError.connectionTimedOut
            }
            let remainingNanoseconds = deadlineNanoseconds - currentNanoseconds
            let remainingMilliseconds = Int32((remainingNanoseconds + 999_999) / 1_000_000)
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result > 0 {
                guard try monotonicNanoseconds() <= deadlineNanoseconds else {
                    throw AuthenticatedLocalSocketServerError.connectionTimedOut
                }
                return
            }
            if result == 0 {
                throw AuthenticatedLocalSocketServerError.connectionTimedOut
            }
            if errno != EINTR {
                throw AuthenticatedLocalSocketServerError.systemCall("poll", errno)
            }
        }
    }

    private func makeDeadlineNanoseconds(timeoutMilliseconds: Int) throws -> UInt64 {
        let now = try monotonicNanoseconds()
        let (deadline, overflow) = now.addingReportingOverflow(
            UInt64(timeoutMilliseconds) * 1_000_000
        )
        guard !overflow else {
            throw AuthenticatedLocalSocketServerError.connectionTimedOut
        }
        return deadline
    }

    private func monotonicNanoseconds() throws -> UInt64 {
        var currentTime = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &currentTime) == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("clock_gettime", errno)
        }
        return UInt64(currentTime.tv_sec) * 1_000_000_000 + UInt64(currentTime.tv_nsec)
    }

    private func isCurrentListener(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock {
            $0.generation == generation && $0.listenerFileDescriptor == fileDescriptor
        }
    }

    private func registerClient(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, state.listenerFileDescriptor != nil,
                state.clients.count < maximumConnections
            else {
                return false
            }
            state.clients[fileDescriptor] = ClientRegistration(
                generation: generation,
                phase: .handling
            )
            return true
        }
    }

    private func ownsClient(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock {
            $0.clients[fileDescriptor]?.generation == generation
                && $0.clients[fileDescriptor]?.phase == .handling
        }
    }

    private func configureAcceptedSocket(_ fileDescriptor: Int32) -> Bool {
        guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        do {
            try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
            try AgentSocketIO.makeNonblocking(fileDescriptor)
            return true
        } catch {
            return false
        }
    }

    static func validatePeer(_ fileDescriptor: Int32, expectedUID: uid_t) -> Bool {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        return getpeereid(fileDescriptor, &effectiveUID, &effectiveGID) == 0
            && effectiveUID == expectedUID
    }

    private func createInstance(
        temporaryBaseDirectory: String,
        socketFileName: String
    ) throws -> AuthenticatedLocalSocketStartedInstance {
        guard temporaryBaseDirectory.hasPrefix("/"), !temporaryBaseDirectory.utf8.contains(0) else {
            throw AuthenticatedLocalSocketServerError.invalidTemporaryBaseDirectory
        }

        var normalizedBase = temporaryBaseDirectory
        while normalizedBase.count > 1, normalizedBase.hasSuffix("/") {
            normalizedBase.removeLast()
        }
        let baseDirectoryFileDescriptor = Darwin.open(
            normalizedBase,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard baseDirectoryFileDescriptor >= 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("open", errno)
        }

        var instanceDirectoryPath: String?
        var instanceDirectoryName: String?
        var instanceDirectoryFileDescriptor: Int32 = -1
        var instanceDirectoryIdentity: AuthenticatedLocalSocketEntryIdentity?
        var socketIdentity: AuthenticatedLocalSocketEntryIdentity?
        var listenerFileDescriptor: Int32 = -1
        var acceptFileDescriptor: Int32 = -1
        var succeeded = false
        defer {
            if !succeeded {
                if acceptFileDescriptor >= 0 { Darwin.close(acceptFileDescriptor) }
                if listenerFileDescriptor >= 0 { Darwin.close(listenerFileDescriptor) }
                if instanceDirectoryFileDescriptor >= 0 {
                    if let socketIdentity {
                        _ = Self.unlinkPinnedSocket(
                            instanceDirectoryFileDescriptor: instanceDirectoryFileDescriptor,
                            socketFileName: socketFileName,
                            socketIdentity: socketIdentity
                        )
                    }
                    Darwin.close(instanceDirectoryFileDescriptor)
                }
                if let instanceDirectoryName {
                    if let instanceDirectoryIdentity {
                        Self.removePinnedInstanceDirectory(
                            baseDirectoryFileDescriptor: baseDirectoryFileDescriptor,
                            instanceDirectoryName: instanceDirectoryName,
                            identity: instanceDirectoryIdentity
                        )
                    } else {
                        unlinkat(
                            baseDirectoryFileDescriptor,
                            instanceDirectoryName,
                            AT_REMOVEDIR
                        )
                    }
                }
                Darwin.close(baseDirectoryFileDescriptor)
            }
        }

        var template = Array("\(normalizedBase)/\(Self.directoryTemplate)".utf8CString)
        instanceDirectoryPath = template.withUnsafeMutableBufferPointer { buffer in
            guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: result)
        }
        guard let instanceDirectoryPath else {
            throw AuthenticatedLocalSocketServerError.systemCall("mkdtemp", errno)
        }
        instanceDirectoryName = URL(fileURLWithPath: instanceDirectoryPath).lastPathComponent

        instanceDirectoryFileDescriptor = instanceDirectoryOpenFunction(
            instanceDirectoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard instanceDirectoryFileDescriptor >= 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("open", errno)
        }
        var instanceDirectoryStatus = stat()
        guard
            instanceDirectoryFstatFunction(
                instanceDirectoryFileDescriptor,
                &instanceDirectoryStatus
            ) == 0
        else {
            throw AuthenticatedLocalSocketServerError.systemCall("fstat", errno)
        }
        instanceDirectoryIdentity = AuthenticatedLocalSocketEntryIdentity(
            device: instanceDirectoryStatus.st_dev,
            inode: instanceDirectoryStatus.st_ino
        )
        guard fchmod(instanceDirectoryFileDescriptor, 0o700) == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("fchmod", errno)
        }

        let socketPath = "\(instanceDirectoryPath)/\(socketFileName)"
        var address: AgentUnixSocketAddress
        do {
            address = try AgentUnixSocketAddress(path: socketPath)
        } catch {
            throw AuthenticatedLocalSocketServerError.invalidSocketPath
        }

        listenerFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFileDescriptor >= 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("socket", errno)
        }
        guard fcntl(listenerFileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("fcntl", errno)
        }
        var noSIGPIPE: Int32 = 1
        guard
            setsockopt(
                listenerFileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSIGPIPE,
                socklen_t(MemoryLayout.size(ofValue: noSIGPIPE))
            ) == 0
        else {
            throw AuthenticatedLocalSocketServerError.systemCall("setsockopt", errno)
        }

        let bindResult = address.withSockAddr { pointer, length in
            Darwin.bind(listenerFileDescriptor, pointer, length)
        }
        guard bindResult == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("bind", errno)
        }
        var socketStatus = stat()
        guard
            fstatat(
                instanceDirectoryFileDescriptor,
                socketFileName,
                &socketStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            throw AuthenticatedLocalSocketServerError.systemCall("fstatat", errno)
        }
        guard socketStatus.st_mode & S_IFMT == S_IFSOCK else {
            throw AuthenticatedLocalSocketServerError.systemCall("fstatat", EINVAL)
        }
        socketIdentity = AuthenticatedLocalSocketEntryIdentity(
            device: socketStatus.st_dev,
            inode: socketStatus.st_ino
        )
        guard fchmodat(instanceDirectoryFileDescriptor, socketFileName, 0o600, 0) == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("fchmodat", errno)
        }
        guard Darwin.listen(listenerFileDescriptor, 16) == 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("listen", errno)
        }
        do {
            try AgentSocketIO.makeNonblocking(listenerFileDescriptor)
        } catch {
            throw AuthenticatedLocalSocketServerError.systemCall("fcntl", errno)
        }
        acceptFileDescriptor = fcntl(listenerFileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard acceptFileDescriptor >= 0 else {
            throw AuthenticatedLocalSocketServerError.systemCall("fcntl", errno)
        }
        guard let instanceDirectoryName, let instanceDirectoryIdentity, let socketIdentity else {
            throw AuthenticatedLocalSocketServerError.systemCall("fstat", EINVAL)
        }

        succeeded = true
        return AuthenticatedLocalSocketStartedInstance(
            resources: AuthenticatedLocalSocketInstanceResources(
                baseDirectoryFileDescriptor: baseDirectoryFileDescriptor,
                instanceDirectoryFileDescriptor: instanceDirectoryFileDescriptor,
                instanceDirectoryIdentity: instanceDirectoryIdentity,
                socketIdentity: socketIdentity,
                instanceDirectoryName: instanceDirectoryName,
                socketFileName: socketFileName,
                socketPath: socketPath
            ),
            listenerFileDescriptor: listenerFileDescriptor,
            acceptFileDescriptor: acceptFileDescriptor
        )
    }

    private static func cleanUp(_ resources: AuthenticatedLocalSocketInstanceResources) {
        let socketEntryRemoved = unlinkPinnedSocket(
            instanceDirectoryFileDescriptor: resources.instanceDirectoryFileDescriptor,
            socketFileName: resources.socketFileName,
            socketIdentity: resources.socketIdentity
        )
        assert(socketEntryRemoved, "Authenticated socket cleanup failed")
        Darwin.close(resources.instanceDirectoryFileDescriptor)
        removePinnedInstanceDirectory(
            baseDirectoryFileDescriptor: resources.baseDirectoryFileDescriptor,
            instanceDirectoryName: resources.instanceDirectoryName,
            identity: resources.instanceDirectoryIdentity
        )
        Darwin.close(resources.baseDirectoryFileDescriptor)
    }

    private static func unlinkPinnedSocket(
        instanceDirectoryFileDescriptor: Int32,
        socketFileName: String,
        socketIdentity: AuthenticatedLocalSocketEntryIdentity
    ) -> Bool {
        var socketStatus = stat()
        guard
            fstatat(
                instanceDirectoryFileDescriptor,
                socketFileName,
                &socketStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            return errno == ENOENT
        }
        guard socketStatus.st_mode & S_IFMT == S_IFSOCK,
            socketStatus.st_dev == socketIdentity.device,
            socketStatus.st_ino == socketIdentity.inode
        else {
            return true
        }
        return unlinkat(instanceDirectoryFileDescriptor, socketFileName, 0) == 0
            || errno == ENOENT
    }

    private static func removePinnedInstanceDirectory(
        baseDirectoryFileDescriptor: Int32,
        instanceDirectoryName: String,
        identity: AuthenticatedLocalSocketEntryIdentity
    ) {
        var namedStatus = stat()
        guard
            fstatat(
                baseDirectoryFileDescriptor,
                instanceDirectoryName,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            namedStatus.st_mode & S_IFMT == S_IFDIR,
            namedStatus.st_dev == identity.device,
            namedStatus.st_ino == identity.inode
        else {
            return
        }
        unlinkat(baseDirectoryFileDescriptor, instanceDirectoryName, AT_REMOVEDIR)
    }
}

private enum AuthenticatedLocalSocketHandlerOutcome: Sendable {
    case response(Data?)
    case timeout
    case disconnected
    case cancelled
}

private struct AuthenticatedLocalSocketHandlerTransportResult: Sendable {
    let response: Data?
    let cancellationRequest: AuthenticatedLocalSocketHandlerCancellationRequest?
}

private final class AuthenticatedLocalSocketHandlerRelay: Sendable {
    private typealias Continuation =
        CheckedContinuation<AuthenticatedLocalSocketHandlerOutcome, Never>

    private struct State {
        var outcome: AuthenticatedLocalSocketHandlerOutcome?
        var continuation: Continuation?
    }

    private let cancellationLease: AuthenticatedLocalSocketCancellationLease
    private let waiterRegistrationObserver: @Sendable () -> Void
    private let cancellationTransitionObserver:
        @Sendable (AuthenticatedLocalSocketHandlerCancellationReason) -> Void
    private let state = Mutex(State())

    init(
        cancellationLease: AuthenticatedLocalSocketCancellationLease,
        waiterRegistrationObserver: @escaping @Sendable () -> Void,
        cancellationTransitionObserver:
            @escaping @Sendable (
                AuthenticatedLocalSocketHandlerCancellationReason
            ) -> Void
    ) {
        self.cancellationLease = cancellationLease
        self.waiterRegistrationObserver = waiterRegistrationObserver
        self.cancellationTransitionObserver = cancellationTransitionObserver
    }

    func wait() async -> AuthenticatedLocalSocketHandlerOutcome {
        await withCheckedContinuation { continuation in
            let outcome = state.withLock { state -> AuthenticatedLocalSocketHandlerOutcome? in
                if let outcome = state.outcome {
                    return outcome
                }
                precondition(state.continuation == nil)
                state.continuation = continuation
                return nil
            }
            guard let outcome else {
                waiterRegistrationObserver()
                return
            }
            continuation.resume(returning: outcome)
        }
    }

    func resolveResponse(_ response: Data?) {
        resolve(.response(response), cancellationReason: nil)
    }

    func resolveCancellation(_ reason: AuthenticatedLocalSocketHandlerCancellationReason) {
        let outcome: AuthenticatedLocalSocketHandlerOutcome =
            switch reason {
            case .timeout: .timeout
            case .disconnected: .disconnected
            case .cancelled: .cancelled
            }
        resolve(outcome, cancellationReason: reason)
    }

    private func resolve(
        _ outcome: AuthenticatedLocalSocketHandlerOutcome,
        cancellationReason: AuthenticatedLocalSocketHandlerCancellationReason?
    ) {
        let resolution = state.withLock { state -> (won: Bool, continuation: Continuation?) in
            guard state.outcome == nil else { return (false, nil) }
            if cancellationReason != nil {
                cancellationLease.cancel()
            }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        guard resolution.won else { return }
        if let cancellationReason {
            cancellationTransitionObserver(cancellationReason)
        }
        resolution.continuation?.resume(returning: outcome)
    }
}

private final class AuthenticatedLocalSocketHandlerReservation: Sendable {
    let cancellationLease = AuthenticatedLocalSocketCancellationLease()

    func invalidateCancellationLease() {
        cancellationLease.cancel()
    }

    func finish() {
        cancellationLease.cancel()
    }
}

private final class AuthenticatedLocalSocketHandlerExecutionPool: Sendable {
    private struct State {
        var activeCount = 0
    }

    private let capacity: Int
    private let releaseObserver: @Sendable () -> Void
    private let state = Mutex(State())

    init(capacity: Int, releaseObserver: @escaping @Sendable () -> Void) {
        self.capacity = capacity
        self.releaseObserver = releaseObserver
    }

    func acquire() -> AuthenticatedLocalSocketHandlerExecutionCompletion? {
        let acquired = state.withLock { state in
            guard state.activeCount < capacity else { return false }
            state.activeCount += 1
            return true
        }
        return acquired ? AuthenticatedLocalSocketHandlerExecutionCompletion(pool: self) : nil
    }

    fileprivate func release() {
        state.withLock { state in
            precondition(state.activeCount > 0)
            state.activeCount -= 1
        }
        releaseObserver()
    }
}

private final class AuthenticatedLocalSocketHandlerExecutionCompletion: Sendable {
    private let pool: AuthenticatedLocalSocketHandlerExecutionPool
    private let finished = Mutex(false)

    init(pool: AuthenticatedLocalSocketHandlerExecutionPool) {
        self.pool = pool
    }

    func finish() {
        let shouldRelease = finished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldRelease { pool.release() }
    }
}

private final class AuthenticatedLocalSocketHandlerExecutionLifetime: Sendable {
    private struct State {
        var handlerFinished = false
        var cancellationFinished = false
        var executionReleased = false
    }

    private let completion: AuthenticatedLocalSocketHandlerExecutionCompletion
    private let state = Mutex(State())

    init(completion: AuthenticatedLocalSocketHandlerExecutionCompletion) {
        self.completion = completion
    }

    func handlerFinished() {
        finishIfReady { $0.handlerFinished = true }
    }

    func cancellationNotRequired() {
        finishIfReady { $0.cancellationFinished = true }
    }

    func cancellationDeliveryFinished() {
        finishIfReady { $0.cancellationFinished = true }
    }

    private func finishIfReady(_ update: (inout State) -> Void) {
        let shouldRelease = state.withLock { state in
            update(&state)
            guard state.handlerFinished, state.cancellationFinished, !state.executionReleased else {
                return false
            }
            state.executionReleased = true
            return true
        }
        if shouldRelease { completion.finish() }
    }
}

private final class AuthenticatedLocalSocketHandlerCancellationQueue: Sendable {
    private let queue: DispatchQueue
    private let enqueueObserver: @Sendable () -> Void
    private let deliveryObserver: @Sendable () -> Void

    init(
        serviceName: String,
        enqueueObserver: @escaping @Sendable () -> Void,
        deliveryObserver: @escaping @Sendable () -> Void
    ) {
        queue = DispatchQueue(label: "com.dntsk.QuickTTY.\(serviceName).handler-cancellation")
        self.enqueueObserver = enqueueObserver
        self.deliveryObserver = deliveryObserver
    }

    func deliver(
        task: Task<Void, Never>,
        executionLifetime: AuthenticatedLocalSocketHandlerExecutionLifetime
    ) {
        let work = AuthenticatedLocalSocketHandlerCancellationWork(
            task: task,
            executionLifetime: executionLifetime,
            deliveryObserver: deliveryObserver
        )
        enqueueObserver()
        queue.async {
            work.perform()
        }
    }
}

private final class AuthenticatedLocalSocketHandlerCancellationWork: Sendable {
    private let task: Task<Void, Never>
    private let executionLifetime: AuthenticatedLocalSocketHandlerExecutionLifetime
    private let deliveryObserver: @Sendable () -> Void

    init(
        task: Task<Void, Never>,
        executionLifetime: AuthenticatedLocalSocketHandlerExecutionLifetime,
        deliveryObserver: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.executionLifetime = executionLifetime
        self.deliveryObserver = deliveryObserver
    }

    func perform() {
        deliveryObserver()
        task.cancel()
        executionLifetime.cancellationDeliveryFinished()
    }
}

private final class AuthenticatedLocalSocketHandlerCancellationRequest: Sendable {
    private let task: Task<Void, Never>
    private let executionLifetime: AuthenticatedLocalSocketHandlerExecutionLifetime
    private let cancellationQueue: AuthenticatedLocalSocketHandlerCancellationQueue
    private let delivered = Mutex(false)

    init(
        task: Task<Void, Never>,
        executionLifetime: AuthenticatedLocalSocketHandlerExecutionLifetime,
        cancellationQueue: AuthenticatedLocalSocketHandlerCancellationQueue
    ) {
        self.task = task
        self.executionLifetime = executionLifetime
        self.cancellationQueue = cancellationQueue
    }

    func deliver() {
        let shouldDeliver = delivered.withLock { delivered in
            guard !delivered else { return false }
            delivered = true
            return true
        }
        guard shouldDeliver else { return }

        cancellationQueue.deliver(task: task, executionLifetime: executionLifetime)
    }
}

private final class AuthenticatedLocalSocketStopOperation: Sendable {
    let completion = DispatchGroup()

    init() {
        completion.enter()
    }
}

private struct AuthenticatedLocalSocketEntryIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
}

private struct AuthenticatedLocalSocketInstanceResources: Sendable {
    let baseDirectoryFileDescriptor: Int32
    let instanceDirectoryFileDescriptor: Int32
    let instanceDirectoryIdentity: AuthenticatedLocalSocketEntryIdentity
    let socketIdentity: AuthenticatedLocalSocketEntryIdentity
    let instanceDirectoryName: String
    let socketFileName: String
    let socketPath: String
}

private struct AuthenticatedLocalSocketStartedInstance: Sendable {
    let resources: AuthenticatedLocalSocketInstanceResources
    let listenerFileDescriptor: Int32
    let acceptFileDescriptor: Int32
}

enum AuthenticatedLocalSocketServerError: Error, Equatable, Sendable {
    case connectionTimedOut
    case invalidFrame
    case invalidTemporaryBaseDirectory
    case invalidSocketPath
    case stopInProgress
    case systemCall(String, Int32)
}
