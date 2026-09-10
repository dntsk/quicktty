import Foundation
import Synchronization
import Testing

@testable import QuickTTY

@MainActor
struct TerminalAutomationCoordinatorTests {
    @Test
    func closeQueueCancellationPreservesPendingOrderAndOtherParticipants() throws {
        var callbacks: [GhosttyConfirmationQueue.Completion] = []
        var results: [Int] = []
        var dismissals = 0
        let queue = GhosttyConfirmationQueue { _, completion in
            callbacks.append(completion)
            return { dismissals += 1 }
        }
        queue.enqueueClose(paneID: paneID(1)) { _ in results.append(0) }
        queue.enqueueClose(paneID: paneID(2)) { _ in results.append(1) }
        let cancelled = queue.enqueueClose(paneID: paneID(2)) { _ in results.append(2) }
        queue.enqueueClose(paneID: paneID(2)) { _ in results.append(3) }
        let solePending = queue.enqueueClose(paneID: paneID(3)) { _ in results.append(4) }
        queue.cancelClose(cancelled)
        queue.cancelClose(cancelled)
        queue.cancelClose(solePending)
        #expect(queue.pendingCount == 1)
        #expect(dismissals == 0)
        callbacks[0](.allow)
        #expect(callbacks.count == 2)
        #expect(queue.activePresentation == .close(paneID(2)))
        callbacks[1](.allow)
        callbacks[1](.deny)
        #expect(results == [0, 1, 3])
        #expect(queue.activePresentation == nil)
        #expect(queue.pendingCount == 0)
        queue.invalidateAll()
        #expect(results == [0, 1, 3])
    }

    @Test
    func clipboardDenialCannotResurrectACancelledCloseParticipant() {
        var presentations: [GhosttyConfirmationPresentation] = []
        var callbacks: [GhosttyConfirmationQueue.Completion] = []
        var denied = 0
        var closeCalls = 0
        var token: GhosttyConfirmationQueue.CloseToken?
        let queue = GhosttyConfirmationQueue { presentation, completion in
            presentations.append(presentation)
            callbacks.append(completion)
            return nil
        }
        queue.enqueueClose(paneID: paneID(1)) { _ in }
        let clipboard = GhosttyClipboardConfirmationRequest(
            id: uuid(10), paneID: paneID(2), kind: .paste, location: .standard, contents: [])
        queue.enqueueClipboard(clipboard) { response in
            #expect(response == .deny)
            denied += 1
            if let token { queue.cancelClose(token) }
        }
        token = queue.enqueueClose(paneID: paneID(3)) { _ in closeCalls += 1 }
        #expect(queue.pendingCount == 2)
        queue.invalidateClipboard(for: paneID(2))
        #expect(denied == 1)
        #expect(queue.pendingCount == 0)
        callbacks[0](.allow)
        #expect(presentations == [.close(paneID(1))])
        #expect(closeCalls == 0)
        #expect(queue.activePresentation == nil)
    }

    @Test
    func closeQueueParticipantCanBeCancelledDuringCoalescedResolution() throws {
        var callback: GhosttyConfirmationQueue.Completion?
        var results: [Int] = []
        var cancelled: GhosttyConfirmationQueue.CloseToken?
        let queue = GhosttyConfirmationQueue { _, completion in
            callback = completion
            return nil
        }
        queue.enqueueClose(paneID: paneID(1)) { _ in
            results.append(1)
            if let cancelled { queue.cancelClose(cancelled) }
        }
        cancelled = queue.enqueueClose(paneID: paneID(1)) { _ in results.append(2) }
        queue.enqueueClose(paneID: paneID(1)) { _ in results.append(3) }
        let resolve = try #require(callback)
        resolve(.allow)
        resolve(.allow)
        #expect(results == [1, 3])
        #expect(queue.activePresentation == nil)
    }

    @Test
    func closeQueueCancelsLastParticipantInsidePresenterAndDismissalReentrancy() throws {
        var queue: GhosttyConfirmationQueue?
        var token: GhosttyConfirmationQueue.CloseToken?
        var callbacks: [GhosttyConfirmationQueue.Completion] = []
        var dismissals = 0
        var cancelledCalls = 0
        queue = GhosttyConfirmationQueue { presentation, completion in
            callbacks.append(completion)
            if presentation == .close(paneID(2)), let token {
                queue?.cancelClose(token)
            }
            return {
                dismissals += 1
                // WHY: Ending a sheet may synchronously deliver a stale allow or deny callback.
                completion(.allow)
                if let token { queue?.cancelClose(token) }
            }
        }
        let ownedQueue = try #require(queue)
        ownedQueue.enqueueClose(paneID: paneID(1)) { _ in }
        token = ownedQueue.enqueueClose(paneID: paneID(2)) { _ in cancelledCalls += 1 }
        callbacks[0](.allow)
        #expect(callbacks.count == 2)
        #expect(dismissals == 1)
        #expect(cancelledCalls == 0)
        #expect(ownedQueue.activePresentation == nil)
        #expect(ownedQueue.pendingCount == 0)
        callbacks[1](.allow)
        #expect(cancelledCalls == 0)
        queue = nil
    }

    @Test
    func createTabSplitAndListRegisterOwnedTasks() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let firstTask = task(
            taskID: uuid(10),
            paneID: uuid(20),
            tabID: uuid(30),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(firstTask))

        let createTabRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(100)
        )
        let createTabResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: createTabRequest),
            context: context()
        )

        #expect(createTabResponse == TerminalControlResponse(result: .task(firstTask)))
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.count == 1)
        #expect(host.createSplitCalls.isEmpty)

        let listedAfterTab = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)),
            context: context()
        )
        expectList(
            listedAfterTab,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [firstTask.taskID]
        )

        let splitTask = task(
            taskID: uuid(11),
            paneID: uuid(21),
            tabID: firstTask.tabID,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .waitingForUser,
            policy: .closeOnSuccess
        )
        let splitID = uuid(41)
        host.enqueueCreateSplitResult(
            .createdTask(
                TerminalAutomationCreatedTaskResponse(task: splitTask, splitID: splitID)
            )
        )
        let splitRequest = try TerminalControlRequest(
            operation: .split(
                anchorPaneID: firstTask.paneID,
                direction: .right,
                ratio: 0.4,
                launch: try launch(),
                policy: .closeOnSuccess,
                focus: false
            ),
            requestID: uuid(101)
        )
        let splitResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin, request: splitRequest
            ),
            context: context()
        )

        #expect(splitResponse == TerminalControlResponse(result: .task(splitTask)))
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.count == 1)
        #expect(host.createSplitCalls.count == 1)
        #expect(host.createSplitCalls[0].anchorPaneID == PaneID(rawValue: firstTask.paneID))

        let listedAfterSplit = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)),
            context: context()
        )
        expectList(
            listedAfterSplit,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [firstTask.taskID, splitTask.taskID]
        )
        #expect(coordinator.ownedSplitIDsForTesting(session.identity) == Set([splitID]))

        host.taskStates.removeValue(forKey: splitTask.taskID)
        let listedAfterSplitRemoval = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listedAfterSplitRemoval,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [firstTask.taskID]
        )
        #expect(coordinator.ownedSplitIDsForTesting(session.identity).isEmpty)
    }

    @Test
    func separateSessionsCanSplitTheirOriginPanesIntoTheSameTab() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let firstOrigin = paneID(40_000)
        let secondOrigin = paneID(40_001)
        let sharedTabID = TabID(rawValue: uuid(40_002))
        let firstSession = resolvedSession(
            originPaneID: firstOrigin,
            originTabID: sharedTabID,
            activeTabID: sharedTabID
        )
        let secondSession = resolvedSession(
            originPaneID: secondOrigin,
            sessionID: "session-2",
            workspaceID: firstSession.workspace.workspaceID,
            originTabID: sharedTabID,
            activeTabID: sharedTabID
        )
        host.setResolvedSession(firstSession)
        host.setResolvedSession(secondSession)
        host.enqueuePromptDecision(.allowed)
        host.enqueuePromptDecision(.allowed)

        let firstTask = task(
            taskID: uuid(40_010),
            paneID: uuid(40_011),
            tabID: sharedTabID.rawValue,
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            state: .running
        )
        let secondTask = task(
            taskID: uuid(40_012),
            paneID: uuid(40_013),
            tabID: sharedTabID.rawValue,
            workspaceID: secondSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateSplitResult(.task(firstTask))
        host.enqueueCreateSplitResult(.task(secondTask))

        let firstResponse = await coordinator.handle(
            request(
                instanceID: firstSession.identity.instanceID,
                originPaneID: firstOrigin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(40_020)
                )
            ),
            context: context()
        )
        let secondResponse = await coordinator.handle(
            request(
                instanceID: secondSession.identity.instanceID,
                originPaneID: secondOrigin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil,
                        direction: .left,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(40_021)
                )
            ),
            context: context()
        )

        #expect(firstResponse == TerminalControlResponse(result: .task(firstTask)))
        #expect(secondResponse == TerminalControlResponse(result: .task(secondTask)))
        #expect(host.discardCreatedTaskCalls.isEmpty)
    }

    @Test
    func staleSessionAfterCreatedResponseCompensatesExactlyOnce() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_100)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()
        let createdTask = task(
            taskID: uuid(40_101),
            paneID: uuid(40_102),
            tabID: uuid(40_103),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(40_104)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        host.setResolvedSession(
            resolvedSession(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                workspaceID: WorkspaceID(rawValue: uuid(40_105))
            )
        )
        host.resumeCreateTabResponses()

        expectFailure(await pending.value, code: .staleSession)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.discardCreatedTaskCalls[0].created.task == createdTask)
        #expect(host.taskStates[createdTask.taskID] == nil)
        host.setResolvedSession(session)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test
    func suspendedCreateCompensatesAcrossBindingABAAndPromptsForNewEpoch() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_110)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()
        let createdTask = task(
            taskID: uuid(40_111),
            paneID: uuid(40_112),
            tabID: uuid(40_113),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(40_114)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        host.setResolvedSession(
            resolvedSession(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                sessionID: "session-b",
                paneCredentialGeneration: 2
            )
        )
        let returnedA = resolvedSession(
            instanceID: initial.identity.instanceID,
            originPaneID: origin,
            sessionID: initial.identity.sessionID,
            paneCredentialGeneration: 3
        )
        host.setResolvedSession(returnedA)
        host.resumeCreateTabResponses()

        expectFailure(await pending.value, code: .permissionRevoked)
        await host.waitForDiscardCreatedTaskCalls(1)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.discardCreatedTaskCalls[0].created.task == createdTask)
        #expect(host.taskStates[createdTask.taskID] == nil)

        host.enqueuePromptDecision(.allowed)
        let freshList = await coordinator.handle(
            request(
                instanceID: returnedA.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            freshList,
            workspaceID: returnedA.workspace.workspaceID.rawValue,
            taskIDs: []
        )
        #expect(host.promptCallCount == 2)
    }

    @Test
    func failedCompensationReturnsInternalFailureWithoutRegisteringOwnership() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_140)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()
        host.discardCreatedTaskSucceeds = false
        let createdTask = task(
            taskID: uuid(40_141),
            paneID: uuid(40_142),
            tabID: uuid(40_143),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(40_144)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        host.setResolvedSession(
            resolvedSession(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                workspaceID: WorkspaceID(rawValue: uuid(40_145))
            )
        )
        host.resumeCreateTabResponses()

        expectFailure(await pending.value, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.taskStates[createdTask.taskID] == createdTask)
        host.setResolvedSession(session)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test(arguments: HostileCreateIdentity.allCases)
    private func createRejectsOriginPaneOrExistingTabBeforeOwnershipRegistration(
        identity: HostileCreateIdentity
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_150)
        let currentPane = paneID(40_155)
        let originTabID = TabID(rawValue: uuid(40_156))
        let currentTabID = TabID(rawValue: uuid(40_157))
        let session = resolvedSession(
            originPaneID: origin,
            originTabID: originTabID,
            activeTabID: currentTabID,
            tabCount: 2,
            paneCount: 2,
            tabIDs: [originTabID, currentTabID],
            paneIDs: [origin, currentPane]
        )
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let paneID: UUID
        let tabID: UUID
        switch identity {
        case .originPane:
            paneID = origin.rawValue
            tabID = uuid(40_170)
        case .existingPane:
            paneID = currentPane.rawValue
            tabID = uuid(40_171)
        case .originTab:
            paneID = uuid(40_160)
            tabID = originTabID.rawValue
        case .currentTab:
            paneID = uuid(40_161)
            tabID = currentTabID.rawValue
        }
        let invalidTask = task(
            taskID: uuid(40_151 + identity.rawValue),
            paneID: paneID,
            tabID: tabID,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(invalidTask))

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_180 + identity.rawValue)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.taskStates[invalidTask.taskID] == nil)
    }

    @Test(arguments: HostileSplitPaneIdentity.allCases)
    private func splitRejectsAnchorOrExistingPaneBeforeOwnershipRegistration(
        identity: HostileSplitPaneIdentity
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_181)
        let existingPane = paneID(40_182)
        let session = resolvedSession(
            originPaneID: origin,
            paneCount: 2,
            paneIDs: [origin, existingPane]
        )
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let invalidTask = task(
            taskID: uuid(40_183 + identity.rawValue),
            paneID: identity == .originAnchor ? origin.rawValue : existingPane.rawValue,
            tabID: session.workspace.originTabID.rawValue,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateSplitResult(.task(invalidTask))

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(40_185 + identity.rawValue)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.taskStates[invalidTask.taskID] == nil)
    }

    @Test
    func splitRejectsOwnedAnchorAndOriginPaneResponses() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_184)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let anchorTask = task(
            taskID: uuid(40_185),
            paneID: uuid(40_186),
            tabID: uuid(40_187),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(anchorTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_188)
                )
            ),
            context: context()
        )

        for (index, paneID) in [anchorTask.paneID, origin.rawValue].enumerated() {
            let invalidTask = task(
                taskID: uuid(40_189 + index),
                paneID: paneID,
                tabID: anchorTask.tabID,
                workspaceID: session.workspace.workspaceID.rawValue,
                state: .running
            )
            host.enqueueCreateSplitResult(.task(invalidTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .split(
                            anchorPaneID: anchorTask.paneID,
                            direction: .down,
                            ratio: 0.5,
                            launch: try launch(),
                            policy: .keep,
                            focus: false
                        ),
                        requestID: uuid(40_191 + index)
                    )
                ),
                context: context()
            )
            expectFailure(response, code: .internalFailure)
        }

        let wrongTabTask = task(
            taskID: uuid(40_193),
            paneID: uuid(40_200),
            tabID: session.workspace.originTabID.rawValue,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateSplitResult(.task(wrongTabTask))
        let wrongTabResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: anchorTask.paneID,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(40_201)
                )
            ),
            context: context()
        )
        expectFailure(wrongTabResponse, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 3)
    }

    @Test
    func splitRejectsUnrelatedExistingTabInTheSameWorkspace() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_194)
        let originTabID = TabID(rawValue: uuid(40_195))
        let unrelatedTabID = TabID(rawValue: uuid(40_196))
        let session = resolvedSession(
            originPaneID: origin,
            originTabID: originTabID,
            activeTabID: unrelatedTabID,
            tabCount: 2,
            paneCount: 2,
            tabIDs: [originTabID, unrelatedTabID]
        )
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let invalidTask = task(
            taskID: uuid(40_197),
            paneID: uuid(40_198),
            tabID: unrelatedTabID.rawValue,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateSplitResult(.task(invalidTask))

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil,
                        direction: .left,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(40_199)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.taskStates[invalidTask.taskID] == nil)
    }

    @Test
    func invalidCreatedResponseIsCompensatedWithoutLocalOwnership() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_200)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let invalidTask = task(
            taskID: uuid(40_201),
            paneID: uuid(40_202),
            tabID: uuid(40_203),
            workspaceID: uuid(40_204),
            state: .running
        )
        host.enqueueCreateTabResult(.task(invalidTask))

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_205)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
        #expect(host.discardCreatedTaskCalls.count == 1)
        #expect(host.taskStates[invalidTask.taskID] == nil)
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_205)
                )
            ),
            context: context()
        )
        #expect(replayed == response)
        #expect(host.discardCreatedTaskCalls.count == 1)
    }

    @Test
    func concurrentFirstRequestsCoalesceIntoOnePrompt() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        let listRequest = try TerminalControlRequest(operation: .list)

        let first = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin,
                    request: listRequest),
                context: context()
            )
        }
        let second = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin,
                    request: listRequest),
                context: context()
            )
        }

        await host.waitForPromptCalls(1)
        #expect(host.promptCallCount == 1)
        host.resumeNextPrompt(.allowed)

        let firstResponse = await first.value
        let secondResponse = await second.value

        expectList(firstResponse, workspaceID: session.workspace.workspaceID.rawValue, taskIDs: [])
        expectList(secondResponse, workspaceID: session.workspace.workspaceID.rawValue, taskIDs: [])
        #expect(host.promptCallCount == 1)
    }

    @Test
    func cancelledPermissionWaiterDoesNotCancelSharedPrompt() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        let listRequest = try TerminalControlRequest(operation: .list)

        let cancelled = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: listRequest
                ),
                context: context()
            )
        }
        let remaining = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: listRequest
                ),
                context: context()
            )
        }

        await host.waitForPromptCalls(1)
        cancelled.cancel()
        let cancelledResponse = await cancelled.value
        expectFailure(cancelledResponse, code: .cancelled)
        #expect(host.promptCallCount == 1)

        host.resumeNextPrompt(.allowed)
        let remainingResponse = await remaining.value
        expectList(
            remainingResponse,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
        #expect(host.promptCallCount == 1)
    }

    @Test
    func deniedPermissionIsRememberedForExactSessionLifetime() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.denied)

        let firstResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(110)
                )
            ),
            context: context()
        )
        let secondResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(111)
                )
            ),
            context: context()
        )

        expectFailure(firstResponse, code: .permissionDenied)
        expectFailure(secondResponse, code: .permissionDenied)
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.isEmpty)
    }

    @Test
    func unavailablePermissionPromptsAgainOnNextRequest() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.unavailable)
        host.enqueuePromptDecision(.allowed)

        let firstResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        let secondResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        expectFailure(firstResponse, code: .permissionUnavailable)
        expectList(
            secondResponse,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
        #expect(host.promptCallCount == 2)
    }

    @Test
    func identicalMutationRetriesReplayStoredResponseAndConflictsReject() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(12),
            paneID: uuid(22),
            tabID: uuid(32),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))

        let requestID = uuid(120)
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: requestID
        )
        let first = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: mutationRequest),
            context: context()
        )
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: mutationRequest),
            context: context()
        )
        let conflicting = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: requestID
                )
            ),
            context: context()
        )

        #expect(first == TerminalControlResponse(result: .task(createdTask)))
        #expect(replayed == first)
        expectFailure(conflicting, code: .requestIDConflict)
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func replaySurvivesMoreThanThirtyTwoLaterMutations() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(22_100),
            paneID: uuid(22_101),
            tabID: uuid(22_102),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(22_103)
                )
            ),
            context: context()
        )

        let requestID = uuid(22_104)
        let originalRequest = try TerminalControlRequest(
            operation: .focus(taskID: ownedTask.taskID),
            requestID: requestID
        )
        let originalResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: originalRequest
            ),
            context: context()
        )

        for index in 0..<33 {
            _ = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .focus(taskID: ownedTask.taskID),
                        requestID: uuid(22_200 + index)
                    )
                ),
                context: context()
            )
        }

        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: originalRequest
            ),
            context: context()
        )
        let conflicting = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .resize(taskID: ownedTask.taskID, ratio: 0.4),
                    requestID: requestID
                )
            ),
            context: context()
        )

        #expect(
            originalResponse
                == TerminalControlResponse(
                    result: .acknowledged(taskID: ownedTask.taskID, revision: 1)
                )
        )
        #expect(replayed == originalResponse)
        expectFailure(conflicting, code: .requestIDConflict)
        #expect(host.taskMutationCallCount == 34)
    }

    @Test(arguments: UserInputSuccessShape.allCases)
    private func requestUserInputPublishesPresentationAndAttentionForEverySuccessShape(
        shape: UserInputSuccessShape
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(22_300 + shape.rawValue),
            paneID: uuid(22_310 + shape.rawValue),
            tabID: uuid(22_320 + shape.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(22_330 + shape.rawValue)
                )
            ),
            context: context()
        )

        let updatedTask = task(
            taskID: ownedTask.taskID,
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: ownedTask.workspaceID,
            state: .waitingForUser,
            revision: 2
        )
        host.enqueueMutationResult(try shape.response(for: updatedTask))
        let expectedResponse = try shape.controlResponse(for: updatedTask)
        let presentationCount = host.presentations.count
        let attentionCount = host.attentions.count

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .requestUserInput(taskID: ownedTask.taskID),
                    requestID: uuid(22_340 + shape.rawValue)
                )
            ),
            context: context()
        )

        #expect(response == expectedResponse)
        #expect(host.presentations.count == presentationCount + 1)
        #expect(host.presentations.last == .taskRequiresPresentation(ownedTask.taskID))
        #expect(host.attentions.count == attentionCount + 1)
        #expect(host.attentions.last == .taskRequiresAttention(ownedTask.taskID))
    }

    @Test
    func concurrentIdenticalMutationUsesOneHostCallAndSameResponse() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(16),
            paneID: uuid(26),
            tabID: uuid(36),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))

        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(240)
        )
        let first = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }
        let second = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        host.resumeCreateTabResponses()

        let firstResponse = await first.value
        let secondResponse = await second.value

        #expect(firstResponse == TerminalControlResponse(result: .task(createdTask)))
        #expect(secondResponse == firstResponse)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func cancelledCoalescedWaiterDoesNotCancelSharedMutation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(16_100),
            paneID: uuid(16_101),
            tabID: uuid(16_102),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(16_103)
        )
        let shared = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        let resolveCount = host.resolveSessionCallCount
        let coalesced = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }
        await host.waitForResolveSessionCalls(resolveCount + 2)
        coalesced.cancel()

        let cancelledResponse = await coalesced.value
        expectFailure(cancelledResponse, code: .cancelled)
        #expect(host.createTabCalls.count == 1)

        host.resumeCreateTabResponses()
        let sharedResponse = await shared.value
        #expect(sharedResponse == TerminalControlResponse(result: .task(createdTask)))

        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        #expect(replayed == sharedResponse)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func concurrentMutationWithSameRequestIDButDifferentDigestConflicts() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(17),
            paneID: uuid(27),
            tabID: uuid(37),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))

        let requestID = uuid(241)
        let firstRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: requestID
        )
        let secondRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: requestID
        )
        let first = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: firstRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        let conflict = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: secondRequest
            ),
            context: context()
        )
        expectFailure(conflict, code: .requestIDConflict)
        host.resumeCreateTabResponses()

        let firstResponse = await first.value
        #expect(firstResponse == TerminalControlResponse(result: .task(createdTask)))
        #expect(host.createTabCalls.count == 1)
    }

    @Test(arguments: TaskMutationKind.allCases)
    private func everyTaskMutationRetainsExactReplay(kind: TaskMutationKind) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(2_500 + kind.rawValue),
            paneID: uuid(2_510 + kind.rawValue),
            tabID: uuid(2_520 + kind.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(2_530 + kind.rawValue)
                )
            ),
            context: context()
        )

        let expected = TerminalControlResponse(
            result: .acknowledged(taskID: ownedTask.taskID, revision: 2)
        )
        host.enqueueMutationResult(.acknowledged(taskID: ownedTask.taskID, revision: 2))
        let mutationRequest = try TerminalControlRequest(
            operation: kind.operation(taskID: ownedTask.taskID),
            requestID: uuid(2_540 + kind.rawValue)
        )
        let first = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )

        #expect(first == expected)
        #expect(replayed == expected)
        #expect(host.taskMutationCallCount == 1)
    }

    @Test(arguments: TaskMutationKind.allCases)
    private func everyTaskMutationRejectsInvalidHostResponseShapes(
        kind: TaskMutationKind
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(2_550 + kind.rawValue),
            paneID: uuid(2_560 + kind.rawValue),
            tabID: uuid(2_570 + kind.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(2_580 + kind.rawValue)
                )
            ),
            context: context()
        )

        host.enqueueMutationResult(
            .acknowledged(taskID: uuid(2_590 + kind.rawValue), revision: 2)
        )
        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: kind.operation(taskID: ownedTask.taskID),
                    requestID: uuid(2_600 + kind.rawValue)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)

        host.enqueueMutationResult(
            .createdTask(
                TerminalAutomationCreatedTaskResponse(
                    task: task(
                        taskID: ownedTask.taskID,
                        paneID: ownedTask.paneID,
                        tabID: ownedTask.tabID,
                        workspaceID: ownedTask.workspaceID,
                        state: ownedTask.state,
                        revision: 2
                    ),
                    splitID: nil
                )
            )
        )
        let createdTaskResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: kind.operation(taskID: ownedTask.taskID),
                    requestID: uuid(2_610 + kind.rawValue)
                )
            ),
            context: context()
        )

        expectFailure(createdTaskResponse, code: .internalFailure)
        #expect(host.taskMutationCallCount == 2)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
    }

    @Test(arguments: TaskMutationKind.allCases)
    private func disconnectedTaskMutationDoesNotApplyLateRevisionOrPublishEffects(
        kind: TaskMutationKind
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(16_200 + kind.rawValue),
            paneID: uuid(16_210 + kind.rawValue),
            tabID: uuid(16_220 + kind.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(16_230 + kind.rawValue)
                )
            ),
            context: context()
        )

        let presentationCount = host.presentations.count
        host.pauseMutationResponses()
        host.enqueueMutationResult(
            .acknowledged(taskID: ownedTask.taskID, revision: 2)
        )
        let mutationRequest = try TerminalControlRequest(
            operation: kind.operation(taskID: ownedTask.taskID),
            requestID: uuid(16_240 + kind.rawValue)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context(lease)
            )
        }

        await host.waitForTaskMutationCalls(1)
        lease.isActive = false
        host.resumeMutationResponses()

        let response = await pending.value
        expectFailure(response, code: .cancelled)
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        expectFailure(replayed, code: .cancelled)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
        #expect(host.presentations.count == presentationCount)
        #expect(host.attentions.isEmpty)
    }

    @Test
    func waitReturnsCancelledWhenSwiftTaskIsCancelled() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let waitingTask = task(
            taskID: uuid(1_500),
            paneID: uuid(1_510),
            tabID: uuid(1_520),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(waitingTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(1_499)
                )
            ),
            context: context()
        )

        let waitRequest = try TerminalControlRequest(
            operation: .wait(
                taskID: waitingTask.taskID,
                revision: waitingTask.revision,
                timeoutMilliseconds: 500
            )
        )
        let responseTask = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: waitRequest
                ),
                context: context()
            )
        }

        await host.waitForInspectTaskCalls(1)
        responseTask.cancel()

        let response = await responseTask.value
        expectFailure(response, code: .cancelled)
    }

    @Test
    func cancelledMutationRetainsExactResponseAndRejectsReplayWithDifferentDigest() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)

        let requestID = uuid(1_502)
        let firstRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: requestID
        )
        let firstResponseTask = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: firstRequest
                ),
                context: context(lease)
            )
        }

        await host.waitForPromptCalls(1)
        lease.isActive = false
        host.resumeNextPrompt(.allowed)

        let firstResponse = await firstResponseTask.value
        expectFailure(firstResponse, code: .cancelled)

        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: firstRequest
            ),
            context: context()
        )

        #expect(replayed == firstResponse)
        #expect(host.createTabCalls.isEmpty)

        let replayConflict = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: requestID
                )
            ),
            context: context()
        )

        expectFailure(replayConflict, code: .requestIDConflict)
        #expect(host.createTabCalls.isEmpty)
    }

    @Test
    func disconnectAfterCreateStartsRegistersAndRetainsValidatedResult() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(2_400),
            paneID: uuid(2_401),
            tabID: uuid(2_402),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(2_403)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context(lease)
            )
        }

        await host.waitForCreateTabCalls(1)
        lease.isActive = false
        host.resumeCreateTabResponses()

        let response = await pending.value
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )

        expectFailure(response, code: .cancelled)
        #expect(replayed == TerminalControlResponse(result: .task(createdTask)))
        #expect(host.createTabCalls.count == 1)
        #expect(host.discardCreatedTaskCalls.isEmpty)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [createdTask.taskID]
        )
    }

    @Test
    func mutationFailureIsRetainedAsExactResponse() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.enqueueCreateTabResult(.failure(.surfaceCreationFailed))

        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(2_410)
        )
        let first = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )

        expectFailure(first, code: .surfaceCreationFailed)
        #expect(replayed == first)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func inactiveMutationRetriesReplayRetainedSuccessAndFailure() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(12_100),
            paneID: uuid(12_101),
            tabID: uuid(12_102),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let successRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(12_103)
        )
        let retainedSuccess = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: successRequest
            ),
            context: context()
        )

        host.enqueueCreateTabResult(.failure(.surfaceCreationFailed))
        let failureRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(12_104)
        )
        let retainedFailure = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: failureRequest
            ),
            context: context()
        )

        let inactiveLease = Lease()
        inactiveLease.isActive = false
        let replayedSuccess = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: successRequest
            ),
            context: context(inactiveLease)
        )
        let replayedFailure = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: failureRequest
            ),
            context: context(inactiveLease)
        )

        #expect(retainedSuccess == TerminalControlResponse(result: .task(createdTask)))
        expectFailure(retainedFailure, code: .surfaceCreationFailed)
        #expect(replayedSuccess == retainedSuccess)
        #expect(replayedFailure == retainedFailure)
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.count == 2)
    }

    @Test
    func retainedPermissionUnavailableReplaysWithoutPromptingAgain() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.unavailable)
        host.enqueuePromptDecision(.allowed)

        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(12_110)
        )
        let retained = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )

        expectFailure(retained, code: .permissionUnavailable)
        #expect(replayed == retained)
        #expect(host.promptCallCount == 1)
        #expect(host.createTabCalls.isEmpty)
    }

    @Test
    func createReplaySurvivesRelatedTaskRemoval() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(2_420),
            paneID: uuid(2_421),
            tabID: uuid(2_422),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .succeeded
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(2_423)
        )
        let first = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        host.taskStates.removeValue(forKey: createdTask.taskID)
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        let replayed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )

        #expect(replayed == first)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func completedReplayIsUnavailableAfterSessionRevocation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(2_430),
            paneID: uuid(2_431),
            tabID: uuid(2_432),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(2_433)
        )
        let first = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        #expect(first == TerminalControlResponse(result: .task(createdTask)))

        let replacement = resolvedSession(originPaneID: origin, sessionID: "replacement")
        host.setResolvedSession(replacement)
        host.enqueuePromptDecision(.allowed)
        _ = await coordinator.handle(
            request(
                instanceID: replacement.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        host.setResolvedSession(initial)
        let inactiveLease = Lease()
        inactiveLease.isActive = false
        let replayAttempt = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context(inactiveLease)
        )

        expectFailure(replayAttempt, code: .permissionRevoked)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func inFlightMutationCannotRestoreRevokedReplayOrTaskRecord() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(2_440),
            paneID: uuid(2_441),
            tabID: uuid(2_442),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(2_443)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }

        await host.waitForCreateTabCalls(1)
        let replacement = resolvedSession(originPaneID: origin, sessionID: "replacement")
        host.setResolvedSession(replacement)
        host.enqueuePromptDecision(.allowed)
        _ = await coordinator.handle(
            request(
                instanceID: replacement.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        host.setResolvedSession(initial)
        host.resumeCreateTabResponses()
        let lateResponse = await pending.value
        expectFailure(lateResponse, code: .permissionRevoked)

        let retry = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: mutationRequest
            ),
            context: context()
        )
        expectFailure(retry, code: .permissionRevoked)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func revokedPausedMutationReleasesWaiterAndHeavyBookkeeping() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        let createdTask = task(
            taskID: uuid(24_000),
            paneID: uuid(24_001),
            tabID: uuid(24_002),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(24_003)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }
        await host.waitForCreateTabCalls(1)
        #expect(coordinator.pendingMutationCountForTesting(initial.identity) == 1)
        #expect(coordinator.pendingCreateReservationCountForTesting(initial.identity) == 1)

        let replacement = resolvedSession(originPaneID: origin, sessionID: "session-2")
        host.setResolvedSession(replacement)
        host.enqueuePromptDecision(.allowed)
        let replacementResponse = await coordinator.handle(
            request(
                instanceID: replacement.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            replacementResponse,
            workspaceID: replacement.workspace.workspaceID.rawValue,
            taskIDs: []
        )

        let revokedResponse = await pending.value
        expectFailure(revokedResponse, code: .permissionRevoked)
        await host.waitForCreateTabCancellations(1)
        #expect(host.createTabCancellationCount == 1)
        #expect(coordinator.pendingMutationCountForTesting(initial.identity) == 0)
        #expect(coordinator.pendingCreateReservationCountForTesting(initial.identity) == 0)

        for index in 3...35 {
            let rotated = resolvedSession(
                originPaneID: origin,
                sessionID: "session-\(index)"
            )
            host.setResolvedSession(rotated)
            host.enqueuePromptDecision(.allowed)
            let response = await coordinator.handle(
                request(
                    instanceID: rotated.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            expectList(
                response,
                workspaceID: rotated.workspace.workspaceID.rawValue,
                taskIDs: []
            )
        }

        #expect(!coordinator.retainsSessionRecordForTesting(initial.identity))
    }

    @Test(arguments: [
        StaleRevalidationTransition.replacement,
        StaleRevalidationTransition.unregistered,
    ])
    private func staleInFlightSessionRevokesNewerTrackedSessionBeforeRebinding(
        transition: StaleRevalidationTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(12_200),
            paneID: uuid(12_201),
            tabID: uuid(12_202),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(12_203)
                )
            ),
            context: context()
        )

        host.pauseReadResponses()
        host.enqueueReadResult(
            .task(
                task(
                    taskID: initialTask.taskID,
                    paneID: initialTask.paneID,
                    tabID: initialTask.tabID,
                    workspaceID: initialTask.workspaceID,
                    state: .running,
                    revision: 2
                )
            )
        )
        let readRequest = try TerminalControlRequest(
            operation: .read(taskID: initialTask.taskID)
        )
        let suspendedInitialRead = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: readRequest
                ),
                context: context()
            )
        }
        await host.waitForReadCalls(1)

        let newer = resolvedSession(originPaneID: origin, sessionID: "session-b")
        host.setResolvedSession(newer)
        host.enqueuePromptDecision(.allowed)
        let newerTask = task(
            taskID: uuid(12_210),
            paneID: uuid(12_211),
            tabID: uuid(12_212),
            workspaceID: newer.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(newerTask))
        let newerRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(12_213)
        )
        let newerResponse = await coordinator.handle(
            request(
                instanceID: newer.identity.instanceID,
                originPaneID: origin,
                request: newerRequest
            ),
            context: context()
        )
        #expect(newerResponse == TerminalControlResponse(result: .task(newerTask)))

        switch transition {
        case .replacement:
            host.setResolvedSession(
                resolvedSession(originPaneID: origin, sessionID: "session-c")
            )
        case .unregistered:
            host.clearResolvedSession(
                instanceID: initial.identity.instanceID,
                originPaneID: origin
            )
        }
        host.resumeReadResponses()
        let staleResponse = await suspendedInitialRead.value
        expectFailure(staleResponse, code: .staleSession)

        host.setResolvedSession(newer)
        let revokedRetry = await coordinator.handle(
            request(
                instanceID: newer.identity.instanceID,
                originPaneID: origin,
                request: newerRequest
            ),
            context: context()
        )
        expectFailure(revokedRetry, code: .permissionRevoked)
        #expect(host.promptCallCount == 2)
        #expect(host.createTabCalls.count == 2)

        let fresh = resolvedSession(originPaneID: origin, sessionID: "session-d")
        host.setResolvedSession(fresh)
        host.enqueuePromptDecision(.allowed)
        host.enqueueCreateTabResult(.task(newerTask))
        let reusedOwnership = await coordinator.handle(
            request(
                instanceID: fresh.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(12_214)
                )
            ),
            context: context()
        )

        #expect(reusedOwnership == TerminalControlResponse(result: .task(newerTask)))
        #expect(host.promptCallCount == 3)
        #expect(host.createTabCalls.count == 3)
    }

    @Test
    func sameSessionPaneReuseAcrossDifferentTasksIsRejected() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let firstTask = task(
            taskID: uuid(1_506),
            paneID: uuid(1_516),
            tabID: uuid(1_526),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(firstTask))
        let firstResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(1_507)
                )
            ),
            context: context()
        )
        #expect(firstResponse == TerminalControlResponse(result: .task(firstTask)))

        host.enqueueCreateTabResult(
            .task(
                task(
                    taskID: uuid(1_508),
                    paneID: firstTask.paneID,
                    tabID: firstTask.tabID,
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .running
                )
            )
        )
        let conflict = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(1_509)
                )
            ),
            context: context()
        )

        expectFailure(conflict, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [firstTask.taskID]
        )
    }

    @Test
    func createAndSplitSnapshotsAreRejectedWithoutRegisteringTasks() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let firstTask = task(
            taskID: uuid(1_510),
            paneID: uuid(1_520),
            tabID: uuid(1_530),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        let firstSnapshot = try TerminalControlSnapshot(
            task: firstTask,
            text: "",
            isTruncated: false
        )
        host.enqueueCreateTabResult(.snapshot(firstSnapshot))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(1_511)
        )
        let createResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: createRequest
            ),
            context: context()
        )
        let replayedCreate = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: createRequest
            ),
            context: context()
        )

        expectFailure(createResponse, code: .internalFailure)
        #expect(replayedCreate == createResponse)
        #expect(host.createTabCalls.count == 1)
        let listedAfterCreate = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listedAfterCreate,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )

        let splitTask = task(
            taskID: uuid(1_512),
            paneID: uuid(1_522),
            tabID: firstTask.tabID,
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .waitingForUser
        )
        let splitSnapshot = try TerminalControlSnapshot(
            task: splitTask,
            text: "",
            isTruncated: false
        )
        host.enqueueCreateSplitResult(.snapshot(splitSnapshot))
        let splitRequest = try TerminalControlRequest(
            operation: .split(
                anchorPaneID: nil,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: false
            ),
            requestID: uuid(1_513)
        )
        let splitResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: splitRequest
            ),
            context: context()
        )
        let replayedSplit = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: splitRequest
            ),
            context: context()
        )

        expectFailure(splitResponse, code: .internalFailure)
        #expect(replayedSplit == splitResponse)
        #expect(host.createSplitCalls.count == 1)
        let listedAfterSplit = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listedAfterSplit,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test
    func createAcknowledgementIsRejectedWithoutStateMutation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.enqueueCreateTabResult(.acknowledged(taskID: uuid(2_450), revision: 1))

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(2_451)
                )
            ),
            context: context()
        )
        expectFailure(response, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test
    func concurrentCreatesStayWithinEightWhileResponsesAreSuspended() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        host.pauseCreateTabResponses()

        for index in 0..<8 {
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: uuid(250 + index),
                        paneID: uuid(350 + index),
                        tabID: uuid(450 + index),
                        workspaceID: session.workspace.workspaceID.rawValue,
                        state: .running
                    )
                )
            )
        }

        let requests = try (0..<8).map { index in
            try TerminalControlRequest(
                operation: .createTab(
                    launch: try launch(),
                    policy: .keep,
                    focus: index.isMultiple(of: 2)
                ),
                requestID: uuid(550 + index)
            )
        }
        let tasks = requests.map { controlRequest in
            Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: controlRequest
                    ),
                    context: context()
                )
            }
        }

        await host.waitForCreateTabCalls(8)
        let ninth = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(558)
                )
            ),
            context: context()
        )
        expectFailure(ninth, code: .resourceLimit)
        host.resumeCreateTabResponses()

        var returnedTaskIDs: [UUID] = []
        for responseTask in tasks {
            let response = await responseTask.value
            if let returnedTaskID = taskID(in: response) {
                returnedTaskIDs.append(returnedTaskID)
            }
        }
        #expect(returnedTaskIDs.count == 8)
        #expect(Set(returnedTaskIDs).count == 8)
        #expect(Set(returnedTaskIDs) == Set((0..<8).map { uuid(250 + $0) }))
        #expect(host.createTabCalls.count == 8)
    }

    @Test
    func creatingAndWaitingForUserTasksCountAgainstActiveLimit() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        host.enqueueCreateTabResult(
            .task(
                task(
                    taskID: uuid(600),
                    paneID: uuid(700),
                    tabID: uuid(800),
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .creating
                )
            )
        )
        host.enqueueCreateTabResult(
            .task(
                task(
                    taskID: uuid(601),
                    paneID: uuid(701),
                    tabID: uuid(801),
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .waitingForUser
                )
            )
        )
        for index in 0..<6 {
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: uuid(610 + index),
                        paneID: uuid(710 + index),
                        tabID: uuid(810 + index),
                        workspaceID: session.workspace.workspaceID.rawValue,
                        state: .running
                    )
                )
            )
        }

        for index in 0..<8 {
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(),
                            policy: .keep,
                            focus: index.isMultiple(of: 2)
                        ),
                        requestID: uuid(900 + index)
                    )
                ),
                context: context()
            )
            #expect(taskID(in: response) != nil)
        }

        let limited = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(910)
                )
            ),
            context: context()
        )
        expectFailure(limited, code: .resourceLimit)
        #expect(host.createTabCalls.count == 8)
    }

    @Test
    func waitReturnsAfterRevisionChanges() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(920),
            paneID: uuid(930),
            tabID: uuid(940),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9200)
                )
            ),
            context: context()
        )

        let waitRequest = try TerminalControlRequest(
            operation: .wait(
                taskID: initialTask.taskID, revision: 1, timeoutMilliseconds: 500)
        )
        let waiter = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: waitRequest
                ),
                context: context()
            )
        }

        await host.waitForInspectTaskCalls(1)
        let updatedTask = task(
            taskID: initialTask.taskID,
            paneID: initialTask.paneID,
            tabID: initialTask.tabID,
            workspaceID: initialTask.workspaceID,
            state: .running,
            revision: 2
        )
        host.taskStates[initialTask.taskID] = updatedTask

        let response = await waiter.value
        #expect(response == TerminalControlResponse(result: .task(updatedTask)))
    }

    @Test
    func waitTimeoutIsBounded() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(9300),
            paneID: uuid(9310),
            tabID: uuid(9320),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(9_299)
                )
            ),
            context: context()
        )

        let clock = ContinuousClock()
        let start = clock.now
        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .wait(
                        taskID: initialTask.taskID, revision: 1, timeoutMilliseconds: 100)
                )
            ),
            context: context()
        )
        let elapsed = start.duration(to: clock.now)

        expectFailure(response, code: .timeout)
        #expect(elapsed >= .milliseconds(80))
        #expect(elapsed <= .seconds(5))
    }

    @Test
    func secondPendingWaitIsRejected() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(9400),
            paneID: uuid(9410),
            tabID: uuid(9420),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(9_399)
                )
            ),
            context: context()
        )

        let firstWaitRequest = try TerminalControlRequest(
            operation: .wait(
                taskID: initialTask.taskID, revision: 1, timeoutMilliseconds: 500)
        )
        let first = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: firstWaitRequest
                ),
                context: context()
            )
        }

        await host.waitForInspectTaskCalls(1)
        let second = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .wait(
                        taskID: initialTask.taskID, revision: 1, timeoutMilliseconds: 500)
                )
            ),
            context: context()
        )
        expectFailure(second, code: .resourceLimit)

        let updatedTask = task(
            taskID: initialTask.taskID,
            paneID: initialTask.paneID,
            tabID: initialTask.tabID,
            workspaceID: initialTask.workspaceID,
            state: .running,
            revision: 2
        )
        host.taskStates[initialTask.taskID] = updatedTask
        let firstResponse = await first.value
        #expect(firstResponse == TerminalControlResponse(result: .task(updatedTask)))
    }

    @Test(arguments: [
        WaitTransition.cancelled,
        WaitTransition.sessionReplaced,
        WaitTransition.workspaceMoved,
    ])
    private func waitCancelsOrBecomesStaleWhenContextOrSessionChanges(
        transition: WaitTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(9500),
            paneID: uuid(9510),
            tabID: uuid(9520),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(9_499)
                )
            ),
            context: context()
        )

        let waitRequest = try TerminalControlRequest(
            operation: .wait(
                taskID: initialTask.taskID, revision: 1, timeoutMilliseconds: 500)
        )
        let responseTask = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: waitRequest
                ),
                context: context(lease)
            )
        }

        await host.waitForInspectTaskCalls(1)
        switch transition {
        case .cancelled:
            lease.isActive = false
        case .sessionReplaced:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    sessionID: "session-2"
                )
            )
        case .workspaceMoved:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    workspaceID: WorkspaceID(rawValue: uuid(9_590))
                )
            )
        }

        let response = await responseTask.value
        switch transition {
        case .cancelled:
            expectFailure(response, code: .cancelled)
        case .sessionReplaced, .workspaceMoved:
            expectFailure(response, code: .staleSession)
        }
    }

    @Test
    func createResponseDoesNotOverwriteAnotherSessionsOwnership() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let firstOrigin = paneID(1)
        let secondOrigin = paneID(2)
        let firstSession = resolvedSession(originPaneID: firstOrigin)
        let secondSession = resolvedSession(originPaneID: secondOrigin, sessionID: "session-2")
        host.setResolvedSession(firstSession)
        host.setResolvedSession(secondSession)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9600),
            paneID: uuid(9610),
            tabID: uuid(9620),
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: firstSession.identity.instanceID,
                originPaneID: firstOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9601)
                )
            ),
            context: context()
        )

        host.enqueuePromptDecision(.allowed)
        let conflictingTask = task(
            taskID: uuid(9602),
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(conflictingTask))
        let conflict = await coordinator.handle(
            request(
                instanceID: secondSession.identity.instanceID,
                originPaneID: secondOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(9603)
                )
            ),
            context: context()
        )

        expectFailure(conflict, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: firstSession.identity.instanceID,
                originPaneID: firstOrigin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            taskIDs: [ownedTask.taskID]
        )
    }

    @Test
    func readResponseDoesNotOverwriteTaskIdentityOrWorkspace() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9630),
            paneID: uuid(9640),
            tabID: uuid(9650),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9631)
                )
            ),
            context: context()
        )

        host.enqueueReadResult(
            .task(
                task(
                    taskID: uuid(9660),
                    paneID: ownedTask.paneID,
                    tabID: ownedTask.tabID,
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .running
                )
            )
        )
        let firstResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .read(taskID: ownedTask.taskID)
                )
            ),
            context: context()
        )

        host.enqueueReadResult(
            .snapshot(
                try TerminalControlSnapshot(
                    task: task(
                        taskID: ownedTask.taskID,
                        paneID: ownedTask.paneID,
                        tabID: ownedTask.tabID,
                        workspaceID: uuid(9699),
                        state: .running
                    ),
                    text: "",
                    isTruncated: false
                )
            )
        )
        let secondResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .read(taskID: ownedTask.taskID)
                )
            ),
            context: context()
        )

        expectFailure(firstResponse, code: .internalFailure)
        expectFailure(secondResponse, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: [ownedTask.taskID]
        )
    }

    @Test
    func readRejectsWrongTaskAndAcknowledgementWithoutMutation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9_660),
            paneID: uuid(9_661),
            tabID: uuid(9_662),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9_663)
                )
            ),
            context: context()
        )

        host.enqueueReadResult(
            .task(
                task(
                    taskID: uuid(9_664),
                    paneID: ownedTask.paneID,
                    tabID: ownedTask.tabID,
                    workspaceID: ownedTask.workspaceID,
                    state: .running,
                    revision: 2
                )
            )
        )
        let wrongTask = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: ownedTask.taskID))
            ),
            context: context()
        )
        expectFailure(wrongTask, code: .internalFailure)

        host.enqueueReadResult(.acknowledged(taskID: ownedTask.taskID, revision: 2))
        let acknowledgement = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: ownedTask.taskID))
            ),
            context: context()
        )
        expectFailure(acknowledgement, code: .internalFailure)

        host.enqueueReadResult(
            .createdTask(
                TerminalAutomationCreatedTaskResponse(task: ownedTask, splitID: nil)
            )
        )
        let createdTaskResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: ownedTask.taskID))
            ),
            context: context()
        )
        expectFailure(createdTaskResponse, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
    }

    @Test
    func lateReadCannotRegressRevisionAdvancedByMutation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9_670),
            paneID: uuid(9_671),
            tabID: uuid(9_672),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9_673)
                )
            ),
            context: context()
        )

        host.pauseReadResponses()
        host.enqueueReadResult(
            .task(
                task(
                    taskID: ownedTask.taskID,
                    paneID: ownedTask.paneID,
                    tabID: ownedTask.tabID,
                    workspaceID: ownedTask.workspaceID,
                    state: .running,
                    revision: 2
                )
            )
        )
        let readRequest = try TerminalControlRequest(
            operation: .read(taskID: ownedTask.taskID)
        )
        let pendingRead = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: readRequest
                ),
                context: context()
            )
        }
        await host.waitForReadCalls(1)

        host.enqueueMutationResult(
            .acknowledged(taskID: ownedTask.taskID, revision: 3)
        )
        let mutation = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: ownedTask.taskID),
                    requestID: uuid(9_674)
                )
            ),
            context: context()
        )
        #expect(
            mutation
                == TerminalControlResponse(
                    result: .acknowledged(taskID: ownedTask.taskID, revision: 3)
                )
        )

        host.resumeReadResponses()
        let lateRead = await pendingRead.value
        expectFailure(lateRead, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 3)
    }

    @Test
    func lateTaskMutationCannotRegressNewerRevision() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9_680),
            paneID: uuid(9_681),
            tabID: uuid(9_682),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9_683)
                )
            ),
            context: context()
        )

        host.pauseMutationResponses()
        host.enqueueMutationResult(.acknowledged(taskID: ownedTask.taskID, revision: 2))
        host.enqueueMutationResult(.acknowledged(taskID: ownedTask.taskID, revision: 3))
        let olderRequest = try TerminalControlRequest(
            operation: .focus(taskID: ownedTask.taskID),
            requestID: uuid(9_684)
        )
        let older = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: olderRequest
                ),
                context: context()
            )
        }
        await host.waitForTaskMutationCalls(1)
        let newerRequest = try TerminalControlRequest(
            operation: .resize(taskID: ownedTask.taskID, ratio: 0.5),
            requestID: uuid(9_685)
        )
        let newer = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: newerRequest
                ),
                context: context()
            )
        }
        await host.waitForTaskMutationCalls(2)

        host.resumeLastMutationResponse()
        let newerResponse = await newer.value
        #expect(
            newerResponse
                == TerminalControlResponse(
                    result: .acknowledged(taskID: ownedTask.taskID, revision: 3)
                )
        )
        host.resumeMutationResponses()
        let olderResponse = await older.value
        expectFailure(olderResponse, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 3)
    }

    @Test
    func optimisticMutationAcceptsAlreadyObservedExactHostRevision() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9_690),
            paneID: uuid(9_691),
            tabID: uuid(9_692),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9_693)
                )
            ),
            context: context()
        )

        host.pauseMutationResponses()
        host.enqueueMutationResult(.acknowledged(taskID: ownedTask.taskID, revision: 2))
        let mutationRequest = try TerminalControlRequest(
            operation: .sendText(
                taskID: ownedTask.taskID,
                expectedRevision: 1,
                text: "input"
            ),
            requestID: uuid(9_694)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }
        await host.waitForTaskMutationCalls(1)

        let observedTask = task(
            taskID: ownedTask.taskID,
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: ownedTask.workspaceID,
            state: .running,
            revision: 2
        )
        host.taskStates[ownedTask.taskID] = observedTask
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        host.resumeMutationResponses()
        let response = await pending.value
        #expect(
            response
                == TerminalControlResponse(
                    result: .acknowledged(taskID: ownedTask.taskID, revision: 2)
                )
        )
    }

    @Test(arguments: [
        ReadTransition.rotatedCredentials,
        ReadTransition.workspaceMoved,
        ReadTransition.unregistered,
    ])
    private func readBecomesStaleWhenSessionChangesDuringRead(
        transition: ReadTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9670),
            paneID: uuid(9680),
            tabID: uuid(9690),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9671)
                )
            ),
            context: context()
        )
        let initialWithTask = try #require(
            host.currentResolvedSession(
                instanceID: initial.identity.instanceID, originPaneID: origin)
        )

        host.pauseReadResponses()
        host.enqueueReadResult(
            .task(
                task(
                    taskID: ownedTask.taskID,
                    paneID: ownedTask.paneID,
                    tabID: ownedTask.tabID,
                    workspaceID: initial.workspace.workspaceID.rawValue,
                    state: .running,
                    revision: 2
                )
            )
        )
        let readRequest = try TerminalControlRequest(
            operation: .read(taskID: ownedTask.taskID)
        )
        let pendingRead = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: readRequest
                ),
                context: context()
            )
        }

        await host.waitForReadCalls(1)
        switch transition {
        case .rotatedCredentials:
            let rotated = resolvedSession(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                paneCredentialGeneration: 2
            )
            host.setResolvedSession(
                TerminalAutomationResolvedSession(
                    identity: rotated.identity, workspace: initialWithTask.workspace)
            )
        case .workspaceMoved:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    workspaceID: WorkspaceID(rawValue: uuid(9790))
                )
            )
        case .unregistered:
            host.clearResolvedSession(instanceID: initial.identity.instanceID, originPaneID: origin)
        }
        host.resumeReadResponses()

        let response = await pendingRead.value
        expectFailure(response, code: .staleSession)

        switch transition {
        case .workspaceMoved:
            host.setResolvedSession(initialWithTask)
            let listed = await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
        case .rotatedCredentials, .unregistered:
            // WHY: Restoring an exact retired identity must not revive its grant or late read.
            host.setResolvedSession(initialWithTask)
            let retry = await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(9794)
                    )
                ),
                context: context()
            )
            expectFailure(retry, code: .permissionRevoked)
            #expect(host.promptCallCount == 1)
            #expect(host.createTabCalls.count == 1)

            host.closeCreatedTask(ownedTask.taskID)
            let fresh = resolvedSession(
                originPaneID: origin,
                sessionID: "fresh",
                paneCredentialGeneration: 3
            )
            host.setResolvedSession(fresh)
            host.enqueuePromptDecision(.allowed)
            let listed = await coordinator.handle(
                request(
                    instanceID: fresh.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            expectList(listed, workspaceID: ownedTask.workspaceID, taskIDs: [])

            // WHY: Reusing every identity exposes ownership resurrected by the late revision.
            host.enqueueCreateTabResult(.task(ownedTask))
            let recreated = await coordinator.handle(
                request(
                    instanceID: fresh.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(9795)
                    )
                ),
                context: context()
            )
            #expect(recreated == TerminalControlResponse(result: .task(ownedTask)))
            #expect(host.discardCreatedTaskCalls.isEmpty)
        }
    }

    @Test
    func taskMutationRevalidatesWorkspaceAfterSuspendedHostCall() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9_795),
            paneID: uuid(9_796),
            tabID: uuid(9_797),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(9_798)
                )
            ),
            context: context()
        )

        let foreignTask = task(
            taskID: uuid(9_799),
            paneID: uuid(9_800),
            tabID: uuid(9_801),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.pauseMutationResponses()
        host.enqueueMutationResult(.task(foreignTask))
        let mutationRequest = try TerminalControlRequest(
            operation: .focus(taskID: ownedTask.taskID),
            requestID: uuid(9_802)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: mutationRequest
                ),
                context: context()
            )
        }

        await host.waitForTaskMutationCalls(1)
        host.setResolvedSession(
            resolvedSession(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                workspaceID: WorkspaceID(rawValue: uuid(9_803))
            )
        )
        host.resumeMutationResponses()

        let response = await pending.value
        expectFailure(response, code: .staleSession)

        host.setResolvedSession(initial)
        let foreignAccess = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: foreignTask.taskID),
                    requestID: uuid(9_804)
                )
            ),
            context: context()
        )
        expectFailure(foreignAccess, code: .targetNotOwned)
        #expect(host.focusCalls == [ownedTask.taskID])
    }

    @Test
    func invalidOriginFailsWithoutPrompt() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let response = await coordinator.handle(
            request(
                instanceID: uuid(200),
                originPaneID: paneID(2),
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(201)
                )
            ),
            context: context()
        )

        expectFailure(response, code: .invalidSession)
        #expect(host.promptCallCount == 0)
        #expect(host.createTabCalls.isEmpty)
    }

    @Test
    func revokedPromptContinuationDoesNotConsumeReplacementPromptDecision() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)

        let initialControlRequest = try TerminalControlRequest(operation: .list)
        let initialRequest = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: initialControlRequest
                ),
                context: context()
            )
        }
        await host.waitForPromptCalls(1)

        let replacement = resolvedSession(originPaneID: origin, sessionID: "replacement")
        host.setResolvedSession(replacement)
        let replacementControlRequest = try TerminalControlRequest(operation: .list)
        let replacementRequest = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: replacement.identity.instanceID,
                    originPaneID: origin,
                    request: replacementControlRequest
                ),
                context: context()
            )
        }

        await host.waitForPromptCalls(2)
        await host.waitForPromptCancellations(1)
        host.resumeNextPrompt(.allowed)

        expectFailure(await initialRequest.value, code: .staleSession)
        expectList(
            await replacementRequest.value,
            workspaceID: replacement.workspace.workspaceID.rawValue,
            taskIDs: []
        )
        #expect(host.promptCallCount == 2)
    }

    @Test(arguments: [
        SessionTransition.replacedSession,
        SessionTransition.replacedAdapter,
        SessionTransition.rotatedCredentials,
        SessionTransition.unregistered,
    ])
    private func replacedRotatedAndUnregisteredSessionsInvalidatePendingPrompt(
        transition: SessionTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)

        let pendingRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(210)
        )
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: pendingRequest
                ),
                context: context()
            )
        }

        await host.waitForPromptCalls(1)
        switch transition {
        case .replacedSession:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    sessionID: "session-2"
                )
            )
        case .replacedAdapter:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    adapterID: "codex"
                )
            )
        case .rotatedCredentials:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    paneCredentialGeneration: 2
                )
            )
        case .unregistered:
            host.clearResolvedSession(instanceID: initial.identity.instanceID, originPaneID: origin)
        }
        host.resumeNextPrompt(.allowed)

        let staleResponse = await pending.value
        expectFailure(staleResponse, code: .staleSession)
        #expect(host.createTabCalls.isEmpty)

        switch transition {
        case .unregistered:
            let invalidResponse = await coordinator.handle(
                request(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                        requestID: uuid(211)
                    )
                ),
                context: context()
            )
            expectFailure(invalidResponse, code: .invalidSession)
            #expect(host.promptCallCount == 1)
        case .replacedSession, .replacedAdapter, .rotatedCredentials:
            let current = try #require(
                host.currentResolvedSession(
                    instanceID: initial.identity.instanceID, originPaneID: origin))
            let createdTask = task(
                taskID: uuid(13),
                paneID: uuid(23),
                tabID: uuid(33),
                workspaceID: current.workspace.workspaceID.rawValue,
                state: .running
            )
            host.enqueuePromptDecision(.allowed)
            host.enqueueCreateTabResult(.task(createdTask))

            let freshResponse = await coordinator.handle(
                request(
                    instanceID: current.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(212)
                    )
                ),
                context: context()
            )

            #expect(freshResponse == TerminalControlResponse(result: .task(createdTask)))
            #expect(host.promptCallCount == 2)
            #expect(host.createTabCalls.count == 1)
        }
    }

    @Test(arguments: [
        SessionTransition.replacedSession,
        SessionTransition.replacedAdapter,
        SessionTransition.rotatedCredentials,
        SessionTransition.unregistered,
    ])
    private func revocationClearsTaskTabPaneAndSplitOwnership(
        transition: SessionTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let tabTask = task(
            taskID: uuid(2_600),
            paneID: uuid(2_601),
            tabID: uuid(2_602),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(tabTask))
        let tabResponse = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(2_603)
                )
            ),
            context: context()
        )

        let splitTask = task(
            taskID: uuid(2_604),
            paneID: uuid(2_605),
            tabID: tabTask.tabID,
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        #expect(tabResponse == TerminalControlResponse(result: .task(tabTask)))
        let splitID = uuid(2_612)
        host.enqueueCreateSplitResult(
            .createdTask(TerminalAutomationCreatedTaskResponse(task: splitTask, splitID: splitID))
        )
        let splitResponse = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: tabTask.paneID,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(2_606)
                )
            ),
            context: context()
        )
        #expect(splitResponse == TerminalControlResponse(result: .task(splitTask)))
        #expect(coordinator.ownedSplitIDsForTesting(initial.identity) == Set([splitID]))

        // WHY: Identity replacement alone does not close host surfaces or free their IDs.
        host.closeCreatedTask(splitTask.taskID)
        let afterSplitClose = try #require(
            host.currentResolvedSession(
                instanceID: initial.identity.instanceID, originPaneID: origin)
        )
        #expect(afterSplitClose.workspace.tabIDs.contains(TabID(rawValue: tabTask.tabID)))
        #expect(afterSplitClose.workspace.paneIDs.contains(PaneID(rawValue: tabTask.paneID)))
        #expect(!afterSplitClose.workspace.paneIDs.contains(PaneID(rawValue: splitTask.paneID)))
        host.closeCreatedTask(tabTask.taskID)
        #expect(host.taskStates.isEmpty)
        #expect(
            host.currentResolvedSession(
                instanceID: initial.identity.instanceID, originPaneID: origin)?.workspace
                == initial.workspace
        )

        switch transition {
        case .replacedSession:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    sessionID: "replacement"
                )
            )
            host.enqueuePromptDecision(.allowed)
        case .replacedAdapter:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    adapterID: "codex"
                )
            )
            host.enqueuePromptDecision(.allowed)
        case .rotatedCredentials:
            host.setResolvedSession(
                resolvedSession(
                    instanceID: initial.identity.instanceID,
                    originPaneID: origin,
                    paneCredentialGeneration: 2
                )
            )
            host.enqueuePromptDecision(.allowed)
        case .unregistered:
            host.clearResolvedSession(instanceID: initial.identity.instanceID, originPaneID: origin)
        }
        _ = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        host.setResolvedSession(initial)
        let revoked = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectFailure(revoked, code: .permissionRevoked)
        #expect(coordinator.ownedSplitIDsForTesting(initial.identity).isEmpty)

        let fresh = resolvedSession(
            instanceID: initial.identity.instanceID,
            originPaneID: origin,
            sessionID: "fresh",
            paneCredentialGeneration: 3
        )
        host.setResolvedSession(fresh)
        host.enqueuePromptDecision(.allowed)

        let staleTaskAccess = await coordinator.handle(
            request(
                instanceID: fresh.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: tabTask.taskID),
                    requestID: uuid(2_607)
                )
            ),
            context: context()
        )
        expectFailure(staleTaskAccess, code: .targetNotOwned)

        let reusedTabPane = task(
            taskID: tabTask.taskID,
            paneID: tabTask.paneID,
            tabID: tabTask.tabID,
            workspaceID: fresh.workspace.workspaceID.rawValue,
            state: .running
        )
        let reusedSplitPane = task(
            taskID: splitTask.taskID,
            paneID: splitTask.paneID,
            tabID: tabTask.tabID,
            workspaceID: fresh.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(reusedTabPane))
        host.enqueueCreateSplitResult(
            .createdTask(
                TerminalAutomationCreatedTaskResponse(task: reusedSplitPane, splitID: splitID)
            )
        )
        let firstReuse = await coordinator.handle(
            request(
                instanceID: fresh.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(2_610)
                )
            ),
            context: context()
        )
        let secondReuse = await coordinator.handle(
            request(
                instanceID: fresh.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: reusedTabPane.paneID,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(2_611)
                )
            ),
            context: context()
        )

        #expect(firstReuse == TerminalControlResponse(result: .task(reusedTabPane)))
        #expect(secondReuse == TerminalControlResponse(result: .task(reusedSplitPane)))
        #expect(coordinator.ownedSplitIDsForTesting(fresh.identity) == Set([splitID]))
        #expect(coordinator.ownedSplitIDsForTesting(initial.identity).isEmpty)
        #expect(host.discardCreatedTaskCalls.isEmpty)
    }

    @Test
    func crossSessionTaskIDsFailClosedAsNotOwned() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let firstOrigin = paneID(1)
        let secondOrigin = paneID(2)
        let firstSession = resolvedSession(originPaneID: firstOrigin)
        let secondSession = resolvedSession(originPaneID: secondOrigin, sessionID: "session-2")
        host.setResolvedSession(firstSession)
        host.setResolvedSession(secondSession)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(14),
            paneID: uuid(24),
            tabID: uuid(34),
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: firstSession.identity.instanceID,
                originPaneID: firstOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(220)
                )
            ),
            context: context()
        )

        host.enqueuePromptDecision(.allowed)
        let crossSessionResponse = await coordinator.handle(
            request(
                instanceID: secondSession.identity.instanceID,
                originPaneID: secondOrigin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: ownedTask.taskID),
                    requestID: uuid(221)
                )
            ),
            context: context()
        )

        expectFailure(crossSessionResponse, code: .targetNotOwned)
        #expect(host.focusCalls.isEmpty)
    }

    @Test(arguments: HostOwnershipAccessPath.allCases)
    private func hostSideRebindFailsClosedAndReleasesStaleOwnership(
        path: HostOwnershipAccessPath
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let firstOrigin = paneID(1)
        let secondOrigin = paneID(2)
        let firstSession = resolvedSession(
            originPaneID: firstOrigin,
            paneCount: 2,
            paneIDs: [firstOrigin, secondOrigin]
        )
        let secondSession = resolvedSession(
            originPaneID: secondOrigin,
            sessionID: "session-2",
            workspaceID: firstSession.workspace.workspaceID,
            paneCount: 2,
            paneIDs: [firstOrigin, secondOrigin]
        )
        host.setResolvedSession(firstSession)
        host.setResolvedSession(secondSession)
        host.enqueuePromptDecision(.allowed)

        let reboundTask = task(
            taskID: uuid(22_000 + path.rawValue),
            paneID: uuid(22_010 + path.rawValue),
            tabID: uuid(22_020 + path.rawValue),
            workspaceID: firstSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(reboundTask))
        let createResponse = await coordinator.handle(
            request(
                instanceID: firstSession.identity.instanceID,
                originPaneID: firstOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(22_030 + path.rawValue)
                )
            ),
            context: context()
        )
        #expect(createResponse == TerminalControlResponse(result: .task(reboundTask)))

        host.rebindTask(reboundTask.taskID, to: secondSession.identity)
        let reboundResponse: TerminalControlResponse
        switch path {
        case .read:
            reboundResponse = await coordinator.handle(
                request(
                    instanceID: firstSession.identity.instanceID,
                    originPaneID: firstOrigin,
                    request: try TerminalControlRequest(
                        operation: .read(taskID: reboundTask.taskID)
                    )
                ),
                context: context()
            )
        case .focus:
            reboundResponse = await coordinator.handle(
                request(
                    instanceID: firstSession.identity.instanceID,
                    originPaneID: firstOrigin,
                    request: try TerminalControlRequest(
                        operation: .focus(taskID: reboundTask.taskID),
                        requestID: uuid(22_040 + path.rawValue)
                    )
                ),
                context: context()
            )
        }

        expectFailure(reboundResponse, code: .targetNotOwned)
        #expect(host.inspectTaskCallCount == 1)
        #expect(host.readCallCount == 0)
        #expect(host.focusCalls.isEmpty)

        // WHY: A foreign rebind releases local ownership but leaves the host surface alive.
        host.closeCreatedTask(reboundTask.taskID)
        #expect(host.taskStates[reboundTask.taskID] == nil)
        for session in [firstSession, secondSession] {
            let current = try #require(
                host.currentResolvedSession(
                    instanceID: session.identity.instanceID,
                    originPaneID: session.identity.originPaneID
                )
            )
            #expect(!current.workspace.paneIDs.contains(PaneID(rawValue: reboundTask.paneID)))
            #expect(!current.workspace.tabIDs.contains(TabID(rawValue: reboundTask.tabID)))
        }

        host.enqueuePromptDecision(.allowed)
        let reusedTask = task(
            taskID: uuid(22_050 + path.rawValue),
            paneID: reboundTask.paneID,
            tabID: reboundTask.tabID,
            workspaceID: secondSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(reusedTask))
        let reuseResponse = await coordinator.handle(
            request(
                instanceID: secondSession.identity.instanceID,
                originPaneID: secondOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(22_060 + path.rawValue)
                )
            ),
            context: context()
        )

        #expect(reuseResponse == TerminalControlResponse(result: .task(reusedTask)))
        #expect(host.readCallCount == 0)
        #expect(host.focusCalls.isEmpty)
        #expect(host.discardCreatedTaskCalls.isEmpty)
    }

    @Test(arguments: HostOwnershipAccessPath.allCases, LateHostTaskFailure.allCases)
    private func postAwaitHostOwnershipFailureRemovesUnchangedCapturedTask(
        path: HostOwnershipAccessPath,
        transition: LateHostTaskFailure
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(22_400 + path.rawValue * 10 + transition.rawValue),
            paneID: uuid(22_500 + path.rawValue * 10 + transition.rawValue),
            tabID: uuid(22_600 + path.rawValue * 10 + transition.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(22_700 + path.rawValue * 10 + transition.rawValue)
                )
            ),
            context: context()
        )

        let pending: Task<TerminalControlResponse, Never>
        switch path {
        case .read:
            host.pauseReadResponses()
            host.enqueueReadResult(.task(ownedTask))
            let readRequest = try TerminalControlRequest(
                operation: .read(taskID: ownedTask.taskID)
            )
            pending = Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: readRequest
                    ),
                    context: context()
                )
            }
            await host.waitForReadCalls(1)
        case .focus:
            host.pauseMutationResponses()
            host.enqueueMutationResult(
                .acknowledged(taskID: ownedTask.taskID, revision: ownedTask.revision)
            )
            let focusRequest = try TerminalControlRequest(
                operation: .focus(taskID: ownedTask.taskID),
                requestID: uuid(22_800 + transition.rawValue)
            )
            pending = Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: focusRequest
                    ),
                    context: context()
                )
            }
            await host.waitForTaskMutationCalls(1)
        }

        transition.apply(to: ownedTask.taskID, host: host, originalSession: session.identity)
        switch path {
        case .read:
            host.resumeReadResponses()
        case .focus:
            host.resumeMutationResponses()
        }

        let response = await pending.value
        expectFailure(response, code: transition.errorCode)

        host.taskStates[ownedTask.taskID] = ownedTask
        host.rebindTask(ownedTask.taskID, to: session.identity)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )

        let foreignOrigin = paneID(2)
        let foreignSession = resolvedSession(
            originPaneID: foreignOrigin,
            sessionID: "foreign-reuse",
            workspaceID: session.workspace.workspaceID
        )
        host.setResolvedSession(foreignSession)
        host.enqueuePromptDecision(.allowed)
        let reusedTask = task(
            taskID: uuid(23_500 + path.rawValue * 10 + transition.rawValue),
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: foreignSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(reusedTask))
        let reuseResponse = await coordinator.handle(
            request(
                instanceID: foreignSession.identity.instanceID,
                originPaneID: foreignOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(23_600 + path.rawValue * 10 + transition.rawValue)
                )
            ),
            context: context()
        )
        #expect(reuseResponse == TerminalControlResponse(result: .task(reusedTask)))
    }

    @Test(arguments: HostOwnershipAccessPath.allCases, LateHostTaskFailure.allCases)
    private func postAwaitHostOwnershipFailureDoesNotDeleteNewerLocalTask(
        path: HostOwnershipAccessPath,
        transition: LateHostTaskFailure
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(22_900 + path.rawValue * 10 + transition.rawValue),
            paneID: uuid(23_000 + path.rawValue * 10 + transition.rawValue),
            tabID: uuid(23_100 + path.rawValue * 10 + transition.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(23_200 + path.rawValue * 10 + transition.rawValue)
                )
            ),
            context: context()
        )

        let pending: Task<TerminalControlResponse, Never>
        switch path {
        case .read:
            host.pauseReadResponses()
            host.enqueueReadResult(.task(ownedTask))
            let readRequest = try TerminalControlRequest(
                operation: .read(taskID: ownedTask.taskID)
            )
            pending = Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: readRequest
                    ),
                    context: context()
                )
            }
            await host.waitForReadCalls(1)
        case .focus:
            host.pauseMutationResponses()
            host.enqueueMutationResult(
                .acknowledged(taskID: ownedTask.taskID, revision: ownedTask.revision)
            )
            let focusRequest = try TerminalControlRequest(
                operation: .focus(taskID: ownedTask.taskID),
                requestID: uuid(23_300 + transition.rawValue)
            )
            pending = Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: focusRequest
                    ),
                    context: context()
                )
            }
            await host.waitForTaskMutationCalls(1)
        }

        let newerTask = task(
            taskID: ownedTask.taskID,
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: ownedTask.workspaceID,
            state: .running,
            revision: 2
        )
        host.taskStates[ownedTask.taskID] = newerTask
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        transition.apply(to: ownedTask.taskID, host: host, originalSession: session.identity)
        switch path {
        case .read:
            host.resumeReadResponses()
        case .focus:
            host.resumeMutationResponses()
        }

        let response = await pending.value
        expectFailure(response, code: transition.errorCode)

        host.taskStates[ownedTask.taskID] = newerTask
        host.rebindTask(ownedTask.taskID, to: session.identity)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == newerTask.revision)
    }

    @Test
    func missingHostTaskIsRemovedAndReportedNotFound() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(9800),
            paneID: uuid(9810),
            tabID: uuid(9820),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9801)
                )
            ),
            context: context()
        )

        host.taskStates.removeValue(forKey: ownedTask.taskID)
        let missingResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: ownedTask.taskID),
                    requestID: uuid(9802)
                )
            ),
            context: context()
        )

        expectFailure(missingResponse, code: .targetNotFound)
        #expect(host.focusCalls.isEmpty)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test
    func movedTasksAndAnchorsInAnotherWorkspaceFailClosed() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(15),
            paneID: uuid(25),
            tabID: uuid(35),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(230)
                )
            ),
            context: context()
        )

        host.taskStates[createdTask.taskID] = task(
            taskID: createdTask.taskID,
            paneID: createdTask.paneID,
            tabID: createdTask.tabID,
            workspaceID: uuid(999),
            state: .running
        )

        let focusResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: createdTask.taskID),
                    requestID: uuid(231)
                )
            ),
            context: context()
        )
        let splitResponse = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: createdTask.paneID,
                        direction: .down,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: true
                    ),
                    requestID: uuid(232)
                )
            ),
            context: context()
        )

        expectFailure(focusResponse, code: .targetNotOwned)
        expectFailure(splitResponse, code: .targetNotOwned)
        #expect(host.focusCalls.isEmpty)
        #expect(host.createSplitCalls.isEmpty)

        let foreignOrigin = paneID(2)
        let foreignSession = resolvedSession(
            originPaneID: foreignOrigin,
            sessionID: "foreign",
            workspaceID: session.workspace.workspaceID
        )
        host.setResolvedSession(foreignSession)
        host.enqueuePromptDecision(.allowed)
        let reusedTask = task(
            taskID: uuid(233),
            paneID: createdTask.paneID,
            tabID: createdTask.tabID,
            workspaceID: foreignSession.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(reusedTask))
        let reuseResponse = await coordinator.handle(
            request(
                instanceID: foreignSession.identity.instanceID,
                originPaneID: foreignOrigin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(234)
                )
            ),
            context: context()
        )
        #expect(reuseResponse == TerminalControlResponse(result: .task(reusedTask)))
    }

    @Test
    func listExcludesReboundTasksAfterRefresh() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(9900),
            paneID: uuid(9910),
            tabID: uuid(9920),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(9901)
                )
            ),
            context: context()
        )

        host.taskStates[createdTask.taskID] = task(
            taskID: createdTask.taskID,
            paneID: uuid(9930),
            tabID: uuid(9940),
            workspaceID: uuid(9950),
            state: .running
        )

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )

        let followUp = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: createdTask.taskID),
                    requestID: uuid(9902)
                )
            ),
            context: context()
        )
        expectFailure(followUp, code: .targetNotOwned)
        #expect(host.focusCalls.isEmpty)
    }

    @Test
    func runningTaskLimitStopsNinthActiveTask() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        for index in 0..<9 {
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: uuid(300 + index),
                        paneID: uuid(400 + index),
                        tabID: uuid(500 + index),
                        workspaceID: session.workspace.workspaceID.rawValue,
                        state: .running
                    )
                )
            )
        }

        for index in 0..<8 {
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .keep, focus: index.isMultiple(of: 2)),
                        requestID: uuid(600 + index)
                    )
                ),
                context: context()
            )
            #expect(taskID(in: response) == uuid(300 + index))
        }

        let limited = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(608)
                )
            ),
            context: context()
        )

        expectFailure(limited, code: .resourceLimit)
        #expect(host.createTabCalls.count == 8)
    }

    @Test
    func failedReservationLeavesRetainedTasksUnchanged() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        // WHY: Terminal records must be retained before running tasks exhaust create capacity.
        var setupTasks: [TerminalControlTask] = []
        for index in 0..<24 {
            setupTasks.append(
                task(
                    taskID: uuid(1_900 + index),
                    paneID: uuid(2_000 + index),
                    tabID: uuid(2_100 + index),
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .succeeded
                )
            )
        }
        for index in 0..<8 {
            setupTasks.append(
                task(
                    taskID: uuid(1_600 + index),
                    paneID: uuid(1_700 + index),
                    tabID: uuid(1_800 + index),
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .running
                )
            )
        }

        for (index, setupTask) in setupTasks.enumerated() {
            host.enqueueCreateTabResult(.task(setupTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .keep, focus: index.isMultiple(of: 2)),
                        requestID: uuid(2_200 + index)
                    )
                ),
                context: context()
            )
            #expect(response == TerminalControlResponse(result: .task(setupTask)))
        }

        let listedBefore = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        let beforeTaskIDs = listTaskIDs(in: listedBefore)
        #expect(beforeTaskIDs.count == 32)
        #expect(beforeTaskIDs == setupTasks.map(\.taskID))
        guard case .list(_, let beforeTasks) = listedBefore.result else {
            Issue.record("Expected list response")
            return
        }
        #expect(beforeTasks.filter { $0.state == .running }.count == 8)
        #expect(beforeTasks.filter { $0.state == .succeeded }.count == 24)
        let createCallCountBefore = host.createTabCalls.count
        #expect(createCallCountBefore == 32)
        #expect(host.discardCreatedTaskCalls.isEmpty)

        let limited = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(2_300)
                )
            ),
            context: context()
        )
        expectFailure(limited, code: .resourceLimit)

        let listedAfter = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(listTaskIDs(in: listedAfter) == beforeTaskIDs)
        #expect(host.createTabCalls.count == createCallCountBefore)
        #expect(host.createSplitCalls.isEmpty)
        #expect(host.discardCreatedTaskCalls.isEmpty)
    }

    @Test
    func terminalRecordsEvictOldestEntriesToStayWithinThirtyTwo() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        for index in 0..<33 {
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: uuid(700 + index),
                        paneID: uuid(800 + index),
                        tabID: uuid(900 + index),
                        workspaceID: session.workspace.workspaceID.rawValue,
                        state: .succeeded
                    )
                )
            )
        }

        for index in 0..<33 {
            _ = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(1_000 + index)
                    )
                ),
                context: context()
            )
        }

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)),
            context: context()
        )
        let listedTaskIDs = listTaskIDs(in: listed)

        #expect(listedTaskIDs.count == 32)
        #expect(!listedTaskIDs.contains(uuid(700)))
        #expect(listedTaskIDs.first == uuid(701))
        #expect(listedTaskIDs.last == uuid(732))
    }

    @Test
    func mandatoryHostClosureProtectsEvictionAndReservationSlots() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let retained = try await populateRetainedTerminalTasks(
            host: host, coordinator: coordinator, session: session, origin: origin, base: 84_000)
        host.pendingMandatoryCloseTaskIDs = Set(retained)
        let create: (Int) throws -> TerminalControlSocketRequest = { index in
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(88_000 + index)))
        }
        expectFailure(
            await coordinator.handle(try create(0), context: context()), code: .resourceLimit)
        #expect(host.createTabCalls.count == 32)
        #expect(host.forgottenTaskIDs.isEmpty)
        #expect(coordinator.pendingCreateReservationCountForTesting(session.identity) == 0)

        let candidate = task(
            taskID: uuid(88_100), paneID: uuid(88_101), tabID: uuid(88_102),
            workspaceID: session.workspace.workspaceID.rawValue, state: .succeeded)
        host.pendingMandatoryCloseTaskIDs.remove(retained[1])
        host.enqueueCreateTabResult(.task(candidate))
        #expect(
            await coordinator.handle(try create(1), context: context())
                == TerminalControlResponse(result: .task(candidate)))
        #expect(host.forgottenTaskIDs == [retained[1]])
        host.pendingMandatoryCloseTaskIDs.insert(candidate.taskID)
        host.pendingMandatoryCloseTaskIDs.remove(retained[0])
        let next = task(
            taskID: uuid(88_110), paneID: uuid(88_111), tabID: uuid(88_112),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running)
        host.enqueueCreateTabResult(.task(next))
        #expect(
            await coordinator.handle(try create(2), context: context())
                == TerminalControlResponse(result: .task(next)))
        #expect(host.forgottenTaskIDs == [retained[1], retained[0]])
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)), context: context())
        #expect(
            listTaskIDs(in: listed) == Array(retained.dropFirst(2)) + [
                candidate.taskID, next.taskID,
            ])
    }

    @Test
    func newlyRequiredHostClosureIsRecheckedAfterSuspendedCreation() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let retained = try await populateRetainedTerminalTasks(
            host: host, coordinator: coordinator, session: session, origin: origin, base: 89_000)
        host.pendingMandatoryCloseTaskIDs = Set(retained.dropFirst())
        host.pauseCreateTabResponses()
        let candidate = task(
            taskID: uuid(93_100), paneID: uuid(93_101), tabID: uuid(93_102),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running)
        host.enqueueCreateTabResult(.task(candidate))
        let create = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(93_103))
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin,
                    request: create), context: context())
        }
        await host.waitForCreateTabCalls(33)
        host.pendingMandatoryCloseTaskIDs.insert(retained[0])
        host.resumeCreateTabResponses()
        expectFailure(await pending.value, code: .internalFailure)
        #expect(host.forgottenTaskIDs.isEmpty)
        #expect(host.discardCreatedTaskCalls.map(\.created.task.taskID) == [candidate.taskID])
        #expect(coordinator.pendingCreateReservationCountForTesting(session.identity) == 0)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)), context: context())
        #expect(listTaskIDs(in: listed) == retained)
    }

    @Test
    func activeRecordsAreNeverEvictedAheadOfTerminalOnes() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        host.enqueueCreateTabResult(
            .task(
                task(
                    taskID: uuid(1_100),
                    paneID: uuid(1_200),
                    tabID: uuid(1_300),
                    workspaceID: session.workspace.workspaceID.rawValue,
                    state: .running
                )
            )
        )
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(1_400)
                )
            ),
            context: context()
        )

        for index in 0..<32 {
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: uuid(1_101 + index),
                        paneID: uuid(1_201 + index),
                        tabID: uuid(1_301 + index),
                        workspaceID: session.workspace.workspaceID.rawValue,
                        state: .succeeded
                    )
                )
            )
        }

        for index in 0..<32 {
            _ = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(1_401 + index)
                    )
                ),
                context: context()
            )
        }

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)),
            context: context()
        )
        let listedTaskIDs = listTaskIDs(in: listed)

        #expect(listedTaskIDs.count == 32)
        #expect(listedTaskIDs.contains(uuid(1_100)))
        #expect(!listedTaskIDs.contains(uuid(1_101)))
        #expect(listedTaskIDs.contains(uuid(1_132)))
    }

    @Test
    func pendingMutationLimitStillCoalescesIdenticalRequestAndCleansUp() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(10_000),
            paneID: uuid(10_001),
            tabID: uuid(10_002),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(10_003)
                )
            ),
            context: context()
        )

        host.pauseMutationResponses()
        let requests = try (0..<32).map { index in
            try TerminalControlRequest(
                operation: .focus(taskID: ownedTask.taskID),
                requestID: uuid(10_100 + index)
            )
        }
        let pending = requests.map { controlRequest in
            Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: controlRequest
                    ),
                    context: context()
                )
            }
        }
        await host.waitForTaskMutationCalls(32)

        let coalesced = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: requests[0]
                ),
                context: context()
            )
        }
        let overflow = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: ownedTask.taskID),
                    requestID: uuid(10_132)
                )
            ),
            context: context()
        )
        expectFailure(overflow, code: .resourceLimit)

        host.resumeMutationResponses()
        for responseTask in pending {
            _ = await responseTask.value
        }
        _ = await coalesced.value
        #expect(host.taskMutationCallCount == 32)

        let afterCleanup = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .focus(taskID: ownedTask.taskID),
                    requestID: uuid(10_133)
                )
            ),
            context: context()
        )
        #expect(
            afterCleanup
                == TerminalControlResponse(
                    result: .acknowledged(taskID: ownedTask.taskID, revision: 1)
                )
        )
        #expect(host.taskMutationCallCount == 33)
    }

    @Test
    func cancelledContextStopsLateMutationSideEffects() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        let pendingRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: true),
            requestID: uuid(1_500)
        )
        let responseTask = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: pendingRequest
                ),
                context: context(lease)
            )
        }

        await host.waitForPromptCalls(1)
        lease.isActive = false
        host.resumeNextPrompt(.allowed)
        let response = await responseTask.value

        expectFailure(response, code: .cancelled)
        #expect(host.createTabCalls.isEmpty)
    }

    @Test
    func concurrentCreateReservationsAccountForTheSameRetentionSlot() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        var protectedTaskIDs: [UUID] = []
        for index in 0..<31 {
            let activeTask = task(
                taskID: uuid(19_000 + index),
                paneID: uuid(19_100 + index),
                tabID: uuid(19_200 + index),
                workspaceID: session.workspace.workspaceID.rawValue,
                state: .succeeded
            )
            host.enqueueCreateTabResult(.task(activeTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(19_300 + index)
                    )
                ),
                context: context()
            )
            try #require(taskID(in: response) == activeTask.taskID)
            protectedTaskIDs.append(activeTask.taskID)
            host.pendingMandatoryCloseTaskIDs.insert(activeTask.taskID)
        }
        let terminalTask = task(
            taskID: uuid(19_400),
            paneID: uuid(19_401),
            tabID: uuid(19_402),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .succeeded
        )
        host.enqueueCreateTabResult(.task(terminalTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(19_403)
                )
            ),
            context: context()
        )

        try #require(host.taskStates[terminalTask.taskID] == terminalTask)
        try #require(host.createTabCalls.count == 32)

        let candidate = task(
            taskID: uuid(19_410),
            paneID: uuid(19_411),
            tabID: uuid(19_412),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .creating
        )
        host.pauseCreateTabResponses()
        host.enqueueCreateTabResult(.task(candidate))
        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(19_413)
        )
        let first = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }
        await host.waitForCreateTabCalls(33)

        let second = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(19_414)
                )
            ),
            context: context()
        )
        expectFailure(second, code: .resourceLimit)
        #expect(host.createTabCalls.count == 33)

        host.resumeCreateTabResponses()
        let firstResponse = await first.value
        #expect(firstResponse == TerminalControlResponse(result: .task(candidate)))

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        let listedTaskIDs = listTaskIDs(in: listed)
        #expect(listedTaskIDs.count == 32)
        #expect(protectedTaskIDs.allSatisfy { listedTaskIDs.contains($0) })
        #expect(!listedTaskIDs.contains(terminalTask.taskID))
        #expect(listedTaskIDs.contains(candidate.taskID))
    }

    @Test(arguments: FailedCreateCompletion.allCases)
    private func createCompletionsAtRetentionLimitEvictOnlyValidatedSuccess(
        completion: FailedCreateCompletion
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let lease = Lease()
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let retainedTaskIDs = try await populateRetainedTerminalTasks(
            host: host,
            coordinator: coordinator,
            session: session,
            origin: origin,
            base: 20_000
        )

        let candidate = task(
            taskID: uuid(20_100),
            paneID: uuid(20_101),
            tabID: uuid(20_102),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .succeeded
        )
        switch completion {
        case .failure:
            host.enqueueCreateTabResult(.failure(.surfaceCreationFailed))
        case .invalid:
            host.enqueueCreateTabResult(.acknowledged(taskID: candidate.taskID, revision: 1))
        case .policyMismatch:
            host.enqueueCreateTabResult(
                .task(
                    task(
                        taskID: candidate.taskID,
                        paneID: candidate.paneID,
                        tabID: candidate.tabID,
                        workspaceID: candidate.workspaceID,
                        state: candidate.state,
                        policy: .closeOnSuccess
                    )
                )
            )
        case .stale, .cancelled:
            host.pauseCreateTabResponses()
            host.enqueueCreateTabResult(.task(candidate))
        }

        let createRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(20_103 + completion.rawValue)
        )
        let response: TerminalControlResponse
        if completion == .stale || completion == .cancelled {
            let pending = Task { @MainActor in
                await coordinator.handle(
                    request(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        request: createRequest
                    ),
                    context: context(lease)
                )
            }
            await host.waitForCreateTabCalls(33)
            if completion == .stale {
                host.setResolvedSession(
                    resolvedSession(
                        instanceID: session.identity.instanceID,
                        originPaneID: origin,
                        workspaceID: WorkspaceID(rawValue: uuid(20_110))
                    )
                )
            } else {
                lease.isActive = false
            }
            host.resumeCreateTabResponses()
            response = await pending.value
            host.setResolvedSession(session)
        } else {
            response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
        }

        switch completion {
        case .failure:
            expectFailure(response, code: .surfaceCreationFailed)
        case .invalid, .policyMismatch:
            expectFailure(response, code: .internalFailure)
        case .stale:
            expectFailure(response, code: .staleSession)
        case .cancelled:
            expectFailure(response, code: .cancelled)
            let retained = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: createRequest
                ),
                context: context()
            )
            #expect(retained == TerminalControlResponse(result: .task(candidate)))
        }

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        if completion == .cancelled {
            let expectedTaskIDs = Array(retainedTaskIDs.dropFirst()) + [candidate.taskID]
            #expect(listTaskIDs(in: listed) == expectedTaskIDs)
        } else {
            #expect(listTaskIDs(in: listed) == retainedTaskIDs)
        }
    }

    @Test(arguments: CreateResponsePath.allCases)
    private func createAndSplitRejectMismatchedLifecyclePolicy(
        path: CreateResponsePath
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let mismatchedTask = task(
            taskID: uuid(21_000 + path.rawValue),
            paneID: uuid(21_010 + path.rawValue),
            tabID: uuid(21_020 + path.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            policy: .keep
        )
        let hostResponse = try path.response(for: mismatchedTask)
        let operation: TerminalControlRequest.Operation
        switch path {
        case .createTask, .createSnapshot:
            host.enqueueCreateTabResult(hostResponse)
            operation = .createTab(
                launch: try launch(), policy: .closeOnSuccess, focus: false)
        case .splitTask, .splitSnapshot:
            host.enqueueCreateSplitResult(hostResponse)
            operation = .split(
                anchorPaneID: nil,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .closeOnSuccess,
                focus: false
            )
        }

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: operation,
                    requestID: uuid(21_030 + path.rawValue)
                )
            ),
            context: context()
        )
        expectFailure(response, code: .internalFailure)

        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            listed,
            workspaceID: session.workspace.workspaceID.rawValue,
            taskIDs: []
        )
    }

    @Test(arguments: HostTaskResponseShape.allCases)
    private func readRejectsMismatchedLifecyclePolicy(
        shape: HostTaskResponseShape
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let ownedTask = task(
            taskID: uuid(21_100 + shape.rawValue),
            paneID: uuid(21_110 + shape.rawValue),
            tabID: uuid(21_120 + shape.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            policy: .keep,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(ownedTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(21_130 + shape.rawValue)
                )
            ),
            context: context()
        )

        let mismatchedTask = task(
            taskID: ownedTask.taskID,
            paneID: ownedTask.paneID,
            tabID: ownedTask.tabID,
            workspaceID: ownedTask.workspaceID,
            state: .running,
            policy: .closeOnSuccess,
            revision: 2
        )
        host.enqueueReadResult(try shape.response(for: mismatchedTask))
        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: ownedTask.taskID))
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
    }

    @Test(arguments: TaskMutationKind.allCases)
    private func everyTaskMutationRejectsMismatchedLifecyclePolicy(
        kind: TaskMutationKind
    ) async throws {
        for shape in HostTaskResponseShape.allCases {
            let host = FakeTerminalAutomationHost()
            let coordinator = TerminalAutomationCoordinator(host: host)
            let origin = paneID(1)
            let session = resolvedSession(originPaneID: origin)
            host.setResolvedSession(session)
            host.enqueuePromptDecision(.allowed)

            let ownedTask = task(
                taskID: uuid(21_200 + kind.rawValue * 10 + shape.rawValue),
                paneID: uuid(21_300 + kind.rawValue * 10 + shape.rawValue),
                tabID: uuid(21_400 + kind.rawValue * 10 + shape.rawValue),
                workspaceID: session.workspace.workspaceID.rawValue,
                state: .running,
                policy: .keep,
                revision: 1
            )
            host.enqueueCreateTabResult(.task(ownedTask))
            _ = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(21_500 + kind.rawValue * 10 + shape.rawValue)
                    )
                ),
                context: context()
            )

            let mismatchedTask = task(
                taskID: ownedTask.taskID,
                paneID: ownedTask.paneID,
                tabID: ownedTask.tabID,
                workspaceID: ownedTask.workspaceID,
                state: .running,
                policy: .closeOnSuccess,
                revision: 2
            )
            host.enqueueMutationResult(try shape.response(for: mismatchedTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: kind.operation(taskID: ownedTask.taskID),
                        requestID: uuid(21_600 + kind.rawValue * 10 + shape.rawValue)
                    )
                ),
                context: context()
            )

            expectFailure(response, code: .internalFailure)
            let listed = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            #expect(taskRevision(in: listed, taskID: ownedTask.taskID) == 1)
        }
    }

    @Test(arguments: EqualRevisionChange.allCases)
    private func equalRevisionChangedSnapshotIsRejected(
        change: EqualRevisionChange
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_250)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initialTask = task(
            taskID: uuid(40_260 + change.rawValue),
            paneID: uuid(40_270 + change.rawValue),
            tabID: uuid(40_280 + change.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 7
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_290 + change.rawValue)
                )
            ),
            context: context()
        )
        host.enqueueReadResult(
            .snapshot(
                try TerminalControlSnapshot(
                    task: change.apply(to: initialTask),
                    text: "unchanged output",
                    isTruncated: false
                )
            )
        )

        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: initialTask.taskID))
            ),
            context: context()
        )

        expectFailure(response, code: .internalFailure)
    }

    @Test(
        arguments: EqualRevisionChange.allCases,
        LifecycleUpdatePath.allCases
    )
    private func equalRevisionAcceptsOnlyTheIdenticalTask(
        change: EqualRevisionChange,
        path: LifecycleUpdatePath
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(40_300)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initialTask = task(
            taskID: uuid(40_310 + change.rawValue * 10 + path.rawValue),
            paneID: uuid(40_410 + change.rawValue * 10 + path.rawValue),
            tabID: uuid(40_510 + change.rawValue * 10 + path.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: .running,
            revision: 7
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(40_610 + change.rawValue * 10 + path.rawValue)
                )
            ),
            context: context()
        )
        let changedTask = change.apply(to: initialTask)

        let response: TerminalControlResponse
        switch path {
        case .refresh:
            host.taskStates[initialTask.taskID] = changedTask
            response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            #expect(listedTask(in: response, taskID: initialTask.taskID) != changedTask)
        case .inspect:
            host.taskStates[initialTask.taskID] = changedTask
            host.enqueueReadResult(.task(initialTask))
            response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .read(taskID: initialTask.taskID))
                ),
                context: context()
            )
            #expect(response != TerminalControlResponse(result: .task(changedTask)))
        case .read:
            host.enqueueReadResult(.task(changedTask))
            response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .read(taskID: initialTask.taskID))
                ),
                context: context()
            )
            expectFailure(response, code: .internalFailure)
        case .mutation:
            host.enqueueMutationResult(.task(changedTask))
            response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .focus(taskID: initialTask.taskID),
                        requestID: uuid(40_710 + change.rawValue * 10 + path.rawValue)
                    )
                ),
                context: context()
            )
            expectFailure(response, code: .internalFailure)
        }
    }

    @Test(arguments: ValidTaskLifecycleTransition.allCases)
    private func validTaskLifecycleTransitionsRemainAccepted(
        transition: ValidTaskLifecycleTransition
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(24_100 + transition.rawValue),
            paneID: uuid(24_110 + transition.rawValue),
            tabID: uuid(24_120 + transition.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: transition.initialState,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(24_130 + transition.rawValue)
                )
            ),
            context: context()
        )

        let updatedTask = task(
            taskID: initialTask.taskID,
            paneID: initialTask.paneID,
            tabID: initialTask.tabID,
            workspaceID: initialTask.workspaceID,
            state: transition.updatedState,
            revision: 2
        )
        host.enqueueReadResult(.task(updatedTask))
        let response = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .read(taskID: initialTask.taskID))
            ),
            context: context()
        )

        #expect(response == TerminalControlResponse(result: .task(updatedTask)))
    }

    @Test(
        arguments: TerminalLifecycleState.allCases,
        LifecycleUpdatePath.allCases
    )
    private func terminalTaskCannotReturnToRunning(
        terminalState: TerminalLifecycleState,
        path: LifecycleUpdatePath
    ) async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)

        let initialTask = task(
            taskID: uuid(24_200 + terminalState.rawValue * 10 + path.rawValue),
            paneID: uuid(24_300 + terminalState.rawValue * 10 + path.rawValue),
            tabID: uuid(24_400 + terminalState.rawValue * 10 + path.rawValue),
            workspaceID: session.workspace.workspaceID.rawValue,
            state: terminalState.state,
            revision: 1
        )
        host.enqueueCreateTabResult(.task(initialTask))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(24_500 + terminalState.rawValue * 10 + path.rawValue)
                )
            ),
            context: context()
        )

        let reactivatedTask = task(
            taskID: initialTask.taskID,
            paneID: initialTask.paneID,
            tabID: initialTask.tabID,
            workspaceID: initialTask.workspaceID,
            state: .running,
            revision: 2
        )
        switch path {
        case .refresh:
            host.taskStates[initialTask.taskID] = reactivatedTask
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            #expect(listedTask(in: response, taskID: initialTask.taskID) == initialTask)
        case .inspect:
            host.taskStates[initialTask.taskID] = reactivatedTask
            host.enqueueReadResult(.task(initialTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .read(taskID: initialTask.taskID)
                    )
                ),
                context: context()
            )
            #expect(response == TerminalControlResponse(result: .task(initialTask)))
        case .read:
            host.enqueueReadResult(.task(reactivatedTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .read(taskID: initialTask.taskID)
                    )
                ),
                context: context()
            )
            expectFailure(response, code: .internalFailure)
        case .mutation:
            host.enqueueMutationResult(.task(reactivatedTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .focus(taskID: initialTask.taskID),
                        requestID: uuid(
                            24_600 + terminalState.rawValue * 10 + path.rawValue)
                    )
                ),
                context: context()
            )
            expectFailure(response, code: .internalFailure)
        }

        host.taskStates[initialTask.taskID] = initialTask
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        #expect(listedTask(in: listed, taskID: initialTask.taskID) == initialTask)
    }

    @Test
    func retiredIdentityRemainsRevokedAfterMoreThanThirtyTwoSameGenerationReplacements()
        async throws
    {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let createdTask = task(
            taskID: uuid(21_700),
            paneID: uuid(21_701),
            tabID: uuid(21_702),
            workspaceID: initial.workspace.workspaceID.rawValue,
            state: .running
        )
        host.enqueueCreateTabResult(.task(createdTask))
        let originalRequest = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(21_703)
        )
        let originalResponse = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: originalRequest
            ),
            context: context()
        )
        #expect(originalResponse == TerminalControlResponse(result: .task(createdTask)))

        for replacement in 2...64 {
            let rotated = resolvedSession(
                originPaneID: origin,
                sessionID: "session-\(replacement)",
                paneCredentialGeneration: initial.identity.paneCredentialGeneration
            )
            host.setResolvedSession(rotated)
            host.enqueuePromptDecision(.allowed)
            let response = await coordinator.handle(
                request(
                    instanceID: rotated.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            expectList(
                response,
                workspaceID: rotated.workspace.workspaceID.rawValue,
                taskIDs: []
            )
        }

        host.setResolvedSession(initial)
        let oldReplayAttempt = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: originalRequest
            ),
            context: context()
        )

        expectFailure(oldReplayAttempt, code: .permissionRevoked)
        #expect(host.promptCallCount == 64)
        #expect(host.createTabCalls.count == 1)
    }

    @Test
    func neverRetiredIdentityIsNotReportedRevokedAfterSixtyThreeRotations() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let initial = resolvedSession(originPaneID: origin)
        host.setResolvedSession(initial)
        host.enqueuePromptDecision(.allowed)

        let initialResponse = await coordinator.handle(
            request(
                instanceID: initial.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )
        expectList(
            initialResponse,
            workspaceID: initial.workspace.workspaceID.rawValue,
            taskIDs: []
        )

        for replacement in 2...64 {
            let rotated = resolvedSession(
                originPaneID: origin,
                sessionID: "session-\(replacement)",
                paneCredentialGeneration: initial.identity.paneCredentialGeneration
            )
            host.setResolvedSession(rotated)
            host.enqueuePromptDecision(.allowed)
            let response = await coordinator.handle(
                request(
                    instanceID: rotated.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(operation: .list)
                ),
                context: context()
            )
            expectList(
                response,
                workspaceID: rotated.workspace.workspaceID.rawValue,
                taskIDs: []
            )
        }

        let neverRetired = resolvedSession(
            originPaneID: origin,
            sessionID: "never-retired",
            paneCredentialGeneration: initial.identity.paneCredentialGeneration
        )
        host.setResolvedSession(neverRetired)
        host.enqueuePromptDecision(.allowed)
        let response = await coordinator.handle(
            request(
                instanceID: neverRetired.identity.instanceID,
                originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: context()
        )

        expectList(
            response,
            workspaceID: neverRetired.workspace.workspaceID.rawValue,
            taskIDs: []
        )
        #expect(host.promptCallCount == 65)
    }

    @Test(arguments: [false, true])
    func closeCancellationDistinguishesOriginatorFromCoalescedWaiter(cancelOriginator: Bool)
        async throws
    {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initial = task(
            taskID: uuid(82_001), paneID: uuid(82_002), tabID: uuid(82_003),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running)
        host.enqueueCreateTabResult(.task(initial))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(82_004))), context: context())
        let closed = task(
            taskID: initial.taskID, paneID: initial.paneID, tabID: initial.tabID,
            workspaceID: initial.workspaceID, state: .cancelled, owner: .finished, revision: 2)
        host.enqueueMutationResult(.task(closed))
        host.pauseMutationResponses()
        let close = request(
            instanceID: session.identity.instanceID, originPaneID: origin,
            request: try TerminalControlRequest(
                operation: .close(taskID: initial.taskID), requestID: uuid(82_005)))
        let lease = Lease()
        let first = Task { @MainActor in
            await coordinator.handle(close, context: context(lease))
        }
        await host.waitForTaskMutationCalls(1)
        let resolutions = host.resolveSessionCallCount
        let duplicate = Task { @MainActor in
            await coordinator.handle(close, context: context())
        }
        // WHY: Resolution and permission revalidation precede joining the existing mutation
        // without another suspension; cancellation therefore targets an actual coalesced waiter.
        await host.waitForResolveSessionCalls(resolutions + 2)
        #expect(coordinator.pendingMutationCountForTesting(session.identity) == 1)
        let cancelled = cancelOriginator ? first : duplicate
        let survivor = cancelOriginator ? duplicate : first
        cancelled.cancel()
        expectFailure(await cancelled.value, code: .cancelled)
        #expect(lease.isActive)
        // WHY: A late successful host response must not turn a cancelled close into a success replay.
        host.resumeMutationResponses()
        let result = await survivor.value
        if cancelOriginator {
            expectFailure(result, code: .cancelled)
        } else {
            #expect(result == TerminalControlResponse(result: .task(closed)))
        }
        #expect(await coordinator.handle(close, context: context()) == result)
        #expect(host.closeCalls == [initial.taskID])
        #expect(coordinator.pendingMutationCountForTesting(session.identity) == 0)
    }

    @Test
    func failedFinalReadPreservesClassificationAndAllowsLaterSnapshotRetry() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initial = task(
            taskID: uuid(83_001), paneID: uuid(83_002), tabID: uuid(83_003),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running,
            policy: .closeOnSuccess)
        host.enqueueCreateTabResult(.task(initial))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(
                        launch: try launch(), policy: .closeOnSuccess, focus: false),
                    requestID: uuid(83_004))), context: context())
        let read = request(
            instanceID: session.identity.instanceID, originPaneID: origin,
            request: try TerminalControlRequest(operation: .read(taskID: initial.taskID)))
        let old = try TerminalControlSnapshot(task: initial, text: "old output", isTruncated: false)
        host.enqueueReadResult(.snapshot(old))
        #expect(
            await coordinator.handle(read, context: context())
                == TerminalControlResponse(result: .snapshot(old)))
        let classified = TerminalControlTask(
            taskID: initial.taskID, paneID: initial.paneID, tabID: initial.tabID,
            workspaceID: initial.workspaceID, state: .succeeded, owner: .finished,
            policy: initial.policy, revision: initial.revision + 1, exitCode: 0)
        host.taskStates[initial.taskID] = classified
        host.enqueueReadResult(.failure(.internalFailure))
        expectFailure(await coordinator.handle(read, context: context()), code: .internalFailure)
        let listed = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(operation: .list)), context: context())
        #expect(listedTask(in: listed, taskID: initial.taskID) == classified)
        let captured = TerminalControlTask(
            taskID: initial.taskID, paneID: initial.paneID, tabID: initial.tabID,
            workspaceID: initial.workspaceID, state: classified.state, owner: classified.owner,
            policy: initial.policy, revision: classified.revision + 1, exitCode: classified.exitCode
        )
        let final = try TerminalControlSnapshot(
            task: captured, text: "final output", isTruncated: false)
        host.taskStates[initial.taskID] = captured
        host.enqueueReadResult(.snapshot(final))
        #expect(
            await coordinator.handle(read, context: context())
                == TerminalControlResponse(result: .snapshot(final)))
        #expect(host.readCallCount == 3)
        #expect(host.closeCalls.isEmpty)
    }

    @Test
    func waiterRefreshesRenderedOutputAndReturnsChangedRevision() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initial = task(
            taskID: uuid(80_001), paneID: uuid(80_002), tabID: uuid(80_003),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running)
        host.enqueueCreateTabResult(.task(initial))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(80_004))), context: context())
        let changed = task(
            taskID: initial.taskID, paneID: initial.paneID, tabID: initial.tabID,
            workspaceID: initial.workspaceID, state: .running, revision: 2)
        host.enqueueReadResult(
            .snapshot(
                try TerminalControlSnapshot(task: changed, text: "output", isTruncated: false)))
        let result = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .wait(taskID: initial.taskID, revision: 1, timeoutMilliseconds: 100))
            ), context: context())
        #expect(result == TerminalControlResponse(result: .task(changed)))
        #expect(host.readCallCount == 1)
    }

    @Test(arguments: WaitRefreshEnding.allCases)
    private func waiterRefreshIsThrottledAndStopsAtLifecycleBoundary(ending: WaitRefreshEnding)
        async throws
    {
        let host = FakeTerminalAutomationHost()
        let clock = AutomationWaitClock()
        let coordinator = TerminalAutomationCoordinator(
            host: host, waitNow: { clock.now }, waitSleep: clock.sleep)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        let lease = Lease()
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let initial = task(
            taskID: uuid(81_001), paneID: uuid(81_002), tabID: uuid(81_003),
            workspaceID: session.workspace.workspaceID.rawValue, state: .running)
        host.enqueueCreateTabResult(.task(initial))
        _ = await coordinator.handle(
            request(
                instanceID: session.identity.instanceID, originPaneID: origin,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(81_004))), context: context())
        let wait = try TerminalControlRequest(
            operation: .wait(taskID: initial.taskID, revision: 1, timeoutMilliseconds: 1_000))
        let pending = Task { @MainActor in
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin, request: wait),
                context: context(lease))
        }
        await clock.waitForSleeps(1)
        #expect(host.readCallCount == 1)
        expectFailure(
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin, request: wait),
                context: context()), code: .resourceLimit)
        clock.advance(to: 0.249)
        await clock.waitForSleeps(2)
        #expect(host.readCallCount == 1)
        clock.advance(to: 0.25)
        await clock.waitForSleeps(3)
        #expect(host.readCallCount == 2)
        switch ending {
        case .output:
            let updated = task(
                taskID: initial.taskID, paneID: initial.paneID, tabID: initial.tabID,
                workspaceID: initial.workspaceID, state: .running, revision: 2)
            host.enqueueReadResult(
                .snapshot(
                    try TerminalControlSnapshot(task: updated, text: "new", isTruncated: false)))
            clock.advance(to: 0.499)
            await clock.waitForSleeps(4)
            #expect(host.readCallCount == 2)
            clock.advance(to: 0.5)
        case .timeout:
            clock.advance(to: 1)
        case .socket:
            lease.isActive = false
            clock.advance(to: 0.3)
        case .taskCancellation:
            pending.cancel()
            clock.advance(to: 0.3)
        case .revoke:
            coordinator.originSessionDidChange(originPaneID: origin)
            host.clearResolvedSession(instanceID: session.identity.instanceID, originPaneID: origin)
            clock.advance(to: 0.3)
        }
        let result = await pending.value
        switch ending {
        case .output:
            guard case .task(let task) = result.result else {
                Issue.record("Expected revision change")
                return
            }
            #expect(task.revision == 2)
        case .timeout:
            expectFailure(result, code: .timeout)
        case .socket, .taskCancellation:
            expectFailure(result, code: .cancelled)
        case .revoke:
            expectFailure(result, code: .staleSession)
        }
        #expect(host.readCallCount == (ending == .output ? 3 : 2))
        #expect(!clock.hasPendingSleep)
    }

    private enum WaitRefreshEnding: CaseIterable, Equatable, Sendable {
        case output, timeout, socket, taskCancellation, revoke
    }

    @Test
    func lifecycleHookRetiresGrantWithoutIncomingRequestAndRejectsABA() async throws {
        let host = FakeTerminalAutomationHost()
        let coordinator = TerminalAutomationCoordinator(host: host)
        let origin = paneID(1)
        let session = resolvedSession(originPaneID: origin)
        host.setResolvedSession(session)
        host.enqueuePromptDecision(.allowed)
        let list = try TerminalControlRequest(operation: .list)
        _ = await coordinator.handle(
            request(instanceID: session.identity.instanceID, originPaneID: origin, request: list),
            context: context())
        coordinator.originSessionDidChange(originPaneID: origin)
        #expect(host.revokedSessions == [session.identity])
        expectFailure(
            await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID, originPaneID: origin, request: list),
                context: context()), code: .permissionRevoked)
        #expect(host.promptCallCount == 1)
    }

    private func populateRetainedTerminalTasks(
        host: FakeTerminalAutomationHost,
        coordinator: TerminalAutomationCoordinator,
        session: TerminalAutomationResolvedSession,
        origin: PaneID,
        base: Int
    ) async throws -> [UUID] {
        var taskIDs: [UUID] = []
        for index in 0..<TerminalControlLimits.maximumRetainedTaskCount {
            let retainedTask = task(
                taskID: uuid(base + index),
                paneID: uuid(base + 1_000 + index),
                tabID: uuid(base + 2_000 + index),
                workspaceID: session.workspace.workspaceID.rawValue,
                state: .succeeded
            )
            host.enqueueCreateTabResult(.task(retainedTask))
            let response = await coordinator.handle(
                request(
                    instanceID: session.identity.instanceID,
                    originPaneID: origin,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(base + 3_000 + index)
                    )
                ),
                context: context()
            )
            #expect(response == TerminalControlResponse(result: .task(retainedTask)))
            taskIDs.append(retainedTask.taskID)
        }
        return taskIDs
    }

    private enum HostileCreateIdentity: Int, CaseIterable, Equatable, Sendable {
        case originPane
        case existingPane
        case originTab
        case currentTab
    }

    private enum HostileSplitPaneIdentity: Int, CaseIterable, Equatable, Sendable {
        case originAnchor
        case existingPane
    }

    private enum FailedCreateCompletion: Int, CaseIterable, Sendable {
        case failure
        case invalid
        case policyMismatch
        case stale
        case cancelled
    }

    private enum EqualRevisionChange: Int, CaseIterable, Sendable {
        case state
        case owner
        case exitCode
        case policy
        case identity

        func apply(to task: TerminalControlTask) -> TerminalControlTask {
            TerminalControlTask(
                taskID: task.taskID,
                paneID: self == .identity ? uuid(40_800 + rawValue) : task.paneID,
                tabID: task.tabID,
                workspaceID: task.workspaceID,
                state: self == .state ? .waitingForUser : task.state,
                owner: self == .owner ? .user : task.owner,
                policy: self == .policy ? .closeOnSuccess : task.policy,
                revision: task.revision,
                exitCode: self == .exitCode ? 1 : task.exitCode
            )
        }
    }

    private enum ValidTaskLifecycleTransition: Int, CaseIterable, Sendable {
        case activeToActive
        case activeToTerminal
        case terminalToTerminal

        var initialState: TerminalTaskState {
            switch self {
            case .activeToActive, .activeToTerminal:
                .running
            case .terminalToTerminal:
                .failed
            }
        }

        var updatedState: TerminalTaskState {
            switch self {
            case .activeToActive:
                .waitingForUser
            case .activeToTerminal:
                .succeeded
            case .terminalToTerminal:
                .cancelled
            }
        }
    }

    private enum TerminalLifecycleState: Int, CaseIterable, Sendable {
        case succeeded
        case failed
        case finishedUnknown
        case cancelled

        var state: TerminalTaskState {
            switch self {
            case .succeeded:
                .succeeded
            case .failed:
                .failed
            case .finishedUnknown:
                .finishedUnknown
            case .cancelled:
                .cancelled
            }
        }
    }

    private enum LifecycleUpdatePath: Int, CaseIterable, Sendable {
        case inspect
        case refresh
        case read
        case mutation
    }

    private enum CreateResponsePath: Int, CaseIterable, Sendable {
        case createTask
        case createSnapshot
        case splitTask
        case splitSnapshot

        func response(for task: TerminalControlTask) throws -> TerminalAutomationHostResponse {
            switch self {
            case .createTask, .splitTask:
                .task(task)
            case .createSnapshot, .splitSnapshot:
                .snapshot(
                    try TerminalControlSnapshot(task: task, text: "", isTruncated: false)
                )
            }
        }
    }

    private enum HostOwnershipAccessPath: Int, CaseIterable, Sendable {
        case read
        case focus
    }

    private enum LateHostTaskFailure: Int, CaseIterable, Sendable {
        case disappeared
        case foreignRebind

        var errorCode: TerminalControlErrorCode {
            switch self {
            case .disappeared:
                .targetNotFound
            case .foreignRebind:
                .targetNotOwned
            }
        }

        @MainActor
        func apply(
            to taskID: UUID,
            host: FakeTerminalAutomationHost,
            originalSession: TerminalAutomationSessionIdentity
        ) {
            switch self {
            case .disappeared:
                host.taskStates.removeValue(forKey: taskID)
            case .foreignRebind:
                let foreign = TerminalAutomationSessionIdentity(
                    instanceID: originalSession.instanceID,
                    originPaneID: PaneID(rawValue: uuid(23_400)),
                    adapterID: originalSession.adapterID,
                    sessionID: "foreign",
                    paneCredentialGeneration: originalSession.paneCredentialGeneration
                )
                host.rebindTask(taskID, to: foreign)
            }
        }
    }

    private enum UserInputSuccessShape: Int, CaseIterable, Sendable {
        case acknowledged
        case task
        case snapshot

        func response(for task: TerminalControlTask) throws -> TerminalAutomationHostResponse {
            switch self {
            case .acknowledged:
                .acknowledged(taskID: task.taskID, revision: task.revision)
            case .task:
                .task(task)
            case .snapshot:
                .snapshot(
                    try TerminalControlSnapshot(task: task, text: "", isTruncated: false)
                )
            }
        }

        func controlResponse(for task: TerminalControlTask) throws -> TerminalControlResponse {
            switch self {
            case .acknowledged:
                TerminalControlResponse(
                    result: .acknowledged(taskID: task.taskID, revision: task.revision)
                )
            case .task:
                TerminalControlResponse(result: .task(task))
            case .snapshot:
                TerminalControlResponse(
                    result: .snapshot(
                        try TerminalControlSnapshot(task: task, text: "", isTruncated: false)
                    )
                )
            }
        }
    }

    private enum HostTaskResponseShape: Int, CaseIterable, Sendable {
        case task
        case snapshot

        func response(for task: TerminalControlTask) throws -> TerminalAutomationHostResponse {
            switch self {
            case .task:
                .task(task)
            case .snapshot:
                .snapshot(
                    try TerminalControlSnapshot(task: task, text: "", isTruncated: false)
                )
            }
        }
    }

    private enum TaskMutationKind: Int, CaseIterable, Sendable {
        case sendText
        case sendKey
        case requestUserInput
        case focus
        case resize
        case interrupt
        case close

        func operation(taskID: UUID) -> TerminalControlRequest.Operation {
            switch self {
            case .sendText:
                .sendText(taskID: taskID, expectedRevision: 1, text: "input")
            case .sendKey:
                .sendKey(taskID: taskID, expectedRevision: 1, key: .enter)
            case .requestUserInput:
                .requestUserInput(taskID: taskID)
            case .focus:
                .focus(taskID: taskID)
            case .resize:
                .resize(taskID: taskID, ratio: 0.5)
            case .interrupt:
                .interrupt(taskID: taskID, expectedRevision: 1)
            case .close:
                .close(taskID: taskID)
            }
        }
    }

    private enum ReadTransition: Sendable {
        case rotatedCredentials
        case workspaceMoved
        case unregistered
    }

    private enum WaitTransition: Sendable {
        case cancelled
        case sessionReplaced
        case workspaceMoved
    }

    private enum SessionTransition: Sendable {
        case replacedSession
        case replacedAdapter
        case rotatedCredentials
        case unregistered
    }

    private enum StaleRevalidationTransition: Sendable {
        case replacement
        case unregistered
    }

    final class Lease: Sendable {
        private let active = Mutex(true)

        var isActive: Bool {
            get { active.withLock { $0 } }
            set { active.withLock { $0 = newValue } }
        }
    }
}

@MainActor
private final class FakeTerminalAutomationHost: TerminalAutomationHost {
    struct CreateTabCall: Equatable {
        let workspaceID: WorkspaceID
        let focus: Bool
        let expectedSession: TerminalAutomationSessionIdentity
    }

    struct CreateSplitCall: Equatable {
        let anchorPaneID: PaneID
        let workspaceID: WorkspaceID
        let direction: TerminalSplitDirection
        let ratio: Double
        let focus: Bool
        let expectedSession: TerminalAutomationSessionIdentity
    }

    struct DiscardCreatedTaskCall: Equatable {
        let created: TerminalAutomationCreatedTaskResponse
        let expectedSession: TerminalAutomationSessionIdentity
    }

    private struct OriginKey: Hashable {
        let instanceID: UUID
        let originPaneID: PaneID
    }

    var revokedSessions: [TerminalAutomationSessionIdentity] = []

    func acceptCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) {}

    func revokeSession(_ session: TerminalAutomationSessionIdentity) {
        revokedSessions.append(session)
    }

    var pendingMandatoryCloseTaskIDs: Set<UUID> = []
    var forgottenTaskIDs: [UUID] = []

    func canEvictTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) -> Bool {
        taskSessions[taskID] == expectedSession && !pendingMandatoryCloseTaskIDs.contains(taskID)
    }

    func forgetTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) {
        forgottenTaskIDs.append(taskID)
    }

    var promptCallCount = 0
    var presentations: [TerminalAutomationPresentationEvent] = []
    var attentions: [TerminalAutomationAttention] = []
    var createTabCalls: [CreateTabCall] = []
    var createSplitCalls: [CreateSplitCall] = []
    var discardCreatedTaskCalls: [DiscardCreatedTaskCall] = []
    var discardCreatedTaskSucceeds = true
    var sendTextCalls: [UUID] = []
    var sendKeyCalls: [UUID] = []
    var requestUserInputCalls: [UUID] = []
    var focusCalls: [UUID] = []
    var resizeCalls: [UUID] = []
    var interruptCalls: [UUID] = []
    var closeCalls: [UUID] = []
    var taskStates: [UUID: TerminalControlTask] = [:]
    private var taskSessions: [UUID: TerminalAutomationSessionIdentity] = [:]
    private var createdTasks: [UUID: TerminalAutomationCreatedTaskResponse] = [:]
    private var discardedCreatedTasks: [UUID: DiscardCreatedTaskCall] = [:]

    var taskMutationCallCount: Int {
        sendTextCalls.count + sendKeyCalls.count + requestUserInputCalls.count + focusCalls.count
            + resizeCalls.count + interruptCalls.count + closeCalls.count
    }
    var inspectTaskCallCount = 0
    var readCallCount = 0
    var resolveSessionCallCount = 0
    var createTabCancellationCount = 0

    private var resolvedSessions: [OriginKey: TerminalAutomationResolvedSession] = [:]
    private var queuedPromptDecisions: [TerminalAutomationPermissionDecision] = []
    private var nextPromptCallID: UInt64 = 0
    private var pendingPromptOrder: [UInt64] = []
    private var pendingPromptContinuations:
        [UInt64: CheckedContinuation<TerminalAutomationPermissionDecision, Never>] = [:]
    private var promptCancellationCount = 0
    private var promptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var promptCancellationWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resolveSessionWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var createTabResults: [TerminalAutomationHostResponse] = []
    private var createSplitResults: [TerminalAutomationHostResponse] = []
    private var generatedSplitResponseSequence = 0
    private var readResults: [TerminalAutomationHostResponse] = []
    private var mutationResults: [TerminalAutomationHostResponse] = []
    private var createTabPaused = false
    private var nextCreateTabPauseID: UInt64 = 0
    private var pendingCreateTabOrder: [UInt64] = []
    private var pendingCreateTabContinuations: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var readPaused = false
    private var pendingReadContinuations: [CheckedContinuation<Void, Never>] = []
    private var mutationPaused = false
    private var pendingMutationContinuations: [CheckedContinuation<Void, Never>] = []
    private var createTabWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
        []
    private var discardCreatedTaskWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var createTabCancellationWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var mutationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var inspectTaskWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
        []

    func setResolvedSession(_ session: TerminalAutomationResolvedSession) {
        resolvedSessions[
            OriginKey(
                instanceID: session.identity.instanceID, originPaneID: session.identity.originPaneID
            )] = session
    }

    func clearResolvedSession(instanceID: UUID, originPaneID: PaneID) {
        resolvedSessions.removeValue(
            forKey: OriginKey(instanceID: instanceID, originPaneID: originPaneID))
    }

    func currentResolvedSession(instanceID: UUID, originPaneID: PaneID)
        -> TerminalAutomationResolvedSession?
    {
        resolvedSessions[OriginKey(instanceID: instanceID, originPaneID: originPaneID)]
    }

    func enqueuePromptDecision(_ decision: TerminalAutomationPermissionDecision) {
        queuedPromptDecisions.append(decision)
    }

    func resumeNextPrompt(_ decision: TerminalAutomationPermissionDecision) {
        while let promptCallID = pendingPromptOrder.first {
            pendingPromptOrder.removeFirst()
            guard
                let continuation = pendingPromptContinuations.removeValue(
                    forKey: promptCallID)
            else {
                continue
            }
            continuation.resume(returning: decision)
            return
        }
    }

    func waitForPromptCalls(_ count: Int) async {
        await waitForCount(count) { promptCallCount }
    }

    func waitForPromptCancellations(_ count: Int) async {
        await waitForCount(count) { promptCancellationCount }
    }

    func waitForResolveSessionCalls(_ count: Int) async {
        await waitForCount(count) { resolveSessionCallCount }
    }

    func enqueueCreateTabResult(_ result: TerminalAutomationHostResponse) {
        if case .task(let task) = result {
            createTabResults.append(
                .createdTask(
                    TerminalAutomationCreatedTaskResponse(task: task, splitID: nil)
                )
            )
        } else {
            createTabResults.append(result)
        }
    }

    func enqueueCreateSplitResult(_ result: TerminalAutomationHostResponse) {
        if case .task(let task) = result {
            generatedSplitResponseSequence += 1
            createSplitResults.append(
                .createdTask(
                    TerminalAutomationCreatedTaskResponse(
                        task: task,
                        splitID: uuid(90_000 + generatedSplitResponseSequence)
                    )
                )
            )
        } else {
            createSplitResults.append(result)
        }
    }

    func enqueueReadResult(_ result: TerminalAutomationHostResponse) {
        readResults.append(result)
    }

    func enqueueMutationResult(_ result: TerminalAutomationHostResponse) {
        mutationResults.append(result)
    }

    func rebindTask(_ taskID: UUID, to session: TerminalAutomationSessionIdentity) {
        taskSessions[taskID] = session
    }

    func closeCreatedTask(_ taskID: UUID) {
        guard let created = createdTasks.removeValue(forKey: taskID) else {
            Issue.record("Expected a created host task to close")
            return
        }
        taskStates.removeValue(forKey: taskID)
        taskSessions.removeValue(forKey: taskID)
        discardedCreatedTasks.removeValue(forKey: taskID)
        let hasRemainingTaskInTab = taskStates.values.contains {
            $0.workspaceID == created.task.workspaceID && $0.tabID == created.task.tabID
        }
        // WHY: Closing a pane must not remove a tab that still hosts another live pane.
        updateWorkspaceSnapshots(for: created) { workspace, paneID, tabID in
            var paneIDs = workspace.paneIDs
            var tabIDs = workspace.tabIDs
            let removedPane = paneIDs.remove(paneID) != nil
            let removedTab =
                !hasRemainingTaskInTab
                && tabID != workspace.originTabID && tabIDs.remove(tabID) != nil
            let activeTabID =
                removedTab && workspace.activeTabID == tabID
                ? workspace.originTabID : workspace.activeTabID
            return TerminalAutomationWorkspaceContext(
                workspaceID: workspace.workspaceID,
                name: workspace.name,
                originTabID: workspace.originTabID,
                activeTabID: activeTabID,
                tabCount: workspace.tabCount - (removedTab ? 1 : 0),
                paneCount: workspace.paneCount - (removedPane ? 1 : 0),
                tabIDs: tabIDs,
                paneIDs: paneIDs
            )
        }
    }

    func pauseReadResponses() {
        readPaused = true
    }

    func resumeReadResponses() {
        readPaused = false
        let continuations = pendingReadContinuations
        pendingReadContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func pauseMutationResponses() {
        mutationPaused = true
    }

    func resumeMutationResponses() {
        mutationPaused = false
        let continuations = pendingMutationContinuations
        pendingMutationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func resumeLastMutationResponse() {
        guard let continuation = pendingMutationContinuations.popLast() else {
            if !waitFailed { Issue.record("No pending mutation response to resume") }
            return
        }
        continuation.resume()
    }

    func pauseCreateTabResponses() {
        createTabPaused = true
    }

    func resumeCreateTabResponses() {
        createTabPaused = false
        let pauseIDs = pendingCreateTabOrder
        pendingCreateTabOrder.removeAll()
        for pauseID in pauseIDs {
            guard
                let continuation = pendingCreateTabContinuations.removeValue(forKey: pauseID)
            else {
                continue
            }
            continuation.resume()
        }
    }

    private var waitFailed = false

    private func waitForCount(_ count: Int, observed: () -> Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while observed() < count && !waitFailed && !Task.isCancelled && clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                break
            }
        }
        guard observed() >= count else {
            Issue.record("Host event wait failed: expected \(count), observed \(observed())")
            abortPendingResponses()
            return
        }
    }

    private func abortPendingResponses() {
        waitFailed = true
        resolvedSessions.removeAll()
        for callID in pendingPromptOrder { cancelPrompt(callID) }
        resumeCreateTabResponses()
        resumeReadResponses()
        resumeMutationResponses()
    }

    private func responseWatchdog() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !waitFailed else { return }
            Issue.record("Fake host response was not released within five seconds")
            abortPendingResponses()
        }
    }

    func waitForCreateTabCalls(_ count: Int) async {
        await waitForCount(count) { createTabCalls.count }
    }

    func waitForCreateTabCancellations(_ count: Int) async {
        await waitForCount(count) { createTabCancellationCount }
    }

    func waitForDiscardCreatedTaskCalls(_ count: Int) async {
        await waitForCount(count) { discardCreatedTaskCalls.count }
    }

    func waitForInspectTaskCalls(_ count: Int) async {
        await waitForCount(count) { inspectTaskCallCount }
    }

    func waitForReadCalls(_ count: Int) async {
        await waitForCount(count) { readCallCount }
    }

    func waitForTaskMutationCalls(_ count: Int) async {
        await waitForCount(count) { taskMutationCallCount }
    }

    private func resumeCreateTabWaitersIfNeeded() {
        let ready = createTabWaiters.filter { createTabCalls.count >= $0.count }
        createTabWaiters.removeAll { createTabCalls.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeDiscardCreatedTaskWaitersIfNeeded() {
        let ready = discardCreatedTaskWaiters.filter {
            discardCreatedTaskCalls.count >= $0.count
        }
        discardCreatedTaskWaiters.removeAll { discardCreatedTaskCalls.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeInspectTaskWaitersIfNeeded() {
        let ready = inspectTaskWaiters.filter { inspectTaskCallCount >= $0.count }
        inspectTaskWaiters.removeAll { inspectTaskCallCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeReadWaitersIfNeeded() {
        let ready = readWaiters.filter { readCallCount >= $0.count }
        readWaiters.removeAll { readCallCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeMutationWaitersIfNeeded() {
        let ready = mutationWaiters.filter { taskMutationCallCount >= $0.count }
        mutationWaiters.removeAll { taskMutationCallCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func resolveAuthenticatedSession(
        instanceID: UUID,
        originPaneID: PaneID
    ) -> TerminalAutomationResolvedSession? {
        resolveSessionCallCount += 1
        resumeResolveSessionWaitersIfNeeded()
        return resolvedSessions[OriginKey(instanceID: instanceID, originPaneID: originPaneID)]
    }

    func presentPermission(
        for session: TerminalAutomationResolvedSession
    ) async -> TerminalAutomationPermissionDecision {
        guard !waitFailed else { return .unavailable }
        promptCallCount += 1
        nextPromptCallID &+= 1
        let promptCallID = nextPromptCallID
        presentations.append(.permissionPrompt(session.identity))
        resumePromptWaitersIfNeeded()
        if !queuedPromptDecisions.isEmpty {
            return queuedPromptDecisions.removeFirst()
        }
        let watchdog = responseWatchdog()
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                pendingPromptOrder.append(promptCallID)
                pendingPromptContinuations[promptCallID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPrompt(promptCallID)
            }
        }
    }

    func createTab(
        in workspaceID: WorkspaceID,
        launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        createTabCalls.append(
            CreateTabCall(workspaceID: workspaceID, focus: focus, expectedSession: expectedSession)
        )
        resumeCreateTabWaitersIfNeeded()
        guard !waitFailed else { return .failure(.cancelled) }
        let result = createTabResults.removeFirst()
        if createTabPaused {
            let watchdog = responseWatchdog()
            defer { watchdog.cancel() }
            nextCreateTabPauseID &+= 1
            let pauseID = nextCreateTabPauseID
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    pendingCreateTabOrder.append(pauseID)
                    pendingCreateTabContinuations[pauseID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelCreateTabResponse(pauseID)
                }
            }
        }
        register(result, expectedSession: expectedSession)
        return result
    }

    func createSplit(
        anchorPaneID: PaneID,
        in workspaceID: WorkspaceID,
        direction: TerminalSplitDirection,
        ratio: Double,
        launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        createSplitCalls.append(
            CreateSplitCall(
                anchorPaneID: anchorPaneID,
                workspaceID: workspaceID,
                direction: direction,
                ratio: ratio,
                focus: focus,
                expectedSession: expectedSession
            )
        )
        let result = createSplitResults.removeFirst()
        register(result, expectedSession: expectedSession)
        return result
    }

    func discardCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> Bool {
        let call = DiscardCreatedTaskCall(created: created, expectedSession: expectedSession)
        discardCreatedTaskCalls.append(call)
        resumeDiscardCreatedTaskWaitersIfNeeded()
        if discardedCreatedTasks[created.task.taskID] == call {
            return true
        }
        guard discardCreatedTaskSucceeds,
            createdTasks[created.task.taskID] == created,
            taskStates[created.task.taskID] == created.task,
            taskSessions[created.task.taskID] == expectedSession
        else {
            return false
        }
        createdTasks.removeValue(forKey: created.task.taskID)
        taskStates.removeValue(forKey: created.task.taskID)
        taskSessions.removeValue(forKey: created.task.taskID)
        discardedCreatedTasks[created.task.taskID] = call
        removeCreatedSurfaceFromWorkspaceSnapshot(created)
        return true
    }

    func inspectTask(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationTaskInspection {
        inspectTaskCallCount += 1
        resumeInspectTaskWaitersIfNeeded()
        guard let task = taskStates[taskID] else {
            return .notFound
        }
        guard taskSessions[taskID] == expectedSession else {
            return .notOwned
        }
        return .owned(task)
    }

    func read(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        readCallCount += 1
        resumeReadWaitersIfNeeded()
        guard taskStates[taskID] != nil else {
            return .failure(.targetNotFound)
        }
        guard taskSessions[taskID] == expectedSession else {
            return .failure(.targetNotOwned)
        }
        guard !readResults.isEmpty else {
            return .task(taskStates[taskID]!)
        }
        let result = readResults.removeFirst()
        if readPaused {
            let watchdog = responseWatchdog()
            defer { watchdog.cancel() }
            await withCheckedContinuation { continuation in
                pendingReadContinuations.append(continuation)
            }
        }
        guard taskStates[taskID] != nil else {
            return .failure(.targetNotFound)
        }
        guard taskSessions[taskID] == expectedSession else {
            return .failure(.targetNotOwned)
        }
        return result
    }

    func sendText(
        taskID: UUID,
        expectedRevision: UInt64,
        text: String,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        sendTextCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func sendKey(
        taskID: UUID,
        expectedRevision: UInt64,
        key: TerminalControlKey,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        sendKeyCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func requestUserInput(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        requestUserInputCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func focus(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        focusCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .acknowledged(taskID: taskID, revision: taskStates[taskID]?.revision ?? 0)
        )
    }

    func resize(
        taskID: UUID,
        ratio: Double,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        resizeCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func interrupt(
        taskID: UUID,
        expectedRevision: UInt64,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        interruptCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func requestClose(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity,
        context: TerminalControlRequestContext
    ) async -> TerminalAutomationHostResponse {
        closeCalls.append(taskID)
        return await nextMutationResult(
            taskID: taskID,
            expectedSession: expectedSession,
            or: .failure(.internalFailure)
        )
    }

    func publishPresentation(_ presentation: TerminalAutomationPresentationEvent) {
        presentations.append(presentation)
    }

    func publishAttention(_ attention: TerminalAutomationAttention) {
        attentions.append(attention)
    }

    private func nextMutationResult(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity,
        or fallback: TerminalAutomationHostResponse
    ) async -> TerminalAutomationHostResponse {
        let result = mutationResults.isEmpty ? fallback : mutationResults.removeFirst()
        resumeMutationWaitersIfNeeded()
        if mutationPaused {
            let watchdog = responseWatchdog()
            defer { watchdog.cancel() }
            await withCheckedContinuation { continuation in
                pendingMutationContinuations.append(continuation)
            }
        }
        guard taskStates[taskID] != nil else {
            return .failure(.targetNotFound)
        }
        guard taskSessions[taskID] == expectedSession else {
            return .failure(.targetNotOwned)
        }
        return result
    }

    private func register(
        _ result: TerminalAutomationHostResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) {
        switch result {
        case .createdTask(let created):
            taskStates[created.task.taskID] = created.task
            taskSessions[created.task.taskID] = expectedSession
            createdTasks[created.task.taskID] = created
            addCreatedSurfaceToWorkspaceSnapshot(created)
        case .task(let task):
            taskStates[task.taskID] = task
            taskSessions[task.taskID] = expectedSession
        case .snapshot(let snapshot):
            taskStates[snapshot.task.taskID] = snapshot.task
            taskSessions[snapshot.task.taskID] = expectedSession
        case .acknowledged, .failure:
            break
        }
    }

    private func addCreatedSurfaceToWorkspaceSnapshot(
        _ created: TerminalAutomationCreatedTaskResponse
    ) {
        updateWorkspaceSnapshots(for: created) { workspace, paneID, tabID in
            var paneIDs = workspace.paneIDs
            var tabIDs = workspace.tabIDs
            let addedPane = paneIDs.insert(paneID).inserted
            let addedTab = tabIDs.insert(tabID).inserted
            return TerminalAutomationWorkspaceContext(
                workspaceID: workspace.workspaceID,
                name: workspace.name,
                originTabID: workspace.originTabID,
                activeTabID: workspace.activeTabID,
                tabCount: workspace.tabCount + (addedTab ? 1 : 0),
                paneCount: workspace.paneCount + (addedPane ? 1 : 0),
                tabIDs: tabIDs,
                paneIDs: paneIDs
            )
        }
    }

    private func removeCreatedSurfaceFromWorkspaceSnapshot(
        _ created: TerminalAutomationCreatedTaskResponse
    ) {
        updateWorkspaceSnapshots(for: created) { workspace, paneID, tabID in
            var paneIDs = workspace.paneIDs
            var tabIDs = workspace.tabIDs
            let removedPane = paneIDs.remove(paneID) != nil
            let removesTab = created.splitID == nil && tabIDs.remove(tabID) != nil
            return TerminalAutomationWorkspaceContext(
                workspaceID: workspace.workspaceID,
                name: workspace.name,
                originTabID: workspace.originTabID,
                activeTabID: workspace.activeTabID,
                tabCount: workspace.tabCount - (removesTab ? 1 : 0),
                paneCount: workspace.paneCount - (removedPane ? 1 : 0),
                tabIDs: tabIDs,
                paneIDs: paneIDs
            )
        }
    }

    private func updateWorkspaceSnapshots(
        for created: TerminalAutomationCreatedTaskResponse,
        transform: (
            TerminalAutomationWorkspaceContext,
            PaneID,
            TabID
        ) -> TerminalAutomationWorkspaceContext
    ) {
        let workspaceID = WorkspaceID(rawValue: created.task.workspaceID)
        let paneID = PaneID(rawValue: created.task.paneID)
        let tabID = TabID(rawValue: created.task.tabID)
        for key in Array(resolvedSessions.keys) {
            guard let resolved = resolvedSessions[key],
                resolved.workspace.workspaceID == workspaceID
            else { continue }
            resolvedSessions[key] = TerminalAutomationResolvedSession(
                identity: resolved.identity,
                workspace: transform(resolved.workspace, paneID, tabID)
            )
        }
    }

    private func cancelCreateTabResponse(_ pauseID: UInt64) {
        guard
            let continuation = pendingCreateTabContinuations.removeValue(forKey: pauseID)
        else {
            return
        }
        pendingCreateTabOrder.removeAll { $0 == pauseID }
        continuation.resume()
        createTabCancellationCount += 1
        let ready = createTabCancellationWaiters.filter {
            createTabCancellationCount >= $0.count
        }
        createTabCancellationWaiters.removeAll { createTabCancellationCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func cancelPrompt(_ promptCallID: UInt64) {
        guard let continuation = pendingPromptContinuations.removeValue(forKey: promptCallID) else {
            return
        }
        pendingPromptOrder.removeAll { $0 == promptCallID }
        continuation.resume(returning: .unavailable)
        promptCancellationCount += 1
        let ready = promptCancellationWaiters.filter {
            promptCancellationCount >= $0.count
        }
        promptCancellationWaiters.removeAll { promptCancellationCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumePromptWaitersIfNeeded() {
        let ready = promptWaiters.filter { promptCallCount >= $0.count }
        promptWaiters.removeAll { promptCallCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeResolveSessionWaitersIfNeeded() {
        let ready = resolveSessionWaiters.filter { resolveSessionCallCount >= $0.count }
        resolveSessionWaiters.removeAll { resolveSessionCallCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class AutomationWaitClock {
    var now: TimeInterval = 0
    private var sleepCount = 0
    private var sleeping: CheckedContinuation<Void, Never>?
    private var waitFailed = false
    var hasPendingSleep: Bool { sleeping != nil }

    func sleep(for duration: Duration) async throws {
        #expect(duration <= .milliseconds(25))
        guard !waitFailed else { throw CancellationError() }
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, sleeping != nil else { return }
            Issue.record("Manual clock sleep was not released within five seconds")
            waitFailed = true
            advance(to: now)
        }
        defer { watchdog.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                sleeping = continuation
                sleepCount += 1
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                advance(to: now)
            }
        }
        try Task.checkCancellation()
        if waitFailed { throw CancellationError() }
    }

    func waitForSleeps(_ count: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while sleepCount < count && !Task.isCancelled && clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        if sleepCount < count {
            Issue.record("Manual clock wait failed: expected \(count), observed \(sleepCount)")
            waitFailed = true
            advance(to: now)
        }
    }

    func advance(to time: TimeInterval) {
        now = time
        let continuation = sleeping
        sleeping = nil
        continuation?.resume()
    }
}

private func context(_ lease: TerminalAutomationCoordinatorTests.Lease? = nil)
    -> TerminalControlRequestContext
{
    return TerminalControlRequestContext {
        lease?.isActive ?? true
    }
}

private func request(
    instanceID: UUID,
    originPaneID: PaneID,
    request: TerminalControlRequest
) -> TerminalControlSocketRequest {
    TerminalControlSocketRequest(
        instanceID: instanceID,
        paneID: originPaneID.rawValue,
        request: request
    )
}

private func resolvedSession(
    instanceID: UUID = uuid(1),
    originPaneID: PaneID,
    adapterID: String = "claude",
    sessionID: String = "session-1",
    paneCredentialGeneration: UInt64 = 1,
    workspaceID: WorkspaceID = WorkspaceID(rawValue: uuid(2)),
    name: String = "Main",
    originTabID: TabID = TabID(rawValue: uuid(3)),
    activeTabID: TabID = TabID(rawValue: uuid(3)),
    tabCount: Int = 1,
    paneCount: Int = 1,
    tabIDs: Set<TabID>? = nil,
    paneIDs: Set<PaneID>? = nil
) -> TerminalAutomationResolvedSession {
    TerminalAutomationResolvedSession(
        identity: TerminalAutomationSessionIdentity(
            instanceID: instanceID,
            originPaneID: originPaneID,
            adapterID: try! AgentAdapterID(rawValue: adapterID),
            sessionID: sessionID,
            paneCredentialGeneration: paneCredentialGeneration
        ),
        workspace: TerminalAutomationWorkspaceContext(
            workspaceID: workspaceID,
            name: name,
            originTabID: originTabID,
            activeTabID: activeTabID,
            tabCount: tabCount,
            paneCount: paneCount,
            tabIDs: tabIDs ?? [originTabID, activeTabID],
            paneIDs: paneIDs ?? [originPaneID]
        )
    )
}

private func launch() throws -> TerminalControlLaunch {
    try TerminalControlLaunch(
        executable: "/usr/bin/env",
        arguments: ["swift", "test"],
        cwd: "/tmp/project"
    )
}

private func task(
    taskID: UUID,
    paneID: UUID,
    tabID: UUID,
    workspaceID: UUID,
    state: TerminalTaskState,
    owner: TerminalPaneControlOwner = .agent,
    policy: TerminalTaskLifecyclePolicy = .keep,
    revision: UInt64 = 1,
    exitCode: Int32? = nil
) -> TerminalControlTask {
    TerminalControlTask(
        taskID: taskID,
        paneID: paneID,
        tabID: tabID,
        workspaceID: workspaceID,
        state: state,
        owner: owner,
        policy: policy,
        revision: revision,
        exitCode: exitCode
    )
}

private func expectFailure(
    _ response: TerminalControlResponse,
    code: TerminalControlErrorCode
) {
    guard case .failure(let error) = response.result else {
        Issue.record("Expected failure response")
        return
    }
    #expect(error.code == code)
}

private func expectList(
    _ response: TerminalControlResponse,
    workspaceID: UUID,
    taskIDs: [UUID]
) {
    guard case .list(let workspace, let tasks) = response.result else {
        Issue.record("Expected list response")
        return
    }
    #expect(workspace.workspaceID == workspaceID)
    #expect(tasks.map(\.taskID) == taskIDs)
}

private func listTaskIDs(in response: TerminalControlResponse) -> [UUID] {
    guard case .list(_, let tasks) = response.result else {
        Issue.record("Expected list response")
        return []
    }
    return tasks.map(\.taskID)
}

private func taskRevision(in response: TerminalControlResponse, taskID: UUID) -> UInt64? {
    guard case .list(_, let tasks) = response.result else {
        Issue.record("Expected list response")
        return nil
    }
    return tasks.first(where: { $0.taskID == taskID })?.revision
}

private func listedTask(
    in response: TerminalControlResponse,
    taskID: UUID
) -> TerminalControlTask? {
    guard case .list(_, let tasks) = response.result else {
        Issue.record("Expected list response")
        return nil
    }
    return tasks.first(where: { $0.taskID == taskID })
}

private func taskID(in response: TerminalControlResponse) -> UUID? {
    guard case .task(let task) = response.result else { return nil }
    return task.taskID
}

private func paneID(_ value: Int) -> PaneID {
    PaneID(rawValue: uuid(value))
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
