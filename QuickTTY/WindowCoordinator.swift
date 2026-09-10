import AppKit

struct WorkspaceDeletionConfirmation: Equatable {
    let workspaceID: WorkspaceID
    let workspaceName: String
    let tabCount: Int
    let paneCount: Int
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private enum StartupState {
        case notStarted
        case starting
        case started
    }

    typealias ModePersistence = @MainActor (PresentationMode) -> Void
    typealias QuakeHeightPersistence = @MainActor (Double) -> Void
    typealias NormalWindowFramePersistence = @MainActor (NormalWindowFrame) -> Void
    typealias WorkspacePersistence = @MainActor (WorkspaceStore) -> Void
    typealias WorkspaceDeletionConfirmationPresenter =
        @MainActor (
            WorkspaceDeletionConfirmation,
            @escaping @MainActor (Bool) -> Void
        ) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void
    typealias TerminalActivityEffectHandler = @MainActor (TerminalActivityEffect) -> Void
    typealias AgentRestoreCompatibilityProvider =
        @MainActor ([AgentAdapterID]) -> [AgentAdapterID: AgentRestoreCompatibility]
    typealias AgentRestoreHomeDirectory = @MainActor () -> String
    typealias AgentRestoreWorkingDirectoryExists = @MainActor (String) -> Bool
    typealias AgentRestorePlanning =
        @MainActor (AgentRestorePlanner.Input) -> [PaneID: AgentRestoreDecision]
    typealias ManagedTaskIDProvider = @MainActor () -> UUID
    typealias TerminalAutomationPermissionPresenter =
        @MainActor (TerminalAutomationResolvedSession) async -> TerminalAutomationPermissionDecision

    private enum ManagedSnapshotState: Equatable {
        case running
        case runningReadFailed
        case pendingFinal
        case readingFinal
        case finalReadFailed
        case finalCaptured
        case closedFallback
        case revoked
    }

    private struct ManagedTerminalTaskRecord {
        var task: TerminalControlTask
        let session: TerminalAutomationSessionIdentity
        let splitID: UUID?
        let previousFocus: ManagedTaskFocusContext?
        let createdTask: TerminalControlTask
        let processGeneration = UUID()
        var surfaceIdentity: ObjectIdentifier?
        var isAccepted = false
        // WHY: Direct host creation is accepted for cleanup, but has no domain grant to advertise.
        var hasDomainAcceptance = false
        var rendered = GhosttyRenderedText(text: "", isTruncated: false)
        var lastRefresh: TimeInterval?
        var snapshotState: ManagedSnapshotState = .running
        var completionObserved = false
        var completionExitCode: Int32?
        var isRevoked = false
        var completionTask: Task<Void, Never>?

        mutating func update(
            rendered: GhosttyRenderedText? = nil,
            state: TerminalTaskState? = nil,
            owner: TerminalPaneControlOwner? = nil,
            exitCode: Int32? = nil
        ) {
            let output = rendered ?? self.rendered
            let exitCode = state == nil ? task.exitCode : exitCode
            let state = state ?? task.state
            let owner = owner ?? task.owner
            guard
                !output.text.utf8.elementsEqual(self.rendered.text.utf8)
                    || output.isTruncated != self.rendered.isTruncated
                    || state != task.state || owner != task.owner || exitCode != task.exitCode
            else { return }
            // WHY: Content-only revisions do not invalidate capture for the same lifecycle.
            if snapshotState == .finalCaptured,
                state != task.state || owner != task.owner || exitCode != task.exitCode
            {
                snapshotState = .finalReadFailed
            }
            precondition(task.revision < UInt64.max, "Terminal revision exhausted")
            task = TerminalControlTask(
                taskID: task.taskID, paneID: task.paneID, tabID: task.tabID,
                workspaceID: task.workspaceID, state: state, owner: owner, policy: task.policy,
                revision: task.revision + 1, exitCode: exitCode
            )
            self.rendered = output
        }
    }

    @MainActor
    private final class ManagedCloseDecision {
        let paneID: PaneID
        let session: TerminalAutomationSessionIdentity
        let processGeneration: UUID
        let surfaceIdentity: ObjectIdentifier?
        var response: GhosttyClipboardConfirmationResponse?
        var isCancelled = false
        var participantCount = 0
        var confirmationToken: GhosttyConfirmationQueue.CloseToken?

        init(_ record: ManagedTerminalTaskRecord) {
            paneID = PaneID(rawValue: record.task.paneID)
            session = record.session
            processGeneration = record.processGeneration
            surfaceIdentity = record.surfaceIdentity
        }
    }

    private struct ManagedTaskFocusContext {
        let selectionGeneration: UInt64
        let activeWorkspaceID: WorkspaceID
        let targetActiveTabID: TabID?
        let targetActivePaneID: PaneID?
    }

    private struct DiscardedManagedTaskRecord {
        let created: TerminalAutomationCreatedTaskResponse
        let session: TerminalAutomationSessionIdentity
        var compensationCompleted: Bool
    }

    private let ghosttyBridge: GhosttyBridge
    private let normalWindowController: NormalWindowController
    private let quakeWindowController: QuakeWindowController
    private let presentationController: PresentationController
    private let hotKeyController: any HotKeyControlling
    private let menuBarManager: MenuBarManager
    private let surfaceConfiguration: GhosttySurfaceConfiguration
    private let executableSearchPath: String
    private weak var agentSessionController: AgentSessionController?
    private let agentRestoreCompatibility: [AgentAdapterID: AgentRestoreCompatibility]
    private let agentRestoreCompatibilityResolver: AgentRestoreCompatibilityProvider?
    private let agentRestoreHomeDirectory: AgentRestoreHomeDirectory
    private let agentRestoreWorkingDirectoryExists: AgentRestoreWorkingDirectoryExists
    private let agentRestorePlanner: AgentRestorePlanning
    private let agentResumeScheduler: any AgentResumeScheduling
    private let agentResumeRegistrationTimeout: TimeInterval
    private let agentResumeStableConfirmationThreshold: TimeInterval
    private let agentResumeClaimLifetime: TimeInterval
    private let managedTaskIDProvider: ManagedTaskIDProvider
    private let terminalAutomationNow: @MainActor () -> TimeInterval
    private let terminalAutomationPermissionPresenter: TerminalAutomationPermissionPresenter?
    private let terminalControlPermissionController: TerminalControlPermissionController
    private let terminalActivityController: TerminalActivityController
    private var terminalNotificationController: TerminalNotificationController?
    private let confirmationPresenter: GhosttyConfirmationQueue.Presenter?
    private let workspaceDeletionConfirmationPresenter: WorkspaceDeletionConfirmationPresenter?
    private let persistNormalWindowFrame: NormalWindowFramePersistence
    private let persistWorkspaceStore: WorkspacePersistence
    private let onError: ErrorHandler
    private let workspaceViewController = WorkspaceViewController()
    private let splitCoordinator = SplitCoordinator()
    private var workspaceStore: WorkspaceStore
    private var selectionGeneration: UInt64 = 0
    private var createWorkspaceController: CreateWorkspaceController?
    private var agentIntegrationsSheetController: AgentIntegrationsSheetController?
    private var agentIntegrationUpdateOfferStore: AgentIntegrationUpdateOfferStore?
    private var agentIntegrationUpdateOfferTask: Task<Void, Never>?
    private var agentIntegrationUpdateOfferTaskID: UUID?
    private var isAgentIntegrationUpdateOfferPresented = false
    private var pendingWorkspaceDeletionID: WorkspaceID?
    private var startupState: StartupState = .notStarted
    private var surfaces: [PaneID: GhosttySurfaceView] = [:]
    private var surfaceFailures: [PaneID: SurfaceFailurePresentation] = [:]
    private var agentResumePresentations: [PaneID: AgentResumePresentation] = [:]
    private var agentResumeAttempts: [PaneID: AgentResumeAttempt] = [:]
    private var agentResumeGenerationByPane: [PaneID: UInt64] = [:]
    private var agentCredentialGenerationByPane: [PaneID: UInt64] = [:]
    private var managedTasks: [UUID: ManagedTerminalTaskRecord] = [:]
    private var managedCloseDecisions: [UUID: ManagedCloseDecision] = [:]
    private var managedPresentationRefreshTask: Task<Void, Never>?
    private var managedTaskOrder: [UUID] = []
    private var managedTaskIDByPane: [PaneID: UUID] = [:]
    private var discardedManagedTasks: [UUID: DiscardedManagedTaskRecord] = [:]
    private var shouldRestoreAgentSessions = false
    private var closingTabIDs: Set<TabID> = []
    private var closingPaneIDs: Set<PaneID> = []
    private var configuredGlobalChord = ShortcutChord(key: .f12)
    private var configEditor = "nano"
    private var workspaceMenuTransientInteraction: QuakeWindowController.TransientInteraction?
    private var tabRenameTransientInteraction: QuakeWindowController.TransientInteraction?
    private var isTabRenameEditing = false
    private var isPreparingForTermination = false
    private var isTerminalControlFrozen = false
    private var activityConfiguration: GhosttyActivityConfiguration
    private var activityCallbackGeneration = 0

    private lazy var terminalAutomationHostFacade = WindowCoordinatorTerminalAutomationHost(
        coordinator: self
    )

    private lazy var terminalAutomationCoordinator = TerminalAutomationCoordinator(
        host: terminalAutomationHostFacade
    )

    private lazy var agentResumeRuntime = AgentResumeRuntime(
        scheduler: agentResumeScheduler,
        registrationTimeout: agentResumeRegistrationTimeout,
        stableConfirmationThreshold: agentResumeStableConfirmationThreshold,
        claimLifetime: agentResumeClaimLifetime
    ) { [weak self] action in
        self?.applyAgentResumeRuntimeAction(action)
    }

    var terminalActivityEffectHandler: TerminalActivityEffectHandler?
    var terminalAutomationPresentationHandler:
        (@MainActor (TerminalAutomationPresentationEvent) -> Void)?
    var terminalAutomationAttentionHandler: (@MainActor (TerminalAutomationAttention) -> Void)?

    var terminalActivityConfiguration: GhosttyActivityConfiguration {
        activityConfiguration
    }

    #if DEBUG
        private var failsNextStartupModelMutationForTesting = false
        private var failsNextSplitMutationForTesting = false
        private var failsNextManagedTabMutationForTesting = false
        private var failsNextManagedSplitMutationForTesting = false
        private var failsNextManagedCommitForTesting = false
        var managedCloseWaiterJoinedForTesting: ((Int) -> Void)?
        private var refreshWorkspacePresentationInvocationCountForTestingStorage = 0
        private var refreshWorkspaceStatusesInvocationCountForTestingStorage = 0
        private var activeWindowIsKeyOverrideForTesting: Bool?
        private var closeUnavailablePaneDidBeginHookForTesting: ((PaneID) -> Void)?
        private var retryUnavailablePanePresentationCallbackForTesting: ((PaneID) -> Void)?
        private var closeUnavailablePanePresentationCallbackForTesting: ((PaneID) -> Void)?
    #endif

    private lazy var confirmationQueue = GhosttyConfirmationQueue {
        [weak self] presentation, completion in
        // WHY: Queued work may reach the presenter only after freeze. Resolve it without
        // opening either an injected presenter or a native sheet, so callbacks cannot hang.
        guard let self, !isPreparingForTermination else {
            completion(.deny)
            return nil
        }
        if let confirmationPresenter {
            return confirmationPresenter(presentation, completion)
        }
        return presentConfirmation(presentation, completion: completion)
    }

    var presentationMode: PresentationMode { presentationController.mode }

    var workspaceStoreForPersistence: WorkspaceStore {
        var candidate = workspaceStore
        for (paneID, workingDirectory) in ghosttyBridge.latestWorkingDirectoriesForPersistence
        where !workingDirectory.isEmpty && (workingDirectory as NSString).isAbsolutePath {
            try? candidate.updateWorkingDirectory(workingDirectory, for: paneID)
        }
        return candidate
    }

    var isBroadcastingActiveTab: Bool {
        activeTab?.isBroadcasting ?? false
    }

    var canToggleBroadcast: Bool {
        activeTab != nil
    }

    var hasActiveWorkspace: Bool {
        workspaceStore.workspace(id: workspaceStore.activeWorkspaceID) != nil
    }

    var canDeleteActiveWorkspace: Bool {
        hasActiveWorkspace && workspaceStore.workspaces.count > 1
    }

    var canCloseActivePane: Bool {
        activePaneID != nil
    }

    var canCloseActiveTab: Bool {
        guard let activeTab else { return false }
        return !activeTab.root.leaves.isEmpty
            && activeTab.root.leaves.allSatisfy { surfaces[$0] != nil }
    }

    var canSplitActivePane: Bool {
        activePaneID.flatMap { surfaces[$0] } != nil
    }

    var canNavigateActivePanes: Bool {
        (activeTab?.root.leaves.count ?? 0) > 1
    }

    var canPresentAgentIntegrations: Bool {
        agentIntegrationsSheetController != nil && activeWindow != nil
    }

    var activeTabCount: Int {
        workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)?.tabs.count ?? 0
    }

    var workspaceCount: Int {
        workspaceStore.workspaces.count
    }

    var registeredGlobalChord: ShortcutChord? {
        hotKeyController.registeredChord
    }

    func createWorkspace() {
        presentCreateWorkspace()
    }

    func renameActiveWorkspace() {
        presentRenameWorkspace()
    }

    func deleteActiveWorkspace() {
        requestDeleteActiveWorkspace()
    }

    func installAgentIntegrations(
        installer: AgentIntegrationInstallerClient,
        launcherInstaller: CommandLineLauncherInstallerClient,
        updateOfferStore: AgentIntegrationUpdateOfferStore? = nil,
        confirmationPresenter: AgentIntegrationsViewController.ConfirmationPresenter? = nil
    ) {
        guard agentIntegrationsSheetController == nil else { return }
        let viewController = AgentIntegrationsViewController(
            installer: installer,
            launcherInstaller: launcherInstaller,
            bindingProvider: { [weak self] in
                self?.agentIntegrationBindingSnapshots() ?? []
            },
            retryBinding: { [weak self] paneID in
                self?.retryAgentResume(paneID)
            },
            forgetBinding: { [weak self] paneID in
                self?.forgetAgentResume(paneID)
            },
            confirmationPresenter: confirmationPresenter
        )
        agentIntegrationUpdateOfferStore = updateOfferStore
        agentIntegrationsSheetController = AgentIntegrationsSheetController(
            viewController: viewController,
            restoreTerminalFocus: { [weak self] in
                guard let self,
                    let paneID = activePaneID,
                    let surface = surfaces[paneID],
                    let window = activeWindow,
                    surface.window === window
                else { return }
                // WHY: Sheet dismissal can outlive the early termination freeze.
                focus(surface, paneID: paneID)
            }
        )
    }

    func offerAgentIntegrationUpdatesIfAvailable() {
        guard let store = agentIntegrationUpdateOfferStore,
            let sheetController = agentIntegrationsSheetController,
            store.shouldOffer
        else { return }

        cancelAgentIntegrationUpdateOffer(onlyIfPending: false)
        let taskID = UUID()
        agentIntegrationUpdateOfferTaskID = taskID
        isAgentIntegrationUpdateOfferPresented = false
        agentIntegrationUpdateOfferTask = Task { @MainActor [weak self, sheetController, store] in
            guard self?.isCurrentAgentIntegrationUpdateOffer(taskID) == true else { return }
            let hasUpdates = await sheetController.viewController.prepareUpdateOffer()
            guard let self else { return }
            defer { finishAgentIntegrationUpdateOffer(taskID) }
            guard isCurrentAgentIntegrationUpdateOffer(taskID),
                hasUpdates,
                store.shouldOffer,
                case .started = startupState,
                activeWindow != nil
            else { return }

            do {
                try presentationController.showCurrentPresentation()
            } catch {
                onError(error)
                return
            }
            guard isCurrentAgentIntegrationUpdateOffer(taskID),
                store.shouldOffer,
                let window = activeWindow,
                sheetController.presentPreparedOffer(on: window)
            else { return }

            store.recordOffered()
            isAgentIntegrationUpdateOfferPresented = true
            await sheetController.viewController.changeSelectedIntegrationsWithConfirmation()
        }
    }

    func presentAgentIntegrations() {
        guard !isPreparingForTermination else { return }
        cancelAgentIntegrationUpdateOffer(onlyIfPending: true)
        guard let sheetController = agentIntegrationsSheetController else { return }
        do {
            try presentationController.showCurrentPresentation()
        } catch {
            onError(error)
            return
        }
        guard !isPreparingForTermination, let window = activeWindow else { return }
        sheetController.present(on: window)
    }

    private func isCurrentAgentIntegrationUpdateOffer(_ taskID: UUID) -> Bool {
        !isPreparingForTermination && agentIntegrationUpdateOfferTaskID == taskID
            && !Task.isCancelled
    }

    private func finishAgentIntegrationUpdateOffer(_ taskID: UUID) {
        guard agentIntegrationUpdateOfferTaskID == taskID else { return }
        agentIntegrationUpdateOfferTask = nil
        agentIntegrationUpdateOfferTaskID = nil
        isAgentIntegrationUpdateOfferPresented = false
    }

    private func cancelAgentIntegrationUpdateOffer(onlyIfPending: Bool) {
        guard !onlyIfPending || !isAgentIntegrationUpdateOfferPresented else { return }
        agentIntegrationUpdateOfferTask?.cancel()
        agentIntegrationUpdateOfferTask = nil
        agentIntegrationUpdateOfferTaskID = nil
        isAgentIntegrationUpdateOfferPresented = false
    }

    private func agentIntegrationBindingSnapshots() -> [AgentIntegrationBindingSnapshot] {
        workspaceStore.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.root.leaves.compactMap { paneID in
                    guard let binding = tab.paneDescriptor(for: paneID)?.agentResumeBinding else {
                        return nil
                    }
                    let definition = AgentIntegrationRegistry.definition(for: binding.adapterID)
                    let state: AgentIntegrationBindingSnapshot.State
                    let canRetry: Bool
                    switch binding.restoreState {
                    case .active:
                        state = .active
                        canRetry = false
                    case .restoring:
                        state = .restoring
                        canRetry = false
                    case .unverified:
                        state = .unverified
                        canRetry = true
                    case .failed(let diagnosticCode, _):
                        state = .failed
                        canRetry =
                            AgentResumePresentation.failed(
                                diagnosticCode: diagnosticCode
                            ).canRetry
                    }
                    return AgentIntegrationBindingSnapshot(
                        paneID: paneID,
                        agentName: definition?.displayName ?? "Unknown Agent",
                        state: state,
                        canRetry: canRetry,
                        canForget: true
                    )
                }
            }
        }
    }

    init(
        ghosttyBridge: GhosttyBridge,
        presentationMode: PresentationMode = .normal,
        normalWindowFrame: NormalWindowFrame? = nil,
        quakeConfiguration: QuakeWindowConfiguration = QuakeWindowConfiguration(),
        surfaceConfiguration: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration(),
        executableSearchPath: String = ApplicationEnvironment.effectiveGUIExecutableSearchPath(),
        agentSessionController: AgentSessionController? = nil,
        terminalActivityController: TerminalActivityController? = nil,
        terminalNotificationController: TerminalNotificationController? = nil,
        initialWorkspaceStore: WorkspaceStore = WorkspaceStore(),
        agentRestoreCompatibility: [AgentAdapterID: AgentRestoreCompatibility] = [:],
        agentRestoreCompatibilityResolver: AgentRestoreCompatibilityProvider? = nil,
        agentRestoreHomeDirectory: @escaping AgentRestoreHomeDirectory = {
            FileManager.default.homeDirectoryForCurrentUser.path
        },
        agentRestoreWorkingDirectoryExists: @escaping AgentRestoreWorkingDirectoryExists = {
            path in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        agentRestorePlanner: @escaping AgentRestorePlanning = {
            AgentRestorePlanner().plan($0)
        },
        agentResumeScheduler: (any AgentResumeScheduling)? = nil,
        agentResumeRegistrationTimeout: TimeInterval = 10,
        agentResumeStableConfirmationThreshold: TimeInterval = 1,
        agentResumeClaimLifetime: TimeInterval = 30,
        managedTaskIDProvider: @escaping ManagedTaskIDProvider = { UUID() },
        terminalAutomationNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        terminalAutomationPermissionPresenter: TerminalAutomationPermissionPresenter? = nil,
        terminalAutomationPermissionTimeout: TimeInterval = 60,
        persistWorkspaceStore: @escaping WorkspacePersistence = { _ in },
        confirmationPresenter: GhosttyConfirmationQueue.Presenter? = nil,
        workspaceDeletionConfirmationPresenter: WorkspaceDeletionConfirmationPresenter? = nil,
        persistPresentationMode: @escaping ModePersistence = { _ in },
        persistQuakeHeight: @escaping QuakeHeightPersistence = { _ in },
        persistNormalWindowFrame: @escaping NormalWindowFramePersistence = { _ in },
        onError: @escaping ErrorHandler = { _ in },
        hotKeyController: (any HotKeyControlling)? = nil,
        quakeWindowController: QuakeWindowController? = nil,
        visibleScreenFrames: @escaping @MainActor () -> [NSRect] = {
            NSScreen.screens.map(\.visibleFrame)
        }
    ) {
        let normalWindowController = NormalWindowController()
        // WHY: Inject the concrete controller to exercise real freeze wiring with manual drivers.
        let quakeWindowController =
            quakeWindowController
            ?? QuakeWindowController(
                configuration: quakeConfiguration,
                persistQuakeHeight: persistQuakeHeight
            )
        let hotKeyRelay = HotKeyActionRelay()
        let resolvedHotKeyController =
            hotKeyController
            ?? GlobalHotKeyController {
                hotKeyRelay.perform()
            }
        let restoredNormalFrame = normalWindowFrame.flatMap {
            Self.restoredWindowFrame(from: $0, visibleScreenFrames: visibleScreenFrames())
        }

        self.ghosttyBridge = ghosttyBridge
        self.normalWindowController = normalWindowController
        self.quakeWindowController = quakeWindowController
        self.hotKeyController = resolvedHotKeyController
        self.menuBarManager = MenuBarManager(
            systemPresentationEnabled: !ApplicationEnvironment.isRunningHostedTests
        )
        self.surfaceConfiguration = surfaceConfiguration
        self.executableSearchPath = executableSearchPath
        self.agentSessionController = agentSessionController
        self.agentRestoreCompatibility = agentRestoreCompatibility
        self.agentRestoreCompatibilityResolver = agentRestoreCompatibilityResolver
        self.agentRestoreHomeDirectory = agentRestoreHomeDirectory
        self.agentRestoreWorkingDirectoryExists = agentRestoreWorkingDirectoryExists
        self.agentRestorePlanner = agentRestorePlanner
        self.agentResumeScheduler = agentResumeScheduler ?? AgentResumeProductionScheduler()
        self.agentResumeRegistrationTimeout = agentResumeRegistrationTimeout
        self.agentResumeStableConfirmationThreshold = agentResumeStableConfirmationThreshold
        self.agentResumeClaimLifetime = agentResumeClaimLifetime
        self.managedTaskIDProvider = managedTaskIDProvider
        self.terminalAutomationNow = terminalAutomationNow
        self.terminalAutomationPermissionPresenter = terminalAutomationPermissionPresenter
        terminalControlPermissionController = TerminalControlPermissionController(
            timeout: terminalAutomationPermissionTimeout)
        self.terminalActivityController =
            terminalActivityController ?? TerminalActivityController()
        self.terminalNotificationController = terminalNotificationController
        activityConfiguration = ghosttyBridge.activityConfiguration
        workspaceStore = initialWorkspaceStore
        self.confirmationPresenter = confirmationPresenter
        self.workspaceDeletionConfirmationPresenter = workspaceDeletionConfirmationPresenter
        self.persistNormalWindowFrame = persistNormalWindowFrame
        self.persistWorkspaceStore = persistWorkspaceStore
        self.onError = onError
        presentationController = try! PresentationController(
            contentViewController: workspaceViewController,
            normalWindowController: normalWindowController,
            quakeWindowController: quakeWindowController,
            initialMode: presentationMode,
            savedNormalFrame: restoredNormalFrame,
            persistSuccessfulMode: persistPresentationMode,
            onError: onError
        )
        super.init()

        workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
        workspaceViewController.applySplitAppearance(ghosttyBridge.splitAppearance)
        normalWindowController.window?.delegate = self
        hotKeyRelay.action = { [weak self] in
            self?.presentationController.toggleQuakeVisibility()
        }
        menuBarManager.applyMode(presentationMode)
        menuBarManager.setToggleCallback { [weak self] in
            self?.presentationController.toggleQuakeVisibility()
        }
        ghosttyBridge.manualInputHandler = { [weak self] paneID in
            self?.takeManualControl(of: paneID)
        }
        ghosttyBridge.surfaceFocusHandler = { [weak self] paneID in
            self?.surfaceDidBecomeFirstResponder(id: paneID)
        }
        ghosttyBridge.surfaceTitleHandler = { [weak self] paneID, _ in
            self?.surfaceTitleDidChange(id: paneID)
        }
        ghosttyBridge.surfaceTabTitleHandler = { [weak self] paneID, title in
            self?.surfaceTabTitleDidChange(id: paneID, title: title)
        }
        ghosttyBridge.surfaceTabTitlePromptHandler = { [weak self] paneID in
            self?.surfaceDidRequestTabTitlePrompt(id: paneID)
        }
        ghosttyBridge.surfaceWorkingDirectoryHandler = { [weak self] paneID, workingDirectory in
            self?.surfaceWorkingDirectoryDidChange(id: paneID, workingDirectory: workingDirectory)
        }
        installSurfaceActivityHandlers()
        self.terminalActivityController.scheduledEffectHandler = { [weak self] effect in
            self?.handleScheduledActivityEffect(effect)
        }
        ghosttyBridge.inputTargetProvider = { [weak self] sourcePaneID in
            guard let self else { return [sourcePaneID] }
            return TerminalInputRouter.targetPaneIDs(
                in: workspaceStore,
                sourcePaneID: sourcePaneID
            ).filter { surfaces[$0] != nil }
        }
        ghosttyBridge.clipboardConfirmationHandler = { [weak self] event in
            switch event {
            case .request(let request, let response):
                // WHY: A late request must not wait behind an already-present confirmation.
                guard let self, !isPreparingForTermination else {
                    response(.deny)
                    return
                }
                confirmationQueue.enqueueClipboard(request, completion: response)
            case .invalidate(let paneID):
                self?.confirmationQueue.invalidateClipboard(for: paneID)
            }
        }
        // WHY: Teardown may be their first use; creating a weak self during deinit traps.
        _ = terminalAutomationCoordinator
        _ = confirmationQueue
        _ = agentResumeRuntime
        configurePresentationCallbacks()
    }

    isolated deinit {
        prepareForApplicationTermination()
        try? hotKeyController.unregister()
        ghosttyBridge.manualInputHandler = nil
        ghosttyBridge.surfaceFocusHandler = nil
        ghosttyBridge.surfaceTitleHandler = nil
        ghosttyBridge.surfaceTabTitleHandler = nil
        ghosttyBridge.surfaceTabTitlePromptHandler = nil
        ghosttyBridge.surfaceWorkingDirectoryHandler = nil
        ghosttyBridge.surfaceProgressHandler = nil
        ghosttyBridge.surfaceCommandFinishedHandler = nil
        ghosttyBridge.surfaceProcessExitedHandler = nil
        terminalActivityController.scheduledEffectHandler = nil
        ghosttyBridge.inputTargetProvider = { [$0] }
        ghosttyBridge.clipboardConfirmationHandler = nil
        if normalWindowController.window?.delegate === self {
            normalWindowController.window?.delegate = nil
        }
    }

    var normalWindowFrame: NormalWindowFrame? {
        Self.normalWindowFrame(from: presentationController.normalFrameForPersistence)
    }

    private var activeWindow: NSWindow? {
        switch presentationMode {
        case .normal:
            normalWindowController.window
        case .quake:
            quakeWindowController.appKitWindow
        }
    }

    static func windowFrame(from frame: NormalWindowFrame) -> NSRect {
        NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    static func normalWindowFrame(from frame: NSRect) -> NormalWindowFrame? {
        NormalWindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    static func restoredWindowFrame(
        from savedFrame: NormalWindowFrame,
        visibleScreenFrames: [NSRect]
    ) -> NSRect? {
        let savedRect = windowFrame(from: savedFrame)
        var selectedScreen: NSRect?
        var largestIntersectionArea: CGFloat = 0

        for screen in visibleScreenFrames where isValidVisibleScreenFrame(screen) {
            let intersection = savedRect.intersection(screen)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > largestIntersectionArea {
                largestIntersectionArea = area
                selectedScreen = screen
            }
        }

        guard let selectedScreen else { return nil }
        let minimumFrameSize = NormalWindowController.minimumFrameSize
        let width = min(max(savedRect.width, minimumFrameSize.width), selectedScreen.width)
        let height = min(max(savedRect.height, minimumFrameSize.height), selectedScreen.height)
        let x = min(
            max(savedRect.minX, selectedScreen.minX),
            selectedScreen.maxX - width
        )
        let y = min(
            max(savedRect.minY, selectedScreen.minY),
            selectedScreen.maxY - height
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func isValidVisibleScreenFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    func start() throws {
        guard !isPreparingForTermination, case .notStarted = startupState else { return }
        startupState = .starting

        do {
            workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
            workspaceViewController.applySplitAppearance(ghosttyBridge.splitAppearance)
            if workspaceStore.workspaces.allSatisfy({ $0.tabs.isEmpty }) {
                try createStartupShellTab()
            } else {
                try restoreWorkspaceSurfaces()
            }
            refreshWorkspacePresentation(focusTerminal: true)
            startupState = .started
        } catch {
            startupState = .notStarted
            throw error
        }
    }

    @discardableResult
    private func commitWorkspaceStore(_ candidate: WorkspaceStore) -> Bool {
        // WHY: Retained callbacks share this boundary; freeze protects the model, selection epoch,
        // persistence and search deactivation even when a caller ignores the commit result.
        guard !isPreparingForTermination else { return false }
        let previousActivePaneID = activePaneID
        guard candidate != workspaceStore else { return false }
        selectionGeneration = selectionGeneration(after: candidate)
        workspaceStore = candidate
        let committedActivePaneID = activePaneID
        persistWorkspaceStore(workspaceStore)
        // WHY: Persistence can freeze reentrantly after this commit was already accepted.
        guard !isPreparingForTermination else { return true }
        if previousActivePaneID != committedActivePaneID,
            let previousActivePaneID,
            let previousSurface = surfaces[previousActivePaneID]
        {
            previousSurface.endSearchForDeactivation()
        }
        return true
    }

    private func selectionGeneration(after candidate: WorkspaceStore) -> UInt64 {
        // WHY: Track local selections even in background workspaces/tabs, but ignore content updates.
        let selectionChanged =
            candidate.activeWorkspaceID != workspaceStore.activeWorkspaceID
            || candidate.workspaces.count != workspaceStore.workspaces.count
            || workspaceStore.workspaces.contains { workspace in
                guard let updated = candidate.workspace(id: workspace.id) else { return true }
                return updated.activeTabID != workspace.activeTabID
                    || updated.tabs.count != workspace.tabs.count
                    || workspace.tabs.contains { tab in
                        guard let updatedTab = updated.tabs.first(where: { $0.id == tab.id }) else {
                            return true
                        }
                        return updatedTab.activePaneID != tab.activePaneID
                    }
            }
        guard selectionChanged else { return selectionGeneration }
        precondition(selectionGeneration < UInt64.max, "Selection generation exhausted")
        return selectionGeneration + 1
    }

    func handleAgentSessionLifecycleAction(_ action: AgentSessionLifecycleAction) -> Bool {
        let paneID: PaneID
        switch action {
        case .register(let actionPaneID, _), .replace(let actionPaneID, _, _),
            .unregister(let actionPaneID, _, _):
            paneID = actionPaneID
        }
        guard surfaces[paneID] != nil,
            let descriptor = workspaceStore.workspaces.lazy
                .flatMap(\.tabs)
                .compactMap({ $0.paneDescriptor(for: paneID) })
                .first
        else { return false }

        if let attempt = agentResumeAttempts[paneID],
            agentResumeRuntime.isCurrent(attempt.reference)
        {
            switch action {
            case .register(_, let binding):
                guard binding.adapterID == attempt.claimKey.adapterID,
                    binding.sessionID == attempt.claimKey.sessionID
                else { return false }
                let changedLifecycle = agentResumeRuntime.register(
                    attempt.reference,
                    adapterID: binding.adapterID,
                    sessionID: binding.sessionID
                )
                if changedLifecycle {
                    advancePaneAuthorizationEpoch(for: paneID)
                }
                return true
            case .unregister(_, let adapterID, let sessionID):
                guard adapterID == attempt.claimKey.adapterID,
                    sessionID == attempt.claimKey.sessionID
                else { return false }
                agentResumeRuntime.unregister(
                    attempt.reference,
                    adapterID: adapterID,
                    sessionID: sessionID
                )
                advancePaneAuthorizationEpoch(for: paneID)
                return true
            case .replace:
                return false
            }
        }

        switch action {
        case .register(_, let binding):
            if let currentBinding = descriptor.agentResumeBinding {
                guard currentBinding.adapterID == binding.adapterID,
                    currentBinding.sessionID == binding.sessionID
                else { return false }
                if case .active = currentBinding.restoreState {
                    agentResumePresentations.removeValue(forKey: paneID)
                    return true
                }
            }
            let updated = updateAgentResumeBinding(binding, for: paneID)
            if updated {
                agentResumePresentations.removeValue(forKey: paneID)
                advancePaneAuthorizationEpoch(for: paneID)
            }
            return updated
        case .replace(_, let previousSessionID, let binding):
            guard let currentBinding = descriptor.agentResumeBinding,
                currentBinding.adapterID == binding.adapterID,
                currentBinding.sessionID == previousSessionID,
                previousSessionID != binding.sessionID
            else { return false }
            let updated = updateAgentResumeBinding(binding, for: paneID)
            if updated {
                agentResumePresentations.removeValue(forKey: paneID)
                advancePaneAuthorizationEpoch(for: paneID)
            }
            return updated
        case .unregister(_, let adapterID, let sessionID):
            guard let currentBinding = descriptor.agentResumeBinding,
                currentBinding.adapterID == adapterID,
                currentBinding.sessionID == sessionID
            else { return false }
            let updated = updateAgentResumeBinding(nil, for: paneID)
            if updated {
                agentResumePresentations.removeValue(forKey: paneID)
                advancePaneAuthorizationEpoch(for: paneID)
            }
            return updated
        }
    }

    private func advancePaneAuthorizationEpoch(for paneID: PaneID) {
        let current = agentCredentialGenerationByPane[paneID] ?? 0
        precondition(current < UInt64.max, "Pane authorization epoch exhausted")
        agentCredentialGenerationByPane[paneID] = current + 1
        revokeManagedOrigin(paneID)
    }

    private func updateAgentResumeBinding(
        _ binding: AgentResumeBinding?,
        for paneID: PaneID
    ) -> Bool {
        var candidate = workspaceStore
        guard (try? candidate.updateAgentResumeBinding(binding, for: paneID)) != nil else {
            return false
        }
        if candidate == workspaceStore {
            return true
        }
        return commitWorkspaceStore(candidate)
    }

    private func applyAgentResumeRuntimeAction(_ action: AgentResumeRuntimeAction) {
        let paneID: PaneID
        switch action {
        case .updateBinding(let actionPaneID, let binding):
            paneID = actionPaneID
            guard updateAgentResumeBinding(binding, for: paneID) else { return }
            switch binding.restoreState {
            case .active:
                agentResumePresentations.removeValue(forKey: paneID)
            case .restoring:
                agentResumePresentations[paneID] = .restoring
            case .unverified:
                agentResumePresentations[paneID] = .unverified
            case .failed(let diagnosticCode, _):
                agentResumePresentations[paneID] = .failed(
                    diagnosticCode: diagnosticCode
                )
            }
        case .removeBinding(let actionPaneID):
            paneID = actionPaneID
            guard updateAgentResumeBinding(nil, for: paneID) else { return }
            agentResumePresentations.removeValue(forKey: paneID)
        }

        switch agentResumeBinding(for: paneID)?.restoreState {
        case .some(.active):
            break
        default:
            revokeManagedOrigin(paneID)
        }
        if case .started = startupState, activeTab?.root.contains(paneID) == true {
            refreshWorkspacePresentation(focusTerminal: false)
        }
    }

    private func makeConfiguredSurface(
        id paneID: PaneID,
        configuration: GhosttySurfaceConfiguration,
        additionalAppOwnedEnvironment: [String: String] = [:],
        includesAgentIdentityEnvironment: Bool = true
    ) throws -> GhosttySurfaceView {
        // WHY: Creation precedes model commit in tab/split/editor paths; rejecting only the
        // commit would still spawn a process and install credentials after freeze.
        guard !isPreparingForTermination else { throw CancellationError() }
        var configuredSurface = configuration
        if includesAgentIdentityEnvironment {
            // WHY: Normal/restore/agent paths cannot inherit a managed launch opt-in.
            configuredSurface.managedHelperPath = nil
        }
        configuredSurface.environment.removeValue(
            forKey: AgentInvocationPayloadEnvironment.payloadKey
        )
        var installedAgentCredentials = false
        var controlSocketPath: String?

        if includesAgentIdentityEnvironment, let agentSessionController {
            let identityEnvironment: [String: String]?
            if agentSessionController.environment(for: paneID) == nil {
                identityEnvironment = agentSessionController.register(paneID: paneID)
            } else {
                identityEnvironment = agentSessionController.rotate(paneID: paneID)
            }
            if let identityEnvironment {
                configuredSurface.environment.merge(identityEnvironment) { _, appValue in appValue }
                installedAgentCredentials = true
                controlSocketPath = identityEnvironment["QUICKTTY_CONTROL_SOCKET"]
                advancePaneAuthorizationEpoch(for: paneID)
            }
        }
        configuredSurface.environment.merge(additionalAppOwnedEnvironment) {
            _, appValue in appValue
        }
        // WHY: Only the live app-owned endpoint may survive any environment merge layer.
        configuredSurface.environment["QUICKTTY_CONTROL_SOCKET"] = controlSocketPath
        if !includesAgentIdentityEnvironment {
            for key in Self.managedTaskExcludedEnvironmentKeys {
                configuredSurface.environment.removeValue(forKey: key)
            }
        }

        do {
            let surface = try ghosttyBridge.makeSurface(
                id: paneID,
                configuration: configuredSurface
            ) { [weak self] paneID, processAlive in
                self?.surfaceDidRequestClose(id: paneID, processAlive: processAlive)
            }
            // WHY: A creation callback may freeze reentrantly; the temporary surface is not accepted.
            guard !isPreparingForTermination else {
                closeCreatedSurface(id: paneID)
                throw CancellationError()
            }
            return surface
        } catch {
            if installedAgentCredentials {
                agentSessionController?.revoke(paneID: paneID)
            }
            throw error
        }
    }

    private static let managedTaskExcludedEnvironmentKeys: Set<String> = [
        "QUICKTTY_PANE_ID",
        "QUICKTTY_AGENT_SOCKET",
        "QUICKTTY_INSTANCE_ID",
        "QUICKTTY_PANE_TOKEN",
        "QUICKTTY_AGENT_HELPER",
        "QUICKTTY_CONTROL_SOCKET",
    ]

    private func closeCreatedSurface(id paneID: PaneID) {
        agentSessionController?.revoke(paneID: paneID)
        ghosttyBridge.closeSurface(id: paneID)
    }

    private func installSurfaceActivityHandlers() {
        guard !isPreparingForTermination else { return }
        activityCallbackGeneration += 1
        let generation = activityCallbackGeneration
        ghosttyBridge.surfaceProgressHandler = { [weak self] paneID, report in
            guard let self, generation == activityCallbackGeneration else { return }
            handleSurfaceProgress(report, for: paneID)
        }
        ghosttyBridge.surfaceCommandFinishedHandler = { [weak self] paneID, command in
            guard let self, generation == activityCallbackGeneration else { return }
            handleSurfaceCommandFinished(command, for: paneID)
        }
        ghosttyBridge.surfaceProcessExitedHandler = { [weak self] paneID, process in
            guard let self, !isPreparingForTermination,
                generation == activityCallbackGeneration
            else { return }
            observeManagedCompletion(process, paneID: paneID)
        }
    }

    private func handleSurfaceProgress(_ report: GhosttyProgressReport, for paneID: PaneID) {
        guard activityConfiguration.progressStyleEnabled,
            liveOwningTab(for: paneID) != nil
        else { return }
        let previousStatuses = terminalActivityController.statuses
        let effects = terminalActivityController.handleProgress(report, for: paneID)
        applyActivityEffects(effects)
        acknowledgeTerminalStatus(for: paneID)
        refreshWorkspaceStatusesIfChanged(from: previousStatuses)
    }

    private func handleSurfaceCommandFinished(
        _ command: GhosttyCommandFinished,
        for paneID: PaneID
    ) {
        // WHY: A command can finish while the managed shell remains alive and accepts input.
        guard activityConfiguration.progressStyleEnabled,
            liveOwningTab(for: paneID) != nil
        else { return }
        let previousStatuses = terminalActivityController.statuses
        let effects = terminalActivityController.handleCommandFinished(command, for: paneID)
        applyActivityEffects(effects)
        acknowledgeTerminalStatus(for: paneID)
        refreshWorkspaceStatusesIfChanged(from: previousStatuses)
    }

    private func applyActivityEffects(_ effects: [TerminalActivityEffect]) {
        for effect in effects {
            terminalActivityEffectHandler?(effect)
            terminalNotificationController?.handle(effect)
        }
    }

    private func handleScheduledActivityEffect(_ effect: TerminalActivityEffect) {
        guard case .cleared(let paneID) = effect,
            liveOwningTab(for: paneID) != nil
        else { return }
        cleanUpPaneLifecycle(paneID, statusChangedBeforeCleanup: true)
    }

    private func refreshWorkspaceStatusesIfChanged(
        from previousStatuses: [PaneID: TerminalActivityState]
    ) {
        guard previousStatuses != terminalActivityController.statuses else { return }
        refreshWorkspaceStatuses()
    }

    private func refreshWorkspaceStatuses() {
        guard !isPreparingForTermination else { return }
        #if DEBUG
            refreshWorkspaceStatusesInvocationCountForTestingStorage += 1
        #endif
        workspaceViewController.refreshStatuses(
            in: workspaceStore,
            paneStatuses: terminalActivityController.statuses
        )
    }

    private func acknowledgeTerminalStatus(for paneID: PaneID) {
        guard let ownership = liveOwnership(for: paneID) else { return }
        let selectedAndVisible =
            ownership.workspace.id == workspaceStore.activeWorkspaceID
            && ownership.workspace.activeTabID == ownership.tab.id
            && activeWindowIsKey
        terminalActivityController.acknowledge(
            paneID,
            selectedAndVisible: selectedAndVisible
        )
        if selectedAndVisible {
            terminalNotificationController?.invalidate(paneID: paneID)
        }
    }

    private func synchronizeTerminalAcknowledgements() {
        guard !isPreparingForTermination else { return }
        for paneID in terminalActivityController.statuses.keys {
            acknowledgeTerminalStatus(for: paneID)
        }
    }

    private var activeWindowIsKey: Bool {
        #if DEBUG
            if let activeWindowIsKeyOverrideForTesting {
                return activeWindowIsKeyOverrideForTesting
            }
        #endif
        return activeWindow?.isKeyWindow == true
    }

    private func clearTerminalActivity() {
        for paneID in Array(terminalActivityController.statuses.keys) {
            cleanUpPaneLifecycle(paneID)
        }
    }

    private func cleanUpPaneLifecycle(
        _ paneID: PaneID,
        statusChangedBeforeCleanup: Bool = false
    ) {
        let hadActivity = terminalActivityController.statuses[paneID] != nil
        terminalActivityController.removePane(paneID)
        terminalNotificationController?.invalidate(paneID: paneID)
        if hadActivity || statusChangedBeforeCleanup {
            refreshWorkspaceStatuses()
        }
    }

    private func surfaceTitleDidChange(id paneID: PaneID) {
        guard liveOwningTab(for: paneID) != nil else { return }
        refreshWorkspaceTitlePresentation()
    }

    private func surfaceTabTitleDidChange(id paneID: PaneID, title: String) {
        guard let tab = liveOwningTab(for: paneID) else { return }
        var candidate = workspaceStore
        guard (try? candidate.setTitleOverride(title, for: tab.id)) != nil else { return }
        _ = commitWorkspaceStore(candidate)
        refreshWorkspaceTitlePresentation()
    }

    private func surfaceDidRequestTabTitlePrompt(id paneID: PaneID) {
        guard !isPreparingForTermination else { return }
        guard let tab = liveOwningTab(for: paneID), tab.id == activeTab?.id else { return }
        workspaceViewController.presentTabTitlePrompt(for: tab.id)
    }

    private func surfaceWorkingDirectoryDidChange(
        id paneID: PaneID,
        workingDirectory: String
    ) {
        guard !workingDirectory.isEmpty, (workingDirectory as NSString).isAbsolutePath,
            surfaces[paneID] != nil
        else {
            return
        }

        var candidate = workspaceStore
        do {
            try candidate.updateWorkingDirectory(workingDirectory, for: paneID)
        } catch {
            return
        }
        _ = commitWorkspaceStore(candidate)
    }

    func createNewTab() {
        do {
            try createShellTab()
        } catch {
            onError(error)
        }
    }

    var terminalAutomationHost: any TerminalAutomationHost {
        terminalAutomationHostFacade
    }

    func handleTerminalAutomationRequest(
        _ authenticatedRequest: TerminalControlSocketRequest,
        context: TerminalControlRequestContext
    ) async -> TerminalControlResponse {
        guard !isTerminalControlFrozen, context.isActive, !Task.isCancelled else {
            return TerminalControlResponse(
                result: .failure(
                    try! TerminalControlError(
                        code: .cancelled, message: "Terminal control request cancelled")))
        }
        return await terminalAutomationCoordinator.handle(authenticatedRequest, context: context)
    }

    func resolveTerminalAutomationSession(
        instanceID: UUID,
        originPaneID: PaneID
    ) -> TerminalAutomationResolvedSession? {
        guard !isTerminalControlFrozen, let agentSessionController,
            agentSessionController.instanceID == instanceID,
            agentSessionController.environment(for: originPaneID) != nil,
            surfaces[originPaneID] != nil,
            let credentialGeneration = agentCredentialGenerationByPane[originPaneID]
        else {
            return nil
        }

        for workspace in workspaceStore.workspaces {
            guard let originTab = workspace.tabs.first(where: { $0.root.contains(originPaneID) }),
                let binding = originTab.paneDescriptor(for: originPaneID)?.agentResumeBinding,
                case .active = binding.restoreState,
                let activeTabID = workspace.activeTabID
            else {
                continue
            }
            return TerminalAutomationResolvedSession(
                identity: TerminalAutomationSessionIdentity(
                    instanceID: instanceID,
                    originPaneID: originPaneID,
                    adapterID: binding.adapterID,
                    sessionID: binding.sessionID,
                    paneCredentialGeneration: credentialGeneration
                ),
                workspace: TerminalAutomationWorkspaceContext(
                    workspaceID: workspace.id,
                    name: workspace.name,
                    originTabID: originTab.id,
                    activeTabID: activeTabID,
                    tabCount: workspace.tabs.count,
                    paneCount: workspace.tabs.reduce(0) { $0 + $1.root.leaves.count },
                    tabIDs: Set(workspace.tabs.map(\.id)),
                    paneIDs: Set(workspace.tabs.flatMap(\.root.leaves))
                )
            )
        }
        return nil
    }

    func createManagedTab(
        in workspaceID: WorkspaceID,
        launchConfiguration: TerminalTaskLaunchConfiguration,
        workingDirectory: String,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        guard resolvedTerminalAutomationSession(expectedSession, in: workspaceID) != nil else {
            return .failure(.staleSession)
        }

        guard canCreateManagedTask(for: expectedSession) else { return .failure(.resourceLimit) }
        let paneID = PaneID()
        let tabID = TabID()
        let taskID = managedTaskIDProvider()
        var configuration = surfaceConfiguration
        configuration.workingDirectory = workingDirectory
        configuration.command = launchConfiguration.command
        configuration.initialInput = nil
        configuration.waitAfterCommand = true
        configuration.managedHelperPath = launchConfiguration.helperPath
        configuration.context = .newTab

        let surface: GhosttySurfaceView
        do {
            surface = try makeConfiguredSurface(
                id: paneID,
                configuration: configuration,
                additionalAppOwnedEnvironment: launchConfiguration.environment,
                includesAgentIdentityEnvironment: false
            )
        } catch {
            agentSessionController?.revoke(paneID: paneID)
            return .failure(.surfaceCreationFailed)
        }

        var candidate = workspaceStore
        do {
            #if DEBUG
                if failsNextManagedTabMutationForTesting {
                    failsNextManagedTabMutationForTesting = false
                    throw WorkspaceError.workspaceNotFound(workspaceID)
                }
            #endif
            let descriptor = TerminalPaneDescriptor(id: paneID, cwd: workingDirectory)
            let tab = TerminalTab(id: tabID, title: "Shell", pane: descriptor)
            try candidate.addTab(tab, to: workspaceID)
            if focus {
                try candidate.activateWorkspace(workspaceID)
                try candidate.activateTab(tabID, in: workspaceID)
            }
        } catch {
            closeCreatedSurface(id: paneID)
            return .failure(.modelMutationFailed)
        }

        let task = TerminalControlTask(
            taskID: taskID,
            paneID: paneID.rawValue,
            tabID: tabID.rawValue,
            workspaceID: workspaceID.rawValue,
            state: .running,
            owner: .agent,
            policy: policy,
            revision: 1,
            exitCode: nil
        )
        guard
            registerManagedTask(
                task,
                session: expectedSession,
                splitID: nil,
                surface: surface,
                previousFocus: focus
                    ? managedTaskFocusContext(in: workspaceID, candidate: candidate) : nil
            )
        else {
            closeCreatedSurface(id: paneID)
            return .failure(.modelMutationFailed)
        }
        surfaces[paneID] = surface

        #if DEBUG
            if failsNextManagedCommitForTesting {
                failsNextManagedCommitForTesting = false
                rollbackManagedCreation(taskID: taskID, paneID: paneID)
                return .failure(.modelMutationFailed)
            }
        #endif
        guard resolvedTerminalAutomationSession(expectedSession, in: workspaceID) != nil else {
            rollbackManagedCreation(taskID: taskID, paneID: paneID)
            return .failure(.staleSession)
        }
        guard commitWorkspaceStore(candidate) else {
            rollbackManagedCreation(taskID: taskID, paneID: paneID)
            return .failure(.modelMutationFailed)
        }

        installSurfaceActivityHandlers()
        refreshWorkspacePresentation(focusTerminal: focus)
        trimManagedTasks(for: expectedSession)
        return .createdTask(
            TerminalAutomationCreatedTaskResponse(task: task, splitID: nil)
        )
    }

    func splitManagedPane(
        anchorPaneID: PaneID,
        in workspaceID: WorkspaceID,
        placement: SplitPlacement,
        ratio: Double,
        launchConfiguration: TerminalTaskLaunchConfiguration,
        workingDirectory: String,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        guard resolvedTerminalAutomationSession(expectedSession, in: workspaceID) != nil else {
            return .failure(.staleSession)
        }
        guard let anchorOwnership = ownership(for: anchorPaneID),
            anchorOwnership.workspace.id == workspaceID,
            anchorIsValid(anchorPaneID, for: expectedSession)
        else {
            return .failure(.targetNotOwned)
        }

        guard canCreateManagedTask(for: expectedSession) else { return .failure(.resourceLimit) }
        let paneID = PaneID()
        let taskID = managedTaskIDProvider()
        let previousActivePaneID = anchorOwnership.tab.activePaneID
        var configuration = surfaceConfiguration
        configuration.workingDirectory = workingDirectory
        configuration.command = launchConfiguration.command
        configuration.initialInput = nil
        configuration.waitAfterCommand = true
        configuration.managedHelperPath = launchConfiguration.helperPath
        configuration.context = .split

        let surface: GhosttySurfaceView
        do {
            surface = try makeConfiguredSurface(
                id: paneID,
                configuration: configuration,
                additionalAppOwnedEnvironment: launchConfiguration.environment,
                includesAgentIdentityEnvironment: false
            )
        } catch {
            agentSessionController?.revoke(paneID: paneID)
            return .failure(.surfaceCreationFailed)
        }

        var candidate = workspaceStore
        let splitID: UUID
        do {
            #if DEBUG
                if failsNextManagedSplitMutationForTesting {
                    failsNextManagedSplitMutationForTesting = false
                    throw SplitCoordinatorError.paneNotFound(anchorPaneID)
                }
            #endif
            let delta = try splitCoordinator.apply(
                .split(
                    workspaceID: workspaceID,
                    tabID: anchorOwnership.tab.id,
                    paneID: anchorPaneID,
                    axis: placement.axis,
                    insertionSide: placement.insertionSide,
                    newPane: TerminalPaneDescriptor(id: paneID, cwd: workingDirectory),
                    ratio: ratio
                ),
                to: &candidate
            )
            guard case .paneSplit(_, _, let createdSplitID, _, _, _, _, _, _, _) = delta else {
                closeCreatedSurface(id: paneID)
                return .failure(.modelMutationFailed)
            }
            splitID = createdSplitID
            if focus {
                try candidate.activateWorkspace(workspaceID)
                try candidate.activateTab(anchorOwnership.tab.id, in: workspaceID)
            } else {
                _ = try splitCoordinator.apply(
                    .activatePane(
                        workspaceID: workspaceID,
                        tabID: anchorOwnership.tab.id,
                        paneID: previousActivePaneID
                    ),
                    to: &candidate
                )
            }
        } catch {
            closeCreatedSurface(id: paneID)
            return .failure(.modelMutationFailed)
        }

        let task = TerminalControlTask(
            taskID: taskID,
            paneID: paneID.rawValue,
            tabID: anchorOwnership.tab.id.rawValue,
            workspaceID: workspaceID.rawValue,
            state: .running,
            owner: .agent,
            policy: policy,
            revision: 1,
            exitCode: nil
        )
        guard
            registerManagedTask(
                task,
                session: expectedSession,
                splitID: splitID,
                surface: surface,
                previousFocus: focus
                    ? managedTaskFocusContext(
                        in: workspaceID,
                        splitTabID: anchorOwnership.tab.id,
                        candidate: candidate
                    ) : nil
            )
        else {
            closeCreatedSurface(id: paneID)
            return .failure(.modelMutationFailed)
        }
        surfaces[paneID] = surface

        #if DEBUG
            if failsNextManagedCommitForTesting {
                failsNextManagedCommitForTesting = false
                rollbackManagedCreation(taskID: taskID, paneID: paneID)
                return .failure(.modelMutationFailed)
            }
        #endif
        guard resolvedTerminalAutomationSession(expectedSession, in: workspaceID) != nil,
            anchorIsValid(anchorPaneID, for: expectedSession)
        else {
            rollbackManagedCreation(taskID: taskID, paneID: paneID)
            return .failure(.staleSession)
        }
        guard commitWorkspaceStore(candidate) else {
            rollbackManagedCreation(taskID: taskID, paneID: paneID)
            return .failure(.modelMutationFailed)
        }

        installSurfaceActivityHandlers()
        refreshWorkspacePresentation(focusTerminal: focus)
        trimManagedTasks(for: expectedSession)
        return .createdTask(
            TerminalAutomationCreatedTaskResponse(task: task, splitID: splitID)
        )
    }

    func presentTerminalAutomationPermission(
        for session: TerminalAutomationResolvedSession
    ) async -> TerminalAutomationPermissionDecision {
        guard !isPreparingForTermination,
            resolvedTerminalAutomationSession(session.identity, in: session.workspace.workspaceID)
                != nil,
            let window = activeWindow
        else { return .unavailable }
        let decision = await terminalControlPermissionController.present(
            for: session, on: window, using: terminalAutomationPermissionPresenter,
            isCurrent: { [weak self, weak window] in
                guard let self, let window, !isPreparingForTermination,
                    activeWindow === window,
                    presentationMode != .quake
                        || quakeWindowController.requestedVisibility == .shown
                else { return false }
                return resolvedTerminalAutomationSession(
                    session.identity, in: session.workspace.workspaceID) != nil
            })
        guard !Task.isCancelled, !isPreparingForTermination, activeWindow === window,
            window.isVisible, !window.isMiniaturized,
            presentationMode != .quake || quakeWindowController.requestedVisibility == .shown,
            resolvedTerminalAutomationSession(session.identity, in: session.workspace.workspaceID)
                != nil
        else { return .unavailable }
        return decision
    }

    func prepareTerminalTaskLaunchConfiguration(
        for launch: TerminalControlLaunch
    ) throws -> TerminalTaskLaunchConfiguration {
        guard let helperPath = agentSessionController?.bundledHelperPath else {
            throw AgentLaunchConfigurationError.invalidHelperPath
        }
        return try TerminalTaskLaunchConfiguration(
            launch: launch,
            bundledHelperPath: helperPath,
            executableSearchPath: executableSearchPath
        )
    }

    private func resolvedTerminalAutomationSession(
        _ expectedSession: TerminalAutomationSessionIdentity,
        in workspaceID: WorkspaceID
    ) -> TerminalAutomationResolvedSession? {
        guard
            let resolved = resolveTerminalAutomationSession(
                instanceID: expectedSession.instanceID,
                originPaneID: expectedSession.originPaneID
            ), resolved.identity == expectedSession,
            resolved.workspace.workspaceID == workspaceID
        else {
            return nil
        }
        return resolved
    }

    private func ownership(for paneID: PaneID) -> (workspace: Workspace, tab: TerminalTab)? {
        for workspace in workspaceStore.workspaces {
            if let tab = workspace.tabs.first(where: { $0.root.contains(paneID) }) {
                return (workspace, tab)
            }
        }
        return nil
    }

    private func anchorIsValid(
        _ paneID: PaneID,
        for session: TerminalAutomationSessionIdentity
    ) -> Bool {
        if paneID == session.originPaneID {
            return true
        }
        guard let taskID = managedTaskIDByPane[paneID],
            let record = managedTasks[taskID]
        else {
            return false
        }
        return record.session == session && !record.isRevoked && isCurrentManagedSurface(record)
    }

    private func managedTaskFocusContext(
        in workspaceID: WorkspaceID,
        splitTabID: TabID? = nil,
        candidate: WorkspaceStore
    ) -> ManagedTaskFocusContext {
        // WHY: Claim only this commit's epoch before persistence/presentation can reenter selection.
        ManagedTaskFocusContext(
            selectionGeneration: selectionGeneration(after: candidate),
            activeWorkspaceID: workspaceStore.activeWorkspaceID,
            targetActiveTabID: workspaceStore.workspace(id: workspaceID)?.activeTabID,
            targetActivePaneID: splitTabID.flatMap { workspaceStore.tab(id: $0)?.activePaneID }
        )
    }

    private func registerManagedTask(
        _ task: TerminalControlTask,
        session: TerminalAutomationSessionIdentity,
        splitID: UUID?,
        surface: GhosttySurfaceView,
        previousFocus: ManagedTaskFocusContext?
    ) -> Bool {
        let paneID = PaneID(rawValue: task.paneID)
        guard managedTasks[task.taskID] == nil,
            discardedManagedTasks[task.taskID] == nil,
            managedTaskIDByPane[paneID] == nil
        else {
            return false
        }
        managedTasks[task.taskID] = ManagedTerminalTaskRecord(
            task: task,
            session: session,
            splitID: splitID,
            previousFocus: previousFocus,
            createdTask: task,
            surfaceIdentity: ObjectIdentifier(surface),
            isAccepted: !terminalAutomationCoordinator.hasPendingHostCreation(for: session)
        )
        managedTaskOrder.append(task.taskID)
        managedTaskIDByPane[paneID] = task.taskID
        return true
    }

    private func rollbackManagedCreation(taskID: UUID, paneID: PaneID) {
        managedTaskOrder.removeAll { $0 == taskID }
        managedTasks.removeValue(forKey: taskID)?.completionTask?.cancel()
        managedTaskIDByPane.removeValue(forKey: paneID)
        surfaces.removeValue(forKey: paneID)
        closeCreatedSurface(id: paneID)
    }

    func discardManagedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> Bool {
        let task = created.task
        if let discarded = discardedManagedTasks[task.taskID] {
            guard discarded.created == created, discarded.session == expectedSession else {
                return false
            }
            discardedManagedTasks[task.taskID]?.compensationCompleted = true
            return true
        }

        let paneID = PaneID(rawValue: task.paneID)
        guard let record = managedTasks[task.taskID],
            record.createdTask == task,
            record.session == expectedSession,
            record.splitID == created.splitID,
            managedTaskIDByPane[paneID] == nil
                || managedTaskIDByPane[paneID] == task.taskID
        else {
            return false
        }

        if let surface = surfaces[paneID], ObjectIdentifier(surface) != record.surfaceIdentity {
            return false
        }
        // WHY: Exact pending-creation compensation must still release its runtime after freeze,
        // but may neither edit the frozen model nor discard an accepted user-visible task.
        guard !isPreparingForTermination || !record.isAccepted else { return false }
        var shouldFocus = false
        if !isPreparingForTermination, let ownership = ownership(for: paneID) {
            let workspaceID = ownership.workspace.id
            let tabID = ownership.tab.id
            shouldFocus =
                workspaceStore.activeWorkspaceID == workspaceID
                && ownership.workspace.activeTabID == tabID
                && ownership.tab.activePaneID == paneID
            var candidate = workspaceStore
            let delta: SplitDelta
            do {
                delta = try splitCoordinator.apply(
                    .closePane(workspaceID: workspaceID, tabID: tabID, paneID: paneID),
                    to: &candidate
                )
            } catch {
                return false
            }
            switch delta {
            case .tabClosed, .paneClosed:
                break
            case .paneSplit, .ratioUpdated, .splitsEqualized, .focusChanged:
                return false
            }
            restoreManagedTaskFocus(record, ownership: ownership, in: &candidate)
            guard commitWorkspaceStore(candidate) else { return false }
        }

        if let current = managedTasks[task.taskID],
            current.processGeneration != record.processGeneration
        {
            return false
        }
        if let surface = surfaces[paneID], ObjectIdentifier(surface) != record.surfaceIdentity {
            return false
        }
        // WHY: Persistence above may freeze too; only unaccepted creation has this exception.
        guard !isPreparingForTermination || !record.isAccepted else { return false }
        // WHY: The task record is the authority after creation; tabs can move before rollback.
        guard
            removeManagedTaskRuntime(
                taskID: task.taskID, paneID: paneID,
                allowDuringTermination: !record.isAccepted
            )
        else { return false }
        discardedManagedTasks[task.taskID] = DiscardedManagedTaskRecord(
            created: created,
            session: expectedSession,
            compensationCompleted: true
        )
        if case .started = startupState {
            refreshWorkspacePresentation(focusTerminal: shouldFocus)
        }
        return true
    }

    private func restoreManagedTaskFocus(
        _ record: ManagedTerminalTaskRecord,
        ownership: (workspace: Workspace, tab: TerminalTab),
        in candidate: inout WorkspaceStore
    ) {
        guard let previous = record.previousFocus,
            previous.selectionGeneration == selectionGeneration,
            ownership.tab.id.rawValue == record.task.tabID,
            ownership.tab.activePaneID.rawValue == record.task.paneID
        else { return }

        // WHY: Equality of IDs alone cannot distinguish creation focus from a later user return.
        if let paneID = previous.targetActivePaneID,
            candidate.tab(id: ownership.tab.id)?.root.contains(paneID) == true
        {
            _ = try? splitCoordinator.apply(
                .activatePane(
                    workspaceID: ownership.workspace.id,
                    tabID: ownership.tab.id,
                    paneID: paneID
                ),
                to: &candidate
            )
        }

        // WHY: Moving a tab or selecting another target transfers workspace/tab focus ownership.
        guard ownership.workspace.id.rawValue == record.task.workspaceID,
            ownership.workspace.activeTabID == ownership.tab.id
        else { return }
        if let tabID = previous.targetActiveTabID, tabID != ownership.tab.id,
            candidate.workspace(id: ownership.workspace.id)?.tabs.contains(where: {
                $0.id == tabID
            }) == true
        {
            try? candidate.activateTab(tabID, in: ownership.workspace.id)
        }
        if workspaceStore.activeWorkspaceID == ownership.workspace.id,
            previous.activeWorkspaceID != ownership.workspace.id,
            candidate.workspace(id: previous.activeWorkspaceID) != nil
        {
            // WHY: Other workspaces' local selections were never changed by creation.
            try? candidate.activateWorkspace(previous.activeWorkspaceID)
        }
    }

    private func removeManagedTaskRuntime(
        taskID: UUID, paneID: PaneID, allowDuringTermination: Bool
    ) -> Bool {
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        if surfaces[paneID] != nil {
            // WHY: Only the exact unaccepted creation checked by discardManagedTask may
            // compensate while frozen; ordinary removal must stop at callback boundaries.
            guard
                removeSurface(
                    id: paneID, closeBridgeSurface: true,
                    allowDuringTermination: allowDuringTermination
                )
            else { return false }
        } else {
            if let attempt = agentResumeAttempts.removeValue(forKey: paneID) {
                agentResumeRuntime.surfaceDidClose(attempt.reference)
            }
            agentResumePresentations.removeValue(forKey: paneID)
            agentSessionController?.revoke(paneID: paneID)
            cleanUpPaneLifecycle(paneID)
            guard !isPreparingForTermination || allowDuringTermination else { return false }
            confirmationQueue.invalidatePane(paneID)
            guard !isPreparingForTermination || allowDuringTermination else { return false }
            ghosttyBridge.closeSurface(id: paneID)
        }
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        managedTasks.removeValue(forKey: taskID)?.completionTask?.cancel()
        managedTaskOrder.removeAll { $0 == taskID }
        if managedTaskIDByPane[paneID] == taskID {
            managedTaskIDByPane.removeValue(forKey: paneID)
        }
        agentCredentialGenerationByPane.removeValue(forKey: paneID)
        surfaceFailures.removeValue(forKey: paneID)
        return true
    }

    func inspectManagedTask(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationTaskInspection {
        guard let record = managedTasks[taskID] else { return .notFound }
        guard record.session == expectedSession, !record.isRevoked else { return .notOwned }
        guard
            resolvedTerminalAutomationSession(
                expectedSession, in: WorkspaceID(rawValue: record.task.workspaceID)) != nil
        else {
            return .notOwned
        }
        let paneID = PaneID(rawValue: record.task.paneID)
        if record.surfaceIdentity == nil, record.task.owner == .finished {
            return .owned(record.task)
        }
        guard let surface = surfaces[paneID], ObjectIdentifier(surface) == record.surfaceIdentity,
            let ownership = ownership(for: paneID),
            ownership.workspace.id.rawValue == record.task.workspaceID,
            ownership.tab.id.rawValue == record.task.tabID
        else {
            return .notFound
        }
        return .owned(record.task)
    }

    private func isCurrentManagedSurface(_ record: ManagedTerminalTaskRecord) -> Bool {
        let paneID = PaneID(rawValue: record.task.paneID)
        guard let surface = surfaces[paneID], surface.isReady,
            ObjectIdentifier(surface) == record.surfaceIdentity,
            managedTaskIDByPane[paneID] == record.task.taskID,
            let location = ownership(for: paneID)
        else { return false }
        return location.workspace.id.rawValue == record.task.workspaceID
            && location.tab.id.rawValue == record.task.tabID
    }

    private func managedAccessError(
        taskID: UUID, session: TerminalAutomationSessionIdentity
    ) -> TerminalControlErrorCode? {
        guard
            let resolved = resolveTerminalAutomationSession(
                instanceID: session.instanceID, originPaneID: session.originPaneID
            ), resolved.identity == session
        else { return .staleSession }
        guard let record = managedTasks[taskID] else { return .targetNotFound }
        guard record.session == session, !record.isRevoked,
            record.task.workspaceID == resolved.workspace.workspaceID.rawValue
        else { return .targetNotOwned }
        if record.surfaceIdentity == nil, record.task.owner == .finished { return nil }
        return isCurrentManagedSurface(record) ? nil : .targetNotFound
    }

    private func refreshManagedSnapshot(
        taskID: UUID, capturesDeferredCompletion: Bool = false
    ) -> Bool {
        guard !isTerminalControlFrozen, !isPreparingForTermination,
            let initial = managedTasks[taskID], !initial.isRevoked
        else { return false }
        switch initial.snapshotState {
        case .finalCaptured, .closedFallback:
            return true
        case .pendingFinal where !capturesDeferredCompletion, .readingFinal:
            // WHY: Interim reads must neither steal the later-turn capture nor fail a waiting client.
            return true
        case .revoked:
            return false
        case .running, .runningReadFailed, .pendingFinal, .finalReadFailed:
            break
        }
        guard isCurrentManagedSurface(initial) else { return false }
        let now = terminalAutomationNow()
        if let previous = initial.lastRefresh, now - previous < 0.25 {
            return initial.snapshotState == .running
        }
        if initial.completionObserved {
            // WHY: A retry after timeout may see more text without EOF; that is still not final.
            let outputState = ghosttyBridge.outputState(id: PaneID(rawValue: initial.task.paneID))
            guard !isTerminalControlFrozen, !isPreparingForTermination,
                let current = managedTasks[taskID], !current.isRevoked,
                current.processGeneration == initial.processGeneration,
                current.surfaceIdentity == initial.surfaceIdentity,
                current.session == initial.session, current.task == initial.task,
                current.isAccepted == initial.isAccepted,
                current.snapshotState == initial.snapshotState,
                isCurrentManagedSurface(current)
            else { return false }
            guard outputState == .complete else { return false }
        }
        // WHY: Only the deferred path can start the first final attempt; explicit reads can retry it.
        let attemptState: ManagedSnapshotState =
            initial.completionObserved ? .readingFinal : .runningReadFailed
        // WHY: Reserve the read window before crossing an injectable bridge boundary.
        managedTasks[taskID]?.lastRefresh = now
        managedTasks[taskID]?.snapshotState = attemptState
        defer {
            // WHY: Reentrant invalidation must not strand a same-generation final read in progress.
            if let current = managedTasks[taskID], !current.isRevoked,
                current.processGeneration == initial.processGeneration,
                current.surfaceIdentity == initial.surfaceIdentity,
                current.snapshotState == .readingFinal
            {
                managedTasks[taskID]?.snapshotState = .finalReadFailed
            }
        }
        let output: GhosttyRenderedText
        do {
            output = try ghosttyBridge.readRenderedText(
                id: PaneID(rawValue: initial.task.paneID),
                maximumUTF8Bytes: TerminalControlProtocol.maximumSnapshotSize
            )
        } catch {
            if let current = managedTasks[taskID], !current.isRevoked,
                current.processGeneration == initial.processGeneration,
                current.surfaceIdentity == initial.surfaceIdentity,
                current.snapshotState == .readingFinal
            {
                managedTasks[taskID]?.snapshotState = .finalReadFailed
            }
            return false
        }
        guard !isTerminalControlFrozen, !isPreparingForTermination,
            var current = managedTasks[taskID], !current.isRevoked,
            current.processGeneration == initial.processGeneration,
            current.session == initial.session, current.isAccepted == initial.isAccepted,
            current.task == initial.task, isCurrentManagedSurface(current),
            current.surfaceIdentity == initial.surfaceIdentity,
            current.snapshotState == attemptState,
            current.completionObserved == initial.completionObserved,
            current.completionExitCode == initial.completionExitCode
        else { return false }
        current.update(rendered: output)
        current.snapshotState = current.completionObserved ? .finalCaptured : .running
        managedTasks[taskID] = current
        return true
    }

    func readManagedTask(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationHostResponse {
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard refreshManagedSnapshot(taskID: taskID) else {
            return .failure(
                managedAccessError(taskID: taskID, session: expectedSession) ?? .internalFailure)
        }
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard let record = managedTasks[taskID],
            let snapshot = try? TerminalControlSnapshot(
                task: record.task, text: record.rendered.text,
                isTruncated: record.rendered.isTruncated
            )
        else { return .failure(.internalFailure) }
        // WHY: Delegate closure only after retaining output, outside any bridge/close reentrancy.
        scheduleManagedSuccessfulClosure(taskID: taskID)
        return .snapshot(snapshot)
    }

    private func canAutomaticallyCloseManagedTask(_ record: ManagedTerminalTaskRecord) -> Bool {
        !record.isRevoked && record.isAccepted && record.completionObserved
            && record.snapshotState == .finalCaptured && record.task.state == .succeeded
            && record.task.owner == .finished && record.task.policy == .closeOnSuccess
            && !isPreparingForTermination && !isTerminalControlFrozen
            && managedAccessError(taskID: record.task.taskID, session: record.session) == nil
            && !closingPaneIDs.contains(PaneID(rawValue: record.task.paneID))
            && isCurrentManagedSurface(record)
    }

    private func scheduleManagedSuccessfulClosure(taskID: UUID) {
        guard let record = managedTasks[taskID], record.completionTask == nil,
            canAutomaticallyCloseManagedTask(record)
        else { return }
        let generation = record.processGeneration
        let surfaceIdentity = record.surfaceIdentity
        managedTasks[taskID]?.completionTask = Task { @MainActor [weak self] in
            // WHY: Reads and creation acceptance must not close inside an outer model mutation.
            await Task.yield()
            guard let self, !Task.isCancelled, let current = managedTasks[taskID],
                current.processGeneration == generation, current.surfaceIdentity == surfaceIdentity,
                current.session == record.session, !current.isRevoked
            else { return }
            managedTasks[taskID]?.completionTask = nil
            guard canAutomaticallyCloseManagedTask(current) else { return }
            finishSurfaceClosure(
                id: PaneID(rawValue: current.task.paneID), closeBridgeSurface: true)
        }
    }

    func sendManagedInput(
        taskID: UUID, expectedRevision: UInt64,
        text: String? = nil, key: TerminalControlKey? = nil,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationHostResponse {
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard let initial = managedTasks[taskID] else { return .failure(.targetNotFound) }
        guard !isPreparingForTermination,
            !closingPaneIDs.contains(PaneID(rawValue: initial.task.paneID))
        else {
            return .failure(.cancelled)
        }
        guard !initial.completionObserved,
            initial.task.state == .running || initial.task.state == .waitingForUser
        else { return .failure(.processFinished) }
        guard initial.task.owner == .agent, initial.task.state == .running else {
            return .failure(.userControlsPane)
        }
        guard refreshManagedSnapshot(taskID: taskID) else {
            return .failure(
                managedAccessError(taskID: taskID, session: expectedSession) ?? .internalFailure)
        }
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let current = managedTasks[taskID],
            current.processGeneration == initial.processGeneration,
            current.surfaceIdentity == initial.surfaceIdentity, isCurrentManagedSurface(current)
        else { return .failure(.targetNotOwned) }
        guard current.task.revision == expectedRevision else {
            return .failure(.staleTerminalRevision)
        }
        guard !current.completionObserved,
            current.task.state == .running || current.task.state == .waitingForUser
        else { return .failure(.processFinished) }
        guard current.task.owner == .agent, current.task.state == .running else {
            return .failure(.userControlsPane)
        }
        // WHY: No suspension is allowed between exact capability validation and bridge delivery.
        do {
            let paneID = PaneID(rawValue: current.task.paneID)
            if let text {
                try ghosttyBridge.sendAutomationText(id: paneID, text: text)
            } else if let key, let bridgeKey = GhosttyAutomationKey(rawValue: key.rawValue) {
                try ghosttyBridge.sendAutomationKey(id: paneID, key: bridgeKey)
            } else {
                return .failure(.invalidRequest)
            }
        } catch { return .failure(.internalFailure) }
        return .acknowledged(taskID: taskID, revision: current.task.revision)
    }

    private func liveManagedTask(taskID: UUID) -> ManagedTerminalTaskRecord? {
        guard !isPreparingForTermination, let record = managedTasks[taskID], !record.isRevoked,
            !record.completionObserved,
            record.task.state == .running || record.task.state == .waitingForUser,
            record.task.owner == .agent || record.task.owner == .user,
            !closingPaneIDs.contains(PaneID(rawValue: record.task.paneID)),
            managedAccessError(taskID: taskID, session: record.session) == nil
        else { return nil }
        return record
    }

    private func liveGrantedManagedTask(taskID: UUID) -> ManagedTerminalTaskRecord? {
        guard let record = liveManagedTask(taskID: taskID),
            terminalAutomationCoordinator.currentGrantedTask(
                taskID: taskID, session: record.session)
                == record.task
        else { return nil }
        return record
    }

    private func takeManualControl(of paneID: PaneID) {
        guard let taskID = managedTaskIDByPane[paneID],
            var record = liveManagedTask(taskID: taskID), record.task.owner == .agent
        else { return }
        // WHY: The bridge calls this synchronously before delivery, including each broadcast target.
        // No input bytes or synthetic terminal text cross this boundary.
        record.update(owner: .user)
        managedTasks[taskID] = record
        scheduleManagedPresentationRefresh()
    }

    @discardableResult
    func returnControlToAgent(taskID: UUID) -> Bool {
        guard var record = liveGrantedManagedTask(taskID: taskID), record.task.owner == .user else {
            return false
        }
        record.update(state: .running, owner: .agent)
        managedTasks[taskID] = record
        scheduleManagedPresentationRefresh()
        return true
    }

    func requestManagedUserInput(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationHostResponse {
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard !Task.isCancelled, !isPreparingForTermination else { return .failure(.cancelled) }
        guard let initial = managedTasks[taskID], !initial.completionObserved,
            initial.task.state == .running || initial.task.state == .waitingForUser
        else { return .failure(.processFinished) }
        let focused = focusManagedTask(taskID: taskID, expectedSession: expectedSession)
        guard case .task(let focusedTask) = focused else { return focused }
        guard var record = liveGrantedManagedTask(taskID: taskID),
            record.session == expectedSession, record.task == focusedTask
        else { return .failure(.targetNotOwned) }
        // WHY: Password prompts may never change rendered text; ownership itself invalidates input.
        record.update(state: .waitingForUser, owner: .user)
        managedTasks[taskID] = record
        scheduleManagedPresentationRefresh()
        return .task(record.task)
    }

    func focusManagedTask(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationHostResponse {
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard !Task.isCancelled, !isPreparingForTermination else { return .failure(.cancelled) }
        guard let record = managedTasks[taskID], !record.completionObserved,
            record.task.state == .running || record.task.state == .waitingForUser
        else { return .failure(.processFinished) }
        guard let initial = liveGrantedManagedTask(taskID: taskID),
            initial.session == expectedSession
        else { return .failure(.targetNotOwned) }
        guard let window = activeWindow else { return .failure(.modelMutationFailed) }
        let mode = presentationMode
        let paneID = PaneID(rawValue: initial.task.paneID)
        let workspaceID = WorkspaceID(rawValue: initial.task.workspaceID)
        let tabID = TabID(rawValue: initial.task.tabID)
        guard let surface = surfaces[paneID] else { return .failure(.targetNotFound) }

        func validationError() -> TerminalControlErrorCode? {
            guard !Task.isCancelled, !isPreparingForTermination else { return .cancelled }
            if let error = managedAccessError(taskID: taskID, session: expectedSession) {
                return error
            }
            guard let record = managedTasks[taskID], !record.completionObserved,
                record.task.state == .running || record.task.state == .waitingForUser
            else { return .processFinished }
            guard let current = liveGrantedManagedTask(taskID: taskID),
                current.session == expectedSession,
                current.processGeneration == initial.processGeneration,
                current.surfaceIdentity == initial.surfaceIdentity
            else { return .targetNotOwned }
            guard current.task == initial.task else { return .staleTerminalRevision }
            guard activeWindow === window, presentationMode == mode,
                window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
                window.sheetParent == nil,
                mode != .quake || quakeWindowController.requestedVisibility == .shown
            else { return .modelMutationFailed }
            return nil
        }

        // WHY: A busy parent must fail before any selection, ownership or presentation changes.
        if let error = validationError() { return .failure(error) }
        let previous = workspaceStore
        var candidate = previous
        do {
            try candidate.activateWorkspace(workspaceID)
            try candidate.activateTab(tabID, in: workspaceID)
            _ = try splitCoordinator.apply(
                .activatePane(workspaceID: workspaceID, tabID: tabID, paneID: paneID),
                to: &candidate)
            #if DEBUG
                if candidate != previous, failsNextManagedCommitForTesting {
                    failsNextManagedCommitForTesting = false
                    return .failure(.modelMutationFailed)
                }
            #endif
            try presentationController.showCurrentPresentation()
        } catch { return .failure(.modelMutationFailed) }
        if let error = validationError() { return .failure(error) }
        // WHY: Showing or persisting can reenter; never overwrite a later model/selection change.
        guard workspaceStore == previous else { return .failure(.modelMutationFailed) }
        if candidate != previous, !commitWorkspaceStore(candidate) {
            return .failure(.modelMutationFailed)
        }
        if let error = validationError() { return .failure(error) }
        guard workspaceStore == candidate else { return .failure(.modelMutationFailed) }
        // WHY: Automation cannot report success on the UI helper's deferred, unchecked focus path.
        refreshWorkspacePresentation(focusTerminal: false)
        if let error = validationError() { return .failure(error) }
        guard workspaceStore == candidate, surface.window === window else {
            return .failure(.modelMutationFailed)
        }
        let didFocus = window.makeFirstResponder(surface)
        if let error = validationError() { return .failure(error) }
        guard didFocus, window.firstResponder === surface, surface.window === window,
            workspaceStore == candidate
        else { return .failure(.modelMutationFailed) }
        return .task(initial.task)
    }

    func resizeManagedTask(
        taskID: UUID, ratio: Double, expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationHostResponse {
        guard ratio.isFinite,
            (TerminalControlProtocol.minimumRatio...TerminalControlProtocol.maximumRatio)
                .contains(ratio)
        else { return .failure(.invalidRequest) }
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard !Task.isCancelled, !isPreparingForTermination else { return .failure(.cancelled) }
        guard let record = managedTasks[taskID], !record.completionObserved,
            record.task.state == .running || record.task.state == .waitingForUser
        else { return .failure(.processFinished) }
        guard let initial = liveGrantedManagedTask(taskID: taskID),
            initial.session == expectedSession
        else { return .failure(.targetNotOwned) }
        guard let splitID = initial.splitID else { return .failure(.invalidRequest) }
        let paneID = PaneID(rawValue: initial.task.paneID)
        let workspaceID = WorkspaceID(rawValue: initial.task.workspaceID)
        let tabID = TabID(rawValue: initial.task.tabID)

        func firstChildRatio(in node: SplitNode) -> Double? {
            guard case .split(let id, _, _, let first, let second) = node else { return nil }
            if id == splitID {
                // WHY: A share belongs to the live adjacent leaf, not its former direction or subtree.
                if first == .pane(paneID) { return ratio }
                if second == .pane(paneID) { return 1 - ratio }
                return nil
            }
            return firstChildRatio(in: first) ?? firstChildRatio(in: second)
        }

        func validationError() -> TerminalControlErrorCode? {
            guard !Task.isCancelled, !isPreparingForTermination else { return .cancelled }
            if let error = managedAccessError(taskID: taskID, session: expectedSession) {
                return error
            }
            guard let record = managedTasks[taskID], !record.completionObserved,
                record.task.state == .running || record.task.state == .waitingForUser
            else { return .processFinished }
            guard let current = liveGrantedManagedTask(taskID: taskID),
                current.session == expectedSession,
                current.processGeneration == initial.processGeneration,
                current.surfaceIdentity == initial.surfaceIdentity
            else { return .targetNotOwned }
            return nil
        }

        let previous = workspaceStore
        guard let tab = previous.workspace(id: workspaceID)?.tabs.first(where: { $0.id == tabID }),
            let storedRatio = firstChildRatio(in: tab.root)
        else { return .failure(.invalidRequest) }
        var candidate = previous
        do {
            _ = try splitCoordinator.apply(
                .updateRatio(
                    workspaceID: workspaceID, tabID: tabID, splitID: splitID, ratio: storedRatio),
                to: &candidate)
        } catch { return .failure(.modelMutationFailed) }
        if let error = validationError() { return .failure(error) }
        guard workspaceStore == previous else { return .failure(.modelMutationFailed) }
        // WHY: Quantized equality must not persist, rebuild presentation or consume a commit failure.
        guard candidate != previous else { return .task(initial.task) }
        #if DEBUG
            if failsNextManagedCommitForTesting {
                failsNextManagedCommitForTesting = false
                return .failure(.modelMutationFailed)
            }
        #endif
        guard commitWorkspaceStore(candidate) else { return .failure(.modelMutationFailed) }
        // WHY: An accepted ratio survives reentrant invalidation; only further presentation is denied.
        if let error = validationError() { return .failure(error) }
        guard workspaceStore == candidate else { return .failure(.modelMutationFailed) }
        if workspaceStore.activeWorkspaceID == workspaceID,
            workspaceStore.workspace(id: workspaceID)?.activeTabID == tabID,
            let window = activeWindow, window.isVisible, !window.isMiniaturized,
            presentationMode != .quake || quakeWindowController.requestedVisibility == .shown
        {
            refreshWorkspacePresentation(focusTerminal: false)
            if let error = validationError() { return .failure(error) }
            guard workspaceStore == candidate else { return .failure(.modelMutationFailed) }
        }
        guard let current = managedTasks[taskID] else { return .failure(.targetNotFound) }
        // WHY: Geometry is not terminal output or control transfer; return any callback-updated task.
        return .task(current.task)
    }

    func publishTerminalAutomationPresentation(_ presentation: TerminalAutomationPresentationEvent)
    {
        if case .taskRequiresPresentation(let taskID) = presentation {
            guard liveGrantedManagedTask(taskID: taskID)?.task.state == .waitingForUser else {
                return
            }
        }
        terminalAutomationPresentationHandler?(presentation)
    }

    func publishTerminalAutomationAttention(_ attention: TerminalAutomationAttention) {
        if case .taskRequiresAttention(let taskID) = attention {
            guard liveGrantedManagedTask(taskID: taskID)?.task.state == .waitingForUser else {
                return
            }
        }
        terminalAutomationAttentionHandler?(attention)
    }

    private func observeManagedCompletion(_ process: GhosttyProcessExited, paneID: PaneID) {
        guard let taskID = managedTaskIDByPane[paneID], var record = managedTasks[taskID],
            !record.isRevoked, !record.completionObserved,
            record.task.state == .running || record.task.state == .waitingForUser,
            isCurrentManagedSurface(record)
        else { return }
        record.completionObserved = true
        record.snapshotState = .pendingFinal
        record.completionExitCode = process.exitCode.map { Int32($0) }
        let generation = record.processGeneration
        let surfaceIdentity = record.surfaceIdentity
        let session = record.session
        let clock = ContinuousClock()
        // WHY: Descendants can hold the PTY open forever; output never renews this deadline.
        let deadline = clock.now.advanced(by: .seconds(2))
        record.completionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let current = managedTasks[taskID],
                    current.processGeneration == generation,
                    current.surfaceIdentity == surfaceIdentity, !current.isRevoked
                {
                    managedTasks[taskID]?.completionTask = nil
                }
            }
            @MainActor
            func pendingRecord() -> ManagedTerminalTaskRecord? {
                guard !Task.isCancelled, !isPreparingForTermination, !isTerminalControlFrozen,
                    let current = managedTasks[taskID], current.session == session,
                    current.processGeneration == generation,
                    current.surfaceIdentity == surfaceIdentity,
                    current.task.state == .running || current.task.state == .waitingForUser,
                    current.completionObserved, current.snapshotState == .pendingFinal,
                    current.completionExitCode == process.exitCode.map({ Int32($0) }),
                    !current.isRevoked, !closingPaneIDs.contains(paneID),
                    isCurrentManagedSurface(current),
                    managedAccessError(taskID: taskID, session: session) == nil
                else { return nil }
                return current
            }
            while true {
                guard let before = pendingRecord() else { return }
                let outputState = ghosttyBridge.outputState(id: paneID)
                // WHY: Even the injectable state accessor is a reentrancy boundary.
                guard let current = pendingRecord(), current.task == before.task,
                    current.isAccepted == before.isAccepted
                else { return }
                if outputState == .failed || clock.now >= deadline {
                    managedTasks[taskID]?.snapshotState = .finalReadFailed
                    break
                }
                let refreshAllowed =
                    current.lastRefresh.map {
                        terminalAutomationNow() - $0 >= 0.25
                    } ?? true
                if outputState == .complete && refreshAllowed {
                    if !refreshManagedSnapshot(taskID: taskID, capturesDeferredCompletion: true),
                        pendingRecord() != nil
                    {
                        managedTasks[taskID]?.snapshotState = .finalReadFailed
                    }
                    break
                }
                // WHY: Polling schedules another observation; elapsed time is never EOF evidence.
                do {
                    try await clock.sleep(
                        until: min(deadline, clock.now.advanced(by: .milliseconds(250))))
                } catch { return }
            }
            guard !Task.isCancelled, !isPreparingForTermination, !isTerminalControlFrozen,
                var final = managedTasks[taskID], final.session == session,
                final.processGeneration == generation, final.surfaceIdentity == surfaceIdentity,
                !final.isRevoked, isCurrentManagedSurface(final),
                managedAccessError(taskID: taskID, session: session) == nil,
                final.task.state == .running || final.task.state == .waitingForUser,
                final.completionObserved,
                final.completionExitCode == process.exitCode.map({ Int32($0) }),
                final.snapshotState == .finalCaptured || final.snapshotState == .finalReadFailed
            else { return }
            let captureState = final.snapshotState
            let state: TerminalTaskState =
                process.exitCode.map { $0 == 0 ? .succeeded : .failed } ?? .finishedUnknown
            final.update(
                state: state, owner: .finished, exitCode: process.exitCode.map { Int32($0) })
            // WHY: Classification belongs to this capture; unrelated lifecycle changes invalidate it.
            final.snapshotState = captureState
            final.completionTask = nil
            managedTasks[taskID] = final
            scheduleManagedPresentationRefresh()
            // WHY: Failed capture keeps the surface alive; only an explicit read retries it.
            if canAutomaticallyCloseManagedTask(final) {
                finishSurfaceClosure(id: paneID, closeBridgeSurface: true)
            }
        }
        managedTasks[taskID] = record
        scheduleManagedPresentationRefresh()
    }

    private func retainManagedClosure(paneID: PaneID, allowDuringTermination: Bool) {
        guard let taskID = managedTaskIDByPane[paneID], let initial = managedTasks[taskID] else {
            return
        }
        if initial.isRevoked {
            rememberClosedManagedCreation(initial)
            forgetManagedTask(taskID: taskID, expectedSession: initial.session)
            return
        }
        _ = refreshManagedSnapshot(taskID: taskID)
        // WHY: A bridge read may freeze before removal was accepted. Keep the live record
        // for later teardown rather than treating freeze's revocation as a completed close.
        guard !isPreparingForTermination || allowDuringTermination else { return }
        guard var record = managedTasks[taskID],
            record.processGeneration == initial.processGeneration
        else { return }
        if record.isRevoked {
            rememberClosedManagedCreation(record)
            forgetManagedTask(taskID: taskID, expectedSession: record.session)
            return
        }
        record.completionTask?.cancel()
        record.completionTask = nil
        let captured = record.snapshotState == .finalCaptured
        // WHY: User-forced closure preserves the bounded cache, but may omit the final tail.
        let retainedOutput =
            captured
            ? record.rendered : GhosttyRenderedText(text: record.rendered.text, isTruncated: true)
        if record.task.owner != .finished {
            let state: TerminalTaskState =
                record.completionObserved
                ? record.completionExitCode.map { $0 == 0 ? .succeeded : .failed }
                    ?? .finishedUnknown
                : .cancelled
            record.update(
                rendered: retainedOutput, state: state, owner: .finished,
                exitCode: record.completionExitCode)
        } else {
            record.update(rendered: retainedOutput)
        }
        // WHY: Closing preserves a successful capture, but cannot turn cached output into one.
        record.snapshotState = captured ? .finalCaptured : .closedFallback
        record.surfaceIdentity = nil
        managedTasks[taskID] = record
        managedTaskIDByPane.removeValue(forKey: paneID)
        scheduleManagedPresentationRefresh()
    }

    func requestManagedClose(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity,
        context: TerminalControlRequestContext
    ) async -> TerminalAutomationHostResponse {
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard context.isActive, !Task.isCancelled else { return .failure(.cancelled) }
        guard let initial = managedTasks[taskID] else { return .failure(.targetNotFound) }
        let paneID = PaneID(rawValue: initial.task.paneID)
        if initial.surfaceIdentity == nil { return .task(initial.task) }
        if initial.task.owner != .finished, ghosttyBridge.surfaceNeedsConfirmQuit(id: paneID) {
            let decision: ManagedCloseDecision
            if let existing = managedCloseDecisions[taskID],
                existing.session == expectedSession,
                existing.processGeneration == initial.processGeneration,
                existing.surfaceIdentity == initial.surfaceIdentity
            {
                decision = existing
            } else {
                decision = ManagedCloseDecision(initial)
                managedCloseDecisions[taskID] = decision
                let token = confirmationQueue.enqueueClose(paneID: paneID) {
                    [weak decision] response in
                    guard let decision, !decision.isCancelled, decision.response == nil else {
                        return
                    }
                    decision.response = response
                }
                decision.confirmationToken = token
                // WHY: A synchronous presenter can revoke the cohort before enqueue returns its token.
                if decision.isCancelled { confirmationQueue.cancelClose(token) }
            }
            decision.participantCount += 1
            defer {
                decision.participantCount -= 1
                if decision.participantCount == 0, managedCloseDecisions[taskID] === decision {
                    managedCloseDecisions.removeValue(forKey: taskID)
                }
            }
            #if DEBUG
                managedCloseWaiterJoinedForTesting?(decision.participantCount)
            #endif
            while decision.response == nil && !decision.isCancelled {
                guard context.isActive, !Task.isCancelled else {
                    cancelManagedClose(taskID: taskID, decision: decision)
                    return .failure(.cancelled)
                }
                if let error = managedAccessError(taskID: taskID, session: expectedSession) {
                    cancelManagedClose(taskID: taskID, decision: decision)
                    return .failure(error)
                }
                guard managedTasks[taskID]?.processGeneration == initial.processGeneration,
                    managedTasks[taskID]?.surfaceIdentity == initial.surfaceIdentity
                else {
                    cancelManagedClose(taskID: taskID, decision: decision)
                    return .failure(.cancelled)
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch {
                    cancelManagedClose(taskID: taskID, decision: decision)
                    return .failure(.cancelled)
                }
            }
            guard context.isActive, !Task.isCancelled else {
                cancelManagedClose(taskID: taskID, decision: decision)
                return .failure(.cancelled)
            }
            if let error = managedAccessError(taskID: taskID, session: expectedSession) {
                cancelManagedClose(taskID: taskID, decision: decision)
                return .failure(error)
            }
            guard !decision.isCancelled else { return .failure(.cancelled) }
            guard decision.response == .allow else { return .failure(.closeConfirmationDenied) }
        }
        guard context.isActive, !Task.isCancelled else { return .failure(.cancelled) }
        if let error = managedAccessError(taskID: taskID, session: expectedSession) {
            return .failure(error)
        }
        guard let current = managedTasks[taskID],
            current.processGeneration == initial.processGeneration,
            current.surfaceIdentity == initial.surfaceIdentity, isCurrentManagedSurface(current)
        else { return .failure(.cancelled) }
        finishSurfaceClosure(id: paneID, closeBridgeSurface: true)
        guard let final = managedTasks[taskID], final.surfaceIdentity == nil else {
            return .failure(.internalFailure)
        }
        return .task(final.task)
    }

    private func cancelManagedClose(taskID: UUID, decision: ManagedCloseDecision) {
        // WHY: Automation owns one queue participant, not the UI's coalesced close requests.
        decision.isCancelled = true
        guard managedCloseDecisions[taskID] === decision else { return }
        managedCloseDecisions.removeValue(forKey: taskID)
        if let token = decision.confirmationToken {
            decision.confirmationToken = nil
            confirmationQueue.cancelClose(token)
        }
    }

    private func revokeManagedOrigin(_ paneID: PaneID) {
        let sessions = Set(
            managedTasks.values.filter { $0.session.originPaneID == paneID }.map(\.session))
        for session in sessions { revokeManagedSession(session) }
        terminalAutomationCoordinator.originSessionDidChange(originPaneID: paneID)
    }

    func revokeManagedSession(_ session: TerminalAutomationSessionIdentity) {
        terminalControlPermissionController.cancel(session: session)
        let ids = managedTaskOrder.filter { managedTasks[$0]?.session == session }
        guard !ids.isEmpty else { return }
        defer { scheduleManagedPresentationRefresh() }
        for id in ids {
            guard var record = managedTasks[id], !record.isRevoked else { continue }
            record.completionTask?.cancel()
            record.completionTask = nil
            // WHY: Revocation clears output, so preserve only closure authority already verified.
            let shouldClose =
                record.snapshotState == .finalCaptured
                && record.completionObserved && record.completionExitCode == 0
                && record.task.state == .succeeded && record.task.owner == .finished
                && record.task.policy == .closeOnSuccess && record.isAccepted
            record.isRevoked = true
            record.hasDomainAcceptance = false
            record.snapshotState = .revoked
            // WHY: Retain exact compensating identity for surviving panes, not revoked output.
            record.update(rendered: GhosttyRenderedText(text: "", isTruncated: false), owner: .user)
            if shouldClose, !isPreparingForTermination, isCurrentManagedSurface(record) {
                let generation = record.processGeneration
                let surfaceIdentity = record.surfaceIdentity
                let paneID = PaneID(rawValue: record.task.paneID)
                // WHY: Origin removal may still own an uncommitted model; close against the next turn's store.
                record.completionTask = Task { @MainActor [weak self] in
                    guard let self, let current = managedTasks[id],
                        current.session == session, current.processGeneration == generation,
                        current.surfaceIdentity == surfaceIdentity, current.isRevoked
                    else { return }
                    managedTasks[id]?.completionTask = nil
                    guard !Task.isCancelled, !isPreparingForTermination, !isTerminalControlFrozen,
                        shouldClose, current.isAccepted, current.task.policy == .closeOnSuccess,
                        current.task.state == .succeeded,
                        isCurrentManagedSurface(current)
                    else { return }
                    finishSurfaceClosure(id: paneID, closeBridgeSurface: true)
                }
            }
            managedTasks[id] = record
            if let decision = managedCloseDecisions[id] {
                cancelManagedClose(taskID: id, decision: decision)
            }
            if record.surfaceIdentity == nil {
                rememberClosedManagedCreation(record)
                forgetManagedTask(taskID: id, expectedSession: session)
            }
        }
    }

    private func rememberClosedManagedCreation(_ record: ManagedTerminalTaskRecord) {
        // WHY: Accepted lifecycle cleanup has no outstanding creation response to compensate.
        guard !record.isAccepted else { return }
        discardedManagedTasks[record.task.taskID] = DiscardedManagedTaskRecord(
            created: TerminalAutomationCreatedTaskResponse(
                task: record.createdTask, splitID: record.splitID),
            session: record.session,
            compensationCompleted: false
        )
    }

    func acceptManagedCreation(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) {
        let taskID = created.task.taskID
        guard var record = managedTasks[taskID], record.session == expectedSession,
            record.createdTask == created.task, record.splitID == created.splitID,
            !record.isRevoked, !record.isAccepted
        else { return }
        record.isAccepted = true
        record.hasDomainAcceptance = true
        managedTasks[taskID] = record
        scheduleManagedPresentationRefresh()
        // WHY: Acceptance alone cannot authorize closure after a failed final capture.
        scheduleManagedSuccessfulClosure(taskID: taskID)
    }

    func forgetManagedTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) {
        guard let record = managedTasks[taskID], record.session == expectedSession else { return }
        record.completionTask?.cancel()
        if let decision = managedCloseDecisions[taskID] {
            cancelManagedClose(taskID: taskID, decision: decision)
        }
        managedTasks.removeValue(forKey: taskID)
        managedTaskOrder.removeAll { $0 == taskID }
        let paneID = PaneID(rawValue: record.task.paneID)
        if managedTaskIDByPane[paneID] == taskID { managedTaskIDByPane.removeValue(forKey: paneID) }
        scheduleManagedPresentationRefresh()
    }

    func canEvictManagedTask(
        taskID: UUID, expectedSession: TerminalAutomationSessionIdentity
    ) -> Bool {
        guard let record = managedTasks[taskID], record.session == expectedSession else {
            return false
        }
        // WHY: Neither failed capture nor a scheduled close releases mandatory cleanup authority.
        let unfinishedClose =
            record.surfaceIdentity != nil && record.task.policy == .closeOnSuccess
            && (record.task.state == .succeeded
                || (record.completionObserved && record.completionExitCode == 0))
        return record.isAccepted && !unfinishedClose
    }

    private func canCreateManagedTask(for session: TerminalAutomationSessionIdentity) -> Bool {
        let records = managedTasks.values.filter { $0.session == session }
        guard
            records.filter({
                !$0.isRevoked && ($0.task.state == .running || $0.task.state == .waitingForUser)
            }).count < 8
        else {
            return false
        }
        return records.count < TerminalControlLimits.maximumRetainedTaskCount
            || records.contains {
                $0.task.owner == .finished
                    && canEvictManagedTask(taskID: $0.task.taskID, expectedSession: session)
                    && terminalAutomationCoordinator.canEvictHostTask(
                        taskID: $0.task.taskID, session: session)
            }
    }

    private func trimManagedTasks(for session: TerminalAutomationSessionIdentity) {
        // WHY: Domain creation must pass post-await validation before any retained task is evicted.
        guard !terminalAutomationCoordinator.hasPendingHostCreation(for: session) else { return }
        while managedTasks.values.filter({ $0.session == session }).count
            > TerminalControlLimits.maximumRetainedTaskCount
        {
            guard
                let id = managedTaskOrder.first(where: {
                    guard let record = managedTasks[$0], record.session == session else {
                        return false
                    }
                    return record.task.owner == .finished
                        && canEvictManagedTask(taskID: $0, expectedSession: session)
                        && terminalAutomationCoordinator.canEvictHostTask(
                            taskID: $0, session: session)
                })
            else { return }
            forgetManagedTask(taskID: id, expectedSession: session)
        }
    }

    func requestCloseActivePane() {
        guard let paneID = activePaneID else { return }
        guard surfaces[paneID] != nil else {
            closeUnavailablePane(paneID)
            return
        }
        requestClosePane(
            paneID,
            requiresConfirmation: ghosttyBridge.surfaceNeedsConfirmQuit(id: paneID)
        )
    }

    func requestCloseActiveTab() {
        guard let tabID = activeTab?.id else { return }
        requestCloseTab(tabID)
    }

    func splitActivePane(axis: SplitAxis) throws {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            let descriptor = tab.paneDescriptor(for: tab.activePaneID),
            let activeSurface = surfaces[tab.activePaneID]
        else {
            return
        }

        let workingDirectory =
            activeSurface.currentWorkingDirectory.flatMap {
                $0.isEmpty ? nil : $0
            } ?? descriptor.cwd
        let paneID = PaneID()
        var splitConfiguration = surfaceConfiguration
        splitConfiguration.workingDirectory = workingDirectory
        splitConfiguration.command = nil
        splitConfiguration.initialInput = nil
        splitConfiguration.context = .split
        let surface = try makeConfiguredSurface(
            id: paneID,
            configuration: splitConfiguration
        )
        let newPane = TerminalPaneDescriptor(
            id: paneID,
            cwd: workingDirectory,
            startupCommand: .shell
        )
        var candidate = workspaceStore

        do {
            #if DEBUG
                if failsNextSplitMutationForTesting {
                    failsNextSplitMutationForTesting = false
                    throw SplitCoordinatorError.paneNotFound(tab.activePaneID)
                }
            #endif

            _ = try splitCoordinator.apply(
                .split(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: tab.activePaneID,
                    axis: axis,
                    newPane: newPane,
                    ratio: 0.5
                ),
                to: &candidate
            )
        } catch {
            closeCreatedSurface(id: paneID)
            throw error
        }

        surfaces[paneID] = surface
        installSurfaceActivityHandlers()
        guard commitWorkspaceStore(candidate) else {
            surfaces.removeValue(forKey: paneID)
            closeCreatedSurface(id: paneID)
            return
        }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func activateTab(at index: Int) {
        guard index > 0,
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID),
            workspace.tabs.indices.contains(index - 1)
        else { return }

        var candidate = workspaceStore
        do {
            try candidate.activateTab(
                workspace.tabs[index - 1].id,
                in: candidate.activeWorkspaceID
            )
        } catch {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func installTerminalNotificationController(
        _ controller: TerminalNotificationController
    ) {
        guard !isPreparingForTermination else {
            controller.shutdown()
            return
        }
        guard terminalNotificationController !== controller else { return }
        terminalNotificationController?.shutdown()
        terminalNotificationController = controller
    }

    func terminalDestination(for paneID: PaneID) -> TerminalDestination? {
        guard let ownership = liveOwnership(for: paneID) else { return nil }
        return TerminalDestination(
            workspaceID: ownership.workspace.id,
            tabID: ownership.tab.id,
            paneID: paneID
        )
    }

    func isCurrentTerminalActivityEffect(_ effect: TerminalActivityEffect) -> Bool {
        guard activityConfiguration.progressStyleEnabled,
            liveOwningTab(for: effect.paneID) != nil,
            let phase = terminalActivityController.statuses[effect.paneID]?.phase
        else { return false }

        switch (effect, phase) {
        case (.waiting, .waiting), (.failed, .failed), (.completed, .completed):
            return true
        case (.waiting, _), (.failed, _), (.completed, _), (.cleared, _):
            return false
        }
    }

    func shouldSuppressNotification(for destination: TerminalDestination) -> Bool {
        guard activeWindowIsKey,
            workspaceStore.activeWorkspaceID == destination.workspaceID,
            let workspace = workspaceStore.workspace(id: destination.workspaceID)
        else {
            return false
        }
        return workspace.activeTabID == destination.tabID
    }

    func activate(destination: TerminalDestination) {
        guard !isPreparingForTermination,
            let ownership = liveOwnership(for: destination.paneID),
            ownership.workspace.id == destination.workspaceID,
            ownership.tab.id == destination.tabID
        else {
            return
        }

        var candidate = workspaceStore
        do {
            try candidate.activateWorkspace(destination.workspaceID)
            try candidate.activateTab(destination.tabID, in: destination.workspaceID)
            _ = try splitCoordinator.apply(
                .activatePane(
                    workspaceID: destination.workspaceID,
                    tabID: destination.tabID,
                    paneID: destination.paneID
                ),
                to: &candidate
            )
            try presentationController.showCurrentPresentation()
        } catch {
            onError(error)
            return
        }

        _ = commitWorkspaceStore(candidate)
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func activateWorkspace(at oneBasedIndex: Int) {
        guard
            (1...9).contains(oneBasedIndex),
            workspaceStore.workspaces.indices.contains(oneBasedIndex - 1)
        else {
            return
        }
        activateWorkspace(id: workspaceStore.workspaces[oneBasedIndex - 1].id)
    }

    private func activateWorkspace(id workspaceID: WorkspaceID) {
        var candidate = workspaceStore
        do {
            try candidate.activateWorkspace(workspaceID)
        } catch {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func toggleBroadcast() {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID)
        else {
            return
        }

        var candidate = workspaceStore
        do {
            try candidate.setBroadcasting(
                !tab.isBroadcasting,
                for: tabID,
                in: workspaceID
            )
            guard commitWorkspaceStore(candidate) else { return }
            guard !isPreparingForTermination else { return }
            workspaceViewController.apply(
                workspaceStore,
                liveTitles: liveSurfaceTitles,
                paneStatuses: terminalActivityController.statuses
            )
            if let surface = activePaneID.flatMap({ surfaces[$0] }), let paneID = activePaneID {
                focus(surface, paneID: paneID)
            }
        } catch {
            onError(error)
        }
    }

    func focusPreviousPane() {
        focusActivePane(using: .previous)
    }

    func focusNextPane() {
        focusActivePane(using: .next)
    }

    func focusPane(direction: SplitFocusDirection) {
        focusActivePane(using: .direction(direction))
    }

    func createShellTab(in workspaceID: WorkspaceID? = nil) throws {
        try createShellTab(in: workspaceID, refreshPresentation: true)
    }

    private func createStartupShellTab() throws {
        let workspaceID = workspaceStore.activeWorkspaceID
        let paneID = PaneID()
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: surfaceConfiguration.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            startupCommand: surfaceConfiguration.command.map(StartupCommand.custom) ?? .shell
        )
        let tab = TerminalTab(title: "Shell", pane: descriptor)
        var candidate = workspaceStore

        #if DEBUG
            if failsNextStartupModelMutationForTesting {
                failsNextStartupModelMutationForTesting = false
                throw WorkspaceError.workspaceNotFound(workspaceID)
            }
        #endif

        try candidate.addTab(tab, to: workspaceID)
        try candidate.activateTab(tab.id, in: workspaceID)
        _ = commitWorkspaceStore(candidate)

        var startupConfiguration = surfaceConfiguration
        startupConfiguration.context = .window
        do {
            let surface = try makeConfiguredSurface(
                id: paneID,
                configuration: startupConfiguration
            )
            surfaces[paneID] = surface
            installSurfaceActivityHandlers()
            surfaceFailures.removeValue(forKey: paneID)
        } catch {
            surfaceFailures[paneID] = SurfaceFailurePresentation(
                message: error.localizedDescription
            )
        }
    }

    func openConfiguration(at configURL: URL) throws {
        try createConfigurationTab(
            at: configURL,
            in: workspaceStore.activeWorkspaceID
        )
    }

    private func createShellTab(
        in workspaceID: WorkspaceID? = nil,
        refreshPresentation: Bool,
        surfaceContext: GhosttySurfaceConfiguration.Context = .newTab
    ) throws {
        var candidate = workspaceStore
        let prepared = try prepareShellTab(
            in: workspaceID ?? candidate.activeWorkspaceID,
            candidate: &candidate,
            surfaceContext: surfaceContext
        )
        surfaces[prepared.paneID] = prepared.surface
        installSurfaceActivityHandlers()
        guard commitWorkspaceStore(candidate) else {
            surfaces.removeValue(forKey: prepared.paneID)
            closeCreatedSurface(id: prepared.paneID)
            return
        }
        if refreshPresentation {
            refreshWorkspacePresentation(focusTerminal: true)
        }
    }

    private func prepareShellTab(
        in workspaceID: WorkspaceID,
        candidate: inout WorkspaceStore,
        surfaceContext: GhosttySurfaceConfiguration.Context
    ) throws -> (paneID: PaneID, surface: GhosttySurfaceView) {
        let paneID = PaneID()
        var tabConfiguration = surfaceConfiguration
        tabConfiguration.context = surfaceContext
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: surfaceConfiguration.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            startupCommand: surfaceConfiguration.command.map(StartupCommand.custom) ?? .shell
        )
        let surface = try prepareTab(
            title: "Shell",
            paneID: paneID,
            descriptor: descriptor,
            configuration: tabConfiguration,
            in: workspaceID,
            candidate: &candidate
        )
        return (paneID, surface)
    }

    private func createConfigurationTab(
        at configURL: URL,
        in workspaceID: WorkspaceID
    ) throws {
        let absoluteConfigURL = configURL.standardizedFileURL
        let workingDirectory = absoluteConfigURL.deletingLastPathComponent().path
        let command = "\(configEditor) \(Self.posixShellQuoted(absoluteConfigURL.path))"
        let paneID = PaneID()
        var tabConfiguration = surfaceConfiguration
        tabConfiguration.workingDirectory = workingDirectory
        tabConfiguration.command = command
        tabConfiguration.initialInput = nil
        tabConfiguration.context = .newTab
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: workingDirectory,
            startupCommand: .custom(command)
        )
        try createTab(
            title: "Config",
            paneID: paneID,
            descriptor: descriptor,
            configuration: tabConfiguration,
            in: workspaceID,
            refreshPresentation: true
        )
    }

    private func createTab(
        title: String,
        paneID: PaneID,
        descriptor: TerminalPaneDescriptor,
        configuration: GhosttySurfaceConfiguration,
        in workspaceID: WorkspaceID,
        refreshPresentation: Bool
    ) throws {
        var candidate = workspaceStore
        let surface = try prepareTab(
            title: title,
            paneID: paneID,
            descriptor: descriptor,
            configuration: configuration,
            in: workspaceID,
            candidate: &candidate
        )
        surfaces[paneID] = surface
        installSurfaceActivityHandlers()
        guard commitWorkspaceStore(candidate) else {
            surfaces.removeValue(forKey: paneID)
            closeCreatedSurface(id: paneID)
            return
        }
        if refreshPresentation {
            refreshWorkspacePresentation(focusTerminal: true)
        }
    }

    private func prepareTab(
        title: String,
        paneID: PaneID,
        descriptor: TerminalPaneDescriptor,
        configuration: GhosttySurfaceConfiguration,
        in workspaceID: WorkspaceID,
        candidate: inout WorkspaceStore
    ) throws -> GhosttySurfaceView {
        let surface = try makeConfiguredSurface(
            id: paneID,
            configuration: configuration
        )
        let tab = TerminalTab(title: title, pane: descriptor)

        do {
            try candidate.addTab(tab, to: workspaceID)
            try candidate.activateTab(tab.id, in: workspaceID)
        } catch {
            closeCreatedSurface(id: paneID)
            throw error
        }

        return surface
    }

    private static func posixShellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct SavedRestorePane {
        let workspaceID: WorkspaceID
        let tabID: TabID
        let leafIndex: Int
        let descriptor: TerminalPaneDescriptor
    }

    private func restoreWorkspaceSurfaces() throws {
        let panes = orderedSavedRestorePanes()
        let decisions = planAgentRestore(
            for: panes,
            explicitRetry: [],
            retryPaneID: nil
        )
        surfaces = [:]
        surfaceFailures = [:]

        for pane in panes {
            let paneID = pane.descriptor.id
            let configuration = savedRestoreSurfaceConfiguration(for: pane)
            switch decisions[paneID] ?? .freshShell(binding: nil) {
            case .freshShell(let binding):
                applyFreshShellAgentPresentation(binding, paneID: paneID)
                do {
                    surfaces[paneID] = try makeConfiguredSurface(
                        id: paneID,
                        configuration: configuration
                    )
                } catch {
                    surfaceFailures[paneID] = SurfaceFailurePresentation(
                        message: error.localizedDescription
                    )
                    resetBroadcastingForRestoreFailure(pane)
                }

            case .blocked(let binding, let diagnostic):
                _ = updateAgentResumeBinding(binding, for: paneID)
                agentResumePresentations[paneID] = .failed(
                    diagnosticCode: diagnostic.code
                )
                do {
                    surfaces[paneID] = try makeConfiguredSurface(
                        id: paneID,
                        configuration: configuration
                    )
                } catch {
                    surfaceFailures[paneID] = SurfaceFailurePresentation(
                        message: error.localizedDescription
                    )
                    resetBroadcastingForRestoreFailure(pane)
                }

            case .resume(let attempt):
                guard agentResumeRuntime.begin(attempt) else {
                    let failedBinding = attempt.binding.updatingRestoreState(
                        .failed(
                            diagnosticCode: .duplicateBinding,
                            failedAt: agentResumeScheduler.date
                        )
                    )
                    _ = updateAgentResumeBinding(failedBinding, for: paneID)
                    agentResumePresentations[paneID] = .failed(
                        diagnosticCode: .duplicateBinding
                    )
                    do {
                        surfaces[paneID] = try makeConfiguredSurface(
                            id: paneID,
                            configuration: configuration
                        )
                    } catch {
                        surfaceFailures[paneID] = SurfaceFailurePresentation(
                            message: error.localizedDescription
                        )
                        resetBroadcastingForRestoreFailure(pane)
                    }
                    continue
                }

                agentResumeAttempts[paneID] = attempt
                do {
                    let launch = try agentLaunchConfiguration(for: attempt)
                    var resumeConfiguration = configuration
                    resumeConfiguration.workingDirectory = attempt.invocation.workingDirectory
                    resumeConfiguration.command = launch.command
                    let surface = try makeConfiguredSurface(
                        id: paneID,
                        configuration: resumeConfiguration,
                        additionalAppOwnedEnvironment: launch.environment
                    )
                    surfaces[paneID] = surface
                    agentResumeRuntime.surfaceDidBecomeLive(attempt.reference)
                } catch {
                    agentResumeRuntime.surfaceCreationFailed(attempt.reference)
                    agentResumeAttempts.removeValue(forKey: paneID)
                    resetBroadcastingForRestoreFailure(pane)
                }
            }
        }

        installSurfaceActivityHandlers()
    }

    private func orderedSavedRestorePanes() -> [SavedRestorePane] {
        workspaceStore.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.root.leaves.enumerated().map { leafIndex, paneID in
                    guard let descriptor = tab.paneDescriptor(for: paneID) else {
                        preconditionFailure("WorkspaceStore contains an invalid tab")
                    }
                    return SavedRestorePane(
                        workspaceID: workspace.id,
                        tabID: tab.id,
                        leafIndex: leafIndex,
                        descriptor: descriptor
                    )
                }
            }
        }
    }

    private func planAgentRestore(
        for panes: [SavedRestorePane],
        explicitRetry: Set<PaneID>,
        retryPaneID: PaneID?
    ) -> [PaneID: AgentRestoreDecision] {
        let adapterIDs = Set(
            panes.compactMap { $0.descriptor.agentResumeBinding?.adapterID }
        ).sorted { $0.rawValue < $1.rawValue }
        let compatibility: [AgentAdapterID: AgentRestoreCompatibility]
        if !shouldRestoreAgentSessions || agentSessionController == nil {
            compatibility = [:]
        } else if let agentRestoreCompatibilityResolver,
            retryPaneID != nil || agentRestoreCompatibility.isEmpty
        {
            compatibility = agentRestoreCompatibilityResolver(adapterIDs)
        } else {
            compatibility = Dictionary(
                uniqueKeysWithValues: adapterIDs.compactMap { adapterID in
                    agentRestoreCompatibility[adapterID].map { (adapterID, $0) }
                }
            )
        }
        let attemptIdentities: [PaneID: AgentResumeAttemptIdentity] = Dictionary(
            uniqueKeysWithValues: panes.compactMap { pane in
                guard pane.descriptor.agentResumeBinding != nil else { return nil }
                if retryPaneID == nil || retryPaneID == pane.descriptor.id {
                    return (
                        pane.descriptor.id,
                        nextAgentResumeAttemptIdentity(for: pane.descriptor.id)
                    )
                }
                return (
                    pane.descriptor.id,
                    AgentResumeAttemptIdentity(
                        id: UUID(),
                        generation: (agentResumeGenerationByPane[pane.descriptor.id] ?? 0) + 1
                    )
                )
            }
        )
        return agentRestorePlanner(
            AgentRestorePlanner.Input(
                panes: panes.map { pane in
                    AgentRestorePaneInput(
                        descriptor: pane.descriptor,
                        bindingWorkingDirectoryExists: pane.descriptor.agentResumeBinding.map {
                            agentRestoreWorkingDirectoryExists($0.workingDirectory)
                        } ?? true
                    )
                },
                effectivePolicyEnabled: shouldRestoreAgentSessions,
                registry: Dictionary(
                    uniqueKeysWithValues: AgentIntegrationRegistry.definitions.map { ($0.id, $0) }
                ),
                compatibilityByAdapter: compatibility,
                homeDirectory: agentRestoreHomeDirectory(),
                explicitRetry: explicitRetry,
                attemptIdentityByPane: attemptIdentities,
                failedAt: agentResumeScheduler.date
            )
        )
    }

    private func nextAgentResumeAttemptIdentity(
        for paneID: PaneID
    ) -> AgentResumeAttemptIdentity {
        let generation = (agentResumeGenerationByPane[paneID] ?? 0) + 1
        agentResumeGenerationByPane[paneID] = generation
        return AgentResumeAttemptIdentity(id: UUID(), generation: generation)
    }

    private func savedRestoreSurfaceConfiguration(
        for pane: SavedRestorePane
    ) -> GhosttySurfaceConfiguration {
        var configuration = surfaceConfiguration
        configuration.workingDirectory = pane.descriptor.cwd
        configuration.command = nil
        configuration.initialInput = nil
        configuration.environment.removeValue(
            forKey: AgentInvocationPayloadEnvironment.payloadKey
        )
        configuration.environment.removeValue(
            forKey: AgentInvocationPayloadEnvironment.helperKey
        )
        configuration.context = pane.leafIndex == 0 ? .newTab : .split
        return configuration
    }

    private func agentLaunchConfiguration(
        for attempt: AgentResumeAttempt
    ) throws -> AgentLaunchConfiguration {
        guard let helperPath = agentSessionController?.bundledHelperPath else {
            throw AgentLaunchConfigurationError.invalidHelperPath
        }
        return try AgentLaunchConfiguration(
            invocation: attempt.invocation,
            bundledHelperPath: helperPath,
            executableSearchPath: executableSearchPath
        )
    }

    private func applyFreshShellAgentPresentation(
        _ binding: AgentResumeBinding?,
        paneID: PaneID
    ) {
        guard let binding else {
            agentResumePresentations.removeValue(forKey: paneID)
            return
        }
        guard shouldRestoreAgentSessions else {
            agentResumePresentations[paneID] = .restoreDisabled
            return
        }
        switch binding.restoreState {
        case .failed(let diagnosticCode, _):
            agentResumePresentations[paneID] = .failed(
                diagnosticCode: diagnosticCode
            )
        case .unverified:
            agentResumePresentations[paneID] = .unverified
        case .active, .restoring:
            agentResumePresentations.removeValue(forKey: paneID)
        }
    }

    private func resetBroadcastingForRestoreFailure(_ pane: SavedRestorePane) {
        var candidate = workspaceStore
        guard
            (try? candidate.resetBroadcasting(
                for: pane.tabID,
                in: pane.workspaceID
            )) != nil
        else { return }
        _ = commitWorkspaceStore(candidate)
    }

    @MainActor
    private func retryUnavailablePane(_ paneID: PaneID) {
        guard !isPreparingForTermination,
            surfaces[paneID] == nil, surfaceFailures[paneID] != nil
        else { return }

        var owningWorkspace: Workspace?
        var owningTab: TerminalTab?
        var leafIndex: Int?
        var descriptor: TerminalPaneDescriptor?

        search: for workspace in workspaceStore.workspaces {
            for tab in workspace.tabs {
                guard let index = tab.root.leaves.firstIndex(of: paneID),
                    let paneDescriptor = tab.paneDescriptor(for: paneID)
                else {
                    continue
                }
                owningWorkspace = workspace
                owningTab = tab
                leafIndex = index
                descriptor = paneDescriptor
                break search
            }
        }

        guard let owningWorkspace, let owningTab, let leafIndex, let descriptor else { return }

        var retryConfiguration = surfaceConfiguration
        retryConfiguration.workingDirectory = descriptor.cwd
        retryConfiguration.command = nil
        retryConfiguration.initialInput = nil
        retryConfiguration.context = leafIndex == 0 ? .newTab : .split

        let ownerTabWasVisible =
            owningWorkspace.id == workspaceStore.activeWorkspaceID
            && owningWorkspace.activeTabID == owningTab.id
        let shouldFocus = ownerTabWasVisible && owningTab.activePaneID == paneID
        do {
            let surface = try makeConfiguredSurface(
                id: paneID,
                configuration: retryConfiguration
            )
            cleanUpPaneLifecycle(paneID)
            surfaces[paneID] = surface
            installSurfaceActivityHandlers()
            surfaceFailures.removeValue(forKey: paneID)
            if ownerTabWasVisible {
                refreshWorkspacePresentation(focusTerminal: shouldFocus)
            }
        } catch {
            surfaceFailures[paneID] = SurfaceFailurePresentation(
                message: error.localizedDescription
            )
            if ownerTabWasVisible {
                refreshWorkspacePresentation(focusTerminal: false)
            }
        }
    }

    private func retryAgentResume(_ paneID: PaneID) {
        // WHY: Retry can remove an existing surface before its binding reaches the commit boundary.
        guard !isPreparingForTermination else { return }
        let panes = orderedSavedRestorePanes()
        guard
            let pane = panes.first(where: {
                $0.descriptor.id == paneID
            }), let binding = pane.descriptor.agentResumeBinding
        else { return }
        switch binding.restoreState {
        case .failed(let diagnosticCode, _):
            guard
                AgentResumePresentation.failed(
                    diagnosticCode: diagnosticCode
                ).canRetry
            else { return }
        case .unverified:
            break
        case .active, .restoring:
            return
        }

        let decisions = planAgentRestore(
            for: panes,
            explicitRetry: [paneID],
            retryPaneID: paneID
        )
        guard !isPreparingForTermination, let decision = decisions[paneID] else { return }
        switch decision {
        case .freshShell(let retainedBinding):
            applyFreshShellAgentPresentation(retainedBinding, paneID: paneID)
            if activeTab?.root.contains(paneID) == true {
                refreshWorkspacePresentation(focusTerminal: false)
            }
            return
        case .blocked(let failedBinding, let diagnostic):
            let replacesResumeSurface = agentResumeAttempts[paneID] != nil
            let shouldFocus = activePaneID == paneID && surfaces[paneID] != nil
            if replacesResumeSurface, surfaces[paneID] != nil {
                guard
                    removeSurface(
                        id: paneID,
                        closeBridgeSurface: true,
                        preserveAgentPresentation: true
                    )
                else { return }
            } else if let previousAttempt = agentResumeAttempts.removeValue(forKey: paneID) {
                agentResumeRuntime.surfaceDidClose(previousAttempt.reference)
            }
            _ = updateAgentResumeBinding(failedBinding, for: paneID)
            agentResumePresentations[paneID] = .failed(
                diagnosticCode: diagnostic.code
            )
            if surfaces[paneID] == nil {
                do {
                    surfaces[paneID] = try makeConfiguredSurface(
                        id: paneID,
                        configuration: savedRestoreSurfaceConfiguration(for: pane)
                    )
                    surfaceFailures.removeValue(forKey: paneID)
                    installSurfaceActivityHandlers()
                } catch {
                    surfaceFailures[paneID] = SurfaceFailurePresentation(
                        message: error.localizedDescription
                    )
                    resetBroadcastingForRestoreFailure(pane)
                }
            }
            if activeTab?.root.contains(paneID) == true {
                refreshWorkspacePresentation(focusTerminal: shouldFocus)
            }
            return
        case .resume(let attempt):
            let shouldFocus = activePaneID == paneID && surfaces[paneID] != nil
            if surfaces[paneID] != nil {
                guard
                    removeSurface(
                        id: paneID,
                        closeBridgeSurface: true,
                        preserveAgentPresentation: true
                    )
                else { return }
            } else if let previousAttempt = agentResumeAttempts.removeValue(forKey: paneID) {
                agentResumeRuntime.surfaceDidClose(previousAttempt.reference)
            }
            surfaceFailures.removeValue(forKey: paneID)
            agentResumeAttempts[paneID] = attempt
            guard agentResumeRuntime.retry(attempt) else {
                agentResumeAttempts.removeValue(forKey: paneID)
                let failedBinding = attempt.binding.updatingRestoreState(
                    .failed(
                        diagnosticCode: .duplicateBinding,
                        failedAt: agentResumeScheduler.date
                    )
                )
                _ = updateAgentResumeBinding(failedBinding, for: paneID)
                agentResumePresentations[paneID] = .failed(
                    diagnosticCode: .duplicateBinding
                )
                if activeTab?.root.contains(paneID) == true {
                    refreshWorkspacePresentation(focusTerminal: false)
                }
                return
            }

            do {
                let launch = try agentLaunchConfiguration(for: attempt)
                var configuration = savedRestoreSurfaceConfiguration(for: pane)
                configuration.workingDirectory = attempt.invocation.workingDirectory
                configuration.command = launch.command
                let surface = try makeConfiguredSurface(
                    id: paneID,
                    configuration: configuration,
                    additionalAppOwnedEnvironment: launch.environment
                )
                surfaces[paneID] = surface
                installSurfaceActivityHandlers()
                agentResumeRuntime.surfaceDidBecomeLive(attempt.reference)
                if activeTab?.root.contains(paneID) == true {
                    refreshWorkspacePresentation(focusTerminal: shouldFocus)
                }
            } catch {
                agentResumeRuntime.surfaceCreationFailed(attempt.reference)
                agentResumeAttempts.removeValue(forKey: paneID)
                resetBroadcastingForRestoreFailure(pane)
                if activeTab?.root.contains(paneID) == true {
                    refreshWorkspacePresentation(focusTerminal: false)
                }
            }
        }
    }

    private func forgetAgentResume(_ paneID: PaneID) {
        guard !isPreparingForTermination else { return }
        guard
            let pane = orderedSavedRestorePanes().first(where: {
                $0.descriptor.id == paneID
            }), pane.descriptor.agentResumeBinding != nil
        else { return }

        if agentResumeAttempts[paneID] != nil {
            agentResumeRuntime.forget(paneID: paneID)
            agentResumeAttempts.removeValue(forKey: paneID)
        } else {
            _ = updateAgentResumeBinding(nil, for: paneID)
        }
        agentResumePresentations.removeValue(forKey: paneID)
        revokeManagedOrigin(paneID)

        if surfaces[paneID] == nil {
            do {
                let surface = try makeConfiguredSurface(
                    id: paneID,
                    configuration: savedRestoreSurfaceConfiguration(for: pane)
                )
                surfaces[paneID] = surface
                surfaceFailures.removeValue(forKey: paneID)
                installSurfaceActivityHandlers()
            } catch {
                surfaceFailures[paneID] = SurfaceFailurePresentation(
                    message: error.localizedDescription
                )
                resetBroadcastingForRestoreFailure(pane)
            }
        }

        if activeTab?.root.contains(paneID) == true {
            refreshWorkspacePresentation(focusTerminal: activePaneID == paneID)
        }
    }

    private func closeUnavailablePane(_ paneID: PaneID) {
        guard !isPreparingForTermination, surfaces[paneID] == nil,
            workspaceStore.workspaces.contains(where: { workspace in
                workspace.tabs.contains(where: { $0.root.contains(paneID) })
            }),
            closingPaneIDs.insert(paneID).inserted
        else {
            return
        }
        defer { closingPaneIDs.remove(paneID) }

        confirmationQueue.invalidatePane(paneID)
        #if DEBUG
            if let hook = closeUnavailablePaneDidBeginHookForTesting {
                closeUnavailablePaneDidBeginHookForTesting = nil
                hook(paneID)
            }
        #endif

        guard surfaces[paneID] == nil else { return }
        let ownership = workspaceStore.workspaces.lazy.compactMap { workspace in
            workspace.tabs.first(where: { $0.root.contains(paneID) }).map { (workspace, $0) }
        }.first
        guard let (owningWorkspace, owningTab) = ownership else { return }

        let ownerWorkspaceWasActive = owningWorkspace.id == workspaceStore.activeWorkspaceID
        let ownerTabWasActive = owningWorkspace.activeTabID == owningTab.id
        var candidate = workspaceStore
        do {
            _ = try splitCoordinator.apply(
                .closePane(
                    workspaceID: owningWorkspace.id,
                    tabID: owningTab.id,
                    paneID: paneID
                ),
                to: &candidate
            )
        } catch {
            return
        }

        guard commitWorkspaceStore(candidate) else { return }
        guard !isPreparingForTermination else { return }
        cleanUpPaneLifecycle(paneID)
        surfaceFailures.removeValue(forKey: paneID)
        agentResumePresentations.removeValue(forKey: paneID)
        if let attempt = agentResumeAttempts.removeValue(forKey: paneID) {
            agentResumeRuntime.surfaceDidClose(attempt.reference)
        }
        guard !isPreparingForTermination, ownerWorkspaceWasActive else { return }
        guard ownerTabWasActive else {
            workspaceViewController.apply(
                workspaceStore,
                liveTitles: liveSurfaceTitles,
                paneStatuses: terminalActivityController.statuses
            )
            synchronizeTerminalAcknowledgements()
            return
        }

        let shouldFocus: Bool
        if let activeTabID = workspaceStore.workspace(id: owningWorkspace.id)?.activeTabID,
            let correctedActivePaneID = workspaceStore.tab(id: activeTabID)?.activePaneID,
            surfaces[correctedActivePaneID] != nil
        {
            shouldFocus = true
        } else {
            shouldFocus = false
        }
        refreshWorkspacePresentation(focusTerminal: shouldFocus)
    }

    func applyConfigurationDiagnostics(_ presentation: ConfigDiagnosticPresentation?) {
        guard !isPreparingForTermination else { return }
        workspaceViewController.applyConfigurationDiagnostics(presentation)
    }

    func applyConfiguration(_ config: QuickTTYConfig) {
        guard !isPreparingForTermination else { return }
        shouldRestoreAgentSessions = config.shouldRestoreAgentSessions
        workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
        workspaceViewController.applySplitAppearance(ghosttyBridge.splitAppearance)
        activityConfiguration = ghosttyBridge.activityConfiguration
        if !activityConfiguration.progressStyleEnabled {
            clearTerminalActivity()
        }
        configEditor = config.configEditor
        let geometry =
            QuakeWindowGeometry(
                heightFraction: config.quakeHeight,
                padding: config.quakePadding
            ) ?? QuakeWindowConfiguration().geometry
        quakeWindowController.updateConfiguration(
            QuakeWindowConfiguration(
                geometry: geometry,
                animationDuration: config.quakeAnimationDuration,
                hideOnFocusLoss: config.hideOnFocusLoss,
                pinToScreen: config.quakePinToScreen
            )
        )

        configuredGlobalChord = config.globalToggle
        do {
            try transitionPresentation(to: config.presentationMode, persist: false)
            guard !isPreparingForTermination else { return }
            if presentationMode == .quake {
                try hotKeyController.replace(with: configuredGlobalChord)
            } else {
                try hotKeyController.unregister()
            }
        } catch {
            onError(error)
        }
        synchronizeTabRenameTransientInteraction()
    }

    func togglePresentationMode() {
        guard !isPreparingForTermination else { return }
        let target: PresentationMode = presentationMode == .normal ? .quake : .normal
        do {
            try transitionPresentation(to: target)
            guard !isPreparingForTermination else { return }
            menuBarManager.applyMode(target)
            if target == .quake {
                try hotKeyController.replace(with: configuredGlobalChord)
            } else {
                try hotKeyController.unregister()
            }
        } catch {
            onError(error)
        }
        synchronizeTabRenameTransientInteraction()
    }

    private func transitionPresentation(
        to target: PresentationMode,
        persist: Bool = true
    ) throws {
        guard !isPreparingForTermination, target != presentationMode else { return }
        terminalAutomationCoordinator.cancelPendingPermissions()
        guard !isPreparingForTermination else { return }
        terminalControlPermissionController.cancel()
        guard !isPreparingForTermination else { return }
        let wasPresented = agentIntegrationsSheetController?.detachForWindowTransition() ?? false
        // WHY: Ending a native sheet may reenter persistence; do not start a host transition
        // after that callback has frozen the coordinator.
        guard !isPreparingForTermination else { return }
        do {
            try presentationController.transition(to: target, persist: persist)
        } catch {
            if !isPreparingForTermination, let window = activeWindow {
                agentIntegrationsSheetController?.reattachAfterWindowTransition(
                    to: window,
                    wasPresented: wasPresented
                )
            }
            throw error
        }
        if !isPreparingForTermination, let window = activeWindow {
            agentIntegrationsSheetController?.reattachAfterWindowTransition(
                to: window,
                wasPresented: wasPresented
            )
        }
    }

    private func configurePresentationCallbacks() {
        workspaceViewController.onActivateWorkspace = { [weak self] workspaceID in
            self?.activateWorkspace(id: workspaceID)
        }
        workspaceViewController.onCreateWorkspace = { [weak self] in
            self?.presentCreateWorkspace()
        }
        workspaceViewController.onRenameWorkspace = { [weak self] in
            self?.presentRenameWorkspace()
        }
        workspaceViewController.onDeleteWorkspace = { [weak self] in
            self?.requestDeleteActiveWorkspace()
        }
        workspaceViewController.onWorkspaceMenuTrackingChanged = { [weak self] isTracking in
            self?.setWorkspaceMenuTracking(isTracking)
        }
        workspaceViewController.onActivateTab = { [weak self] tabID in
            guard let self else { return }
            var candidate = workspaceStore
            do {
                try candidate.activateTab(tabID, in: candidate.activeWorkspaceID)
            } catch {
                return
            }
            guard commitWorkspaceStore(candidate) else { return }
            refreshWorkspacePresentation(focusTerminal: true)
        }
        workspaceViewController.onCloseTab = { [weak self] tabID in
            self?.requestCloseTab(tabID)
        }
        workspaceViewController.onToggleBroadcast = { [weak self] in
            self?.toggleBroadcast()
        }
        workspaceViewController.onMoveToNewWorkspace = { [weak self] tabIDs in
            self?.presentMoveToNewWorkspace(tabIDs)
        }
        workspaceViewController.onMoveToWorkspace = { [weak self] tabIDs, workspaceID in
            self?.moveTabs(tabIDs, to: workspaceID)
        }
        workspaceViewController.onReorderTabs = { [weak self] tabIDs, activeTabID in
            guard let self else { return false }
            return reorderTabs(tabIDs, activeTabID: activeTabID)
        }
        workspaceViewController.onFinishReorderTabs = { [weak self] in
            self?.finishTabReorder()
        }
        workspaceViewController.onRenameTab = { [weak self] tabID, title in
            self?.commitTabRename(tabID, title: title)
        }
        workspaceViewController.onRenameEditingChanged = { [weak self] isEditing in
            self?.setTabRenameEditing(isEditing)
        }
        workspaceViewController.onWindowKeyStateChanged = { [weak self] _ in
            self?.synchronizeTerminalAcknowledgements()
        }
    }

    private func commitTabRename(_ tabID: TabID, title: String) {
        // WHY: Ending native editing during dismissal must not persist a late rename.
        guard !isPreparingForTermination,
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID),
            let tab = workspace.tabs.first(where: { $0.id == tabID }),
            surfaces[tab.activePaneID] != nil
        else { return }
        var candidate = workspaceStore
        guard (try? candidate.setTitleOverride(title, for: tabID)) != nil else { return }
        _ = commitWorkspaceStore(candidate)
        refreshWorkspaceTitlePresentation()
    }

    private func setTabRenameEditing(_ isEditing: Bool) {
        guard isEditing != isTabRenameEditing else { return }
        isTabRenameEditing = isEditing
        synchronizeTabRenameTransientInteraction()
        guard !isEditing, !isPreparingForTermination,
            let paneID = activePaneID,
            let surface = surfaces[paneID]
        else { return }
        focus(surface, paneID: paneID)
    }

    private func synchronizeTabRenameTransientInteraction() {
        if isTabRenameEditing, presentationMode == .quake {
            guard tabRenameTransientInteraction == nil else { return }
            tabRenameTransientInteraction = quakeWindowController.beginTransientInteraction()
            return
        }
        tabRenameTransientInteraction?.end()
        tabRenameTransientInteraction = nil
    }

    private func setWorkspaceMenuTracking(_ isTracking: Bool) {
        if isTracking {
            guard presentationMode == .quake, workspaceMenuTransientInteraction == nil else {
                return
            }
            workspaceMenuTransientInteraction = quakeWindowController.beginTransientInteraction()
            return
        }

        endWorkspaceMenuTracking()
    }

    private func endWorkspaceMenuTracking() {
        workspaceMenuTransientInteraction?.end()
        workspaceMenuTransientInteraction = nil
    }

    private enum PaneFocusCommand {
        case previous
        case next
        case direction(SplitFocusDirection)
    }

    private func focusActivePane(using command: PaneFocusCommand) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            tab.root.leaves.count > 1
        else { return }

        var candidate = workspaceStore
        let splitCommand: SplitCommand =
            switch command {
            case .previous:
                .focusPrevious(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID
                )
            case .next:
                .focusNext(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID
                )
            case .direction(let direction):
                .focus(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID,
                    direction: direction
                )
            }
        let delta: SplitDelta
        do {
            delta = try splitCoordinator.apply(splitCommand, to: &candidate)
        } catch {
            return
        }

        guard case .focusChanged(_, _, let sourcePaneID, let destinationPaneID) = delta,
            sourcePaneID != destinationPaneID,
            surfaces[destinationPaneID] != nil
        else { return }

        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    private var activeTab: TerminalTab? {
        workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)?
            .activeTabID
            .flatMap { workspaceStore.tab(id: $0) }
    }

    private var activePaneID: PaneID? {
        activeTab?.activePaneID
    }

    private var liveSurfaceTitles: [PaneID: String] {
        Dictionary(
            uniqueKeysWithValues: surfaces.compactMap { entry in
                guard let title = entry.value.currentTitle else { return nil }
                return (entry.key, title)
            }
        )
    }

    private func liveOwningTab(for paneID: PaneID) -> TerminalTab? {
        liveOwnership(for: paneID)?.tab
    }

    private func liveOwnership(for paneID: PaneID) -> (workspace: Workspace, tab: TerminalTab)? {
        guard surfaces[paneID] != nil else { return nil }
        for workspace in workspaceStore.workspaces {
            if let tab = workspace.tabs.first(where: { $0.root.contains(paneID) }) {
                return (workspace, tab)
            }
        }
        return nil
    }

    private func refreshWorkspaceTitlePresentation() {
        guard !isPreparingForTermination else { return }
        workspaceViewController.refreshTabTitles(
            in: workspaceStore,
            liveTitles: liveSurfaceTitles
        )
    }

    private var activeTerminalAutomationPresentations: [PaneID: TerminalAutomationPresentation] {
        var presentations: [PaneID: TerminalAutomationPresentation] = [:]
        for paneID in activeTab?.root.leaves ?? [] {
            guard let taskID = managedTaskIDByPane[paneID], let record = managedTasks[taskID] else {
                continue
            }
            // WHY: Domain accept/revoke/forget callbacks mirror eligibility without revalidating
            // or mutating domain records while rendering. The action still checks the exact grant.
            let canReturn =
                record.hasDomainAcceptance && !record.isRevoked
                && !record.completionObserved && !isPreparingForTermination
                && record.task.owner == .user
                && (record.task.state == .running || record.task.state == .waitingForUser)
                && !closingPaneIDs.contains(paneID) && isCurrentManagedSurface(record)
                && resolvedTerminalAutomationSession(
                    record.session, in: WorkspaceID(rawValue: record.task.workspaceID)) != nil
            presentations[paneID] = TerminalAutomationPresentation(
                taskID: taskID,
                adapterDisplayName: AgentIntegrationRegistry.definition(
                    for: record.session.adapterID)?
                    .displayName ?? "Agent",
                taskState: record.task.state,
                controlOwner: record.task.owner,
                isRevoked: record.isRevoked,
                canReturnControl: canReturn
            )
        }
        return presentations
    }

    private func scheduleManagedPresentationRefresh() {
        guard !isPreparingForTermination, managedPresentationRefreshTask == nil else { return }
        // WHY: Manual takeover must finish before native input, and lifecycle callbacks may
        // still be inside a model commit. Coalesce only visual changes onto the next actor turn.
        managedPresentationRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !isPreparingForTermination else { return }
            managedPresentationRefreshTask = nil
            workspaceViewController.refreshTerminalAutomationPresentations(
                activeTerminalAutomationPresentations)
        }
    }

    private func returnControlFromPresentation(taskID: UUID) {
        guard let record = managedTasks[taskID],
            activeTab?.root.contains(PaneID(rawValue: record.task.paneID)) == true
        else { return }
        _ = returnControlToAgent(taskID: taskID)
    }

    private func refreshWorkspacePresentation(focusTerminal: Bool) {
        // WHY: Some callers refresh after an ignored/reentrant commit; freeze must not rebuild
        // hosts or restore responders. Explicit teardown bypasses this presentation boundary.
        guard !isPreparingForTermination else { return }
        #if DEBUG
            refreshWorkspacePresentationInvocationCountForTestingStorage += 1
        #endif
        workspaceViewController.apply(
            workspaceStore,
            liveTitles: liveSurfaceTitles,
            paneStatuses: terminalActivityController.statuses
        )
        guard !isPreparingForTermination else { return }
        let activePaneIDs = activeTab?.root.leaves ?? []
        let activeTabSurfaces = Dictionary(
            uniqueKeysWithValues: activePaneIDs.compactMap { paneID in
                surfaces[paneID].map { (paneID, $0) }
            }
        )
        let activeSurfaceFailures = Dictionary(
            uniqueKeysWithValues: activePaneIDs.compactMap { paneID in
                surfaceFailures[paneID].map { (paneID, $0) }
            }
        )
        let activeAgentResumePresentations = Dictionary(
            uniqueKeysWithValues: activePaneIDs.compactMap { paneID in
                agentResumePresentations[paneID].map { (paneID, $0) }
            }
        )
        let surface = activePaneID.flatMap { activeTabSurfaces[$0] }
        let retryUnavailablePaneCallback: (PaneID) -> Void = { [weak self] paneID in
            self?.retryUnavailablePane(paneID)
        }
        let closeUnavailablePaneCallback: (PaneID) -> Void = { [weak self] paneID in
            self?.closeUnavailablePane(paneID)
        }
        #if DEBUG
            retryUnavailablePanePresentationCallbackForTesting = retryUnavailablePaneCallback
            closeUnavailablePanePresentationCallbackForTesting = closeUnavailablePaneCallback
        #endif
        workspaceViewController.displayTerminal(
            root: activeTab?.root,
            surfaces: activeTabSurfaces,
            failures: activeSurfaceFailures,
            agentResumePresentations: activeAgentResumePresentations,
            terminalAutomationPresentations: activeTerminalAutomationPresentations,
            palette: ghosttyBridge.chromePalette,
            activePaneID: activePaneID,
            splitAppearance: ghosttyBridge.splitAppearance,
            onResize: { [weak self] splitID, ratio in
                self?.updateActiveSplitRatio(id: splitID, ratio: ratio)
            },
            onEqualize: { [weak self] splitID in
                self?.equalizeActiveSplits(triggeredBy: splitID)
            },
            onRetryUnavailablePane: retryUnavailablePaneCallback,
            onCloseUnavailablePane: closeUnavailablePaneCallback,
            onRetryAgentResume: { [weak self] paneID in
                self?.retryAgentResume(paneID)
            },
            onForgetAgentResume: { [weak self] paneID in
                self?.forgetAgentResume(paneID)
            },
            onReturnControlToAgent: { [weak self] taskID in
                self?.returnControlFromPresentation(taskID: taskID)
            }
        )
        if focusTerminal, let surface, let paneID = activePaneID {
            focus(surface, paneID: paneID)
        }
        synchronizeTerminalAcknowledgements()
    }

    private func focus(
        _ surface: GhosttySurfaceView,
        paneID: PaneID,
        retryingAfterPresentation: Bool = false
    ) {
        guard !isPreparingForTermination, let window = activeWindow else { return }
        guard surface.window === window else {
            guard !retryingAfterPresentation else { return }
            DispatchQueue.main.async { [weak self, weak surface] in
                guard let self, !self.isPreparingForTermination,
                    let surface, self.activePaneID == paneID
                else { return }
                self.focus(surface, paneID: paneID, retryingAfterPresentation: true)
            }
            return
        }
        window.makeFirstResponder(surface)
    }

    private func surfaceDidBecomeFirstResponder(id paneID: PaneID) {
        guard !isPreparingForTermination else { return }
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            tab.root.contains(paneID),
            tab.activePaneID != paneID,
            surfaces[paneID] != nil
        else {
            return
        }

        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .activatePane(workspaceID: workspaceID, tabID: tabID, paneID: paneID),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func updateActiveSplitRatio(id splitID: UUID, ratio: Double) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID else { return }
        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .updateRatio(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    splitID: splitID,
                    ratio: ratio
                ),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func equalizeActiveSplits(triggeredBy splitID: UUID) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID,
            workspaceStore.tab(id: tabID)?.root.contains(splitID: splitID) == true
        else {
            return
        }
        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .equalize(workspaceID: workspaceID, tabID: tabID),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func presentCreateWorkspace() {
        guard !isPreparingForTermination,
            createWorkspaceController == nil, let window = activeWindow
        else { return }

        let controller = CreateWorkspaceController(
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.map(\.name) ?? []
            },
            submit: { [weak self] name in
                guard let self, !isPreparingForTermination else {
                    return .failure(.workspaceNotFound(WorkspaceID()))
                }
                var candidate = workspaceStore
                do {
                    let workspaceID = try candidate.createWorkspace(named: name)
                    try candidate.activateWorkspace(workspaceID)
                    let prepared = try prepareShellTab(
                        in: workspaceID,
                        candidate: &candidate,
                        surfaceContext: .newTab
                    )
                    surfaces[prepared.paneID] = prepared.surface
                    installSurfaceActivityHandlers()
                    guard commitWorkspaceStore(candidate) else {
                        closeCreatedSurface(id: prepared.paneID)
                        surfaces.removeValue(forKey: prepared.paneID)
                        return .failure(.workspaceNotFound(workspaceID))
                    }
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    onError(error)
                    return .failure(.workspaceNotFound(candidate.activeWorkspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func presentRenameWorkspace() {
        guard
            !isPreparingForTermination,
            createWorkspaceController == nil,
            let window = activeWindow,
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)
        else {
            return
        }
        let workspaceID = workspace.id
        let controller = CreateWorkspaceController(
            title: "Rename Workspace",
            initialName: workspace.name,
            buttonTitle: "Rename",
            errorMessage: "The workspace could not be renamed.",
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.compactMap { workspace in
                    workspace.id == workspaceID ? nil : workspace.name
                } ?? []
            },
            submit: { [weak self] name in
                guard let self, !isPreparingForTermination,
                    workspaceStore.activeWorkspaceID == workspaceID
                else {
                    return .failure(.workspaceNotFound(workspaceID))
                }
                var candidate = workspaceStore
                do {
                    try candidate.renameWorkspace(workspaceID, to: name)
                    guard commitWorkspaceStore(candidate) else { return .success(()) }
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    return .failure(.workspaceNotFound(workspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func presentWorkspaceEditor(
        _ controller: CreateWorkspaceController,
        for window: NSWindow
    ) {
        // WHY: All workspace editors share this last boundary before ownership and AppKit focus.
        guard !isPreparingForTermination else { return }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.createWorkspaceController === controller else { return }
            self?.createWorkspaceController = nil
        }
        createWorkspaceController = controller
        controller.presentSheet(for: window)
    }

    private func requestDeleteActiveWorkspace() {
        requestDeleteWorkspace(workspaceStore.activeWorkspaceID)
    }

    private func requestDeleteWorkspace(_ workspaceID: WorkspaceID) {
        guard
            !isPreparingForTermination,
            pendingWorkspaceDeletionID == nil,
            workspaceID == workspaceStore.activeWorkspaceID,
            workspaceStore.workspaces.count > 1,
            let workspace = workspaceStore.workspace(id: workspaceID)
        else {
            return
        }

        let paneCount = workspace.tabs.reduce(into: 0) { count, tab in
            count += tab.root.leaves.count
        }
        guard paneCount > 0 else {
            deleteWorkspace(workspaceID)
            return
        }

        let confirmation = WorkspaceDeletionConfirmation(
            workspaceID: workspaceID,
            workspaceName: workspace.name,
            tabCount: workspace.tabs.count,
            paneCount: paneCount
        )
        pendingWorkspaceDeletionID = workspaceID
        let completion: @MainActor (Bool) -> Void = { [weak self] allowed in
            self?.resolveWorkspaceDeletion(workspaceID, allowed: allowed)
        }
        if let workspaceDeletionConfirmationPresenter {
            workspaceDeletionConfirmationPresenter(confirmation, completion)
        } else {
            presentWorkspaceDeletionConfirmation(confirmation, completion: completion)
        }
    }

    private func resolveWorkspaceDeletion(_ workspaceID: WorkspaceID, allowed: Bool) {
        guard pendingWorkspaceDeletionID == workspaceID else { return }
        pendingWorkspaceDeletionID = nil
        guard allowed else { return }
        deleteWorkspace(workspaceID)
    }

    private func deleteWorkspace(_ workspaceID: WorkspaceID) {
        // WHY: A retained confirmation must not detach the selected workspace after freeze.
        guard !isPreparingForTermination,
            workspaceID == workspaceStore.activeWorkspaceID,
            workspaceStore.workspaces.count > 1
        else {
            return
        }
        var candidate = workspaceStore
        let removedWorkspace: Workspace
        do {
            removedWorkspace = try candidate.deleteWorkspace(workspaceID)
        } catch {
            return
        }

        guard detachActiveWorkspacePresentation() else { return }
        for paneID in removedWorkspace.tabs.flatMap(\.root.leaves) {
            guard !isPreparingForTermination else { return }
            if surfaces[paneID] != nil {
                guard removeSurface(id: paneID, closeBridgeSurface: true) else { return }
            } else {
                if let attempt = agentResumeAttempts.removeValue(forKey: paneID) {
                    agentResumeRuntime.surfaceDidClose(attempt.reference)
                }
                guard !isPreparingForTermination else { return }
                cleanUpPaneLifecycle(paneID)
            }
            // WHY: Removal can reenter too; do not clean up another pane or commit deletion
            // after freeze. An already executing native operation may itself finish.
            guard !isPreparingForTermination else { return }
            surfaceFailures.removeValue(forKey: paneID)
            agentResumePresentations.removeValue(forKey: paneID)
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    // WHY: Ending a fully active rename can persist and freeze inside AppKit. Returning
    // early from a Void helper does not cancel its caller's model/runtime removal.
    private func detachActiveWorkspacePresentation() -> Bool {
        guard !isPreparingForTermination else { return false }
        if let window = activeWindow, !window.makeFirstResponder(nil) { return false }
        guard !isPreparingForTermination else { return false }
        workspaceViewController.displayTerminal(
            root: nil,
            surfaces: [:],
            failures: [:],
            palette: ghosttyBridge.chromePalette,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        // WHY: Host updates are callback-capable as well as responder changes.
        return !isPreparingForTermination
    }

    private func presentWorkspaceDeletionConfirmation(
        _ confirmation: WorkspaceDeletionConfirmation,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isPreparingForTermination, let window = activeWindow else {
            completion(false)
            return
        }
        let alert = Self.makeWorkspaceDeletionAlert(confirmation)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    static func makeWorkspaceDeletionAlert(_ confirmation: WorkspaceDeletionConfirmation) -> NSAlert
    {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Workspace?"
        alert.informativeText =
            "\(confirmation.workspaceName) contains \(confirmation.tabCount) \(pluralized(confirmation.tabCount, singular: "tab", plural: "tabs")) and \(confirmation.paneCount) \(pluralized(confirmation.paneCount, singular: "pane", plural: "panes")). All of its terminals will be closed."
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1B}"
        return alert
    }

    private static func pluralized(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? singular : plural
    }

    private func presentMoveToNewWorkspace(_ tabIDs: [TabID]) {
        guard !isPreparingForTermination, !tabIDs.isEmpty,
            createWorkspaceController == nil, let window = activeWindow
        else { return }
        let sourceWorkspaceID = workspaceStore.activeWorkspaceID
        let controller = CreateWorkspaceController(
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.map(\.name) ?? []
            },
            submit: { [weak self] name in
                guard let self, !isPreparingForTermination else {
                    return .failure(.workspaceNotFound(sourceWorkspaceID))
                }
                var updatedStore = workspaceStore
                do {
                    let destinationID = try updatedStore.createWorkspace(named: name)
                    try updatedStore.moveTabs(
                        tabIDs,
                        from: sourceWorkspaceID,
                        to: destinationID
                    )
                    guard commitWorkspaceStore(updatedStore) else {
                        return .success(())
                    }
                    // WHY: The commit remains successful if persistence froze reentrantly.
                    guard !isPreparingForTermination else { return .success(()) }
                    workspaceViewController.tabBarViewController.clearSelectionAfterMove()
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    return .failure(.workspaceNotFound(sourceWorkspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func moveTabs(_ tabIDs: [TabID], to destinationWorkspaceID: WorkspaceID) {
        let sourceWorkspaceID = workspaceStore.activeWorkspaceID
        var candidate = workspaceStore
        do {
            try candidate.moveTabs(
                tabIDs,
                from: sourceWorkspaceID,
                to: destinationWorkspaceID
            )
            guard commitWorkspaceStore(candidate) else { return }
            guard !isPreparingForTermination else { return }
            workspaceViewController.tabBarViewController.clearSelectionAfterMove()
            refreshWorkspacePresentation(focusTerminal: true)
        } catch {
            NSSound.beep()
        }
    }

    private func reorderTabs(_ orderedTabIDs: [TabID], activeTabID: TabID) -> Bool {
        let workspaceID = workspaceStore.activeWorkspaceID
        var candidate = workspaceStore
        do {
            try candidate.reorderTabs(orderedTabIDs, in: workspaceID)
            try candidate.activateTab(activeTabID, in: workspaceID)
        } catch {
            return false
        }
        guard candidate != workspaceStore, commitWorkspaceStore(candidate) else { return false }
        return true
    }

    private func finishTabReorder() {
        guard !isPreparingForTermination else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    private func requestClosePane(
        _ paneID: PaneID,
        requiresConfirmation: Bool
    ) {
        // WHY: Enqueueing a close can preempt an existing clipboard sheet before presentation.
        guard !isPreparingForTermination, surfaces[paneID] != nil else { return }
        guard requiresConfirmation else {
            finishSurfaceClosure(id: paneID, closeBridgeSurface: true)
            return
        }

        confirmationQueue.enqueueClose(paneID: paneID) { [weak self] response in
            guard response == .allow, let self else { return }
            finishSurfaceClosure(id: paneID, closeBridgeSurface: true)
        }
    }

    private func requestCloseTab(_ tabID: TabID) {
        guard !isPreparingForTermination, let tab = workspaceStore.tab(id: tabID) else { return }
        let paneIDs = tab.root.leaves
        if let confirmationPaneID = paneIDs.first(where: {
            ghosttyBridge.surfaceNeedsConfirmQuit(id: $0)
        }) {
            confirmationQueue.enqueueClose(paneID: confirmationPaneID) { [weak self] response in
                guard response == .allow else { return }
                self?.closeTab(tabID, paneIDs: paneIDs)
            }
            return
        }
        closeTab(tabID, paneIDs: paneIDs)
    }

    private func closeTab(_ tabID: TabID, paneIDs: [PaneID]) {
        guard !isPreparingForTermination, closingTabIDs.insert(tabID).inserted else { return }
        defer { closingTabIDs.remove(tabID) }
        guard
            let owner = workspaceStore.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tabID })
            }),
            paneIDs.allSatisfy({ surfaces[$0] != nil })
        else {
            return
        }
        let newlyClosingPaneIDs = paneIDs.filter { closingPaneIDs.insert($0).inserted }
        guard newlyClosingPaneIDs.count == paneIDs.count else {
            for paneID in newlyClosingPaneIDs {
                closingPaneIDs.remove(paneID)
            }
            return
        }
        defer {
            for paneID in newlyClosingPaneIDs {
                closingPaneIDs.remove(paneID)
            }
        }

        var candidate = workspaceStore
        do {
            try candidate.closeTab(tabID, in: owner.id)
        } catch {
            return
        }

        let requiresReplacement = candidate.workspace(id: owner.id)?.tabs.isEmpty == true
        let replacement: (paneID: PaneID, surface: GhosttySurfaceView)?
        if requiresReplacement {
            do {
                replacement = try prepareShellTab(
                    in: owner.id,
                    candidate: &candidate,
                    surfaceContext: .newTab
                )
            } catch {
                // WHY: Frozen creation already released its temporary surface; keep the old tab
                // intact instead of treating cancellation as an ordinary replacement failure.
                guard !isPreparingForTermination else { return }
                for paneID in paneIDs {
                    guard removeSurface(id: paneID, closeBridgeSurface: true) else { return }
                }
                _ = commitWorkspaceStore(candidate)
                refreshWorkspacePresentation(focusTerminal: owner.id == candidate.activeWorkspaceID)
                guard !isPreparingForTermination else { return }
                if ghosttyBridge.activeSurfaceCount == 0, presentationMode == .normal {
                    normalWindowController.close()
                }
                onError(error)
                return
            }
        } else {
            replacement = nil
        }

        for paneID in paneIDs {
            guard removeSurface(id: paneID, closeBridgeSurface: true) else {
                if let replacement {
                    closeCreatedSurface(id: replacement.paneID)
                }
                return
            }
        }
        if let replacement {
            surfaces[replacement.paneID] = replacement.surface
            installSurfaceActivityHandlers()
        }
        _ = commitWorkspaceStore(candidate)
        refreshWorkspacePresentation(focusTerminal: owner.id == candidate.activeWorkspaceID)
        guard !isPreparingForTermination else { return }
        if ghosttyBridge.activeSurfaceCount == 0, presentationMode == .normal {
            normalWindowController.close()
        }
    }

    @discardableResult
    private func removeSurface(
        id: PaneID,
        closeBridgeSurface: Bool,
        preserveAgentPresentation: Bool = false,
        allowDuringTermination: Bool = false
    ) -> Bool {
        guard !isPreparingForTermination || allowDuringTermination,
            surfaces[id] != nil
        else { return false }
        let insertedClosingID = closingPaneIDs.insert(id).inserted
        defer { if insertedClosingID { closingPaneIDs.remove(id) } }
        if let taskID = managedTaskIDByPane[id], let decision = managedCloseDecisions[taskID] {
            cancelManagedClose(taskID: taskID, decision: decision)
        }
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        retainManagedClosure(paneID: id, allowDuringTermination: allowDuringTermination)
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        revokeManagedOrigin(id)
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        if let attempt = agentResumeAttempts.removeValue(forKey: id) {
            agentResumeRuntime.surfaceDidClose(attempt.reference)
        }
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        if !preserveAgentPresentation {
            agentResumePresentations.removeValue(forKey: id)
        }
        agentSessionController?.revoke(paneID: id)
        cleanUpPaneLifecycle(id)
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        if !isPreparingForTermination {
            installSurfaceActivityHandlers()
        }
        confirmationQueue.invalidatePane(id)
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        // WHY: Keep the live surface discoverable for intentional teardown if any of the
        // callbacks above freeze. Once native close begins it may finish, but not its caller.
        surfaces.removeValue(forKey: id)
        if closeBridgeSurface {
            ghosttyBridge.closeSurface(id: id)
        }
        return !isPreparingForTermination || allowDuringTermination
    }

    func freezeTerminalControlForApplicationTermination() {
        guard !isTerminalControlFrozen else { return }
        // WHY: Revoking successful close-on-success tasks must not detach panes before persistence.
        isTerminalControlFrozen = true
        isPreparingForTermination = true
        // WHY: Native callers continue after coordinator callbacks return. Retire their
        // deferred work before any other freeze callback, without changing visible UI.
        presentationController.retireForApplicationTermination()
        normalWindowController.retireForApplicationTermination()
        workspaceViewController.tabBarViewController.retireForApplicationTermination()
        createWorkspaceController?.retireForApplicationTermination()
        quakeWindowController.invalidateForApplicationTermination()
        cancelAgentIntegrationUpdateOffer(onlyIfPending: false)
        // WHY: Late focus must not change the selection before the final application snapshot.
        ghosttyBridge.surfaceFocusHandler = nil
        ghosttyBridge.surfaceProcessExitedHandler = nil
        managedPresentationRefreshTask?.cancel()
        managedPresentationRefreshTask = nil
        let origins = Set(agentCredentialGenerationByPane.keys)
            .union(managedTasks.values.map { $0.session.originPaneID })
        for origin in origins { revokeManagedOrigin(origin) }
        terminalAutomationCoordinator.cancelPendingPermissions()
        terminalControlPermissionController.cancel()
    }

    func prepareForApplicationTermination() {
        freezeTerminalControlForApplicationTermination()
        ghosttyBridge.manualInputHandler = nil
        terminalAutomationPresentationHandler = nil
        terminalAutomationAttentionHandler = nil
        cancelAgentIntegrationUpdateOffer(onlyIfPending: false)
        terminalActivityController.scheduledEffectHandler = nil
        terminalActivityEffectHandler = nil
        clearTerminalActivity()
        terminalNotificationController?.shutdown()
        terminalNotificationController = nil
        tearDownSurfaces()
        ghosttyBridge.surfaceProgressHandler = nil
        ghosttyBridge.surfaceCommandFinishedHandler = nil
        ghosttyBridge.surfaceProcessExitedHandler = nil
    }

    #if DEBUG
        var windowForTesting: NSWindow? {
            normalWindowController.window
        }

        var presentationControllerForTesting: PresentationController {
            presentationController
        }

        var normalWindowControllerForTesting: NormalWindowController {
            normalWindowController
        }

        var activeWindowForTesting: NSWindow? {
            activeWindow
        }

        var quakeVisibilityForTesting: QuakeVisibility {
            quakeWindowController.requestedVisibility
        }

        func requestQuakeVisibilityForTesting(_ visibility: QuakeVisibility) throws {
            try presentationController.requestQuakeVisibility(visibility)
        }

        var workspaceViewControllerForTesting: WorkspaceViewController {
            workspaceViewController
        }

        var configEditorForTesting: String {
            configEditor
        }

        var defaultSurfaceForTesting: GhosttySurfaceView? {
            activeSurfaceForTesting
        }

        var isWorkspaceMenuTrackingForTesting: Bool {
            workspaceMenuTransientInteraction != nil
        }

        var isTabRenameEditingForTesting: Bool {
            isTabRenameEditing
        }

        var quakeTransientInteractionCountForTesting: Int {
            quakeWindowController.transientInteractionCountForTesting
        }

        var activeSurfaceForTesting: GhosttySurfaceView? {
            activePaneID.flatMap { surfaces[$0] }
        }

        var surfaceIDsForTesting: [PaneID] {
            surfaces.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }

        var surfaceFailureIDsForTesting: [PaneID] {
            surfaceFailures.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }

        var surfaceFailureMessagesForTesting: [PaneID: String] {
            surfaceFailures.mapValues(\.message)
        }

        var agentResumePresentationsForTesting: [PaneID: AgentResumePresentation] {
            agentResumePresentations
        }

        var agentResumeDateForTesting: Date {
            agentResumeScheduler.date
        }

        func paneAuthorizationEpochForTesting(_ paneID: PaneID) -> UInt64? {
            agentCredentialGenerationByPane[paneID]
        }

        func agentResumeAttemptReferenceForTesting(
            _ paneID: PaneID
        ) -> AgentResumeAttemptReference? {
            agentResumeAttempts[paneID]?.reference
        }

        func agentResumeHasClaimForTesting(_ binding: AgentResumeBinding) -> Bool {
            agentResumeRuntime.hasClaim(
                AgentResumeClaimKey(
                    adapterID: binding.adapterID,
                    sessionID: binding.sessionID
                )
            )
        }

        func processAgentResumeExitForTesting(
            _ reference: AgentResumeAttemptReference
        ) {
            agentResumeRuntime.processExited(reference)
        }

        func surfaceForTesting(id paneID: PaneID) -> GhosttySurfaceView? {
            surfaces[paneID]
        }

        func clearSurfaceFailureForTesting(_ paneID: PaneID) {
            surfaceFailures.removeValue(forKey: paneID)
        }

        func retryUnavailablePaneForTesting(_ paneID: PaneID) {
            retryUnavailablePane(paneID)
        }

        func retryAgentResumeForTesting(_ paneID: PaneID) {
            retryAgentResume(paneID)
        }

        func forgetAgentResumeForTesting(_ paneID: PaneID) {
            forgetAgentResume(paneID)
        }

        func invokeRetryUnavailablePanePresentationCallbackForTesting(_ paneID: PaneID) {
            retryUnavailablePanePresentationCallbackForTesting?(paneID)
        }

        func invokeCloseUnavailablePanePresentationCallbackForTesting(_ paneID: PaneID) {
            closeUnavailablePanePresentationCallbackForTesting?(paneID)
        }

        func setCloseUnavailablePaneDidBeginHookForTesting(
            _ hook: @escaping (PaneID) -> Void
        ) {
            closeUnavailablePaneDidBeginHookForTesting = hook
        }

        var refreshWorkspacePresentationInvocationCountForTesting: Int {
            refreshWorkspacePresentationInvocationCountForTestingStorage
        }

        var refreshWorkspaceStatusesInvocationCountForTesting: Int {
            refreshWorkspaceStatusesInvocationCountForTestingStorage
        }

        var terminalActivityStatusesForTesting: [PaneID: TerminalActivityState] {
            terminalActivityController.statuses
        }

        var terminalActivityConfigurationForTesting: GhosttyActivityConfiguration {
            activityConfiguration
        }

        func setActiveWindowIsKeyForTesting(_ isKey: Bool) {
            activeWindowIsKeyOverrideForTesting = isKey
            synchronizeTerminalAcknowledgements()
        }

        func activateTabForTesting(_ tabID: TabID) {
            var candidate = workspaceStore
            guard
                (try? candidate.activateTab(tabID, in: candidate.activeWorkspaceID)) != nil,
                commitWorkspaceStore(candidate)
            else { return }
            refreshWorkspacePresentation(focusTerminal: true)
        }

        func openConfigurationForTesting(
            at configURL: URL,
            in workspaceID: WorkspaceID
        ) throws {
            try createConfigurationTab(at: configURL, in: workspaceID)
        }

        func splitActivePaneForTesting(axis: SplitAxis) throws {
            try splitActivePane(axis: axis)
        }

        func focusActivePaneForTesting() {
            guard let paneID = activePaneID, let surface = surfaces[paneID] else { return }
            focus(surface, paneID: paneID)
        }

        func failNextStartupModelMutationForTesting() {
            failsNextStartupModelMutationForTesting = true
        }

        func failNextSplitMutationForTesting() {
            failsNextSplitMutationForTesting = true
        }

        func failNextManagedTabMutationForTesting() {
            failsNextManagedTabMutationForTesting = true
        }

        func failNextManagedSplitMutationForTesting() {
            failsNextManagedSplitMutationForTesting = true
        }

        func failNextManagedCommitForTesting() {
            failsNextManagedCommitForTesting = true
        }

        func waitForManagedPresentationForTesting() async {
            await managedPresentationRefreshTask?.value
        }

        func managedCompletionTaskForTesting(taskID: UUID) -> Task<Void, Never>? {
            managedTasks[taskID]?.completionTask
        }

        func waitForManagedCompletionForTesting(taskID: UUID) async {
            // WHY: Revocation during the final read can replace completion with deferred cleanup.
            await managedTasks[taskID]?.completionTask?.value
            if managedTasks[taskID]?.isRevoked == true {
                await managedTasks[taskID]?.completionTask?.value
            }
        }

        var managedCloseDecisionCountForTesting: Int {
            managedCloseDecisions.count
        }

        func managedTaskForTesting(taskID: UUID) -> TerminalControlTask? {
            managedTasks[taskID]?.task
        }

        func managedSplitIDForTesting(taskID: UUID) -> UUID? {
            managedTasks[taskID]?.splitID
        }

        func moveTabToNewWorkspaceForTesting(_ tabID: TabID, name: String) -> WorkspaceID? {
            guard
                let sourceWorkspaceID = workspaceStore.workspaces.first(where: {
                    $0.tabs.contains(where: { $0.id == tabID })
                })?.id
            else { return nil }
            var candidate = workspaceStore
            guard let destinationWorkspaceID = try? candidate.createWorkspace(named: name),
                (try? candidate.moveTabs(
                    [tabID],
                    from: sourceWorkspaceID,
                    to: destinationWorkspaceID
                )) != nil,
                commitWorkspaceStore(candidate)
            else {
                return nil
            }
            refreshWorkspacePresentation(focusTerminal: true)
            return destinationWorkspaceID
        }

        var managedTaskCountForTesting: Int {
            managedTasks.count
        }

        func hasPendingTerminalControlWaitForTesting(
            taskID: UUID, session: TerminalAutomationSessionIdentity
        ) -> Bool {
            !terminalAutomationCoordinator.canEvictHostTask(taskID: taskID, session: session)
        }

        var managedCompensationRecordCountForTesting: Int {
            discardedManagedTasks.count
        }

        func requestCloseTabForTesting(_ tabID: TabID) {
            requestCloseTab(tabID)
        }

        func closeTabImmediatelyForTesting(_ tabID: TabID) {
            guard let tab = workspaceStore.tab(id: tabID) else { return }
            closeTab(tabID, paneIDs: tab.root.leaves)
        }

        func presentMoveToNewWorkspaceForTesting(_ tabIDs: [TabID]) {
            presentMoveToNewWorkspace(tabIDs)
        }

        var createWorkspaceControllerForTesting: CreateWorkspaceController? {
            createWorkspaceController
        }

        func surfaceDidRequestCloseForTesting(id: PaneID, processAlive: Bool) {
            surfaceDidRequestClose(id: id, processAlive: processAlive)
        }

        func setActiveTabBroadcastingForTesting(_ isBroadcasting: Bool) throws {
            let workspaceID = workspaceStore.activeWorkspaceID
            guard let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID else { return }
            var candidate = workspaceStore
            try candidate.setBroadcasting(isBroadcasting, for: tabID, in: workspaceID)
            _ = commitWorkspaceStore(candidate)
        }

        func prepareForBridgeShutdownForTesting() {
            prepareForApplicationTermination()
        }

        var activeConfirmationForTesting: GhosttyConfirmationPresentation? {
            confirmationQueue.activePresentation
        }

        var pendingConfirmationCountForTesting: Int {
            confirmationQueue.pendingCount
        }

        func enqueueCloseConfirmationForTesting(
            _ paneID: PaneID,
            completion: @escaping GhosttyConfirmationQueue.Completion = { _ in }
        ) {
            confirmationQueue.enqueueClose(paneID: paneID, completion: completion)
        }

        var pendingWorkspaceDeletionIDForTesting: WorkspaceID? {
            pendingWorkspaceDeletionID
        }

        var workspaceStoreForTesting: WorkspaceStore {
            workspaceStore
        }

        var selectionGenerationForTesting: UInt64 {
            selectionGeneration
        }

        var agentIntegrationsSheetControllerForTesting: AgentIntegrationsSheetController? {
            agentIntegrationsSheetController
        }

        func waitForAgentIntegrationUpdateOfferForTesting() async {
            await agentIntegrationUpdateOfferTask?.value
        }

        var agentIntegrationUpdateOfferTaskForTesting: Task<Void, Never>? {
            agentIntegrationUpdateOfferTask
        }

        var hasPendingAgentIntegrationUpdateOfferForTesting: Bool {
            agentIntegrationUpdateOfferTask != nil && !isAgentIntegrationUpdateOfferPresented
        }

        var agentIntegrationBindingSnapshotsForTesting: [AgentIntegrationBindingSnapshot] {
            agentIntegrationBindingSnapshots()
        }
    #endif

    func windowDidEndLiveResize(_ notification: Notification) {
        persistNormalWindowFrameIfNeeded(from: notification)
    }

    func windowDidMove(_ notification: Notification) {
        persistNormalWindowFrameIfNeeded(from: notification)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === normalWindowController.window else { return true }
        guard !isPreparingForTermination else { return false }
        let activeSurfaceIDs = ghosttyBridge.activeSurfaceIDs
        guard !activeSurfaceIDs.isEmpty else { return true }
        guard
            let confirmationPaneID = activeSurfaceIDs.first(where: {
                ghosttyBridge.surfaceNeedsConfirmQuit(id: $0)
            })
        else {
            return closeActiveSurfaces()
        }

        let window = sender
        confirmationQueue.enqueueClose(paneID: confirmationPaneID) {
            [weak self, weak window] response in
            guard response == .allow,
                let self, !isPreparingForTermination,
                let window,
                normalWindowController.window === window
            else { return }

            guard closeActiveSurfaces() else { return }
            window.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // WHY: Native close notifications are not the later explicit termination teardown.
        guard !isPreparingForTermination else { return }
        guard let window = notification.object as? NSWindow,
            window === normalWindowController.window
        else { return }

        terminalAutomationCoordinator.cancelPendingPermissions()
        guard !isPreparingForTermination else { return }
        terminalControlPermissionController.cancel()
        guard !isPreparingForTermination else { return }
        confirmationQueue.invalidateAll()
        closeActiveSurfaces()
    }

    private func persistNormalWindowFrameIfNeeded(from notification: Notification) {
        guard !isPreparingForTermination,
            let window = notification.object as? NSWindow,
            window === normalWindowController.window,
            let frame = Self.normalWindowFrame(from: window.frame)
        else { return }

        persistNormalWindowFrame(frame)
    }

    private func tearDownSurfaces() {
        isPreparingForTermination = true
        // WHY: Early freeze retains the editor; only this explicit teardown ends its sheet.
        createWorkspaceController?.dismissForApplicationTermination()
        createWorkspaceController = nil
        workspaceViewController.cancelTabRename()
        tabRenameTransientInteraction?.end()
        tabRenameTransientInteraction = nil
        isTabRenameEditing = false
        endWorkspaceMenuTracking()
        // WHY: Retirement can stop reparenting before mode commits. Either physical window
        // may still own content or be visible, independently of the persisted mode.
        _ = normalWindowController.window?.makeFirstResponder(nil)
        _ = quakeWindowController.appKitWindow?.makeFirstResponder(nil)
        workspaceViewController.displayTerminal(
            root: nil,
            surfaces: [:],
            failures: [:],
            palette: ghosttyBridge.chromePalette,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        normalWindowController.window?.orderOut(nil)
        quakeWindowController.appKitWindow?.orderOut(nil)
        closeActiveSurfaces(allowDuringTermination: true)
        surfaceFailures.removeAll()
        // WHY: Unaccepted responses may still arrive after teardown and require exact compensation.
        discardedManagedTasks = discardedManagedTasks.filter { !$0.value.compensationCompleted }
    }

    @discardableResult
    private func closeActiveSurfaces(allowDuringTermination: Bool = false) -> Bool {
        // WHY: Only explicit teardown may close all panes while frozen. UI close callbacks
        // must honor reentrant cancellation, including between panes and before window.close.
        guard !isPreparingForTermination || allowDuringTermination else { return false }
        for paneID in Array(surfaces.keys) {
            // WHY: A previous close callback may already have removed a sibling.
            guard surfaces[paneID] != nil else { continue }
            guard
                removeSurface(
                    id: paneID, closeBridgeSurface: true,
                    allowDuringTermination: allowDuringTermination
                )
            else { return false }
        }
        return !isPreparingForTermination || allowDuringTermination
    }

    private func surfaceDidRequestClose(id: PaneID, processAlive: Bool) {
        guard !isPreparingForTermination else { return }
        if !processAlive, surfaces[id]?.isManagedTask == true {
            // WHY: A native exit-close cannot bypass EOF or keep policy. Explicit UI close remains available.
            if let taskID = managedTaskIDByPane[id] {
                scheduleManagedSuccessfulClosure(taskID: taskID)
            }
            return
        }
        if !processAlive, let attempt = agentResumeAttempts[id] {
            if agentResumeRuntime.isCurrent(attempt.reference) {
                agentResumeRuntime.processExited(attempt.reference)
            }
            if case .failed(.immediateExit, _) = agentResumeBinding(for: id)?.restoreState {
                guard
                    removeSurface(
                        id: id,
                        closeBridgeSurface: true,
                        preserveAgentPresentation: true
                    )
                else { return }
                surfaceFailures.removeValue(forKey: id)
                if case .started = startupState, activeTab?.root.contains(id) == true {
                    refreshWorkspacePresentation(focusTerminal: false)
                }
                return
            }
        }
        requestClosePane(id, requiresConfirmation: processAlive)
    }

    private func agentResumeBinding(for paneID: PaneID) -> AgentResumeBinding? {
        workspaceStore.workspaces.lazy
            .flatMap(\.tabs)
            .compactMap { $0.paneDescriptor(for: paneID)?.agentResumeBinding }
            .first
    }

    private func presentConfirmation(
        _ presentation: GhosttyConfirmationPresentation,
        completion: @escaping GhosttyConfirmationQueue.Completion
    ) -> GhosttyConfirmationQueue.Dismiss? {
        guard !isPreparingForTermination, let window = activeWindow else {
            completion(.deny)
            return nil
        }

        let alert = Self.makeConfirmationAlert(presentation)

        alert.beginSheetModal(for: window) { response in
            let allowed: Bool
            switch presentation {
            case .close:
                allowed = response == .alertFirstButtonReturn
            case .clipboard:
                allowed = response == .alertSecondButtonReturn
            }
            completion(allowed ? .allow : .deny)
        }

        return { [weak alert, weak window] in
            guard let alert, let window, alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    }

    static func makeConfirmationAlert(
        _ presentation: GhosttyConfirmationPresentation
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch presentation {
        case .close:
            alert.messageText = "Close Terminal?"
            alert.informativeText =
                "The terminal still has a running process. If you close the terminal the process will be killed."
            let closeButton = alert.addButton(withTitle: "Close")
            closeButton.hasDestructiveAction = true
            closeButton.keyEquivalent = "\r"
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1B}"
        case .clipboard(let request):
            configureClipboardAlert(alert, request: request)
        }

        return alert
    }

    private static func configureClipboardAlert(
        _ alert: NSAlert,
        request: GhosttyClipboardConfirmationRequest
    ) {
        let cancelButton: NSButton
        let affirmativeButton: NSButton

        switch request.kind {
        case .paste:
            alert.messageText = "Warning: Potentially Unsafe Paste"
            alert.informativeText =
                "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
            cancelButton = alert.addButton(withTitle: "Cancel")
            affirmativeButton = alert.addButton(withTitle: "Paste")
        case .osc52Read:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to read from the clipboard. The current clipboard contents are shown below."
            cancelButton = alert.addButton(withTitle: "Deny")
            affirmativeButton = alert.addButton(withTitle: "Allow")
        case .osc52Write:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to write to the clipboard. The content to write is shown below."
            cancelButton = alert.addButton(withTitle: "Deny")
            affirmativeButton = alert.addButton(withTitle: "Allow")
        }

        cancelButton.keyEquivalent = "\u{1B}"
        affirmativeButton.keyEquivalent = "\r"
        alert.accessoryView = clipboardContentsView(request.contents)
    }

    private static func clipboardContentsView(_ contents: [GhosttyClipboardContent]) -> NSView {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 220)
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = displayContents(contents)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        scrollView.documentView = textView
        return scrollView
    }

    private static func displayContents(_ contents: [GhosttyClipboardContent]) -> String {
        guard contents.count != 1 else { return contents[0].data }
        return contents.map { "[\($0.mime)]\n\($0.data)" }.joined(separator: "\n\n")
    }

    private func finishSurfaceClosure(
        id: PaneID,
        closeBridgeSurface: Bool
    ) {
        // WHY: Late close decisions must leave live panes intact until explicit teardown.
        guard !isPreparingForTermination,
            surfaces[id] != nil, closingPaneIDs.insert(id).inserted
        else { return }
        defer { closingPaneIDs.remove(id) }
        let location = workspaceStore.workspaces.lazy
            .flatMap(\.tabs)
            .first { $0.root.contains(id) }
        guard let tab = location,
            let workspace = workspaceStore.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tab.id })
            })
        else {
            _ = removeSurface(id: id, closeBridgeSurface: closeBridgeSurface)
            return
        }

        var candidate = workspaceStore
        if workspace.id == candidate.activeWorkspaceID,
            workspace.activeTabID == tab.id,
            tab.isBroadcasting
        {
            try? candidate.setBroadcasting(false, for: tab.id, in: workspace.id)
        }
        guard
            let delta = try? splitCoordinator.apply(
                .closePane(
                    workspaceID: workspace.id,
                    tabID: tab.id,
                    paneID: id
                ),
                to: &candidate
            )
        else {
            return
        }

        let requiresReplacement: Bool
        if case .tabClosed = delta {
            requiresReplacement = candidate.workspace(id: workspace.id)?.tabs.isEmpty == true
        } else {
            requiresReplacement = false
        }
        if requiresReplacement {
            do {
                let replacement = try prepareShellTab(
                    in: workspace.id,
                    candidate: &candidate,
                    surfaceContext: .newTab
                )
                guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else {
                    closeCreatedSurface(id: replacement.paneID)
                    return
                }
                surfaces[replacement.paneID] = replacement.surface
                installSurfaceActivityHandlers()
                _ = commitWorkspaceStore(candidate)
                refreshWorkspacePresentation(
                    focusTerminal: workspace.id == candidate.activeWorkspaceID)
            } catch {
                // WHY: A replacement cancelled by freeze must not close the original pane.
                guard !isPreparingForTermination else { return }
                guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else {
                    return
                }
                _ = commitWorkspaceStore(candidate)
                refreshWorkspacePresentation(
                    focusTerminal: workspace.id == candidate.activeWorkspaceID)
                guard !isPreparingForTermination else { return }
                onError(error)
            }
            return
        }

        guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else { return }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: workspace.id == candidate.activeWorkspaceID)
    }
}

@MainActor
private final class WindowCoordinatorTerminalAutomationHost: TerminalAutomationHost {
    private weak var coordinator: WindowCoordinator?

    init(coordinator: WindowCoordinator) {
        self.coordinator = coordinator
    }

    func resolveAuthenticatedSession(
        instanceID: UUID,
        originPaneID: PaneID
    ) -> TerminalAutomationResolvedSession? {
        coordinator?.resolveTerminalAutomationSession(
            instanceID: instanceID,
            originPaneID: originPaneID
        )
    }

    func presentPermission(
        for session: TerminalAutomationResolvedSession
    ) async -> TerminalAutomationPermissionDecision {
        guard let coordinator else { return .unavailable }
        return await coordinator.presentTerminalAutomationPermission(for: session)
    }

    func createTab(
        in workspaceID: WorkspaceID,
        launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        guard let coordinator else { return .failure(.cancelled) }
        let configuration: TerminalTaskLaunchConfiguration
        do {
            configuration = try coordinator.prepareTerminalTaskLaunchConfiguration(for: launch)
        } catch {
            return .failure(.invalidLaunchRequest)
        }
        return await coordinator.createManagedTab(
            in: workspaceID,
            launchConfiguration: configuration,
            workingDirectory: launch.cwd,
            policy: policy,
            focus: focus,
            expectedSession: expectedSession
        )
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
        guard let coordinator else { return .failure(.cancelled) }
        let configuration: TerminalTaskLaunchConfiguration
        do {
            configuration = try coordinator.prepareTerminalTaskLaunchConfiguration(for: launch)
        } catch {
            return .failure(.invalidLaunchRequest)
        }
        return await coordinator.splitManagedPane(
            anchorPaneID: anchorPaneID,
            in: workspaceID,
            placement: direction.splitPlacement,
            ratio: ratio,
            launchConfiguration: configuration,
            workingDirectory: launch.cwd,
            policy: policy,
            focus: focus,
            expectedSession: expectedSession
        )
    }

    func discardCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> Bool {
        guard let coordinator else { return false }
        return coordinator.discardManagedTask(created, expectedSession: expectedSession)
    }

    func inspectTask(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationTaskInspection {
        coordinator?.inspectManagedTask(taskID: taskID, expectedSession: expectedSession)
            ?? .notFound
    }

    func acceptCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) {
        coordinator?.acceptManagedCreation(created, expectedSession: expectedSession)
    }

    func revokeSession(_ session: TerminalAutomationSessionIdentity) {
        coordinator?.revokeManagedSession(session)
    }

    func forgetTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) {
        coordinator?.forgetManagedTask(taskID: taskID, expectedSession: expectedSession)
    }

    func canEvictTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) -> Bool {
        coordinator?.canEvictManagedTask(taskID: taskID, expectedSession: expectedSession) ?? false
    }

    func read(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.readManagedTask(taskID: taskID, expectedSession: expectedSession)
            ?? .failure(.cancelled)
    }

    func sendText(
        taskID: UUID,
        expectedRevision: UInt64,
        text: String,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.sendManagedInput(
            taskID: taskID, expectedRevision: expectedRevision, text: text,
            expectedSession: expectedSession) ?? .failure(.cancelled)
    }

    func sendKey(
        taskID: UUID,
        expectedRevision: UInt64,
        key: TerminalControlKey,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.sendManagedInput(
            taskID: taskID, expectedRevision: expectedRevision, key: key,
            expectedSession: expectedSession) ?? .failure(.cancelled)
    }

    func requestUserInput(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.requestManagedUserInput(taskID: taskID, expectedSession: expectedSession)
            ?? .failure(.cancelled)
    }

    func focus(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.focusManagedTask(taskID: taskID, expectedSession: expectedSession)
            ?? .failure(.cancelled)
    }

    func resize(
        taskID: UUID,
        ratio: Double,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.resizeManagedTask(
            taskID: taskID, ratio: ratio, expectedSession: expectedSession)
            ?? .failure(.cancelled)
    }

    func interrupt(
        taskID: UUID,
        expectedRevision: UInt64,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        coordinator?.sendManagedInput(
            taskID: taskID, expectedRevision: expectedRevision, key: .controlC,
            expectedSession: expectedSession) ?? .failure(.cancelled)
    }

    func requestClose(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity,
        context: TerminalControlRequestContext
    ) async -> TerminalAutomationHostResponse {
        guard let coordinator else { return .failure(.cancelled) }
        return await coordinator.requestManagedClose(
            taskID: taskID, expectedSession: expectedSession, context: context)
    }

    func publishPresentation(_ presentation: TerminalAutomationPresentationEvent) {
        coordinator?.publishTerminalAutomationPresentation(presentation)
    }

    func publishAttention(_ attention: TerminalAutomationAttention) {
        coordinator?.publishTerminalAutomationAttention(attention)
    }
}

@MainActor
private final class HotKeyActionRelay {
    var action: (@MainActor () -> Void)?

    func perform() {
        action?()
    }
}
