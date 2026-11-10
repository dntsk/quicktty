import Foundation

struct TelegramPairingCandidate: Equatable, Sendable {
    let id: UUID
    let peer: TelegramPeer
}

struct TelegramPairingChallenge: Sendable {
    let code: String
    let expiresAtMilliseconds: UInt64
    private(set) var confirmedPeer: TelegramPeer?
    private var candidate: TelegramPairingCandidate?
    private var isConsumed = false

    init(now: UInt64) throws {
        let (expiresAt, overflow) = now.addingReportingOverflow(300_000)
        guard !overflow else { throw AgentInteractionError.clockExhausted }
        code = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        expiresAtMilliseconds = expiresAt
    }

    mutating func propose(_ update: TelegramUpdate, now: UInt64) -> TelegramPairingCandidate? {
        guard !isConsumed, now < expiresAtMilliseconds, update.updateID >= 0,
            update.callbackQuery == nil, let message = update.message,
            !message.isRelayed, message.date > 0, message.messageID > 0,
            message.chat.type == "private", let user = message.from, !user.isBot,
            message.text == "/start \(code)",
            let peer = try? TelegramPeer(userID: user.id, chatID: message.chat.id)
        else { return nil }
        let proposed = TelegramPairingCandidate(id: UUID(), peer: peer)
        candidate = proposed
        isConsumed = true
        return proposed
    }

    // Possession of the code proposes an account; only a native user decision grants access.
    mutating func confirm(candidateID: UUID, now: UInt64) -> TelegramPeer? {
        guard now < expiresAtMilliseconds, let candidate, candidate.id == candidateID else {
            return nil
        }
        self.candidate = nil
        confirmedPeer = candidate.peer
        return candidate.peer
    }

    mutating func cancel() {
        candidate = nil
        confirmedPeer = nil
        isConsumed = true
    }
}
