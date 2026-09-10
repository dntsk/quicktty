import CryptoKit
import Foundation

@MainActor
final class TerminalAutomationCoordinator {
    private enum GrantState {
        case unknown
        case pending(generation: UInt64, task: Task<TerminalAutomationPermissionDecision, Never>)
        case allowed
        case denied
        case revoked
    }

    private struct GrantRecord {
        var state: GrantState = .unknown
        var generation: UInt64 = 0
    }

    private struct TaskRecord {
        let createdSequence: UInt64
        let createdSplitID: UUID?
        var task: TerminalControlTask
    }

    private struct ReplayRecord {
        let requestDigest: Data
        let response: TerminalControlResponse
    }

    private struct PendingMutationRecord {
        let requestDigest: Data
        let lifecycleGeneration: UInt64
        let task: Task<TerminalControlResponse, Never>
    }

    private struct SessionRecord {
        var grant = GrantRecord()
        var lifecycleGeneration: UInt64 = 0
        var taskOrder: [UUID] = []
        var tasks: [UUID: TaskRecord] = [:]
        // WHY: Replay state is lifecycle-bounded because revocation replaces the session record.
        var replays: [UUID: ReplayRecord] = [:]
        var pendingMutationOrder: [UUID] = []
        var pendingMutations: [UUID: PendingMutationRecord] = [:]
        var pendingCreateReservations = 0
        var pendingWaitTaskIDs: Set<UUID> = []
        var ownedTabIDs: Set<TabID> = []
        var ownedPaneIDs: Set<PaneID> = []
        var createdSplitIDs: Set<UUID> = []
    }

    private struct OriginKey: Hashable {
        let instanceID: UUID
        let originPaneID: PaneID
    }

    private enum PermissionOutcome {
        case allowed(TerminalAutomationResolvedSession)
        case failure(TerminalControlResponse)
    }

    private enum TaskLookup {
        case task(TerminalControlTask)
        case notFound
        case notOwned
    }

    private static let maximumPendingMutationCount = 32
    private static let maximumRevokedSessionCount = 32

    private let host: any TerminalAutomationHost
    private let waitNow: @MainActor () -> TimeInterval
    private let waitSleep: @MainActor (Duration) async throws -> Void

    private var nextSequence: UInt64 = 0
    private var latestSessionByOrigin: [OriginKey: TerminalAutomationSessionIdentity] = [:]
    private var sessions: [TerminalAutomationSessionIdentity: SessionRecord] = [:]
    // WHY: Exact retired identity membership intentionally prioritizes fail-accurate
    // authorization over probabilistic bounded storage.
    private var retiredSessionIdentities: Set<TerminalAutomationSessionIdentity> = []
    private var revokedSessionOrder: [TerminalAutomationSessionIdentity] = []
    private var taskOwners: [UUID: TerminalAutomationSessionIdentity] = [:]
    private var paneOwners: [PaneID: TerminalAutomationSessionIdentity] = [:]
    private var tabOwners: [TabID: TerminalAutomationSessionIdentity] = [:]
    private var splitOwners: [UUID: TerminalAutomationSessionIdentity] = [:]

    init(
        host: any TerminalAutomationHost,
        waitNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        waitSleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.host = host
        self.waitNow = waitNow
        self.waitSleep = waitSleep
    }

    func originSessionDidChange(originPaneID: PaneID) {
        let origins = latestSessionByOrigin.keys.filter { $0.originPaneID == originPaneID }
        for origin in origins {
            if let previous = latestSessionByOrigin.removeValue(forKey: origin) {
                revokeGrant(for: previous)
            }
        }
    }

    func cancelPendingPermissions() {
        for session in Array(sessions.keys) {
            guard var record = sessions[session], case .pending(_, let task) = record.grant.state
            else {
                continue
            }
            // WHY: A sheet can have completed while its async caller still waits to apply the grant.
            record.grant.state = .unknown
            record.grant.generation = nextStateSequence()
            sessions[session] = record
            task.cancel()
        }
    }

    func currentGrantedTask(
        taskID: UUID, session: TerminalAutomationSessionIdentity
    ) -> TerminalControlTask? {
        // WHY: Host acceptance is not authorization; direct host creation never establishes a grant.
        guard !retiredSessionIdentities.contains(session),
            let record = sessions[session], case .allowed = record.grant.state,
            let resolved = revalidateSession(
                instanceID: session.instanceID, originPaneID: session.originPaneID,
                expected: session),
            case .task(let task) = currentTask(
                taskID: taskID, for: session,
                currentWorkspaceID: resolved.workspace.workspaceID.rawValue)
        else { return nil }
        return task
    }

    func hasPendingHostCreation(for session: TerminalAutomationSessionIdentity) -> Bool {
        (sessions[session]?.pendingCreateReservations ?? 0) > 0
    }

    func canEvictHostTask(taskID: UUID, session: TerminalAutomationSessionIdentity) -> Bool {
        sessions[session]?.pendingWaitTaskIDs.contains(taskID) != true
    }

    func retainsSessionRecordForTesting(
        _ session: TerminalAutomationSessionIdentity
    ) -> Bool {
        sessions[session] != nil
    }

    func pendingMutationCountForTesting(
        _ session: TerminalAutomationSessionIdentity
    ) -> Int {
        sessions[session]?.pendingMutations.count ?? 0
    }

    func pendingCreateReservationCountForTesting(
        _ session: TerminalAutomationSessionIdentity
    ) -> Int {
        sessions[session]?.pendingCreateReservations ?? 0
    }

    func ownedSplitIDsForTesting(
        _ session: TerminalAutomationSessionIdentity
    ) -> Set<UUID> {
        sessions[session]?.createdSplitIDs ?? []
    }

    func handle(
        _ authenticatedRequest: TerminalControlSocketRequest,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        guard let resolved = resolveSession(for: authenticatedRequest) else {
            return failure(.invalidSession)
        }

        let request = authenticatedRequest.request
        let requestDigest: Data?
        do {
            requestDigest = request.requestID == nil ? nil : try canonicalDigest(for: request)
        } catch {
            return failure(.invalidRequest)
        }

        switch request.operation {
        case .list:
            return await handleList(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                context: context
            )
        case .createTab(let launch, let policy, let focus):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .createTab(launch: launch, policy: policy, focus: focus)
            )
        case .split(let anchorPaneID, let direction, let ratio, let launch, let policy, let focus):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .split(
                    anchorPaneID: anchorPaneID,
                    direction: direction,
                    ratio: ratio,
                    launch: launch,
                    policy: policy,
                    focus: focus
                )
            )
        case .read(let taskID):
            return await handleRead(
                taskID: taskID,
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                context: context
            )
        case .wait(let taskID, let revision, let timeoutMilliseconds):
            return await handleWait(
                taskID: taskID,
                revision: revision,
                timeoutMilliseconds: timeoutMilliseconds,
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                context: context
            )
        case .sendText(let taskID, let expectedRevision, let text):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .sendText(
                    taskID: taskID,
                    expectedRevision: expectedRevision,
                    text: text
                )
            )
        case .sendKey(let taskID, let expectedRevision, let key):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .sendKey(
                    taskID: taskID,
                    expectedRevision: expectedRevision,
                    key: key
                )
            )
        case .requestUserInput(let taskID):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .requestUserInput(taskID: taskID)
            )
        case .focus(let taskID):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .focus(taskID: taskID)
            )
        case .resize(let taskID, let ratio):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .resize(taskID: taskID, ratio: ratio)
            )
        case .interrupt(let taskID, let expectedRevision):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .interrupt(taskID: taskID, expectedRevision: expectedRevision)
            )
        case .close(let taskID):
            return await handleMutation(
                authenticatedRequest: authenticatedRequest,
                resolved: resolved,
                requestDigest: requestDigest,
                context: context,
                operation: .close(taskID: taskID)
            )
        }
    }

    private func handleList(
        authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        switch await ensurePermission(
            for: authenticatedRequest,
            resolved: resolved,
            context: context
        ) {
        case .failure(let response):
            return response
        case .allowed(let current):
            refreshTasks(
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            )
            guard let metadata = workspaceMetadata(for: current) else {
                return failure(.internalFailure)
            }
            let tasks = retainedTasks(
                for: current.identity,
                workspaceID: current.workspace.workspaceID.rawValue
            )
            return TerminalControlResponse(result: .list(workspace: metadata, tasks: tasks))
        }
    }

    private func handleRead(
        taskID: UUID,
        authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        switch await ensurePermission(
            for: authenticatedRequest,
            resolved: resolved,
            context: context
        ) {
        case .failure(let response):
            return response
        case .allowed(let current):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                let startingWorkspaceID = current.workspace.workspaceID.rawValue
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let hostResponse = await host.read(
                    taskID: taskID,
                    expectedSession: latest.identity
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(from: hostResponse)
                guard
                    applyReadResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }
        }
    }

    private func handleWait<T: BinaryInteger>(
        taskID: UUID,
        revision: UInt64,
        timeoutMilliseconds: T,
        authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        switch await ensurePermission(
            for: authenticatedRequest,
            resolved: resolved,
            context: context
        ) {
        case .failure(let response):
            return response
        case .allowed(let current):
            guard context.isActive else {
                return failure(.cancelled)
            }
            let startingWorkspaceID = current.workspace.workspaceID.rawValue
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: startingWorkspaceID
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let task):
                if task.revision != revision || task.state.isTerminal || task.owner != .agent {
                    return TerminalControlResponse(result: .task(task))
                }
                guard reserveWait(for: current.identity, taskID: taskID) else {
                    return failure(.resourceLimit)
                }
                defer {
                    releaseWait(for: current.identity, taskID: taskID)
                }
                let deadline = waitNow() + Double(Int(timeoutMilliseconds)) / 1_000
                var nextRefresh = waitNow()
                while true {
                    guard context.isActive, !Task.isCancelled else {
                        return failure(.cancelled)
                    }
                    guard
                        let latest = revalidateSession(
                            authenticatedRequest, expected: current.identity),
                        latest.workspace.workspaceID.rawValue == startingWorkspaceID
                    else {
                        return failure(.staleSession)
                    }
                    if waitNow() >= deadline {
                        return failure(.timeout)
                    }
                    if waitNow() >= nextRefresh {
                        guard
                            case .task(let expectedTask) = currentTask(
                                taskID: taskID, for: latest.identity,
                                currentWorkspaceID: startingWorkspaceID
                            )
                        else {
                            return failure(.targetNotOwned)
                        }
                        // WHY: Completion is authoritative even if its final capture failed;
                        // a waiter must not turn that lifecycle change into a retry read error.
                        if expectedTask.revision != revision || expectedTask.state.isTerminal
                            || expectedTask.owner != .agent
                        {
                            return TerminalControlResponse(result: .task(expectedTask))
                        }
                        let refreshed = response(
                            from: await host.read(
                                taskID: taskID, expectedSession: latest.identity
                            ))
                        nextRefresh = waitNow() + 0.25
                        guard context.isActive, !Task.isCancelled else {
                            return failure(.cancelled)
                        }
                        guard
                            let final = revalidateSession(
                                authenticatedRequest, expected: latest.identity),
                            final.workspace.workspaceID.rawValue == startingWorkspaceID
                        else { return failure(.staleSession) }
                        guard waitNow() < deadline else { return failure(.timeout) }
                        guard
                            applyReadResponse(
                                refreshed, to: latest.identity,
                                expectedTask: expectedTask, expectedWorkspaceID: startingWorkspaceID
                            )
                        else { return failure(.internalFailure) }
                        if case .failure = refreshed.result { return refreshed }
                    }
                    switch currentTask(
                        taskID: taskID,
                        for: latest.identity,
                        currentWorkspaceID: latest.workspace.workspaceID.rawValue
                    ) {
                    case .notFound:
                        return failure(.targetNotFound)
                    case .notOwned:
                        return failure(.targetNotOwned)
                    case .task(let task):
                        if task.revision != revision || task.state.isTerminal
                            || task.owner != .agent
                        {
                            return TerminalControlResponse(result: .task(task))
                        }
                    }
                    if waitNow() >= deadline {
                        return failure(.timeout)
                    }
                    do {
                        try await waitSleep(.seconds(min(0.025, max(0, deadline - waitNow()))))
                    } catch {
                        return failure(.cancelled)
                    }
                }
            }
        }
    }

    private func handleMutation(
        authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        requestDigest: Data?,
        context: TerminalControlRequestContext,
        operation: TerminalControlRequest.Operation
    ) async -> TerminalControlResponse {
        guard let requestID = authenticatedRequest.request.requestID,
            let requestDigest
        else {
            return failure(.invalidRequest)
        }

        let initialRecord = sessionRecord(for: resolved.identity)
        let lifecycleGeneration = initialRecord.lifecycleGeneration
        if case .revoked = initialRecord.grant.state {
            return failure(.permissionRevoked)
        }
        if let replay = replayResponse(
            for: resolved.identity,
            requestID: requestID,
            requestDigest: requestDigest
        ) {
            return replay
        }

        switch await ensurePermission(
            for: authenticatedRequest,
            resolved: resolved,
            context: context
        ) {
        case .failure(let permissionFailure):
            if let replay = replayResponse(
                for: resolved.identity,
                requestID: requestID,
                requestDigest: requestDigest
            ) {
                return replay
            }
            return storeReplayIfNeeded(
                permissionFailure,
                requestID: requestID,
                requestDigest: requestDigest,
                session: resolved.identity,
                expectedLifecycleGeneration: lifecycleGeneration
            )
        case .allowed(let current):
            if let replay = replayResponse(
                for: current.identity,
                requestID: requestID,
                requestDigest: requestDigest
            ) {
                return replay
            }
            if let pending = pendingMutation(for: current.identity, requestID: requestID) {
                guard pending.requestDigest == requestDigest else {
                    return failure(.requestIDConflict)
                }
                return await waitForMutation(
                    session: current.identity,
                    requestID: requestID,
                    requestDigest: requestDigest,
                    context: context
                )
            }
            guard let record = sessions[current.identity],
                record.lifecycleGeneration == lifecycleGeneration
            else {
                return failure(.staleSession)
            }
            if record.pendingMutations.count >= Self.maximumPendingMutationCount {
                return storeReplayIfNeeded(
                    failure(.resourceLimit),
                    requestID: requestID,
                    requestDigest: requestDigest,
                    session: current.identity,
                    expectedLifecycleGeneration: lifecycleGeneration
                )
            }

            let task = Task {
                @MainActor [
                    authenticatedRequest, current, requestID, requestDigest, operation, context
                ] in
                await self.performMutation(
                    authenticatedRequest: authenticatedRequest,
                    resolved: current,
                    lifecycleGeneration: lifecycleGeneration,
                    requestID: requestID,
                    requestDigest: requestDigest,
                    operation: operation,
                    context: context
                )
            }
            storePendingMutation(
                task,
                requestID: requestID,
                requestDigest: requestDigest,
                lifecycleGeneration: lifecycleGeneration,
                session: current.identity
            )
            if case .close = operation {
                // WHY: Only the originating close owns host cancellation; duplicate waiters
                // must not cancel shared work, and irreversible creates retain their result.
                return await withTaskCancellationHandler {
                    await waitForMutation(
                        session: current.identity,
                        requestID: requestID,
                        requestDigest: requestDigest,
                        context: context
                    )
                } onCancel: {
                    task.cancel()
                }
            }
            return await waitForMutation(
                session: current.identity,
                requestID: requestID,
                requestDigest: requestDigest,
                context: context
            )
        }
    }

    private func waitForMutation(
        session: TerminalAutomationSessionIdentity,
        requestID: UUID,
        requestDigest: Data,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        guard context.isActive, !Task.isCancelled else {
            return failure(.cancelled)
        }
        if let replay = replayResponse(
            for: session,
            requestID: requestID,
            requestDigest: requestDigest
        ) {
            return replay
        }
        guard let initialRecord = sessions[session] else {
            return failure(
                retiredSessionIdentities.contains(session) ? .permissionRevoked : .staleSession
            )
        }
        if case .revoked = initialRecord.grant.state {
            return failure(.permissionRevoked)
        }
        guard !retiredSessionIdentities.contains(session) else {
            return failure(.permissionRevoked)
        }
        guard
            let initialPending = initialRecord.pendingMutations[requestID],
            initialPending.requestDigest == requestDigest
        else {
            return failure(.staleSession)
        }
        let lifecycleGeneration = initialPending.lifecycleGeneration

        while true {
            guard context.isActive, !Task.isCancelled else {
                return failure(.cancelled)
            }
            if let replay = replayResponse(
                for: session,
                requestID: requestID,
                requestDigest: requestDigest
            ) {
                return replay
            }
            guard let record = sessions[session] else {
                return failure(
                    retiredSessionIdentities.contains(session) ? .permissionRevoked : .staleSession
                )
            }
            if case .revoked = record.grant.state {
                return failure(.permissionRevoked)
            }
            guard !retiredSessionIdentities.contains(session) else {
                return failure(.permissionRevoked)
            }
            guard record.lifecycleGeneration == lifecycleGeneration else {
                return failure(.staleSession)
            }
            guard let pending = record.pendingMutations[requestID] else {
                return failure(.staleSession)
            }
            guard pending.requestDigest == requestDigest else {
                return failure(.requestIDConflict)
            }
            guard pending.lifecycleGeneration == lifecycleGeneration else {
                return failure(.staleSession)
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return failure(.cancelled)
            }
        }
    }

    private func performMutation(
        authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        lifecycleGeneration: UInt64,
        requestID: UUID,
        requestDigest: Data,
        operation: TerminalControlRequest.Operation,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        defer {
            removePendingMutation(
                for: resolved.identity,
                requestID: requestID,
                requestDigest: requestDigest,
                lifecycleGeneration: lifecycleGeneration
            )
        }

        let requiresCreateReservation: Bool
        switch operation {
        case .createTab, .split:
            requiresCreateReservation = true
        case .list, .read, .wait, .sendText, .sendKey, .requestUserInput, .focus, .resize,
            .interrupt, .close:
            requiresCreateReservation = false
        }

        if requiresCreateReservation {
            refreshTasks(
                for: resolved.identity, currentWorkspaceID: resolved.workspace.workspaceID.rawValue)
        }
        let response: TerminalControlResponse
        if requiresCreateReservation && !reserveCreateResources(for: resolved.identity) {
            response = failure(.resourceLimit)
        } else {
            response = await executeMutation(
                authenticatedRequest: authenticatedRequest,
                session: resolved.identity,
                operation: operation,
                context: context,
                reservedCreateResources: requiresCreateReservation
            )
        }
        return storeReplayIfNeeded(
            response,
            requestID: requestID,
            requestDigest: requestDigest,
            session: resolved.identity,
            expectedLifecycleGeneration: lifecycleGeneration
        )
    }

    private func executeMutation(
        authenticatedRequest: TerminalControlSocketRequest,
        session: TerminalAutomationSessionIdentity,
        operation: TerminalControlRequest.Operation,
        context: TerminalControlRequestContext,
        reservedCreateResources: Bool
    ) async -> TerminalControlResponse {
        defer {
            if reservedCreateResources {
                releaseCreateReservation(for: session)
            }
        }

        guard context.isActive, !Task.isCancelled else {
            return failure(.cancelled)
        }
        guard let current = revalidateSession(authenticatedRequest, expected: session) else {
            return failure(.staleSession)
        }
        let startingWorkspaceID = current.workspace.workspaceID.rawValue

        switch operation {
        case .createTab(let launch, let policy, let focus):
            guard isValidCreateCapacity(for: current.identity) else {
                return failure(.resourceLimit)
            }
            guard let latest = revalidateSession(authenticatedRequest, expected: current.identity),
                latest.workspace.workspaceID.rawValue == startingWorkspaceID
            else {
                return failure(.staleSession)
            }
            let creationSnapshot = latest.workspace
            let hostResponse = await host.createTab(
                in: latest.workspace.workspaceID,
                launch: launch,
                policy: policy,
                focus: focus,
                expectedSession: latest.identity
            )
            let response = response(fromCreate: hostResponse)
            guard !Task.isCancelled else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .cancelled
                )
            }
            guard let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                final.workspace.workspaceID.rawValue == startingWorkspaceID
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .staleSession
                )
            }
            guard
                isValidCreatedTabResponse(
                    hostResponse,
                    initialWorkspace: creationSnapshot,
                    finalWorkspace: final.workspace,
                    session: final.identity
                )
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .internalFailure
                )
            }
            guard
                applyHostResponse(
                    hostResponse,
                    to: final.identity,
                    expectsSplitID: false,
                    expectedWorkspaceID: startingWorkspaceID,
                    expectedPolicy: policy
                )
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .internalFailure
                )
            }
            return response

        case .split(let anchorPaneID, let direction, let ratio, let launch, let policy, let focus):
            let anchor = PaneID(rawValue: anchorPaneID ?? current.identity.originPaneID.rawValue)
            guard isValidAnchor(anchor, for: current) else {
                return failure(.targetNotOwned)
            }
            guard isValidCreateCapacity(for: current.identity) else {
                return failure(.resourceLimit)
            }
            guard let latest = revalidateSession(authenticatedRequest, expected: current.identity),
                latest.workspace.workspaceID.rawValue == startingWorkspaceID,
                let expectedAnchorTabID = anchorTabID(anchor, for: latest)
            else {
                return failure(.staleSession)
            }
            let creationSnapshot = latest.workspace
            let hostResponse = await host.createSplit(
                anchorPaneID: anchor,
                in: latest.workspace.workspaceID,
                direction: direction,
                ratio: ratio,
                launch: launch,
                policy: policy,
                focus: focus,
                expectedSession: latest.identity
            )
            let response = response(fromCreate: hostResponse)
            guard !Task.isCancelled else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .cancelled
                )
            }
            guard let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                final.workspace.workspaceID.rawValue == startingWorkspaceID,
                anchorTabID(anchor, for: final) == expectedAnchorTabID
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .staleSession
                )
            }
            guard
                isValidCreatedSplitResponse(
                    hostResponse,
                    anchorPaneID: anchor,
                    anchorTabID: expectedAnchorTabID,
                    initialWorkspace: creationSnapshot,
                    finalWorkspace: final.workspace,
                    session: final.identity
                )
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .internalFailure
                )
            }
            guard
                applyHostResponse(
                    hostResponse,
                    to: final.identity,
                    expectsSplitID: true,
                    expectedWorkspaceID: startingWorkspaceID,
                    expectedPolicy: policy
                )
            else {
                return await failureAfterCompensatingCreatedTask(
                    in: hostResponse,
                    session: latest.identity,
                    preferredCode: .internalFailure
                )
            }
            return response

        case .sendText(let taskID, let expectedRevision, let text):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.sendText(
                        taskID: taskID,
                        expectedRevision: expectedRevision,
                        text: text,
                        expectedSession: latest.identity
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .sendKey(let taskID, let expectedRevision, let key):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.sendKey(
                        taskID: taskID,
                        expectedRevision: expectedRevision,
                        key: key,
                        expectedSession: latest.identity
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .requestUserInput(let taskID):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.requestUserInput(
                        taskID: taskID,
                        expectedSession: latest.identity
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                if let validatedTaskID = successfulTaskID(in: response) {
                    host.publishPresentation(.taskRequiresPresentation(validatedTaskID))
                    host.publishAttention(.taskRequiresAttention(validatedTaskID))
                }
                return response
            }

        case .focus(let taskID):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.focus(taskID: taskID, expectedSession: latest.identity)
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .resize(let taskID, let ratio):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.resize(
                        taskID: taskID,
                        ratio: ratio,
                        expectedSession: latest.identity
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .interrupt(let taskID, let expectedRevision):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.interrupt(
                        taskID: taskID,
                        expectedRevision: expectedRevision,
                        expectedSession: latest.identity
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .close(let taskID):
            switch currentTask(
                taskID: taskID,
                for: current.identity,
                currentWorkspaceID: current.workspace.workspaceID.rawValue
            ) {
            case .notFound:
                return failure(.targetNotFound)
            case .notOwned:
                return failure(.targetNotOwned)
            case .task(let expectedTask):
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let latest = revalidateSession(
                        authenticatedRequest, expected: current.identity),
                    latest.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                let response = response(
                    from: await host.requestClose(
                        taskID: taskID,
                        expectedSession: latest.identity,
                        context: context
                    )
                )
                guard context.isActive, !Task.isCancelled else {
                    return failure(.cancelled)
                }
                guard
                    let final = revalidateSession(authenticatedRequest, expected: latest.identity),
                    final.workspace.workspaceID.rawValue == startingWorkspaceID
                else {
                    return failure(.staleSession)
                }
                guard
                    applyTaskMutationResponse(
                        response,
                        to: final.identity,
                        expectedTask: expectedTask,
                        expectedWorkspaceID: startingWorkspaceID
                    )
                else {
                    return failure(.internalFailure)
                }
                return response
            }

        case .list, .read, .wait:
            return failure(.invalidRequest)
        }
    }

    private func pendingMutation(
        for session: TerminalAutomationSessionIdentity,
        requestID: UUID
    ) -> PendingMutationRecord? {
        sessions[session]?.pendingMutations[requestID]
    }

    private func storePendingMutation(
        _ task: Task<TerminalControlResponse, Never>,
        requestID: UUID,
        requestDigest: Data,
        lifecycleGeneration: UInt64,
        session: TerminalAutomationSessionIdentity
    ) {
        guard var record = sessions[session],
            record.lifecycleGeneration == lifecycleGeneration
        else {
            task.cancel()
            return
        }
        record.pendingMutationOrder.removeAll { $0 == requestID }
        record.pendingMutationOrder.append(requestID)
        record.pendingMutations[requestID] = PendingMutationRecord(
            requestDigest: requestDigest,
            lifecycleGeneration: lifecycleGeneration,
            task: task
        )
        sessions[session] = record
    }

    private func removePendingMutation(
        for session: TerminalAutomationSessionIdentity,
        requestID: UUID,
        requestDigest: Data,
        lifecycleGeneration: UInt64
    ) {
        guard var record = sessions[session],
            let pending = record.pendingMutations[requestID],
            pending.requestDigest == requestDigest,
            pending.lifecycleGeneration == lifecycleGeneration
        else {
            return
        }
        let isRevoked: Bool
        if case .revoked = record.grant.state {
            isRevoked = true
        } else {
            isRevoked = false
        }
        guard record.lifecycleGeneration == lifecycleGeneration || isRevoked else {
            return
        }
        record.pendingMutations.removeValue(forKey: requestID)
        record.pendingMutationOrder.removeAll { $0 == requestID }
        sessions[session] = record
        cleanupRevokedSessions()
    }

    private func isValidCreateCapacity(for session: TerminalAutomationSessionIdentity) -> Bool {
        guard let record = sessions[session] else {
            return false
        }
        return runningTaskCount(for: record) + record.pendingCreateReservations <= 8
    }

    private func reserveCreateResources(for session: TerminalAutomationSessionIdentity) -> Bool {
        guard var record = sessions[session] else {
            return false
        }
        guard runningTaskCount(for: record) + record.pendingCreateReservations < 8 else {
            return false
        }

        let reservedRetainedCount = record.tasks.count + record.pendingCreateReservations + 1
        let requiredTerminalSlots = max(
            0,
            reservedRetainedCount - TerminalControlLimits.maximumRetainedTaskCount
        )
        let availableTerminalSlots = record.taskOrder.reduce(into: 0) { count, taskID in
            guard let taskRecord = record.tasks[taskID],
                taskRecord.task.state.isTerminal,
                !record.pendingWaitTaskIDs.contains(taskID),
                host.canEvictTask(taskID: taskID, expectedSession: session)
            else {
                return
            }
            count += 1
        }
        guard availableTerminalSlots >= requiredTerminalSlots else {
            return false
        }

        record.pendingCreateReservations += 1
        sessions[session] = record
        return true
    }

    private func releaseCreateReservation(for session: TerminalAutomationSessionIdentity) {
        guard var record = sessions[session], record.pendingCreateReservations > 0 else {
            return
        }
        record.pendingCreateReservations -= 1
        sessions[session] = record
        cleanupRevokedSessions()
    }

    private func reserveWait(for session: TerminalAutomationSessionIdentity, taskID: UUID) -> Bool {
        guard var record = sessions[session] else {
            return false
        }
        guard record.pendingWaitTaskIDs.insert(taskID).inserted else {
            sessions[session] = record
            return false
        }
        sessions[session] = record
        return true
    }

    private func releaseWait(for session: TerminalAutomationSessionIdentity, taskID: UUID) {
        guard var record = sessions[session] else {
            return
        }
        record.pendingWaitTaskIDs.remove(taskID)
        sessions[session] = record
        cleanupRevokedSessions()
    }

    private func runningTaskCount(for record: SessionRecord) -> Int {
        record.tasks.values.reduce(into: 0) { count, taskRecord in
            if taskRecord.task.state.isActive {
                count += 1
            }
        }
    }

    private func canRegisterTask(
        _ task: TerminalControlTask,
        for session: TerminalAutomationSessionIdentity,
        createdSplitID: UUID?,
        expectedWorkspaceID: UUID?
    ) -> Bool {
        if let expectedWorkspaceID, task.workspaceID != expectedWorkspaceID {
            return false
        }
        if let owner = taskOwners[task.taskID], owner != session {
            return false
        }
        let paneID = PaneID(rawValue: task.paneID)
        if let owner = paneOwners[paneID], owner != session {
            return false
        }
        let tabID = TabID(rawValue: task.tabID)
        if let owner = tabOwners[tabID], owner != session {
            return false
        }
        if let createdSplitID, splitOwners[createdSplitID] != nil {
            return false
        }
        if createdSplitID == nil,
            sessions.values.contains(where: { record in
                record.tasks.values.contains { $0.task.tabID == task.tabID }
            })
        {
            return false
        }
        if let record = sessions[session],
            record.tasks.values.contains(where: {
                $0.task.taskID != task.taskID && $0.task.paneID == task.paneID
            })
        {
            return false
        }
        if let existing = sessions[session]?.tasks[task.taskID]?.task,
            existing.paneID != task.paneID || existing.tabID != task.tabID
                || existing.workspaceID != task.workspaceID
        {
            return false
        }
        return true
    }

    private func ensurePermission(
        for authenticatedRequest: TerminalControlSocketRequest,
        resolved: TerminalAutomationResolvedSession,
        context: TerminalControlRequestContext
    ) async -> PermissionOutcome {
        guard context.isActive, !Task.isCancelled else {
            return .failure(failure(.cancelled))
        }

        let session = resolved.identity
        let grant = sessionRecord(for: session).grant
        switch grant.state {
        case .allowed:
            guard let current = revalidateSession(authenticatedRequest, expected: session) else {
                return .failure(failure(.staleSession))
            }
            return .allowed(current)

        case .denied:
            return .failure(failure(.permissionDenied))

        case .revoked:
            return .failure(failure(.permissionRevoked))

        case .unknown:
            let generation = nextStateSequence()
            let task = Task { @MainActor [host, resolved] in
                let decision = await host.presentPermission(for: resolved)
                guard !Task.isCancelled else {
                    return decision
                }
                self.applyPermissionDecision(decision, generation: generation, for: session)
                return decision
            }
            var record = sessionRecord(for: session)
            record.grant.state = .pending(generation: generation, task: task)
            record.grant.generation = generation
            sessions[session] = record
            host.publishPresentation(.permissionPrompt(session))
            return await resolvePermission(
                for: authenticatedRequest,
                session: session,
                generation: generation,
                context: context
            )

        case .pending(let generation, _):
            return await resolvePermission(
                for: authenticatedRequest,
                session: session,
                generation: generation,
                context: context
            )
        }
    }

    private func resolvePermission(
        for authenticatedRequest: TerminalControlSocketRequest,
        session: TerminalAutomationSessionIdentity,
        generation: UInt64,
        context: TerminalControlRequestContext
    ) async -> PermissionOutcome {
        while true {
            guard context.isActive, !Task.isCancelled else {
                return .failure(failure(.cancelled))
            }
            guard let current = revalidateSession(authenticatedRequest, expected: session) else {
                return .failure(failure(.staleSession))
            }

            let grant = sessionRecord(for: session).grant
            if grant.generation != generation {
                if case .revoked = grant.state { return .failure(failure(.permissionRevoked)) }
                // WHY: A cancelled cohort cannot join a replacement prompt on another parent window.
                return .failure(failure(.permissionUnavailable))
            }
            switch grant.state {
            case .allowed:
                return .allowed(current)
            case .denied:
                return .failure(failure(.permissionDenied))
            case .revoked:
                return .failure(failure(.permissionRevoked))
            case .unknown:
                return .failure(failure(.permissionUnavailable))
            case .pending:
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return .failure(failure(.cancelled))
                }
            }
        }
    }

    private func applyPermissionDecision(
        _ decision: TerminalAutomationPermissionDecision,
        generation: UInt64,
        for session: TerminalAutomationSessionIdentity
    ) {
        guard
            revalidateSession(
                instanceID: session.instanceID,
                originPaneID: session.originPaneID,
                expected: session
            ) != nil
        else {
            return
        }
        guard var record = sessions[session],
            case .pending(let currentGeneration, _) = record.grant.state,
            currentGeneration == generation
        else {
            return
        }
        switch decision {
        case .allowed:
            record.grant.state = .allowed
        case .denied:
            record.grant.state = .denied
        case .unavailable:
            record.grant.state = .unknown
        }
        sessions[session] = record
        // WHY: Attention can synchronously revoke the session; never write the old record afterward.
        if case .denied = decision {
            host.publishAttention(.permissionDenied(session))
        }
    }

    private func resolveSession(
        for authenticatedRequest: TerminalControlSocketRequest
    ) -> TerminalAutomationResolvedSession? {
        let originPaneID = PaneID(rawValue: authenticatedRequest.paneID)
        let originKey = OriginKey(
            instanceID: authenticatedRequest.instanceID,
            originPaneID: originPaneID
        )
        guard
            let resolved = host.resolveAuthenticatedSession(
                instanceID: authenticatedRequest.instanceID,
                originPaneID: originPaneID
            )
        else {
            if let previous = latestSessionByOrigin.removeValue(forKey: originKey) {
                revokeGrant(for: previous)
            }
            cleanupRevokedSessions()
            return nil
        }
        if let previous = latestSessionByOrigin[originKey], previous != resolved.identity {
            revokeGrant(for: previous)
        }
        latestSessionByOrigin[originKey] = resolved.identity
        cleanupRevokedSessions()
        _ = sessionRecord(for: resolved.identity)
        return resolved
    }

    private func revalidateSession(
        _ authenticatedRequest: TerminalControlSocketRequest,
        expected: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationResolvedSession? {
        revalidateSession(
            instanceID: authenticatedRequest.instanceID,
            originPaneID: PaneID(rawValue: authenticatedRequest.paneID),
            expected: expected
        )
    }

    private func revalidateSession(
        instanceID: UUID,
        originPaneID: PaneID,
        expected: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationResolvedSession? {
        let originKey = OriginKey(instanceID: instanceID, originPaneID: originPaneID)
        let tracked = latestSessionByOrigin[originKey]
        guard
            let current = host.resolveAuthenticatedSession(
                instanceID: instanceID,
                originPaneID: originPaneID
            )
        else {
            if let tracked {
                revokeGrant(for: tracked)
            }
            if tracked != expected {
                revokeGrant(for: expected)
            }
            latestSessionByOrigin.removeValue(forKey: originKey)
            cleanupRevokedSessions()
            return nil
        }
        if current.identity != expected {
            if let tracked, tracked != expected, tracked != current.identity {
                revokeGrant(for: tracked)
            }
            revokeGrant(for: expected)
            latestSessionByOrigin[originKey] = current.identity
            cleanupRevokedSessions()
            return nil
        }
        if let tracked, tracked != current.identity {
            revokeGrant(for: tracked)
        }
        latestSessionByOrigin[originKey] = current.identity
        cleanupRevokedSessions()
        return current
    }

    private func currentTask(
        taskID: UUID,
        for session: TerminalAutomationSessionIdentity,
        currentWorkspaceID: UUID
    ) -> TaskLookup {
        if let owner = taskOwners[taskID], owner != session {
            return .notOwned
        }
        guard var record = sessions[session], let stored = record.tasks[taskID] else {
            return .notOwned
        }

        let inspected: TerminalControlTask
        switch host.inspectTask(taskID: taskID, expectedSession: session) {
        case .owned(let task):
            inspected = task
        case .notFound:
            removeTask(taskID, from: &record, session: session)
            sessions[session] = record
            rebuildOwnership(for: session)
            return .notFound
        case .notOwned:
            removeTask(taskID, from: &record, session: session)
            sessions[session] = record
            rebuildOwnership(for: session)
            return .notOwned
        }

        let paneID = PaneID(rawValue: inspected.paneID)
        let tabID = TabID(rawValue: inspected.tabID)
        guard inspected.taskID == stored.task.taskID,
            paneID == PaneID(rawValue: stored.task.paneID),
            tabID == TabID(rawValue: stored.task.tabID),
            hasValidOwnership(stored, taskID: taskID, session: session),
            inspected.workspaceID == currentWorkspaceID,
            inspected.policy == stored.task.policy
        else {
            removeTask(taskID, from: &record, session: session)
            sessions[session] = record
            rebuildOwnership(for: session)
            return .notOwned
        }

        if isValidTaskLifecycleTransition(from: stored.task, to: inspected) {
            updateTask(inspected, for: session)
            return .task(inspected)
        }
        return .task(stored.task)
    }

    private func isValidAnchor(
        _ paneID: PaneID,
        for resolved: TerminalAutomationResolvedSession
    ) -> Bool {
        anchorTabID(paneID, for: resolved) != nil
    }

    private func anchorTabID(
        _ paneID: PaneID,
        for resolved: TerminalAutomationResolvedSession
    ) -> TabID? {
        if paneID == resolved.identity.originPaneID {
            return resolved.workspace.originTabID
        }
        guard let session = sessions[resolved.identity],
            session.ownedPaneIDs.contains(paneID),
            paneOwners[paneID] == resolved.identity,
            let taskID = session.taskOrder.first(where: {
                session.tasks[$0]?.task.paneID == paneID.rawValue
            }),
            case .task(let task) = currentTask(
                taskID: taskID,
                for: resolved.identity,
                currentWorkspaceID: resolved.workspace.workspaceID.rawValue
            )
        else {
            return nil
        }
        return TabID(rawValue: task.tabID)
    }

    private func refreshTasks(
        for session: TerminalAutomationSessionIdentity,
        currentWorkspaceID: UUID
    ) {
        guard var record = sessions[session] else { return }
        let taskIDs = record.taskOrder
        for taskID in taskIDs {
            guard let stored = record.tasks[taskID],
                stored.task.workspaceID == currentWorkspaceID
            else {
                removeTask(taskID, from: &record, session: session)
                continue
            }

            let inspected: TerminalControlTask
            switch host.inspectTask(taskID: taskID, expectedSession: session) {
            case .owned(let task):
                inspected = task
            case .notFound, .notOwned:
                removeTask(taskID, from: &record, session: session)
                continue
            }
            guard inspected.taskID == stored.task.taskID,
                inspected.paneID == stored.task.paneID,
                inspected.tabID == stored.task.tabID,
                inspected.workspaceID == currentWorkspaceID,
                inspected.policy == stored.task.policy
            else {
                removeTask(taskID, from: &record, session: session)
                continue
            }
            if isValidTaskLifecycleTransition(from: stored.task, to: inspected) {
                record.tasks[taskID]?.task = inspected
            }
        }
        sessions[session] = record
        trimRetainedTasks(for: session)
    }

    private func retainedTasks(for session: TerminalAutomationSessionIdentity, workspaceID: UUID)
        -> [TerminalControlTask]
    {
        let record = sessionRecord(for: session)
        return record.taskOrder.compactMap { taskID in
            guard let task = record.tasks[taskID]?.task,
                task.workspaceID == workspaceID
            else {
                return nil
            }
            return task
        }
    }

    private func activeTaskCount(for session: TerminalAutomationSessionIdentity) -> Int {
        sessionRecord(for: session).tasks.values.reduce(into: 0) { count, record in
            if record.task.state.isActive {
                count += 1
            }
        }
    }

    private func canRetainAdditionalTask(for session: TerminalAutomationSessionIdentity) -> Bool {
        trimRetainedTasks(for: session, maximumRetainedCount: 31)
        return sessionRecord(for: session).tasks.count
            < TerminalControlLimits.maximumRetainedTaskCount
    }

    private func trimRetainedTasks(
        for session: TerminalAutomationSessionIdentity,
        maximumRetainedCount: Int = TerminalControlLimits.maximumRetainedTaskCount
    ) {
        guard var record = sessions[session] else { return }
        while record.tasks.count > maximumRetainedCount {
            guard
                let evictedTaskID = record.taskOrder.first(where: {
                    guard let taskRecord = record.tasks[$0] else { return false }
                    return taskRecord.task.state.isTerminal
                        && !record.pendingWaitTaskIDs.contains($0)
                        && host.canEvictTask(taskID: $0, expectedSession: session)
                })
            else {
                break
            }
            removeTask(evictedTaskID, from: &record, session: session)
        }
        sessions[session] = record
        rebuildOwnership(for: session)
    }

    private func updateTask(
        _ task: TerminalControlTask, for session: TerminalAutomationSessionIdentity
    ) {
        guard var record = sessions[session], let existing = record.tasks[task.taskID],
            isValidTaskLifecycleTransition(from: existing.task, to: task)
        else {
            return
        }
        record.tasks[task.taskID] = TaskRecord(
            createdSequence: existing.createdSequence,
            createdSplitID: existing.createdSplitID,
            task: task
        )
        sessions[session] = record
    }

    private func isValidTaskLifecycleTransition(
        from current: TerminalControlTask,
        to candidate: TerminalControlTask
    ) -> Bool {
        guard candidate.revision >= current.revision else {
            return false
        }
        if candidate.revision == current.revision {
            return candidate == current
        }
        return !(current.state.isTerminal && candidate.state.isActive)
    }

    private func applyReadResponse(
        _ response: TerminalControlResponse,
        to session: TerminalAutomationSessionIdentity,
        expectedTask: TerminalControlTask,
        expectedWorkspaceID: UUID
    ) -> Bool {
        switch response.result {
        case .task(let task):
            guard
                canApplyTaskUpdate(
                    task,
                    to: session,
                    expectedTask: expectedTask,
                    expectedWorkspaceID: expectedWorkspaceID
                )
            else {
                return false
            }
            updateTask(task, for: session)
            return true
        case .snapshot(let snapshot):
            guard
                canApplyTaskUpdate(
                    snapshot.task,
                    to: session,
                    expectedTask: expectedTask,
                    expectedWorkspaceID: expectedWorkspaceID
                )
            else {
                return false
            }
            updateTask(snapshot.task, for: session)
            return true
        case .failure(let error):
            reconcileTaskAfterHostFailure(
                error.code,
                session: session,
                expectedTask: expectedTask
            )
            return true
        case .acknowledged, .list:
            return false
        }
    }

    private func applyTaskMutationResponse(
        _ response: TerminalControlResponse,
        to session: TerminalAutomationSessionIdentity,
        expectedTask: TerminalControlTask,
        expectedWorkspaceID: UUID
    ) -> Bool {
        if case .failure(let error) = response.result {
            reconcileTaskAfterHostFailure(
                error.code,
                session: session,
                expectedTask: expectedTask
            )
            return true
        }
        guard var record = sessions[session],
            let existing = record.tasks[expectedTask.taskID]
        else {
            return false
        }

        let updatedTask: TerminalControlTask
        switch response.result {
        case .task(let task):
            updatedTask = task
        case .snapshot(let snapshot):
            updatedTask = snapshot.task
        case .acknowledged(let taskID, let revision):
            guard taskID == expectedTask.taskID else {
                return false
            }
            let task = existing.task
            updatedTask = TerminalControlTask(
                taskID: task.taskID,
                paneID: task.paneID,
                tabID: task.tabID,
                workspaceID: task.workspaceID,
                state: task.state,
                owner: task.owner,
                policy: task.policy,
                revision: revision,
                exitCode: task.exitCode
            )
        case .list, .failure:
            return false
        }

        guard
            canApplyTaskUpdate(
                updatedTask,
                to: session,
                expectedTask: expectedTask,
                expectedWorkspaceID: expectedWorkspaceID
            )
        else {
            return false
        }
        record.tasks[expectedTask.taskID] = TaskRecord(
            createdSequence: existing.createdSequence,
            createdSplitID: existing.createdSplitID,
            task: updatedTask
        )
        sessions[session] = record
        return true
    }

    private func canApplyTaskUpdate(
        _ task: TerminalControlTask,
        to session: TerminalAutomationSessionIdentity,
        expectedTask: TerminalControlTask,
        expectedWorkspaceID: UUID
    ) -> Bool {
        guard expectedTask.workspaceID == expectedWorkspaceID,
            let record = sessions[session],
            case .allowed = record.grant.state,
            let current = record.tasks[expectedTask.taskID]?.task,
            current.taskID == expectedTask.taskID,
            current.paneID == expectedTask.paneID,
            current.tabID == expectedTask.tabID,
            current.workspaceID == expectedTask.workspaceID,
            task.taskID == expectedTask.taskID,
            task.paneID == expectedTask.paneID,
            task.tabID == expectedTask.tabID,
            task.workspaceID == expectedWorkspaceID,
            expectedTask.policy == current.policy,
            task.policy == current.policy,
            let taskRecord = record.tasks[expectedTask.taskID],
            hasValidOwnership(
                taskRecord,
                taskID: expectedTask.taskID,
                session: session
            ),
            current.revision >= expectedTask.revision,
            isValidTaskLifecycleTransition(from: current, to: task)
        else {
            return false
        }
        return true
    }

    private func reconcileTaskAfterHostFailure(
        _ code: TerminalControlErrorCode,
        session: TerminalAutomationSessionIdentity,
        expectedTask: TerminalControlTask
    ) {
        guard code == .targetNotFound || code == .targetNotOwned,
            var record = sessions[session],
            record.tasks[expectedTask.taskID]?.task == expectedTask
        else {
            return
        }
        removeTask(expectedTask.taskID, from: &record, session: session)
        sessions[session] = record
        rebuildOwnership(for: session)
    }

    private func isValidCreatedTabResponse(
        _ response: TerminalAutomationHostResponse,
        initialWorkspace: TerminalAutomationWorkspaceContext,
        finalWorkspace: TerminalAutomationWorkspaceContext,
        session: TerminalAutomationSessionIdentity
    ) -> Bool {
        guard case .createdTask(let created) = response else { return true }
        let paneID = PaneID(rawValue: created.task.paneID)
        let tabID = TabID(rawValue: created.task.tabID)
        return paneID != session.originPaneID
            && !initialWorkspace.paneIDs.contains(paneID)
            && tabID != initialWorkspace.originTabID
            && tabID != initialWorkspace.activeTabID
            && !initialWorkspace.tabIDs.contains(tabID)
            && finalWorkspace.paneIDs.contains(paneID)
            && finalWorkspace.tabIDs.contains(tabID)
    }

    private func isValidCreatedSplitResponse(
        _ response: TerminalAutomationHostResponse,
        anchorPaneID: PaneID,
        anchorTabID: TabID,
        initialWorkspace: TerminalAutomationWorkspaceContext,
        finalWorkspace: TerminalAutomationWorkspaceContext,
        session: TerminalAutomationSessionIdentity
    ) -> Bool {
        guard case .createdTask(let created) = response else { return true }
        let paneID = PaneID(rawValue: created.task.paneID)
        return paneID != anchorPaneID
            && paneID != session.originPaneID
            && !initialWorkspace.paneIDs.contains(paneID)
            && created.task.tabID == anchorTabID.rawValue
            && finalWorkspace.paneIDs.contains(paneID)
            && finalWorkspace.tabIDs.contains(anchorTabID)
    }

    private func applyHostResponse(
        _ response: TerminalAutomationHostResponse,
        to session: TerminalAutomationSessionIdentity,
        expectsSplitID: Bool,
        expectedWorkspaceID: UUID? = nil,
        expectedPolicy: TerminalTaskLifecyclePolicy
    ) -> Bool {
        guard let record = sessions[session], case .allowed = record.grant.state else {
            return false
        }
        switch response {
        case .createdTask(let created):
            guard (created.splitID != nil) == expectsSplitID,
                sessions[session]?.tasks[created.task.taskID] == nil
            else {
                return false
            }
            let registered = registerTask(
                created.task,
                for: session,
                createdSplitID: created.splitID,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedPolicy: expectedPolicy
            )
            if registered {
                host.acceptCreatedTask(created, expectedSession: session)
            }
            return registered
        case .failure:
            return true
        case .task, .snapshot, .acknowledged:
            return false
        }
    }

    private func registerTask(
        _ task: TerminalControlTask,
        for session: TerminalAutomationSessionIdentity,
        createdSplitID: UUID?,
        expectedWorkspaceID: UUID? = nil,
        expectedPolicy: TerminalTaskLifecyclePolicy
    ) -> Bool {
        guard task.policy == expectedPolicy,
            canRegisterTask(
                task,
                for: session,
                createdSplitID: createdSplitID,
                expectedWorkspaceID: expectedWorkspaceID
            ),
            var record = sessions[session],
            record.pendingCreateReservations > 0,
            runningTaskCount(for: record) + record.pendingCreateReservations <= 8
        else {
            return false
        }

        let requiredTerminalSlots = max(
            0,
            record.tasks.count + 1 - TerminalControlLimits.maximumRetainedTaskCount
        )
        var evictedTaskIDs: [UUID] = []
        if requiredTerminalSlots > 0 {
            for taskID in record.taskOrder {
                guard let taskRecord = record.tasks[taskID],
                    taskRecord.task.state.isTerminal,
                    !record.pendingWaitTaskIDs.contains(taskID),
                    host.canEvictTask(taskID: taskID, expectedSession: session)
                else {
                    continue
                }
                evictedTaskIDs.append(taskID)
                if evictedTaskIDs.count == requiredTerminalSlots {
                    break
                }
            }
        }
        guard evictedTaskIDs.count == requiredTerminalSlots else {
            return false
        }

        for taskID in evictedTaskIDs {
            host.forgetTask(taskID: taskID, expectedSession: session)
            record.tasks.removeValue(forKey: taskID)
            record.taskOrder.removeAll { $0 == taskID }
            record.pendingWaitTaskIDs.remove(taskID)
        }
        record.taskOrder.append(task.taskID)
        record.tasks[task.taskID] = TaskRecord(
            createdSequence: nextStateSequence(),
            createdSplitID: createdSplitID,
            task: task
        )
        sessions[session] = record
        rebuildOwnership(for: session)
        return true
    }

    private func rebuildOwnership(for session: TerminalAutomationSessionIdentity) {
        guard var record = sessions[session] else { return }
        record.ownedPaneIDs = []
        record.createdSplitIDs = []
        let representedTabIDs = Set(
            record.tasks.values.map {
                TabID(rawValue: $0.task.tabID)
            })
        record.ownedTabIDs.formIntersection(representedTabIDs)

        var activeTaskIDs = Set<UUID>()
        for taskID in record.taskOrder {
            guard let taskRecord = record.tasks[taskID] else { continue }
            let paneID = PaneID(rawValue: taskRecord.task.paneID)
            let tabID = TabID(rawValue: taskRecord.task.tabID)
            record.ownedPaneIDs.insert(paneID)
            if let createdSplitID = taskRecord.createdSplitID {
                record.createdSplitIDs.insert(createdSplitID)
            } else {
                record.ownedTabIDs.insert(tabID)
            }
            activeTaskIDs.insert(taskID)
        }
        sessions[session] = record

        taskOwners = taskOwners.filter { _, owner in owner != session }
        paneOwners = paneOwners.filter { _, owner in owner != session }
        tabOwners = tabOwners.filter { _, owner in owner != session }
        splitOwners = splitOwners.filter { _, owner in owner != session }

        for taskID in activeTaskIDs {
            taskOwners[taskID] = session
        }
        for paneID in record.ownedPaneIDs {
            paneOwners[paneID] = session
        }
        for tabID in record.ownedTabIDs {
            tabOwners[tabID] = session
        }
        for splitID in record.createdSplitIDs {
            splitOwners[splitID] = session
        }
    }

    private func hasValidOwnership(
        _ record: TaskRecord,
        taskID: UUID,
        session: TerminalAutomationSessionIdentity
    ) -> Bool {
        guard taskOwners[taskID] == session,
            paneOwners[PaneID(rawValue: record.task.paneID)] == session
        else {
            return false
        }
        if let splitID = record.createdSplitID {
            return splitOwners[splitID] == session
        }
        return tabOwners[TabID(rawValue: record.task.tabID)] == session
    }

    private func failureAfterCompensatingCreatedTask(
        in response: TerminalAutomationHostResponse,
        session: TerminalAutomationSessionIdentity,
        preferredCode: TerminalControlErrorCode
    ) async -> TerminalControlResponse {
        guard await compensateCreatedTask(in: response, session: session) else {
            return failure(.internalFailure)
        }
        return failure(preferredCode)
    }

    private func compensateCreatedTask(
        in response: TerminalAutomationHostResponse,
        session: TerminalAutomationSessionIdentity
    ) async -> Bool {
        guard case .createdTask(let created) = response else { return true }
        return await host.discardCreatedTask(created, expectedSession: session)
    }

    private func removeTask(
        _ taskID: UUID,
        from record: inout SessionRecord,
        session: TerminalAutomationSessionIdentity
    ) {
        host.forgetTask(taskID: taskID, expectedSession: session)
        record.tasks.removeValue(forKey: taskID)
        record.taskOrder.removeAll { $0 == taskID }
        record.pendingWaitTaskIDs.remove(taskID)
        taskOwners.removeValue(forKey: taskID)
    }

    private func replayResponse(
        for session: TerminalAutomationSessionIdentity,
        requestID: UUID,
        requestDigest: Data
    ) -> TerminalControlResponse? {
        guard let record = sessions[session] else {
            return nil
        }
        if case .revoked = record.grant.state {
            return nil
        }
        guard let replay = record.replays[requestID] else {
            return nil
        }
        guard replay.requestDigest == requestDigest else {
            return failure(.requestIDConflict)
        }
        return replay.response
    }

    private func storeReplayIfNeeded(
        _ response: TerminalControlResponse,
        requestID: UUID,
        requestDigest: Data,
        session: TerminalAutomationSessionIdentity,
        expectedLifecycleGeneration: UInt64
    ) -> TerminalControlResponse {
        guard var record = sessions[session],
            record.lifecycleGeneration == expectedLifecycleGeneration
        else {
            return response
        }
        if case .revoked = record.grant.state {
            return response
        }

        if let existing = record.replays[requestID] {
            guard existing.requestDigest == requestDigest else {
                return failure(.requestIDConflict)
            }
            return existing.response
        }

        record.replays[requestID] = ReplayRecord(
            requestDigest: requestDigest,
            response: response
        )
        sessions[session] = record
        return response
    }

    private func revokeGrant(for session: TerminalAutomationSessionIdentity) {
        let existing = sessionRecord(for: session)
        retiredSessionIdentities.insert(session)
        if case .revoked = existing.grant.state {
            return
        }
        host.revokeSession(session)
        if case .pending(_, let task) = existing.grant.state {
            task.cancel()
        }
        for pending in existing.pendingMutations.values {
            pending.task.cancel()
        }

        var record = SessionRecord()
        record.lifecycleGeneration = nextStateSequence()
        record.grant.generation = nextStateSequence()
        record.grant.state = .revoked
        sessions[session] = record
        revokedSessionOrder.removeAll { $0 == session }
        revokedSessionOrder.append(session)
        taskOwners = taskOwners.filter { _, owner in owner != session }
        paneOwners = paneOwners.filter { _, owner in owner != session }
        tabOwners = tabOwners.filter { _, owner in owner != session }
        splitOwners = splitOwners.filter { _, owner in owner != session }
        cleanupRevokedSessions()
    }

    private func cleanupRevokedSessions() {
        while revokedSessionOrder.count > Self.maximumRevokedSessionCount {
            guard
                let index = revokedSessionOrder.firstIndex(where: { session in
                    guard !latestSessionByOrigin.values.contains(session),
                        let record = sessions[session],
                        case .revoked = record.grant.state
                    else {
                        return false
                    }
                    return record.pendingMutations.isEmpty
                        && record.pendingCreateReservations == 0
                        && record.pendingWaitTaskIDs.isEmpty
                })
            else {
                return
            }
            let session = revokedSessionOrder.remove(at: index)
            sessions.removeValue(forKey: session)
        }
    }

    private func sessionRecord(for session: TerminalAutomationSessionIdentity) -> SessionRecord {
        if let record = sessions[session] {
            return record
        }
        guard retiredSessionIdentities.contains(session) else {
            return SessionRecord()
        }
        var tombstone = SessionRecord()
        tombstone.grant.state = .revoked
        return tombstone
    }

    private func nextStateSequence() -> UInt64 {
        nextSequence &+= 1
        return nextSequence
    }

    private func canonicalDigest(for request: TerminalControlRequest) throws -> Data {
        Data(SHA256.hash(data: try TerminalControlProtocol.encodeRequest(request)))
    }

    private func workspaceMetadata(
        for resolved: TerminalAutomationResolvedSession
    ) -> TerminalControlWorkspaceMetadata? {
        try? TerminalControlWorkspaceMetadata(
            workspaceID: resolved.workspace.workspaceID.rawValue,
            name: resolved.workspace.name,
            originPaneID: resolved.identity.originPaneID.rawValue,
            activeTabID: resolved.workspace.activeTabID.rawValue,
            tabCount: resolved.workspace.tabCount,
            paneCount: resolved.workspace.paneCount
        )
    }

    private func successfulTaskID(in response: TerminalControlResponse) -> UUID? {
        switch response.result {
        case .task(let task):
            task.taskID
        case .snapshot(let snapshot):
            snapshot.task.taskID
        case .acknowledged(let taskID, _):
            taskID
        case .list, .failure:
            nil
        }
    }

    private func response(fromCreate hostResponse: TerminalAutomationHostResponse)
        -> TerminalControlResponse
    {
        switch hostResponse {
        case .createdTask(let created):
            TerminalControlResponse(result: .task(created.task))
        case .failure(let code):
            failure(code)
        case .task, .snapshot, .acknowledged:
            failure(.internalFailure)
        }
    }

    private func response(from hostResponse: TerminalAutomationHostResponse)
        -> TerminalControlResponse
    {
        switch hostResponse {
        case .createdTask:
            failure(.internalFailure)
        case .task(let task):
            TerminalControlResponse(result: .task(task))
        case .snapshot(let snapshot):
            TerminalControlResponse(result: .snapshot(snapshot))
        case .acknowledged(let taskID, let revision):
            TerminalControlResponse(result: .acknowledged(taskID: taskID, revision: revision))
        case .failure(let code):
            failure(code)
        }
    }

    private func failure(_ code: TerminalControlErrorCode) -> TerminalControlResponse {
        TerminalControlResponse(
            result: .failure(
                try! TerminalControlError(code: code, message: message(for: code))
            )
        )
    }

    private func message(for code: TerminalControlErrorCode) -> String {
        switch code {
        case .permissionRequired:
            "Terminal permission is required"
        case .permissionDenied:
            "Terminal permission was denied"
        case .permissionRevoked:
            "Terminal permission was revoked"
        case .permissionUnavailable:
            "Terminal permission is unavailable"
        case .invalidSession:
            "Terminal session is unavailable"
        case .staleSession:
            "Terminal session changed"
        case .targetNotFound:
            "Task was not found"
        case .targetNotOwned:
            "Target is not owned"
        case .staleTerminalRevision:
            "Terminal revision is stale"
        case .userControlsPane:
            "User controls this pane"
        case .processFinished:
            "Process already finished"
        case .resourceLimit:
            "Terminal resource limit was reached"
        case .invalidLaunchRequest:
            "Launch request is invalid"
        case .invalidRequest:
            "Request is invalid"
        case .requestIDConflict:
            "Request ID conflicts with a different request"
        case .surfaceCreationFailed:
            "Failed to create terminal surface"
        case .modelMutationFailed:
            "Failed to update terminal model"
        case .closeConfirmationDenied:
            "Close request was denied"
        case .timeout:
            "Terminal control request timed out"
        case .cancelled:
            "Terminal control request was cancelled"
        case .internalFailure:
            "Terminal control request failed"
        }
    }
}

extension TerminalTaskState {
    fileprivate var isActive: Bool {
        switch self {
        case .creating, .running, .waitingForUser:
            true
        case .succeeded, .failed, .finishedUnknown, .cancelled:
            false
        }
    }

    fileprivate var isTerminal: Bool {
        !isActive
    }
}
