import Foundation

@main
struct AgentMessagingContract {
    static func main() async throws {
        defer { fflush(nil) }
        if CommandLine.arguments.count == 7, CommandLine.arguments[1] == "--pi-e2e" {
            try await AgentMessagingPiE2EContract.run(
                repository: CommandLine.arguments[2], rootPath: CommandLine.arguments[3],
                node: CommandLine.arguments[4], package: CommandLine.arguments[5],
                helper: CommandLine.arguments[6])
            return
        }
        try ledgerContract()
        try isolationContract()
        try routingContract()
        try pairingContract()
        try await clientContract()
        try await AgentMessagingRuntimeContract.run()
        try await AgentMessagingAutoconnectContract.run()
        try await AgentMessagingIPCContract.run()
        try await AgentMessagingHostContract.run()
        try await AgentMessagingInstallerContract.run()
        try AgentMessagingClaudeQuestionContract.run()
        print("PASS: agent messaging contracts (no GUI, network, or credentials)")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ContractFailure(message: message) }
    }

    static func rejects(
        _ expected: AgentInteractionError,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as AgentInteractionError {
            try require(error == expected, "Unexpected interaction error")
            return
        }
        throw ContractFailure(message: "Invalid interaction was accepted")
    }

    static func origin(
        instanceID: UUID = UUID(),
        paneID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        sessionID: String = "opaque-session",
        generation: UInt64 = 1
    ) throws -> AgentInteractionOrigin {
        try AgentInteractionOrigin(
            instanceID: instanceID, workspaceID: workspaceID, paneID: paneID,
            adapterID: "pi", sessionID: sessionID, generation: generation
        )
    }

    static func request(
        origin: AgentInteractionOrigin,
        id: UUID = UUID(),
        prompt: AgentInteractionPrompt = .question(text: "Which option?", choices: ["One", "Two"])
    ) throws -> AgentInteractionRequest {
        try AgentInteractionRequest(
            id: id, origin: origin, prompt: prompt, timeoutMilliseconds: 1_000)
    }

    static func authorizedLedger(_ origin: AgentInteractionOrigin) throws -> AgentInteractionLedger
    {
        var ledger = AgentInteractionLedger()
        ledger.setEnabledWorkspaces([origin.workspaceID], now: 0)
        try ledger.authorize(origin, workspaceName: "Workspace", agentName: "Pi", now: 0)
        return ledger
    }

    static func ledgerContract() throws {
        let first = try origin()
        let question = try request(origin: first)
        var ledger = AgentInteractionLedger()
        try rejects(.notAuthorized) { _ = try ledger.submit(question, now: 0) }
        ledger = try authorizedLedger(first)
        let pending = try ledger.submit(question, now: 0)
        try require(pending.state == .pending, "New request is not pending")
        try require(try ledger.submit(question, now: 10) == pending, "Replay changed the deadline")
        let conflict = try request(
            origin: first, id: question.id, prompt: .question(text: "Changed", choices: []))
        try rejects(.requestIDConflict) { _ = try ledger.submit(conflict, now: 20) }
        try rejects(.capacityExceeded) { _ = try ledger.submit(request(origin: first), now: 20) }
        try rejects(.invalidAnswer) {
            _ = try ledger.resolveLocal(question.id, answer: .choice(2), now: 20)
        }
        let resolved = try ledger.resolveLocal(question.id, answer: .choice(1), now: 20)
        try require(resolved.state == .resolved(.choice(index: 1, label: "Two")), "Wrong choice")
        try rejects(.requestUnavailable) {
            _ = try ledger.resolveLocal(question.id, answer: .choice(0), now: 21)
        }
        try require(
            try ledger.submit(question, now: 22) == resolved, "Resolved replay was not stable")

        let elevated = try request(
            origin: first,
            prompt: .action(
                try AgentInteractionAction(
                    operation: "Deploy exact revision", resources: "test-service",
                    consequences: "Service will restart", risk: .elevated
                ))
        )
        _ = try ledger.submit(elevated, now: 30)
        try rejects(.invalidAnswer) {
            _ = try ledger.resolveLocal(elevated.id, answer: .approve, now: 31)
        }
        try rejects(.invalidAnswer) {
            _ = try ledger.resolveLocal(elevated.id, answer: .text("yes"), now: 31)
        }
        try rejects(.invalidAnswer) {
            _ = try ledger.resolveLocal(
                elevated.id, answer: .text(elevated.confirmationPhrase + " "), now: 31)
        }
        let approved = try ledger.resolveLocal(
            elevated.id, answer: .text(elevated.confirmationPhrase), now: 32)
        try require(approved.state == .resolved(.approved), "Exact elevated confirmation failed")

        let expired = try request(origin: first)
        _ = try ledger.submit(expired, now: 100)
        try rejects(.requestUnavailable) {
            _ = try ledger.resolveLocal(expired.id, answer: .text("late"), now: 1_100)
        }
        try require(
            ledger.snapshot(expired.id, now: 1_100)?.state == .resolved(.expired), "Expiry boundary"
        )
        let revoked = try request(origin: first)
        _ = try ledger.submit(revoked, now: 1_101)
        ledger.revoke(first, now: 1_102)
        try rejects(.requestUnavailable) {
            _ = try ledger.resolveLocal(revoked.id, answer: .text("late"), now: 1_102)
        }
        try require(
            ledger.snapshot(revoked.id, now: 1_102)?.state == .resolved(.revoked),
            "Revocation failed")
        try rejects(.notAuthorized) { _ = try ledger.submit(question, now: 1_103) }

        ledger = try authorizedLedger(first)
        _ = try ledger.submit(question, now: 0)
        let replacement = try origin(
            instanceID: first.instanceID, paneID: first.paneID,
            workspaceID: first.workspaceID, generation: 2)
        try ledger.authorize(replacement, workspaceName: "Workspace", agentName: "Pi", now: 1)
        try require(
            ledger.snapshot(question.id, now: 1)?.state == .resolved(.revoked),
            "Old generation survived")
        try rejects(.notAuthorized) { _ = try ledger.submit(question, now: 2) }
        let next = try request(origin: replacement)
        _ = try ledger.submit(next, now: 2)
        let switched = try origin(
            instanceID: first.instanceID, paneID: first.paneID,
            workspaceID: first.workspaceID, sessionID: "different-session", generation: 2)
        try ledger.authorize(switched, workspaceName: "Workspace", agentName: "Pi", now: 3)
        try require(
            ledger.snapshot(next.id, now: 3)?.state == .resolved(.revoked),
            "Session switch kept old question")
        let switchedRequest = try request(origin: switched)
        _ = try ledger.submit(switchedRequest, now: 3)
        ledger.setEnabledWorkspaces([], now: 4)
        try require(
            ledger.snapshot(switchedRequest.id, now: 4)?.state == .resolved(.revoked),
            "Workspace opt-out failed")

        var bounded = AgentInteractionLedger(maximumRecords: 1)
        bounded.setEnabledWorkspaces([first.workspaceID], now: 0)
        try bounded.authorize(first, workspaceName: "Workspace", agentName: "Pi", now: 0)
        _ = try bounded.submit(question, now: 0)
        _ = try bounded.resolveLocal(question.id, answer: .cancel, now: 1)
        try rejects(.capacityExceeded) { _ = try bounded.submit(request(origin: first), now: 2) }
        try require(bounded.recordCount == 1, "Ledger silently evicted replay protection")
        try rejects(.invalidText) {
            _ = try request(
                origin: first, prompt: .question(text: "Hidden\u{202E}operation", choices: []))
        }
        try rejects(.invalidChoices) {
            _ = try request(
                origin: first, prompt: .question(text: "Choose", choices: ["Same", "Same"]))
        }
        try rejects(.invalidText) {
            _ = try AgentInteractionAction(
                operation: String(repeating: "x", count: 1_025), resources: "service",
                consequences: "restart", risk: .standard)
        }
        var overflow = try authorizedLedger(first)
        try rejects(.clockExhausted) { _ = try overflow.submit(question, now: UInt64.max) }
    }

    static func isolationContract() throws {
        let first = try origin()
        let second = try origin()
        var ledger = try authorizedLedger(first)
        ledger.setEnabledWorkspaces([first.workspaceID, second.workspaceID], now: 0)
        try ledger.authorize(second, workspaceName: "Other", agentName: "Other agent", now: 0)
        let firstRequest = try request(origin: first)
        let secondRequest = try request(origin: second)
        _ = try ledger.submit(firstRequest, now: 0)
        _ = try ledger.submit(secondRequest, now: 0)
        let firstMessage = try TelegramMessageReference(chatID: 42, messageID: 1)
        let secondMessage = try TelegramMessageReference(chatID: 42, messageID: 2)
        _ = try ledger.bindTelegram(firstRequest.id, message: firstMessage, now: 1)
        try rejects(.messageAlreadyBound) {
            _ = try ledger.bindTelegram(secondRequest.id, message: firstMessage, now: 1)
        }
        _ = try ledger.bindTelegram(secondRequest.id, message: secondMessage, now: 1)
        try rejects(.invalidTelegramMessage) {
            _ = try ledger.resolveTelegram(
                firstRequest.id, message: secondMessage, answer: .text("Wrong session"), now: 1)
        }
        _ = try ledger.resolveLocal(firstRequest.id, answer: .text("Local wins"), now: 2)
        try rejects(.requestUnavailable) {
            _ = try ledger.resolveTelegram(
                firstRequest.id, message: firstMessage, answer: .text("Remote loses"), now: 2)
        }
        _ = try ledger.resolveTelegram(
            secondRequest.id, message: secondMessage, answer: .choice(0), now: 2)
        try rejects(.requestUnavailable) {
            _ = try ledger.resolveLocal(secondRequest.id, answer: .text("Local loses"), now: 2)
        }
        try rejects(.requestIDConflict) {
            _ = try ledger.submit(request(origin: second, id: firstRequest.id), now: 3)
        }
        let liveFirst = try request(origin: first)
        let liveSecond = try request(origin: second)
        _ = try ledger.submit(liveFirst, now: 3)
        _ = try ledger.submit(liveSecond, now: 3)
        ledger.revoke(first, now: 4)
        try require(
            ledger.snapshot(liveSecond.id, now: 4)?.state == .pending,
            "Revoke crossed origin boundary")
        ledger.revokeAll(now: 5)
        try require(
            ledger.snapshot(liveSecond.id, now: 5)?.state == .resolved(.revoked),
            "Shutdown did not revoke pending requests")
        try rejects(.notAuthorized) { _ = try ledger.submit(request(origin: second), now: 5) }

        var bounded = AgentInteractionLedger(maximumPending: 1)
        bounded.setEnabledWorkspaces([first.workspaceID, second.workspaceID], now: 0)
        try bounded.authorize(first, workspaceName: "First", agentName: "Agent", now: 0)
        try bounded.authorize(second, workspaceName: "Second", agentName: "Agent", now: 0)
        _ = try bounded.submit(firstRequest, now: 0)
        try rejects(.capacityExceeded) { _ = try bounded.submit(secondRequest, now: 0) }

        var actions = try authorizedLedger(first)
        for (answer, resolution) in [
            (AgentInteractionAnswer.approve, AgentInteractionResolution.approved), (.deny, .denied),
            (.cancel, .cancelled),
        ] {
            let action = try request(
                origin: first,
                prompt: .action(
                    try AgentInteractionAction(
                        operation: "Run compiler-only build", resources: "Local checkout",
                        consequences: "Writes build artifacts", risk: .standard
                    )))
            _ = try actions.submit(action, now: 0)
            try rejects(.invalidAnswer) {
                _ = try actions.resolveLocal(action.id, answer: .text("yes"), now: 1)
            }
            let result = try actions.resolveLocal(action.id, answer: answer, now: 1)
            try require(result.state == .resolved(resolution), "Standard action decision failed")
        }
    }

    static func update(_ json: String) throws -> TelegramUpdate {
        try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    }

    static func routingContract() throws {
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let router = TelegramInteractionRouter(peer: peer)
        let first = try origin()
        var ledger = try authorizedLedger(first)
        let question = try request(origin: first)
        _ = try ledger.submit(question, now: 0)
        let reference = try TelegramMessageReference(chatID: 42, messageID: 100)
        _ = try ledger.bindTelegram(question.id, message: reference, now: 1)
        let body =
            "\"message_id\":101,\"date\":1,\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"My answer\",\"reply_to_message\":{\"message_id\":100}"
        for invalid in [
            body.replacingOccurrences(of: "\"id\":42,\"is_bot\"", with: "\"id\":43,\"is_bot\""),
            body.replacingOccurrences(of: "\"type\":\"private\"", with: "\"type\":\"group\""),
            body.replacingOccurrences(of: "\"message_id\":100", with: "\"message_id\":99"),
            body + ",\"forward_origin\":{}",
            body + ",\"via_bot\":{\"id\":9,\"is_bot\":true}",
            body + ",\"sender_chat\":{\"id\":42,\"type\":\"private\"}",
            body + ",\"business_connection_id\":\"another-chat-namespace\"",
            body + ",\"guest_query_id\":\"another-chat-namespace\"",
            body + ",\"guest_bot_caller_user\":{\"id\":42,\"is_bot\":false}",
            body + ",\"is_automatic_forward\":true",
            body.replacingOccurrences(of: "\"is_bot\":false", with: "\"is_bot\":true"),
        ] {
            let ignored = try router.route(
                update("{\"update_id\":1,\"message\":{\(invalid)}}"), ledger: &ledger, now: 2)
            try require(ignored == nil, "Untrusted Telegram message accepted")
        }
        let edited = try update("{\"update_id\":1,\"edited_message\":{\(body)}}")
        try require(
            try router.route(edited, ledger: &ledger, now: 2) == nil, "Edited message accepted")
        let valid = try update("{\"update_id\":2,\"message\":{\(body)}}")
        let answer = try router.route(valid, ledger: &ledger, now: 2)
        try require(answer?.state == .resolved(.text("My answer")), "Reply did not resolve request")
        try require(
            try router.route(valid, ledger: &ledger, now: 3) == nil,
            "Telegram update replay accepted")

        let second = try request(origin: first)
        let snapshot = try ledger.submit(second, now: 4)
        let secondReference = try TelegramMessageReference(chatID: 42, messageID: 102)
        _ = try ledger.bindTelegram(second.id, message: secondReference, now: 4)
        let callback = TelegramCallbackData(requestID: second.id, answer: .choice(1))
        let callbackJSON =
            "{\"update_id\":3,\"callback_query\":{\"id\":\"query-id\",\"from\":{\"id\":42,\"is_bot\":false},\"data\":\"\(callback.encoded)\",\"message\":{\"message_id\":102,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}}}"
        let forged = callbackJSON.replacingOccurrences(
            of: "\"message_id\":102", with: "\"message_id\":100")
        try require(
            try router.route(update(forged), ledger: &ledger, now: 5) == nil,
            "Forged callback accepted")
        let selected = try router.route(update(callbackJSON), ledger: &ledger, now: 5)
        try require(
            selected?.state == .resolved(.choice(index: 1, label: "Two")), "Callback choice failed")
        try require(
            try router.route(update(callbackJSON), ledger: &ledger, now: 6) == nil,
            "Callback replay accepted")
        let prompt = try TelegramPrompt(snapshot: snapshot)
        try require(prompt.text.utf16.count <= 4_096, "Oversized rendered prompt")
        try require(!prompt.text.contains(first.sessionID), "Session ID leaked into Telegram")
        try require(!prompt.text.contains(first.paneID.uuidString), "Pane ID leaked into Telegram")
        try require(
            prompt.buttons.flatMap { $0 }.allSatisfy { $0.callbackData.utf8.count <= 64 },
            "Oversized callback")
        try require(
            TelegramCallbackData(encoded: callback.encoded + "x") == nil,
            "Malformed callback accepted")
        try require(
            TelegramCallbackData(encoded: "qt1:\(second.id.uuidString.lowercased()):q01") == nil,
            "Noncanonical callback accepted")

        let actionRequest = try request(
            origin: first,
            prompt: .action(
                try AgentInteractionAction(
                    operation: "Delete test object", resources: "test-object",
                    consequences: "Cannot undo", risk: .elevated
                )))
        let actionSnapshot = try ledger.submit(actionRequest, now: 7)
        let actionPrompt = try TelegramPrompt(snapshot: actionSnapshot)
        try require(
            actionPrompt.text.contains(actionRequest.confirmationPhrase), "Missing elevated phrase")
        try require(
            actionPrompt.buttons.flatMap { $0 }.allSatisfy { !$0.callbackData.hasSuffix(":a") },
            "Elevated approval button exists")
        _ = try ledger.resolveLocal(actionRequest.id, answer: .deny, now: 8)
        try rejects(.requestUnavailable) {
            _ = try ledger.bindTelegram(
                actionRequest.id, message: try TelegramMessageReference(chatID: 42, messageID: 103),
                now: 9)
        }
    }

    static func pairingContract() throws {
        var pairing = try TelegramPairingChallenge(now: 10)
        let message =
            "\"message_id\":1,\"date\":1,\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"/start \(pairing.code)\""
        let wrong = message.replacingOccurrences(of: pairing.code, with: "incorrect")
        try require(
            try pairing.propose(update("{\"update_id\":1,\"message\":{\(wrong)}}"), now: 11) == nil,
            "Wrong pairing code accepted")
        let forwarded = message + ",\"forward_origin\":{}"
        try require(
            try pairing.propose(update("{\"update_id\":1,\"message\":{\(forwarded)}}"), now: 11)
                == nil, "Forwarded pairing accepted")
        let candidate = try pairing.propose(
            update("{\"update_id\":1,\"message\":{\(message)}}"), now: 11)
        try require(
            candidate?.peer == TelegramPeer(userID: 42, chatID: 42), "Pairing candidate missing")
        try require(
            pairing.confirmedPeer == nil,
            "Telegram message granted access without native confirmation")
        try require(
            try pairing.propose(update("{\"update_id\":1,\"message\":{\(message)}}"), now: 12)
                == nil, "Pairing code was reusable")
        try require(
            pairing.confirm(candidateID: UUID(), now: 12) == nil, "Wrong native candidate accepted")
        let peer = pairing.confirm(candidateID: candidate!.id, now: 12)
        try require(
            peer == candidate?.peer && pairing.confirmedPeer == peer,
            "Native pairing confirmation failed")
        try require(
            pairing.confirm(candidateID: candidate!.id, now: 13) == nil,
            "Native pairing confirmation reused")
        var expired = try TelegramPairingChallenge(now: 0)
        let expiredMessage = message.replacingOccurrences(of: pairing.code, with: expired.code)
        try require(
            try expired.propose(
                update("{\"update_id\":2,\"message\":{\(expiredMessage)}}"), now: 300_000) == nil,
            "Expired pairing accepted")
        var cancelled = try TelegramPairingChallenge(now: 0)
        let cancelledMessage = message.replacingOccurrences(of: pairing.code, with: cancelled.code)
        let cancelledCandidate = try cancelled.propose(
            update("{\"update_id\":3,\"message\":{\(cancelledMessage)}}"), now: 1)
        cancelled.cancel()
        try require(
            cancelled.confirm(candidateID: cancelledCandidate!.id, now: 2) == nil,
            "Cancelled pairing confirmed")
    }

    static func clientContract() async throws {
        let tokenText = "123456:contract-test-not-a-real-token"
        let token = try TelegramBotToken(tokenText)
        for invalid in [
            "", ":suffix", "123:", "123:token/elsewhere", "123:token?query", "123:token\n",
            "123:token@host",
        ] {
            do {
                _ = try TelegramBotToken(invalid)
                throw ContractFailure(message: "Unsafe token accepted into endpoint")
            } catch let error as TelegramBotClientError {
                try require(error == .invalidToken, "Wrong invalid token error")
            }
        }
        try require(!String(describing: token).contains(tokenText), "Token description leaked")
        try require(
            !String(reflecting: token).contains(tokenText), "Token debug description leaked")
        let transport = MockTelegramTransport()
        let client = TelegramBotClient(
            token: token, transport: { request in try await transport.send(request) })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await client.getMe()
                return false
            } catch let error as TelegramBotClientError {
                return error == .cancelled
            } catch {
                return false
            }
        }
        let wasCancelled = await cancelled.value
        try require(wasCancelled, "Cancelled task reached Telegram transport")
        let beforePolling = await transport.callCount
        try require(beforePolling == 0, "Cancelled task made a network request")
        do {
            _ = try await client.getUpdates(offset: -1)
            throw ContractFailure(message: "Negative offset could discard updates")
        } catch let error as TelegramBotClientError {
            try require(error == .invalidRequest, "Wrong invalid offset error")
        }
        let updates = try await client.getUpdates(offset: 3)
        try require(updates.isEmpty, "Unexpected mock updates")
        let pollingRequest = await transport.lastRequest
        try require(pollingRequest?.httpMethod == "POST", "Telegram method is not POST")
        try require(pollingRequest?.url?.host == "api.telegram.org", "Wrong Telegram host")
        let json =
            try JSONSerialization.jsonObject(with: pollingRequest!.httpBody!) as! [String: Any]
        try require(json["offset"] as? Int == 3, "Offset was lost")
        try require(
            json["allowed_updates"] as? [String] == ["message", "callback_query"],
            "Broad update subscription")
        try require(json["timeout"] as? Int == 25, "Missing bounded long poll")
        let bot = try await client.getMe()
        try require(bot.isBot, "getMe did not return a bot")

        let first = try origin()
        var ledger = try authorizedLedger(first)
        let snapshot = try ledger.submit(try request(origin: first), now: 0)
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let sent = try await client.sendPrompt(snapshot, to: peer)
        try require(
            sent == TelegramMessageReference(chatID: 42, messageID: 100),
            "Wrong sent message binding")
        let sendRequest = await transport.lastRequest
        let sendJSON =
            try JSONSerialization.jsonObject(with: sendRequest!.httpBody!) as! [String: Any]
        try require(sendJSON["parse_mode"] == nil, "Prompt enables Telegram markup")
        try require(sendJSON["protect_content"] as? Bool == true, "Prompt content is not protected")
        try require(
            (sendJSON["link_preview_options"] as? [String: Bool])?["is_disabled"] == true,
            "Link preview enabled")
        try require(
            !(String(data: sendRequest!.httpBody!, encoding: .utf8)!).contains(first.sessionID),
            "Wire leaked session ID")
        try await client.answerCallbackQuery("query-id", text: "Answered")
        try await client.clearButtons(sent)

        for (status, body, expected) in [
            (
                401, "{\"ok\":false,\"error_code\":401,\"description\":\"\(tokenText)\"}",
                TelegramBotClientError.unauthorized
            ),
            (409, "{\"ok\":false,\"error_code\":409}", .conflict),
            (
                429, "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":7}}",
                .rateLimited(retryAfterSeconds: 7)
            ),
            (200, "{\"ok\":true,\"result\":null}", .invalidResponse),
            (200, "not JSON \(tokenText)", .invalidResponse),
            (302, "", .invalidResponse),
            (503, "", .unavailable),
        ] {
            await transport.configure(status: status, body: body)
            do {
                _ = try await client.getUpdates(offset: nil)
                throw ContractFailure(message: "Invalid Telegram response accepted")
            } catch let error as TelegramBotClientError {
                try require(error == expected, "Wrong Telegram error classification")
                try require(
                    !String(reflecting: error).contains(tokenText), "Telegram error leaked token")
            }
        }
        await transport.configure(
            status: 200,
            body: String(repeating: "x", count: TelegramBotClient.maximumResponseBytes + 1))
        do {
            _ = try await client.getMe()
            throw ContractFailure(message: "Oversized response accepted")
        } catch let error as TelegramBotClientError {
            try require(error == .invalidResponse, "Wrong oversized response error")
        }
        await transport.configure(status: 200, body: "{\"ok\":true,\"result\":[]}", redirect: true)
        do {
            _ = try await client.getUpdates(offset: nil)
            throw ContractFailure(message: "Redirect accepted")
        } catch let error as TelegramBotClientError {
            try require(error == .invalidResponse, "Wrong redirect error")
        }
        for (status, body) in [
            (503, ""), (200, "invalid JSON"), (200, "{\"ok\":true,\"result\":null}"),
        ] {
            await transport.configure(status: status, body: body)
            let before = await transport.callCount
            do {
                _ = try await client.sendPrompt(snapshot, to: peer)
                throw ContractFailure(message: "Uncertain send succeeded")
            } catch let error as TelegramBotClientError {
                try require(
                    error == .deliveryUncertain, "Ambiguous send may be retried as a safe failure")
            }
            let after = await transport.callCount
            try require(after == before + 1, "Telegram client silently retried a send")
        }
        await transport.configure(status: 200, body: nil, failure: true)
        do {
            _ = try await client.sendPrompt(snapshot, to: peer)
            throw ContractFailure(message: "Failed send succeeded")
        } catch let error as TelegramBotClientError {
            try require(error == .deliveryUncertain, "Failed send was not classified uncertain")
            try require(
                !String(reflecting: error).contains(tokenText), "Raw transport error escaped")
        }
    }
}

private struct ContractFailure: Error {
    let message: String
}

private actor MockTelegramTransport {
    var lastRequest: URLRequest?
    var callCount = 0
    private var status = 200
    private var body: String?
    private var redirect = false
    private var failure = false

    func configure(status: Int, body: String?, redirect: Bool = false, failure: Bool = false) {
        self.status = status
        self.body = body
        self.redirect = redirect
        self.failure = failure
    }

    func send(_ request: URLRequest) throws -> TelegramHTTPResponse {
        lastRequest = request
        callCount += 1
        if failure {
            throw NSError(domain: request.url!.absoluteString, code: -1)
        }
        let result: String
        switch request.url!.lastPathComponent {
        case "getMe": result = "{\"id\":1,\"is_bot\":true}"
        case "sendMessage", "editMessageReplyMarkup":
            result = "{\"message_id\":100,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
        case "answerCallbackQuery": result = "true"
        default: result = "[]"
        }
        let url = redirect ? URL(string: "https://example.invalid/redirect")! : request.url!
        return TelegramHTTPResponse(
            data: Data((body ?? "{\"ok\":true,\"result\":\(result)}").utf8),
            response: HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
