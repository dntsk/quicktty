import AppKit
import Foundation
import Synchronization
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct WindowCoordinatorTerminalAutomationTests {
    private let workingDirectories = AutomationWorkingDirectories()

    @Test
    func resolvesExactOriginMetadataWithoutTerminalContent() throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let resolved = try #require(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: fixture.instanceID,
                originPaneID: fixture.originPaneID
            )
        )

        #expect(resolved.identity.originPaneID == fixture.originPaneID)
        #expect(resolved.identity.adapterID == fixture.binding.adapterID)
        #expect(resolved.identity.sessionID == fixture.binding.sessionID)
        #expect(resolved.identity.paneCredentialGeneration == 1)
        #expect(resolved.workspace.workspaceID == fixture.workspaceID)
        #expect(resolved.workspace.originTabID == fixture.originTabID)
        #expect(resolved.workspace.activeTabID == fixture.activeTabID)
        #expect(resolved.workspace.tabCount == 1)
        #expect(resolved.workspace.paneCount == 1)
        #expect(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: UUID(),
                originPaneID: fixture.originPaneID
            ) == nil
        )

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .unregister(
                    paneID: fixture.originPaneID,
                    adapterID: fixture.binding.adapterID,
                    sessionID: fixture.binding.sessionID
                )
            )
        )
        #expect(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: fixture.instanceID,
                originPaneID: fixture.originPaneID
            ) == nil
        )
    }

    @Test
    func exactActiveRegistrationDoesNotAdvanceAuthorizationEpoch() throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let initial = try resolvedSession(in: fixture)

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: fixture.originPaneID, binding: fixture.binding)
            )
        )

        let current = try resolvedSession(in: fixture)
        #expect(current.identity == initial.identity)
        #expect(
            fixture.coordinator.paneAuthorizationEpochForTesting(fixture.originPaneID)
                == initial.identity.paneCredentialGeneration
        )
    }

    @Test
    func acceptedLifecycleMutationsAdvanceAuthorizationEpochExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let initial = try resolvedSession(in: fixture)
        let replacement = try makeBinding(sessionID: "replacement-session", registeredAt: 2_000)

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID,
                    previousSessionID: fixture.binding.sessionID,
                    binding: replacement
                )
            )
        )
        #expect(
            try resolvedSession(in: fixture).identity.paneCredentialGeneration
                == initial.identity.paneCredentialGeneration + 1
        )

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID,
                    previousSessionID: replacement.sessionID,
                    binding: fixture.binding
                )
            )
        )
        #expect(
            try resolvedSession(in: fixture).identity.paneCredentialGeneration
                == initial.identity.paneCredentialGeneration + 2
        )

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .unregister(
                    paneID: fixture.originPaneID,
                    adapterID: fixture.binding.adapterID,
                    sessionID: fixture.binding.sessionID
                )
            )
        )
        #expect(
            fixture.coordinator.paneAuthorizationEpochForTesting(fixture.originPaneID)
                == initial.identity.paneCredentialGeneration + 3
        )
        #expect(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: fixture.instanceID,
                originPaneID: fixture.originPaneID
            ) == nil
        )

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: fixture.originPaneID, binding: fixture.binding)
            )
        )
        let registered = try resolvedSession(in: fixture)
        #expect(registered.identity.adapterID == fixture.binding.adapterID)
        #expect(registered.identity.sessionID == fixture.binding.sessionID)
        #expect(
            registered.identity.paneCredentialGeneration
                == initial.identity.paneCredentialGeneration + 4
        )
    }

    @Test
    func rejectedLifecycleActionsDoNotAdvanceAuthorizationEpoch() throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let initial = try resolvedSession(in: fixture)
        let replacement = try makeBinding(sessionID: "replacement-session", registeredAt: 2_000)
        let actions: [AgentSessionLifecycleAction] = [
            .register(paneID: fixture.originPaneID, binding: replacement),
            .replace(
                paneID: fixture.originPaneID,
                previousSessionID: "wrong-previous-session",
                binding: replacement
            ),
            .unregister(
                paneID: fixture.originPaneID,
                adapterID: fixture.binding.adapterID,
                sessionID: "wrong-session"
            ),
        ]

        for action in actions {
            #expect(!fixture.coordinator.handleAgentSessionLifecycleAction(action))
            #expect(try resolvedSession(in: fixture).identity == initial.identity)
        }
    }

    @Test
    func bindingABARetiresGrantAndTaskOwnershipWithoutRotatingSocketCredential() async throws {
        var promptCount = 0
        let fixture = try makeFixture(
            permissionPresenter: { _ in
                promptCount += 1
                return .allowed
            }
        )
        defer { fixture.shutdown() }
        let paneToken = try #require(
            fixture.controller.environment(for: fixture.originPaneID)?["QUICKTTY_PANE_TOKEN"]
        )
        let created = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(
                    operation: .createTab(
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(102)
                )
            ),
            context: TerminalControlRequestContext()
        )
        _ = try requireControlTask(created)
        let replacement = try makeBinding(sessionID: "replacement-session", registeredAt: 2_000)

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID,
                    previousSessionID: fixture.binding.sessionID,
                    binding: replacement
                )
            )
        )
        let replacementList = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: TerminalControlRequestContext()
        )
        guard case .list(_, let replacementTasks) = replacementList.result else {
            Issue.record("Expected replacement list response, got \(replacementList)")
            return
        }
        #expect(replacementTasks.isEmpty)
        #expect(promptCount == 2)

        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID,
                    previousSessionID: replacement.sessionID,
                    binding: fixture.binding
                )
            )
        )
        #expect(
            fixture.controller.environment(for: fixture.originPaneID)?["QUICKTTY_PANE_TOKEN"]
                == paneToken
        )

        let freshList = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(operation: .list)
            ),
            context: TerminalControlRequestContext()
        )
        guard case .list(_, let tasks) = freshList.result else {
            Issue.record("Expected list response, got \(freshList)")
            return
        }
        #expect(tasks.isEmpty)
        #expect(promptCount == 3)
    }

    @Test
    func resolvesBackgroundOriginTabSeparatelyFromCurrentActiveTab() throws {
        let fixture = try makeFixture(originTabIsActive: false)
        defer { fixture.shutdown() }
        let resolved = try #require(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: fixture.instanceID,
                originPaneID: fixture.originPaneID
            )
        )

        #expect(resolved.workspace.workspaceID == fixture.workspaceID)
        #expect(resolved.workspace.originTabID == fixture.originTabID)
        #expect(resolved.identity.originPaneID == fixture.originPaneID)
        #expect(resolved.workspace.activeTabID == fixture.activeTabID)
        #expect(resolved.workspace.activeTabID != resolved.workspace.originTabID)
        #expect(resolved.workspace.tabCount == 2)
        #expect(resolved.workspace.paneCount == 2)
    }

    @Test
    func managedTabIsBackgroundShellDescriptorWithSanitizedLaunchEnvironment() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let response = await fixture.coordinator.terminalAutomationHost.createTab(
            in: fixture.workspaceID,
            launch: try launch(),
            policy: .closeOnSuccess,
            focus: false,
            expectedSession: session.identity
        )
        let created = try requireCreatedTask(response)
        let task = created.task
        let paneID = PaneID(rawValue: task.paneID)
        let configuration = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: paneID)
        )
        let workspace = try #require(
            fixture.coordinator.workspaceStoreForTesting.workspace(id: fixture.workspaceID)
        )
        let tab = try #require(
            fixture.coordinator.workspaceStoreForTesting.tab(id: TabID(rawValue: task.tabID))
        )
        let descriptor = try #require(tab.paneDescriptor(for: paneID))

        #expect(workspace.activeTabID == fixture.originTabID)
        #expect(created.splitID == nil)
        #expect(task.workspaceID == fixture.workspaceID.rawValue)
        #expect(task.state == .running)
        #expect(task.owner == .agent)
        #expect(task.policy == .closeOnSuccess)
        #expect(task.revision == 1)
        #expect(
            descriptor == TerminalPaneDescriptor(id: paneID, cwd: fixture.directories.managed.path))
        let quotedHelper =
            "'" + fixture.helperPath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        #expect(configuration.command == quotedHelper + " internal launch")
        #expect(configuration.managedHelperPath == fixture.helperPath)
        #expect(
            fixture.bridge.surfaceConfigurationForTesting(id: fixture.originPaneID)?
                .managedHelperPath == nil)
        #expect(configuration.workingDirectory == fixture.directories.managed.path)
        #expect(configuration.workingDirectory != fixture.directories.origin.path)
        #expect(configuration.waitAfterCommand)
        #expect(configuration.context == .newTab)
        #expect(configuration.initialInput == nil)
        #expect(configuration.environment["PATH"] == "/managed/bin")
        let payload = try AgentInvocationPayloadCodec.decodeBase64(
            try #require(configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]))
        #expect(payload.executable == "/bin/sh")
        #expect(payload.arguments == ["-c", "exec /bin/cat", "managed-argument"])
        #expect(payload.workingDirectory == fixture.directories.managed.path)
        #expect(configuration.environment["BASE"] == "preserved")
        expectNoAgentIdentity(in: configuration.environment)
        #expect(fixture.controller.environment(for: paneID) == nil)

        let encoded = String(
            decoding: try JSONEncoder().encode(fixture.coordinator.workspaceStoreForTesting),
            as: UTF8.self
        )
        #expect(!encoded.contains(task.taskID.uuidString))
        #expect(!encoded.contains("/bin/sh"))
        #expect(!encoded.contains(fixture.helperPath))
        #expect(!encoded.contains("managed-argument"))
        #expect(!encoded.contains(AgentInvocationPayloadEnvironment.payloadKey))
        #expect(!encoded.contains("close-on-success"))

        let originEnvironment = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: fixture.originPaneID)?.environment
        )
        #expect(originEnvironment["QUICKTTY_PANE_ID"] == fixture.originPaneID.rawValue.uuidString)
        #expect(originEnvironment["QUICKTTY_AGENT_SOCKET"] == "/tmp/quicktty-automation.sock")
        #expect(originEnvironment["QUICKTTY_INSTANCE_ID"] == fixture.instanceID.uuidString)
        #expect(originEnvironment["QUICKTTY_PANE_TOKEN"] != nil)
        #expect(originEnvironment["QUICKTTY_AGENT_HELPER"] == fixture.helperPath)
        // WHY: An inherited collision is not a live app-owned control endpoint.
        #expect(originEnvironment["QUICKTTY_CONTROL_SOCKET"] == nil)
    }

    @Test(arguments: TerminalSplitDirection.allCases)
    func managedSplitUsesEveryInsertionDirectionAndRestoresFocusWhenBackground(
        direction: TerminalSplitDirection
    ) async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let response = await fixture.coordinator.terminalAutomationHost.createSplit(
            anchorPaneID: fixture.originPaneID,
            in: fixture.workspaceID,
            direction: direction,
            ratio: 0.25,
            launch: try launch(),
            policy: .keep,
            focus: false,
            expectedSession: session.identity
        )
        let created = try requireCreatedTask(response)
        let task = created.task
        let paneID = PaneID(rawValue: task.paneID)
        let tab = try #require(
            fixture.coordinator.workspaceStoreForTesting.tab(id: fixture.originTabID)
        )
        guard case .split(let splitID, let axis, let storedRatio, let first, let second) = tab.root
        else {
            Issue.record("Expected managed split")
            return
        }
        let placement = direction.splitPlacement
        let expectedFirst: SplitNode =
            placement.insertionSide == .first
            ? .pane(paneID) : .pane(fixture.originPaneID)
        let expectedSecond: SplitNode =
            placement.insertionSide == .first
            ? .pane(fixture.originPaneID) : .pane(paneID)

        #expect(axis == placement.axis)
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        #expect(storedRatio == (placement.insertionSide == .first ? 0.25 : 0.75))
        #expect(tab.activePaneID == fixture.originPaneID)
        #expect(created.splitID == splitID)
        #expect(fixture.coordinator.managedSplitIDForTesting(taskID: task.taskID) == splitID)
        #expect(
            tab.paneDescriptor(for: paneID)
                == TerminalPaneDescriptor(id: paneID, cwd: fixture.directories.managed.path)
        )
        let configuration = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: paneID)
        )
        #expect(configuration.context == .split)
        #expect(configuration.managedHelperPath == fixture.helperPath)
        #expect(configuration.workingDirectory == fixture.directories.managed.path)
        #expect(configuration.workingDirectory != fixture.directories.origin.path)
        #expect(configuration.waitAfterCommand)
        expectNoAgentIdentity(in: configuration.environment)
    }

    @Test
    func focusedManagedTabAndSplitActivateExactTargetsWithoutChangingModeOrWindow() async throws {
        let fixture = try makeFixture(mode: .quake)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let mode = fixture.coordinator.presentationMode
        let window = fixture.coordinator.activeWindowForTesting
        let tabTask = try requireTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        let tabPaneID = PaneID(rawValue: tabTask.paneID)

        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.coordinator.activeWindowForTesting === window)
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspace(id: fixture.workspaceID)?
                .activeTabID == TabID(rawValue: tabTask.tabID)
        )
        #expect(fixture.coordinator.activeSurfaceForTesting?.paneID == tabPaneID)

        let splitTask = try requireTask(
            await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: tabPaneID,
                in: fixture.workspaceID,
                direction: .down,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.tab(id: TabID(rawValue: tabTask.tabID))?
                .activePaneID == PaneID(rawValue: splitTask.paneID)
        )
        #expect(fixture.coordinator.activeSurfaceForTesting?.paneID.rawValue == splitTask.paneID)
        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.coordinator.activeWindowForTesting === window)
    }

    @Test
    func requestRouteRetainsOwnedPaneAcrossSplitRequests() async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let firstResponse = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil,
                        direction: .right,
                        ratio: 0.5,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(100)
                )
            ),
            context: TerminalControlRequestContext()
        )
        let firstTask = try requireControlTask(firstResponse)
        let secondResponse = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: firstTask.paneID,
                        direction: .down,
                        ratio: 0.4,
                        launch: try launch(),
                        policy: .keep,
                        focus: false
                    ),
                    requestID: uuid(101)
                )
            ),
            context: TerminalControlRequestContext()
        )
        let secondTask = try requireControlTask(secondResponse)

        #expect(firstTask.tabID == fixture.originTabID.rawValue)
        #expect(secondTask.tabID == fixture.originTabID.rawValue)
        #expect(fixture.coordinator.managedTaskCountForTesting == 2)
    }

    @Test
    func compensatingDiscardRequiresTheExactTaskAndSession() async throws {
        let fixture = try makeFixture(mode: .quake)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let mode = fixture.coordinator.presentationMode
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        let foreignSession = TerminalAutomationSessionIdentity(
            instanceID: session.identity.instanceID,
            originPaneID: session.identity.originPaneID,
            adapterID: session.identity.adapterID,
            sessionID: "another-session",
            paneCredentialGeneration: session.identity.paneCredentialGeneration
        )
        let mismatchedTask = TerminalControlTask(
            taskID: created.task.taskID,
            paneID: created.task.paneID,
            tabID: created.task.tabID,
            workspaceID: created.task.workspaceID,
            state: created.task.state,
            owner: created.task.owner,
            policy: created.task.policy,
            revision: created.task.revision + 1,
            exitCode: created.task.exitCode
        )
        let mismatchedCreated = TerminalAutomationCreatedTaskResponse(
            task: mismatchedTask,
            splitID: created.splitID
        )

        let mismatchedTaskDiscarded = await fixture.coordinator.terminalAutomationHost
            .discardCreatedTask(mismatchedCreated, expectedSession: session.identity)
        #expect(mismatchedTaskDiscarded == false)
        let mismatchedSessionDiscarded = await fixture.coordinator.terminalAutomationHost
            .discardCreatedTask(created, expectedSession: foreignSession)
        #expect(mismatchedSessionDiscarded == false)
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: created.task.taskID,
                expectedSession: session.identity
            ) == .owned(created.task)
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.tab(
                id: TabID(rawValue: created.task.tabID)
            ) != nil
        )

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )
        #expect(discarded)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        #expect(
            fixture.coordinator.workspaceStoreForTesting.tab(
                id: TabID(rawValue: created.task.tabID)
            ) == nil
        )
        #expect(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: created.task.paneID)) == nil
        )
        #expect(fixture.coordinator.presentationMode == mode)
        let discardedAgain = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )
        #expect(discardedAgain)
    }

    @Test
    func compensatingDiscardFindsATabAfterItMovesToAnotherWorkspace() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        let paneID = PaneID(rawValue: created.task.paneID)
        let tabID = TabID(rawValue: created.task.tabID)
        let destinationWorkspaceID = try #require(
            fixture.coordinator.moveTabToNewWorkspaceForTesting(
                tabID,
                name: "Moved Managed Task"
            )
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspace(id: destinationWorkspaceID)?
                .tabs.contains(where: { $0.id == tabID }) == true
        )

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )

        #expect(discarded)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        #expect(fixture.coordinator.surfaceForTesting(id: paneID) == nil)
        #expect(!fixture.bridge.activeSurfaceIDs.contains(paneID))
        #expect(
            fixture.coordinator.workspaceStoreForTesting.activeWorkspaceID == destinationWorkspaceID
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspace(id: destinationWorkspaceID)?
                .activeTabID == nil
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspace(id: fixture.workspaceID)?
                .activeTabID == fixture.originTabID
        )
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspaces.allSatisfy { workspace in
                workspace.tabs.allSatisfy { tab in
                    tab.id != tabID && !tab.root.contains(paneID)
                }
            }
        )
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: created.task.taskID,
                expectedSession: session.identity
            ) == .notFound
        )
    }

    @Test
    func compensatingDiscardCollapsesOnlyTheCreatedSplit() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: false,
                expectedSession: session.identity
            )
        )

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )
        #expect(discarded)
        let tab = try #require(
            fixture.coordinator.workspaceStoreForTesting.tab(id: fixture.originTabID)
        )
        #expect(tab.root == .pane(fixture.originPaneID))
        #expect(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID) != nil)
        #expect(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: created.task.paneID)) == nil
        )
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
    }

    @Test(
        arguments: FocusCompensationScenario.allCases,
        [PresentationMode.normal, .quake]
    )
    private func compensatingDiscardRestoresOnlyCreationFocus(
        scenario: FocusCompensationScenario,
        mode: PresentationMode
    ) async throws {
        for focus in [false, true] {
            var commits: [WorkspaceStore] = []
            let fixture = try makeFixture(
                mode: mode,
                originTabIsActive: scenario == .nonActiveAnchor
                    || scenario == .backgroundWorkspaceTab,
                originWorkspaceIsActive: !scenario.isBackgroundWorkspace,
                originPaneIsActive: scenario != .nonActiveAnchor,
                includesCurrentTab: scenario == .backgroundWorkspaceTab,
                persistWorkspaceStore: { commits.append($0) }
            )
            defer { fixture.shutdown() }
            let session = try resolvedSession(in: fixture)
            let before = fixture.coordinator.workspaceStoreForTesting
            let surfaces = fixture.coordinator.surfaceIDsForTesting
            let window = fixture.coordinator.activeWindowForTesting
            let normalWindow = fixture.coordinator.windowForTesting
            let normalFrame = fixture.coordinator.normalWindowFrame
            let visibility = fixture.coordinator.quakeVisibilityForTesting
            let response: TerminalAutomationHostResponse
            if scenario == .backgroundWorkspaceTab {
                response = await fixture.coordinator.terminalAutomationHost.createTab(
                    in: fixture.workspaceID,
                    launch: try launch(),
                    policy: .keep,
                    focus: focus,
                    expectedSession: session.identity
                )
            } else {
                response = await fixture.coordinator.terminalAutomationHost.createSplit(
                    anchorPaneID: fixture.originPaneID,
                    in: fixture.workspaceID,
                    direction: .left,
                    ratio: 0.5,
                    launch: try launch(),
                    policy: .keep,
                    focus: focus,
                    expectedSession: session.identity
                )
            }
            let created = try requireCreatedTask(response)
            if focus {
                #expect(
                    fixture.coordinator.activeSurfaceForTesting?.paneID.rawValue
                        == created.task.paneID
                )
            }
            let commitCount = commits.count

            let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
                created,
                expectedSession: session.identity
            )

            #expect(discarded)
            #expect(commits.count == commitCount + 1)
            #expect(commits.last == before)
            #expect(fixture.coordinator.workspaceStoreForTesting == before)
            let previousWorkspace = try #require(before.workspace(id: before.activeWorkspaceID))
            let previousTab = try #require(
                previousWorkspace.activeTabID.flatMap { before.tab(id: $0) }
            )
            #expect(fixture.coordinator.activeSurfaceForTesting?.paneID == previousTab.activePaneID)
            expectManagedTaskCleanedUp(
                created,
                session: session.identity,
                in: fixture,
                surfaces: surfaces
            )
            #expect(fixture.coordinator.presentationMode == mode)
            #expect(fixture.coordinator.activeWindowForTesting === window)
            #expect(fixture.coordinator.windowForTesting === normalWindow)
            #expect(fixture.coordinator.normalWindowFrame == normalFrame)
            #expect(fixture.coordinator.quakeVisibilityForTesting == visibility)

            let discardedAgain = await fixture.coordinator.terminalAutomationHost
                .discardCreatedTask(
                    created,
                    expectedSession: session.identity
                )
            #expect(discardedAgain)
            #expect(commits.count == commitCount + 1)
        }
    }

    @Test(arguments: LaterFocusSelection.allCases, [PresentationMode.normal, .quake])
    private func compensatingDiscardPreservesLaterUserSelection(
        selection: LaterFocusSelection,
        mode: PresentationMode
    ) async throws {
        let fixture = try makeFixture(
            mode: mode,
            originTabIsActive: selection == .pane,
            originWorkspaceIsActive: selection != .workspace,
            originPaneIsActive: selection != .pane
        )
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        let window = fixture.coordinator.activeWindowForTesting
        let normalWindow = fixture.coordinator.windowForTesting
        let normalFrame = fixture.coordinator.normalWindowFrame
        let visibility = fixture.coordinator.quakeVisibilityForTesting
        let response: TerminalAutomationHostResponse
        if selection == .tab {
            response = await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        } else {
            response = await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        }
        let created = try requireCreatedTask(response)
        switch selection {
        case .workspace:
            _ = try #require(
                fixture.coordinator.moveTabToNewWorkspaceForTesting(
                    fixture.activeTabID,
                    name: "Later User Workspace"
                )
            )
        case .tab:
            fixture.coordinator.activateTabForTesting(fixture.originTabID)
        case .pane:
            fixture.coordinator.focusPreviousPane()
        }
        let selectedStore = fixture.coordinator.workspaceStoreForTesting
        let selectedWorkspace = try #require(
            selectedStore.workspace(id: selectedStore.activeWorkspaceID)
        )
        let selectedTabID = try #require(selectedWorkspace.activeTabID)
        let selectedPaneID = try #require(selectedStore.tab(id: selectedTabID)?.activePaneID)
        #expect(selectedPaneID.rawValue != created.task.paneID)

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )

        #expect(discarded)
        let finalStore = fixture.coordinator.workspaceStoreForTesting
        #expect(finalStore.activeWorkspaceID == selectedWorkspace.id)
        #expect(finalStore.workspace(id: selectedWorkspace.id)?.activeTabID == selectedTabID)
        #expect(finalStore.tab(id: selectedTabID)?.activePaneID == selectedPaneID)
        #expect(fixture.coordinator.activeSurfaceForTesting?.paneID == selectedPaneID)
        expectManagedTaskCleanedUp(
            created,
            session: session.identity,
            in: fixture,
            surfaces: surfaces
        )
        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.coordinator.activeWindowForTesting === window)
        #expect(fixture.coordinator.windowForTesting === normalWindow)
        #expect(fixture.coordinator.normalWindowFrame == normalFrame)
        #expect(fixture.coordinator.quakeVisibilityForTesting == visibility)
    }

    @Test(arguments: LaterFocusSelection.allCases, [false, true])
    private func compensatingDiscardPreservesSelectionABA(
        selection: LaterFocusSelection,
        duringCreationCommit: Bool
    ) async throws {
        var commits: [WorkspaceStore] = []
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            originTabIsActive: false,
            originWorkspaceIsActive: false,
            originPaneIsActive: false,
            persistWorkspaceStore: {
                commits.append($0)
                let callback = onCommit
                onCommit = nil
                callback?()
            }
        )
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        let selectAwayAndBack = {
            switch selection {
            case .workspace:
                fixture.coordinator.activateWorkspace(at: 2)
                fixture.coordinator.activateWorkspace(at: 1)
            case .tab:
                fixture.coordinator.activateTabForTesting(fixture.activeTabID)
                fixture.coordinator.activateTabForTesting(fixture.originTabID)
            case .pane:
                fixture.coordinator.focusPreviousPane()
                fixture.coordinator.focusNextPane()
            }
        }
        if duringCreationCommit {
            onCommit = selectAwayAndBack
        }
        let response: TerminalAutomationHostResponse
        if selection == .workspace {
            response = await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        } else {
            response = await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        }
        let created = try requireCreatedTask(response)
        if !duringCreationCommit {
            selectAwayAndBack()
        }
        #expect(fixture.coordinator.activeSurfaceForTesting?.paneID.rawValue == created.task.paneID)
        var expected = fixture.coordinator.workspaceStoreForTesting
        #expect(expected.activeWorkspaceID == fixture.workspaceID)
        // WHY: Once the user returns, discard may apply close fallback but not creation compensation.
        _ = try SplitCoordinator().apply(
            .closePane(
                workspaceID: fixture.workspaceID,
                tabID: TabID(rawValue: created.task.tabID),
                paneID: PaneID(rawValue: created.task.paneID)
            ),
            to: &expected
        )
        let commitCount = commits.count

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )

        #expect(discarded)
        #expect(commits.count == commitCount + 1)
        #expect(commits.last == expected)
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
        #expect(
            fixture.coordinator.workspaceStoreForTesting.activeWorkspaceID == fixture.workspaceID)
        expectManagedTaskCleanedUp(
            created,
            session: session.identity,
            in: fixture,
            surfaces: surfaces
        )
    }

    @Test
    func contentUpdatesPreserveCompensationAndSurviveDiscard() async throws {
        let fixture = try makeFixture(
            originTabIsActive: false,
            originWorkspaceIsActive: false,
            originPaneIsActive: false
        )
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        var expected = fixture.coordinator.workspaceStoreForTesting
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        let replacement = try makeBinding(sessionID: "updated-session", registeredAt: 2_000)
        fixture.bridge.surfaceTabTitleHandler?(fixture.originPaneID, "Updated title")
        fixture.bridge.surfaceWorkingDirectoryHandler?(
            fixture.originPaneID, fixture.directories.current.path)
        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID,
                    previousSessionID: fixture.binding.sessionID,
                    binding: replacement
                )
            )
        )
        try expected.setTitleOverride("Updated title", for: fixture.originTabID)
        try expected.updateWorkingDirectory(
            fixture.directories.current.path, for: fixture.originPaneID)
        try expected.updateAgentResumeBinding(replacement, for: fixture.originPaneID)

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )

        #expect(discarded)
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
    }

    @Test
    func compensatingDiscardStillCleansUpWhenPreviousPaneWasRemoved() async throws {
        let fixture = try makeFixture(originPaneIsActive: false)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let previousPaneID = try #require(fixture.coordinator.activeSurfaceForTesting?.paneID)
        #expect(previousPaneID != fixture.originPaneID)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.5,
                launch: try launch(),
                policy: .keep,
                focus: true,
                expectedSession: session.identity
            )
        )
        fixture.coordinator.surfaceDidRequestCloseForTesting(
            id: previousPaneID, processAlive: false)

        let discarded = await fixture.coordinator.terminalAutomationHost.discardCreatedTask(
            created,
            expectedSession: session.identity
        )

        #expect(discarded)
        let store = fixture.coordinator.workspaceStoreForTesting
        #expect(store.activeWorkspaceID == fixture.workspaceID)
        #expect(store.workspace(id: fixture.workspaceID)?.activeTabID == fixture.originTabID)
        #expect(store.tab(id: fixture.originTabID)?.activePaneID == fixture.originPaneID)
        #expect(fixture.coordinator.activeSurfaceForTesting?.paneID == fixture.originPaneID)
        expectManagedTaskCleanedUp(
            created,
            session: session.identity,
            in: fixture,
            surfaces: [fixture.originPaneID]
        )
    }

    private func expectManagedTaskCleanedUp(
        _ created: TerminalAutomationCreatedTaskResponse,
        session: TerminalAutomationSessionIdentity,
        in fixture: AutomationFixture,
        surfaces: [PaneID]
    ) {
        let paneID = PaneID(rawValue: created.task.paneID)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        #expect(fixture.coordinator.managedSplitIDForTesting(taskID: created.task.taskID) == nil)
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: created.task.taskID,
                expectedSession: session
            ) == .notFound
        )
        #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.controller.environment(for: paneID) == nil)
        #expect(fixture.coordinator.paneAuthorizationEpochForTesting(paneID) == nil)
        #expect(fixture.coordinator.agentResumeAttemptReferenceForTesting(paneID) == nil)
        #expect(fixture.coordinator.agentResumePresentationsForTesting[paneID] == nil)
        #expect(!fixture.coordinator.surfaceFailureIDsForTesting.contains(paneID))
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspaces.allSatisfy { workspace in
                workspace.tabs.allSatisfy { !$0.root.contains(paneID) }
            }
        )
    }

    @Test
    func invalidTargetsRejectBothCreationPathsBeforeAnyMutation() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            taskIDs: (0..<6).map { uuid(110_000 + $0) },
            persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let origin = try #require(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID))
        try #require(origin.isReady)
        let fileManager = FileManager.default
        let nonExecutable = fixture.directories.root.appending(path: "non-executable-target")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonExecutable)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
        let directory = fixture.directories.root.appending(
            path: "directory-target", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let missing = fixture.directories.root.appending(path: "missing-target")
        try #require(!fileManager.fileExists(atPath: missing.path))
        try #require(!fileManager.isExecutableFile(atPath: nonExecutable.path))
        try #require(fileManager.isExecutableFile(atPath: directory.path))

        let store = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        let active = fixture.coordinator.activeSurfaceForTesting
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let responder = window.firstResponder
        let selection = fixture.coordinator.selectionGenerationForTesting
        let refreshes = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let beforeCommits = commits
        let closes = fixture.bridge.successfulSurfaceCloseObservationsForTesting
        let taskCount = fixture.coordinator.managedTaskCountForTesting
        let compensationCount = fixture.coordinator.managedCompensationRecordCountForTesting
        try #require(taskCount == 0 && compensationCount == 0)

        // WHY: One live origin and valid bundled helper isolate target preflight from stale-session rejection.
        for target in [missing, nonExecutable, directory] {
            let launch = try TerminalControlLaunch(
                executable: target.path, arguments: [], cwd: fixture.directories.managed.path)
            for kind in ManagedCreationKind.allCases {
                let response: TerminalAutomationHostResponse
                switch kind {
                case .tab:
                    response = await fixture.coordinator.terminalAutomationHost.createTab(
                        in: fixture.workspaceID, launch: launch, policy: .keep, focus: true,
                        expectedSession: session.identity)
                case .split:
                    response = await fixture.coordinator.terminalAutomationHost.createSplit(
                        anchorPaneID: fixture.originPaneID, in: fixture.workspaceID,
                        direction: .right, ratio: 0.5, launch: launch, policy: .keep, focus: true,
                        expectedSession: session.identity)
                }
                #expect(response == .failure(.invalidLaunchRequest))
                #expect(fixture.coordinator.workspaceStoreForTesting == store)
                #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
                #expect(fixture.bridge.activeSurfaceIDs == surfaces)
                // WHY: Unchanged live IDs alone would miss a transient creation followed by rollback.
                #expect(fixture.bridge.successfulSurfaceCloseObservationsForTesting == closes)
                #expect(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID) === origin)
                #expect(fixture.coordinator.activeSurfaceForTesting === active)
                #expect(fixture.coordinator.activeWindowForTesting === window)
                #expect(window.firstResponder === responder)
                #expect(fixture.coordinator.selectionGenerationForTesting == selection)
                #expect(
                    fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                        == refreshes)
                #expect(commits == beforeCommits)
                #expect(fixture.coordinator.managedTaskCountForTesting == taskCount)
                #expect(
                    fixture.coordinator.managedCompensationRecordCountForTesting
                        == compensationCount)
                #expect(try resolvedSession(in: fixture) == session)
            }
        }
    }

    @Test(arguments: ManagedRollbackSeam.allCases)
    private func managedTabRollsBackAtEverySeam(seam: ManagedRollbackSeam) async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let store = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        seam.armTab(coordinator: fixture.coordinator, bridge: fixture.bridge)

        let response = await fixture.coordinator.terminalAutomationHost.createTab(
            in: fixture.workspaceID,
            launch: try launch(),
            policy: .keep,
            focus: true,
            expectedSession: session.identity
        )

        #expect(response.errorCode == seam.errorCode)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        #expect(fixture.controller.environment(for: fixture.originPaneID) != nil)
    }

    @Test(arguments: ManagedRollbackSeam.allCases)
    private func managedSplitRollsBackAtEverySeam(seam: ManagedRollbackSeam) async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let store = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        seam.armSplit(coordinator: fixture.coordinator, bridge: fixture.bridge)

        let response = await fixture.coordinator.terminalAutomationHost.createSplit(
            anchorPaneID: fixture.originPaneID,
            in: fixture.workspaceID,
            direction: .left,
            ratio: 0.5,
            launch: try launch(),
            policy: .keep,
            focus: true,
            expectedSession: session.identity
        )

        #expect(response.errorCode == seam.errorCode)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        #expect(fixture.controller.environment(for: fixture.originPaneID) != nil)
    }

    @Test(arguments: ManagedCreationKind.allCases)
    private func duplicateTaskIDRollsBackOwnershipRegistrationWithoutAffectingExistingTask(
        kind: ManagedCreationKind
    ) async throws {
        let taskID = uuid(10)
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            originTabIsActive: false,
            originWorkspaceIsActive: false,
            originPaneIsActive: false,
            taskIDs: [taskID, taskID],
            persistWorkspaceStore: { commits.append($0) }
        )
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        // WHY: A split gives the existing task non-nil ownership metadata that must survive collision.
        let first = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: fixture.originPaneID,
                in: fixture.workspaceID,
                direction: .right,
                ratio: 0.4,
                launch: try launch(),
                policy: .keep,
                focus: false,
                expectedSession: session.identity
            )
        )
        #expect(first.task.taskID == taskID)
        let firstSplitID = try #require(first.splitID)
        let firstPaneID = PaneID(rawValue: first.task.paneID)
        let firstSurface = try #require(fixture.coordinator.surfaceForTesting(id: firstPaneID))
        let firstConfiguration = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: firstPaneID)
        )
        let originSurface = try #require(
            fixture.coordinator.surfaceForTesting(id: fixture.originPaneID)
        )
        let originEnvironment = try #require(
            fixture.controller.environment(for: fixture.originPaneID)
        )
        let beforeSession = try resolvedSession(in: fixture)
        let store = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        let activeSurface = try #require(fixture.coordinator.activeSurfaceForTesting)
        let beforeCommits = commits
        let beforeCloses = fixture.bridge.successfulSurfaceCloseObservationsForTesting
        #expect(fixture.coordinator.managedTaskCountForTesting == 1)
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: taskID,
                expectedSession: session.identity
            ) == .owned(first.task)
        )

        let response: TerminalAutomationHostResponse
        switch kind {
        case .tab:
            response = await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID,
                launch: try launch(),
                policy: .closeOnSuccess,
                focus: true,
                expectedSession: session.identity
            )
        case .split:
            response = await fixture.coordinator.terminalAutomationHost.createSplit(
                anchorPaneID: firstPaneID,
                in: fixture.workspaceID,
                direction: .left,
                ratio: 0.5,
                launch: try launch(),
                policy: .closeOnSuccess,
                focus: true,
                expectedSession: session.identity
            )
        }

        #expect(response == .failure(.modelMutationFailed))
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.activeSurfaceForTesting === activeSurface)
        #expect(commits == beforeCommits)
        #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.coordinator.managedTaskCountForTesting == 1)
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: taskID,
                expectedSession: session.identity
            ) == .owned(first.task)
        )
        #expect(fixture.coordinator.managedSplitIDForTesting(taskID: taskID) == firstSplitID)
        #expect(fixture.coordinator.surfaceForTesting(id: firstPaneID) === firstSurface)
        #expect(
            fixture.bridge.surfaceConfigurationForTesting(id: firstPaneID) == firstConfiguration)
        #expect(fixture.controller.environment(for: firstPaneID) == nil)
        #expect(fixture.coordinator.paneAuthorizationEpochForTesting(firstPaneID) == nil)
        #expect(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID) === originSurface)
        #expect(fixture.controller.environment(for: fixture.originPaneID) == originEnvironment)
        #expect(try resolvedSession(in: fixture) == beforeSession)

        let closes = fixture.bridge.successfulSurfaceCloseObservationsForTesting
        #expect(closes.count == beforeCloses.count + 1)
        #expect(Array(closes.prefix(beforeCloses.count)) == beforeCloses)
        let removedPaneID = try #require(closes.last)
        #expect(!surfaces.contains(removedPaneID))
        #expect(fixture.coordinator.surfaceForTesting(id: removedPaneID) == nil)
        #expect(fixture.bridge.surfaceConfigurationForTesting(id: removedPaneID) == nil)
        #expect(fixture.controller.environment(for: removedPaneID) == nil)
        #expect(fixture.coordinator.paneAuthorizationEpochForTesting(removedPaneID) == nil)
        #expect(fixture.coordinator.agentResumeAttemptReferenceForTesting(removedPaneID) == nil)
        #expect(fixture.coordinator.agentResumePresentationsForTesting[removedPaneID] == nil)
        #expect(!fixture.coordinator.surfaceFailureIDsForTesting.contains(removedPaneID))
        #expect(
            fixture.coordinator.workspaceStoreForTesting.workspaces.allSatisfy { workspace in
                workspace.tabs.allSatisfy { !$0.root.contains(removedPaneID) }
            }
        )
    }

    @Test
    func renderedSnapshotThrottleAndStableRevision() async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        let host = fixture.coordinator.terminalAutomationHost
        let first = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        #expect(first.task.revision == 1)
        spy.text = "changed"
        clock.now += 0.249
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(first))
        #expect(spy.readCount == 1)
        clock.now += 0.001
        let changed = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        #expect(changed.text == "changed")
        #expect(changed.task.revision == 2)
        clock.now += 0.25
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(changed))
        #expect(spy.readCount == 3)
        spy.text = String(repeating: "x", count: TerminalControlProtocol.maximumSnapshotSize)
        clock.now += 0.25
        let full = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        spy.text = "prefix" + spy.text
        clock.now += 0.25
        let truncated = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        #expect(full.text == truncated.text)
        #expect(!full.isTruncated && truncated.isTruncated)
        #expect(truncated.task.revision == full.task.revision + 1)
        #expect(truncated.text.utf8.count == 65_536)
    }

    @Test
    func staleTextKeyAndInterruptHaveNoInputSideEffects() async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        let id = created.task.taskID
        let surface = try #require(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: created.task.paneID)))
        _ = try requireSnapshot(await host.read(taskID: id, expectedSession: session.identity))
        spy.text = "new output"
        clock.now += 0.25
        #expect(
            await host.sendText(
                taskID: id, expectedRevision: 1, text: "unsafe", expectedSession: session.identity)
                == .failure(.staleTerminalRevision))
        #expect(
            await host.sendKey(
                taskID: id, expectedRevision: 1, key: .enter, expectedSession: session.identity)
                == .failure(.staleTerminalRevision))
        #expect(
            await host.interrupt(taskID: id, expectedRevision: 1, expectedSession: session.identity)
                == .failure(.staleTerminalRevision))
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(surface.automationKeyObservationsForTesting.isEmpty)
        #expect(
            await host.interrupt(taskID: id, expectedRevision: 2, expectedSession: session.identity)
                == .acknowledged(taskID: id, revision: 2))
        #expect(surface.automationKeyObservationsForTesting.map(\.key) == [.controlC])
        #expect(surface.automationKeyObservationsForTesting.first?.event.text == nil)
        #expect(
            await host.sendText(
                taskID: id, expectedRevision: 2, text: "safe", expectedSession: session.identity)
                == .acknowledged(taskID: id, revision: 2))
        #expect(
            await host.sendKey(
                taskID: id, expectedRevision: 2, key: .enter, expectedSession: session.identity)
                == .acknowledged(taskID: id, revision: 2))
        #expect(surface.automationTextObservationsForTesting.map(\.bytes) == [Data("safe".utf8)])
        #expect(
            try requireSnapshot(await host.read(taskID: id, expectedSession: session.identity)).task
                .revision == 2)
    }

    @Test
    func shellCommandFinishDoesNotCompleteManagedProcessButProcessCallbackCompletesOnce()
        async throws
    {
        let clock = AutomationClock()
        let fixture = try makeFixture(permission: .allowed, automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        let staleProcessHandler = try #require(fixture.bridge.surfaceProcessExitedHandler)
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(
                        launch: try launch(), policy: .closeOnSuccess, focus: false),
                    requestID: uuid(101_000)), in: fixture))
        let host = fixture.coordinator.terminalAutomationHost
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let baseline = try requireSnapshot(
            await host.read(taskID: task.taskID, expectedSession: session))
        let store = fixture.coordinator.workspaceStoreForTesting
        // WHY: Creation installs a new callback generation; a retained old handler has no authority.
        staleProcessHandler(pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 1))
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: task.taskID) == nil)
        let commandHandler = try #require(fixture.bridge.surfaceCommandFinishedHandler)
        var commandsDelivered = 0
        fixture.bridge.surfaceCommandFinishedHandler = { pane, command in
            commandHandler(pane, command)
            commandsDelivered += 1
        }
        #expect(!surface.processExitedForTesting)
        #expect(
            surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 0, durationNanoseconds: 1))
        try await waitForAutomation { commandsDelivered == 1 }
        #expect(!surface.processExitedForTesting)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == baseline.task)
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: task.taskID) == nil)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(
            await host.sendText(
                taskID: task.taskID, expectedRevision: baseline.task.revision, text: "safe",
                expectedSession: session)
                == .acknowledged(taskID: task.taskID, revision: baseline.task.revision))
        #expect(surface.automationTextObservationsForTesting.map(\.bytes) == [Data("safe".utf8)])
        #expect(spy.readCount == 1)

        let installed = try #require(fixture.bridge.surfaceProcessExitedHandler)
        var delivered = 0
        fixture.bridge.surfaceProcessExitedHandler = { pane, process in
            installed(pane, process)
            delivered += 1
        }
        // WHY: Exercise actual C callback -> bridge -> coordinator routing with synthetic exit data.
        // This does not establish real PTY final-tail ordering (Task 13 remains a separate gate).
        #expect(
            !surface.scheduleProcessExitedCallbackForTesting(
                exitCode: 0, runtimeMilliseconds: 17))
        #expect(
            !surface.scheduleProcessExitedCallbackForTesting(
                exitCode: 7, runtimeMilliseconds: 18))
        try await waitForAutomation { delivered == 2 }
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == baseline.task)
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: task.taskID, expectedRevision: baseline.task.revision, text: "unsafe",
                expectedSession: session) == .failure(.processFinished))
        #expect(
            fixture.coordinator.readManagedTask(taskID: task.taskID, expectedSession: session)
                == .snapshot(baseline))
        #expect(spy.readCount == 1)
        spy.text = "final rendered output"
        clock.now += 0.25
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: task.taskID)
        let final = try requireSnapshot(
            await host.read(taskID: task.taskID, expectedSession: session))
        #expect(final.text == spy.text)
        #expect(final.task.state == .succeeded && final.task.owner == .finished)
        #expect(final.task.exitCode == 0)
        #expect(spy.readCount == 2)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(
            fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter { $0 == pane }.count
                == 1)
        installed(pane, GhosttyProcessExited(exitCode: 7, runtimeMilliseconds: 19))
        #expect(
            !surface.scheduleProcessExitedCallbackForTesting(
                exitCode: 7, runtimeMilliseconds: 20))
        #expect(await host.read(taskID: task.taskID, expectedSession: session) == .snapshot(final))
        #expect(spy.readCount == 2)
    }

    @Test
    func queuedProcessExitAndRetainedHandlerFailClosedAfterSessionRevocation() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture).identity
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session))
        let pane = PaneID(rawValue: created.task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let handler = try #require(fixture.bridge.surfaceProcessExitedHandler)
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        #expect(
            !surface.scheduleProcessExitedCallbackForTesting(exitCode: 0, runtimeMilliseconds: 1))
        fixture.coordinator.revokeManagedSession(session)
        let revoked = try #require(
            fixture.coordinator.managedTaskForTesting(taskID: created.task.taskID))
        let store = fixture.coordinator.workspaceStoreForTesting
        handler(pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 2))
        await Task.yield()
        await Task.yield()
        #expect(revoked.state == .running && revoked.owner == .user)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: created.task.taskID) == revoked)
        #expect(
            fixture.coordinator.managedCompletionTaskForTesting(taskID: created.task.taskID) == nil)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(spy.readCount == 0)
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: created.task.taskID, expectedRevision: revoked.revision, text: "unsafe",
                expectedSession: session) == .failure(.targetNotOwned))
        #expect(surface.automationTextObservationsForTesting.isEmpty)
    }

    @Test(arguments: [0, 7, -1], TerminalTaskLifecyclePolicy.allCases)
    func completionRetainsFinalSnapshotBeforePolicyClosure(
        exit: Int, policy: TerminalTaskLifecyclePolicy
    ) async throws {
        let clock = AutomationClock()
        let config = try AutomationConfig(
            contents: "progress-style = false\nconfirm-close-surface = always\n")
        defer { config.remove() }
        let fixture = try makeFixture(configURL: config.url, automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: policy, focus: false,
                expectedSession: session.identity
            ))
        let pane = PaneID(rawValue: created.task.paneID)
        let interim = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        clock.now += 0.25
        // WHY: This is a managed policy seam, not evidence of a native child exit.
        let handler = try #require(fixture.bridge.surfaceProcessExitedHandler)
        handler(
            pane,
            GhosttyProcessExited(exitCode: exit < 0 ? nil : UInt8(exit), runtimeMilliseconds: 0))
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        // WHY: No suspension may let capture run between callback, ordinary read and final render.
        #expect(
            fixture.coordinator.readManagedTask(
                taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(interim))
        #expect(spy.readCount == 1)
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: created.task.taskID, expectedRevision: interim.task.revision,
                text: "unsafe",
                expectedSession: session.identity) == .failure(.processFinished))
        spy.text = "final rendered output"
        spy.onRead = { #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil) }
        defer { spy.onRead = nil }
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: created.task.taskID)
        let final = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        #expect(final.text == "final rendered output")
        #expect(spy.readCount == 2)
        #expect(
            final.task.state == (exit == 0 ? .succeeded : exit < 0 ? .finishedUnknown : .failed))
        #expect(final.task.exitCode == (exit < 0 ? nil : Int32(exit)))
        #expect(final.task.owner == .finished)
        #expect(
            (fixture.coordinator.surfaceForTesting(id: pane) == nil)
                == (exit == 0 && policy == .closeOnSuccess))
        let reads = spy.readCount
        clock.now += 1
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(final))
        #expect(spy.readCount == reads)
        #expect(
            await host.requestClose(taskID: created.task.taskID, expectedSession: session.identity)
                == .task(final.task))
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(final))
    }

    @Test(arguments: [0, 7, -1], TerminalTaskLifecyclePolicy.allCases)
    func failedFinalCaptureKeepsSurfaceUntilExplicitThrottledRetry(
        exit: Int, policy: TerminalTaskLifecyclePolicy
    ) async throws {
        let clock = AutomationClock()
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            automationNow: { clock.now }, persistWorkspaceStore: { _ in onCommit?() })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text = "old output"
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: policy, focus: false,
                expectedSession: session.identity))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let read = {
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session.identity)
        }
        let old = try requireSnapshot(read())
        spy.text = "final output"
        spy.failReads = true
        fixture.bridge.surfaceProcessExitedHandler?(
            pane,
            GhosttyProcessExited(
                exitCode: exit < 0 ? nil : UInt8(exit), runtimeMilliseconds: 0))
        // WHY: Observation revokes input, but an interim cache is not a failed final attempt.
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: id, expectedRevision: old.task.revision, text: "unsafe",
                expectedSession: session.identity) == .failure(.processFinished))
        #expect(read() == .snapshot(old))
        #expect(spy.readCount == 1)
        clock.now += 0.25
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        let classified = try #require(fixture.coordinator.managedTaskForTesting(taskID: id))
        #expect(
            classified.state == (exit == 0 ? .succeeded : exit < 0 ? .finishedUnknown : .failed))
        #expect(classified.owner == .finished)
        #expect(classified.exitCode == (exit < 0 ? nil : Int32(exit)))
        #expect(classified.revision == old.task.revision + 1)
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: id) == nil)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(fixture.bridge.activeSurfaceIDs.contains(pane))
        #expect(!fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(pane))
        #expect(read() == .failure(.internalFailure))
        #expect(spy.readCount == 2)
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: id, expectedRevision: classified.revision, key: .controlC,
                expectedSession: session.identity) == .failure(.processFinished))
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(surface.automationKeyObservationsForTesting.isEmpty)
        spy.failReads = false
        clock.now += 0.249
        #expect(read() == .failure(.internalFailure))
        #expect(spy.readCount == 2)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: id) == classified)

        var retainedAtClose: TerminalAutomationHostResponse?
        onCommit = {
            // WHY: The close commit must already expose the retained snapshot without a bridge read.
            #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
            retainedAtClose = read()
        }
        defer { onCommit = nil }
        clock.now += 0.001
        let final = try requireSnapshot(read())
        #expect(final.text == "final output")
        #expect(final.task.state == classified.state)
        #expect(final.task.owner == classified.owner)
        #expect(final.task.exitCode == classified.exitCode)
        #expect(final.task.revision == classified.revision + 1)
        #expect(spy.readCount == 3)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        let shouldClose = exit == 0 && policy == .closeOnSuccess
        #expect((fixture.coordinator.surfaceForTesting(id: pane) == nil) == shouldClose)
        #expect(retainedAtClose == (shouldClose ? .snapshot(final) : nil))
        clock.now += 1
        #expect(read() == .snapshot(final))
        #expect(spy.readCount == 3)
        #expect(
            await fixture.coordinator.terminalAutomationHost.requestClose(
                taskID: id, expectedSession: session.identity) == .task(final.task))
        #expect(retainedAtClose == .snapshot(final))
        #expect(read() == .snapshot(final))
        #expect(spy.readCount == 3)
    }

    // WHY: Darwin's real controlling-process exit revokes descendant TTY access and yields EOF.
    // These explicit policy states still prove the two-second timeout, no autoclose/early read,
    // blocked input and retry/revocation safety; native Task 13 runs do not replace this coverage.
    @Test(arguments: [GhosttyOutputState.pending, .failed])
    func incompleteOutputBlocksCaptureAndRetryUntilExplicitCompletion(state: GhosttyOutputState)
        async throws
    {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.outputState = state
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let clock = ContinuousClock()
        let started = clock.now
        surface.scheduleRuntimeCloseForTesting(processAlive: false)
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 1))
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: id, expectedRevision: 1, text: "unsafe", expectedSession: session)
                == .failure(.processFinished))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        if state == .pending { #expect(started.duration(to: clock.now) >= .seconds(2)) }
        #expect(started.duration(to: clock.now) < .seconds(5))
        #expect(fixture.coordinator.managedTaskForTesting(taskID: id)?.state == .succeeded)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: id)?.exitCode == 0)
        #expect(spy.readCount == 0)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(!fixture.coordinator.canEvictManagedTask(taskID: id, expectedSession: session))
        spy.outputState = .pending
        #expect(
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session)
                == .failure(.internalFailure))
        #expect(spy.readCount == 0)
        spy.outputState = .complete
        spy.text = "verified final"
        let final = try requireSnapshot(
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session))
        #expect(final.text == "verified final")
        #expect(spy.readCount == 1)
        // WHY: A verified retry retains revocation's existing close-on-success policy.
        fixture.coordinator.revokeManagedSession(session)
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(spy.readCount == 1)
    }

    @Test
    func manualCloseAfterIncompleteOutputRetainsTruncatedCacheAndStatus() async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        let host = fixture.coordinator.terminalAutomationHost
        // WHY: Reuse one policy fixture, not a GUI matrix or a fabricated native descendant EOF.
        for state in [GhosttyOutputState.pending, .failed] {
            spy.outputState = state
            spy.text = "interim cache, not a verified final tail"
            let created = try requireCreatedTask(
                await host.createTab(
                    in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                    focus: false, expectedSession: session))
            let id = created.task.taskID
            let pane = PaneID(rawValue: created.task.paneID)
            let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
            let read = { fixture.coordinator.readManagedTask(taskID: id, expectedSession: session) }
            let interim = try requireSnapshot(read())
            #expect(!interim.isTruncated)
            let reads = spy.readCount
            #expect(reads > 0 && spy.freeCount == reads)
            clock.now += 0.25
            let handler = try #require(fixture.bridge.surfaceProcessExitedHandler)
            handler(pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 1))
            await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
            let classified = try #require(fixture.coordinator.managedTaskForTesting(taskID: id))
            #expect(classified.state == .succeeded && classified.exitCode == 0)
            #expect(classified.owner == .finished && classified.policy == .closeOnSuccess)
            #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: id) == nil)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
            #expect(!fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(pane))
            #expect(read() == .failure(.internalFailure))
            #expect(spy.readCount == reads && spy.freeCount == reads)
            #expect(
                fixture.coordinator.sendManagedInput(
                    taskID: id, expectedRevision: classified.revision, text: "unsafe",
                    expectedSession: session) == .failure(.processFinished))
            #expect(surface.automationTextObservationsForTesting.isEmpty)
            // WHY: Keep output pending/failed across the explicit close; no successful retry
            // may silently turn the interim cache into a supposedly complete final snapshot.
            let closed = await host.requestClose(taskID: id, expectedSession: session)
            let fallback = try requireSnapshot(read())
            #expect(closed == .task(fallback.task))
            #expect(fallback.text == interim.text && fallback.isTruncated)
            #expect(fallback.text.utf8.count <= TerminalControlProtocol.maximumSnapshotSize)
            #expect(fallback.task.state == classified.state)
            #expect(fallback.task.exitCode == classified.exitCode)
            #expect(fallback.task.owner == classified.owner)
            #expect(fallback.task.policy == classified.policy)
            #expect(fallback.task.revision == classified.revision + 1)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
            #expect(!surface.isReady)
            #expect(
                fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter {
                    $0 == pane
                }.count == 1)
            clock.now += 1
            #expect(read() == .snapshot(fallback))
            #expect(spy.outputState == state)
            #expect(spy.readCount == reads && spy.freeCount == reads)
        }
    }

    @Test(arguments: ["complete", "close", "revoke", "freeze"])
    func pendingEOFRevalidatesEveryStateAccessorBoundary(ending: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.outputState = .pending
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        var observed = false
        var observations = 0
        spy.onOutputState = {
            observations += 1
            // WHY: Invalidate after an actual pending poll, not merely before the Task starts.
            guard observations == 2 else { return }
            spy.onOutputState = nil
            observed = true
            switch ending {
            case "complete": break
            case "close":
                fixture.coordinator.closeTabImmediatelyForTesting(
                    TabID(rawValue: created.task.tabID))
            case "revoke": fixture.coordinator.revokeManagedSession(session)
            default: fixture.coordinator.freezeTerminalControlForApplicationTermination()
            }
            // WHY: A late ready observation cannot authorize capture after invalidation.
            spy.outputState = .complete
        }
        defer { spy.onOutputState = nil }
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 1))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        #expect(observed && observations == 2)
        #expect(spy.readCount == (ending == "complete" ? 1 : 0))
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: id) == nil)
        if ending == "complete" {
            let final = try requireSnapshot(
                fixture.coordinator.readManagedTask(taskID: id, expectedSession: session))
            #expect(!final.isTruncated && final.task.exitCode == 0)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
            #expect(spy.readCount == 1)
        } else if ending == "close" {
            let fallback = try requireSnapshot(
                fixture.coordinator.readManagedTask(taskID: id, expectedSession: session))
            #expect(fallback.isTruncated && fallback.task.exitCode == 0)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        } else {
            #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
            #expect(fixture.coordinator.managedTaskForTesting(taskID: id)?.owner == .user)
            #expect(!fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(pane))
        }
    }

    @Test
    func successfulFinalRetryWithUnchangedTextDoesNotAdvanceRevision() async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text = "unchanged output"
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let read = {
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session.identity)
        }
        _ = try requireSnapshot(read())
        clock.now += 0.25
        spy.failReads = true
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        let classified = try #require(fixture.coordinator.managedTaskForTesting(taskID: id))
        spy.failReads = false
        clock.now += 0.25
        let final = try requireSnapshot(read())
        #expect(final.task == classified)
        #expect(final.text == spy.text)
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(read() == .snapshot(final))
        #expect(spy.readCount == 3)
    }

    @Test(arguments: [false, true])
    func failedFinalCaptureRemainsQueryableAfterExplicitClose(duringRetry: Bool) async throws {
        let clock = AutomationClock()
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let fixture = try makeFixture(configURL: config.url, automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text = String(repeating: "x", count: TerminalControlProtocol.maximumSnapshotSize)
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let read = {
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session.identity)
        }
        let old = try requireSnapshot(read())
        #expect(!old.isTruncated)
        clock.now += 0.25
        spy.failReads = true
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: id)
        let classified = try #require(fixture.coordinator.managedTaskForTesting(taskID: id))
        #expect(classified.state == .succeeded)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        #expect(!fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(pane))
        #expect(spy.readCount == 2)
        var closeResponse: TerminalAutomationHostResponse?
        if duringRetry {
            clock.now += 0.25
            spy.failReads = false
            spy.text = "must not resurrect closed capture"
            spy.onRead = {
                fixture.coordinator.closeTabImmediatelyForTesting(
                    TabID(rawValue: created.task.tabID))
            }
            // WHY: The in-flight bridge result is stale, even though subsequent reads can use the cache.
            #expect(read() == .failure(.internalFailure))
            spy.onRead = nil
        } else {
            // WHY: An explicit completed close remains permitted even when output capture failed.
            closeResponse = await host.requestClose(taskID: id, expectedSession: session.identity)
        }
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        let reads = spy.readCount
        clock.now += 1
        let retained = try requireSnapshot(read())
        #expect(retained.text == old.text)
        #expect(retained.text.utf8.count == TerminalControlProtocol.maximumSnapshotSize)
        #expect(retained.isTruncated)
        #expect(retained.task.state == classified.state)
        #expect(retained.task.owner == classified.owner)
        #expect(retained.task.exitCode == classified.exitCode)
        #expect(retained.task.revision == classified.revision + 1)
        if !duringRetry { #expect(closeResponse == .task(retained.task)) }
        #expect(
            host.inspectTask(taskID: id, expectedSession: session.identity) == .owned(retained.task)
        )
        #expect(read() == .snapshot(retained))
        #expect(spy.readCount == reads)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: id) == retained.task)
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: id) == nil)
    }

    @Test(arguments: [0, 7, -1])
    func manualCloseBeforeDeferredCaptureRetainsBoundedInterimSnapshot(exit: Int) async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text =
            "prefix" + String(repeating: "x", count: TerminalControlProtocol.maximumSnapshotSize)
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        let id = created.task.taskID
        let pane = PaneID(rawValue: created.task.paneID)
        let read = {
            fixture.coordinator.readManagedTask(taskID: id, expectedSession: session.identity)
        }
        let interim = try requireSnapshot(read())
        #expect(interim.isTruncated)
        #expect(interim.text.utf8.count == TerminalControlProtocol.maximumSnapshotSize)
        clock.now += 0.125
        fixture.bridge.surfaceProcessExitedHandler?(
            pane,
            GhosttyProcessExited(
                exitCode: exit < 0 ? nil : UInt8(exit), runtimeMilliseconds: 0))
        let deferred = try #require(fixture.coordinator.managedCompletionTaskForTesting(taskID: id))
        spy.text = "uncaptured final tail"
        // WHY: Closing inside the throttle window cannot promise a final render or wait for capture.
        fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: created.task.tabID))
        let retained = try requireSnapshot(read())
        #expect(retained.text == interim.text)
        #expect(retained.isTruncated)
        #expect(
            retained.task.state == (exit == 0 ? .succeeded : exit < 0 ? .finishedUnknown : .failed))
        #expect(retained.task.owner == .finished)
        #expect(retained.task.exitCode == (exit < 0 ? nil : Int32(exit)))
        #expect(retained.task.revision == interim.task.revision + 1)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(fixture.coordinator.managedCompletionTaskForTesting(taskID: id) == nil)
        clock.now += 1
        await deferred.value
        #expect(read() == .snapshot(retained))
        #expect(spy.readCount == 1)
        #expect(
            fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter { $0 == pane }.count
                == 1)
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: id, expectedRevision: retained.task.revision, key: .controlC,
                expectedSession: session.identity) == .failure(.processFinished))
    }

    @Test(arguments: PendingCaptureWaitEnding.allCases)
    private func waitDuringPendingCaptureHonorsCompletionDeadlineAndCancellation(
        ending: PendingCaptureWaitEnding
    ) async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(permission: .allowed, automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text = "interim"
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let active = Mutex(true)
        var taskID: UUID?
        var sleeps = 0
        let coordinator = TerminalAutomationCoordinator(
            host: fixture.coordinator.terminalAutomationHost, waitNow: { clock.now },
            waitSleep: { _ in
                sleeps += 1
                #expect(sleeps == 1)
                #expect(spy.readCount == 1)
                switch ending {
                case .completion, .failedCapture:
                    spy.text = "final"
                    spy.failReads = ending == .failedCapture
                    clock.now += 0.25
                    await fixture.coordinator.waitForManagedCompletionForTesting(
                        taskID: try #require(taskID))
                case .timeout:
                    clock.now += 1
                case .cancellation:
                    active.withLock { $0 = false }
                }
            })
        let created = try requireControlTask(
            await coordinator.handle(
                TerminalControlSocketRequest(
                    instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                    request: try TerminalControlRequest(
                        operation: .createTab(
                            launch: try launch(), policy: .closeOnSuccess, focus: false),
                        requestID: uuid(220))), context: TerminalControlRequestContext()))
        taskID = created.taskID
        let interim = try requireSnapshot(
            fixture.coordinator.readManagedTask(
                taskID: created.taskID, expectedSession: session.identity))
        fixture.bridge.surfaceProcessExitedHandler?(
            PaneID(rawValue: created.paneID),
            GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        // WHY: The injected wait clock keeps the first refresh inside the host's 250 ms window.
        let response = await coordinator.handle(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(
                    operation: .wait(
                        taskID: created.taskID, revision: interim.task.revision,
                        timeoutMilliseconds: 1_000))),
            context: TerminalControlRequestContext { active.withLock { $0 } })
        #expect(sleeps == 1)
        switch ending {
        case .completion, .failedCapture:
            let completed = try requireControlTask(response)
            #expect(completed.state == .succeeded)
            #expect(completed.owner == .finished)
            #expect(completed.exitCode == 0)
            #expect(completed.revision > interim.task.revision)
            #expect(spy.readCount == 2)
            let pane = PaneID(rawValue: created.paneID)
            #expect(
                (fixture.coordinator.surfaceForTesting(id: pane) == nil) == (ending == .completion))
        case .timeout, .cancellation:
            guard case .failure(let error) = response.result else {
                Issue.record("Expected pending wait to stop without a read error")
                return
            }
            #expect(error.code == (ending == .timeout ? .timeout : .cancelled))
            #expect(spy.readCount == 1)
        }
    }

    @Test(arguments: [false, true], [PresentationMode.normal, .quake])
    func originClosureAfterCompletionDoesNotResurrectDependentPanes(
        closeWholeTab: Bool, mode: PresentationMode
    ) async throws {
        let fixture = try makeFixture(mode: mode)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let tabTask = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        let splitTask = try requireCreatedTask(
            await host.createSplit(
                anchorPaneID: fixture.originPaneID, in: fixture.workspaceID,
                direction: .right, ratio: 0.5, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        let tasks = [tabTask.task, splitTask.task]
        let window = fixture.coordinator.activeWindowForTesting
        let frame = fixture.coordinator.normalWindowFrame
        let visibility = fixture.coordinator.quakeVisibilityForTesting
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let handler = try #require(fixture.bridge.surfaceProcessExitedHandler)
        for task in tasks {
            handler(
                PaneID(rawValue: task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        }
        let completions = tasks.compactMap {
            fixture.coordinator.managedCompletionTaskForTesting(taskID: $0.taskID)
        }
        // WHY: No suspension may let final capture run before the outer close prepares its candidate.
        if closeWholeTab {
            fixture.coordinator.closeTabImmediatelyForTesting(fixture.originTabID)
        } else {
            fixture.coordinator.surfaceDidRequestCloseForTesting(
                id: fixture.originPaneID, processAlive: false)
        }
        let pane = PaneID(rawValue: tabTask.task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        #expect(
            fixture.coordinator.readManagedTask(
                taskID: tabTask.task.taskID, expectedSession: session.identity)
                == .failure(.staleSession))
        #expect(
            fixture.coordinator.sendManagedInput(
                taskID: tabTask.task.taskID, expectedRevision: tabTask.task.revision,
                text: "revoked input", expectedSession: session.identity)
                == .failure(.staleSession))
        #expect(
            host.inspectTask(taskID: tabTask.task.taskID, expectedSession: session.identity)
                == .notOwned)
        #expect(spy.readCount == 0)
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(surface.automationKeyObservationsForTesting.isEmpty)

        // WHY: Deferred closure must mutate the latest store, not overwrite intervening user work.
        try fixture.coordinator.createShellTab()
        let survivor = try #require(fixture.coordinator.activeSurfaceForTesting)
        fixture.bridge.surfaceTabTitleHandler?(survivor.paneID, "Later user tab")
        // WHY: Revocation before capture keeps dependent panes unless the user closed their tab.
        let expected = fixture.coordinator.workspaceStoreForTesting
        for completion in completions { await completion.value }
        for task in tasks {
            await fixture.coordinator.waitForManagedCompletionForTesting(taskID: task.taskID)
        }
        let store = fixture.coordinator.workspaceStoreForTesting
        let descriptors = Set(store.workspaces.flatMap(\.tabs).flatMap(\.root.leaves))
        #expect(descriptors == Set(fixture.coordinator.surfaceIDsForTesting))
        #expect(descriptors == Set(fixture.bridge.activeSurfaceIDs))
        #expect(!descriptors.contains(fixture.originPaneID))
        for task in tasks {
            let taskPane = PaneID(rawValue: task.paneID)
            let explicitlyClosed = closeWholeTab && task.taskID == splitTask.task.taskID
            #expect(descriptors.contains(taskPane) == !explicitlyClosed)
            #expect(
                (fixture.coordinator.surfaceForTesting(id: taskPane) == nil) == explicitlyClosed)
            #expect(
                fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter {
                    $0 == taskPane
                }.count == (explicitlyClosed ? 1 : 0))
        }
        #expect(fixture.coordinator.surfaceForTesting(id: survivor.paneID) === survivor)
        #expect(store == expected)
        #expect(fixture.coordinator.managedTaskCountForTesting == (closeWholeTab ? 1 : 2))
        #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 0)
        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.coordinator.activeWindowForTesting === window)
        #expect(fixture.coordinator.normalWindowFrame == frame)
        #expect(fixture.coordinator.quakeVisibilityForTesting == visibility)
    }

    @Test(arguments: [false, true], [PresentationMode.normal, .quake])
    func revokedDeferredClosureCannotMutateAfterManualCloseOrTeardown(
        teardown: Bool, mode: PresentationMode
    ) async throws {
        let fixture = try makeFixture(mode: mode)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let created = try requireCreatedTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity))
        fixture.bridge.surfaceProcessExitedHandler?(
            PaneID(rawValue: created.task.paneID),
            GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        let completion = try #require(
            fixture.coordinator.managedCompletionTaskForTesting(taskID: created.task.taskID))
        fixture.coordinator.revokeManagedSession(session.identity)
        // WHY: Root success without a retained final capture grants no revocation autoclose.
        #expect(
            fixture.coordinator.managedCompletionTaskForTesting(taskID: created.task.taskID) == nil)
        if teardown {
            fixture.coordinator.prepareForBridgeShutdownForTesting()
        } else {
            fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: created.task.tabID))
            try fixture.coordinator.createShellTab()
        }
        let store = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.coordinator.surfaceIDsForTesting
        let closes = fixture.bridge.successfulSurfaceCloseObservationsForTesting
        await completion.value
        // WHY: Teardown intentionally retains persistence descriptors; deferred work must leave them alone.
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.surfaceIDsForTesting == surfaces)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.bridge.successfulSurfaceCloseObservationsForTesting == closes)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
        if teardown { #expect(surfaces.isEmpty) }
    }

    @Test
    func manualClosureRetainsCancelledSnapshotAndRejectsInput() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        spy.text = "retained"
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        _ = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: created.task.tabID))
        let reads = spy.readCount
        let final = try requireSnapshot(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity))
        #expect(final.text == "retained")
        #expect(final.isTruncated)
        #expect(final.task.state == .cancelled)
        #expect(final.task.owner == .finished)
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .snapshot(final))
        #expect(spy.readCount == reads)
        #expect(
            await host.interrupt(
                taskID: created.task.taskID, expectedRevision: final.task.revision,
                expectedSession: session.identity) == .failure(.processFinished))
    }

    @Test
    func sessionReplacementImmediatelyRevokesHostWithoutAnotherRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false,
                expectedSession: session.identity
            ))
        let replacement = try makeBinding(sessionID: "replacement", registeredAt: 2_000)
        #expect(
            fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                    binding: replacement
                )))
        #expect(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: created.task.paneID)) != nil)
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .failure(.staleSession))
        #expect(
            host.inspectTask(taskID: created.task.taskID, expectedSession: session.identity)
                == .notOwned)
        let revoked = try #require(
            fixture.coordinator.managedTaskForTesting(taskID: created.task.taskID))
        #expect(revoked.owner == .user)
        #expect(revoked.state == .running)
        #expect(revoked.revision == created.task.revision + 1)
    }

    @Test(arguments: [false, true])
    func managedCloseUsesExistingConfirmationQueue(allow: Bool) async throws {
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let probe = AutomationConfirmationProbe()
        let fixture = try makeFixture(configURL: config.url, confirmationPresenter: probe.present)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        let pane = PaneID(rawValue: created.task.paneID)
        try requireRunningCloseTarget(created.task, in: fixture)
        let before = fixture.coordinator.workspaceStoreForTesting
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let pending = Task { @MainActor in
            await host.requestClose(taskID: created.task.taskID, expectedSession: session.identity)
        }
        defer { pending.cancel() }
        try await probe.waitForPresentation()
        try requireRunningCloseTarget(created.task, in: fixture)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        probe.resolve(allow ? .allow : .deny)
        let result = await pending.value
        if allow {
            guard case .task(let closed) = result else {
                Issue.record("Expected closed task")
                return
            }
            #expect(closed.state == .cancelled)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        } else {
            #expect(result == .failure(.closeConfirmationDenied))
            #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
            #expect(fixture.coordinator.workspaceStoreForTesting == before)
            #expect(
                fixture.coordinator.managedTaskForTesting(taskID: created.task.taskID)
                    == created.task)
        }
    }

    @Test(arguments: [false, true])
    func automationCancellationPreservesCoalescedUserTabClose(userFirst: Bool) async throws {
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let probe = AutomationConfirmationProbe()
        let fixture = try makeFixture(configURL: config.url, confirmationPresenter: probe.present)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity))
        let tab = TabID(rawValue: created.task.tabID)
        let pane = PaneID(rawValue: created.task.paneID)
        let sibling = try requireCreatedTask(
            await host.createSplit(
                anchorPaneID: pane, in: fixture.workspaceID, direction: .right, ratio: 0.5,
                launch: try launch(), policy: .keep, focus: false, expectedSession: session.identity
            ))
        try requireRunningCloseTarget(created.task, in: fixture)
        try requireRunningCloseTarget(sibling.task, in: fixture)
        if userFirst { fixture.coordinator.requestCloseTabForTesting(tab) }
        fixture.coordinator.managedCloseWaiterJoinedForTesting = probe.participantJoined
        defer { fixture.coordinator.managedCloseWaiterJoinedForTesting = nil }
        let active = Mutex(true)
        let pending = Task { @MainActor in
            await host.requestClose(
                taskID: created.task.taskID, expectedSession: session.identity,
                context: TerminalControlRequestContext { active.withLock { $0 } })
        }
        defer {
            active.withLock { $0 = false }
            pending.cancel()
        }
        if userFirst {
            // WHY: A user-owned prompt is already visible; wait for the automation participant itself.
            try await probe.waitForParticipants(count: 1)
        } else {
            try await probe.waitForPresentation()
            try requireRunningCloseTarget(created.task, in: fixture)
            try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
            fixture.coordinator.requestCloseTabForTesting(tab)
        }
        fixture.coordinator.managedCloseWaiterJoinedForTesting = nil
        try requireRunningCloseTarget(created.task, in: fixture)
        try requireRunningCloseTarget(sibling.task, in: fixture)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        #expect(probe.presentationCount == 1)
        active.withLock { $0 = false }
        #expect(await pending.value == .failure(.cancelled))
        #expect(!probe.wasDismissed)
        #expect(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        #expect(fixture.coordinator.managedCloseDecisionCountForTesting == 0)
        probe.resolve(.allow)
        probe.resolve(.allow)
        #expect(fixture.coordinator.workspaceStoreForTesting.tab(id: tab) == nil)
        for task in [created.task, sibling.task] {
            let closedPane = PaneID(rawValue: task.paneID)
            #expect(fixture.coordinator.surfaceForTesting(id: closedPane) == nil)
            #expect(
                fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter {
                    $0 == closedPane
                }.count == 1)
        }
    }

    @Test
    func cancellingOriginatingCloseTaskThroughRouteInvalidatesConfirmationAndReplay() async throws {
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let probe = AutomationConfirmationProbe()
        let fixture = try makeFixture(
            configURL: config.url, confirmationPresenter: probe.present, permission: .allowed)
        defer { fixture.shutdown() }
        let context = TerminalControlRequestContext()
        let created = try requireControlTask(
            await fixture.coordinator.handleTerminalAutomationRequest(
                TerminalControlSocketRequest(
                    instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(210))),
                context: context))
        let pane = PaneID(rawValue: created.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let before = fixture.coordinator.workspaceStoreForTesting
        let request = TerminalControlSocketRequest(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            request: try TerminalControlRequest(
                operation: .close(taskID: created.taskID), requestID: uuid(211)))
        try requireRunningCloseTarget(created, in: fixture)
        let pending = Task { @MainActor in
            await fixture.coordinator.handleTerminalAutomationRequest(request, context: context)
        }
        defer { pending.cancel() }
        try await probe.waitForPresentation()
        try requireRunningCloseTarget(created, in: fixture)
        let lateAllow = try #require(probe.completion)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        pending.cancel()
        let result = await pending.value
        guard case .failure(let error) = result.result else {
            Issue.record("Expected cancelled originating close")
            return
        }
        #expect(error.code == .cancelled)
        #expect(context.isActive)
        // WHY: Dismissal is the cleanup boundary, independent of which cancelled Task resumes first.
        try await probe.waitForDismissal()
        #expect(fixture.coordinator.activeConfirmationForTesting == nil)
        #expect(fixture.coordinator.pendingConfirmationCountForTesting == 0)
        #expect(fixture.coordinator.managedCloseDecisionCountForTesting == 0)
        lateAllow(.allow)
        let replay = await fixture.coordinator.handleTerminalAutomationRequest(
            request, context: context)
        #expect(replay == result)
        #expect(probe.presentationCount == 1)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(fixture.bridge.activeSurfaceIDs.contains(pane))
        #expect(!fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(pane))
        #expect(fixture.coordinator.managedTaskForTesting(taskID: created.taskID) == created)
    }

    @Test(arguments: [false, true], [false, true])
    func cancellingOneConcurrentCloseCompletesTheWholeCohort(
        allowNext: Bool, cancelTask: Bool
    ) async throws {
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let probe = AutomationConfirmationProbe()
        let fixture = try makeFixture(
            configURL: config.url, confirmationPresenter: probe.present, permission: .allowed)
        defer { fixture.shutdown() }
        fixture.coordinator.managedCloseWaiterJoinedForTesting = probe.participantJoined
        defer { fixture.coordinator.managedCloseWaiterJoinedForTesting = nil }
        let created = try requireControlTask(
            await fixture.coordinator.handleTerminalAutomationRequest(
                TerminalControlSocketRequest(
                    instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                    request: try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(200))),
                context: TerminalControlRequestContext()))
        let pane = PaneID(rawValue: created.paneID)
        let before = fixture.coordinator.workspaceStoreForTesting
        let session = try resolvedSession(in: fixture)
        let active = Mutex(true)
        let firstRequest = TerminalControlSocketRequest(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            request: try TerminalControlRequest(
                operation: .close(taskID: created.taskID),
                requestID: uuid(201)))
        let secondRequest = TerminalControlSocketRequest(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            request: try TerminalControlRequest(
                operation: .close(taskID: created.taskID),
                requestID: uuid(202)))
        try requireRunningCloseTarget(created, in: fixture)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let first = Task { @MainActor in
            await fixture.coordinator.handleTerminalAutomationRequest(
                firstRequest,
                context: TerminalControlRequestContext {
                    active.withLock { $0 }
                })
        }
        defer {
            active.withLock { $0 = false }
            first.cancel()
        }
        let second = Task { @MainActor in
            await fixture.coordinator.handleTerminalAutomationRequest(
                secondRequest, context: TerminalControlRequestContext())
        }
        defer { second.cancel() }
        try await probe.waitForParticipants()
        try requireRunningCloseTarget(created, in: fixture)
        #expect(probe.presentationCount == 1)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        #expect(fixture.coordinator.pendingConfirmationCountForTesting == 0)
        let staleCompletion = try #require(probe.completion)
        if cancelTask {
            first.cancel()
            #expect(active.withLock { $0 })
        } else {
            active.withLock { $0 = false }
        }
        let firstResult = await first.value
        let secondResult = await second.value
        guard case .failure(let firstError) = firstResult.result,
            case .failure(let secondError) = secondResult.result
        else {
            Issue.record("Expected both close participants to finish cancelled")
            return
        }
        #expect(firstError.code == .cancelled)
        #expect(secondError.code == .cancelled)
        #expect(fixture.coordinator.managedCloseDecisionCountForTesting == 0)
        #expect(fixture.coordinator.activeConfirmationForTesting == nil)
        staleCompletion(.allow)
        staleCompletion(.deny)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        try #require(fixture.coordinator.managedTaskForTesting(taskID: created.taskID) == created)
        #expect(try resolvedSession(in: fixture) == session)
        try #require(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        try requireRunningCloseTarget(created, in: fixture)
        try #require(fixture.coordinator.activeConfirmationForTesting == nil)
        try #require(fixture.coordinator.pendingConfirmationCountForTesting == 0)
        try #require(fixture.coordinator.managedCloseDecisionCountForTesting == 0)

        probe.resetPresentation()
        let next = Task { @MainActor in
            await fixture.coordinator.terminalAutomationHost.requestClose(
                taskID: created.taskID, expectedSession: session.identity)
        }
        defer { next.cancel() }
        try await probe.waitForPresentation()
        try requireRunningCloseTarget(created, in: fixture)
        #expect(probe.presentationCount == 2)
        staleCompletion(.allow)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        probe.resolve(allowNext ? .allow : .deny)
        let result = await next.value
        if allowNext {
            guard case .task = result else {
                Issue.record("Expected a closed task")
                return
            }
        } else {
            #expect(result == .failure(.closeConfirmationDenied))
            #expect(fixture.coordinator.workspaceStoreForTesting == before)
        }
        probe.resolve(.allow)
        #expect((fixture.coordinator.surfaceForTesting(id: pane) == nil) == allowNext)
        #expect(
            fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter {
                $0 == pane
            }.count == (allowNext ? 1 : 0))
        #expect(fixture.coordinator.managedCloseDecisionCountForTesting == 0)
    }

    @Test(arguments: [false, true])
    func pendingConfirmationCannotCloseAfterCancellationOrRebind(rebind: Bool) async throws {
        let config = try AutomationConfig(contents: "confirm-close-surface = always\n")
        defer { config.remove() }
        let probe = AutomationConfirmationProbe()
        let fixture = try makeFixture(configURL: config.url, confirmationPresenter: probe.present)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        let pane = PaneID(rawValue: created.task.paneID)
        try requireRunningCloseTarget(created.task, in: fixture)
        let pending = Task { @MainActor in
            await host.requestClose(taskID: created.task.taskID, expectedSession: session.identity)
        }
        defer { pending.cancel() }
        try await probe.waitForPresentation()
        try requireRunningCloseTarget(created.task, in: fixture)
        try #require(fixture.coordinator.activeConfirmationForTesting == .close(pane))
        if rebind {
            let replacement = try makeBinding(sessionID: "replacement", registeredAt: 2_000)
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .replace(
                        paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                        binding: replacement
                    )))
        } else {
            pending.cancel()
        }
        let result = await pending.value
        #expect(result == .failure(rebind ? .staleSession : .cancelled))
        probe.resolve(.allow)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        #expect(fixture.coordinator.activeConfirmationForTesting == nil)
    }

    @Test
    func completionCannotRestoreRevokedCapabilitiesDuringBridgeRead() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .closeOnSuccess,
                focus: false, expectedSession: session.identity
            ))
        let pane = PaneID(rawValue: created.task.paneID)
        let replacement = try makeBinding(sessionID: "replacement", registeredAt: 2_000)
        defer { spy.onRead = nil }
        spy.onRead = {
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .replace(
                        paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                        binding: replacement
                    )))
        }
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: created.task.taskID)
        // WHY: Rebinding during capture invalidates the result, not the user's native pane.
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        #expect(
            await host.read(taskID: created.task.taskID, expectedSession: session.identity)
                == .failure(.staleSession))
        #expect(
            host.inspectTask(taskID: created.task.taskID, expectedSession: session.identity)
                == .notOwned)
    }

    @Test
    func rebindDuringPreInputReadFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let created = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity
            ))
        let surface = try #require(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: created.task.paneID)))
        let replacement = try makeBinding(sessionID: "replacement", registeredAt: 2_000)
        spy.onRead = {
            _ = fixture.coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                    binding: replacement
                ))
        }
        defer { spy.onRead = nil }
        #expect(
            await host.sendText(
                taskID: created.task.taskID, expectedRevision: 1, text: "unsafe",
                expectedSession: session.identity) == .failure(.staleSession))
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(surface.automationKeyObservationsForTesting.isEmpty)
    }

    @Test
    func finalRetryAtFullRetentionCannotLoseDeferredMandatoryClose() async throws {
        let clock = AutomationClock()
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            taskIDs: (0..<34).map { uuid(94_000 + $0) }, automationNow: { clock.now },
            persistWorkspaceStore: { _ in onCommit?() })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        var retained: [TerminalAutomationCreatedTaskResponse] = []
        for index in 0..<32 {
            let created = try requireCreatedTask(
                await host.createTab(
                    in: fixture.workspaceID, launch: try launch(),
                    policy: index == 0 ? .closeOnSuccess : .keep, focus: false,
                    expectedSession: session.identity))
            retained.append(created)
            spy.failReads = index == 0
            fixture.bridge.surfaceProcessExitedHandler?(
                PaneID(rawValue: created.task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
            await fixture.coordinator.waitForManagedCompletionForTesting(
                taskID: created.task.taskID)
            if index > 0 {
                fixture.coordinator.closeTabImmediatelyForTesting(
                    TabID(rawValue: created.task.tabID))
            }
        }
        let oldest = retained[0].task
        let pane = PaneID(rawValue: oldest.paneID)
        #expect(fixture.coordinator.managedTaskCountForTesting == 32)
        #expect(!host.canEvictTask(taskID: oldest.taskID, expectedSession: session.identity))
        spy.failReads = false
        spy.text = "final retry output"
        clock.now += 0.25
        let final = try requireSnapshot(
            fixture.coordinator.readManagedTask(
                taskID: oldest.taskID, expectedSession: session.identity))
        let deferred = try #require(
            fixture.coordinator.managedCompletionTaskForTesting(taskID: oldest.taskID))
        onCommit = {
            // WHY: Prove creation reaches eviction before the deferred close gets a turn.
            #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
            #expect(!host.canEvictTask(taskID: oldest.taskID, expectedSession: session.identity))
        }
        _ = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity))
        onCommit = nil
        #expect(fixture.coordinator.managedTaskCountForTesting == 32)
        #expect(
            host.inspectTask(taskID: retained[1].task.taskID, expectedSession: session.identity)
                == .notFound)
        #expect(
            host.inspectTask(taskID: oldest.taskID, expectedSession: session.identity)
                == .owned(final.task))
        await deferred.value
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        #expect(!fixture.bridge.activeSurfaceIDs.contains(pane))
        #expect(
            fixture.coordinator.workspaceStoreForTesting.tab(id: TabID(rawValue: oldest.tabID))
                == nil)
        #expect(
            fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter { $0 == pane }.count
                == 1)
        #expect(host.canEvictTask(taskID: oldest.taskID, expectedSession: session.identity))
        #expect(
            fixture.coordinator.readManagedTask(
                taskID: oldest.taskID, expectedSession: session.identity)
                == .snapshot(final))
        _ = try requireCreatedTask(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity))
        #expect(
            host.inspectTask(taskID: oldest.taskID, expectedSession: session.identity) == .notFound)
        #expect(fixture.coordinator.managedTaskCountForTesting == 32)
        #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 0)
    }

    @Test
    func acceptedCloseAndSessionChurnDoNotAccumulateCompensationRecords() async throws {
        let fixture = try makeFixture(
            permission: .allowed, taskIDs: (0..<34).map { uuid(95_000 + $0) })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        for index in 0..<34 {
            let created = try requireControlTask(
                await fixture.coordinator.handleTerminalAutomationRequest(
                    TerminalControlSocketRequest(
                        instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                        request: try TerminalControlRequest(
                            operation: .createTab(
                                launch: try launch(), policy: .keep, focus: false),
                            requestID: uuid(96_000 + index))),
                    context: TerminalControlRequestContext()))
            if index.isMultiple(of: 2) {
                fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: created.tabID))
            }
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .unregister(
                        paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                        sessionID: fixture.binding.sessionID)))
            if !index.isMultiple(of: 2) {
                fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: created.tabID))
            }
            #expect(fixture.coordinator.managedTaskCountForTesting == 0)
            #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 0)
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .register(
                        paneID: fixture.originPaneID, binding: fixture.binding)))
        }
    }

    @Test
    func unacceptedClosedCreationRetainsExactIdempotentCompensationUntilTeardown() async throws {
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            permission: .allowed,
            persistWorkspaceStore: { _ in
                let callback = onCommit
                onCommit = nil
                callback?()
            })
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        var unaccepted: TerminalAutomationCreatedTaskResponse?
        onCommit = {
            guard let task = fixture.coordinator.managedTaskForTesting(taskID: uuid(10)) else {
                Issue.record("Expected unaccepted host creation")
                return
            }
            unaccepted = TerminalAutomationCreatedTaskResponse(task: task, splitID: nil)
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .unregister(
                        paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                        sessionID: fixture.binding.sessionID)))
            fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: task.tabID))
            #expect(fixture.coordinator.managedTaskCountForTesting == 0)
            #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 1)
        }
        let response = await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                request: try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(97_000))), context: TerminalControlRequestContext())
        guard case .failure(let error) = response.result else {
            Issue.record("Expected revoked creation")
            return
        }
        #expect(error.code == .permissionRevoked || error.code == .staleSession)
        let created = try #require(unaccepted)
        let closes = fixture.bridge.successfulSurfaceCloseObservationsForTesting
        for _ in 0..<2 {
            #expect(
                fixture.coordinator.discardManagedTask(created, expectedSession: session.identity))
        }
        let wrongSplit = TerminalAutomationCreatedTaskResponse(task: created.task, splitID: UUID())
        #expect(
            !fixture.coordinator.discardManagedTask(wrongSplit, expectedSession: session.identity))
        #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 1)
        #expect(fixture.bridge.successfulSurfaceCloseObservationsForTesting == closes)
        fixture.coordinator.prepareForBridgeShutdownForTesting()
        #expect(fixture.coordinator.managedCompensationRecordCountForTesting == 0)
    }

    @Test
    func retainedHostSnapshotsAreBoundedAndRunningLimitIsEnforced() async throws {
        let clock = AutomationClock()
        let fixture = try makeFixture(
            taskIDs: (0..<40).map { uuid(90_000 + $0) }, automationNow: { clock.now })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        var created: [TerminalAutomationCreatedTaskResponse] = []
        for _ in 0..<8 {
            created.append(
                try requireCreatedTask(
                    await host.createTab(
                        in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                        expectedSession: session.identity
                    )))
        }
        #expect(
            await host.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session.identity) == .failure(.resourceLimit))
        for value in created {
            fixture.bridge.surfaceProcessExitedHandler?(
                PaneID(rawValue: value.task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
            await fixture.coordinator.waitForManagedCompletionForTesting(taskID: value.task.taskID)
        }
        for _ in 8..<33 {
            let value = try requireCreatedTask(
                await host.createTab(
                    in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                    expectedSession: session.identity
                ))
            fixture.bridge.surfaceProcessExitedHandler?(
                PaneID(rawValue: value.task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
            await fixture.coordinator.waitForManagedCompletionForTesting(taskID: value.task.taskID)
        }
        #expect(fixture.coordinator.managedTaskCountForTesting == 32)
        #expect(
            host.inspectTask(taskID: created[0].task.taskID, expectedSession: session.identity)
                == .notFound)
    }

    @Test
    func permissionCoalescesConcurrentRequestsAndDenialLastsForExactSession() async throws {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present)
        defer {
            probe.resolve(.denied)
            fixture.shutdown()
        }
        let before = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.bridge.activeSurfaceIDs
        var first: TerminalControlResponse?
        var second: TerminalControlResponse?
        let list = try TerminalControlRequest(operation: .list)
        let create = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(98_001))
        let a = Task { first = await controlRequest(list, in: fixture) }
        let b = Task { second = await controlRequest(create, in: fixture) }
        defer {
            a.cancel()
            b.cancel()
        }
        try await waitForAutomation { probe.count == 1 }
        #expect(first == nil && second == nil)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        probe.resolve(.denied)
        try await waitForAutomation { first != nil && second != nil }
        expectControlFailure(try #require(first), .permissionDenied)
        expectControlFailure(try #require(second), .permissionDenied)
        expectControlFailure(await controlRequest(list, in: fixture), .permissionDenied)
        #expect(probe.count == 1)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
    }

    @Test
    func denialAttentionCancellationAndUnregisterPreserveBoundedRevokedRecords() async throws {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present)
        let coordinator = TerminalAutomationCoordinator(
            host: fixture.coordinator.terminalAutomationHost)
        defer {
            fixture.coordinator.terminalAutomationAttentionHandler = nil
            probe.resolve(.denied)
            coordinator.cancelPendingPermissions()
            fixture.shutdown()
        }
        let surfaces = fixture.bridge.activeSurfaceIDs
        let origin = try #require(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID))
        let list = TerminalControlSocketRequest(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            request: try TerminalControlRequest(operation: .list))
        var retired: [TerminalAutomationSessionIdentity] = []
        var attention: [TerminalAutomationAttention] = []

        // WHY: Cross the 32-record limit twice so cleanup must keep progressing after reentrancy.
        for index in 0..<66 {
            if index > 0 {
                try #require(
                    fixture.coordinator.handleAgentSessionLifecycleAction(
                        .register(paneID: fixture.originPaneID, binding: fixture.binding)))
            }
            let session = try resolvedSession(in: fixture).identity
            try #require(!retired.contains(session))
            var response: TerminalControlResponse?
            let pending = Task { @MainActor in
                response = await coordinator.handle(list, context: TerminalControlRequestContext())
            }
            defer {
                pending.cancel()
                fixture.coordinator.terminalAutomationAttentionHandler = nil
            }
            fixture.coordinator.terminalAutomationAttentionHandler = { event in
                attention.append(event)
                #expect(event == .permissionDenied(session))
                // WHY: Cancellation keeps the original waiter from revalidating and repairing stale state.
                pending.cancel()
                #expect(
                    fixture.coordinator.handleAgentSessionLifecycleAction(
                        .unregister(
                            paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                            sessionID: fixture.binding.sessionID)))
                // WHY: This separately instantiated coordinator needs the same lifecycle notification
                // that WindowCoordinator sends to its private request coordinator on unregister.
                coordinator.originSessionDidChange(originPaneID: fixture.originPaneID)
            }
            try await waitForAutomation { probe.count == index + 1 }
            #expect(response == nil)
            probe.resolve(.denied)
            try await waitForAutomation { response != nil }
            await pending.value
            expectControlFailure(try #require(response), .cancelled)
            #expect(pending.isCancelled)
            retired.append(session)
            #expect(attention == retired.map { .permissionDenied($0) })
            #expect(probe.sessions == retired)
            #expect(
                fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                    instanceID: fixture.instanceID, originPaneID: fixture.originPaneID) == nil)
            // WHY: Inspect before another request or origin notification can mask an overwritten revocation.
            #expect(coordinator.retainsSessionRecordForTesting(session))
            #expect(
                retired.filter { coordinator.retainsSessionRecordForTesting($0) }.count
                    == min(retired.count, 32))
            for evicted in retired.dropLast(32) {
                #expect(!coordinator.retainsSessionRecordForTesting(evicted))
            }
            #expect(fixture.coordinator.managedTaskCountForTesting == 0)
            #expect(fixture.bridge.activeSurfaceIDs == surfaces)
            #expect(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID) === origin)
        }
    }

    @Test
    func permissionTimeoutCreatesNoResources() async throws {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present, permissionTimeout: 0.05)
        defer {
            probe.resolve(.denied)
            fixture.shutdown()
        }
        let before = fixture.coordinator.workspaceStoreForTesting
        let surfaces = fixture.bridge.activeSurfaceIDs
        let create = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(98_002))
        var response: TerminalControlResponse?
        let request = Task { response = await controlRequest(create, in: fixture) }
        defer { request.cancel() }
        try await waitForAutomation { response != nil }
        expectControlFailure(try #require(response), .permissionUnavailable)
        probe.resolve(.allowed)
        try await waitForAutomation { probe.didReturn }
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.bridge.activeSurfaceIDs == surfaces)
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
    }

    @Test
    func concurrentAllowedRequestsPromptOnceAndReuseGrant() async throws {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present)
        defer {
            probe.resolve(.denied)
            fixture.shutdown()
        }
        let list = try TerminalControlRequest(operation: .list)
        var first: TerminalControlResponse?
        var second: TerminalControlResponse?
        let a = Task { first = await controlRequest(list, in: fixture) }
        let b = Task { second = await controlRequest(list, in: fixture) }
        defer {
            a.cancel()
            b.cancel()
        }
        try await waitForAutomation { probe.count == 1 }
        probe.resolve(.allowed)
        try await waitForAutomation { first != nil && second != nil }
        guard case .list = first?.result, case .list = second?.result else {
            Issue.record("Expected two granted lists")
            return
        }
        _ = await controlRequest(list, in: fixture)
        #expect(probe.count == 1)
        #expect(probe.sessions == [try resolvedSession(in: fixture).identity])
    }

    @Test(arguments: [false, true])
    func productionPermissionUnavailableWithoutUsableParent(hidden: Bool) async throws {
        let fixture = try makeFixture(useProductionPermission: true)
        defer { fixture.shutdown() }
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let before = fixture.coordinator.workspaceStoreForTesting
        let surfaceIDs = fixture.bridge.activeSurfaceIDs
        let unrelated = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            if unrelated.sheetParent === window { window.endSheet(unrelated) }
            unrelated.orderOut(nil)
        }
        if hidden {
            window.orderOut(nil)
        } else {
            window.beginSheet(unrelated, completionHandler: nil)
        }
        let response = await controlRequest(
            try TerminalControlRequest(
                operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                requestID: uuid(98_003)), in: fixture)
        expectControlFailure(response, .permissionUnavailable)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        if !hidden { #expect(window.attachedSheet === unrelated) }
    }

    @Test(arguments: AutomationPermissionEnding.allCases)
    private func pendingPermissionEndsWithoutLateGrant(ending: AutomationPermissionEnding)
        async throws
    {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present)
        defer {
            probe.resolve(.denied)
            fixture.shutdown()
        }
        var response: TerminalControlResponse?
        let create = try TerminalControlRequest(
            operation: .createTab(launch: try launch(), policy: .keep, focus: false),
            requestID: uuid(98_004))
        let request = Task { response = await controlRequest(create, in: fixture) }
        defer { request.cancel() }
        try await waitForAutomation { probe.count == 1 }
        switch ending {
        case .revoke:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .unregister(
                        paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                        sessionID: fixture.binding.sessionID)))
        case .replace:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .replace(
                        paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                        binding: try makeBinding(sessionID: "new-session", registeredAt: 2_000))))
        case .transition:
            fixture.coordinator.togglePresentationMode()
        case .termination:
            fixture.coordinator.prepareForApplicationTermination()
        }
        try await waitForAutomation { response != nil }
        guard case .failure = response?.result else {
            Issue.record("Expected fail-closed permission")
            return
        }
        probe.resolve(.allowed)
        try await waitForAutomation { probe.didReturn }
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
    }

    @Test
    func cancelledPermissionCohortCannotJoinPromptAfterWindowTransition() async throws {
        let probe = AutomationPermissionProbe()
        let fixture = try makeFixture(permissionPresenter: probe.present)
        defer {
            probe.resolve(.denied)
            fixture.shutdown()
        }
        let list = try TerminalControlRequest(operation: .list)
        var first: TerminalControlResponse?
        var second: TerminalControlResponse?
        let a = Task { first = await controlRequest(list, in: fixture) }
        defer { a.cancel() }
        try await waitForAutomation { probe.count == 1 }
        probe.resolve(.allowed)
        fixture.coordinator.togglePresentationMode()
        let b = Task { second = await controlRequest(list, in: fixture) }
        defer { b.cancel() }
        try await waitForAutomation { probe.count == 2 }
        probe.resolve(.allowed)
        try await waitForAutomation { first != nil && second != nil }
        expectControlFailure(try #require(first), .permissionUnavailable)
        guard case .list = second?.result else {
            Issue.record("Expected new-parent grant")
            return
        }
        #expect(probe.sessions.count == 2 && probe.sessions[0] == probe.sessions[1])
        #expect(fixture.coordinator.managedTaskCountForTesting == 0)
    }

    @Test
    func requestUserInputChangesRevisionWithoutTextFocusesAndRequiresExplicitReturn() async throws {
        var prompts = 0
        let fixture = try makeFixture(permissionPresenter: { _ in
            prompts += 1
            return .allowed
        })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(98_005)), in: fixture))
        let paneID = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: paneID))
        let session = try resolvedSession(in: fixture)
        let initialSnapshot = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: session.identity))
        var presentations: [TerminalAutomationPresentationEvent] = []
        var attention: [TerminalAutomationAttention] = []
        fixture.coordinator.terminalAutomationPresentationHandler = {
            #expect(fixture.coordinator.activeSurfaceForTesting === surface)
            #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === surface)
            #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
            presentations.append($0)
        }
        fixture.coordinator.terminalAutomationAttentionHandler = {
            #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === surface)
            attention.append($0)
        }
        let waiting = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_006)),
                in: fixture))
        #expect(waiting.owner == .user && waiting.state == .waitingForUser)
        #expect(waiting.revision == initialSnapshot.task.revision + 1)
        #expect(presentations == [.taskRequiresPresentation(task.taskID)])
        #expect(attention == [.taskRequiresAttention(task.taskID)])
        #expect(fixture.coordinator.activeSurfaceForTesting === surface)
        #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === surface)
        let waitingSnapshot = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: session.identity))
        #expect(waitingSnapshot.text == initialSnapshot.text)
        let inputs = surface.automationTextObservationsForTesting.count
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .sendText(
                        taskID: task.taskID, expectedRevision: waiting.revision, text: "agent-input"
                    ),
                    requestID: uuid(98_007)), in: fixture), .userControlsPane)
        #expect(surface.automationTextObservationsForTesting.count == inputs)
        #expect(fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        let returned = try #require(fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        #expect(returned.owner == .agent && returned.state == .running)
        #expect(returned.revision == waiting.revision + 1)
        #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        let sent = await controlRequest(
            try TerminalControlRequest(
                operation: .sendKey(
                    taskID: task.taskID, expectedRevision: returned.revision, key: .enter),
                requestID: uuid(98_008)), in: fixture)
        guard case .acknowledged = sent.result else {
            Issue.record("Expected resumed agent input")
            return
        }
        #expect(prompts == 1)
    }

    @Test
    func requestUserInputWithUnrelatedSheetFailsUnchangedThenNewRequestFocusesExactPane()
        async throws
    {
        var persisted: [WorkspaceStore] = []
        let fixture = try makeFixture(
            permission: .allowed, originWorkspaceIsActive: false,
            persistWorkspaceStore: { persisted.append($0) })
        defer { fixture.shutdown() }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .right, ratio: 0.5, launch: try launch(),
                        policy: .keep, focus: false),
                    requestID: uuid(98_030)), in: fixture))
        let session = try resolvedSession(in: fixture)
        let host = fixture.coordinator.terminalAutomationHost
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let unrelated = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            if unrelated.sheetParent === window { window.endSheet(unrelated) }
            unrelated.orderOut(nil)
        }
        window.beginSheet(unrelated, completionHandler: nil)
        try #require(window.attachedSheet === unrelated)
        let before = fixture.coordinator.workspaceStoreForTesting
        let beforeTask = try #require(
            fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        let beforeSurface = fixture.coordinator.activeSurfaceForTesting
        let beforeResponder = window.firstResponder
        let surfaceIDs = fixture.bridge.activeSurfaceIDs
        let persistenceCount = persisted.count
        let mode = fixture.coordinator.presentationMode
        var presentations: [TerminalAutomationPresentationEvent] = []
        var attention: [TerminalAutomationAttention] = []
        fixture.coordinator.terminalAutomationPresentationHandler = { presentations.append($0) }
        fixture.coordinator.terminalAutomationAttentionHandler = { attention.append($0) }
        let blocked = try TerminalControlRequest(
            operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_031))
        expectControlFailure(await controlRequest(blocked, in: fixture), .modelMutationFailed)
        #expect(
            await host.focus(taskID: task.taskID, expectedSession: session.identity)
                == .failure(.modelMutationFailed))
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == beforeTask)
        #expect(beforeTask.owner == .agent && beforeTask.state == .running)
        #expect(
            host.inspectTask(taskID: task.taskID, expectedSession: session.identity)
                == .owned(beforeTask))
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(persisted.count == persistenceCount)
        #expect(fixture.coordinator.activeSurfaceForTesting === beforeSurface)
        #expect(window.firstResponder === beforeResponder)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(surface.automationKeyObservationsForTesting.isEmpty)
        #expect(presentations.isEmpty && attention.isEmpty)
        #expect(window.attachedSheet === unrelated)
        #expect(fixture.coordinator.presentationMode == mode)

        window.endSheet(unrelated)
        unrelated.orderOut(nil)
        try await waitForAutomation { window.attachedSheet == nil }
        // WHY: Failed mutations are replayed; only a new request may retry focus after dismissal.
        expectControlFailure(await controlRequest(blocked, in: fixture), .modelMutationFailed)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == beforeTask)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(presentations.isEmpty && attention.isEmpty)
        var expected = before
        try expected.activateWorkspace(fixture.workspaceID)
        try expected.activateTab(TabID(rawValue: task.tabID), in: fixture.workspaceID)
        _ = try SplitCoordinator().apply(
            .activatePane(
                workspaceID: fixture.workspaceID, tabID: TabID(rawValue: task.tabID), paneID: pane),
            to: &expected)
        let waiting = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_032)),
                in: fixture))
        #expect(waiting.owner == .user && waiting.state == .waitingForUser)
        #expect(waiting.revision == beforeTask.revision + 1)
        #expect(
            host.inspectTask(taskID: task.taskID, expectedSession: session.identity)
                == .owned(waiting))
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
        #expect(fixture.coordinator.activeSurfaceForTesting === surface)
        #expect(window.firstResponder === surface)
        #expect(fixture.coordinator.activeWindowForTesting === window)
        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        #expect(presentations == [.taskRequiresPresentation(task.taskID)])
        #expect(attention == [.taskRequiresAttention(task.taskID)])
        // WHY: Publication must not execute focus or undo a later user selection.
        fixture.coordinator.activateWorkspace(at: 2)
        let selected = fixture.coordinator.workspaceStoreForTesting
        let selectedResponder = window.firstResponder
        fixture.coordinator.publishTerminalAutomationPresentation(
            .taskRequiresPresentation(task.taskID))
        #expect(fixture.coordinator.workspaceStoreForTesting == selected)
        #expect(window.firstResponder === selectedResponder)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == waiting)
        #expect(fixture.coordinator.returnControlToAgent(taskID: task.taskID))
    }

    @Test(arguments: [false, true])
    func managedFocusCommitFailureCannotReportSuccess(requestsInput: Bool) async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(98_033)), in: fixture))
        let before = fixture.coordinator.workspaceStoreForTesting
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let responder = window.firstResponder
        let surface = fixture.coordinator.activeSurfaceForTesting
        let surfaceIDs = fixture.bridge.activeSurfaceIDs
        var presentations: [TerminalAutomationPresentationEvent] = []
        var attention: [TerminalAutomationAttention] = []
        fixture.coordinator.terminalAutomationPresentationHandler = { presentations.append($0) }
        fixture.coordinator.terminalAutomationAttentionHandler = { attention.append($0) }
        fixture.coordinator.failNextManagedCommitForTesting()
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: requestsInput
                        ? .requestUserInput(taskID: task.taskID) : .focus(taskID: task.taskID),
                    requestID: uuid(98_034)), in: fixture), .modelMutationFailed)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == task)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(fixture.coordinator.activeSurfaceForTesting === surface)
        #expect(window.firstResponder === responder)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        #expect(presentations.isEmpty && attention.isEmpty)
        let retried = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: requestsInput
                        ? .requestUserInput(taskID: task.taskID) : .focus(taskID: task.taskID),
                    requestID: uuid(98_035)), in: fixture))
        #expect(retried.owner == (requestsInput ? .user : .agent))
        #expect(retried.state == (requestsInput ? .waitingForUser : .running))
        #expect(retried.revision == task.revision + (requestsInput ? 1 : 0))
        #expect(
            window.firstResponder
                === fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: task.paneID)))
    }

    @Test(arguments: AutomationFocusReentrancy.allCases)
    private func requestUserInputRevalidatesAfterFocusCommit(change: AutomationFocusReentrancy)
        async throws
    {
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            permission: .allowed,
            persistWorkspaceStore: { _ in
                let callback = onCommit
                onCommit = nil
                callback?()
            })
        defer {
            onCommit = nil
            fixture.shutdown()
        }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(98_036)), in: fixture))
        var presentations: [TerminalAutomationPresentationEvent] = []
        var attention: [TerminalAutomationAttention] = []
        fixture.coordinator.terminalAutomationPresentationHandler = { presentations.append($0) }
        fixture.coordinator.terminalAutomationAttentionHandler = { attention.append($0) }
        var afterCallback: TerminalControlTask?
        var selectedStore: WorkspaceStore?
        onCommit = {
            switch change {
            case .manualTakeover:
                fixture.bridge.manualInputHandler?(PaneID(rawValue: task.paneID))
            case .selection:
                fixture.coordinator.activateTabForTesting(fixture.originTabID)
            case .revocation:
                #expect(
                    fixture.coordinator.handleAgentSessionLifecycleAction(
                        .unregister(
                            paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                            sessionID: fixture.binding.sessionID)))
            }
            afterCallback = fixture.coordinator.managedTaskForTesting(taskID: task.taskID)
            selectedStore = fixture.coordinator.workspaceStoreForTesting
        }
        let response = await controlRequest(
            try TerminalControlRequest(
                operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_037)),
            in: fixture)
        let expectedError: TerminalControlErrorCode
        switch change {
        case .manualTakeover: expectedError = .staleTerminalRevision
        case .selection: expectedError = .modelMutationFailed
        case .revocation: expectedError = .permissionRevoked
        }
        expectControlFailure(response, expectedError)
        #expect(selectedStore != nil)
        #expect(fixture.coordinator.workspaceStoreForTesting == selectedStore)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == afterCallback)
        #expect(presentations.isEmpty && attention.isEmpty)
        if change == .manualTakeover {
            #expect(afterCallback?.owner == .user && afterCallback?.state == .running)
            #expect(afterCallback?.revision == task.revision + 1)
            #expect(fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        } else if change == .selection {
            #expect(afterCallback == task)
            #expect(fixture.coordinator.activeSurfaceForTesting?.paneID == fixture.originPaneID)
        } else {
            #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        }
    }

    @Test
    func manualBroadcastTakeoverRunsBeforeEachDeliveryAndNeverSynthesizesText() async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .right, ratio: 0.5, launch: try launch(),
                        policy: .keep, focus: false),
                    requestID: uuid(98_009)), in: fixture))
        let source = try #require(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID))
        let target = try #require(
            fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: task.paneID)))
        let originalHandler = try #require(fixture.bridge.manualInputHandler)
        var seen: [PaneID] = []
        let targetInputs = target.inputObservationsForTesting.count
        fixture.bridge.manualInputHandler = { paneID in
            originalHandler(paneID)
            seen.append(paneID)
            if paneID == target.paneID {
                #expect(
                    fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
                #expect(target.inputObservationsForTesting.count == targetInputs)
            }
        }
        try fixture.coordinator.setActiveTabBroadcastingForTesting(true)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: source.window?.windowNumber ?? 0, context: nil,
                characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        source.keyDown(with: event)
        #expect(seen == [source.paneID, target.paneID])
        #expect(target.inputObservationsForTesting.count == targetInputs + 1)
        let taken = try #require(fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        #expect(taken.revision == task.revision + 1 && taken.owner == .user)
        let snapshot = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: try resolvedSession(in: fixture).identity))
        #expect(snapshot.text == "")
        #expect(snapshot.task.owner == .user)
        originalHandler(target.paneID)
        #expect(
            fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.revision
                == taken.revision)
        #expect(fixture.coordinator.returnControlToAgent(taskID: task.taskID))
    }

    @Test
    func echoDisabledManualKeyCannotBecomeSnapshotTextOrAuthorizeAgentInput() async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let launch = try TerminalControlLaunch(
            executable: "/bin/sh",
            // WHY: login may print a banner containing the manual key before echo is disabled.
            arguments: [
                "-c", "/bin/stty -echo; printf '\\033[2J\\033[3J\\033[HREADY'; exec /bin/cat",
            ],
            cwd: fixture.directories.managed.path)
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: launch, policy: .keep, focus: true),
                    requestID: uuid(98_020)), in: fixture))
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        try await waitForAutomation {
            // WHY: A native read failure is not a slow READY marker and must retain its diagnosis.
            try fixture.bridge.readRenderedText(id: pane, maximumUTF8Bytes: 65_536).text.contains(
                "READY")
        }
        let waiting = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_021)),
                in: fixture))
        let session = try resolvedSession(in: fixture)
        let before = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: session.identity))
        // WHY: Secret absence is meaningful only when the fixture starts without that character.
        try #require(!before.text.contains("p"))
        surface.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: surface.window?.windowNumber ?? 0, context: nil,
                    characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35
                )))
        try await Task.sleep(for: .milliseconds(300))
        let after = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: session.identity))
        #expect(after.text == before.text)
        #expect(!after.text.contains("p"))
        #expect(after.task.owner == .user && after.task.state == .waitingForUser)
        #expect(after.task.revision == before.task.revision)
        #expect(waiting.revision > task.revision)
        let inputCount = surface.automationKeyObservationsForTesting.count
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .sendKey(
                        taskID: task.taskID, expectedRevision: after.task.revision, key: .enter),
                    requestID: uuid(98_022)), in: fixture), .userControlsPane)
        #expect(surface.automationKeyObservationsForTesting.count == inputCount)
    }

    @Test(arguments: TerminalTaskLifecyclePolicy.allCases)
    func waitingTasksStillConsumeCapacityAndCompleteWithFinalCapture(
        policy: TerminalTaskLifecyclePolicy
    ) async throws {
        let fixture = try makeFixture(
            permission: .allowed, taskIDs: (0..<9).map { uuid(98_100 + $0) })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        var tasks: [TerminalControlTask] = []
        for index in 0..<8 {
            let task = try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: policy, focus: false),
                        requestID: uuid(98_200 + index)), in: fixture))
            tasks.append(task)
            _ = try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .requestUserInput(taskID: task.taskID),
                        requestID: uuid(98_300 + index)), in: fixture))
        }
        let before = fixture.coordinator.workspaceStoreForTesting
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(98_400)),
                in: fixture), .resourceLimit)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        let task = try #require(tasks.first)
        spy.text = "final output"
        fixture.bridge.surfaceProcessExitedHandler?(
            PaneID(rawValue: task.paneID),
            GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        try await waitForAutomation {
            fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.state == .succeeded
        }
        let snapshot = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: task.taskID, expectedSession: try resolvedSession(in: fixture).identity))
        #expect(snapshot.text == "final output")
        #expect(snapshot.task.owner == .finished)
        #expect(
            (fixture.coordinator.surfaceForTesting(id: PaneID(rawValue: task.paneID)) == nil)
                == (policy == .closeOnSuccess))
        #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
    }

    @Test(arguments: AutomationReturnRejection.allCases)
    private func explicitReturnRejectsNonCurrentCapabilities(reason: AutomationReturnRejection)
        async throws
    {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture)
        let task: TerminalControlTask
        if reason == .ungranted {
            task = try requireTask(
                await fixture.coordinator.terminalAutomationHost.createTab(
                    in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: false,
                    expectedSession: session.identity))
        } else {
            task = try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                        requestID: uuid(98_010)), in: fixture))
            _ = await controlRequest(
                try TerminalControlRequest(
                    operation: .requestUserInput(taskID: task.taskID), requestID: uuid(98_011)),
                in: fixture)
        }
        switch reason {
        case .ungranted:
            fixture.bridge.manualInputHandler?(PaneID(rawValue: task.paneID))
            #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
            #expect(
                await fixture.coordinator.terminalAutomationHost.requestUserInput(
                    taskID: task.taskID, expectedSession: session.identity)
                    == .failure(.targetNotOwned))
        case .dead:
            fixture.bridge.surfaceProcessExitedHandler?(
                PaneID(rawValue: task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        case .closed:
            fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: task.tabID))
        case .revoked:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .unregister(
                        paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                        sessionID: fixture.binding.sessionID)))
        case .replaced:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .replace(
                        paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                        binding: try makeBinding(sessionID: "replacement", registeredAt: 2_000))))
            _ = await controlRequest(try TerminalControlRequest(operation: .list), in: fixture)
        case .wrongWorkspace:
            _ = try #require(
                fixture.coordinator.moveTabToNewWorkspaceForTesting(
                    TabID(rawValue: task.tabID), name: "Moved"))
        }
        let before = fixture.coordinator.managedTaskForTesting(taskID: task.taskID)
        #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        #expect(!fixture.coordinator.returnControlToAgent(taskID: UUID()))
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == before)
        let requestInput = await fixture.coordinator.terminalAutomationHost.requestUserInput(
            taskID: task.taskID, expectedSession: session.identity)
        guard case .failure = requestInput else {
            Issue.record("Invalid capability requested user input")
            return
        }
    }

    @Test(arguments: [true, false])
    func managedBadgesFollowManualTakeoverAndRouteExactTaskWithoutFocusOrSnapshotReads(
        registeredAdapter: Bool
    ) async throws {
        let adapterID = try AgentAdapterID(rawValue: registeredAdapter ? "claude" : "claude-code")
        let expectedAdapterName: String
        if registeredAdapter {
            let definition = try #require(AgentIntegrationRegistry.definition(for: adapterID))
            #expect(definition.displayName == "Claude Code")
            expectedAdapterName = "Claude Code"
        } else {
            try #require(AgentIntegrationRegistry.definition(for: adapterID) == nil)
            expectedAdapterName = "Agent"
        }
        var persisted: [WorkspaceStore] = []
        let fixture = try makeFixture(
            permission: .allowed, adapterID: adapterID,
            persistWorkspaceStore: { persisted.append($0) })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let firstTask = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .right, ratio: 0.5,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(99_001)), in: fixture))
        let secondTask = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .down, ratio: 0.5,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(99_002)), in: fixture))
        await settleManagedBadges(in: fixture)
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let origin = try #require(fixture.coordinator.surfaceForTesting(id: fixture.originPaneID))
        let firstPane = PaneID(rawValue: firstTask.paneID)
        let secondPane = PaneID(rawValue: secondTask.paneID)
        let first = try #require(fixture.coordinator.surfaceForTesting(id: firstPane))
        let second = try #require(fixture.coordinator.surfaceForTesting(id: secondPane))
        #expect(window.makeFirstResponder(origin))
        let hostID = controller.splitHostingControllerIdentifierForTesting
        let surfaceIDs = controller.hostedSurfaceIdentifiersForTesting
        let store = fixture.coordinator.workspaceStoreForTesting
        let persistenceCount = persisted.count
        let refreshCount = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let sizes = [first.frame, second.frame]
        #expect(controller.hostedTerminalAutomationPresentationsForTesting.count == 2)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[firstPane]?.stateText
                == "Running")
        #expect(fixture.binding.adapterID == adapterID)
        for pane in [firstPane, secondPane] {
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.adapterDisplayName
                    == expectedAdapterName)
        }
        let renderedLabels = automationBadgeViews(in: controller.view).compactMap {
            $0 as? NSTextField
        }
        #expect(
            renderedLabels.filter {
                !$0.isHiddenOrHasHiddenAncestor
                    && $0.stringValue == "\(expectedAdapterName) · Running"
            }.count == 2)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[fixture.originPaneID] == nil)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting.values.allSatisfy {
                !$0.canReturnControl
            })

        for surface in [first, second] {
            surface.keyDown(
                with: try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "x", charactersIgnoringModifiers: "x", isARepeat: false,
                        keyCode: 7)))
        }
        #expect(fixture.coordinator.managedTaskForTesting(taskID: firstTask.taskID)?.owner == .user)
        #expect(
            fixture.coordinator.managedTaskForTesting(taskID: secondTask.taskID)?.owner == .user)
        await settleManagedBadges(in: fixture)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting.values.allSatisfy {
                $0.canReturnControl
            })
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[firstPane]?.stateText
                == "User controlled")
        let button = try managedReturnButton(for: firstPane, in: fixture)
        let hitPoint = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: controller.view)
        let hit = controller.view.hitTest(hitPoint)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
        button.performClick(nil)
        #expect(
            fixture.coordinator.managedTaskForTesting(taskID: firstTask.taskID)?.owner == .agent)
        #expect(
            fixture.coordinator.managedTaskForTesting(taskID: secondTask.taskID)?.owner == .user)
        await settleManagedBadges(in: fixture)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[firstPane]?.canReturnControl
                == false)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[secondPane]?.canReturnControl
                == true)
        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        #expect(controller.hostedSurfaceIdentifiersForTesting == surfaceIDs)
        #expect(Set(controller.renderedSurfaceIdentifiersForTesting) == Set(surfaceIDs.values))
        #expect([first.frame, second.frame] == sizes)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(persisted.count == persistenceCount)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == refreshCount)
        #expect(window.firstResponder === origin)
        #expect(spy.readCount == 0)

        _ = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .requestUserInput(taskID: secondTask.taskID),
                    requestID: uuid(99_003)), in: fixture))
        await settleManagedBadges(in: fixture)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[secondPane]?.stateText
                == "Waiting for user")
        #expect(window.firstResponder === second)
        try managedReturnButton(for: secondPane, in: fixture).performClick(nil)
        await settleManagedBadges(in: fixture)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[secondPane]?.stateText
                == "Running")
        #expect(window.firstResponder === second)
        #expect(spy.readCount == 0)

        let refreshes = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let map = controller.hostedTerminalAutomationPresentationsForTesting
        spy.text = "This snapshot text must never enter the badge"
        _ = try requireSnapshot(
            await fixture.coordinator.terminalAutomationHost.read(
                taskID: firstTask.taskID, expectedSession: try resolvedSession(in: fixture).identity
            ))
        await settleManagedBadges(in: fixture)
        #expect(controller.hostedTerminalAutomationPresentationsForTesting == map)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshes)
        #expect(
            automationBadgeViews(in: controller.view).allSatisfy {
                ($0 as? NSTextField)?.stringValue.contains(spy.text) != true
            })
    }

    @Test(arguments: AutomationReturnRejection.allCases.filter { $0 != .ungranted })
    private func staleMountedReturnButtonCannotRestoreInvalidGrant(
        reason: AutomationReturnRejection
    ) async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(99_010)), in: fixture))
        let pane = PaneID(rawValue: task.paneID)
        fixture.bridge.manualInputHandler?(pane)
        await settleManagedBadges(in: fixture)
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let button = try managedReturnButton(for: pane, in: fixture)
        try #require(button.isEnabled && !button.isHidden)
        var destinationWorkspaceID: WorkspaceID?
        switch reason {
        case .dead:
            fixture.bridge.surfaceProcessExitedHandler?(
                pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        case .closed:
            fixture.coordinator.closeTabImmediatelyForTesting(TabID(rawValue: task.tabID))
        case .revoked:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .unregister(
                        paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                        sessionID: fixture.binding.sessionID)))
        case .replaced:
            #expect(
                fixture.coordinator.handleAgentSessionLifecycleAction(
                    .replace(
                        paneID: fixture.originPaneID, previousSessionID: fixture.binding.sessionID,
                        binding: try makeBinding(sessionID: "replacement", registeredAt: 2_000))))
        case .wrongWorkspace:
            let movedWorkspaceID: WorkspaceID = try #require(
                fixture.coordinator.moveTabToNewWorkspaceForTesting(
                    TabID(rawValue: task.tabID), name: "Moved"))
            destinationWorkspaceID = movedWorkspaceID
        case .ungranted:
            Issue.record("Ungrantable direct creations have no return button")
        }
        let before = fixture.coordinator.managedTaskForTesting(taskID: task.taskID)
        let store = fixture.coordinator.workspaceStoreForTesting
        let responder = fixture.coordinator.activeWindowForTesting?.firstResponder
        // WHY: Invoke before the deferred refresh can hide or disable the stale control.
        button.performClick(nil)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == before)
        #expect(fixture.coordinator.workspaceStoreForTesting == store)
        #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === responder)
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: task.taskID)
        await settleManagedBadges(in: fixture)
        if reason == .dead {
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.taskState
                    == .succeeded)
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.controlOwner
                    == .finished)
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.canReturnControl
                    == false)
            #expect(
                !automationBadgeViews(in: controller.view).compactMap {
                    $0 as? TerminalAutomationBadgeView
                }.isEmpty)
        } else if reason == .revoked || reason == .replaced {
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.isRevoked == true)
            #expect(
                controller.hostedTerminalAutomationPresentationsForTesting[pane]?.canReturnControl
                    == false)
        } else if reason == .wrongWorkspace {
            // WHY: Moving activates the destination; surviving managed panes keep their badge, not authority.
            let movedWorkspaceID = try #require(destinationWorkspaceID)
            let currentStore = fixture.coordinator.workspaceStoreForTesting
            let destination = try #require(currentStore.workspace(id: movedWorkspaceID))
            let movedTabID = TabID(rawValue: task.tabID)
            let movedTab = try #require(destination.tabs.first { $0.id == movedTabID })
            #expect(movedWorkspaceID != fixture.workspaceID)
            #expect(currentStore.activeWorkspaceID == movedWorkspaceID)
            #expect(destination.activeTabID == movedTabID)
            #expect(movedTab.root.contains(pane))
            let source = try #require(currentStore.workspace(id: fixture.workspaceID))
            #expect(!source.tabs.contains { $0.id == movedTabID })
            let retainedTask = try #require(
                fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
            #expect(retainedTask.taskID == task.taskID && retainedTask.paneID == task.paneID)
            let value = try #require(
                controller.hostedTerminalAutomationPresentationsForTesting[pane])
            #expect(value.taskID == task.taskID)
            #expect(value.taskState == .running && value.controlOwner == .user)
            #expect(!value.isRevoked && !value.canReturnControl)
            let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
            let paneFrame = surface.convert(surface.bounds, to: controller.view)
            let badge = try #require(
                automationBadgeViews(in: controller.view).compactMap {
                    $0 as? TerminalAutomationBadgeView
                }.first { $0.convert($0.bounds, to: controller.view) == paneFrame })
            #expect(!badge.isHiddenOrHasHiddenAncestor)
            let currentButton = try #require(
                automationBadgeViews(in: badge).compactMap { $0 as? NSButton }.first {
                    $0.title == TerminalAutomationPresentation.returnControlTitle
                })
            #expect(currentButton.isHidden && !currentButton.isEnabled)
        } else if reason == .closed {
            #expect(controller.hostedTerminalAutomationPresentationsForTesting[pane] == nil)
        }
        let settledTask = fixture.coordinator.managedTaskForTesting(taskID: task.taskID)
        let settledStore = fixture.coordinator.workspaceStoreForTesting
        let settledResponder = fixture.coordinator.activeWindowForTesting?.firstResponder
        button.performClick(nil)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == settledTask)
        #expect(fixture.coordinator.workspaceStoreForTesting == settledStore)
        #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === settledResponder)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner != .agent)
    }

    @Test
    func directHostCreationShowsManagedBadgeButNeverOffersReturnWithoutDomainGrant() async throws {
        let fixture = try makeFixture(permission: .allowed)
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture).identity
        let task = try requireTask(
            await fixture.coordinator.terminalAutomationHost.createTab(
                in: fixture.workspaceID, launch: try launch(), policy: .keep, focus: true,
                expectedSession: session))
        let pane = PaneID(rawValue: task.paneID)
        fixture.bridge.manualInputHandler?(pane)
        await settleManagedBadges(in: fixture)
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let value = try #require(controller.hostedTerminalAutomationPresentationsForTesting[pane])
        #expect(value.taskID == task.taskID && value.stateText == "User controlled")
        #expect(!value.canReturnControl)
        #expect(!fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        _ = await controlRequest(try TerminalControlRequest(operation: .list), in: fixture)
        // WHY: Even a granted session and a forged enabled badge cannot grant an unowned task.
        controller.refreshTerminalAutomationPresentations([
            pane: TerminalAutomationPresentation(
                taskID: task.taskID, adapterDisplayName: "Agent", taskState: .running,
                controlOwner: .user, canReturnControl: true)
        ])
        await settleManagedBadges(in: fixture)
        try managedReturnButton(for: pane, in: fixture).performClick(nil)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
        fixture.coordinator.forgetManagedTask(taskID: task.taskID, expectedSession: session)
        await settleManagedBadges(in: fixture)
        #expect(controller.hostedTerminalAutomationPresentationsForTesting.isEmpty)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        #expect(
            !automationBadgeViews(in: controller.view).contains {
                $0 is TerminalAutomationBadgeView
            })
    }

    @Test
    func pendingBadgeRefreshUsesCurrentTabAndWorkspaceAndIsCancelledAtTeardown() async throws {
        let fixture = try makeFixture(permission: .allowed, originWorkspaceIsActive: false)
        defer { fixture.shutdown() }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: true),
                    requestID: uuid(99_020)), in: fixture))
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        fixture.bridge.manualInputHandler?(pane)
        await settleManagedBadges(in: fixture)
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let hostID = controller.splitHostingControllerIdentifierForTesting
        let staleButton = try managedReturnButton(for: pane, in: fixture)
        fixture.coordinator.activateTabForTesting(fixture.originTabID)
        staleButton.performClick(nil)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
        fixture.coordinator.activateWorkspace(at: 2)
        await settleManagedBadges(in: fixture)
        #expect(controller.hostedTerminalAutomationPresentationsForTesting.isEmpty)
        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        fixture.coordinator.activateWorkspace(at: 1)
        fixture.coordinator.activateTabForTesting(TabID(rawValue: task.tabID))
        await settleManagedBadges(in: fixture)
        #expect(
            controller.hostedTerminalAutomationPresentationsForTesting[pane]?.canReturnControl
                == true)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(surface)])
        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        let button = try managedReturnButton(for: pane, in: fixture)
        button.performClick(nil)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .agent)
        fixture.bridge.manualInputHandler?(pane)
        fixture.coordinator.activateWorkspace(at: 2)
        await settleManagedBadges(in: fixture)
        #expect(controller.hostedTerminalAutomationPresentationsForTesting.isEmpty)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        fixture.coordinator.activateWorkspace(at: 1)
        fixture.coordinator.activateTabForTesting(TabID(rawValue: task.tabID))
        #expect(fixture.coordinator.returnControlToAgent(taskID: task.taskID))
        fixture.coordinator.prepareForApplicationTermination()
        await fixture.coordinator.waitForManagedPresentationForTesting()
        button.performClick(nil)
        #expect(controller.hostedTerminalAutomationPresentationsForTesting.isEmpty)
        #expect(controller.splitHostingControllerIdentifierForTesting == nil)
    }

    @Test
    func managedResizeUsesAllFourLeafSidesAndReplaysWithoutAnotherCommit() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            permission: .allowed, originPaneIsActive: false,
            taskIDs: (0..<4).map { uuid(100_000 + $0) },
            persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let original = try #require(
            fixture.coordinator.workspaceStoreForTesting.tab(id: fixture.originTabID))
        guard case .split(let userDivider, .horizontal, 0.5, _, _) = original.root else {
            Issue.record("Expected the fixture's user divider")
            return
        }
        var tasks: [TerminalControlTask] = []
        for (index, direction) in [TerminalSplitDirection.left, .right, .up, .down].enumerated() {
            tasks.append(
                try requireControlTask(
                    await controlRequest(
                        try TerminalControlRequest(
                            operation: .split(
                                anchorPaneID: nil, direction: direction, ratio: 0.25,
                                launch: try launch(), policy: .keep, focus: false),
                            requestID: uuid(100_010 + index)), in: fixture)))
        }
        await fixture.coordinator.waitForManagedPresentationForTesting()
        let dividers = try tasks.map {
            try #require(fixture.coordinator.managedSplitIDForTesting(taskID: $0.taskID))
        }
        let panes = tasks.map { PaneID(rawValue: $0.paneID) }
        let before = fixture.coordinator.workspaceStoreForTesting
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let active = try #require(fixture.coordinator.activeSurfaceForTesting)
        #expect(window.makeFirstResponder(active))
        let epoch = fixture.coordinator.selectionGenerationForTesting
        let frame = window.frame
        let mode = fixture.coordinator.presentationMode
        let visibility = fixture.coordinator.quakeVisibilityForTesting
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let hostID = controller.splitHostingControllerIdentifierForTesting
        let surfaceIDs = fixture.bridge.activeSurfaceIDs
        let surfaces = try fixture.coordinator.surfaceIDsForTesting.map {
            try #require(fixture.coordinator.surfaceForTesting(id: $0))
        }
        let configurations = surfaces.map {
            fixture.bridge.surfaceConfigurationForTesting(id: $0.paneID)
        }
        let commitCount = commits.count
        let refreshCount = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        var stored = [0.25, 0.75, 0.25, 0.75]
        func expectedRoot() -> SplitNode {
            // WHY: Literal topology and first-child shares must not reuse the resize algorithm.
            .split(
                id: userDivider, axis: .horizontal, ratio: 0.5,
                first: .split(
                    id: dividers[0], axis: .horizontal, ratio: stored[0],
                    first: .pane(panes[0]),
                    second: .split(
                        id: dividers[1], axis: .horizontal, ratio: stored[1],
                        first: .split(
                            id: dividers[2], axis: .vertical, ratio: stored[2],
                            first: .pane(panes[2]),
                            second: .split(
                                id: dividers[3], axis: .vertical, ratio: stored[3],
                                first: .pane(fixture.originPaneID), second: .pane(panes[3]))),
                        second: .pane(panes[1]))),
                second: .pane(PaneID(rawValue: uuid(13))))
        }
        #expect(before.tab(id: fixture.originTabID)?.root == expectedRoot())
        for (index, share) in [0.3, 0.4, 0.2, 0.35].enumerated() {
            let request = try TerminalControlRequest(
                operation: .resize(taskID: tasks[index].taskID, ratio: share),
                requestID: uuid(100_020 + index))
            let response = await controlRequest(request, in: fixture)
            #expect(try requireControlTask(response) == tasks[index])
            stored[index] = [0.3, 0.6, 0.2, 0.65][index]
            let expected = try replacingAutomationRoot(
                expectedRoot(), tabID: fixture.originTabID, in: before)
            #expect(fixture.coordinator.workspaceStoreForTesting == expected)
            #expect(commits.last == expected)
            #expect(commits.count == commitCount + index + 1)
            #expect(
                fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                    == refreshCount + index + 1)
            #expect(await controlRequest(request, in: fixture) == response)
            expectControlFailure(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: tasks[index].taskID, ratio: 0.8),
                        requestID: request.requestID), in: fixture), .requestIDConflict)
            #expect(commits.count == commitCount + index + 1)
            #expect(fixture.coordinator.workspaceStoreForTesting == expected)
            #expect(fixture.coordinator.selectionGenerationForTesting == epoch)
            #expect(window.firstResponder === active)
            #expect(fixture.coordinator.activeSurfaceForTesting === active)
        }
        // WHY: A new request with the same quantized geometry is also a host-level no-op.
        for (index, ratio) in [0.3, 0.3000000000001].enumerated() {
            #expect(
                try requireControlTask(
                    await controlRequest(
                        try TerminalControlRequest(
                            operation: .resize(taskID: tasks[0].taskID, ratio: ratio),
                            requestID: uuid(100_030 + index)), in: fixture)) == tasks[0])
        }
        #expect(commits.count == commitCount + 4)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == refreshCount + 4)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        for (index, surface) in surfaces.enumerated() {
            #expect(fixture.coordinator.surfaceForTesting(id: surface.paneID) === surface)
            #expect(surface.isReady)
            #expect(
                fixture.bridge.surfaceConfigurationForTesting(id: surface.paneID)
                    == configurations[index])
            #expect(surface.automationTextObservationsForTesting.isEmpty)
            #expect(surface.automationKeyObservationsForTesting.isEmpty)
        }
        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        #expect(fixture.coordinator.activeWindowForTesting === window)
        #expect(window.frame == frame)
        #expect(fixture.coordinator.presentationMode == mode)
        #expect(fixture.coordinator.quakeVisibilityForTesting == visibility)
        #expect(spy.readCount == 0)
    }

    @Test
    func managedResizeLeavesBackgroundWorkspaceAndTabPresentationUntouched() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            permission: .allowed, originTabIsActive: false,
            originWorkspaceIsActive: false, persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .down, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_040)), in: fixture))
        let divider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: task.taskID))
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        for (index, share) in [0.3, 0.4].enumerated() {
            if index == 1 { fixture.coordinator.activateWorkspace(at: 1) }
            let before = fixture.coordinator.workspaceStoreForTesting
            let window = try #require(fixture.coordinator.activeWindowForTesting)
            let responder = window.firstResponder
            let active = fixture.coordinator.activeSurfaceForTesting
            let frame = window.frame
            let epoch = fixture.coordinator.selectionGenerationForTesting
            let controller = fixture.coordinator.workspaceViewControllerForTesting
            let hostID = controller.splitHostingControllerIdentifierForTesting
            let hostedSurfaces = controller.hostedSurfaceIdentifiersForTesting
            let refreshCount = fixture.coordinator
                .refreshWorkspacePresentationInvocationCountForTesting
            let commitCount = commits.count
            #expect(
                try requireControlTask(
                    await controlRequest(
                        try TerminalControlRequest(
                            operation: .resize(taskID: task.taskID, ratio: share),
                            requestID: uuid(100_041 + index)), in: fixture)) == task)
            let expected = try replacingAutomationRoot(
                .split(
                    id: divider, axis: .vertical, ratio: index == 0 ? 0.7 : 0.6,
                    first: .pane(fixture.originPaneID), second: .pane(pane)),
                tabID: fixture.originTabID, in: before)
            #expect(fixture.coordinator.workspaceStoreForTesting == expected)
            #expect(commits.count == commitCount + 1 && commits.last == expected)
            #expect(fixture.coordinator.selectionGenerationForTesting == epoch)
            #expect(
                fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                    == refreshCount)
            #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
            #expect(controller.hostedSurfaceIdentifiersForTesting == hostedSurfaces)
            #expect(fixture.coordinator.activeSurfaceForTesting === active)
            #expect(window.firstResponder === responder)
            #expect(window.frame == frame)
            #expect(fixture.coordinator.activeWindowForTesting === window)
            #expect(fixture.coordinator.presentationMode == .normal)
            #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        }
    }

    @Test
    func managedResizeValidatesRatiosAndExactGrantWithoutReturningManualControl() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            permission: .allowed, persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let session = try resolvedSession(in: fixture).identity
        let host = fixture.coordinator.terminalAutomationHost
        let ungranted = try requireTask(
            await host.createSplit(
                anchorPaneID: fixture.originPaneID, in: fixture.workspaceID, direction: .left,
                ratio: 0.25, launch: try launch(), policy: .keep, focus: false,
                expectedSession: session))
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .right, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_050)), in: fixture))
        let wrongSession = TerminalAutomationSessionIdentity(
            instanceID: session.instanceID, originPaneID: session.originPaneID,
            adapterID: session.adapterID, sessionID: "wrong-session",
            paneCredentialGeneration: session.paneCredentialGeneration)
        let before = fixture.coordinator.workspaceStoreForTesting
        let count = commits.count
        let refresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        for ratio in [Double.nan, .infinity, -.infinity, -1, 0, 0.1.nextDown, 0.9.nextUp, 1] {
            #expect(
                await host.resize(taskID: task.taskID, ratio: ratio, expectedSession: session)
                    == .failure(.invalidRequest))
        }
        #expect(
            await host.resize(taskID: UUID(), ratio: .nan, expectedSession: wrongSession)
                == .failure(.invalidRequest))
        #expect(
            await host.resize(taskID: ungranted.taskID, ratio: 0.3, expectedSession: session)
                == .failure(.targetNotOwned))
        let wrongGeneration = TerminalAutomationSessionIdentity(
            instanceID: session.instanceID, originPaneID: session.originPaneID,
            adapterID: session.adapterID, sessionID: session.sessionID,
            paneCredentialGeneration: session.paneCredentialGeneration + 1)
        for invalidSession in [wrongSession, wrongGeneration] {
            #expect(
                await host.resize(taskID: task.taskID, ratio: 0.3, expectedSession: invalidSession)
                    == .failure(.staleSession))
        }
        let cancelled = Task { @MainActor in
            await host.resize(taskID: task.taskID, ratio: 0.3, expectedSession: session)
        }
        cancelled.cancel()
        #expect(await cancelled.value == .failure(.cancelled))
        #expect(
            await host.resize(taskID: UUID(), ratio: 0.3, expectedSession: session)
                == .failure(.targetNotFound))
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: uuid(100_099), ratio: 0.3),
                    requestID: uuid(100_051)), in: fixture), .targetNotOwned)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(commits.count == count)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refresh)

        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        fixture.bridge.manualInputHandler?(pane)
        await fixture.coordinator.waitForManagedPresentationForTesting()
        let manual = try #require(fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        #expect(manual.owner == .user && manual.state == .running)
        let divider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: task.taskID))
        let outer = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: ungranted.taskID))
        for (index, share) in [0.1, 0.9].enumerated() {
            #expect(
                await host.resize(taskID: task.taskID, ratio: share, expectedSession: session)
                    == .task(manual))
            let expected = try replacingAutomationRoot(
                .split(
                    id: outer, axis: .horizontal, ratio: 0.25,
                    first: .pane(PaneID(rawValue: ungranted.paneID)),
                    second: .split(
                        id: divider, axis: .horizontal, ratio: index == 0 ? 0.9 : 0.1,
                        first: .pane(fixture.originPaneID), second: .pane(pane))),
                tabID: fixture.originTabID, in: before)
            #expect(fixture.coordinator.workspaceStoreForTesting == expected)
            #expect(commits.count == count + index + 1)
        }
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .sendText(
                        taskID: task.taskID, expectedRevision: manual.revision, text: "x"),
                    requestID: uuid(100_052)), in: fixture), .userControlsPane)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == manual)
        #expect(surface.automationTextObservationsForTesting.isEmpty)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)

        // WHY: Moving origin and target together still must not transfer a recorded workspace grant.
        _ = try #require(
            fixture.coordinator.moveTabToNewWorkspaceForTesting(fixture.originTabID, name: "Moved"))
        let moved = fixture.coordinator.workspaceStoreForTesting
        let movedCount = commits.count
        #expect(
            await host.resize(taskID: task.taskID, ratio: 0.3, expectedSession: session)
                == .failure(.targetNotOwned))
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_053)), in: fixture), .targetNotOwned)
        #expect(fixture.coordinator.workspaceStoreForTesting == moved)
        #expect(commits.count == movedCount)
    }

    @Test
    func managedResizeRejectsTabTasksNestedLeavesAndCollapsedRecordedDividers() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            confirmationPresenter: { _, completion in
                completion(.allow)
                return nil
            },
            permission: .allowed, persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let tabTask = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .createTab(launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_060)), in: fixture))
        let tabID = TabID(rawValue: tabTask.tabID)
        let unsplit = fixture.coordinator.workspaceStoreForTesting
        let unsplitCount = commits.count
        #expect(unsplit.tab(id: tabID)?.root == .pane(PaneID(rawValue: tabTask.paneID)))
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: tabTask.taskID, ratio: 0.3),
                    requestID: uuid(100_059)), in: fixture), .invalidRequest)
        #expect(fixture.coordinator.workspaceStoreForTesting == unsplit)
        #expect(commits.count == unsplitCount)
        let first = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: tabTask.paneID, direction: .right, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_061)), in: fixture))
        let nested = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: first.paneID, direction: .up, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_062)), in: fixture))
        let firstPane = PaneID(rawValue: first.paneID)
        let nestedPane = PaneID(rawValue: nested.paneID)
        let firstDivider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: first.taskID))
        let nestedDivider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: nested.taskID))
        let before = fixture.coordinator.workspaceStoreForTesting
        let count = commits.count
        #expect(fixture.coordinator.managedSplitIDForTesting(taskID: tabTask.taskID) == nil)
        for (index, task) in [tabTask, first].enumerated() {
            expectControlFailure(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: task.taskID, ratio: 0.3),
                        requestID: uuid(100_063 + index)), in: fixture), .invalidRequest)
            #expect(fixture.coordinator.workspaceStoreForTesting == before)
            #expect(commits.count == count)
        }
        #expect(
            try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: nested.taskID, ratio: 0.3),
                        requestID: uuid(100_065)), in: fixture)) == nested)
        #expect(
            fixture.coordinator.workspaceStoreForTesting
                == (try replacingAutomationRoot(
                    .split(
                        id: firstDivider, axis: .horizontal, ratio: 0.75,
                        first: .pane(PaneID(rawValue: tabTask.paneID)),
                        second: .split(
                            id: nestedDivider, axis: .vertical, ratio: 0.3,
                            first: .pane(nestedPane), second: .pane(firstPane))),
                    tabID: tabID, in: before)))
        fixture.coordinator.activate(
            destination: try #require(fixture.coordinator.terminalDestination(for: nestedPane)))
        fixture.coordinator.requestCloseActivePane()
        let restored = fixture.coordinator.workspaceStoreForTesting
        #expect(
            try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: first.taskID, ratio: 0.4),
                        requestID: uuid(100_066)), in: fixture)) == first)
        #expect(
            fixture.coordinator.workspaceStoreForTesting
                == (try replacingAutomationRoot(
                    .split(
                        id: firstDivider, axis: .horizontal, ratio: 0.6,
                        first: .pane(PaneID(rawValue: tabTask.paneID)), second: .pane(firstPane)),
                    tabID: tabID, in: restored)))
        fixture.coordinator.activate(
            destination: try #require(
                fixture.coordinator.terminalDestination(for: PaneID(rawValue: tabTask.paneID))))
        fixture.coordinator.requestCloseActivePane()
        #expect(
            fixture.coordinator.workspaceStoreForTesting.tab(id: tabID)?.root == .pane(firstPane))
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: firstPane))
        for index in 0..<2 {
            if index == 1 {
                fixture.coordinator.activateTabForTesting(tabID)
                try fixture.coordinator.splitActivePaneForTesting(axis: .vertical)
            }
            let collapsed = fixture.coordinator.workspaceStoreForTesting
            let collapsedCount = commits.count
            let refresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
            #expect(collapsed.tab(id: tabID)?.root.contains(splitID: firstDivider) == false)
            expectControlFailure(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: first.taskID, ratio: 0.3),
                        requestID: uuid(100_067 + index)), in: fixture), .invalidRequest)
            #expect(fixture.coordinator.workspaceStoreForTesting == collapsed)
            #expect(commits.count == collapsedCount)
            #expect(
                fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refresh
            )
            #expect(fixture.coordinator.surfaceForTesting(id: firstPane) === surface)
        }
    }

    @Test
    func managedResizeRejectsFinishedRetainedAndFrozenTasksWithoutMutation() async throws {
        var commits: [WorkspaceStore] = []
        let fixture = try makeFixture(
            confirmationPresenter: { _, completion in
                completion(.allow)
                return nil
            },
            permission: .allowed, persistWorkspaceStore: { commits.append($0) })
        defer { fixture.shutdown() }
        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        var tasks: [TerminalControlTask] = []
        for index in 0..<2 {
            tasks.append(
                try requireControlTask(
                    await controlRequest(
                        try TerminalControlRequest(
                            operation: .split(
                                anchorPaneID: nil, direction: .right, ratio: 0.25,
                                launch: try launch(), policy: .keep, focus: false),
                            requestID: uuid(100_070 + index)), in: fixture)))
        }
        let task = tasks[0]
        let pane = PaneID(rawValue: task.paneID)
        let before = fixture.coordinator.workspaceStoreForTesting
        let count = commits.count
        let host = fixture.coordinator.terminalAutomationHost
        fixture.bridge.surfaceProcessExitedHandler?(
            pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        #expect(
            await host.resize(taskID: task.taskID, ratio: 0.3, expectedSession: session)
                == .failure(.processFinished))
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: task.taskID)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID)?.state == .succeeded)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) != nil)
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_072)), in: fixture), .processFinished)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(commits.count == count)
        fixture.coordinator.activate(
            destination: try #require(fixture.coordinator.terminalDestination(for: pane)))
        fixture.coordinator.requestCloseActivePane()
        #expect(fixture.coordinator.surfaceForTesting(id: pane) == nil)
        let retained = fixture.coordinator.workspaceStoreForTesting
        let retainedCount = commits.count
        #expect(
            await host.resize(taskID: task.taskID, ratio: 0.3, expectedSession: session)
                == .failure(.processFinished))
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_073)), in: fixture), .processFinished)
        #expect(fixture.coordinator.workspaceStoreForTesting == retained)
        #expect(commits.count == retainedCount)
        fixture.coordinator.freezeTerminalControlForApplicationTermination()
        let frozenTask = fixture.coordinator.managedTaskForTesting(taskID: tasks[1].taskID)
        let refresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        #expect(
            await host.resize(taskID: tasks[1].taskID, ratio: 0.3, expectedSession: session)
                == .failure(.staleSession))
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: tasks[1].taskID, ratio: 0.3),
                    requestID: uuid(100_074)), in: fixture), .cancelled)
        #expect(fixture.coordinator.workspaceStoreForTesting == retained)
        #expect(commits.count == retainedCount)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: tasks[1].taskID) == frozenTask)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refresh)
    }

    @Test
    func managedResizeRejectsCommitFailureAndRevalidatesModelOwnerAndCompletion() async throws {
        var commits: [WorkspaceStore] = []
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            permission: .allowed,
            persistWorkspaceStore: {
                commits.append($0)
                let callback = onCommit
                onCommit = nil
                callback?()
            })
        defer {
            onCommit = nil
            fixture.shutdown()
        }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .right, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_080)), in: fixture))
        let divider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: task.taskID))
        let pane = PaneID(rawValue: task.paneID)
        let before = fixture.coordinator.workspaceStoreForTesting
        let count = commits.count
        let refresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        fixture.coordinator.failNextManagedCommitForTesting()
        // WHY: An identical candidate must neither persist nor consume the rejected-commit seam.
        #expect(
            try requireControlTask(
                await controlRequest(
                    try TerminalControlRequest(
                        operation: .resize(taskID: task.taskID, ratio: 0.25),
                        requestID: uuid(100_081)), in: fixture)) == task)
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_082)), in: fixture), .modelMutationFailed)
        #expect(fixture.coordinator.workspaceStoreForTesting == before)
        #expect(commits.count == count)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refresh)
        onCommit = { fixture.bridge.manualInputHandler?(pane) }
        let resized = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_083)), in: fixture))
        #expect(resized == fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        #expect(resized.owner == .user && resized.policy == task.policy)
        #expect(resized.revision == task.revision + 1)
        #expect(
            fixture.coordinator.workspaceStoreForTesting
                == (try replacingAutomationRoot(
                    .split(
                        id: divider, axis: .horizontal, ratio: 0.7,
                        first: .pane(fixture.originPaneID), second: .pane(pane)),
                    tabID: fixture.originTabID, in: before)))
        #expect(commits.count == count + 1)
        let afterResize = fixture.coordinator.workspaceStoreForTesting
        let afterRefresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        var afterCallback: WorkspaceStore?
        onCommit = {
            fixture.bridge.surfaceTabTitleHandler?(fixture.originPaneID, "Later title")
            afterCallback = fixture.coordinator.workspaceStoreForTesting
        }
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.4),
                    requestID: uuid(100_084)), in: fixture), .modelMutationFailed)
        var expected = try replacingAutomationRoot(
            .split(
                id: divider, axis: .horizontal, ratio: 0.6,
                first: .pane(fixture.originPaneID), second: .pane(pane)),
            tabID: fixture.originTabID, in: afterResize)
        try expected.setTitleOverride("Later title", for: fixture.originTabID)
        #expect(afterCallback == expected)
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
        #expect(commits.count == count + 3)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == afterRefresh)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == resized)

        let spy = AutomationReadSpy()
        fixture.bridge.setTerminalAutomationClientForTesting(spy.client)
        let session = try resolvedSession(in: fixture).identity
        onCommit = {
            fixture.bridge.surfaceProcessExitedHandler?(
                pane, GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 0))
        }
        // WHY: Check the synchronous callback boundary before deferred completion changes the task.
        #expect(
            fixture.coordinator.resizeManagedTask(
                taskID: task.taskID, ratio: 0.35, expectedSession: session)
                == .failure(.processFinished))
        expected = try replacingAutomationRoot(
            .split(
                id: divider, axis: .horizontal, ratio: 0.65,
                first: .pane(fixture.originPaneID), second: .pane(pane)),
            tabID: fixture.originTabID, in: expected)
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
        #expect(commits.count == count + 4 && commits.last == expected)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == afterRefresh)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == resized)
        await fixture.coordinator.waitForManagedCompletionForTesting(taskID: task.taskID)
    }

    @Test(arguments: [false, true])
    func managedResizeAcceptedCommitSurvivesReentrantRevocationOrFreeze(freezes: Bool) async throws
    {
        var commits: [WorkspaceStore] = []
        var onCommit: (() -> Void)?
        let fixture = try makeFixture(
            permission: .allowed,
            persistWorkspaceStore: {
                commits.append($0)
                let callback = onCommit
                onCommit = nil
                callback?()
            })
        defer {
            onCommit = nil
            fixture.shutdown()
        }
        let task = try requireControlTask(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .split(
                        anchorPaneID: nil, direction: .left, ratio: 0.25,
                        launch: try launch(), policy: .keep, focus: false),
                    requestID: uuid(100_090)), in: fixture))
        await fixture.coordinator.waitForManagedPresentationForTesting()
        let pane = PaneID(rawValue: task.paneID)
        let divider = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: task.taskID))
        let before = fixture.coordinator.workspaceStoreForTesting
        let count = commits.count
        let refresh = fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let window = try #require(fixture.coordinator.activeWindowForTesting)
        let responder = window.firstResponder
        let frame = window.frame
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let surfaceIDs = fixture.bridge.activeSurfaceIDs
        let epoch = fixture.coordinator.selectionGenerationForTesting
        var callbackTask: TerminalControlTask?
        onCommit = {
            if freezes {
                fixture.coordinator.freezeTerminalControlForApplicationTermination()
            } else {
                #expect(
                    fixture.coordinator.handleAgentSessionLifecycleAction(
                        .unregister(
                            paneID: fixture.originPaneID, adapterID: fixture.binding.adapterID,
                            sessionID: fixture.binding.sessionID)))
            }
            callbackTask = fixture.coordinator.managedTaskForTesting(taskID: task.taskID)
        }
        expectControlFailure(
            await controlRequest(
                try TerminalControlRequest(
                    operation: .resize(taskID: task.taskID, ratio: 0.3),
                    requestID: uuid(100_091)), in: fixture), .permissionRevoked)
        var expected = try replacingAutomationRoot(
            .split(
                id: divider, axis: .horizontal, ratio: 0.3,
                first: .pane(pane), second: .pane(fixture.originPaneID)),
            tabID: fixture.originTabID, in: before)
        if !freezes { try expected.updateAgentResumeBinding(nil, for: fixture.originPaneID) }
        #expect(fixture.coordinator.workspaceStoreForTesting == expected)
        #expect(commits.count == count + (freezes ? 1 : 2))
        #expect(commits.last == expected)
        #expect(
            fixture.coordinator.refreshWorkspacePresentationInvocationCountForTesting == refresh)
        #expect(fixture.coordinator.selectionGenerationForTesting == epoch)
        #expect(callbackTask?.owner == .user)
        #expect(fixture.coordinator.managedTaskForTesting(taskID: task.taskID) == callbackTask)
        #expect(fixture.coordinator.surfaceForTesting(id: pane) === surface)
        #expect(fixture.bridge.activeSurfaceIDs == surfaceIDs)
        #expect(window.firstResponder === responder)
        #expect(window.frame == frame)
        #expect(fixture.coordinator.activeWindowForTesting === window)
    }

    private func replacingAutomationRoot(
        _ root: SplitNode, tabID: TabID, in store: WorkspaceStore
    ) throws -> WorkspaceStore {
        var workspaces = store.workspaces
        let workspaceIndex = try #require(
            workspaces.firstIndex { $0.tabs.contains { $0.id == tabID } })
        let tabIndex = try #require(workspaces[workspaceIndex].tabs.firstIndex { $0.id == tabID })
        let tab = workspaces[workspaceIndex].tabs[tabIndex]
        workspaces[workspaceIndex].tabs[tabIndex] = try TerminalTab(
            id: tab.id, title: tab.title, titleOverride: tab.titleOverride, root: root,
            paneDescriptors: tab.paneDescriptors, activePaneID: tab.activePaneID,
            isBroadcasting: tab.isBroadcasting)
        return try WorkspaceStore(
            workspaces: workspaces, activeWorkspaceID: store.activeWorkspaceID)
    }

    private func settleManagedBadges(in fixture: AutomationFixture) async {
        await fixture.coordinator.waitForManagedPresentationForTesting()
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        for _ in 0..<4 {
            fixture.coordinator.activeWindowForTesting?.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        controller.view.layoutSubtreeIfNeeded()
    }

    private func automationBadgeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { automationBadgeViews(in: $0) }
    }

    private func managedReturnButton(for pane: PaneID, in fixture: AutomationFixture) throws
        -> NSButton
    {
        let controller = fixture.coordinator.workspaceViewControllerForTesting
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        let frame = surface.convert(surface.bounds, to: controller.view)
        let badge = try #require(
            automationBadgeViews(in: controller.view).compactMap {
                $0 as? TerminalAutomationBadgeView
            }.first { $0.convert($0.bounds, to: controller.view) == frame })
        return try #require(
            automationBadgeViews(in: badge).compactMap { $0 as? NSButton }.first {
                $0.title == TerminalAutomationPresentation.returnControlTitle && !$0.isHidden
            })
    }

    private func controlRequest(_ request: TerminalControlRequest, in fixture: AutomationFixture)
        async
        -> TerminalControlResponse
    {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        return await fixture.coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: fixture.instanceID,
                paneID: fixture.originPaneID.rawValue, request: request),
            context: TerminalControlRequestContext { ContinuousClock().now < deadline })
    }

    private func expectControlFailure(
        _ response: TerminalControlResponse, _ code: TerminalControlErrorCode
    ) {
        guard case .failure(let error) = response.result else {
            Issue.record("Expected failure, got \(response)")
            return
        }
        #expect(error.code == code)
    }

    private func waitForAutomation(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while try !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw AutomationTestError.confirmationTimedOut("Task 8 wait exceeded 5 seconds")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func requireRunningCloseTarget(
        _ task: TerminalControlTask, in fixture: AutomationFixture
    ) throws {
        let current = try #require(fixture.coordinator.managedTaskForTesting(taskID: task.taskID))
        try #require(current.state == .running, "A close prompt requires a running managed task")
        try #require(current.owner == .agent)
        let pane = PaneID(rawValue: task.paneID)
        let surface = try #require(fixture.coordinator.surfaceForTesting(id: pane))
        try #require(surface.isReady)
        try #require(fixture.bridge.activeSurfaceIDs.contains(pane))
        try #require(
            fixture.bridge.surfaceNeedsConfirmQuit(id: pane),
            "Managed process exited before confirmation for task \(task.taskID), pane \(pane)")
    }

    private func requireSnapshot(_ response: TerminalAutomationHostResponse) throws
        -> TerminalControlSnapshot
    {
        guard case .snapshot(let snapshot) = response else {
            Issue.record("Expected snapshot, got \(response)")
            throw AutomationTestError.missingTask
        }
        return snapshot
    }

    private func makeFixture(
        mode: PresentationMode = .normal,
        configURL: URL? = nil,
        confirmationPresenter: GhosttyConfirmationQueue.Presenter? = nil,
        permission: TerminalAutomationPermissionDecision? = nil,
        adapterID: AgentAdapterID? = nil,
        permissionPresenter: WindowCoordinator.TerminalAutomationPermissionPresenter? = nil,
        permissionTimeout: TimeInterval = 60,
        useProductionPermission: Bool = false,
        originTabIsActive: Bool = true,
        originWorkspaceIsActive: Bool = true,
        originPaneIsActive: Bool = true,
        includesCurrentTab: Bool = false,
        taskIDs: [UUID] = [uuid(10), uuid(11), uuid(12)],
        automationNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        persistWorkspaceStore: @escaping WindowCoordinator.WorkspacePersistence = { _ in }
    ) throws -> AutomationFixture {
        try workingDirectories.create()
        var initialized = false
        defer {
            if !initialized { workingDirectories.remove() }
        }
        let helperPath = ApplicationEnvironment.bundledAgentHelperURL(in: Bundle.main).path
        var helperIsDirectory = ObjCBool(false)
        try #require(
            FileManager.default.fileExists(atPath: helperPath, isDirectory: &helperIsDirectory)
                && !helperIsDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: helperPath),
            "The test host must contain an executable Contents/Helpers/quicktty: \(helperPath)")
        let instanceID = uuid(1)
        let originPaneID = PaneID(rawValue: uuid(2))
        let binding = try AgentResumeBinding(
            adapterID: adapterID ?? AgentAdapterID(rawValue: "claude-code"),
            sessionID: "origin-session",
            workingDirectory: workingDirectories.origin.path,
            registeredAt: Date(timeIntervalSince1970: 1_000),
            launchMetadata: ["source": "test"],
            restoreState: .active
        )
        let tab = TerminalTab(
            id: TabID(rawValue: uuid(3)),
            title: "Origin",
            pane: TerminalPaneDescriptor(
                id: originPaneID,
                cwd: workingDirectories.origin.path,
                startupCommand: .custom("exec /bin/cat"),
                agentResumeBinding: binding
            )
        )
        let activeTab = TerminalTab(
            id: TabID(rawValue: uuid(6)),
            title: "Current",
            pane: TerminalPaneDescriptor(
                id: PaneID(rawValue: uuid(5)),
                cwd: workingDirectories.current.path,
                startupCommand: .custom("exec /bin/cat")
            )
        )
        let tabs = originTabIsActive && !includesCurrentTab ? [tab] : [tab, activeTab]
        let activeTabID = originTabIsActive ? tab.id : activeTab.id
        let workspace = Workspace(
            id: WorkspaceID(rawValue: uuid(4)),
            name: "Main",
            tabs: tabs,
            activeTabID: activeTabID
        )
        let foregroundWorkspace = Workspace(
            id: WorkspaceID(rawValue: uuid(7)),
            name: "Foreground",
            tabs: [
                TerminalTab(
                    id: TabID(rawValue: uuid(8)),
                    title: "Foreground",
                    pane: TerminalPaneDescriptor(
                        id: PaneID(rawValue: uuid(9)),
                        cwd: workingDirectories.foreground.path,
                        startupCommand: .custom("exec /bin/cat")
                    )
                )
            ],
            activeTabID: TabID(rawValue: uuid(8))
        )
        var store = try WorkspaceStore(
            workspaces: originWorkspaceIsActive ? [workspace] : [workspace, foregroundWorkspace],
            activeWorkspaceID: originWorkspaceIsActive ? workspace.id : foregroundWorkspace.id
        )
        if !originPaneIsActive {
            _ = try SplitCoordinator().apply(
                .split(
                    workspaceID: workspace.id,
                    tabID: tab.id,
                    paneID: originPaneID,
                    axis: .horizontal,
                    newPane: TerminalPaneDescriptor(
                        id: PaneID(rawValue: uuid(13)),
                        cwd: workingDirectories.current.path,
                        startupCommand: .custom("exec /bin/cat")
                    ),
                    ratio: 0.5
                ),
                to: &store
            )
        }
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-automation.sock",
            helperPath: helperPath,
            instanceID: instanceID,
            tokenGenerator: { Array(repeating: 0xAB, count: 32) },
            onAction: { _ in false }
        )
        // WHY: Saved restore deliberately clears command overrides, so its default must also be inert.
        let fixtureConfigURL = workingDirectories.root.appending(path: "config")
        var configContents = try configURL.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        configContents += "\ncommand = /bin/cat\n"
        try Data(configContents.utf8).write(to: fixtureConfigURL)
        let bridge = try GhosttyBridge(configURL: fixtureConfigURL)
        defer {
            if !initialized { bridge.shutdown() }
        }
        let taskIDSequence = ManagedTaskIDSequence(taskIDs)
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: workingDirectories.current.path,
                command: "exec /bin/cat",
                environment: [
                    "BASE": "preserved",
                    "QUICKTTY_PANE_ID": "collision",
                    "QUICKTTY_AGENT_SOCKET": "collision",
                    "QUICKTTY_INSTANCE_ID": "collision",
                    "QUICKTTY_PANE_TOKEN": "collision",
                    "QUICKTTY_AGENT_HELPER": "collision",
                    "QUICKTTY_CONTROL_SOCKET": "collision",
                ]
            ),
            executableSearchPath: "/managed/bin",
            agentSessionController: controller,
            initialWorkspaceStore: store,
            managedTaskIDProvider: taskIDSequence.next,
            terminalAutomationNow: automationNow,
            terminalAutomationPermissionPresenter: useProductionPermission
                ? nil
                : (permissionPresenter ?? { _ in
                    permission ?? .unavailable
                }),
            terminalAutomationPermissionTimeout: permissionTimeout,
            persistWorkspaceStore: persistWorkspaceStore,
            confirmationPresenter: confirmationPresenter
        )
        defer {
            if !initialized { coordinator.prepareForBridgeShutdownForTesting() }
        }
        try coordinator.start()
        for workspace in store.workspaces {
            for tab in workspace.tabs {
                for descriptor in tab.paneDescriptors {
                    let surface = try #require(coordinator.surfaceForTesting(id: descriptor.id))
                    try #require(surface.isReady)
                    #expect(
                        bridge.surfaceConfigurationForTesting(id: descriptor.id)?.workingDirectory
                            == descriptor.cwd)
                }
            }
        }
        initialized = true
        return AutomationFixture(
            bridge: bridge,
            controller: controller,
            coordinator: coordinator,
            instanceID: instanceID,
            originPaneID: originPaneID,
            originTabID: tab.id,
            activeTabID: activeTabID,
            workspaceID: workspace.id,
            binding: binding,
            directories: workingDirectories,
            helperPath: helperPath
        )
    }

    private func resolvedSession(in fixture: AutomationFixture) throws
        -> TerminalAutomationResolvedSession
    {
        try #require(
            fixture.coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: fixture.instanceID,
                originPaneID: fixture.originPaneID
            )
        )
    }

    private func makeBinding(
        sessionID: String,
        registeredAt: TimeInterval
    ) throws -> AgentResumeBinding {
        try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude-code"),
            sessionID: sessionID,
            workingDirectory: workingDirectories.origin.path,
            registeredAt: Date(timeIntervalSince1970: registeredAt),
            launchMetadata: ["source": "test"],
            restoreState: .active
        )
    }

    private func launch() throws -> TerminalControlLaunch {
        try TerminalControlLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/cat", "managed-argument"],
            cwd: workingDirectories.managed.path
        )
    }

    private func requireCreatedTask(_ response: TerminalAutomationHostResponse) throws
        -> TerminalAutomationCreatedTaskResponse
    {
        guard case .createdTask(let created) = response else {
            Issue.record("Expected created task response, got \(response)")
            throw AutomationTestError.missingTask
        }
        return created
    }

    private func requireTask(_ response: TerminalAutomationHostResponse) throws
        -> TerminalControlTask
    {
        try requireCreatedTask(response).task
    }

    private func requireControlTask(_ response: TerminalControlResponse) throws
        -> TerminalControlTask
    {
        guard case .task(let task) = response.result else {
            Issue.record("Expected task response, got \(response)")
            throw AutomationTestError.missingTask
        }
        return task
    }

    private func expectNoAgentIdentity(in environment: [String: String]) {
        let excluded = [
            "QUICKTTY_PANE_ID",
            "QUICKTTY_AGENT_SOCKET",
            "QUICKTTY_INSTANCE_ID",
            "QUICKTTY_PANE_TOKEN",
            "QUICKTTY_AGENT_HELPER",
            "QUICKTTY_CONTROL_SOCKET",
        ]
        #expect(excluded.allSatisfy { environment[$0] == nil })
    }
}

@MainActor
private struct AutomationFixture {
    let bridge: GhosttyBridge
    let controller: AgentSessionController
    let coordinator: WindowCoordinator
    let instanceID: UUID
    let originPaneID: PaneID
    let originTabID: TabID
    let activeTabID: TabID
    let workspaceID: WorkspaceID
    let binding: AgentResumeBinding
    let directories: AutomationWorkingDirectories
    let helperPath: String

    func shutdown() {
        coordinator.managedCloseWaiterJoinedForTesting = nil
        coordinator.prepareForBridgeShutdownForTesting()
        bridge.shutdown()
        directories.remove()
    }
}

@MainActor
private final class AutomationWorkingDirectories {
    private(set) var root = FileManager.default.temporaryDirectory.appending(
        path: "QuickTTY-TerminalAutomation-\(UUID().uuidString)", directoryHint: .isDirectory)

    var origin: URL { root.appending(path: "origin", directoryHint: .isDirectory) }
    var current: URL { root.appending(path: "current", directoryHint: .isDirectory) }
    var foreground: URL { root.appending(path: "foreground", directoryHint: .isDirectory) }
    var managed: URL { root.appending(path: "managed", directoryHint: .isDirectory) }

    func create() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for directory in [origin, current, foreground, managed] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            // WHY: Ghostty reports resolved cwd; snapshots must start with the same canonical paths.
            root = root.resolvingSymlinksInPath()
            try #require(
                Set([origin.path, current.path, foreground.path, managed.path]).count == 4)
            for directory in [origin, current, foreground, managed] {
                try #require(directory.path == directory.resolvingSymlinksInPath().path)
            }
        } catch {
            remove()
            throw error
        }
    }

    func remove() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) } catch {
            Issue.record("Could not remove fixture directory \(root.path): \(error)")
        }
    }
}

private enum FocusCompensationScenario: CaseIterable, Sendable {
    case backgroundWorkspaceTab
    case backgroundWorkspaceSplit
    case backgroundTabSplit
    case nonActiveAnchor

    var isBackgroundWorkspace: Bool {
        self == .backgroundWorkspaceTab || self == .backgroundWorkspaceSplit
    }
}

private enum LaterFocusSelection: CaseIterable, Sendable {
    case workspace
    case tab
    case pane
}

private enum ManagedCreationKind: CaseIterable, Sendable {
    case tab
    case split
}

private enum ManagedRollbackSeam: CaseIterable, Sendable {
    case surface
    case model
    case commit

    var errorCode: TerminalControlErrorCode {
        switch self {
        case .surface:
            .surfaceCreationFailed
        case .model, .commit:
            .modelMutationFailed
        }
    }

    @MainActor
    func armTab(coordinator: WindowCoordinator, bridge: GhosttyBridge) {
        switch self {
        case .surface:
            bridge.failNextSurfaceCreationForTesting()
        case .model:
            coordinator.failNextManagedTabMutationForTesting()
        case .commit:
            coordinator.failNextManagedCommitForTesting()
        }
    }

    @MainActor
    func armSplit(coordinator: WindowCoordinator, bridge: GhosttyBridge) {
        switch self {
        case .surface:
            bridge.failNextSurfaceCreationForTesting()
        case .model:
            coordinator.failNextManagedSplitMutationForTesting()
        case .commit:
            coordinator.failNextManagedCommitForTesting()
        }
    }
}

extension TerminalAutomationHostResponse {
    fileprivate var errorCode: TerminalControlErrorCode? {
        guard case .failure(let code) = self else { return nil }
        return code
    }
}

@MainActor
private final class ManagedTaskIDSequence {
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        values.removeFirst()
    }
}

private struct AutomationConfig {
    let directory: URL
    let url: URL

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        url = directory.appending(path: "config")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class AutomationConfirmationProbe {
    private(set) var completion: GhosttyConfirmationQueue.Completion?
    private(set) var presentationCount = 0
    private var participantCount = 0
    private(set) var wasDismissed = false

    func waitForDismissal() async throws {
        try await wait(for: .dismissal)
    }

    func participantJoined(_ count: Int) {
        participantCount = count
    }

    func waitForParticipants(count: Int = 2) async throws {
        try await wait(for: .participants(count))
    }

    func resetPresentation() { completion = nil }

    func present(
        _ presentation: GhosttyConfirmationPresentation,
        completion: @escaping GhosttyConfirmationQueue.Completion
    ) -> GhosttyConfirmationQueue.Dismiss? {
        self.completion = completion
        presentationCount += 1
        wasDismissed = false
        return { [self] in
            wasDismissed = true
        }
    }

    func waitForPresentation() async throws {
        try await wait(for: .presentation)
    }

    private enum Event {
        case presentation
        case participants(Int)
        case dismissal
    }

    private func wait(for event: Event) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            let observed: Bool
            switch event {
            case .presentation: observed = completion != nil
            case .participants(let count): observed = participantCount >= count
            case .dismissal: observed = wasDismissed
            }
            if observed { return }
            guard clock.now < deadline else {
                throw AutomationTestError.confirmationTimedOut(
                    "No \(event) within 5 seconds; presentations=\(presentationCount), "
                        + "participants=\(participantCount), dismissed=\(wasDismissed)")
            }
            // WHY: Poll only recorded events; cancellation and a monotonic deadline bound missing callbacks.
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
        }
    }

    func resolve(_ response: GhosttyClipboardConfirmationResponse) { completion?(response) }
}

@MainActor
private final class AutomationClock {
    var now: TimeInterval = 100
}

@MainActor
private final class AutomationReadSpy {
    var text = ""
    var readCount = 0
    var freeCount = 0
    var failReads = false
    // WHY: This policy spy pairs synthetic root exits with explicit EOF, although cat is still alive.
    // NativeControlReadObserver deliberately leaves the production outputState seam live.
    var outputState: GhosttyOutputState = .complete
    var onOutputState: (@MainActor () -> Void)?
    var onRead: (@MainActor () -> Void)?

    var client: GhosttyTerminalAutomationClient {
        GhosttyTerminalAutomationClient(
            readText: { [self] request, _ in
                #expect(request.maximumUTF8Bytes == 65_536)
                readCount += 1
                onRead?()
                if failReads { return .failure }
                return .success(
                    GhosttyTerminalAutomationReadBuffer(bytes: Data(text.utf8), release: {}))
            },
            freeText: { [self] buffer in
                buffer.release()
                freeCount += 1
            },
            outputState: { [self] _ in
                onOutputState?()
                return outputState
            }
        )
    }
}

@MainActor
private final class AutomationPermissionProbe {
    var count = 0
    var didReturn = false
    var sessions: [TerminalAutomationSessionIdentity] = []
    private var continuation: CheckedContinuation<TerminalAutomationPermissionDecision, Never>?

    func present(_ session: TerminalAutomationResolvedSession) async
        -> TerminalAutomationPermissionDecision
    {
        count += 1
        sessions.append(session.identity)
        let decision = await withCheckedContinuation { continuation = $0 }
        didReturn = true
        return decision
    }

    func resolve(_ decision: TerminalAutomationPermissionDecision) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: decision)
    }
}

private enum AutomationPermissionEnding: CaseIterable, Sendable {
    case revoke, replace, transition, termination
}

private enum AutomationFocusReentrancy: CaseIterable, Sendable {
    case manualTakeover, selection, revocation
}

private enum AutomationReturnRejection: CaseIterable, Sendable {
    case ungranted, dead, closed, revoked, replaced, wrongWorkspace
}

private enum PendingCaptureWaitEnding: CaseIterable, Sendable {
    case completion, failedCapture, timeout, cancellation
}

private enum AutomationTestError: Error {
    case missingTask
    case confirmationTimedOut(String)
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
