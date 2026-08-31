import Darwin
import Dispatch
import Foundation
import Synchronization

final class AgentSocketServer: Sendable {
    typealias Handler = @Sendable (AgentIPCMessage) async -> Bool
    typealias CredentialProvider = @Sendable (AgentIPCPreflight) -> String?
    typealias PeerValidator = @Sendable (_ fileDescriptor: Int32, _ expectedUID: uid_t) -> Bool
    typealias AcceptFunction = @Sendable (_ listenerFileDescriptor: Int32) -> Int32
    typealias AcceptRetryBackoff = @Sendable () -> Void

    private let runtime: AgentSocketServerRuntime

    init(
        temporaryBaseDirectory: String = "/tmp",
        expectedUID: uid_t = geteuid(),
        peerValidator: @escaping PeerValidator = AgentSocketServer.validatePeer,
        maximumConnections: Int = 64,
        connectionTimeoutMilliseconds: Int = 5_000,
        acceptFunction: @escaping AcceptFunction = { Darwin.accept($0, nil, nil) },
        acceptRetryBackoff: @escaping AcceptRetryBackoff = { _ = Darwin.usleep(10_000) },
        credentialProvider: @escaping CredentialProvider = { _ in nil },
        handler: @escaping Handler
    ) {
        precondition((1...256).contains(maximumConnections))
        precondition((1...60_000).contains(connectionTimeoutMilliseconds))
        runtime = AgentSocketServerRuntime(
            temporaryBaseDirectory: temporaryBaseDirectory,
            expectedUID: expectedUID,
            peerValidator: peerValidator,
            maximumConnections: maximumConnections,
            connectionTimeoutMilliseconds: connectionTimeoutMilliseconds,
            acceptFunction: acceptFunction,
            acceptRetryBackoff: acceptRetryBackoff,
            credentialProvider: credentialProvider,
            handler: handler
        )
    }

    deinit {
        runtime.stopImmediately()
    }

    var socketPath: String? {
        runtime.socketPath
    }

    @discardableResult
    func start() throws -> String {
        try runtime.start()
    }

    func stop() async {
        await runtime.stop()
    }

    func stopImmediately() {
        runtime.stopImmediately()
    }

    private static func validatePeer(_ fileDescriptor: Int32, expectedUID: uid_t) -> Bool {
        AgentSocketServerRuntime.validatePeer(fileDescriptor, expectedUID: expectedUID)
    }
}

private struct AgentSocketNonceKey: Hashable, Sendable {
    let instanceID: UUID
    let paneID: UUID
    let nonce: Data
}

private struct AgentSocketEntryIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
}

private struct AgentSocketInstanceResources: Sendable {
    let baseDirectoryFileDescriptor: Int32
    let instanceDirectoryFileDescriptor: Int32
    let instanceDirectoryIdentity: AgentSocketEntryIdentity
    let socketIdentity: AgentSocketEntryIdentity
    let instanceDirectoryName: String
    let instanceDirectoryPath: String
    let socketPath: String
}

private struct AgentSocketStartedInstance {
    let resources: AgentSocketInstanceResources
    let listenerFileDescriptor: Int32
}

private final class AgentSocketStopOperation: Sendable {
    let completion = DispatchGroup()

    init() {
        completion.enter()
    }
}

private final class AgentSocketServerRuntime: Sendable {
    private struct State: Sendable {
        var generation: UInt64 = 0
        var listenerFileDescriptor: Int32?
        var clientGenerations: [Int32: UInt64] = [:]
        var authenticatedNonces: Set<AgentSocketNonceKey> = []
        var resources: AgentSocketInstanceResources?
        var stopOperation: AgentSocketStopOperation?
    }

    private struct FrozenInstance: Sendable {
        let operation: AgentSocketStopOperation
        let resources: AgentSocketInstanceResources?
    }

    private static let socketFileName = "agent.sock"
    private static let directoryTemplate = "quicktty.XXXXXX"
    private static let maximumAuthenticatedNonces = 65_536

    private let temporaryBaseDirectory: String
    private let expectedUID: uid_t
    private let peerValidator: AgentSocketServer.PeerValidator
    private let maximumConnections: Int
    private let connectionTimeoutMilliseconds: Int
    private let acceptFunction: AgentSocketServer.AcceptFunction
    private let acceptRetryBackoff: AgentSocketServer.AcceptRetryBackoff
    private let credentialProvider: AgentSocketServer.CredentialProvider
    private let handler: AgentSocketServer.Handler
    private let lifecycle = Mutex(())
    private let state = Mutex(State())
    private let handlerGroup = DispatchGroup()
    private let acceptQueue = DispatchQueue(label: "com.dntsk.QuickTTY.agent-socket.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.dntsk.QuickTTY.agent-socket.connections",
        attributes: .concurrent
    )
    private let cleanupQueue = DispatchQueue(label: "com.dntsk.QuickTTY.agent-socket.cleanup")

    init(
        temporaryBaseDirectory: String,
        expectedUID: uid_t,
        peerValidator: @escaping AgentSocketServer.PeerValidator,
        maximumConnections: Int,
        connectionTimeoutMilliseconds: Int,
        acceptFunction: @escaping AgentSocketServer.AcceptFunction,
        acceptRetryBackoff: @escaping AgentSocketServer.AcceptRetryBackoff,
        credentialProvider: @escaping AgentSocketServer.CredentialProvider,
        handler: @escaping AgentSocketServer.Handler
    ) {
        self.temporaryBaseDirectory = temporaryBaseDirectory
        self.expectedUID = expectedUID
        self.peerValidator = peerValidator
        self.maximumConnections = maximumConnections
        self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
        self.acceptFunction = acceptFunction
        self.acceptRetryBackoff = acceptRetryBackoff
        self.credentialProvider = credentialProvider
        self.handler = handler
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
                        throw AgentSocketServerError.stopInProgress
                    }
                    state.stopOperation = nil
                }
            }

            let startedInstance = try Self.createInstance(
                temporaryBaseDirectory: temporaryBaseDirectory
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
                    listenerFileDescriptor: startedInstance.listenerFileDescriptor,
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
    ) -> AgentSocketStopOperation? {
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
                    return FrozenInstance(operation: operation, resources: nil)
                }
                guard
                    state.listenerFileDescriptor != nil || state.resources != nil
                        || !state.clientGenerations.isEmpty
                else {
                    return nil
                }

                state.generation &+= 1
                state.authenticatedNonces.removeAll(keepingCapacity: false)
                let operation = AgentSocketStopOperation()
                state.stopOperation = operation

                if let listenerFileDescriptor = state.listenerFileDescriptor {
                    Darwin.shutdown(listenerFileDescriptor, SHUT_RDWR)
                    Darwin.close(listenerFileDescriptor)
                    state.listenerFileDescriptor = nil
                }
                for fileDescriptor in state.clientGenerations.keys {
                    // Darwin can reject SHUT_RDWR after peer EOF without shutting down writes.
                    Darwin.shutdown(fileDescriptor, SHUT_WR)
                    Darwin.shutdown(fileDescriptor, SHUT_RD)
                }

                let resources = state.resources
                state.resources = nil
                return FrozenInstance(operation: operation, resources: resources)
            }

            guard let frozenInstance else {
                return nil
            }
            guard let resources = frozenInstance.resources else {
                return frozenInstance.operation
            }

            let socketEntryRemoved = Self.unlinkPinnedSocket(
                instanceDirectoryFileDescriptor: resources.instanceDirectoryFileDescriptor,
                socketIdentity: resources.socketIdentity
            )
            assert(socketEntryRemoved, "Agent socket entry must be removed during immediate stop")

            let acceptQueue = acceptQueue
            let connectionQueue = connectionQueue
            let handlerGroup = handlerGroup
            cleanupQueue.async { [self] in
                acceptQueue.sync {}
                connectionQueue.sync(flags: .barrier) {}
                handlerGroup.wait()
                assert(state.withLock { $0.clientGenerations.isEmpty })
                Self.cleanUp(resources)
                frozenInstance.operation.completion.leave()
            }
            return frozenInstance.operation
        }
    }

    private func acceptConnections(listenerFileDescriptor: Int32, generation: UInt64) {
        while isCurrentListener(listenerFileDescriptor, generation: generation) {
            let clientFileDescriptor = acceptFunction(listenerFileDescriptor)
            if clientFileDescriptor < 0 {
                let acceptError = errno
                switch acceptError {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    guard isCurrentListener(listenerFileDescriptor, generation: generation) else {
                        return
                    }
                    acceptRetryBackoff()
                    continue
                default:
                    _ = freezeAndScheduleCleanup(
                        expectedListenerFileDescriptor: listenerFileDescriptor,
                        expectedGeneration: generation
                    )
                    return
                }
            }

            guard configureAcceptedSocket(clientFileDescriptor) else {
                Darwin.close(clientFileDescriptor)
                continue
            }
            guard let deadlineNanoseconds = try? makeConnectionDeadlineNanoseconds() else {
                Darwin.close(clientFileDescriptor)
                continue
            }
            guard registerClient(clientFileDescriptor, generation: generation) else {
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

        do {
            guard peerValidator(fileDescriptor, expectedUID) else {
                finishClient(fileDescriptor, generation: generation, acknowledgement: 0)
                return
            }

            guard
                let preflightData = try readExactly(
                    AgentIPCProtocol.preflightSize,
                    from: fileDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                )
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
                finishClient(fileDescriptor, generation: generation, acknowledgement: 0)
                return
            }
            var challenge = Data([1])
            challenge.append(proof)
            try writeAll(
                challenge,
                to: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )

            let frame = try readSingleFrame(
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
            guard let currentPaneToken = credentialProvider(preflight) else {
                finishClient(fileDescriptor, generation: generation, acknowledgement: 0)
                return
            }
            let message = try AgentIPCProtocol.decodeFrame(
                frame,
                for: preflight,
                paneToken: currentPaneToken
            )
            guard message.identity.instanceID == preflight.instanceID,
                message.identity.paneID == preflight.paneID,
                reserveAuthenticatedNonce(preflight, generation: generation),
                reserveHandler(fileDescriptor, generation: generation)
            else {
                finishClient(fileDescriptor, generation: generation, acknowledgement: 0)
                return
            }

            Task { [self] in
                let accepted = await handler(message)
                connectionQueue.async { [self] in
                    finishClient(
                        fileDescriptor,
                        generation: generation,
                        acknowledgement: accepted ? 1 : 0
                    )
                    handlerGroup.leave()
                }
            }
        } catch {
            finishClient(fileDescriptor, generation: generation, acknowledgement: 0)
        }
    }

    private func makeConnectionDeadlineNanoseconds() throws -> UInt64 {
        try monotonicNanoseconds() + UInt64(connectionTimeoutMilliseconds) * 1_000_000
    }

    private func monotonicNanoseconds() throws -> UInt64 {
        var currentTime = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &currentTime) == 0 else {
            throw AgentSocketServerError.systemCall("clock_gettime", errno)
        }
        return UInt64(currentTime.tv_sec) * 1_000_000_000 + UInt64(currentTime.tv_nsec)
    }

    private func readSingleFrame(
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> Data {
        let headerSize = MemoryLayout<UInt32>.size
        guard
            let header = try readExactly(
                headerSize,
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
        else {
            throw AgentIPCProtocolError.truncatedHeader
        }
        let declaredLength = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard declaredLength > 0 else {
            throw AgentIPCProtocolError.emptyPayload
        }
        guard declaredLength <= UInt32(AgentIPCProtocol.maximumPayloadSize) else {
            throw AgentIPCProtocolError.payloadTooLarge
        }
        guard
            let payload = try readExactly(
                Int(declaredLength),
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
        else {
            throw AgentIPCProtocolError.truncatedPayload
        }
        guard
            try readByte(
                from: fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            ) == nil
        else {
            throw AgentIPCProtocolError.trailingBytes
        }

        var frame = Data(capacity: headerSize + payload.count)
        frame.append(header)
        frame.append(payload)
        return frame
    }

    private func readExactly(
        _ count: Int,
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> Data? {
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
                    throw AgentSocketServerError.systemCall("read", errno)
                }
            }
            return offset
        }
        return bytesRead == count ? data : nil
    }

    private func readByte(
        from fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws -> UInt8? {
        var byte: UInt8 = 0
        while true {
            try waitUntilReadable(
                fileDescriptor,
                deadlineNanoseconds: deadlineNanoseconds
            )
            let result = Darwin.read(fileDescriptor, &byte, 1)
            if result == 1 {
                return byte
            }
            if result == 0 {
                return nil
            }
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw AgentSocketServerError.systemCall("read", errno)
            }
        }
    }

    private func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        deadlineNanoseconds: UInt64
    ) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try waitUntilWritable(
                    fileDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                let result = Darwin.write(
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
                    throw AgentSocketServerError.systemCall("write", errno)
                }
            }
        }
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

    private func wait(
        _ fileDescriptor: Int32,
        events: Int16,
        deadlineNanoseconds: UInt64
    ) throws {
        while true {
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let currentNanoseconds = try monotonicNanoseconds()
            guard currentNanoseconds < deadlineNanoseconds else {
                throw AgentSocketServerError.connectionTimedOut
            }
            let remainingNanoseconds = deadlineNanoseconds - currentNanoseconds
            let remainingMilliseconds = Int32(
                (remainingNanoseconds + 999_999) / 1_000_000
            )
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if result > 0 {
                guard try monotonicNanoseconds() <= deadlineNanoseconds else {
                    throw AgentSocketServerError.connectionTimedOut
                }
                return
            }
            if result == 0 {
                throw AgentSocketServerError.connectionTimedOut
            }
            if errno != EINTR {
                throw AgentSocketServerError.systemCall("poll", errno)
            }
        }
    }

    private func isCurrentListener(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock {
            $0.generation == generation && $0.listenerFileDescriptor == fileDescriptor
        }
    }

    private func registerClient(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation, state.listenerFileDescriptor != nil,
                state.clientGenerations.count < maximumConnections
            else {
                return false
            }
            state.clientGenerations[fileDescriptor] = generation
            return true
        }
    }

    private func ownsClient(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock { $0.clientGenerations[fileDescriptor] == generation }
    }

    private func reserveAuthenticatedNonce(
        _ preflight: AgentIPCPreflight,
        generation: UInt64
    ) -> Bool {
        let key = AgentSocketNonceKey(
            instanceID: preflight.instanceID,
            paneID: preflight.paneID,
            nonce: preflight.nonce
        )
        return state.withLock { state in
            guard state.generation == generation,
                state.authenticatedNonces.count < Self.maximumAuthenticatedNonces
            else {
                return false
            }
            return state.authenticatedNonces.insert(key).inserted
        }
    }

    private func reserveHandler(_ fileDescriptor: Int32, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation,
                state.clientGenerations[fileDescriptor] == generation
            else {
                return false
            }
            // Entering under the state lock makes handler reservation atomic with stop freeze.
            handlerGroup.enter()
            return true
        }
    }

    private func finishClient(
        _ fileDescriptor: Int32,
        generation: UInt64,
        acknowledgement: UInt8
    ) {
        state.withLock { state in
            guard state.clientGenerations[fileDescriptor] == generation else {
                return
            }

            writeAcknowledgementIfWritable(acknowledgement, to: fileDescriptor)
            state.clientGenerations.removeValue(forKey: fileDescriptor)
            Darwin.close(fileDescriptor)
        }
    }

    private func writeAcknowledgementIfWritable(
        _ acknowledgement: UInt8,
        to fileDescriptor: Int32
    ) {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let result = Darwin.poll(&descriptor, 1, 0)
            if result > 0 {
                guard descriptor.revents & Int16(POLLOUT) != 0 else {
                    return
                }
                break
            }
            if result == 0 || errno != EINTR {
                return
            }
        }

        var acknowledgement = acknowledgement
        while true {
            let result = Darwin.write(fileDescriptor, &acknowledgement, 1)
            if result == 1 {
                return
            }
            if result < 0, errno == EINTR {
                continue
            }
            return
        }
    }

    private func configureAcceptedSocket(_ fileDescriptor: Int32) -> Bool {
        guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            return false
        }
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

    private static func createInstance(
        temporaryBaseDirectory: String
    ) throws -> AgentSocketStartedInstance {
        guard temporaryBaseDirectory.hasPrefix("/"), !temporaryBaseDirectory.utf8.contains(0)
        else {
            throw AgentSocketServerError.invalidTemporaryBaseDirectory
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
            throw AgentSocketServerError.systemCall("open", errno)
        }

        var instanceDirectoryPath: String?
        var instanceDirectoryName: String?
        var instanceDirectoryFileDescriptor: Int32 = -1
        var instanceDirectoryIdentity: AgentSocketEntryIdentity?
        var socketIdentity: AgentSocketEntryIdentity?
        var listenerFileDescriptor: Int32 = -1
        var succeeded = false
        defer {
            if !succeeded {
                if listenerFileDescriptor >= 0 {
                    Darwin.close(listenerFileDescriptor)
                }
                if instanceDirectoryFileDescriptor >= 0 {
                    if let socketIdentity {
                        _ = unlinkPinnedSocket(
                            instanceDirectoryFileDescriptor: instanceDirectoryFileDescriptor,
                            socketIdentity: socketIdentity
                        )
                    }
                    Darwin.close(instanceDirectoryFileDescriptor)
                }
                if let instanceDirectoryName, let instanceDirectoryIdentity {
                    removePinnedInstanceDirectory(
                        baseDirectoryFileDescriptor: baseDirectoryFileDescriptor,
                        instanceDirectoryName: instanceDirectoryName,
                        identity: instanceDirectoryIdentity
                    )
                }
                Darwin.close(baseDirectoryFileDescriptor)
            }
        }

        var template = Array(
            "\(normalizedBase)/\(directoryTemplate)".utf8CString
        )
        instanceDirectoryPath = template.withUnsafeMutableBufferPointer { buffer in
            guard let result = mkdtemp(buffer.baseAddress!) else {
                return nil
            }
            return String(cString: result)
        }
        guard let instanceDirectoryPath else {
            throw AgentSocketServerError.systemCall("mkdtemp", errno)
        }
        instanceDirectoryName = URL(fileURLWithPath: instanceDirectoryPath).lastPathComponent

        instanceDirectoryFileDescriptor = Darwin.open(
            instanceDirectoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard instanceDirectoryFileDescriptor >= 0 else {
            throw AgentSocketServerError.systemCall("open", errno)
        }
        var instanceDirectoryStatus = stat()
        guard fstat(instanceDirectoryFileDescriptor, &instanceDirectoryStatus) == 0 else {
            throw AgentSocketServerError.systemCall("fstat", errno)
        }
        instanceDirectoryIdentity = AgentSocketEntryIdentity(
            device: instanceDirectoryStatus.st_dev,
            inode: instanceDirectoryStatus.st_ino
        )
        guard fchmod(instanceDirectoryFileDescriptor, 0o700) == 0 else {
            throw AgentSocketServerError.systemCall("fchmod", errno)
        }

        let socketPath = "\(instanceDirectoryPath)/\(socketFileName)"
        var address: AgentUnixSocketAddress
        do {
            address = try AgentUnixSocketAddress(path: socketPath)
        } catch {
            throw AgentSocketServerError.invalidSocketPath
        }

        listenerFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFileDescriptor >= 0 else {
            throw AgentSocketServerError.systemCall("socket", errno)
        }
        guard fcntl(listenerFileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw AgentSocketServerError.systemCall("fcntl", errno)
        }
        try AgentSocketIO.disableSIGPIPE(on: listenerFileDescriptor)

        let bindResult = address.withSockAddr { pointer, length in
            Darwin.bind(listenerFileDescriptor, pointer, length)
        }
        guard bindResult == 0 else {
            throw AgentSocketServerError.systemCall("bind", errno)
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
            throw AgentSocketServerError.systemCall("fstatat", errno)
        }
        guard socketStatus.st_mode & S_IFMT == S_IFSOCK else {
            throw AgentSocketServerError.systemCall("fstatat", EINVAL)
        }
        socketIdentity = AgentSocketEntryIdentity(
            device: socketStatus.st_dev,
            inode: socketStatus.st_ino
        )
        guard fchmodat(instanceDirectoryFileDescriptor, socketFileName, 0o600, 0) == 0 else {
            throw AgentSocketServerError.systemCall("fchmodat", errno)
        }
        guard Darwin.listen(listenerFileDescriptor, 16) == 0 else {
            throw AgentSocketServerError.systemCall("listen", errno)
        }
        guard let instanceDirectoryName, let instanceDirectoryIdentity, let socketIdentity else {
            throw AgentSocketServerError.systemCall("fstat", EINVAL)
        }

        succeeded = true
        return AgentSocketStartedInstance(
            resources: AgentSocketInstanceResources(
                baseDirectoryFileDescriptor: baseDirectoryFileDescriptor,
                instanceDirectoryFileDescriptor: instanceDirectoryFileDescriptor,
                instanceDirectoryIdentity: instanceDirectoryIdentity,
                socketIdentity: socketIdentity,
                instanceDirectoryName: instanceDirectoryName,
                instanceDirectoryPath: instanceDirectoryPath,
                socketPath: socketPath
            ),
            listenerFileDescriptor: listenerFileDescriptor
        )
    }

    private static func cleanUp(_ resources: AgentSocketInstanceResources) {
        let socketEntryRemoved = unlinkPinnedSocket(
            instanceDirectoryFileDescriptor: resources.instanceDirectoryFileDescriptor,
            socketIdentity: resources.socketIdentity
        )
        assert(socketEntryRemoved, "Agent socket cleanup failed")
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
        socketIdentity: AgentSocketEntryIdentity
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
        if unlinkat(instanceDirectoryFileDescriptor, socketFileName, 0) == 0 {
            return true
        }
        return errno == ENOENT
    }

    private static func removePinnedInstanceDirectory(
        baseDirectoryFileDescriptor: Int32,
        instanceDirectoryName: String,
        identity: AgentSocketEntryIdentity
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

enum AgentSocketServerError: Error, Equatable, Sendable {
    case connectionTimedOut
    case invalidTemporaryBaseDirectory
    case invalidSocketPath
    case stopInProgress
    case systemCall(String, Int32)
}
