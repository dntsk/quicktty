import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct AgentIntegrationsSheetControllerTests {
    @Test
    func oneSheetReopensAndReattachesBetweenNormalAndQuakeWindows() {
        let viewController = makeViewController()
        let focusRecorder = TerminalFocusRestorationRecorder()
        let controller = AgentIntegrationsSheetController(
            viewController: viewController,
            restoreTerminalFocus: focusRecorder.restore
        )
        let normal = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let quake = QuakeWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))

        controller.present(on: normal)
        let sheet = normal.attachedSheet
        controller.present(on: normal)

        #expect(controller.isPresented)
        #expect(normal.attachedSheet === sheet)
        #expect(sheet === controller.sheetWindow)

        let wasPresented = controller.detachForWindowTransition()
        controller.reattachAfterWindowTransition(to: quake, wasPresented: wasPresented)

        #expect(normal.attachedSheet == nil)
        #expect(quake.attachedSheet === sheet)
        #expect(controller.parentWindowForTesting === quake)
        controller.close()
        #expect(!controller.isPresented)
        #expect(quake.attachedSheet == nil)
        #expect(focusRecorder.restoreCallCount == 1)
    }

    @Test
    func preparedOfferPresentationDoesNotReloadStatus() async throws {
        let recorder = SheetOfferInstallerRecorder(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable])
        )
        let viewController = AgentIntegrationsViewController(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())
        #expect(await recorder.statusRequestCount == 1)
        let controller = AgentIntegrationsSheetController(
            viewController: viewController,
            restoreTerminalFocus: {}
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        #expect(controller.presentPreparedOffer(on: parent))
        #expect(await recorder.statusRequestCount == 1)
        controller.close()
    }

    @Test
    func automaticOfferRecordsWhenPresentedAndStillRequiresConfirmation() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let recorder = SheetOfferInstallerRecorder(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmation = SheetOfferConfirmationRecorder(result: false)
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "automatic-offer",
                defaults: defaultsSuite.defaults
            )
        )
        coordinator.installAgentIntegrations(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store,
            confirmationPresenter: { request in confirmation.present(request) }
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(!store.shouldOffer)
        #expect(confirmation.requests.count == 1)
        #expect(confirmation.requests.first?.title == "Update selected integrations?")
        #expect(await recorder.prepareRequestCount == 1)
        #expect(await recorder.applyRequestCount == 0)
        #expect(await recorder.appliedPlanIDs.isEmpty)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == true
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()
        #expect(confirmation.requests.count == 1)
        coordinator.agentIntegrationsSheetControllerForTesting?.close()
    }

    @Test
    func automaticOfferWithoutUpdatesDoesNotPresentOrRecord() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let recorder = SheetOfferInstallerRecorder(statuses: offerStatuses())
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(build: "no-updates", defaults: defaultsSuite.defaults)
        )
        coordinator.installAgentIntegrations(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(store.shouldOffer)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == false
        )
        #expect(await recorder.appliedPlanIDs.isEmpty)
    }

    @Test
    func automaticOfferWithAttachedSheetDoesNotPresentOrRecord() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let activeWindow = try #require(coordinator.activeWindowForTesting)
        let blockerSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        activeWindow.beginSheet(blockerSheet, completionHandler: nil)
        defer {
            if activeWindow.attachedSheet === blockerSheet {
                activeWindow.endSheet(blockerSheet)
            }
        }
        #expect(activeWindow.attachedSheet === blockerSheet)
        let recorder = SheetOfferInstallerRecorder(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmation = SheetOfferConfirmationRecorder(result: true)
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "attached-sheet",
                defaults: defaultsSuite.defaults
            )
        )
        coordinator.installAgentIntegrations(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store,
            confirmationPresenter: { request in confirmation.present(request) }
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(await recorder.statusRequestCount == 1)
        #expect(await recorder.prepareRequestCount == 0)
        #expect(await recorder.applyRequestCount == 0)
        #expect(confirmation.requests.isEmpty)
        #expect(store.shouldOffer)
        #expect(activeWindow.attachedSheet === blockerSheet)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == false
        )
    }

    @Test
    func automaticStatusFailureDoesNotPresentOrRecord() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let recorder = SheetOfferInstallerRecorder(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable]),
            failure: .status
        )
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "status-failure", defaults: defaultsSuite.defaults)
        )
        coordinator.installAgentIntegrations(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(store.shouldOffer)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == false
        )
    }

    @Test
    func terminationCancelsPendingAutomaticOfferAndRejectsStaleStatusResponse() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        try coordinator.start()
        let statusGate = SheetOfferStatusGate(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmation = SheetOfferConfirmationRecorder(result: true)
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "termination-cancellation",
                defaults: defaultsSuite.defaults
            )
        )
        coordinator.installAgentIntegrations(
            installer: statusGate.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store,
            confirmationPresenter: { request in confirmation.present(request) }
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await statusGate.waitUntilFirstRequestStarts()
        let automaticTask = try #require(
            coordinator.agentIntegrationUpdateOfferTaskForTesting
        )

        coordinator.prepareForBridgeShutdownForTesting()
        await statusGate.resumeFirstRequest()
        await automaticTask.value

        #expect(await statusGate.statusRequestCount == 1)
        #expect(await statusGate.prepareRequestCount == 0)
        #expect(await statusGate.applyRequestCount == 0)
        #expect(confirmation.requests.isEmpty)
        #expect(store.shouldOffer)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == false
        )
    }

    @Test(arguments: [SheetOfferInstallerFailure.prepare, .apply])
    func attachedAutomaticOfferRecordsBuildBeforePrepareOrApplyFailure(
        failure: SheetOfferInstallerFailure
    ) async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let recorder = SheetOfferInstallerRecorder(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable]),
            failure: failure
        )
        let confirmation = SheetOfferConfirmationRecorder(result: true)
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "attached-failure-\(failure)",
                defaults: defaultsSuite.defaults
            )
        )
        coordinator.installAgentIntegrations(
            installer: recorder.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store,
            confirmationPresenter: { request in confirmation.present(request) }
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(!store.shouldOffer)
        #expect(await recorder.statusRequestCount == 1)
        #expect(await recorder.prepareRequestCount == 1)
        #expect(await recorder.applyRequestCount == (failure == .apply ? 1 : 0))
        #expect(confirmation.requests.count == (failure == .apply ? 1 : 0))
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == true
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await coordinator.waitForAgentIntegrationUpdateOfferForTesting()

        #expect(await recorder.statusRequestCount == 1)
        #expect(await recorder.prepareRequestCount == 1)
        #expect(await recorder.applyRequestCount == (failure == .apply ? 1 : 0))
        #expect(confirmation.requests.count == (failure == .apply ? 1 : 0))
        coordinator.agentIntegrationsSheetControllerForTesting?.close()
    }

    @Test
    func manualPresentationCancelsPendingAutomaticOfferWithoutRecording() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let statusGate = SheetOfferStatusGate(
            statuses: offerStatuses(overrides: ["claude": .updateAvailable])
        )
        let defaultsSuite = try makeDefaults()
        defer { defaultsSuite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(
                build: "manual-cancellation",
                defaults: defaultsSuite.defaults
            )
        )
        coordinator.installAgentIntegrations(
            installer: statusGate.client,
            launcherInstaller: makeLauncherClient(),
            updateOfferStore: store
        )

        coordinator.offerAgentIntegrationUpdatesIfAvailable()
        await statusGate.waitUntilFirstRequestStarts()
        let automaticTask = try #require(
            coordinator.agentIntegrationUpdateOfferTaskForTesting
        )
        #expect(coordinator.hasPendingAgentIntegrationUpdateOfferForTesting)

        coordinator.presentAgentIntegrations()
        await statusGate.resumeFirstRequest()
        await automaticTask.value

        #expect(store.shouldOffer)
        #expect(
            coordinator.agentIntegrationsSheetControllerForTesting?.isPresented == true
        )
        coordinator.agentIntegrationsSheetControllerForTesting?.close()
    }

    @Test
    func coordinatorNormalToQuakeThenCloseFocusesCurrentSurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.installAgentIntegrations(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient()
        )
        let initialStore = coordinator.workspaceStoreForTesting
        let initialSurfaceIDs = coordinator.surfaceIDsForTesting
        let initialSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.presentAgentIntegrations()
        let sheetController = try #require(
            coordinator.agentIntegrationsSheetControllerForTesting
        )
        let sheet = try #require(coordinator.activeWindowForTesting?.attachedSheet)
        coordinator.presentAgentIntegrations()

        #expect(coordinator.activeWindowForTesting?.attachedSheet === sheet)
        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting == initialSurfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === initialSurface)

        coordinator.togglePresentationMode()

        #expect(coordinator.presentationMode == .quake)
        #expect(coordinator.activeWindowForTesting?.attachedSheet === sheet)
        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting == initialSurfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === initialSurface)

        let quakeWindow = try #require(coordinator.activeWindowForTesting)
        let currentSurface = try #require(coordinator.activeSurfaceForTesting)
        sheetController.close()

        #expect(quakeWindow.firstResponder === currentSurface)
    }

    @Test
    func coordinatorRetryReplacementThenCloseFocusesCurrentSurface() throws {
        let helper = try AgentIntegrationsResumeHelperFixture()
        defer { helper.remove() }
        let paneID = PaneID()
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude"),
            sessionID: "focus-retry-session",
            workingDirectory: "/tmp",
            registeredAt: Date(timeIntervalSinceReferenceDate: 100),
            launchMetadata: [:],
            restoreState: .active
        )
        let tab = TerminalTab(
            title: "Retry",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp",
                agentResumeBinding: binding
            )
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let sessionController = try AgentSessionController(
            socketPath: "/tmp/quicktty-focus-\(UUID().uuidString).sock",
            helperPath: helper.path,
            tokenGenerator: { Array(repeating: 0xAB, count: 32) },
            onAction: { _ in false }
        )
        let scheduler = AgentResumeManualScheduler()
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: sessionController,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: { adapterIDs in
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
            },
            agentResumeScheduler: scheduler,
            agentResumeRegistrationTimeout: 1
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())
        try coordinator.start()
        coordinator.installAgentIntegrations(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient()
        )
        let originalSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.presentAgentIntegrations()
        scheduler.advance(by: 1)
        coordinator.retryAgentResumeForTesting(paneID)

        let replacementSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(replacementSurface !== originalSurface)
        let sheetController = try #require(
            coordinator.agentIntegrationsSheetControllerForTesting
        )
        sheetController.close()

        #expect(coordinator.activeWindowForTesting?.firstResponder === replacementSurface)
    }

    @Test
    func closingRequestsTerminalFocusRestoration() {
        let focusRecorder = TerminalFocusRestorationRecorder()
        let controller = AgentIntegrationsSheetController(
            viewController: makeViewController(),
            restoreTerminalFocus: focusRecorder.restore
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        controller.present(on: parent)
        controller.close()

        #expect(focusRecorder.restoreCallCount == 1)
    }

    private func makeViewController() -> AgentIntegrationsViewController {
        AgentIntegrationsViewController(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient(),
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
    }

    private func makeInstallerClient() -> AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [] },
            prepare: { _ in AgentIntegrationPreparedSummary(planID: "plan", adapters: []) },
            apply: { _ in AgentIntegrationApplySummary(adapters: []) }
        )
    }

    private func makeLauncherClient() -> CommandLineLauncherInstallerClient {
        CommandLineLauncherInstallerClient(
            prepare: {
                CommandLineLauncherSummary(
                    planID: "launcher",
                    displayPath: "~/.local/bin/quicktty",
                    kind: "symlinkCreate",
                    createsBackup: false,
                    status: .available
                )
            },
            apply: { _ in .succeeded }
        )
    }

    private func offerStatuses(
        overrides: [String: AgentIntegrationInstallerStatus] = [:]
    ) -> [AgentIntegrationAdapterSummary] {
        let blocked: Set<String> = [
            "grok", "campfire", "kiro", "rovo-dev", "codebuddy", "ollama",
        ]
        let wrappers: Set<String> = ["amp", "antigravity", "opencode"]
        return AgentIntegrationInstaller.adapterIDs.map { adapterID in
            let capability: AgentIntegrationInstallerCapability =
                if blocked.contains(adapterID) {
                    .blocked
                } else if wrappers.contains(adapterID) {
                    .wrapperLifecycle
                } else {
                    .nativeLifecycle
                }
            return AgentIntegrationAdapterSummary(
                adapterID: adapterID,
                capability: capability,
                status: blocked.contains(adapterID)
                    ? .blocked : overrides[adapterID] ?? .available,
                operations: []
            )
        }
    }

    private func makeDefaults() throws -> SheetDefaultsSuite {
        let name = "AgentIntegrationsSheetControllerTests.\(UUID().uuidString)"
        return SheetDefaultsSuite(
            name: name,
            defaults: try #require(UserDefaults(suiteName: name))
        )
    }
}

enum SheetOfferInstallerFailure: Error, Equatable, Sendable {
    case status
    case prepare
    case apply
}

private actor SheetOfferInstallerRecorder {
    let statuses: [AgentIntegrationAdapterSummary]
    let failure: SheetOfferInstallerFailure?
    private(set) var statusRequestCount = 0
    private(set) var prepareRequestCount = 0
    private(set) var applyRequestCount = 0
    private(set) var appliedPlanIDs: [String] = []

    init(
        statuses: [AgentIntegrationAdapterSummary],
        failure: SheetOfferInstallerFailure? = nil
    ) {
        self.statuses = statuses
        self.failure = failure
    }

    nonisolated var client: AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [self] generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await requestStatus()
                )
            },
            prepare: { [self] generation, _, selected in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await prepare(selected)
                )
            },
            apply: { [self] generation, planID in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await apply(planID)
                )
            }
        )
    }

    private func requestStatus() throws -> [AgentIntegrationAdapterSummary] {
        statusRequestCount += 1
        if failure == .status {
            throw SheetOfferInstallerFailure.status
        }
        return statuses
    }

    private func prepare(_ selected: [String]) throws -> AgentIntegrationPreparedSummary {
        prepareRequestCount += 1
        if failure == .prepare {
            throw SheetOfferInstallerFailure.prepare
        }
        return AgentIntegrationPreparedSummary(
            planID: "sheet-offer-plan",
            adapters: statuses.filter { selected.contains($0.adapterID) }
        )
    }

    private func apply(_ planID: String) throws -> AgentIntegrationApplySummary {
        applyRequestCount += 1
        if failure == .apply {
            throw SheetOfferInstallerFailure.apply
        }
        appliedPlanIDs.append(planID)
        return AgentIntegrationApplySummary(
            adapters: statuses.filter { $0.status == .updateAvailable }
        )
    }
}

private actor SheetOfferStatusGate {
    let statuses: [AgentIntegrationAdapterSummary]
    private let firstRequestStarts: AsyncStream<Void>
    private let firstRequestStartContinuation: AsyncStream<Void>.Continuation
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private(set) var statusRequestCount = 0
    private(set) var prepareRequestCount = 0
    private(set) var applyRequestCount = 0

    init(statuses: [AgentIntegrationAdapterSummary]) {
        self.statuses = statuses
        (firstRequestStarts, firstRequestStartContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    nonisolated var client: AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [self] generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: await requestStatus()
                )
            },
            prepare: { [self] generation, _, selected in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: await prepare(selected)
                )
            },
            apply: { [self] generation, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: await apply()
                )
            }
        )
    }

    func waitUntilFirstRequestStarts() async {
        for await _ in firstRequestStarts {
            return
        }
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    private func requestStatus() async -> [AgentIntegrationAdapterSummary] {
        statusRequestCount += 1
        if statusRequestCount == 1 {
            firstRequestStartContinuation.yield()
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        return statuses
    }

    private func prepare(_ selected: [String]) -> AgentIntegrationPreparedSummary {
        prepareRequestCount += 1
        return AgentIntegrationPreparedSummary(
            planID: "manual-cancellation-plan",
            adapters: statuses.filter { selected.contains($0.adapterID) }
        )
    }

    private func apply() -> AgentIntegrationApplySummary {
        applyRequestCount += 1
        return AgentIntegrationApplySummary(adapters: statuses)
    }
}

@MainActor
private final class SheetOfferConfirmationRecorder {
    let result: Bool
    private(set) var requests: [AgentIntegrationConfirmationRequest] = []

    init(result: Bool) {
        self.result = result
    }

    func present(_ request: AgentIntegrationConfirmationRequest) -> Bool {
        requests.append(request)
        return result
    }
}

@MainActor
private struct SheetDefaultsSuite {
    let name: String
    let defaults: UserDefaults

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

@MainActor
private final class TerminalFocusRestorationRecorder {
    private(set) var restoreCallCount = 0

    func restore() {
        restoreCallCount += 1
    }
}

@MainActor
private final class AgentIntegrationsResumeHelperFixture {
    let directoryURL: URL
    let path: String

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-AgentIntegrationsFocus-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let helperURL = directoryURL.appending(path: "quicktty")
        try Data("#!/bin/sh\nwhile :; do sleep 60; done\n".utf8).write(to: helperURL)
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

@MainActor
private final class SheetTestHotKeyController: HotKeyControlling {
    private(set) var registeredChord: ShortcutChord?

    func replace(with chord: ShortcutChord) throws {
        registeredChord = chord
    }

    func unregister() throws {
        registeredChord = nil
    }
}
