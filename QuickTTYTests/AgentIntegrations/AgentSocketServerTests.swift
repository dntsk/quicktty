import Darwin
import Foundation
import Synchronization
import Testing

@testable import QuickTTY

struct AgentSocketServerTests {
    @Test
    func realClientReceivesSuccessAfterHandlerDelivery() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let messages = Mutex<[AgentIPCMessage]>([])
        let expectedMessage = try makeMessage()
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { message in
            messages.withLock { $0.append(message) }
            return true
        }

        let socketPath = try server.start()
        #expect(try AgentSocketClient.send(expectedMessage, to: socketPath))
        #expect(messages.withLock { $0 } == [expectedMessage])
        await server.stop()
    }

    @Test
    func transparentRelayCanForwardRequestButCannotObtainPaneToken() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()
        let upstream = try connectRaw(to: socketPath)
        guard unlink(socketPath) == 0 else {
            throw AgentSocketTestError.systemCall("unlink", errno)
        }
        let fakeListener = try makeListener(at: socketPath)
        let captured = Mutex(Data())
        let fakeCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let client = Darwin.accept(fakeListener, nil, nil)
            guard client >= 0 else {
                Darwin.close(upstream)
                fakeCompleted.signal()
                return
            }
            defer {
                Darwin.close(client)
                Darwin.close(upstream)
                fakeCompleted.signal()
            }
            var buffer = [UInt8](repeating: 0, count: 512)
            var preflightBytes = 0
            while preflightBytes < AgentIPCProtocol.preflightSize {
                let result = Darwin.read(
                    client, &buffer, AgentIPCProtocol.preflightSize - preflightBytes)
                guard result > 0 else { return }
                let data = Data(buffer.prefix(result))
                preflightBytes += result
                captured.withLock { $0.append(data) }
                try? AgentSocketIO.writeAll(data, to: upstream)
            }
            guard
                let challenge = try? AgentSocketIO.readExactly(
                    1 + AgentIPCProtocol.proofSize,
                    from: upstream,
                    deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
                )
            else {
                return
            }
            try? AgentSocketIO.writeAll(challenge, to: client)

            while true {
                let result = Darwin.read(client, &buffer, buffer.count)
                if result == 0 { break }
                guard result > 0 else { return }
                let data = Data(buffer.prefix(result))
                captured.withLock { $0.append(data) }
                try? AgentSocketIO.writeAll(data, to: upstream)
            }
            try? AgentSocketIO.shutdownWrite(upstream)
            guard let acknowledgement = try? AgentSocketIO.readByte(from: upstream) else {
                return
            }
            try? AgentSocketIO.writeAll(Data([acknowledgement]), to: client)
            try? AgentSocketIO.shutdownWrite(client)
        }

        let message = try makeMessage()
        let accepted = try await Task.detached {
            try AgentSocketClient.send(message, to: socketPath)
        }.value

        #expect(accepted)
        #expect(await waitForSemaphore(fakeCompleted))
        let capturedData = captured.withLock { $0 }
        #expect(capturedData.count > AgentIPCProtocol.preflightSize)
        #expect(
            try AgentIPCProtocol.decodePreflight(
                Data(capturedData.prefix(AgentIPCProtocol.preflightSize))
            ).paneID == message.identity.paneID
        )
        #expect(capturedData.range(of: Data(message.identity.paneToken.utf8)) == nil)
        #expect(capturedData.range(of: Data("paneToken".utf8)) == nil)
        #expect(deliveryCount.withLock { $0 } == 1)

        Darwin.close(fakeListener)
        #expect(unlink(socketPath) == 0)
        await server.stop()
    }

    @Test
    func unknownPaneGetsNegativeChallengeWithoutHandlerDelivery() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()
        let message = try makeMessage(paneID: UUID())

        #expect(try !AgentSocketClient.send(message, to: socketPath))
        #expect(deliveryCount.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func authenticatedNonceCannotBeReplayed() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()
        let client = AgentSocketClient(
            socketPath: socketPath,
            timeoutMilliseconds: 2_000,
            nonceGenerator: { Data(repeating: 7, count: AgentIPCProtocol.nonceSize) }
        )

        #expect(try client.send(makeMessage()))
        #expect(try !client.send(makeMessage()))
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func credentialRotationDuringChallengeRejectsFrame() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let credentialReads = Mutex(0)
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: { preflight in
                guard Self.provideCredential(preflight) != nil else { return nil }
                return credentialReads.withLock { reads in
                    reads += 1
                    return String(repeating: reads == 1 ? "a" : "b", count: 64)
                }
            }
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()

        #expect(try !AgentSocketClient.send(makeMessage(), to: socketPath))
        #expect(deliveryCount.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func totalClientDeadlineExpiresAtEveryProtocolPhase() async throws {
        let connectClient = AgentSocketClient(
            socketPath: "/tmp/qtt-missing-\(UUID().uuidString).sock",
            timeoutMilliseconds: 100,
            nonceGenerator: { Data(repeating: 1, count: AgentIPCProtocol.nonceSize) },
            phaseObserver: { phase in
                if phase == .connect { _ = Darwin.usleep(150_000) }
            }
        )
        #expect(throws: AgentSocketClientError.timedOut) {
            try connectClient.send(makeMessage())
        }

        for phase in [
            AgentSocketClientPhase.challenge,
            .frameWrite,
            .acknowledgement,
        ] {
            let baseDirectory = try makeTemporaryBaseDirectory()
            let server = AgentSocketServer(
                temporaryBaseDirectory: baseDirectory,
                credentialProvider: Self.provideCredential
            ) { _ in true }
            let socketPath = try server.start()
            let client = AgentSocketClient(
                socketPath: socketPath,
                timeoutMilliseconds: 100,
                nonceGenerator: { Data(repeating: 2, count: AgentIPCProtocol.nonceSize) },
                phaseObserver: { observedPhase in
                    if observedPhase == phase { _ = Darwin.usleep(150_000) }
                }
            )

            #expect(throws: AgentSocketClientError.timedOut) {
                try client.send(makeMessage())
            }
            await server.stop()
            removeTemporaryBaseDirectory(baseDirectory)
        }
    }

    @Test
    func rejectedHandlerReturnsNegativeAcknowledgement() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return false
        }

        let socketPath = try server.start()
        #expect(try !AgentSocketClient.send(makeMessage(), to: socketPath))
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func rejectsMalformedOversizedTruncatedZeroAndTrailingFrames() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()

        let message = try makeMessage()
        let validFrame = try AgentIPCProtocol.encodeFrame(
            message,
            for: makePreflight(message: message)
        )
        let oldEncoder = JSONEncoder()
        oldEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let oldTokenBearingFrame = lengthPrefixed(try oldEncoder.encode(message))
        var trailingFrame = validFrame
        trailingFrame.append(0)
        let malformedFrames = [
            lengthPrefixed(Data("{}".utf8)),
            oldTokenBearingFrame,
            lengthPrefixed(Data(), declaredLength: AgentIPCProtocol.maximumPayloadSize + 1),
            lengthPrefixed(Data([1]), declaredLength: 2),
            lengthPrefixed(Data(), declaredLength: 0),
            trailingFrame,
        ]

        for frame in malformedFrames {
            #expect(try sendRawFrame(frame, to: socketPath) == 0)
        }
        #expect(deliveryCount.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func acceptsAFrameWrittenInSingleByteFragments() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let message = try makeMessage()
        let preflight = try authenticate(fileDescriptor, message: message)

        for byte in try AgentIPCProtocol.encodeFrame(message, for: preflight) {
            try AgentSocketIO.writeAll(Data([byte]), to: fileDescriptor)
        }
        try AgentSocketIO.shutdownWrite(fileDescriptor)

        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == 1)
        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func maximumConnectionsRejectsExcessClientsAndReleasesCapacity() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let firstClientValidated = DispatchSemaphore(value: 0)
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            peerValidator: { fileDescriptor, expectedUID in
                let valid = Self.validatePeer(fileDescriptor, expectedUID: expectedUID)
                firstClientValidated.signal()
                return valid
            },
            maximumConnections: 1,
            credentialProvider: Self.provideCredential,
            handler: { _ in
                deliveryCount.withLock { $0 += 1 }
                return true
            }
        )
        let socketPath = try server.start()

        var firstClient: Int32? = try connectRaw(to: socketPath)
        defer {
            if let firstClient {
                Darwin.close(firstClient)
            }
        }
        try AgentSocketIO.writeAll(Data([0, 0]), to: firstClient!)
        #expect(await waitForSemaphore(firstClientValidated))

        let rejectedClient = try connectRaw(to: socketPath)
        #expect(try AgentSocketIO.readByte(from: rejectedClient) == nil)
        Darwin.close(rejectedClient)

        try AgentSocketIO.shutdownWrite(firstClient!)
        #expect(try AgentSocketIO.readByte(from: firstClient!) == 0)
        #expect(try AgentSocketIO.readByte(from: firstClient!) == nil)
        Darwin.close(firstClient!)
        firstClient = nil

        #expect(try AgentSocketClient.send(makeMessage(), to: socketPath))
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func totalConnectionDeadlineRejectsPartialClientWithoutDelivery() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            connectionTimeoutMilliseconds: 25
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            return true
        }
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }

        try AgentSocketIO.writeAll(Data([0, 0]), to: fileDescriptor)

        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == 0)
        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)
        #expect(deliveryCount.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func retriesRecoverableAcceptErrorsWithBackoffOnlyForResourcePressure() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let injectedErrors = Mutex<[Int32]>([
            EINTR, ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM,
        ])
        let backoffCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            acceptFunction: { listenerFileDescriptor in
                let injectedError = injectedErrors.withLock { errors in
                    errors.isEmpty ? nil : errors.removeFirst()
                }
                guard let injectedError else {
                    return Darwin.accept(listenerFileDescriptor, nil, nil)
                }
                errno = injectedError
                return -1
            },
            acceptRetryBackoff: {
                backoffCount.withLock { $0 += 1 }
            },
            credentialProvider: Self.provideCredential,
            handler: { _ in true }
        )

        let socketPath = try server.start()
        #expect(try AgentSocketClient.send(makeMessage(), to: socketPath))
        #expect(injectedErrors.withLock { $0.isEmpty })
        #expect(backoffCount.withLock { $0 } == 4)
        await server.stop()
    }

    @Test
    func fatalAcceptErrorFreezesCleanupAndAllowsWorkingRestart() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let shouldFail = Mutex(true)
        let failureObserved = DispatchSemaphore(value: 0)
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            acceptFunction: { listenerFileDescriptor in
                let fail = shouldFail.withLock { shouldFail in
                    defer { shouldFail = false }
                    return shouldFail
                }
                guard fail else {
                    return Darwin.accept(listenerFileDescriptor, nil, nil)
                }
                errno = EBADF
                failureObserved.signal()
                return -1
            },
            acceptRetryBackoff: {},
            credentialProvider: Self.provideCredential,
            handler: { _ in
                deliveryCount.withLock { $0 += 1 }
                return true
            }
        )

        let firstPath = try server.start()
        #expect(await waitForSemaphore(failureObserved))
        while server.socketPath != nil {
            await Task.yield()
        }
        await server.stop()
        #expect(access(firstPath, F_OK) != 0)

        let secondPath = try server.start()
        #expect(secondPath != firstPath)
        #expect(try AgentSocketClient.send(makeMessage(), to: secondPath))
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func injectedPeerRejectionOccursBeforeDecoding() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let validatorCalls = Mutex(0)
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            peerValidator: { _, expectedUID in
                #expect(expectedUID == geteuid())
                validatorCalls.withLock { $0 += 1 }
                return false
            },
            handler: { _ in
                deliveryCount.withLock { $0 += 1 }
                return true
            }
        )

        let socketPath = try server.start()
        #expect(try !AgentSocketClient.send(makeMessage(), to: socketPath))
        #expect(validatorCalls.withLock { $0 } == 1)
        #expect(deliveryCount.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func createsPrivateUniqueInstancePathsAndCleansUpIdempotently() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let firstServer = AgentSocketServer(temporaryBaseDirectory: baseDirectory) { _ in true }
        let secondServer = AgentSocketServer(temporaryBaseDirectory: baseDirectory) { _ in true }

        let firstPath = try firstServer.start()
        let secondPath = try secondServer.start()
        #expect(firstPath != secondPath)
        #expect(try firstServer.start() == firstPath)
        #expect(
            try permissions(at: URL(fileURLWithPath: firstPath).deletingLastPathComponent().path)
                == 0o700)
        #expect(try permissions(at: firstPath) == 0o600)
        #expect(
            try permissions(at: URL(fileURLWithPath: secondPath).deletingLastPathComponent().path)
                == 0o700)
        #expect(try permissions(at: secondPath) == 0o600)

        let firstDirectory = URL(fileURLWithPath: firstPath).deletingLastPathComponent().path
        let secondDirectory = URL(fileURLWithPath: secondPath).deletingLastPathComponent().path
        await firstServer.stop()
        await firstServer.stop()
        #expect(access(firstPath, F_OK) != 0)
        #expect(access(firstDirectory, F_OK) != 0)
        #expect(access(secondPath, F_OK) == 0)

        await secondServer.stop()
        #expect(access(secondDirectory, F_OK) != 0)
    }

    @Test
    func stopClosesPartialClientAndFreezesItsGeneration() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let peerValidated = DispatchSemaphore(value: 0)
        let deliveryCount = Mutex(0)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            peerValidator: { fileDescriptor, expectedUID in
                let valid = Self.validatePeer(fileDescriptor, expectedUID: expectedUID)
                peerValidated.signal()
                return valid
            },
            credentialProvider: Self.provideCredential,
            handler: { _ in
                deliveryCount.withLock { $0 += 1 }
                return true
            }
        )

        let firstPath = try server.start()
        let clientFileDescriptor = try connectRaw(to: firstPath)
        defer { Darwin.close(clientFileDescriptor) }
        try AgentSocketIO.writeAll(Data([0, 0]), to: clientFileDescriptor)
        #expect(await waitForSemaphore(peerValidated))

        await server.stop()
        await server.stop()
        #expect(deliveryCount.withLock { $0 } == 0)
        #expect(access(firstPath, F_OK) != 0)

        let secondPath = try server.start()
        #expect(secondPath != firstPath)
        #expect(try AgentSocketClient.send(makeMessage(), to: secondPath))
        #expect(deliveryCount.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func awaitedStopWaitsForReservedHandlerAndSuppressesAcknowledgement() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let handlerEntered = DispatchSemaphore(value: 0)
        let handlerRelease = AsyncGate()
        let deliveryCount = Mutex(0)
        let stopCompleted = Mutex(false)
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            deliveryCount.withLock { $0 += 1 }
            handlerEntered.signal()
            await handlerRelease.wait()
            return true
        }

        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let message = try makeMessage()
        let preflight = try authenticate(fileDescriptor, message: message)
        try AgentSocketIO.writeAll(
            AgentIPCProtocol.encodeFrame(message, for: preflight),
            to: fileDescriptor
        )
        try AgentSocketIO.shutdownWrite(fileDescriptor)
        let entered = await waitForSemaphore(handlerEntered)
        #expect(entered)

        let stopTask = Task {
            await server.stop()
            stopCompleted.withLock { $0 = true }
        }
        while server.socketPath != nil {
            await Task.yield()
        }
        #expect(!stopCompleted.withLock { $0 })
        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)

        await handlerRelease.open()
        await stopTask.value
        #expect(stopCompleted.withLock { $0 })
        #expect(deliveryCount.withLock { $0 } == 1)
        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)
    }

    @Test
    func immediateStopUnlinksEndpointWithoutWaitingForHandlerCleanup() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let handlerEntered = DispatchSemaphore(value: 0)
        let handlerRelease = AsyncGate()
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _ in
            handlerEntered.signal()
            await handlerRelease.wait()
            return true
        }

        let socketPath = try server.start()
        let instanceDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let message = try makeMessage()
        let preflight = try authenticate(fileDescriptor, message: message)
        try AgentSocketIO.writeAll(
            AgentIPCProtocol.encodeFrame(message, for: preflight),
            to: fileDescriptor
        )
        try AgentSocketIO.shutdownWrite(fileDescriptor)
        #expect(await waitForSemaphore(handlerEntered))

        server.stopImmediately()
        server.stopImmediately()

        #expect(access(socketPath, F_OK) != 0)
        #expect(access(instanceDirectory, F_OK) == 0)
        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)

        await handlerRelease.open()
        await server.stop()
        #expect(access(instanceDirectory, F_OK) != 0)
    }

    @Test
    func cleanupPreservesReplacementAtSocketPath() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let server = AgentSocketServer(temporaryBaseDirectory: baseDirectory) { _ in true }
        let socketPath = try server.start()
        let instanceDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        defer {
            _ = unlink(socketPath)
            _ = rmdir(instanceDirectory)
        }
        guard unlink(socketPath) == 0 else {
            throw AgentSocketTestError.systemCall("unlink", errno)
        }
        let sentinel = Data("replacement".utf8)
        #expect(FileManager.default.createFile(atPath: socketPath, contents: sentinel))

        server.stopImmediately()
        await server.stop()

        #expect(try Data(contentsOf: URL(fileURLWithPath: socketPath)) == sentinel)
    }

    @Test
    func cleanupDoesNotDeleteUnrelatedBaseEntry() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let unrelatedPath = "\(baseDirectory)/keep"
        #expect(FileManager.default.createFile(atPath: unrelatedPath, contents: Data("keep".utf8)))
        let server = AgentSocketServer(temporaryBaseDirectory: baseDirectory) { _ in true }

        let socketPath = try server.start()
        let instanceDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        await server.stop()

        #expect(access(instanceDirectory, F_OK) != 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: unrelatedPath)) == Data("keep".utf8))
        #expect(unlink(unrelatedPath) == 0)
    }

    @Test
    func cleanupPreservesReplacementForRenamedInstanceDirectory() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let server = AgentSocketServer(temporaryBaseDirectory: baseDirectory) { _ in true }
        let socketPath = try server.start()
        let instanceDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        let renamedDirectory = "\(instanceDirectory).renamed"
        let renamedSocketPath = "\(renamedDirectory)/agent.sock"
        let sentinelPath = "\(instanceDirectory)/sentinel"
        defer {
            _ = unlink(sentinelPath)
            _ = rmdir(instanceDirectory)
            _ = unlink(renamedSocketPath)
            _ = rmdir(renamedDirectory)
        }

        guard rename(instanceDirectory, renamedDirectory) == 0 else {
            throw AgentSocketTestError.systemCall("rename", errno)
        }
        guard mkdir(instanceDirectory, 0o700) == 0 else {
            throw AgentSocketTestError.systemCall("mkdir", errno)
        }
        #expect(FileManager.default.createFile(atPath: sentinelPath, contents: Data("keep".utf8)))

        await server.stop()

        #expect(access(instanceDirectory, F_OK) == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: sentinelPath)) == Data("keep".utf8))
        #expect(access(renamedDirectory, F_OK) == 0)
        #expect(access(renamedSocketPath, F_OK) != 0)
    }

    @Test
    func validatesServerAndClientSocketPathsAtTheByteBoundary() async throws {
        let path = "/a" + String(repeating: "é", count: 51)
        #expect(path.utf8.count == MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        #expect(throws: AgentSocketClientError.invalidSocketPath) {
            try AgentSocketClient.send(makeMessage(), to: path)
        }

        let longBaseDirectory = "/tmp/qtt-\(UUID().uuidString)-\(String(repeating: "é", count: 24))"
        guard mkdir(longBaseDirectory, 0o700) == 0 else {
            throw AgentSocketTestError.systemCall("mkdir", errno)
        }
        defer { removeTemporaryBaseDirectory(longBaseDirectory) }
        let server = AgentSocketServer(temporaryBaseDirectory: longBaseDirectory) { _ in true }

        #expect(throws: AgentSocketServerError.invalidSocketPath) {
            try server.start()
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: longBaseDirectory).isEmpty
        )
        await server.stop()
    }

    private func makeMessage(
        paneID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    ) throws -> AgentIPCMessage {
        let identity = try AgentIPCIdentity(
            instanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            paneID: paneID,
            paneToken: String(repeating: "a", count: 64),
            adapterID: "claude-code"
        )
        return AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: identity,
                    sessionID: "session",
                    cwd: "/tmp",
                    metadata: [:]
                )
            )
        )
    }

    private func makeTemporaryBaseDirectory() throws -> String {
        let path = "/tmp/qtt-test-\(UUID().uuidString)"
        guard mkdir(path, 0o700) == 0 else {
            throw AgentSocketTestError.systemCall("mkdir", errno)
        }
        return path
    }

    private func removeTemporaryBaseDirectory(_ path: String) {
        _ = rmdir(path)
    }

    private func waitForSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private func permissions(at path: String) throws -> mode_t {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0 else {
            throw AgentSocketTestError.systemCall("lstat", errno)
        }
        return fileStatus.st_mode & 0o777
    }

    private func lengthPrefixed(_ payload: Data, declaredLength: Int? = nil) -> Data {
        var length = UInt32(declaredLength ?? payload.count).bigEndian
        var frame = Data()
        Swift.withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func sendRawFrame(_ frame: Data, to socketPath: String) throws -> UInt8 {
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        try authenticate(fileDescriptor, message: makeMessage())
        try AgentSocketIO.writeAll(frame, to: fileDescriptor)
        try AgentSocketIO.shutdownWrite(fileDescriptor)
        guard let acknowledgement = try AgentSocketIO.readByte(from: fileDescriptor) else {
            throw AgentSocketTestError.missingAcknowledgement
        }
        guard try AgentSocketIO.readByte(from: fileDescriptor) == nil else {
            throw AgentSocketTestError.trailingAcknowledgement
        }
        return acknowledgement
    }

    @discardableResult
    private func authenticate(
        _ fileDescriptor: Int32,
        message: AgentIPCMessage
    ) throws -> AgentIPCPreflight {
        let identity = message.identity
        let preflight = try makePreflight(message: message)
        try AgentSocketIO.writeAll(
            AgentIPCProtocol.encodePreflight(preflight),
            to: fileDescriptor
        )
        guard try AgentSocketIO.readByte(from: fileDescriptor) == 1 else {
            throw AgentSocketTestError.missingChallenge
        }
        var proof = Data()
        for _ in 0..<AgentIPCProtocol.proofSize {
            guard let byte = try AgentSocketIO.readByte(from: fileDescriptor) else {
                throw AgentSocketTestError.missingChallenge
            }
            proof.append(byte)
        }
        guard
            AgentIPCProtocol.verifyServerProof(
                proof,
                for: preflight,
                paneToken: identity.paneToken
            )
        else {
            throw AgentSocketTestError.invalidChallenge
        }
        return preflight
    }

    private func makePreflight(message: AgentIPCMessage) throws -> AgentIPCPreflight {
        try AgentIPCPreflight(
            instanceID: message.identity.instanceID,
            paneID: message.identity.paneID,
            nonce: Data(repeating: 0x42, count: AgentIPCProtocol.nonceSize)
        )
    }

    private func makeListener(at socketPath: String) throws -> Int32 {
        var address = try AgentUnixSocketAddress(path: socketPath)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AgentSocketTestError.systemCall("socket", errno)
        }
        do {
            try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
            let bindResult = address.withSockAddr { pointer, length in
                Darwin.bind(fileDescriptor, pointer, length)
            }
            guard bindResult == 0 else {
                throw AgentSocketTestError.systemCall("bind", errno)
            }
            guard Darwin.listen(fileDescriptor, 1) == 0 else {
                throw AgentSocketTestError.systemCall("listen", errno)
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private func connectRaw(to socketPath: String) throws -> Int32 {
        var address = try AgentUnixSocketAddress(path: socketPath)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AgentSocketTestError.systemCall("socket", errno)
        }
        do {
            try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
            let result = address.withSockAddr { pointer, length in
                Darwin.connect(fileDescriptor, pointer, length)
            }
            guard result == 0 else {
                throw AgentSocketTestError.systemCall("connect", errno)
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private static func provideCredential(_ preflight: AgentIPCPreflight) -> String? {
        guard
            preflight.instanceID
                == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            preflight.paneID
                == UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        else {
            return nil
        }
        return String(repeating: "a", count: 64)
    }

    private static func validatePeer(_ fileDescriptor: Int32, expectedUID: uid_t) -> Bool {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        return getpeereid(fileDescriptor, &effectiveUID, &effectiveGID) == 0
            && effectiveUID == expectedUID
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private enum AgentSocketTestError: Error {
    case systemCall(String, Int32)
    case missingChallenge
    case invalidChallenge
    case missingAcknowledgement
    case trailingAcknowledgement
}
