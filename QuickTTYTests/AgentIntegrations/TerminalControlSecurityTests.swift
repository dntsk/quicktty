import Foundation
import Testing

@testable import QuickTTY

@MainActor
struct TerminalControlSecurityTests {
    @Test
    func runningCapRejectsBeforeCreationAndReplayCannotSpendAnotherSlot() async throws {
        let host = SecurityHostSpy()
        let session = try host.addSession(origin: 1, workspace: 10)
        let coordinator = TerminalAutomationCoordinator(host: host)
        var tasks: [TerminalControlTask] = []
        for _ in 0..<8 {
            tasks.append(try await createTask(coordinator, session: session))
        }
        #expect(host.created.count == 8)
        #expect(try await listedTasks(coordinator, session: session) == tasks)
        let before = host.tasks
        let calls = host.effects
        let ninth = try createRequest()
        let rejected = await send(ninth, to: coordinator, session: session)
        expectFailure(rejected, .resourceLimit)
        #expect(host.effects == calls)
        #expect(host.tasks == before)
        #expect(coordinator.pendingCreateReservationCountForTesting(session) == 0)

        // WHY: A rejected request has a stable replay too; freeing capacity must not execute it.
        host.finish(tasks[0])
        let afterCompletion = host.tasks
        #expect(await send(ninth, to: coordinator, session: session) == rejected)
        #expect(host.tasks == afterCompletion)
        #expect(host.effects == calls)
        let conflicting = try TerminalControlRequest(
            operation: .createTab(launch: launch(), policy: .keep, focus: true),
            requestID: ninth.requestID)
        expectFailure(
            await send(conflicting, to: coordinator, session: session), .requestIDConflict)
        #expect(host.effects == calls)
        #expect(host.tasks == afterCompletion)
        #expect(host.tasks[tasks[0].taskID]?.state == .succeeded)

        let fresh = try createRequest()
        let accepted = await send(fresh, to: coordinator, session: session)
        _ = try requireTask(accepted)
        let after = host.tasks
        let acceptedCalls = host.effects
        #expect(await send(fresh, to: coordinator, session: session) == accepted)
        #expect(host.tasks == after)
        #expect(host.effects == acceptedCalls)
        #expect(host.created.count == 9)
        #expect(host.prompts == [session])
        let listed = try await listedTasks(coordinator, session: session)
        #expect(listed.filter { $0.state == .running }.count == 8)
    }

    @Test
    func thirtyTwoRecordsRetainRunningTaskAndEvictOldestFinishedCapability() async throws {
        let host = SecurityHostSpy()
        let session = try host.addSession(origin: 1, workspace: 10)
        let coordinator = TerminalAutomationCoordinator(host: host)
        let running = try await createTask(coordinator, session: session)
        var completed: [TerminalControlTask] = []
        for _ in 0..<31 {
            let task = try await createTask(coordinator, session: session)
            host.finish(task)
            completed.append(try #require(host.tasks[task.taskID]))
        }
        #expect(try await listedTasks(coordinator, session: session) == [running] + completed)
        #expect(host.forgotten.isEmpty)
        let newest = try await createTask(coordinator, session: session)
        let retained = try await listedTasks(coordinator, session: session)
        #expect(retained.count == 32)
        #expect(retained == [running] + Array(completed.dropFirst()) + [newest])
        #expect(host.forgotten == [completed[0].taskID])
        #expect(coordinator.currentGrantedTask(taskID: running.taskID, session: session) == running)
        #expect(
            coordinator.currentGrantedTask(taskID: completed[0].taskID, session: session) == nil)

        // WHY: The spy deliberately keeps the forgotten host record. Only domain ownership
        // can reject its UUID; a missing host object would make this a weaker test.
        let before = host.tasks
        let calls = host.effects
        for operation in [
            TerminalControlRequest.Operation.read(taskID: completed[0].taskID),
            .focus(taskID: completed[0].taskID),
        ] {
            let request = try TerminalControlRequest(
                operation: operation, requestID: operation.requiresRequestID ? UUID() : nil)
            expectFailure(await send(request, to: coordinator, session: session), .targetNotOwned)
            #expect(host.effects == calls)
            #expect(host.tasks == before)
        }
        #expect(try await listedTasks(coordinator, session: session) == retained)
    }

    @Test
    func exactUUIDAndRequestReplayNeverCrossSessionOrWorkspace() async throws {
        let host = SecurityHostSpy()
        let owner = try host.addSession(origin: 1, workspace: 10)
        // WHY: Identical textual session IDs do not make two origin capabilities equivalent.
        let sibling = try host.addSession(origin: 2, workspace: 10)
        let foreign = try host.addSession(origin: 3, workspace: 20)
        let coordinator = TerminalAutomationCoordinator(host: host)
        let task = try await createTask(coordinator, session: owner)
        let focus = try TerminalControlRequest(
            operation: .focus(taskID: task.taskID), requestID: UUID())
        let success = await send(focus, to: coordinator, session: owner)
        #expect(
            success
                == TerminalControlResponse(
                    result: .acknowledged(taskID: task.taskID, revision: 1)))
        let before = host.tasks
        let calls = host.effects
        let inspections = host.inspections
        #expect(await send(focus, to: coordinator, session: owner) == success)
        #expect(host.effects == calls)
        #expect(host.inspections == inspections)

        for attacker in [sibling, foreign] {
            let workspaceID = securityUUID(attacker == sibling ? 10 : 20)
            #expect(
                try await listedTasks(
                    coordinator, session: attacker, expectedWorkspaceID: workspaceID
                ).isEmpty)
            let attempts = [
                focus,
                try TerminalControlRequest(operation: .read(taskID: task.taskID)),
                try TerminalControlRequest(
                    operation: .sendText(
                        taskID: task.taskID, expectedRevision: task.revision,
                        text: "forbidden-input"),
                    requestID: UUID()),
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: task.paneID, direction: .right, ratio: 0.5,
                        launch: launch(), policy: .keep, focus: false),
                    requestID: UUID()),
                // A pane or tab UUID is not an alternate spelling of a task capability.
                try TerminalControlRequest(
                    operation: .focus(taskID: task.paneID), requestID: UUID()),
                try TerminalControlRequest(
                    operation: .focus(taskID: task.tabID), requestID: UUID()),
            ]
            for attempt in attempts {
                let inspectionCount = host.inspections
                expectFailure(
                    await send(attempt, to: coordinator, session: attacker), .targetNotOwned)
                #expect(host.effects == calls)
                #expect(host.tasks == before)
                #expect(host.inspections == inspectionCount)
            }
        }
        #expect(host.prompts == [owner, sibling, foreign])
        #expect(
            try await listedTasks(
                coordinator, session: owner, expectedWorkspaceID: securityUUID(10)) == [task])
        let conflict = try TerminalControlRequest(
            operation: .close(taskID: task.taskID), requestID: focus.requestID)
        expectFailure(await send(conflict, to: coordinator, session: owner), .requestIDConflict)
        #expect(host.effects == calls)
        #expect(host.tasks == before)

        // WHY: Moving the origin cannot confer access to tasks left in its previous workspace.
        host.moveOrigin(owner, to: securityUUID(20))
        expectFailure(
            await send(
                try TerminalControlRequest(operation: .read(taskID: task.taskID)),
                to: coordinator, session: owner), .targetNotOwned)
        #expect(host.effects == calls)
        #expect(host.tasks == before)
        #expect(
            try await listedTasks(
                coordinator, session: owner, expectedWorkspaceID: securityUUID(20)
            ).isEmpty)
    }

    enum IdentityReplacement: CaseIterable, Equatable, Sendable {
        case credentialGeneration
        case session
        case adapter
    }

    @Test(arguments: IdentityReplacement.allCases)
    func replacementIdentityNeedsNewGrantAndCannotReviveOldReplayOrOwnership(
        replacementKind: IdentityReplacement
    ) async throws {
        let host = SecurityHostSpy()
        let original = try host.addSession(origin: 1, workspace: 10)
        let coordinator = TerminalAutomationCoordinator(host: host)
        let creation = try createRequest()
        let task = try requireTask(await send(creation, to: coordinator, session: original))
        let before = host.tasks
        let calls = host.effects
        let replacement = try host.addSession(
            origin: 1, workspace: 10,
            generation: replacementKind == .credentialGeneration ? 2 : 1,
            adapter: replacementKind == .adapter ? "codex" : "claude-code",
            sessionID: replacementKind == .session ? "task13-replacement" : original.sessionID)
        host.permission = .denied
        expectFailure(
            await send(creation, to: coordinator, session: replacement), .permissionDenied)
        #expect(host.prompts == [original, replacement])
        #expect(host.revoked == [original])
        #expect(host.effects == calls)
        #expect(host.tasks == before)
        #expect(coordinator.currentGrantedTask(taskID: task.taskID, session: original) == nil)
        #expect(coordinator.currentGrantedTask(taskID: task.taskID, session: replacement) == nil)

        // WHY: Returning to the exact retired identity is an ABA attack, not a new permission prompt.
        host.sessions[original.originPaneID] = original
        host.permission = .allowed
        expectFailure(await send(creation, to: coordinator, session: original), .permissionRevoked)
        #expect(host.prompts == [original, replacement])
        #expect(host.effects == calls)
        #expect(host.tasks == before)

        for envelope in [
            TerminalControlSocketRequest(
                instanceID: UUID(), paneID: original.originPaneID.rawValue, request: creation),
            TerminalControlSocketRequest(
                instanceID: original.instanceID, paneID: UUID(), request: creation),
        ] {
            expectFailure(
                await coordinator.handle(envelope, context: boundedContext()), .invalidSession)
            #expect(host.effects == calls)
            #expect(host.tasks == before)
        }
    }

    @Test
    func freshCoordinatorCannotInheritHostRecordsGrantsOrRequestReplay() async throws {
        let host = SecurityHostSpy()
        let session = try host.addSession(origin: 1, workspace: 10)
        let oldCoordinator = TerminalAutomationCoordinator(host: host)
        let creation = try createRequest()
        let task = try requireTask(await send(creation, to: oldCoordinator, session: session))
        let focus = try TerminalControlRequest(
            operation: .focus(taskID: task.taskID), requestID: UUID())
        #expect(
            await send(focus, to: oldCoordinator, session: session)
                == TerminalControlResponse(
                    result: .acknowledged(taskID: task.taskID, revision: task.revision)))
        let before = host.tasks
        let calls = host.effects
        let freshCoordinator = TerminalAutomationCoordinator(host: host)
        #expect(freshCoordinator.currentGrantedTask(taskID: task.taskID, session: session) == nil)

        // WHY: Even a fresh grant cannot adopt retained host values by UUID. This checks
        // in-memory capability lifetime, not application restart or descriptor projection.
        #expect(try await listedTasks(freshCoordinator, session: session).isEmpty)
        #expect(host.prompts == [session, session])
        for request in [focus, try TerminalControlRequest(operation: .read(taskID: task.taskID))] {
            expectFailure(
                await send(request, to: freshCoordinator, session: session), .targetNotOwned)
            #expect(host.tasks == before)
            #expect(host.effects == calls)
        }
        #expect(freshCoordinator.currentGrantedTask(taskID: task.taskID, session: session) == nil)
        #expect(oldCoordinator.currentGrantedTask(taskID: task.taskID, session: session) == task)
        let newTask = try requireTask(await send(creation, to: freshCoordinator, session: session))
        #expect(newTask.taskID != task.taskID)
        #expect(host.created == [task.taskID, newTask.taskID])
        #expect(try await listedTasks(freshCoordinator, session: session) == [newTask])
        #expect(try await listedTasks(oldCoordinator, session: session) == [task])
    }

    @Test
    func managedLaunchConfigurationCarriesPayloadButNotOriginCredentials() throws {
        let controller = try makeCredentialController()
        defer { controller.freeze() }
        let pane = PaneID(rawValue: securityUUID(1))
        let originEnvironment = try #require(controller.register(paneID: pane))
        let token = try #require(originEnvironment["QUICKTTY_PANE_TOKEN"])
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Security-Launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "task13-executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let requestLaunch = try TerminalControlLaunch(
            executable: executable.path, arguments: launch().arguments, cwd: launch().cwd)
        // WHY: Use an owned executable for real filesystem preflight; this test launches nothing.
        let configuration = try TerminalTaskLaunchConfiguration(
            launch: requestLaunch, bundledHelperPath: executable.path,
            executableSearchPath: "/fixture/bin")
        #expect(
            Set(configuration.environment.keys) == [
                "PATH", AgentInvocationPayloadEnvironment.payloadKey,
                AgentInvocationPayloadEnvironment.helperKey,
            ])
        #expect(configuration.environment["PATH"] == "/fixture/bin")
        let payload = try AgentInvocationPayloadCodec.decodeBase64(
            #require(configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]))
        #expect(payload.executable == requestLaunch.executable)
        #expect(payload.arguments == requestLaunch.arguments)
        #expect(payload.workingDirectory == requestLaunch.cwd)
        for key in [
            "QUICKTTY_INSTANCE_ID", "QUICKTTY_PANE_ID", "QUICKTTY_PANE_TOKEN",
            "QUICKTTY_AGENT_SOCKET", "QUICKTTY_CONTROL_SOCKET",
        ] {
            #expect(originEnvironment[key] != nil)
            #expect(configuration.environment[key] == nil)
        }
        #expect(!configuration.command.contains(token))
        #expect(!configuration.environment.values.contains { $0.contains(token) })
        #expect(controller.environment(for: pane) == originEnvironment)
        #expect(controller.environment(for: PaneID(rawValue: securityUUID(2))) == nil)
        // This proves configuration non-propagation, not the environment of a real PTY child.
    }

    @Test
    func credentialFreezeAndDomainRevocationCancelWaitsWithoutRequestingProcessClosure()
        async throws
    {
        let controller = try makeCredentialController()
        defer { controller.freeze() }
        let host = SecurityHostSpy()
        let first = try host.addSession(origin: 1, workspace: 10)
        let second = try host.addSession(origin: 2, workspace: 20)
        let sessions = [first, second]
        let preflights = try sessions.map {
            try TerminalControlPreflight(
                instanceID: $0.instanceID, paneID: $0.originPaneID.rawValue,
                nonce: Data(repeating: 0x11, count: TerminalControlProtocol.nonceSize))
        }
        for session in sessions {
            _ = try #require(controller.register(paneID: session.originPaneID))
        }
        let coordinator = TerminalAutomationCoordinator(host: host)
        var tasks: [TerminalControlTask] = []
        for session in sessions {
            tasks.append(try await createTask(coordinator, session: session))
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let contexts = preflights.map { preflight in
            TerminalControlRequestContext {
                controller.credential(for: preflight) != nil && ContinuousClock().now < deadline
            }
        }
        let waitRequests = try tasks.map {
            try TerminalControlRequest(
                operation: .wait(
                    taskID: $0.taskID, revision: $0.revision, timeoutMilliseconds: 30_000))
        }
        let waits = sessions.indices.map { index in
            Task { @MainActor in
                await coordinator.handle(
                    TerminalControlSocketRequest(
                        instanceID: sessions[index].instanceID,
                        paneID: sessions[index].originPaneID.rawValue,
                        request: waitRequests[index]),
                    context: contexts[index])
            }
        }
        defer {
            for wait in waits {
                wait.cancel()
            }
        }
        try await waitUntil {
            host.effects.filter { $0 == "read" }.count >= 2
                && sessions.indices.allSatisfy {
                    !coordinator.canEvictHostTask(taskID: tasks[$0].taskID, session: sessions[$0])
                }
        }
        for index in sessions.indices {
            #expect(contexts[index].isActive)
            #expect(
                coordinator.currentGrantedTask(
                    taskID: tasks[index].taskID, session: sessions[index])
                    == tasks[index])
        }
        let before = host.tasks
        let calls = host.effects

        // WHY: These are the component boundaries used during termination, not a simulated
        // AppDelegate/WindowCoordinator shutdown or proof that an OS process remains alive.
        let cancellationDeadline = ContinuousClock().now.advanced(by: .seconds(1))
        controller.freeze()
        for session in sessions {
            coordinator.originSessionDidChange(originPaneID: session.originPaneID)
        }
        for wait in waits { expectFailure(await wait.value, .cancelled) }
        // WHY: The five-second safety lease expiring must not masquerade as freeze cancellation.
        #expect(ContinuousClock().now < cancellationDeadline)
        #expect(Set(host.revoked) == Set(sessions))
        for index in sessions.indices {
            let session = sessions[index]
            #expect(!contexts[index].isActive)
            #expect(controller.credential(for: preflights[index]) == nil)
            #expect(controller.environment(for: session.originPaneID) == nil)
            #expect(controller.register(paneID: session.originPaneID) == nil)
            #expect(controller.rotate(paneID: session.originPaneID) == nil)
            #expect(
                coordinator.currentGrantedTask(taskID: tasks[index].taskID, session: session) == nil
            )
            #expect(coordinator.canEvictHostTask(taskID: tasks[index].taskID, session: session))
            #expect(coordinator.pendingMutationCountForTesting(session) == 0)
            let close = try TerminalControlRequest(
                operation: .close(taskID: tasks[index].taskID), requestID: UUID())
            expectFailure(await send(close, to: coordinator, session: session), .permissionRevoked)
        }
        #expect(host.effects == calls)
        #expect(host.tasks == before)
        #expect(host.tasks.values.allSatisfy { $0.state == .running })
        #expect(host.forgotten.isEmpty)
    }

    private func launch() -> TerminalControlLaunch {
        try! TerminalControlLaunch(
            executable: "/fixture/task13-executable",
            arguments: ["task13-argv-sentinel"], cwd: "/tmp")
    }

    private func createRequest() throws -> TerminalControlRequest {
        try TerminalControlRequest(
            operation: .createTab(launch: launch(), policy: .keep, focus: false), requestID: UUID())
    }

    private func createTask(
        _ coordinator: TerminalAutomationCoordinator, session: TerminalAutomationSessionIdentity
    ) async throws -> TerminalControlTask {
        let request = try createRequest()
        return try requireTask(await send(request, to: coordinator, session: session))
    }

    private func requireTask(_ response: TerminalControlResponse) throws -> TerminalControlTask {
        guard case .task(let task) = response.result else {
            Issue.record("Expected created task, got \(response)")
            throw SecurityFixtureError.unexpectedResponse
        }
        return task
    }

    private func listedTasks(
        _ coordinator: TerminalAutomationCoordinator, session: TerminalAutomationSessionIdentity,
        expectedWorkspaceID: UUID? = nil
    ) async throws -> [TerminalControlTask] {
        let response = await send(
            try TerminalControlRequest(operation: .list), to: coordinator, session: session)
        guard case .list(let workspace, let tasks) = response.result else {
            Issue.record("Expected list, got \(response)")
            throw SecurityFixtureError.unexpectedResponse
        }
        #expect(workspace.originPaneID == session.originPaneID.rawValue)
        if let expectedWorkspaceID {
            #expect(workspace.workspaceID == expectedWorkspaceID)
        }
        return tasks
    }

    private func send(
        _ request: TerminalControlRequest, to coordinator: TerminalAutomationCoordinator,
        session: TerminalAutomationSessionIdentity
    ) async -> TerminalControlResponse {
        await coordinator.handle(
            TerminalControlSocketRequest(
                instanceID: session.instanceID, paneID: session.originPaneID.rawValue,
                request: request),
            context: boundedContext())
    }

    private func boundedContext() -> TerminalControlRequestContext {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        return TerminalControlRequestContext { ContinuousClock().now < deadline }
    }

    private func expectFailure(
        _ response: TerminalControlResponse, _ code: TerminalControlErrorCode
    ) {
        guard case .failure(let error) = response.result else {
            Issue.record("Expected \(code), got \(response)")
            return
        }
        #expect(error.code == code)
    }

    private func makeCredentialController() throws -> AgentSessionController {
        try AgentSessionController(
            socketPath: "/tmp/task13-agent.sock", helperPath: "/bin/echo",
            controlSocketPath: "/tmp/task13-control.sock", instanceID: securityUUID(100),
            tokenGenerator: { Array(repeating: 0xAB, count: 32) }, onAction: { _ in false })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock().now < deadline else { throw SecurityFixtureError.waitTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum SecurityFixtureError: Error {
    case unexpectedResponse
    case waitTimedOut
}

// WHY: Capacity and authorization belong to the real coordinator. This host records boundary
// calls and owns only value records, never windows, shells, sockets, or synthetic PTY output.
@MainActor
private final class SecurityHostSpy: TerminalAutomationHost {
    var sessions: [PaneID: TerminalAutomationSessionIdentity] = [:]
    private var workspaces: [PaneID: UUID] = [:]
    var tasks: [UUID: TerminalControlTask] = [:]
    private var owners: [UUID: TerminalAutomationSessionIdentity] = [:]
    var permission: TerminalAutomationPermissionDecision = .allowed
    private(set) var prompts: [TerminalAutomationSessionIdentity] = []
    private(set) var revoked: [TerminalAutomationSessionIdentity] = []
    private(set) var created: [UUID] = []
    private(set) var forgotten: [UUID] = []
    private(set) var effects: [String] = []
    private(set) var inspections = 0

    func addSession(
        origin: Int, workspace: Int, generation: UInt64 = 1,
        adapter: String = "claude-code", sessionID: String = "task13-same-session"
    ) throws -> TerminalAutomationSessionIdentity {
        let session = TerminalAutomationSessionIdentity(
            instanceID: securityUUID(100), originPaneID: PaneID(rawValue: securityUUID(origin)),
            adapterID: try AgentAdapterID(rawValue: adapter), sessionID: sessionID,
            paneCredentialGeneration: generation)
        sessions[session.originPaneID] = session
        workspaces[session.originPaneID] = securityUUID(workspace)
        return session
    }

    func moveOrigin(_ session: TerminalAutomationSessionIdentity, to workspace: UUID) {
        workspaces[session.originPaneID] = workspace
    }

    func resolveAuthenticatedSession(instanceID: UUID, originPaneID: PaneID)
        -> TerminalAutomationResolvedSession?
    {
        guard let session = sessions[originPaneID], session.instanceID == instanceID,
            let workspace = workspaces[originPaneID]
        else { return nil }
        let origins = sessions.keys.filter { workspaces[$0] == workspace }
        let originTab = TabID(rawValue: originPaneID.rawValue)
        let localTasks = tasks.values.filter { $0.workspaceID == workspace }
        let tabs = Set(
            origins.map { TabID(rawValue: $0.rawValue) }
                + localTasks.map { TabID(rawValue: $0.tabID) })
        let panes = Set(origins + localTasks.map { PaneID(rawValue: $0.paneID) })
        return TerminalAutomationResolvedSession(
            identity: session,
            workspace: TerminalAutomationWorkspaceContext(
                workspaceID: WorkspaceID(rawValue: workspace), name: "Task13",
                originTabID: originTab,
                activeTabID: originTab, tabCount: tabs.count, paneCount: panes.count,
                tabIDs: tabs, paneIDs: panes))
    }

    func presentPermission(for session: TerminalAutomationResolvedSession) async
        -> TerminalAutomationPermissionDecision
    {
        prompts.append(session.identity)
        return permission
    }

    func createTab(
        in workspaceID: WorkspaceID, launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy, focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        effects.append("create")
        let task = TerminalControlTask(
            taskID: UUID(), paneID: UUID(), tabID: UUID(), workspaceID: workspaceID.rawValue,
            state: .running, owner: .agent, policy: policy, revision: 1, exitCode: nil)
        tasks[task.taskID] = task
        owners[task.taskID] = expectedSession
        created.append(task.taskID)
        return .createdTask(TerminalAutomationCreatedTaskResponse(task: task, splitID: nil))
    }

    func createSplit(
        anchorPaneID: PaneID, in workspaceID: WorkspaceID, direction: TerminalSplitDirection,
        ratio: Double, launch: TerminalControlLaunch, policy: TerminalTaskLifecyclePolicy,
        focus: Bool, expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        unexpected("split")
    }

    func discardCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> Bool {
        _ = unexpected("discard")
        return false
    }

    func acceptCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) {
        #expect(owners[created.task.taskID] == expectedSession)
    }

    func revokeSession(_ session: TerminalAutomationSessionIdentity) { revoked.append(session) }

    func forgetTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) {
        #expect(owners[taskID] == expectedSession)
        forgotten.append(taskID)
    }

    func canEvictTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) -> Bool {
        owners[taskID] == expectedSession
    }

    func inspectTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity)
        -> TerminalAutomationTaskInspection
    {
        inspections += 1
        guard let task = tasks[taskID] else { return .notFound }
        guard owners[taskID] == expectedSession else { return .notOwned }
        return .owned(task)
    }

    func read(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) async
        -> TerminalAutomationHostResponse
    {
        effects.append("read")
        guard let task = tasks[taskID], owners[taskID] == expectedSession else {
            Issue.record("Unauthorized read reached the host")
            return .failure(.targetNotOwned)
        }
        return .task(task)
    }

    func focus(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) async
        -> TerminalAutomationHostResponse
    {
        effects.append("focus")
        guard let task = tasks[taskID], owners[taskID] == expectedSession else {
            Issue.record("Unauthorized focus reached the host")
            return .failure(.targetNotOwned)
        }
        return .acknowledged(taskID: taskID, revision: task.revision)
    }

    func sendText(
        taskID: UUID, expectedRevision: UInt64, text: String,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        unexpected("text")
    }

    func sendKey(
        taskID: UUID, expectedRevision: UInt64, key: TerminalControlKey,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        unexpected("key")
    }

    func requestUserInput(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) async
        -> TerminalAutomationHostResponse
    {
        unexpected("user-input")
    }

    func resize(
        taskID: UUID, ratio: Double, expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        unexpected("resize")
    }

    func interrupt(
        taskID: UUID, expectedRevision: UInt64, expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        unexpected("interrupt")
    }

    func requestClose(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity,
        context: TerminalControlRequestContext
    ) async -> TerminalAutomationHostResponse {
        unexpected("close")
    }

    func publishPresentation(_ presentation: TerminalAutomationPresentationEvent) {}
    func publishAttention(_ attention: TerminalAutomationAttention) {}

    func finish(_ task: TerminalControlTask) {
        tasks[task.taskID] = TerminalControlTask(
            taskID: task.taskID, paneID: task.paneID, tabID: task.tabID,
            workspaceID: task.workspaceID,
            state: .succeeded, owner: .finished, policy: task.policy,
            revision: task.revision + 1, exitCode: 0)
    }

    private func unexpected(_ operation: String) -> TerminalAutomationHostResponse {
        effects.append(operation)
        Issue.record("Unexpected host operation: \(operation)")
        return .failure(.internalFailure)
    }
}

private func securityUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "13000000-0000-0000-0000-%012d", value))!
}
