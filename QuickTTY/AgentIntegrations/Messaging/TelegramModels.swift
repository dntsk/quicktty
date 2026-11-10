import Foundation

enum TelegramAgentStatus: String, Sendable {
    case working, waiting, completed, failed

    var caption: String {
        switch self {
        case .working: "Агент работает"
        case .waiting: "Агент ждёт ответа"
        case .completed: "Агент завершил работу"
        case .failed: "Ошибка агента"
        }
    }
}

struct TelegramPeer: Equatable, Sendable {
    let userID: Int64
    let chatID: Int64

    init(userID: Int64, chatID: Int64) throws {
        guard userID > 0, chatID > 0 else { throw AgentInteractionError.invalidTelegramMessage }
        self.userID = userID
        self.chatID = chatID
    }

    func accepts(_ user: TelegramUser?, in chat: TelegramChat) -> Bool {
        chat.id == chatID && chat.type == "private" && user?.id == userID && user?.isBot == false
    }
}

struct TelegramMessageReference: Equatable, Hashable, Sendable {
    let chatID: Int64
    let messageID: Int64

    init(chatID: Int64, messageID: Int64) throws {
        guard chatID > 0, messageID > 0 else { throw AgentInteractionError.invalidTelegramMessage }
        self.chatID = chatID
        self.messageID = messageID
    }
}

struct TelegramUser: Decodable, Sendable {
    let id: Int64
    let isBot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
    }
}

struct TelegramChat: Decodable, Sendable {
    let id: Int64
    let type: String
}

struct TelegramReplyReference: Decodable, Sendable {
    let messageID: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

struct TelegramMessage: Decodable, Sendable {
    let messageID: Int64
    let date: Int64
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?
    let replyToMessage: TelegramReplyReference?
    let isRelayed: Bool

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case date, from, chat, text
        case replyToMessage = "reply_to_message"
        case forwardOrigin = "forward_origin"
        case viaBot = "via_bot"
        case senderChat = "sender_chat"
        case businessConnectionID = "business_connection_id"
        case senderBusinessBot = "sender_business_bot"
        case guestQueryID = "guest_query_id"
        case guestBotCallerUser = "guest_bot_caller_user"
        case guestBotCallerChat = "guest_bot_caller_chat"
        case isAutomaticForward = "is_automatic_forward"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(Int64.self, forKey: .messageID)
        date = try container.decode(Int64.self, forKey: .date)
        from = try container.decodeIfPresent(TelegramUser.self, forKey: .from)
        chat = try container.decode(TelegramChat.self, forKey: .chat)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        replyToMessage = try container.decodeIfPresent(
            TelegramReplyReference.self, forKey: .replyToMessage)
        let isAutomaticForward =
            try container.decodeIfPresent(Bool.self, forKey: .isAutomaticForward) == true
        // Business and guest messages can reuse a private chat ID in a different namespace.
        isRelayed =
            container.contains(.forwardOrigin) || container.contains(.viaBot)
            || container.contains(.senderChat) || container.contains(.businessConnectionID)
            || container.contains(.senderBusinessBot) || container.contains(.guestQueryID)
            || container.contains(.guestBotCallerUser) || container.contains(.guestBotCallerChat)
            || isAutomaticForward
    }
}

struct TelegramCallbackQuery: Decodable, Sendable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case id, from, message, data
    }
}

struct TelegramUpdate: Decodable, Sendable {
    let updateID: Int64
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TelegramCallbackData: Equatable, Sendable {
    let requestID: UUID
    let answer: AgentInteractionAnswer

    init(requestID: UUID, answer: AgentInteractionAnswer) {
        precondition(answer.isCallbackAnswer)
        self.requestID = requestID
        self.answer = answer
    }

    init?(encoded: String) {
        guard encoded.utf8.count <= 64 else { return nil }
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "qt1",
            let id = UUID(uuidString: String(parts[1])),
            parts[1] == Substring(id.uuidString.lowercased())
        else { return nil }
        let answer: AgentInteractionAnswer
        switch parts[2] {
        case "a": answer = .approve
        case "d": answer = .deny
        case "x": answer = .cancel
        default:
            guard parts[2].first == "q", let index = Int(parts[2].dropFirst()),
                (0..<8).contains(index), parts[2] == "q\(index)"
            else { return nil }
            answer = .choice(index)
        }
        requestID = id
        self.answer = answer
    }

    var encoded: String {
        let suffix: String
        switch answer {
        case .approve: suffix = "a"
        case .deny: suffix = "d"
        case .cancel: suffix = "x"
        case .choice(let index): suffix = "q\(index)"
        case .text: preconditionFailure("Text answers cannot be callback data")
        }
        return "qt1:\(requestID.uuidString.lowercased()):\(suffix)"
    }
}

extension AgentInteractionAnswer {
    fileprivate var isCallbackAnswer: Bool {
        switch self {
        case .approve, .deny, .cancel: true
        case .choice(let index): (0..<8).contains(index)
        case .text: false
        }
    }
}

struct TelegramInlineButton: Encodable, Equatable, Sendable {
    let text: String
    let callbackData: String

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TelegramPrompt: Sendable {
    let text: String
    let buttons: [[TelegramInlineButton]]

    init(snapshot: AgentInteractionSnapshot) throws {
        guard snapshot.state == .pending else { throw AgentInteractionError.requestUnavailable }
        let request = snapshot.request
        var lines = [
            "QuickTTY · \(snapshot.presentation.workspaceName) · \(snapshot.presentation.agentName)",
            "",
        ]
        var rows: [[TelegramInlineButton]] = []
        func button(_ label: String, _ answer: AgentInteractionAnswer) -> TelegramInlineButton {
            TelegramInlineButton(
                text: label,
                callbackData: TelegramCallbackData(requestID: request.id, answer: answer).encoded
            )
        }
        switch request.prompt {
        case .question(let question, let choices):
            lines.append(question)
            for (index, choice) in choices.enumerated() {
                lines.append("\(index + 1). \(choice)")
                rows.append([button(choice, .choice(index))])
            }
            lines.append("\nОтветьте на это сообщение или выберите вариант.")
        case .action(let action):
            lines += [
                "Действие:", action.operation,
                "\nРесурсы:", action.resources,
                "\nПоследствия:", action.consequences,
            ]
            if action.risk == .elevated {
                lines += [
                    "\nДля однократного подтверждения ответьте на это сообщение точной фразой:",
                    request.confirmationPhrase,
                ]
                rows.append([button("Отказать", .deny)])
            } else {
                lines.append("\nРазрешение только на указанное действие, один раз.")
                rows.append([button("Разрешить один раз", .approve), button("Отказать", .deny)])
            }
        }
        rows.append([button("Отменить запрос", .cancel)])
        let rendered = lines.joined(separator: "\n")
        // Never truncate an operation: the visible payload must describe the entire decision.
        guard rendered.utf16.count <= 4_096 else { throw AgentInteractionError.invalidText }
        text = rendered
        buttons = rows
    }
}
