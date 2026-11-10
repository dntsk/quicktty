import Foundation
import Synchronization

struct AgentMessagingClaudeQuestionContract {
    static func run() throws {
        let data = try input()
        let hook = try ClaudeQuestionHook(input: data)
        let requests = try hook.requests()
        try AgentMessagingContract.require(requests.count == 2, "Claude question count changed")
        try AgentMessagingContract.require(
            try requests == ClaudeQuestionHook(input: data).requests(),
            "Claude request identities are unstable")
        try AgentMessagingContract.require(
            requests[0].requestID != requests[1].requestID, "Claude questions share an identity")
        for request in requests {
            try AgentMessagingContract.require(
                request.operation == .question && request.sessionID == "private-claude-fixture",
                "Claude request lost session binding")
            try AgentMessagingContract.require(
                request.text?.contains("DO-NOT-FORWARD") == false
                    && request.text?.contains("private-claude-fixture") == false,
                "Claude projection forwarded private metadata")
            try AgentMessagingContract.require(
                request.text?.contains("First option description") == true,
                "Claude projection dropped option context")
            try request.validate()
        }
        let answers = [
            AgentMessagingResponse(
                version: 1, requestID: requests[0].requestID, state: "choice", text: "Two",
                choiceIndex: 1),
            AgentMessagingResponse(
                version: 1, requestID: requests[1].requestID, state: "text",
                text: "One"),
        ]
        let output = try hook.output(answers: answers)
        let root = try JSONSerialization.jsonObject(with: output) as! [String: Any]
        let specific = root["hookSpecificOutput"] as! [String: Any]
        let updated = specific["updatedInput"] as! [String: Any]
        try AgentMessagingContract.require(
            specific["hookEventName"] as? String == "PreToolUse"
                && specific["permissionDecision"] as? String == "allow",
            "Claude output used the wrong schema")
        try AgentMessagingContract.require(
            updated["answers"] as? [String: String] == [
                "First question?": "Two", "Second question?": "One",
            ], "Claude answers were not mapped by original question text")
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let originalInput = original["tool_input"] as! [String: Any]
        let oldQuestions = originalInput["questions"] as! NSArray
        try AgentMessagingContract.require(
            updated["questions"] as? NSArray == oldQuestions,
            "Claude updatedInput changed the original questions")
        let outputText = String(decoding: output, as: UTF8.self)
        try AgentMessagingContract.require(
            !outputText.contains("DO-NOT-FORWARD") && !outputText.contains("private-claude-fixture")
                && specific["updatedPermissions"] == nil,
            "Claude output exposed metadata or changed permissions")
        let changed = try ClaudeQuestionHook(input: input(firstQuestion: "Changed question?"))
            .requests()
        try AgentMessagingContract.require(
            changed[0].requestID == requests[0].requestID && changed[0].text != requests[0].text,
            "Payload change evaded ledger conflict")
        let switched = try ClaudeQuestionHook(input: input(sessionID: "other-session")).requests()
        try AgentMessagingContract.require(
            switched[0].requestID != requests[0].requestID, "Claude session identities collided")
        let anotherCall = try ClaudeQuestionHook(input: input(toolID: "other-tool-call")).requests()
        try AgentMessagingContract.require(
            anotherCall[0].requestID != requests[0].requestID,
            "Claude tool-call identities collided")

        let duplicate = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "\"session_id\":", with: "\"session_id\":\"shadow\",\"session_id\":")
        let oversizedOptions = (0..<4).map {
            ["label": "Choice \($0)", "description": String(repeating: "x", count: 700)]
        }
        for bad in [
            try input(toolName: "Bash"), try input(event: "PermissionRequest"),
            try input(multiSelect: true),
            try input(extraInput: ["answers": ["First question?": "Forged"]]),
            try input(firstQuestion: "Second question?"),
            try input(firstQuestion: "\u{202E}Hidden"),
            try input(firstQuestion: String(repeating: "x", count: 2_305)),
            try input(extraQuestion: ["sensitive": true]),
            try input(extraQuestion: ["multiSelect": 1]),
            try input(extraQuestion: ["multiSelect": NSNull()]),
            try input(extraQuestion: ["options": oversizedOptions]),
            try input(firstQuestion: "Cafe\u{301}?"),
            try input(extraRoot: ["agent_id": "subagent"]),
            try input(extraRoot: ["metadata": String(repeating: "x", count: 65_536)]),
            Data(duplicate.utf8),
        ] { try rejectsInput(bad) }
        for bad in [
            [], [answers[0]],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "text",
                    text: "Unlisted answer"), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: UUID(), state: "text", text: "Wrong ID"), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "approved"), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "pending"), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "choice",
                    text: "Forged label", choiceIndex: 1), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "choice", text: "One",
                    choiceIndex: 2), answers[1],
            ],
            [
                AgentMessagingResponse(
                    version: 1, requestID: requests[0].requestID, state: "text",
                    text: "\u{1B}escape"), answers[1],
            ],
        ] { try rejectsAnswers(hook, bad) }
        try resolverContract(hook)
        try runtimeContract()
        print(
            "PASS: Claude question codec/resolver/runtime-gate contracts (no vendor process or installed settings change)"
        )
    }

    static func input(
        sessionID: String = "private-claude-fixture", toolID: String = "toolu_fixture",
        toolName: String = "AskUserQuestion", event: String = "PreToolUse",
        firstQuestion: String = "First question?", multiSelect: Bool = false,
        extraInput: [String: Any] = [:], extraQuestion: [String: Any] = [:],
        extraRoot: [String: Any] = [:]
    ) throws -> Data {
        var first: [String: Any] = [
            "question": firstQuestion, "header": "Fixture", "multiSelect": multiSelect,
            "options": [
                ["label": "One", "description": "First option description"],
                ["label": "Two", "description": "Second option description"],
            ],
        ]
        first.merge(extraQuestion) { _, new in new }
        var second = first
        second["question"] = "Second question?"
        var toolInput: [String: Any] = ["questions": [first, second]]
        toolInput.merge(extraInput) { _, new in new }
        var root: [String: Any] = [
            "hook_event_name": event, "tool_name": toolName, "tool_use_id": toolID,
            "session_id": sessionID, "tool_input": toolInput,
            "transcript_path": "/DO-NOT-FORWARD/transcript", "cwd": "/DO-NOT-FORWARD/workspace",
        ]
        root.merge(extraRoot) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func runtimeContract() throws {
        let verified = "677a2ea7bf576cedd20e191d973914ed8a41796f53a63b1923381ddc4d5b5e7d"
        let direct = ClaudeQuestionRuntime.Caller(
            parentPID: 1, uid: 501, executable: "/fixture/claude")
        try AgentMessagingContract.require(
            ClaudeQuestionRuntime.isVerified(
                parentPID: 10, uid: 501, caller: { _ in direct }, fingerprint: { _ in verified }),
            "Verified native Claude caller was rejected")
        try AgentMessagingContract.require(
            !ClaudeQuestionRuntime.isVerified(
                parentPID: 10, uid: 502, caller: { _ in direct }, fingerprint: { _ in verified }),
            "Another UID supplied a verified caller")
        try AgentMessagingContract.require(
            ClaudeQuestionRuntime.isVerified(
                parentPID: 10, uid: 501,
                caller: { _ in .init(parentPID: 1, uid: 501, executable: "/fixture/2.1.318") },
                fingerprint: { _ in verified }),
            "A renamed exact verified artifact depended on its filename")
        var visited: [Int32] = []
        let unknown = ClaudeQuestionRuntime.isVerified(
            parentPID: 10, uid: 501,
            caller: { pid in
                visited.append(pid)
                return .init(
                    parentPID: pid + 1, uid: 501,
                    executable: pid == 10 ? "/fixture/new-cli" : "/fixture/claude")
            }, fingerprint: { path in path == "/fixture/claude" ? verified : "wrong" })
        try AgentMessagingContract.require(
            !unknown && visited == [10],
            "An unverified non-shell caller inherited an ancestor runtime")
        visited.removeAll()
        let nearest = ClaudeQuestionRuntime.isVerified(
            parentPID: 10, uid: 501,
            caller: { pid in
                visited.append(pid)
                return .init(
                    parentPID: pid + 1, uid: 501,
                    executable: pid == 10 ? "/bin/sh" : "/unverified/claude")
            }, fingerprint: { path in path == "/unverified/claude" ? "wrong" : verified })
        try AgentMessagingContract.require(
            !nearest && visited == [10, 11], "Unverified nearest Claude was skipped")
        visited.removeAll()
        let bounded = ClaudeQuestionRuntime.isVerified(
            parentPID: 10, uid: 501,
            caller: { pid in
                visited.append(pid)
                return .init(parentPID: pid + 1, uid: 501, executable: "/bin/sh")
            }, fingerprint: { _ in verified })
        try AgentMessagingContract.require(
            !bounded && visited.count == 4, "Caller inspection was unbounded")
        try AgentMessagingContract.require(
            !ClaudeQuestionRuntime.isVerified(
                parentPID: 10, uid: 501, caller: { _ in direct },
                fingerprint: { _ in throw ClaudeContractFailure() }),
            "Fingerprint failure enabled an unknown runtime")
        let file = URL(fileURLWithPath: CommandLine.arguments[2]).appending(
            path: "fingerprint-fixture")
        try Data("abc".utf8).write(to: file)
        try AgentMessagingContract.require(
            try ClaudeQuestionRuntime.fingerprint(file.path)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "Runtime fingerprint was not SHA256 of executable bytes")
    }

    private static func resolverContract(_ hook: ClaudeQuestionHook) throws {
        for uncertain in [false, true] {
            let calls = Mutex([AgentMessagingRequest]())
            let resolver = ClaudeQuestionResolver(send: { request in
                let count = calls.withLock {
                    $0.append(request)
                    return $0.count
                }
                if uncertain && count == 1 { throw ClaudeContractFailure() }
                return AgentMessagingResponse(
                    version: 1, requestID: request.requestID,
                    state: request.operation == .wait ? "choice" : "pending",
                    text: request.operation == .wait ? "Two" : nil,
                    choiceIndex: request.operation == .wait ? 1 : nil)
            })
            let output = try resolver.resolve(hook)
            let expected = try hook.output(
                answers: hook.requests().map {
                    AgentMessagingResponse(
                        version: 1, requestID: $0.requestID, state: "choice", text: "Two",
                        choiceIndex: 1)
                })
            try AgentMessagingContract.require(output == expected, "Resolver changed vendor output")
            let requests = calls.withLock { $0 }
            try AgentMessagingContract.require(
                requests.filter { $0.operation == .question }.count == 2,
                "Uncertain delivery resubmitted a question")
            try AgentMessagingContract.require(
                requests.filter { $0.operation == .status }.count == (uncertain ? 1 : 0),
                "Uncertain delivery did not use readonly recovery")
            try AgentMessagingContract.require(
                requests.allSatisfy { $0.sessionID == "private-claude-fixture" },
                "Resolver lost native session binding")
        }
        for state in ["cancelled", "expired", "revoked", "approved", "text"] {
            let resolver = ClaudeQuestionResolver(send: { request in
                AgentMessagingResponse(
                    version: 1, requestID: request.requestID, state: state,
                    text: state == "text" ? "Unlisted answer" : nil)
            })
            do {
                _ = try resolver.resolve(hook)
                throw ClaudeContractFailure()
            } catch is ClaudeQuestionResolver.Failure {}
        }
        let revoked = ClaudeQuestionResolver(send: { request in
            if request.operation == .wait {
                return .failure("permissionRequired", requestID: request.requestID)
            }
            return AgentMessagingResponse(
                version: 1, requestID: request.requestID,
                state: request.operation == .cancel ? "cancelled" : "pending")
        })
        do {
            _ = try revoked.resolve(hook)
            throw ClaudeContractFailure()
        } catch ClaudeQuestionResolver.Failure.closed {}
        let cancelled = Mutex(false)
        let calls = Mutex([AgentMessagingRequest.Operation]())
        let resolver = ClaudeQuestionResolver(
            send: { request in
                calls.withLock { $0.append(request.operation) }
                if request.operation == .wait { cancelled.withLock { $0 = true } }
                return AgentMessagingResponse(
                    version: 1, requestID: request.requestID,
                    state: request.operation == .cancel ? "cancelled" : "pending")
            }, isCancelled: { cancelled.withLock { $0 } })
        do {
            _ = try resolver.resolve(hook)
            throw ClaudeContractFailure()
        } catch ClaudeQuestionResolver.Failure.closed {}
        try AgentMessagingContract.require(
            calls.withLock { $0 } == [.question, .wait, .cancel],
            "Cancelled resolver left a pending request or started another question")
        let instant = Mutex(ContinuousClock.now)
        let expiryCalls = Mutex([AgentMessagingRequest.Operation]())
        let expiring = ClaudeQuestionResolver(
            send: { request in
                expiryCalls.withLock { $0.append(request.operation) }
                if request.operation == .wait {
                    instant.withLock { $0 = $0.advanced(by: .seconds(1)) }
                }
                return AgentMessagingResponse(
                    version: 1, requestID: request.requestID,
                    state: request.operation == .cancel ? "cancelled" : "pending")
            }, now: { instant.withLock { $0 } }, timeout: .seconds(1))
        do {
            _ = try expiring.resolve(hook)
            throw ClaudeContractFailure()
        } catch ClaudeQuestionResolver.Failure.timedOut {}
        try AgentMessagingContract.require(
            expiryCalls.withLock { $0 } == [.question, .wait, .cancel],
            "Deadline did not close the remote question")
    }

    private static func rejectsInput(_ data: Data) throws {
        do { _ = try ClaudeQuestionHook(input: data) } catch ClaudeQuestionHook.Failure.invalidInput
        { return }
        throw ClaudeContractFailure()
    }
    private static func rejectsAnswers(
        _ hook: ClaudeQuestionHook, _ answers: [AgentMessagingResponse]
    ) throws {
        do { _ = try hook.output(answers: answers) } catch ClaudeQuestionHook.Failure.invalidAnswer
        { return }
        throw ClaudeContractFailure()
    }
}

private struct ClaudeContractFailure: Error {}
