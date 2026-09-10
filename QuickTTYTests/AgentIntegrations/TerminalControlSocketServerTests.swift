import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct TerminalControlSocketServerTests {
    @Test
    func clientRejectsInvalidControlIdentityBeforeConnecting() {
        for socketPath in ["relative/control.sock", "//tmp/control.sock", "/tmp/control.sock/"] {
            #expect(throws: TerminalControlSocketClientError.invalidConfiguration) {
                try TerminalControlSocketClient(
                    socketPath: socketPath,
                    instanceID: Self.instanceID,
                    paneID: Self.paneID,
                    paneToken: Self.paneToken
                )
            }
        }
        #expect(throws: TerminalControlSocketClientError.invalidConfiguration) {
            try TerminalControlSocketClient(
                socketPath: "/tmp/control.sock",
                instanceID: Self.instanceID,
                paneID: Self.paneID,
                paneToken: "secret"
            )
        }
    }

    @Test
    func roundTripsReadMutationAndStableErrorResponses() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let requests = Mutex<[TerminalControlSocketRequest]>([])
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { authenticatedRequest, _ in
            requests.withLock { $0.append(authenticatedRequest) }
            switch authenticatedRequest.request.operation {
            case .read(let taskID):
                return TerminalControlResponse(
                    result: .acknowledged(taskID: taskID, revision: 7)
                )
            case .focus(let taskID):
                return TerminalControlResponse(result: .task(Self.makeTask(taskID: taskID)))
            default:
                return TerminalControlResponse(
                    result: .failure(
                        try! TerminalControlError(
                            code: .targetNotOwned,
                            message: "Task is not owned"
                        )
                    )
                )
            }
        }
        let socketPath = try server.start()
        let client = try makeClient(socketPath: socketPath)
        let taskID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        #expect(
            try client.send(TerminalControlRequest(operation: .read(taskID: taskID)))
                == TerminalControlResponse(
                    result: .acknowledged(taskID: taskID, revision: 7)
                )
        )
        #expect(
            try client.send(
                TerminalControlRequest(
                    operation: .focus(taskID: taskID),
                    requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
                )) == TerminalControlResponse(result: .task(Self.makeTask(taskID: taskID)))
        )
        let failure = try client.send(TerminalControlRequest(operation: .list))
        #expect(
            failure
                == TerminalControlResponse(
                    result: .failure(
                        try TerminalControlError(
                            code: .targetNotOwned,
                            message: "Task is not owned"
                        )
                    )
                )
        )
        #expect(requests.withLock { $0.count } == 3)
        #expect(requests.withLock { $0.allSatisfy { $0.instanceID == Self.instanceID } })
        #expect(requests.withLock { $0.allSatisfy { $0.paneID == Self.paneID } })
        await server.stop()
    }

    @Test
    func usesPrivateIndependentSocketAndCleansPinnedEntries() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let server = makeServer(baseDirectory: baseDirectory)
        let socketPath = try server.start()
        let instanceDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path

        #expect(URL(fileURLWithPath: socketPath).lastPathComponent == "control.sock")
        #expect(try permissions(at: socketPath) == 0o600)
        #expect(try permissions(at: instanceDirectory) == 0o700)

        await server.stop()
        #expect(access(socketPath, F_OK) != 0)
        #expect(access(instanceDirectory, F_OK) != 0)
    }

    @Test
    func rejectsPeerBeforePreflightAndNeverInvokesHandler() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let validatorCalls = Mutex(0)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            peerValidator: { _, expectedUID in
                #expect(expectedUID == geteuid())
                validatorCalls.withLock { $0 += 1 }
                return false
            },
            credentialProvider: Self.provideCredential,
            handler: { _, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(result: .failure(Self.internalFailure()))
            }
        )
        let socketPath = try server.start()

        #expect(throws: TerminalControlSocketClientError.serverAuthenticationFailed) {
            try makeClient(socketPath: socketPath).send(
                TerminalControlRequest(operation: .read(taskID: UUID()))
            )
        }
        #expect(validatorCalls.withLock { $0 } == 1)
        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func duplicateAuthenticatedNonceIsRejectedAndCapacityIsReleased() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { request, _ in
            deliveries.withLock { $0 += 1 }
            return TerminalControlResponse(
                result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
            )
        }
        let socketPath = try server.start()
        let client = try makeClient(
            socketPath: socketPath,
            nonceGenerator: { Data(repeating: 7, count: TerminalControlProtocol.nonceSize) }
        )
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))

        _ = try client.send(request)
        #expect(throws: TerminalControlSocketClientError.transportFailure) {
            try client.send(request)
        }
        #expect(deliveries.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func nonceCacheExpiryRestoresAcceptanceWithoutRestart() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let now = Mutex<UInt64>(10)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            nonceCacheCapacity: 1,
            nonceRetentionMilliseconds: 100,
            monotonicMilliseconds: { now.withLock { $0 } },
            credentialProvider: Self.provideCredential,
            handler: { request, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(
                    result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
                )
            }
        )
        let socketPath = try server.start()
        let nonce = Data(repeating: 0x41, count: TerminalControlProtocol.nonceSize)
        let client = try makeClient(socketPath: socketPath, nonceGenerator: { nonce })
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))

        _ = try client.send(request)
        #expect(throws: TerminalControlSocketClientError.transportFailure) {
            try client.send(request)
        }
        now.withLock { $0 = 110 }
        _ = try client.send(request)

        #expect(deliveries.withLock { $0 } == 2)
        await server.stop()
    }

    @Test
    func evictedNonceRemainsReplaySafeBecauseFramesBindNewChallenge() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let challengeSequence = Mutex<UInt8>(0)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            nonceCacheCapacity: 1,
            challengeGenerator: {
                challengeSequence.withLock { sequence in
                    sequence &+= 1
                    return Data(repeating: sequence, count: TerminalControlProtocol.challengeSize)
                }
            },
            monotonicMilliseconds: { 0 },
            credentialProvider: Self.provideCredential,
            handler: { request, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(
                    result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
                )
            }
        )
        let socketPath = try server.start()
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let firstNonce = Data(repeating: 0x51, count: TerminalControlProtocol.nonceSize)
        let secondNonce = Data(repeating: 0x52, count: TerminalControlProtocol.nonceSize)

        let firstConnection = try connectRaw(to: socketPath)
        let capturedFrame = try makeAuthenticatedRequestFrame(
            request,
            fileDescriptor: firstConnection,
            nonce: firstNonce
        )
        try AgentSocketIO.writeAll(capturedFrame, to: firstConnection)
        try AgentSocketIO.shutdownWrite(firstConnection)
        while try AgentSocketIO.readByte(from: firstConnection) != nil {}
        Darwin.close(firstConnection)
        #expect(deliveries.withLock { $0 } == 1)

        _ = try makeClient(
            socketPath: socketPath,
            nonceGenerator: { secondNonce }
        ).send(request)
        #expect(deliveries.withLock { $0 } == 2)

        let replayConnection = try connectRaw(to: socketPath)
        _ = try makeAuthenticatedRequestFrame(
            request,
            fileDescriptor: replayConnection,
            nonce: firstNonce
        )
        try AgentSocketIO.writeAll(capturedFrame, to: replayConnection)
        try AgentSocketIO.shutdownWrite(replayConnection)
        #expect(try AgentSocketIO.readByte(from: replayConnection) == nil)
        Darwin.close(replayConnection)
        #expect(deliveries.withLock { $0 } == 2)

        _ = try makeClient(
            socketPath: socketPath,
            nonceGenerator: { firstNonce }
        ).send(request)
        #expect(deliveries.withLock { $0 } == 3)
        await server.stop()
    }

    @Test
    func credentialRotationAfterProofRejectsRequestBeforeHandler() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let credentialReads = Mutex(0)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: { preflight in
                guard Self.matchesIdentity(preflight) else { return nil }
                return credentialReads.withLock { reads in
                    reads += 1
                    return String(repeating: reads == 1 ? "a" : "b", count: 64)
                }
            },
            handler: { _, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(result: .failure(Self.internalFailure()))
            }
        )
        let socketPath = try server.start()

        #expect(throws: TerminalControlSocketClientError.transportFailure) {
            try makeClient(socketPath: socketPath).send(
                TerminalControlRequest(operation: .read(taskID: UUID()))
            )
        }
        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func malformedAndOversizedRequestLengthsNeverReachHandler() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            deliveries.withLock { $0 += 1 }
            return TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
        let socketPath = try server.start()

        for frame in [
            lengthPrefixed(Data(), declaredLength: 0),
            lengthPrefixed(Data("{}".utf8)),
            lengthPrefixed(
                Data(),
                declaredLength: TerminalControlProtocol.maximumRequestSize + 1
            ),
            lengthPrefixed(Data([1]), declaredLength: 2),
        ] {
            try sendAuthenticatedRaw(frame, to: socketPath)
        }

        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func delayedTrailingByteIsRejectedBeforeHandlerInvocation() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let frameBodyRead = DispatchSemaphore(value: 0)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            requestFrameReadObserver: { frameBodyRead.signal() },
            credentialProvider: Self.provideCredential,
            handler: { _, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(result: .failure(Self.internalFailure()))
            }
        )
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let frame = try makeAuthenticatedRequestFrame(
            request,
            fileDescriptor: fileDescriptor,
            nonce: Data(repeating: 0x31, count: TerminalControlProtocol.nonceSize)
        )

        try AgentSocketIO.writeAll(frame, to: fileDescriptor)
        #expect(await waitForSemaphore(frameBodyRead))
        try AgentSocketIO.writeAll(Data([0xFF]), to: fileDescriptor)
        try AgentSocketIO.shutdownWrite(fileDescriptor)

        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)
        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func missingRequestHalfCloseTimesOutBeforeHandlerInvocation() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let frameBodyRead = DispatchSemaphore(value: 0)
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            connectionTimeoutMilliseconds: 100,
            requestFrameReadObserver: { frameBodyRead.signal() },
            credentialProvider: Self.provideCredential,
            handler: { _, _ in
                deliveries.withLock { $0 += 1 }
                return TerminalControlResponse(result: .failure(Self.internalFailure()))
            }
        )
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let frame = try makeAuthenticatedRequestFrame(
            request,
            fileDescriptor: fileDescriptor,
            nonce: Data(repeating: 0x32, count: TerminalControlProtocol.nonceSize)
        )

        try AgentSocketIO.writeAll(frame, to: fileDescriptor)
        #expect(await waitForSemaphore(frameBodyRead))

        #expect(try AgentSocketIO.readByte(from: fileDescriptor) == nil)
        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()
    }

    @Test
    func authenticatedWireLimitsIncludeFramingOverhead() async throws {
        #expect(
            TerminalControlProtocol.maximumRequestPayloadSize
                + TerminalControlProtocol.authenticatedFrameOverhead
                == TerminalControlProtocol.maximumRequestSize
        )
        #expect(
            TerminalControlProtocol.maximumResponsePayloadSize
                + TerminalControlProtocol.authenticatedFrameOverhead
                == TerminalControlProtocol.maximumResponseSize
        )

        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let deliveries = Mutex(0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            deliveries.withLock { $0 += 1 }
            return TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
        let socketPath = try server.start()

        var exactRequestFrame = lengthPrefixed(
            Data(repeating: 0, count: TerminalControlProtocol.maximumRequestPayloadSize)
        )
        exactRequestFrame.append(
            Data(repeating: 0, count: TerminalControlProtocol.authenticationCodeSize)
        )
        #expect(exactRequestFrame.count == TerminalControlProtocol.maximumRequestSize)
        try sendAuthenticatedRaw(exactRequestFrame, to: socketPath)

        let oversizedRequestPayloadSize = TerminalControlProtocol.maximumRequestPayloadSize + 1
        #expect(
            oversizedRequestPayloadSize + TerminalControlProtocol.authenticatedFrameOverhead
                == TerminalControlProtocol.maximumRequestSize + 1
        )
        try sendAuthenticatedRaw(
            lengthPrefixed(Data(), declaredLength: oversizedRequestPayloadSize),
            to: socketPath
        )
        #expect(deliveries.withLock { $0 } == 0)
        await server.stop()

        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        for payloadSize in [
            TerminalControlProtocol.maximumResponsePayloadSize,
            TerminalControlProtocol.maximumResponsePayloadSize + 1,
        ] {
            var responseFrame = lengthPrefixed(Data(), declaredLength: payloadSize)
            if payloadSize == TerminalControlProtocol.maximumResponsePayloadSize {
                responseFrame.append(Data(repeating: 0, count: payloadSize))
                responseFrame.append(
                    Data(repeating: 0, count: TerminalControlProtocol.authenticationCodeSize)
                )
                #expect(responseFrame.count == TerminalControlProtocol.maximumResponseSize)
            } else {
                #expect(
                    payloadSize + TerminalControlProtocol.authenticatedFrameOverhead
                        == TerminalControlProtocol.maximumResponseSize + 1
                )
            }
            let fake = try OneShotAuthenticatedControlServer(responseFrame: responseFrame)
            let client = try makeClient(
                socketPath: fake.socketPath,
                nonceGenerator: {
                    Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
                }
            )
            #expect(throws: TerminalControlSocketClientError.invalidResponse) {
                try client.send(request)
            }
            fake.stop()
        }
    }

    @Test
    func handlerTimeoutReturnsAuthenticatedStableFailureAndCancelsHandler() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let cancelled = Mutex(false)
        let handlerCompleted = DispatchSemaphore(value: 0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            handlerTransportMarginMilliseconds: 25,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            defer { handlerCompleted.signal() }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelled.withLock { $0 = true }
            }
            return TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
        let socketPath = try server.start()
        let client = try makeClient(socketPath: socketPath, timeoutMilliseconds: 500)
        let request = try TerminalControlRequest(
            operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 100)
        )

        let response = try client.send(request)
        #expect(
            response
                == TerminalControlResponse(
                    result: .failure(
                        try TerminalControlError(
                            code: .timeout,
                            message: "Terminal control request timed out"
                        )
                    )
                )
        )
        #expect(await waitForSemaphore(handlerCompleted))
        #expect(cancelled.withLock { $0 })
        await server.stop()
    }

    @Test
    func requestHalfCloseKeepsSuspendedHandlerAliveAndDeliversResponse() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let entered = DispatchSemaphore(value: 0)
        let cancelled = Mutex(false)
        let monitorObservedIdle = TerminalControlAsyncGate()
        let release = TerminalControlAsyncGate()
        let monitorIdleObserver: @Sendable () -> Void = { monitorObservedIdle.open() }
        defer {
            monitorObservedIdle.open()
            release.open()
        }
        let taskID = UUID()
        let request = try TerminalControlRequest(
            operation: .wait(taskID: taskID, revision: 0, timeoutMilliseconds: 30_000)
        )
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            disconnectMonitorIdleObserver: monitorIdleObserver,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            await monitorObservedIdle.wait()
            entered.signal()
            return await withTaskCancellationHandler {
                await release.wait()
                return TerminalControlResponse(
                    result: .acknowledged(taskID: taskID, revision: 1)
                )
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
        let socketPath = try server.start()
        let sendTask = Task.detached {
            try makeClient(socketPath: socketPath).send(request)
        }
        #expect(await waitForSemaphore(entered))

        let cancelledAfterHalfClose = cancelled.withLock { $0 }
        release.open()
        let result = await sendTask.result
        await server.stop()

        #expect(!cancelledAfterHalfClose)
        #expect(
            try result.get()
                == TerminalControlResponse(
                    result: .acknowledged(taskID: taskID, revision: 1)
                )
        )
    }

    @Test
    func responseWriterRemainsOwnedUntilStopInterruptsAndClosesIt() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let responseWriteReached = DispatchSemaphore(value: 0)
        let responseWriteRelease = DispatchSemaphore(value: 0)
        let stopShutdownObserved = DispatchSemaphore(value: 0)
        let clientClosed = DispatchSemaphore(value: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let closeCount = Mutex(0)
        defer { responseWriteRelease.signal() }
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            maximumConnections: 1,
            handlerClientCloseObserver: {
                closeCount.withLock { $0 += 1 }
                clientClosed.signal()
            },
            responseWriteObserver: {
                responseWriteReached.signal()
                responseWriteRelease.wait()
            },
            stopClientShutdownObserver: { stopShutdownObserved.signal() },
            credentialProvider: Self.provideCredential,
            handler: { request, _ in
                TerminalControlResponse(
                    result: .acknowledged(
                        taskID: request.request.taskIDForTesting,
                        revision: 1
                    )
                )
            }
        )
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        try authenticateAndWriteRequest(request, fileDescriptor: fileDescriptor)
        #expect(await waitForSemaphore(responseWriteReached))

        let rejectedClient = try connectRaw(to: socketPath)
        defer { Darwin.close(rejectedClient) }
        #expect(
            try AgentSocketIO.readExactly(
                1,
                from: rejectedClient,
                deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
            ) == nil
        )

        _ = Task {
            await server.stop()
            stopCompleted.signal()
        }
        #expect(await waitForSemaphore(stopShutdownObserved))
        #expect(
            try AgentSocketIO.readExactly(
                1,
                from: fileDescriptor,
                deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
            ) == nil
        )

        responseWriteRelease.signal()
        #expect(await waitForSemaphore(clientClosed))
        #expect(await waitForSemaphore(stopCompleted))
        #expect(closeCount.withLock { $0 } == 1)
    }

    @Test
    func disconnectInvalidatesContextBeforePublishingOutcome() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let handlerEntered = DispatchSemaphore(value: 0)
        let waiterRegistered = DispatchSemaphore(value: 0)
        let monitorObservedIdle = DispatchSemaphore(value: 0)
        let cancellationWon = DispatchSemaphore(value: 0)
        let publicationRelease = DispatchSemaphore(value: 0)
        let handlerCheckedContext = DispatchSemaphore(value: 0)
        let mutationAllowed = TerminalControlAsyncGate()
        let observedReason = Mutex<AuthenticatedLocalSocketHandlerCancellationReason?>(nil)
        let observedContextActive = Mutex<Bool?>(nil)
        let mutationMarker = Mutex(false)
        defer {
            mutationAllowed.open()
            publicationRelease.signal()
        }
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            handlerTransportMarginMilliseconds: 25,
            disconnectMonitorIdleObserver: { monitorObservedIdle.signal() },
            handlerWaiterRegistrationObserver: { waiterRegistered.signal() },
            handlerCancellationTransitionObserver: { reason in
                observedReason.withLock { $0 = reason }
                cancellationWon.signal()
                publicationRelease.wait()
            },
            credentialProvider: Self.provideCredential,
            handler: { request, context in
                handlerEntered.signal()
                await mutationAllowed.wait()
                let isActive = context.isActive
                observedContextActive.withLock { $0 = isActive }
                if isActive {
                    mutationMarker.withLock { $0 = true }
                }
                handlerCheckedContext.signal()
                return TerminalControlResponse(
                    result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
                )
            }
        )
        let socketPath = try server.start()
        var fileDescriptor = try connectRaw(to: socketPath)
        defer {
            if fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
            }
        }
        let request = try TerminalControlRequest(
            operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 30_000)
        )
        try authenticateAndWriteRequest(request, fileDescriptor: fileDescriptor)
        #expect(await waitForSemaphore(handlerEntered))
        #expect(await waitForSemaphore(waiterRegistered))
        #expect(await waitForSemaphore(monitorObservedIdle))

        Darwin.close(fileDescriptor)
        fileDescriptor = -1
        #expect(await waitForSemaphore(cancellationWon))
        mutationAllowed.open()
        #expect(await waitForSemaphore(handlerCheckedContext))

        #expect(observedReason.withLock { $0 } == .disconnected)
        #expect(observedContextActive.withLock { $0 } == false)
        #expect(!mutationMarker.withLock { $0 })

        publicationRelease.signal()
        await server.stop()
    }

    @Test
    func stopNeverActsOnClientDescriptorReusedAfterCompletion() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let serverFileDescriptor = Mutex<Int32?>(nil)
        let clientDescriptorWasReused = Mutex(false)
        let staleClientOperations = Mutex(0)
        let handlerEntered = DispatchSemaphore(value: 0)
        let stopShutdownObserved = DispatchSemaphore(value: 0)
        let stopShutdownRelease = DispatchSemaphore(value: 0)
        let handlerCheckedContext = DispatchSemaphore(value: 0)
        let clientClosedAndReused = DispatchSemaphore(value: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let mutationAllowed = TerminalControlAsyncGate()
        let observedContextActive = Mutex<Bool?>(nil)
        let mutationMarker = Mutex(false)
        defer {
            mutationAllowed.open()
            stopShutdownRelease.signal()
        }
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            peerValidator: { fileDescriptor, expectedUID in
                serverFileDescriptor.withLock { $0 = fileDescriptor }
                return AuthenticatedLocalSocketServer.validatePeer(
                    fileDescriptor,
                    expectedUID: expectedUID
                )
            },
            handlerClientCloseObserver: { clientClosedAndReused.signal() },
            stopClientShutdownObserver: {
                stopShutdownObserved.signal()
                stopShutdownRelease.wait()
            },
            clientShutdownFunction: { fileDescriptor, direction in
                let isStale =
                    clientDescriptorWasReused.withLock { $0 }
                    && serverFileDescriptor.withLock { $0 } == fileDescriptor
                if isStale {
                    staleClientOperations.withLock { $0 += 1 }
                } else {
                    _ = Darwin.shutdown(fileDescriptor, direction)
                }
            },
            clientCloseFunction: { fileDescriptor in
                let isStale =
                    clientDescriptorWasReused.withLock { $0 }
                    && serverFileDescriptor.withLock { $0 } == fileDescriptor
                if isStale {
                    staleClientOperations.withLock { $0 += 1 }
                } else {
                    _ = Darwin.close(fileDescriptor)
                    clientDescriptorWasReused.withLock { $0 = true }
                }
            },
            credentialProvider: Self.provideCredential,
            handler: { request, context in
                handlerEntered.signal()
                await mutationAllowed.wait()
                let isActive = context.isActive
                observedContextActive.withLock { $0 = isActive }
                if isActive {
                    mutationMarker.withLock { $0 = true }
                }
                handlerCheckedContext.signal()
                return TerminalControlResponse(
                    result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
                )
            }
        )
        let socketPath = try server.start()
        let clientFileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(clientFileDescriptor) }
        let request = try TerminalControlRequest(
            operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 30_000)
        )
        try authenticateAndWriteRequest(request, fileDescriptor: clientFileDescriptor)
        #expect(await waitForSemaphore(handlerEntered))

        _ = Task {
            await server.stop()
            stopCompleted.signal()
        }
        #expect(await waitForSemaphore(stopShutdownObserved))
        #expect(try AgentSocketIO.readByte(from: clientFileDescriptor) == nil)

        mutationAllowed.open()
        #expect(await waitForSemaphore(handlerCheckedContext))
        #expect(await waitForSemaphore(clientClosedAndReused))
        #expect(observedContextActive.withLock { $0 } == false)
        #expect(!mutationMarker.withLock { $0 })
        #expect(clientDescriptorWasReused.withLock { $0 })

        stopShutdownRelease.signal()
        #expect(await waitForSemaphore(stopCompleted))
        #expect(staleClientOperations.withLock { $0 } == 0)
    }

    @Test
    func disconnectDuringWaitCancelsHandlerPromptly() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let entered = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            entered.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.signal()
            }
            return TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
        let socketPath = try server.start()
        let fileDescriptor = try connectRaw(to: socketPath)
        let request = try TerminalControlRequest(
            operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 30_000)
        )
        try authenticateAndWriteRequest(request, fileDescriptor: fileDescriptor)
        #expect(await waitForSemaphore(entered))

        Darwin.close(fileDescriptor)
        #expect(await waitForSemaphore(cancelled))
        await server.stop()
    }

    @Test
    func stopCancelsSuspendedHandlerWaitsAndDoesNotDeadlock() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let entered = DispatchSemaphore(value: 0)
        let handlerCompleted = DispatchSemaphore(value: 0)
        let cancelled = Mutex(false)
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            defer { handlerCompleted.signal() }
            entered.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
            return TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
        let socketPath = try server.start()
        let sendTask = Task.detached {
            try? makeClient(socketPath: socketPath, timeoutMilliseconds: 500).send(
                TerminalControlRequest(
                    operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 30_000)
                )
            )
        }
        #expect(await waitForSemaphore(entered))

        await server.stop()
        #expect(await waitForSemaphore(handlerCompleted))
        _ = await sendTask.value
        #expect(cancelled.withLock { $0 })
    }

    @Test
    func cancellationQueueRemainsGloballyBoundedAcrossStopRestartCycles() async throws {
        let baseDirectory = try makeTemporaryBaseDirectory()
        defer { removeTemporaryBaseDirectory(baseDirectory) }
        let capacity = 2
        let entered = DispatchSemaphore(value: 0)
        let cancellationEnqueued = DispatchSemaphore(value: 0)
        let cancellationDeliveryStarted = DispatchSemaphore(value: 0)
        let cancellationHandlerStarted = DispatchSemaphore(value: 0)
        let cancellationHandlerRelease = DispatchSemaphore(value: 0)
        let executionReleased = DispatchSemaphore(value: 0)
        let swiftTaskProgressed = DispatchSemaphore(value: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let release = TerminalControlAsyncGate()
        let shouldSuspend = Mutex(true)
        let enqueueCount = Mutex(0)
        let deliveryCount = Mutex(0)
        let permittedEffects = Mutex(0)
        defer {
            cancellationHandlerRelease.signal()
            cancellationHandlerRelease.signal()
            release.open()
        }
        let server = TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            maximumExecutingHandlers: capacity,
            handlerTransportMarginMilliseconds: 25,
            handlerExecutionReleaseObserver: { executionReleased.signal() },
            handlerCancellationEnqueueObserver: {
                enqueueCount.withLock { $0 += 1 }
                cancellationEnqueued.signal()
            },
            handlerCancellationDeliveryObserver: {
                deliveryCount.withLock { $0 += 1 }
                cancellationDeliveryStarted.signal()
            },
            credentialProvider: Self.provideCredential,
            handler: { request, context in
                entered.signal()
                if shouldSuspend.withLock({ $0 }) {
                    await withTaskCancellationHandler {
                        await release.wait()
                    } onCancel: {
                        cancellationHandlerStarted.signal()
                        cancellationHandlerRelease.wait()
                    }
                }
                if context.isActive {
                    permittedEffects.withLock { $0 += 1 }
                }
                return TerminalControlResponse(
                    result: .acknowledged(taskID: request.request.taskIDForTesting, revision: 1)
                )
            }
        )
        let waitRequest = try TerminalControlRequest(
            operation: .wait(taskID: UUID(), revision: 0, timeoutMilliseconds: 30_000)
        )
        let firstPath = try server.start()
        let sends = (0..<capacity).map { _ in
            Task.detached {
                try? makeClient(socketPath: firstPath, timeoutMilliseconds: 500).send(waitRequest)
            }
        }
        for _ in 0..<capacity {
            #expect(await waitForSemaphore(entered))
        }

        _ = Task {
            await server.stop()
            stopCompleted.signal()
        }
        let stoppedInTime = await waitForSemaphore(stopCompleted)
        if !stoppedInTime {
            cancellationHandlerRelease.signal()
            cancellationHandlerRelease.signal()
            shouldSuspend.withLock { $0 = false }
            release.open()
            #expect(await waitForSemaphore(stopCompleted))
        }
        #expect(stoppedInTime)
        guard stoppedInTime else { return }
        for send in sends {
            _ = await send.value
        }
        #expect(await waitForSemaphore(cancellationEnqueued))
        #expect(await waitForSemaphore(cancellationEnqueued))
        #expect(await waitForSemaphore(cancellationDeliveryStarted))
        #expect(await waitForSemaphore(cancellationHandlerStarted))

        Task {
            await Task.yield()
            swiftTaskProgressed.signal()
        }
        #expect(await waitForSemaphore(swiftTaskProgressed))

        for _ in 0..<3 {
            let socketPath = try server.start()
            #expect(throws: TerminalControlSocketClientError.transportFailure) {
                try makeClient(socketPath: socketPath, timeoutMilliseconds: 500).send(waitRequest)
            }
            await server.stop()
        }
        #expect(enqueueCount.withLock { $0 } == capacity)
        #expect(deliveryCount.withLock { $0 } == 1)

        cancellationHandlerRelease.signal()
        #expect(await waitForSemaphore(cancellationDeliveryStarted))
        #expect(await waitForSemaphore(cancellationHandlerStarted))
        #expect(deliveryCount.withLock { $0 } == capacity)
        cancellationHandlerRelease.signal()
        shouldSuspend.withLock { $0 = false }
        release.open()
        for _ in 0..<capacity {
            #expect(await waitForSemaphore(executionReleased))
        }
        #expect(enqueueCount.withLock { $0 } == capacity)
        #expect(permittedEffects.withLock { $0 } == 0)

        let finalPath = try server.start()
        let finalResponse = try makeClient(socketPath: finalPath).send(waitRequest)
        #expect(
            finalResponse
                == TerminalControlResponse(
                    result: .acknowledged(taskID: waitRequest.taskIDForTesting, revision: 1)
                )
        )
        #expect(permittedEffects.withLock { $0 } == 1)
        await server.stop()
    }

    @Test
    func clientRejectsMissingAndForgedProof() async throws {
        for response in [
            Data(),
            Data([1]) + Self.fakeChallenge
                + Data(repeating: 0, count: TerminalControlProtocol.authenticationCodeSize),
        ] {
            let fake = try OneShotSocketServer(response: response)
            defer { fake.stop() }
            let client = try makeClient(socketPath: fake.socketPath)
            #expect(throws: TerminalControlSocketClientError.serverAuthenticationFailed) {
                try client.send(TerminalControlRequest(operation: .read(taskID: UUID())))
            }
        }
    }

    @Test
    func clientRejectsForgedWronglyBoundAndOversizedResponses() async throws {
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let otherRequest = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let response = TerminalControlResponse(
            result: .acknowledged(taskID: UUID(), revision: 1)
        )

        let forged = try makeFakeExchangeResponse(
            request: request,
            response: response,
            macRequest: request,
            forgeMAC: true
        )
        let wrongBinding = try makeFakeExchangeResponse(
            request: request,
            response: response,
            macRequest: otherRequest,
            forgeMAC: false
        )
        let oversized = lengthPrefixed(
            Data(),
            declaredLength: TerminalControlProtocol.maximumResponseSize + 1
        )

        for rawResponse in [forged, wrongBinding] {
            let fake = try OneShotAuthenticatedControlServer(responseFrame: rawResponse)
            defer { fake.stop() }
            let client = try makeClient(
                socketPath: fake.socketPath,
                nonceGenerator: {
                    Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
                }
            )
            #expect(throws: TerminalControlSocketClientError.responseAuthenticationFailed) {
                try client.send(request)
            }
        }

        let fake = try OneShotAuthenticatedControlServer(responseFrame: oversized)
        defer { fake.stop() }
        let client = try makeClient(
            socketPath: fake.socketPath,
            nonceGenerator: {
                Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
            }
        )
        #expect(throws: TerminalControlSocketClientError.invalidResponse) {
            try client.send(request)
        }
    }

    @Test
    func clientRejectsMalformedTruncatedMismatchedAndTrailingResponses() async throws {
        let request = try TerminalControlRequest(operation: .read(taskID: UUID()))
        let response = TerminalControlResponse(
            result: .acknowledged(taskID: UUID(), revision: 1)
        )
        let validFrame = try makeFakeExchangeResponse(
            request: request,
            response: response,
            macRequest: request,
            forgeMAC: false
        )
        var declaredLengthMismatch = validFrame
        let payloadSize = validFrame.count - TerminalControlProtocol.authenticatedFrameOverhead
        replaceDeclaredLength(in: &declaredLengthMismatch, with: payloadSize + 1)
        var trailingByte = validFrame
        trailingByte.append(0)
        var trailingFrame = validFrame
        trailingFrame.append(validFrame)

        let malformedResponses: [(Data, TerminalControlSocketClientError)] = [
            (lengthPrefixed(Data(), declaredLength: 0), .invalidResponse),
            (Data([0, 0]), .transportFailure),
            (lengthPrefixed(Data([1]), declaredLength: 2), .transportFailure),
            (Data(validFrame.dropLast()), .transportFailure),
            (declaredLengthMismatch, .transportFailure),
            (trailingByte, .invalidResponse),
            (trailingFrame, .invalidResponse),
        ]

        for (responseFrame, expectedError) in malformedResponses {
            let fake = try OneShotAuthenticatedControlServer(responseFrame: responseFrame)
            let client = try makeClient(
                socketPath: fake.socketPath,
                nonceGenerator: {
                    Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
                }
            )
            do {
                _ = try client.send(request)
                Issue.record("Malformed response was accepted")
            } catch let error as TerminalControlSocketClientError {
                #expect(error == expectedError)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            fake.stop()
        }
    }

    private static let instanceID = UUID(
        uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private static let paneID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    fileprivate static let paneToken = String(repeating: "a", count: 64)
    fileprivate static let fakeChallenge = Data(
        repeating: 0x24,
        count: TerminalControlProtocol.challengeSize
    )

    private static func makeTask(taskID: UUID) -> TerminalControlTask {
        TerminalControlTask(
            taskID: taskID,
            paneID: paneID,
            tabID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            workspaceID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            state: .running,
            owner: .agent,
            policy: .keep,
            revision: 7,
            exitCode: nil
        )
    }

    private static func internalFailure() -> TerminalControlError {
        try! TerminalControlError(code: .internalFailure, message: "Internal failure")
    }

    private static func timeoutResponse() -> TerminalControlResponse {
        TerminalControlResponse(
            result: .failure(
                try! TerminalControlError(
                    code: .timeout,
                    message: "Terminal control request timed out"
                )
            )
        )
    }

    private func makeServer(baseDirectory: String) -> TerminalControlSocketServer {
        TerminalControlSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: Self.provideCredential
        ) { _, _ in
            TerminalControlResponse(result: .failure(Self.internalFailure()))
        }
    }

    private func makeClient(
        socketPath: String,
        nonceGenerator: @escaping @Sendable () -> Data = {
            Data((0..<TerminalControlProtocol.nonceSize).map { _ in UInt8.random(in: 0...255) })
        },
        timeoutMilliseconds: Int? = nil
    ) throws -> TerminalControlSocketClient {
        try TerminalControlSocketClient(
            socketPath: socketPath,
            instanceID: Self.instanceID,
            paneID: Self.paneID,
            paneToken: Self.paneToken,
            nonceGenerator: nonceGenerator,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    private static func matchesIdentity(_ preflight: TerminalControlPreflight) -> Bool {
        preflight.instanceID == instanceID && preflight.paneID == paneID
    }

    private static func provideCredential(_ preflight: TerminalControlPreflight) -> String? {
        matchesIdentity(preflight) ? paneToken : nil
    }

    private func makeTemporaryBaseDirectory() throws -> String {
        let path = "/tmp/qtt-control-test-\(UUID().uuidString)"
        guard mkdir(path, 0o700) == 0 else {
            throw TerminalControlSocketTestError.systemCall
        }
        return path
    }

    private func removeTemporaryBaseDirectory(_ path: String) {
        _ = rmdir(path)
    }

    private func permissions(at path: String) throws -> mode_t {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0 else {
            throw TerminalControlSocketTestError.systemCall
        }
        return fileStatus.st_mode & 0o777
    }

    private func waitForSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private func connectRaw(to socketPath: String) throws -> Int32 {
        var address = try AgentUnixSocketAddress(path: socketPath)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw TerminalControlSocketTestError.systemCall }
        do {
            try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
            guard
                address.withSockAddr({ pointer, length in
                    Darwin.connect(fileDescriptor, pointer, length)
                }) == 0
            else {
                throw TerminalControlSocketTestError.systemCall
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private func authenticateAndWriteRequest(
        _ request: TerminalControlRequest,
        fileDescriptor: Int32
    ) throws {
        let frame = try makeAuthenticatedRequestFrame(
            request,
            fileDescriptor: fileDescriptor,
            nonce: Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
        )
        try AgentSocketIO.writeAll(frame, to: fileDescriptor)
        try AgentSocketIO.shutdownWrite(fileDescriptor)
    }

    private func makeAuthenticatedRequestFrame(
        _ request: TerminalControlRequest,
        fileDescriptor: Int32,
        nonce: Data
    ) throws -> Data {
        let preflight = try TerminalControlPreflight(
            instanceID: Self.instanceID,
            paneID: Self.paneID,
            nonce: nonce
        )
        try AgentSocketIO.writeAll(
            TerminalControlProtocol.encodePreflight(preflight),
            to: fileDescriptor
        )
        guard try AgentSocketIO.readByte(from: fileDescriptor) == 1 else {
            throw TerminalControlSocketTestError.authenticationFailed
        }
        guard
            let challenge = try AgentSocketIO.readExactly(
                TerminalControlProtocol.challengeSize,
                from: fileDescriptor,
                deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
            ),
            let proof = try AgentSocketIO.readExactly(
                TerminalControlProtocol.authenticationCodeSize,
                from: fileDescriptor,
                deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
            ),
            TerminalControlProtocol.verifyServerProof(
                proof,
                for: preflight,
                challenge: challenge,
                paneToken: Self.paneToken
            )
        else {
            throw TerminalControlSocketTestError.authenticationFailed
        }
        return try TerminalControlProtocol.encodeRequestFrame(
            request,
            for: preflight,
            challenge: challenge,
            paneToken: Self.paneToken
        )
    }

    private func sendAuthenticatedRaw(_ frame: Data, to socketPath: String) throws {
        let fileDescriptor = try connectRaw(to: socketPath)
        defer { Darwin.close(fileDescriptor) }
        let preflight = try TerminalControlPreflight(
            instanceID: Self.instanceID,
            paneID: Self.paneID,
            nonce: Data(
                (0..<TerminalControlProtocol.nonceSize).map { _ in UInt8.random(in: 0...255) })
        )
        try AgentSocketIO.writeAll(
            TerminalControlProtocol.encodePreflight(preflight),
            to: fileDescriptor
        )
        _ = try AgentSocketIO.readExactly(
            1 + TerminalControlProtocol.challengeSize
                + TerminalControlProtocol.authenticationCodeSize,
            from: fileDescriptor,
            deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
        )
        try AgentSocketIO.writeAll(frame, to: fileDescriptor)
        try AgentSocketIO.shutdownWrite(fileDescriptor)
        _ = try? AgentSocketIO.readByte(from: fileDescriptor)
    }

    private func makeFakeExchangeResponse(
        request: TerminalControlRequest,
        response: TerminalControlResponse,
        macRequest: TerminalControlRequest,
        forgeMAC: Bool
    ) throws -> Data {
        let preflight = try TerminalControlPreflight(
            instanceID: Self.instanceID,
            paneID: Self.paneID,
            nonce: Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
        )
        var frame = try TerminalControlProtocol.encodeResponseFrame(
            response,
            for: preflight,
            challenge: Self.fakeChallenge,
            request: macRequest,
            paneToken: Self.paneToken
        )
        if forgeMAC {
            frame[frame.index(before: frame.endIndex)] ^= 1
        }
        return frame
    }

    private func lengthPrefixed(_ payload: Data, declaredLength: Int? = nil) -> Data {
        var length = UInt32(declaredLength ?? payload.count).bigEndian
        var frame = Data()
        Swift.withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func replaceDeclaredLength(in frame: inout Data, with payloadSize: Int) {
        var length = UInt32(payloadSize).bigEndian
        Swift.withUnsafeBytes(of: &length) { bytes in
            frame.replaceSubrange(0..<MemoryLayout<UInt32>.size, with: bytes)
        }
    }
}

extension TerminalControlRequest {
    fileprivate var taskIDForTesting: UUID {
        switch operation {
        case .read(let taskID), .wait(let taskID, _, _), .sendText(let taskID, _, _),
            .sendKey(let taskID, _, _), .requestUserInput(let taskID), .focus(let taskID),
            .resize(let taskID, _), .interrupt(let taskID, _), .close(let taskID):
            taskID
        case .list, .createTab, .split:
            UUID()
        }
    }
}

private final class OneShotSocketServer {
    let socketPath: String
    private let listener: Int32

    init(response: Data) throws {
        socketPath = "/tmp/qtt-control-fake-\(UUID().uuidString).sock"
        listener = try Self.makeListener(at: socketPath)
        let listener = listener
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            _ = try? AgentSocketIO.readExactly(
                TerminalControlProtocol.preflightSize,
                from: client,
                deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
            )
            try? AgentSocketIO.writeAll(response, to: client)
            try? AgentSocketIO.shutdownWrite(client)
        }
    }

    func stop() {
        Darwin.close(listener)
        _ = unlink(socketPath)
    }

    fileprivate static func makeListener(at socketPath: String) throws -> Int32 {
        var address = try AgentUnixSocketAddress(path: socketPath)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw TerminalControlSocketTestError.systemCall }
        guard
            address.withSockAddr({ pointer, length in
                Darwin.bind(fileDescriptor, pointer, length)
            }) == 0,
            Darwin.listen(fileDescriptor, 1) == 0
        else {
            Darwin.close(fileDescriptor)
            throw TerminalControlSocketTestError.systemCall
        }
        return fileDescriptor
    }
}

private final class OneShotAuthenticatedControlServer {
    let socketPath: String
    private let listener: Int32

    init(responseFrame: Data) throws {
        socketPath = "/tmp/qtt-control-auth-fake-\(UUID().uuidString).sock"
        listener = try OneShotSocketServer.makeListener(at: socketPath)
        let listener = listener
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            guard
                let preflightData = try? AgentSocketIO.readExactly(
                    TerminalControlProtocol.preflightSize,
                    from: client,
                    deadline: AgentSocketDeadline(timeoutMilliseconds: 2_000)
                ),
                let preflight = try? TerminalControlProtocol.decodePreflight(preflightData),
                let proof = try? TerminalControlProtocol.makeServerProof(
                    for: preflight,
                    challenge: TerminalControlSocketServerTests.fakeChallenge,
                    paneToken: TerminalControlSocketServerTests.paneToken
                )
            else { return }
            try? AgentSocketIO.writeAll(
                Data([1]) + TerminalControlSocketServerTests.fakeChallenge + proof,
                to: client
            )
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while Darwin.read(client, &buffer, buffer.count) > 0 {}
            try? AgentSocketIO.writeAll(responseFrame, to: client)
            try? AgentSocketIO.shutdownWrite(client)
        }
    }

    func stop() {
        Darwin.close(listener)
        _ = unlink(socketPath)
    }
}

private final class TerminalControlAsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let pendingWaiters = state.withLock { state in
            state.isOpen = true
            let pendingWaiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return pendingWaiters
        }
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private enum TerminalControlSocketTestError: Error {
    case systemCall
    case authenticationFailed
}
