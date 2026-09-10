import Foundation

struct TerminalControlRequestContext: Sendable {
    private let isActiveProvider: @Sendable () -> Bool

    init(isActiveProvider: @escaping @Sendable () -> Bool = { true }) {
        self.isActiveProvider = isActiveProvider
    }

    init(_ socketContext: TerminalControlSocketRequestContext) {
        isActiveProvider = { socketContext.isActive }
    }

    var isActive: Bool {
        isActiveProvider()
    }
}

struct TerminalAutomationSessionIdentity: Equatable, Hashable, Sendable {
    let instanceID: UUID
    let originPaneID: PaneID
    let adapterID: AgentAdapterID
    let sessionID: String
    let paneCredentialGeneration: UInt64
}

struct TerminalAutomationWorkspaceContext: Equatable, Sendable {
    let workspaceID: WorkspaceID
    let name: String
    let originTabID: TabID
    let activeTabID: TabID
    let tabCount: Int
    let paneCount: Int
    let tabIDs: Set<TabID>
    let paneIDs: Set<PaneID>

    init(
        workspaceID: WorkspaceID,
        name: String,
        originTabID: TabID,
        activeTabID: TabID,
        tabCount: Int,
        paneCount: Int
    ) {
        self.init(
            workspaceID: workspaceID,
            name: name,
            originTabID: originTabID,
            activeTabID: activeTabID,
            tabCount: tabCount,
            paneCount: paneCount,
            tabIDs: [originTabID, activeTabID],
            paneIDs: []
        )
    }

    init(
        workspaceID: WorkspaceID,
        name: String,
        originTabID: TabID,
        activeTabID: TabID,
        tabCount: Int,
        paneCount: Int,
        tabIDs: Set<TabID>,
        paneIDs: Set<PaneID>
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.originTabID = originTabID
        self.activeTabID = activeTabID
        self.tabCount = tabCount
        self.paneCount = paneCount
        self.tabIDs = tabIDs
        self.paneIDs = paneIDs
    }
}

struct TerminalAutomationResolvedSession: Equatable, Sendable {
    let identity: TerminalAutomationSessionIdentity
    let workspace: TerminalAutomationWorkspaceContext
}

enum TerminalAutomationPermissionDecision: Equatable, Sendable {
    case allowed
    case denied
    case unavailable
}

struct TerminalAutomationCreatedTaskResponse: Equatable, Sendable {
    let task: TerminalControlTask
    let splitID: UUID?
}

enum TerminalAutomationHostResponse: Equatable, Sendable {
    case createdTask(TerminalAutomationCreatedTaskResponse)
    case task(TerminalControlTask)
    case snapshot(TerminalControlSnapshot)
    case acknowledged(taskID: UUID, revision: UInt64)
    case failure(TerminalControlErrorCode)
}

enum TerminalAutomationTaskInspection: Equatable, Sendable {
    case owned(TerminalControlTask)
    case notFound
    case notOwned
}

enum TerminalAutomationPresentationEvent: Equatable, Sendable {
    case permissionPrompt(TerminalAutomationSessionIdentity)
    case taskRequiresPresentation(UUID)
}

enum TerminalAutomationAttention: Equatable, Sendable {
    case permissionDenied(TerminalAutomationSessionIdentity)
    case taskRequiresAttention(UUID)
}

@MainActor
protocol TerminalAutomationHost: AnyObject {
    func resolveAuthenticatedSession(instanceID: UUID, originPaneID: PaneID)
        -> TerminalAutomationResolvedSession?
    func presentPermission(for session: TerminalAutomationResolvedSession) async
        -> TerminalAutomationPermissionDecision
    func createTab(
        in workspaceID: WorkspaceID,
        launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func createSplit(
        anchorPaneID: PaneID,
        in workspaceID: WorkspaceID,
        direction: TerminalSplitDirection,
        ratio: Double,
        launch: TerminalControlLaunch,
        policy: TerminalTaskLifecyclePolicy,
        focus: Bool,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func discardCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> Bool
    func acceptCreatedTask(
        _ created: TerminalAutomationCreatedTaskResponse,
        expectedSession: TerminalAutomationSessionIdentity
    )
    func revokeSession(_ session: TerminalAutomationSessionIdentity)
    func forgetTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity)
    // WHY: Terminal state alone does not prove that mandatory host cleanup has finished.
    func canEvictTask(taskID: UUID, expectedSession: TerminalAutomationSessionIdentity) -> Bool
    func inspectTask(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) -> TerminalAutomationTaskInspection
    func read(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func sendText(
        taskID: UUID,
        expectedRevision: UInt64,
        text: String,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func sendKey(
        taskID: UUID,
        expectedRevision: UInt64,
        key: TerminalControlKey,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func requestUserInput(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func focus(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func resize(
        taskID: UUID,
        ratio: Double,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func interrupt(
        taskID: UUID,
        expectedRevision: UInt64,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse
    func requestClose(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity,
        context: TerminalControlRequestContext
    ) async -> TerminalAutomationHostResponse
    func publishPresentation(_ presentation: TerminalAutomationPresentationEvent)
    func publishAttention(_ attention: TerminalAutomationAttention)
}

extension TerminalAutomationHost {
    func requestClose(
        taskID: UUID,
        expectedSession: TerminalAutomationSessionIdentity
    ) async -> TerminalAutomationHostResponse {
        await requestClose(
            taskID: taskID, expectedSession: expectedSession,
            context: TerminalControlRequestContext())
    }
}
