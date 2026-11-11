import Foundation

struct TelegramBotToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(_ value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard value.utf8.count <= 300, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
            parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
            parts[1].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { throw TelegramBotClientError.invalidToken }
        self.value = value
    }

    var description: String { "<redacted Telegram bot token>" }
    var debugDescription: String { description }

    func keychainData(peer: TelegramPeer) throws -> Data {
        try JSONEncoder().encode(
            TelegramCredentialRecord(token: value, userID: peer.userID, chatID: peer.chatID))
    }

    static func fromKeychainData(_ data: Data) throws -> (token: Self, peer: TelegramPeer) {
        guard data.count <= 2_048 else { throw TelegramCredentialError.invalidRecord }
        let record = try JSONDecoder().decode(TelegramCredentialRecord.self, from: data)
        return (
            try Self(record.token), try TelegramPeer(userID: record.userID, chatID: record.chatID)
        )
    }

    fileprivate func endpoint(_ method: TelegramBotMethod) -> URL {
        URL(string: "https://api.telegram.org/bot\(value)/\(method.rawValue)")!
    }
}

private struct TelegramCredentialRecord: Codable {
    let token: String
    let userID: Int64
    let chatID: Int64
}

private enum TelegramBotMethod: String {
    case getMe
    case getUpdates
    case sendMessage
    case answerCallbackQuery
    case editMessageReplyMarkup
}

struct TelegramHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

enum TelegramBotClientError: Error, Equatable, Sendable {
    case invalidToken
    case invalidRequest
    case invalidResponse
    case unauthorized
    case conflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
    case rejected
    case transportFailure
    case deliveryUncertain
    case cancelled
}

struct TelegramBotClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> TelegramHTTPResponse
    static let maximumResponseBytes = 1_048_576

    private let token: TelegramBotToken
    private let transport: Transport

    init(token: TelegramBotToken, transport: Transport? = nil) {
        self.token = token
        self.transport = transport ?? Self.liveTransport()
    }

    func getMe() async throws -> TelegramUser {
        let user: TelegramUser = try await call(.getMe, body: EmptyBody())
        guard user.isBot, user.id > 0 else { throw TelegramBotClientError.invalidResponse }
        return user
    }

    func getUpdates(offset: Int64?) async throws -> [TelegramUpdate] {
        if let offset, offset < 0 { throw TelegramBotClientError.invalidRequest }
        let updates: [TelegramUpdate] = try await call(
            .getUpdates, body: UpdatesBody(offset: offset))
        guard updates.count <= 20, updates.allSatisfy({ (0..<Int64.max).contains($0.updateID) })
        else {
            throw TelegramBotClientError.invalidResponse
        }
        return updates
    }

    func sendPrompt(
        _ snapshot: AgentInteractionSnapshot,
        to peer: TelegramPeer
    ) async throws -> TelegramMessageReference {
        let prompt = try TelegramPrompt(snapshot: snapshot)
        return try await sendText(
            prompt.text, buttons: prompt.buttons, forceReply: prompt.forceReply, to: peer)
    }

    func sendStatus(
        presentation: AgentInteractionPresentation,
        status: TelegramAgentStatus,
        summary: String,
        to peer: TelegramPeer
    ) async throws -> TelegramMessageReference {
        try AgentInteractionText.validate(summary, maximumBytes: 512)
        let text =
            "QuickTTY · \(presentation.workspaceName) · \(presentation.agentName)\n\(status.caption)\n\(summary)"
        return try await sendText(text, buttons: [], to: peer)
    }

    func sendReplyFeedback(accepted: Bool, to peer: TelegramPeer) async throws {
        let text =
            accepted
            ? "Ответ принят и передан агенту."
            : "Ответ не передан агенту. На вопрос отвечайте через «Ответить» в меню его сообщения; действие подтверждайте кнопкой под запросом."
        _ = try await sendText(text, buttons: [], to: peer)
    }

    private func sendText(
        _ text: String, buttons: [[TelegramInlineButton]], forceReply: Bool = false,
        to peer: TelegramPeer
    ) async throws -> TelegramMessageReference {
        let message: TelegramMessage = try await call(
            .sendMessage,
            body: SendMessageBody(
                chatID: peer.chatID, text: text,
                replyMarkup: InlineKeyboard(
                    inlineKeyboard: buttons, forceReply: forceReply ? true : nil)
            )
        )
        guard message.chat.id == peer.chatID, message.chat.type == "private",
            let reference = try? TelegramMessageReference(
                chatID: message.chat.id, messageID: message.messageID
            )
        else { throw TelegramBotClientError.deliveryUncertain }
        return reference
    }

    func answerCallbackQuery(_ id: String, text: String) async throws {
        guard (1...256).contains(id.utf8.count), text.utf16.count <= 200,
            (try? AgentInteractionText.validate(id, maximumBytes: 256, multiline: false)) != nil
        else { throw TelegramBotClientError.invalidRequest }
        let accepted: Bool = try await call(
            .answerCallbackQuery, body: CallbackAnswerBody(callbackQueryID: id, text: text)
        )
        guard accepted else { throw TelegramBotClientError.invalidResponse }
    }

    func clearButtons(_ reference: TelegramMessageReference) async throws {
        let message: TelegramMessage = try await call(
            .editMessageReplyMarkup,
            body: EditMarkupBody(
                chatID: reference.chatID, messageID: reference.messageID,
                replyMarkup: InlineKeyboard(inlineKeyboard: [])
            )
        )
        guard message.chat.id == reference.chatID, message.messageID == reference.messageID else {
            throw TelegramBotClientError.invalidResponse
        }
    }

    private func call<Result: Decodable & Sendable>(
        _ method: TelegramBotMethod,
        body: some Encodable & Sendable
    ) async throws -> Result {
        guard !Task.isCancelled else { throw TelegramBotClientError.cancelled }
        let uncertainResponse: TelegramBotClientError =
            method == .sendMessage ? .deliveryUncertain : .invalidResponse
        let endpoint = token.endpoint(method)
        var request = URLRequest(
            url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.httpBody = try JSONEncoder().encode(body)
        let received: TelegramHTTPResponse
        do {
            received = try await transport(request)
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw TelegramBotClientError.cancelled
            }
            if error as? TelegramBotClientError == .invalidResponse {
                throw uncertainResponse
            }
            // A network error does not prove that Telegram did not create the message.
            throw method == .sendMessage
                ? TelegramBotClientError.deliveryUncertain : .transportFailure
        }
        guard !Task.isCancelled else { throw TelegramBotClientError.cancelled }
        guard received.response.url == endpoint, received.data.count <= Self.maximumResponseBytes
        else {
            throw uncertainResponse
        }
        let status = received.response.statusCode
        if status == 401 { throw TelegramBotClientError.unauthorized }
        if status == 409 { throw TelegramBotClientError.conflict }
        if status == 429 {
            let response = try? JSONDecoder().decode(
                TelegramFailureEnvelope.self, from: received.data)
            let retryAfter = response?.parameters?.retryAfter ?? 1
            throw TelegramBotClientError.rateLimited(
                retryAfterSeconds: min(max(retryAfter, 1), 86_400))
        }
        if (500...599).contains(status) {
            throw method == .sendMessage ? TelegramBotClientError.deliveryUncertain : .unavailable
        }
        guard (200...299).contains(status) else {
            if (400...499).contains(status) { throw TelegramBotClientError.rejected }
            throw uncertainResponse
        }
        guard
            let envelope = try? JSONDecoder().decode(
                TelegramEnvelope<Result>.self, from: received.data)
        else {
            throw uncertainResponse
        }
        guard envelope.ok else { throw TelegramBotClientError.rejected }
        guard let result = envelope.result else { throw uncertainResponse }
        return result
    }

    private static func liveTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(
            configuration: configuration, delegate: TelegramRedirectBlocker(), delegateQueue: nil)
        return { request in
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                response.expectedContentLength <= Int64(maximumResponseBytes)
            else { throw TelegramBotClientError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw TelegramBotClientError.invalidResponse
                }
                data.append(byte)
            }
            return TelegramHTTPResponse(data: data, response: response)
        }
    }
}

private final class TelegramRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct TelegramEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Result?
}

private struct TelegramFailureEnvelope: Decodable {
    struct Parameters: Decodable {
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey {
            case retryAfter = "retry_after"
        }
    }
    let parameters: Parameters?
}

private struct EmptyBody: Encodable, Sendable {}

private struct UpdatesBody: Encodable, Sendable {
    let offset: Int64?
    let limit = 20
    let timeout = 25
    let allowedUpdates = ["message", "callback_query"]

    enum CodingKeys: String, CodingKey {
        case offset, limit, timeout
        case allowedUpdates = "allowed_updates"
    }
}

private struct InlineKeyboard: Encodable, Sendable {
    let inlineKeyboard: [[TelegramInlineButton]]
    let forceReply: Bool?

    init(inlineKeyboard: [[TelegramInlineButton]], forceReply: Bool? = nil) {
        self.inlineKeyboard = inlineKeyboard
        self.forceReply = forceReply
    }

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
        case forceReply = "force_reply"
    }
}

private struct SendMessageBody: Encodable, Sendable {
    struct LinkPreview: Encodable, Sendable {
        let isDisabled = true
        enum CodingKeys: String, CodingKey {
            case isDisabled = "is_disabled"
        }
    }
    let chatID: Int64
    let text: String
    let replyMarkup: InlineKeyboard
    let protectContent = true
    let linkPreviewOptions = LinkPreview()

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case replyMarkup = "reply_markup"
        case protectContent = "protect_content"
        case linkPreviewOptions = "link_preview_options"
    }
}

private struct CallbackAnswerBody: Encodable, Sendable {
    let callbackQueryID: String
    let text: String
    let cacheTime = 0

    enum CodingKeys: String, CodingKey {
        case callbackQueryID = "callback_query_id"
        case text
        case cacheTime = "cache_time"
    }
}

private struct EditMarkupBody: Encodable, Sendable {
    let chatID: Int64
    let messageID: Int64
    let replyMarkup: InlineKeyboard

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case messageID = "message_id"
        case replyMarkup = "reply_markup"
    }
}
