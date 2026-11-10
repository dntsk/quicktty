import Foundation

struct AgentMessagingOriginContext: Equatable {
    let origin: AgentInteractionOrigin
    let workspaceName: String
    let agentName: String
}

@MainActor
private final class AgentMessagingServiceRouter {
    weak var service: AgentMessagingService?
    func route(_ request: AgentMessagingRequest, context: AgentMessagingSocketContext) async
        -> AgentMessagingResponse
    {
        guard let service else { return .failure("unavailable", requestID: request.requestID) }
        return await service.handle(request, context: context)
    }
}

@MainActor
final class AgentMessagingService {
    static var current: AgentMessagingService?
    private let workspaceProvider: @MainActor () -> [Workspace]
    private let paneIsLive: @MainActor (PaneID) -> Bool
    private let credentials: TelegramCredentialStore
    private let preferences: TelegramConnectionPreferences
    private let makeClient: TelegramConnectionController.ClientFactory
    private let sessions: AgentSessionController
    private var server: AgentMessagingSocketServer?
    private var registered: [PaneID: (adapter: AgentAdapterID, session: String)] = [:]
    private var epochs: [PaneID: UInt64] = [:]
    private var knownOrigins: [PaneID: AgentInteractionOrigin] = [:]
    private var submissions: [UUID: (AgentInteractionOrigin, AgentMessagingRequest)] = [:]
    private var isFrozen = false
    private var isReconcilingAccess = false
    private var revokedOrigins: Set<AgentInteractionOrigin> = []
    var onChange: (@MainActor () -> Void)?
    private(set) lazy var connection = TelegramConnectionController(
        credentials: credentials, preferences: preferences, makeClient: makeClient,
        originIsCurrent: { [weak self] origin in
            self?.originContext(for: PaneID(rawValue: origin.paneID))?.origin == origin
        }
    )

    init(
        sessions: AgentSessionController,
        workspaceProvider: @escaping @MainActor () -> [Workspace],
        paneIsLive: @escaping @MainActor (PaneID) -> Bool,
        credentials: TelegramCredentialStore = .keychain(),
        preferences: TelegramConnectionPreferences = .standard(),
        makeClient: @escaping TelegramConnectionController.ClientFactory = {
            TelegramBotClient(token: $0)
        }
    ) throws {
        self.workspaceProvider = workspaceProvider
        self.paneIsLive = paneIsLive
        self.credentials = credentials
        self.preferences = preferences
        self.makeClient = makeClient
        self.sessions = sessions
        let router = AgentMessagingServiceRouter()
        let server = AgentMessagingSocketServer(
            credentialProvider: { sessions.credential(for: $0) },
            handler: { request, context in await router.route(request, context: context) }
        )
        let path = try server.start()
        do { try sessions.installMessagingSocket(path) } catch {
            server.stopImmediately()
            throw error
        }
        self.server = server
        router.service = self
        sessions.onMessagingLifecycle = { [weak self] in self?.lifecycle($0) }
        sessions.onMessagingInvalidation = { [weak self] in self?.invalidate($0) }
        connection.onChange = { [weak self] in self?.connectionChanged() }
        connection.start()
    }

    var workspaces: [(id: UUID, name: String)] {
        workspaceProvider().map { ($0.id.rawValue, $0.name) }
    }

    func origins() -> [AgentMessagingOriginContext] {
        registered.keys.compactMap { originContext(for: $0) }.sorted {
            ($0.workspaceName, $0.agentName, $0.origin.paneID.uuidString)
                < ($1.workspaceName, $1.agentName, $1.origin.paneID.uuidString)
        }
    }

    func isAuthorized(_ origin: AgentInteractionOrigin) -> Bool { connection.hasGrant(origin) }

    func setAuthorized(_ origin: AgentInteractionOrigin, allowed: Bool) throws {
        guard !isFrozen, let context = originContext(for: PaneID(rawValue: origin.paneID)),
            context.origin == origin
        else {
            throw AgentInteractionError.notAuthorized
        }
        if allowed {
            revokedOrigins.remove(origin)
            try connection.authorize(
                origin, workspaceName: context.workspaceName, agentName: context.agentName)
            knownOrigins[PaneID(rawValue: origin.paneID)] = origin
        } else {
            revokedOrigins.insert(origin)
            connection.revoke(origin)
        }
        onChange?()
    }

    private func connectionChanged() {
        guard !isFrozen, !isReconcilingAccess else { return }
        reconcileAccess()
        onChange?()
    }

    private func reconcileAccess() {
        guard !isFrozen, !isReconcilingAccess else { return }
        isReconcilingAccess = true
        defer { isReconcilingAccess = false }
        let contexts = origins()
        let currentOrigins = Set(contexts.map(\.origin))
        for (pane, origin) in knownOrigins where !currentOrigins.contains(origin) {
            knownOrigins.removeValue(forKey: pane)
            revokedOrigins.remove(origin)
            connection.revoke(origin)
        }
        guard connection.isEnabled, case .connected = connection.phase else { return }
        let workspaceIDs = Set(workspaces.map(\.id))
        if connection.enabledWorkspaces != workspaceIDs {
            connection.setEnabledWorkspaces(workspaceIDs)
        }
        for context in contexts {
            let origin = context.origin
            guard !revokedOrigins.contains(origin), !connection.hasGrant(origin) else { continue }
            do {
                try connection.authorize(
                    origin, workspaceName: context.workspaceName, agentName: context.agentName)
                knownOrigins[PaneID(rawValue: origin.paneID)] = origin
            } catch {
                // Invalid presentation text must not weaken the origin checks or enable a grant.
                continue
            }
        }
    }

    func shutdown() {
        guard !isFrozen else { return }
        isFrozen = true
        connection.shutdown()
        server?.stopImmediately()
        sessions.onMessagingLifecycle = nil
        sessions.onMessagingInvalidation = nil
        registered.removeAll()
        knownOrigins.removeAll()
        revokedOrigins.removeAll()
        onChange = nil
        if Self.current === self { Self.current = nil }
    }

    private func originContext(for paneID: PaneID) -> AgentMessagingOriginContext? {
        guard !isFrozen, let registered = registered[paneID], paneIsLive(paneID) else { return nil }
        for workspace in workspaceProvider() {
            for tab in workspace.tabs {
                guard let descriptor = tab.paneDescriptors.first(where: { $0.id == paneID }),
                    let binding = descriptor.agentResumeBinding,
                    binding.adapterID == registered.adapter,
                    binding.sessionID == registered.session,
                    binding.restoreState == .active,
                    let definition = AgentIntegrationRegistry.definition(for: binding.adapterID),
                    let origin = try? AgentInteractionOrigin(
                        instanceID: sessions.instanceID, workspaceID: workspace.id.rawValue,
                        paneID: paneID.rawValue, adapterID: binding.adapterID.rawValue,
                        sessionID: binding.sessionID, generation: epochs[paneID] ?? 0
                    )
                else { continue }
                return AgentMessagingOriginContext(
                    origin: origin, workspaceName: workspace.name, agentName: definition.displayName
                )
            }
        }
        return nil
    }

    private func lifecycle(_ action: AgentSessionLifecycleAction) {
        guard !isFrozen else { return }
        switch action {
        case .register(let pane, let binding), .replace(let pane, _, let binding):
            let previous = registered[pane]
            if previous?.adapter != binding.adapterID || previous?.session != binding.sessionID {
                invalidate(pane)
                let epoch = epochs[pane] ?? 0
                guard epoch < UInt64.max else { return }
                epochs[pane] = epoch + 1
                registered[pane] = (binding.adapterID, binding.sessionID)
            }
            if let origin = originContext(for: pane)?.origin { knownOrigins[pane] = origin }
        case .unregister(let pane, _, _): invalidate(pane)
        }
        reconcileAccess()
        onChange?()
    }

    private func invalidate(_ pane: PaneID?) {
        guard !isFrozen else { return }
        if let pane {
            registered.removeValue(forKey: pane)
            if let origin = knownOrigins.removeValue(forKey: pane) {
                revokedOrigins.remove(origin)
                connection.revoke(origin)
            }
        } else {
            let previous = Array(knownOrigins.values)
            registered.removeAll()
            knownOrigins.removeAll()
            revokedOrigins.removeAll()
            for origin in previous { connection.revoke(origin) }
        }
        onChange?()
    }

    fileprivate func handle(_ request: AgentMessagingRequest, context: AgentMessagingSocketContext)
        async -> AgentMessagingResponse
    {
        reconcileAccess()
        guard !isFrozen, context.isActive, context.instanceID == sessions.instanceID,
            let origin = originContext(for: PaneID(rawValue: context.paneID))?.origin,
            request.sessionID == nil || request.sessionID == origin.sessionID
        else { return .failure("unavailable", requestID: request.requestID) }
        guard connection.hasGrant(origin) else {
            return .failure("permissionRequired", requestID: request.requestID)
        }
        do {
            try request.validate()
            if [.question, .action, .notify].contains(request.operation) {
                if let previous = submissions[request.requestID] {
                    guard previous.0 == origin, previous.1 == request else {
                        return .failure("requestIDConflict", requestID: request.requestID)
                    }
                    if request.operation == .notify {
                        return AgentMessagingResponse(
                            version: 1, requestID: request.requestID, state: "accepted")
                    }
                } else if submissions.count >= 4_096 {
                    return .failure("capacityExceeded", requestID: request.requestID)
                }
            }
            switch request.operation {
            case .question, .action:
                let prompt: AgentInteractionPrompt
                if request.operation == .question {
                    prompt = .question(text: request.text!, choices: request.choices ?? [])
                } else {
                    prompt = .action(
                        try AgentInteractionAction(
                            operation: request.text!, resources: request.resources!,
                            consequences: request.consequences!,
                            risk: request.elevated == false ? .standard : .elevated))
                }
                let interaction = try AgentInteractionRequest(
                    id: request.requestID, origin: origin, prompt: prompt,
                    timeoutMilliseconds: request.timeoutMilliseconds ?? 900_000)
                let snapshot = try connection.submit(interaction)
                submissions[request.requestID] = (origin, request)
                return response(snapshot)
            case .notify:
                try connection.notify(
                    origin, status: TelegramAgentStatus(rawValue: request.status!)!,
                    summary: request.text!)
                submissions[request.requestID] = (origin, request)
                return AgentMessagingResponse(
                    version: 1, requestID: request.requestID, state: "accepted")
            case .status, .wait, .cancel:
                guard let original = submissions[request.requestID], original.0 == origin,
                    original.1.operation == .question || original.1.operation == .action,
                    var snapshot = connection.snapshot(request.requestID)
                else { return .failure("requestUnavailable", requestID: request.requestID) }
                if request.operation == .cancel, snapshot.state == .pending {
                    snapshot = try connection.answerLocally(request.requestID, answer: .cancel)
                }
                if request.operation == .wait {
                    let deadline = ContinuousClock.now.advanced(
                        by: .milliseconds(Int64(request.timeoutMilliseconds!)))
                    while snapshot.state == .pending, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                        guard !isFrozen, context.isActive, !Task.isCancelled,
                            originContext(for: PaneID(rawValue: context.paneID))?.origin == origin,
                            connection.hasGrant(origin)
                        else { return .failure("cancelled", requestID: request.requestID) }
                        guard let current = connection.snapshot(request.requestID) else {
                            return .failure("requestUnavailable", requestID: request.requestID)
                        }
                        snapshot = current
                    }
                }
                return response(snapshot)
            }
        } catch let error as AgentInteractionError {
            let code: String
            switch error {
            case .requestIDConflict: code = "requestIDConflict"
            case .capacityExceeded: code = "capacityExceeded"
            case .notAuthorized: code = "permissionRequired"
            default: code = "invalidRequest"
            }
            return .failure(code, requestID: request.requestID)
        } catch { return .failure("cancelled", requestID: request.requestID) }
    }

    private func response(_ snapshot: AgentInteractionSnapshot) -> AgentMessagingResponse {
        let id = snapshot.request.id
        switch snapshot.state {
        case .pending: return AgentMessagingResponse(version: 1, requestID: id, state: "pending")
        case .resolved(let resolution):
            switch resolution {
            case .text(let text):
                return AgentMessagingResponse(version: 1, requestID: id, state: "text", text: text)
            case .choice(let index, let label):
                return AgentMessagingResponse(
                    version: 1, requestID: id, state: "choice", text: label, choiceIndex: index)
            case .approved:
                return AgentMessagingResponse(version: 1, requestID: id, state: "approved")
            case .denied: return AgentMessagingResponse(version: 1, requestID: id, state: "denied")
            case .cancelled:
                return AgentMessagingResponse(version: 1, requestID: id, state: "cancelled")
            case .expired:
                return AgentMessagingResponse(version: 1, requestID: id, state: "expired")
            case .revoked:
                return AgentMessagingResponse(version: 1, requestID: id, state: "revoked")
            }
        }
    }
}
