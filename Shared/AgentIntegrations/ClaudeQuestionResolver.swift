import Foundation

struct ClaudeQuestionResolver: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case unavailable
        case closed
        case timedOut
        case invalidReply
    }

    let send: @Sendable (AgentMessagingRequest) throws -> AgentMessagingResponse
    var isCancelled: @Sendable () -> Bool = { false }
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    var timeout: Duration = .seconds(300)

    func resolve(_ hook: ClaudeQuestionHook) throws -> Data {
        let deadline = now().advanced(by: timeout)
        var pending: AgentMessagingRequest?
        var answers: [AgentMessagingResponse] = []
        defer {
            if let pending {
                _ = try? send(
                    AgentMessagingRequest(
                        version: 1, operation: .cancel, requestID: pending.requestID,
                        sessionID: pending.sessionID))
            }
        }
        for request in try hook.requests() {
            try check(deadline)
            pending = request
            var response = try exchange(request)
            let accepted = !answers.isEmpty || response.state != "error"
            while response.state == "pending" {
                try check(deadline)
                do {
                    response = try exchange(
                        AgentMessagingRequest(
                            version: 1, operation: .wait, requestID: request.requestID,
                            timeoutMilliseconds: 1_000, sessionID: request.sessionID))
                } catch { throw Failure.closed }
            }
            try check(deadline)
            if response.state == "error" {
                if !accepted, ["unavailable", "permissionRequired"].contains(response.code ?? "") {
                    pending = nil
                    throw Failure.unavailable
                }
                throw Failure.closed
            }
            switch response.state {
            case "text":
                guard let text = response.text,
                    request.choices?.contains(where: { $0.utf8.elementsEqual(text.utf8) }) == true
                else { throw Failure.invalidReply }
            case "choice":
                guard let text = response.text, let index = response.choiceIndex,
                    let choices = request.choices, choices.indices.contains(index),
                    choices[index].utf8.elementsEqual(text.utf8)
                else { throw Failure.invalidReply }
            case "cancelled", "expired", "revoked": throw Failure.closed
            default: throw Failure.invalidReply
            }
            answers.append(response)
            pending = nil
        }
        do { return try hook.output(answers: answers) } catch { throw Failure.invalidReply }
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        guard !isCancelled() else { throw Failure.closed }
        guard now() < deadline else { throw Failure.timedOut }
    }

    private func exchange(_ request: AgentMessagingRequest) throws -> AgentMessagingResponse {
        let response: AgentMessagingResponse
        do {
            response = try receive(request)
        } catch let error as Failure {
            throw error
        } catch {
            return try recover(request)
        }
        if response.state == "error",
            ["deliveryUncertain", "timedOut"].contains(response.code ?? "")
        {
            return try recover(request)
        }
        return response
    }

    private func recover(_ request: AgentMessagingRequest) throws -> AgentMessagingResponse {
        // A lost acknowledgement must never create or resubmit a question.
        do {
            return try receive(
                AgentMessagingRequest(
                    version: 1, operation: .status, requestID: request.requestID,
                    sessionID: request.sessionID))
        } catch let error as Failure {
            throw error
        } catch { throw Failure.unavailable }
    }

    private func receive(_ request: AgentMessagingRequest) throws -> AgentMessagingResponse {
        let response = try send(request)
        do { try response.validate(for: request) } catch { throw Failure.invalidReply }
        return response
    }
}
