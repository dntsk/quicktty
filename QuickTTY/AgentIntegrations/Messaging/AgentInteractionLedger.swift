import Foundation

struct AgentInteractionLedger: Sendable {
    private let maximumRecords: Int
    private let maximumPending: Int
    private var enabledWorkspaces: Set<UUID> = []
    private var grants: [AgentInteractionOrigin: AgentInteractionPresentation] = [:]
    private var records: [UUID: AgentInteractionSnapshot] = [:]

    init(maximumRecords: Int = 4_096, maximumPending: Int = 32) {
        precondition((1...4_096).contains(maximumRecords))
        precondition((1...32).contains(maximumPending))
        self.maximumRecords = maximumRecords
        self.maximumPending = maximumPending
    }

    var recordCount: Int { records.count }

    mutating func setEnabledWorkspaces(_ workspaceIDs: Set<UUID>, now: UInt64) {
        expire(now: now)
        enabledWorkspaces = workspaceIDs
        let removed = grants.keys.filter { !workspaceIDs.contains($0.workspaceID) }
        for origin in removed { revoke(origin, now: now) }
    }

    // The host must verify the live origin and apply the user's Telegram access policy.
    mutating func authorize(
        _ origin: AgentInteractionOrigin,
        workspaceName: String,
        agentName: String,
        now: UInt64
    ) throws {
        guard enabledWorkspaces.contains(origin.workspaceID) else {
            throw AgentInteractionError.notAuthorized
        }
        let presentation = try AgentInteractionPresentation(
            workspaceName: workspaceName, agentName: agentName
        )
        expire(now: now)
        let replaced = grants.keys.filter { $0.paneID == origin.paneID && $0 != origin }
        for previous in replaced { revoke(previous, now: now) }
        grants[origin] = presentation
    }

    mutating func revoke(_ origin: AgentInteractionOrigin, now: UInt64) {
        expire(now: now)
        grants.removeValue(forKey: origin)
        for id in Array(records.keys) {
            guard records[id]?.request.origin == origin, records[id]?.state == .pending else {
                continue
            }
            records[id]?.resolve(.revoked)
        }
    }

    mutating func revokeAll(now: UInt64) {
        expire(now: now)
        grants.removeAll()
        enabledWorkspaces.removeAll()
        for id in Array(records.keys) where records[id]?.state == .pending {
            records[id]?.resolve(.revoked)
        }
    }

    mutating func submit(_ request: AgentInteractionRequest, now: UInt64) throws
        -> AgentInteractionSnapshot
    {
        expire(now: now)
        guard let presentation = grants[request.origin],
            enabledWorkspaces.contains(request.origin.workspaceID)
        else { throw AgentInteractionError.notAuthorized }
        if let previous = records[request.id] {
            guard previous.request == request else { throw AgentInteractionError.requestIDConflict }
            return previous
        }
        let pending = records.values.filter { $0.state == .pending }
        // Retain terminal records for this runtime so capacity pressure cannot permit ID reuse.
        guard records.count < maximumRecords, pending.count < maximumPending,
            !pending.contains(where: { $0.request.origin == request.origin })
        else { throw AgentInteractionError.capacityExceeded }
        let (expiresAt, overflow) = now.addingReportingOverflow(request.timeoutMilliseconds)
        guard !overflow else { throw AgentInteractionError.clockExhausted }
        let snapshot = AgentInteractionSnapshot(
            request: request, presentation: presentation,
            expiresAtMilliseconds: expiresAt, state: .pending
        )
        records[request.id] = snapshot
        return snapshot
    }

    mutating func snapshot(_ id: UUID, now: UInt64) -> AgentInteractionSnapshot? {
        expire(now: now)
        return records[id]
    }

    mutating func snapshots(now: UInt64) -> [AgentInteractionSnapshot] {
        expire(now: now)
        return records.values.sorted { $0.request.id.uuidString < $1.request.id.uuidString }
    }

    func presentation(for origin: AgentInteractionOrigin) -> AgentInteractionPresentation? {
        guard enabledWorkspaces.contains(origin.workspaceID) else { return nil }
        return grants[origin]
    }

    mutating func pendingRequest(
        for message: TelegramMessageReference,
        now: UInt64
    ) -> AgentInteractionSnapshot? {
        expire(now: now)
        return records.values.first { $0.state == .pending && $0.telegramMessage == message }
    }

    @discardableResult
    mutating func bindTelegram(
        _ id: UUID,
        message: TelegramMessageReference,
        now: UInt64
    ) throws -> AgentInteractionSnapshot {
        var snapshot = try pending(id, now: now)
        if let previous = snapshot.telegramMessage {
            guard previous == message else { throw AgentInteractionError.messageAlreadyBound }
            return snapshot
        }
        guard !records.values.contains(where: { $0.telegramMessage == message }) else {
            throw AgentInteractionError.messageAlreadyBound
        }
        snapshot.bind(message)
        records[id] = snapshot
        return snapshot
    }

    @discardableResult
    mutating func resolveLocal(
        _ id: UUID,
        answer: AgentInteractionAnswer,
        now: UInt64
    ) throws -> AgentInteractionSnapshot {
        try resolve(pending(id, now: now), answer: answer)
    }

    @discardableResult
    mutating func resolveTelegram(
        _ id: UUID,
        message: TelegramMessageReference,
        answer: AgentInteractionAnswer,
        now: UInt64
    ) throws -> AgentInteractionSnapshot {
        let snapshot = try pending(id, now: now)
        guard snapshot.telegramMessage == message else {
            throw AgentInteractionError.invalidTelegramMessage
        }
        return try resolve(snapshot, answer: answer)
    }

    private mutating func pending(_ id: UUID, now: UInt64) throws -> AgentInteractionSnapshot {
        expire(now: now)
        guard let snapshot = records[id], snapshot.state == .pending,
            grants[snapshot.request.origin] != nil,
            enabledWorkspaces.contains(snapshot.request.origin.workspaceID)
        else { throw AgentInteractionError.requestUnavailable }
        return snapshot
    }

    private mutating func resolve(
        _ snapshot: AgentInteractionSnapshot,
        answer: AgentInteractionAnswer
    ) throws -> AgentInteractionSnapshot {
        let resolution: AgentInteractionResolution
        switch (snapshot.request.prompt, answer) {
        case (_, .cancel):
            resolution = .cancelled
        case (.question, .text(let text)):
            guard (try? AgentInteractionText.validate(text, maximumBytes: 4_096)) != nil else {
                throw AgentInteractionError.invalidAnswer
            }
            resolution = .text(text)
        case (.question(_, let choices), .choice(let index)) where choices.indices.contains(index):
            resolution = .choice(index: index, label: choices[index])
        case (.action, .deny):
            resolution = .denied
        case (.action(let action), .approve) where action.risk == .standard:
            resolution = .approved
        case (.action(let action), .text(let text))
        where action.risk == .elevated && text == snapshot.request.confirmationPhrase:
            resolution = .approved
        default:
            throw AgentInteractionError.invalidAnswer
        }
        var resolved = snapshot
        resolved.resolve(resolution)
        records[snapshot.request.id] = resolved
        return resolved
    }

    private mutating func expire(now: UInt64) {
        for id in Array(records.keys) {
            guard let snapshot = records[id], snapshot.state == .pending,
                now >= snapshot.expiresAtMilliseconds
            else { continue }
            records[id]?.resolve(.expired)
        }
    }
}
