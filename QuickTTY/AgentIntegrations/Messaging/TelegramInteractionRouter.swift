import Foundation

struct TelegramInteractionRouter: Sendable {
    let peer: TelegramPeer

    func route(
        _ update: TelegramUpdate,
        ledger: inout AgentInteractionLedger,
        now: UInt64
    ) throws -> AgentInteractionSnapshot? {
        guard update.updateID >= 0 else { return nil }
        if let message = update.message, update.callbackQuery == nil {
            guard peer.accepts(message.from, in: message.chat), !message.isRelayed,
                message.messageID > 0, message.date > 0,
                let reply = message.replyToMessage, let text = message.text,
                let reference = try? TelegramMessageReference(
                    chatID: message.chat.id, messageID: reply.messageID
                ),
                let pending = ledger.pendingRequest(for: reference, now: now)
            else { return nil }
            return try ledger.resolveTelegram(
                pending.request.id, message: reference, answer: .text(text), now: now
            )
        }
        if let callback = update.callbackQuery, update.message == nil {
            guard let message = callback.message,
                peer.accepts(callback.from, in: message.chat), !message.isRelayed,
                message.date > 0, let data = callback.data,
                let parsed = TelegramCallbackData(encoded: data),
                let reference = try? TelegramMessageReference(
                    chatID: message.chat.id, messageID: message.messageID
                ),
                let pending = ledger.pendingRequest(for: reference, now: now),
                pending.request.id == parsed.requestID
            else { return nil }
            return try ledger.resolveTelegram(
                pending.request.id, message: reference, answer: parsed.answer, now: now
            )
        }
        return nil
    }
}
