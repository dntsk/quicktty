import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct WindowCoordinatorAgentResumeTests {
    @Test
    func savedRestorePlansOrderedSnapshotOnceAndLaunchesOnlyEligibleBinding() throws {
        let helper = try AgentResumeHelperFixture()
        defer { helper.remove() }
        let eligiblePaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let blockedPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000101")!
        let eligibleBinding = try makeBinding(
            adapterID: "claude",
            sessionID: "sensitive-session-eligible",
            workingDirectory: "/missing/sensitive-cwd",
            state: .active
        )
        let blockedBinding = try makeBinding(
            adapterID: "grok",
            sessionID: "sensitive-session-blocked",
            workingDirectory: "/private/sensitive-blocked",
            state: .active
        )
        let eligibleDescriptor = TerminalPaneDescriptor(
            id: eligiblePaneID,
            cwd: "/tmp",
            startupCommand: .custom("sensitive-startup-command-eligible"),
            agentResumeBinding: eligibleBinding
        )
        let blockedDescriptor = TerminalPaneDescriptor(
            id: blockedPaneID,
            cwd: "/tmp",
            startupCommand: .custom("sensitive-startup-command-blocked"),
            agentResumeBinding: blockedBinding
        )
        let root = SplitNode.split(
            id: splitID,
            axis: .horizontal,
            ratio: 0.37,
            first: .pane(eligiblePaneID),
            second: .pane(blockedPaneID)
        )
        let tab = try TerminalTab(
            title: "Restored",
            root: root,
            paneDescriptors: [eligibleDescriptor, blockedDescriptor],
            activePaneID: eligiblePaneID
        )
        let workspace = Workspace(name: "Restored", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let controller = try makeController(helperPath: helper.path)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let scheduler = AgentResumeManualScheduler()
        var plannerInvocationCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                environment: [
                    "BASE_VALUE": "preserved",
                    "QUICKTTY_PANE_ID": "caller-pane",
                    "QUICKTTY_AGENT_HELPER": "caller-helper",
                    AgentInvocationPayloadEnvironment.payloadKey: "caller-payload",
                ]
            ),
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: { adapterIDs in
                Dictionary(
                    uniqueKeysWithValues: adapterIDs.map {
                        (
                            $0,
                            AgentRestoreCompatibility(
                                status: .compatible(version: "1.2.3"),
                                resolvedExecutablePath: "/bin/echo"
                            )
                        )
                    }
                )
            },
            agentRestoreHomeDirectory: { "/tmp" },
            agentRestoreWorkingDirectoryExists: { _ in false },
            agentRestorePlanner: { input in
                plannerInvocationCount += 1
                return AgentRestorePlanner().plan(input)
            },
            agentResumeScheduler: scheduler
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())

        try coordinator.start()

        #expect(plannerInvocationCount == 1)
        #expect(Set(coordinator.surfaceIDsForTesting) == [eligiblePaneID, blockedPaneID])
        let restoredTab = try #require(coordinator.workspaceStoreForTesting.tab(id: tab.id))
        #expect(restoredTab.root == root)
        #expect(restoredTab.activePaneID == eligiblePaneID)
        #expect(
            restoredTab.paneDescriptor(for: eligiblePaneID)?.startupCommand
                == .custom("sensitive-startup-command-eligible")
        )
        #expect(
            restoredTab.paneDescriptor(for: blockedPaneID)?.startupCommand
                == .custom("sensitive-startup-command-blocked")
        )

        let eligibleConfiguration = try #require(
            bridge.surfaceConfigurationForTesting(id: eligiblePaneID)
        )
        #expect(eligibleConfiguration.command == "'\(helper.path)' internal launch")
        #expect(eligibleConfiguration.workingDirectory == "/tmp")
        #expect(eligibleConfiguration.initialInput == nil)
        #expect(eligibleConfiguration.environment["BASE_VALUE"] == "preserved")
        #expect(
            eligibleConfiguration.environment["QUICKTTY_PANE_ID"]
                == eligiblePaneID.rawValue.uuidString
        )
        #expect(eligibleConfiguration.environment["QUICKTTY_AGENT_HELPER"] == helper.path)
        let payload = try decodedPayload(from: eligibleConfiguration)
        #expect(payload.executable == "/bin/echo")
        #expect(payload.arguments == ["--resume", "sensitive-session-eligible"])
        #expect(payload.workingDirectory == "/tmp")
        let persistedState = try JSONEncoder().encode(
            ApplicationState(workspaceStore: coordinator.workspaceStoreForTesting)
        )
        for forbiddenValue in [
            AgentInvocationPayloadEnvironment.payloadKey,
            helper.path,
            "/bin/echo",
            "--resume",
        ] {
            #expect(!persistedState.contains(Data(forbiddenValue.utf8)))
        }

        let blockedConfiguration = try #require(
            bridge.surfaceConfigurationForTesting(id: blockedPaneID)
        )
        #expect(blockedConfiguration.command == nil)
        #expect(blockedConfiguration.workingDirectory == "/tmp")
        #expect(
            blockedConfiguration.environment[AgentInvocationPayloadEnvironment.payloadKey] == nil
        )
        #expect(
            restoredBinding(in: coordinator, paneID: blockedPaneID)?.restoreState
                == .failed(
                    diagnosticCode: .missingAdapter, failedAt: coordinator.agentResumeDateForTesting
                )
        )
        let presentation = try #require(
            coordinator.agentResumePresentationsForTesting[blockedPaneID]
        )
        #expect(!presentation.canRetry)
        assertPresentationIsBoundedAndRedacted(
            presentation,
            sentinels: [
                blockedBinding.sessionID,
                blockedBinding.workingDirectory,
                helper.path,
                "caller-payload",
            ]
        )
    }

    @Test
    func immutableProductionCompatibilityMapLaunchesVerifiedPiAndFallsBackWhenAbsent() throws {
        let helper = try AgentResumeHelperFixture()
        defer { helper.remove() }
        let piPaneID = PaneID()
        let absentPaneID = PaneID()
        let piTab = TerminalTab(
            title: "Pi",
            pane: TerminalPaneDescriptor(
                id: piPaneID,
                cwd: "/tmp",
                agentResumeBinding: try makeBinding(
                    adapterID: "pi",
                    sessionID: "pi-session"
                )
            )
        )
        let absentTab = TerminalTab(
            title: "Absent",
            pane: TerminalPaneDescriptor(
                id: absentPaneID,
                cwd: "/tmp",
                agentResumeBinding: try makeBinding(
                    adapterID: "claude",
                    sessionID: "absent-session"
                )
            )
        )
        let workspace = Workspace(
            name: "Production map",
            tabs: [piTab, absentTab],
            activeTabID: piTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let controller = try makeController(helperPath: helper.path)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let piID = try AgentAdapterID(rawValue: "pi")
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibility: [
                piID: AgentRestoreCompatibility(
                    status: .compatible(version: "0.83.0"),
                    resolvedExecutablePath: "/bin/echo"
                )
            ],
            agentResumeScheduler: AgentResumeManualScheduler()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())

        try coordinator.start()

        let piConfiguration = try #require(
            bridge.surfaceConfigurationForTesting(id: piPaneID)
        )
        #expect(piConfiguration.command == "'\(helper.path)' internal launch")
        #expect(try decodedPayload(from: piConfiguration).arguments == ["--session", "pi-session"])
        let absentConfiguration = try #require(
            bridge.surfaceConfigurationForTesting(id: absentPaneID)
        )
        #expect(absentConfiguration.command == nil)
        #expect(
            restoredBinding(in: coordinator, paneID: absentPaneID)?.restoreState
                == .failed(
                    diagnosticCode: .missingExecutable,
                    failedAt: coordinator.agentResumeDateForTesting
                )
        )
    }

    @Test
    func ineligibleBindingsOpenFreshShellsWithoutReplayingPersistedCommands() throws {
        let now = Date(timeIntervalSinceReferenceDate: 200)
        let cases: [(PaneID, AgentResumeBinding, AgentCompatibilityStatus?)] = [
            (
                PaneID(),
                try makeBinding(
                    adapterID: "cursor",
                    sessionID: "failed-session",
                    state: .failed(diagnosticCode: .immediateExit, failedAt: now)
                ),
                .compatible(version: "1.0")
            ),
            (
                PaneID(),
                try makeBinding(
                    adapterID: "gemini", sessionID: "unverified-session", state: .unverified),
                .compatible(version: "1.0")
            ),
            (
                PaneID(),
                try makeBinding(adapterID: "codex", sessionID: "unsupported-session"),
                .unsupportedVersion
            ),
            (
                PaneID(),
                try makeBinding(adapterID: "pi", sessionID: "unknown-version-session"),
                .unverifiedVersion
            ),
            (
                PaneID(),
                try makeBinding(adapterID: "omp", sessionID: "missing-executable-session"),
                nil
            ),
            (
                PaneID(),
                try makeBinding(adapterID: "claude", sessionID: "--invalid-session"),
                .compatible(version: "1.0")
            ),
            (
                PaneID(),
                try makeBinding(
                    adapterID: "amp",
                    sessionID: "invalid-metadata-session",
                    metadata: ["model.name": "sensitive-metadata-value"]
                ),
                .compatible(version: "1.0")
            ),
        ]
        let tabs = cases.enumerated().map { index, item in
            TerminalTab(
                title: "Case \(index)",
                pane: TerminalPaneDescriptor(
                    id: item.0,
                    cwd: "/tmp",
                    startupCommand: .custom("sensitive-persisted-command-\(index)"),
                    agentResumeBinding: item.1
                )
            )
        }
        let workspace = Workspace(name: "Cases", tabs: tabs, activeTabID: tabs[0].id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let controller = try makeController(helperPath: "/tmp/quicktty-test-helper")
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let compatibility = Dictionary(
            uniqueKeysWithValues: cases.compactMap { _, binding, status in
                status.map {
                    (
                        binding.adapterID,
                        AgentRestoreCompatibility(
                            status: $0,
                            resolvedExecutablePath: "/bin/echo"
                        )
                    )
                }
            }
        )
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: { _ in compatibility }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())

        try coordinator.start()

        #expect(Set(coordinator.surfaceIDsForTesting) == Set(cases.map(\.0)))
        for (index, item) in cases.enumerated() {
            let configuration = try #require(
                bridge.surfaceConfigurationForTesting(id: item.0)
            )
            #expect(configuration.command == nil)
            #expect(configuration.initialInput == nil)
            #expect(
                configuration.environment[AgentInvocationPayloadEnvironment.payloadKey] == nil
            )
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: tabs[index].id)?
                    .paneDescriptor(for: item.0)?.startupCommand
                    == .custom("sensitive-persisted-command-\(index)")
            )
            let presentation = try #require(
                coordinator.agentResumePresentationsForTesting[item.0]
            )
            assertPresentationIsBoundedAndRedacted(
                presentation,
                sentinels: [
                    item.1.sessionID,
                    item.1.workingDirectory,
                    "sensitive-metadata-value",
                    "/bin/echo",
                ]
            )
        }
    }

    @Test
    func configurationDisablesAgentRestoreBeforeStartAndRetainsBinding() throws {
        let paneID = PaneID()
        let binding = try makeBinding(adapterID: "claude", sessionID: "policy-session")
        let tab = TerminalTab(
            title: "Policy",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp",
                startupCommand: .custom("sensitive-policy-command"),
                agentResumeBinding: binding
            )
        )
        let workspace = Workspace(name: "Policy", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let controller = try makeController(helperPath: "/tmp/quicktty-test-helper")
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: verifiedCompatibility
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        var config = QuickTTYConfig()
        config.restoreAgentSessions = false

        coordinator.applyConfiguration(config)
        try coordinator.start()

        let configuration = try #require(bridge.surfaceConfigurationForTesting(id: paneID))
        #expect(configuration.command == nil)
        #expect(configuration.environment[AgentInvocationPayloadEnvironment.payloadKey] == nil)
        #expect(restoredBinding(in: coordinator, paneID: paneID) == binding)
        #expect(coordinator.agentResumePresentationsForTesting[paneID]?.canRetry == false)
    }

    @Test
    func retryReverifiesReplacesSurfaceRotatesTokenAndIgnoresStaleCallbacks() throws {
        let helper = try AgentResumeHelperFixture()
        defer { helper.remove() }
        let paneID = PaneID()
        let binding = try makeBinding(adapterID: "claude", sessionID: "retry-session")
        let tab = TerminalTab(
            title: "Retry",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp",
                startupCommand: .custom("sensitive-retry-command"),
                agentResumeBinding: binding
            )
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let scheduler = AgentResumeManualScheduler()
        let tokenSequence = AgentResumeTokenSequence([
            Array(repeating: 0x11, count: 32),
            Array(repeating: 0x22, count: 32),
            Array(repeating: 0x33, count: 32),
        ])
        let controller = try makeController(
            helperPath: helper.path,
            tokenGenerator: tokenSequence.next
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var compatibilityResolutionCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: { adapterIDs in
                compatibilityResolutionCount += 1
                return verifiedCompatibility(adapterIDs)
            },
            agentResumeScheduler: scheduler,
            agentResumeRegistrationTimeout: 5,
            agentResumeStableConfirmationThreshold: 2,
            agentResumeClaimLifetime: 20
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())

        try coordinator.start()
        let oldSurface = try #require(coordinator.surfaceForTesting(id: paneID))
        let oldReference = try #require(
            coordinator.agentResumeAttemptReferenceForTesting(paneID)
        )
        let oldEnvironment = try #require(
            bridge.surfaceConfigurationForTesting(id: paneID)?.environment
        )
        scheduler.advance(by: 5)
        #expect(restoredBinding(in: coordinator, paneID: paneID)?.restoreState == .unverified)

        coordinator.retryAgentResumeForTesting(paneID)

        let replacementSurface = try #require(coordinator.surfaceForTesting(id: paneID))
        let replacementReference = try #require(
            coordinator.agentResumeAttemptReferenceForTesting(paneID)
        )
        let replacementEnvironment = try #require(
            bridge.surfaceConfigurationForTesting(id: paneID)?.environment
        )
        #expect(replacementSurface !== oldSurface)
        #expect(replacementReference.generation > oldReference.generation)
        #expect(replacementReference.attemptID != oldReference.attemptID)
        #expect(
            replacementEnvironment["QUICKTTY_PANE_TOKEN"]
                != oldEnvironment["QUICKTTY_PANE_TOKEN"]
        )
        #expect(compatibilityResolutionCount == 2)
        #expect(restoredBinding(in: coordinator, paneID: paneID)?.restoreState == .restoring)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.startupCommand
                == .custom("sensitive-retry-command")
        )

        coordinator.processAgentResumeExitForTesting(oldReference)
        #expect(restoredBinding(in: coordinator, paneID: paneID)?.restoreState == .restoring)
        #expect(coordinator.surfaceForTesting(id: paneID) === replacementSurface)

        let resumedRegistration = try makeBinding(
            adapterID: "claude",
            sessionID: "retry-session",
            state: .active
        )
        #expect(
            coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: paneID, binding: resumedRegistration)
            )
        )
        #expect(restoredBinding(in: coordinator, paneID: paneID)?.restoreState == .restoring)
        #expect(
            coordinator.handleAgentSessionLifecycleAction(
                .unregister(
                    paneID: paneID,
                    adapterID: resumedRegistration.adapterID,
                    sessionID: resumedRegistration.sessionID
                )
            )
        )
        #expect(
            restoredBinding(in: coordinator, paneID: paneID)?.restoreState
                == .failed(diagnosticCode: .immediateExit, failedAt: scheduler.date)
        )
        #expect(coordinator.surfaceForTesting(id: paneID) === replacementSurface)

        coordinator.surfaceDidRequestCloseForTesting(id: paneID, processAlive: false)

        #expect(coordinator.surfaceForTesting(id: paneID) == nil)
        #expect(
            restoredBinding(in: coordinator, paneID: paneID)?.restoreState
                == .failed(diagnosticCode: .immediateExit, failedAt: scheduler.date)
        )
        #expect(!coordinator.agentResumeHasClaimForTesting(binding))
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == .pane(paneID))
        #expect(coordinator.agentResumePresentationsForTesting[paneID]?.canRetry == true)

        coordinator.forgetAgentResumeForTesting(paneID)

        #expect(restoredBinding(in: coordinator, paneID: paneID) == nil)
        #expect(coordinator.surfaceForTesting(id: paneID) != nil)
        #expect(coordinator.agentResumePresentationsForTesting[paneID] == nil)
        #expect(
            bridge.surfaceConfigurationForTesting(id: paneID)?.command == nil
        )
        #expect(
            bridge.surfaceConfigurationForTesting(id: paneID)?
                .environment["QUICKTTY_PANE_TOKEN"]
                == String(repeating: "33", count: 32)
        )
    }

    @Test
    func resumeSurfaceCreationFailureIsPaneLocalAndRetryable() throws {
        let helper = try AgentResumeHelperFixture()
        defer { helper.remove() }
        let failingPaneID = PaneID()
        let livePaneID = PaneID()
        let failingDescriptor = TerminalPaneDescriptor(
            id: failingPaneID,
            cwd: "/tmp",
            agentResumeBinding: try makeBinding(
                adapterID: "claude",
                sessionID: "failing-session"
            )
        )
        let liveDescriptor = TerminalPaneDescriptor(
            id: livePaneID,
            cwd: "/tmp",
            agentResumeBinding: try makeBinding(
                adapterID: "codex",
                sessionID: "live-session"
            )
        )
        let root = SplitNode.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.61,
            first: .pane(failingPaneID),
            second: .pane(livePaneID)
        )
        let tab = try TerminalTab(
            title: "Pane-local",
            root: root,
            paneDescriptors: [failingDescriptor, liveDescriptor],
            activePaneID: livePaneID
        )
        let workspace = Workspace(name: "Pane-local", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let controller = try makeController(helperPath: helper.path)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: failingPaneID)
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: verifiedCompatibility,
            agentResumeScheduler: AgentResumeManualScheduler()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())

        try coordinator.start()

        #expect(coordinator.surfaceForTesting(id: failingPaneID) == nil)
        #expect(coordinator.surfaceForTesting(id: livePaneID) != nil)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
        #expect(
            restoredBinding(in: coordinator, paneID: failingPaneID)?.restoreState
                == .failed(
                    diagnosticCode: .surfaceCreation,
                    failedAt: coordinator.agentResumeDateForTesting
                )
        )
        #expect(controller.environment(for: failingPaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.agentResumePresentationsForTesting[failingPaneID]?.canRetry == true)

        coordinator.retryAgentResumeForTesting(failingPaneID)

        #expect(coordinator.surfaceForTesting(id: failingPaneID) != nil)
        #expect(coordinator.surfaceForTesting(id: livePaneID) != nil)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
    }

    @Test
    func normalRestoredShellExitKeepsExistingPaneCloseSemantics() throws {
        let paneID = PaneID()
        let tab = TerminalTab(
            title: "Shell",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Shell", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(ghosttyBridge: bridge, initialWorkspaceStore: store)
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        coordinator.surfaceDidRequestCloseForTesting(id: paneID, processAlive: false)

        #expect(coordinator.surfaceForTesting(id: paneID) == nil)
        #expect(
            !coordinator.workspaceStoreForTesting.workspaces
                .flatMap(\.tabs)
                .contains { $0.root.contains(paneID) }
        )
        #expect(coordinator.activeSurfaceForTesting != nil)
    }

    private func makeController(
        helperPath: String,
        tokenGenerator: @escaping AgentSessionController.TokenGenerator = {
            Array(repeating: 0xAB, count: 32)
        }
    ) throws -> AgentSessionController {
        try AgentSessionController(
            socketPath: "/tmp/quicktty-agent-resume-tests/agent.sock",
            helperPath: helperPath,
            tokenGenerator: tokenGenerator,
            onAction: { _ in false }
        )
    }

    private func decodedPayload(
        from configuration: GhosttySurfaceConfiguration
    ) throws -> AgentInvocationPayload {
        let encoded = try #require(
            configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]
        )
        return try AgentInvocationPayloadCodec.decodeBase64(encoded)
    }

    private func restoredBinding(
        in coordinator: WindowCoordinator,
        paneID: PaneID
    ) -> AgentResumeBinding? {
        coordinator.workspaceStoreForTesting.workspaces.lazy
            .flatMap(\.tabs)
            .compactMap { $0.paneDescriptor(for: paneID)?.agentResumeBinding }
            .first
    }

    private func makeBinding(
        adapterID: String,
        sessionID: String,
        workingDirectory: String = "/tmp/project",
        metadata: [String: String] = [:],
        state: AgentResumeState = .active
    ) throws -> AgentResumeBinding {
        try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: adapterID),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            registeredAt: Date(timeIntervalSinceReferenceDate: 100),
            launchMetadata: metadata,
            restoreState: state
        )
    }

    private func assertPresentationIsBoundedAndRedacted(
        _ presentation: AgentResumePresentation,
        sentinels: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let renderedStrings = [
            presentation.title,
            presentation.message,
            presentation.accessibilityLabel,
            presentation.accessibilityValue,
        ]
        #expect(
            renderedStrings.allSatisfy {
                $0.utf8.count <= AgentResumePresentation.maximumCopyBytes
            },
            sourceLocation: sourceLocation
        )
        for sentinel in sentinels where !sentinel.isEmpty {
            #expect(
                renderedStrings.allSatisfy { !$0.contains(sentinel) },
                sourceLocation: sourceLocation
            )
        }
    }
}

@MainActor
private func verifiedCompatibility(
    _ adapterIDs: [AgentAdapterID]
) -> [AgentAdapterID: AgentRestoreCompatibility] {
    Dictionary(
        uniqueKeysWithValues: adapterIDs.map {
            (
                $0,
                AgentRestoreCompatibility(
                    status: .compatible(version: "1.0"),
                    resolvedExecutablePath: "/bin/echo"
                )
            )
        }
    )
}

@MainActor
private final class AgentResumeTokenSequence {
    private var values: [[UInt8]]

    init(_ values: [[UInt8]]) {
        self.values = values
    }

    func next() -> [UInt8] {
        guard !values.isEmpty else { return Array(repeating: 0xFF, count: 32) }
        return values.removeFirst()
    }
}

@MainActor
private final class AgentResumeHelperFixture {
    let directoryURL: URL
    let path: String

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-AgentResume-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let helperURL = directoryURL.appending(path: "quicktty")
        try Data(
            "#!/bin/sh\nwhile :; do sleep 60; done\n".utf8
        ).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )
        path = helperURL.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
