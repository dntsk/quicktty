import Foundation

@MainActor
struct AgentMessagingClaudeCLIContract {
    static func run(
        sessions: AgentSessionController, service: AgentMessagingService, pane: PaneID
    ) async throws {
        let environment = sessions.environment(for: pane)!
        let rejectedInput = try JSONSerialization.data(withJSONObject: [
            "session_id": "rejected", "cwd": "/tmp",
        ])
        let rejected = try start(rejectedInput, environment: [:], event: "SessionStart")
        defer { if rejected.process.isRunning { rejected.process.terminate() } }
        try await waitUntil { !rejected.process.isRunning }
        try AgentMessagingContract.require(
            rejected.process.terminationStatus != 0
                && rejected.output.fileHandleForReading.readDataToEndOfFile().isEmpty,
            "Rejected lifecycle registration emitted model instructions")
        let sessionID = "claude-cli-fixture-session"
        let identity = try AgentIPCIdentity(
            instanceID: sessions.instanceID, paneID: pane.rawValue,
            paneToken: environment["QUICKTTY_PANE_TOKEN"]!, adapterID: "claude")
        let registered = await sessions.handle(
            AgentIPCMessage(
                event: .register(
                    try AgentIPCRegisterPayload(
                        identity: identity, sessionID: sessionID, cwd: "/tmp", metadata: [:]))))
        try AgentMessagingContract.require(registered, "Claude CLI fixture registration failed")
        let origin = service.origins().first!.origin
        try service.setAuthorized(origin, allowed: false)
        let input = try AgentMessagingClaudeQuestionContract.input(sessionID: sessionID)
        let hook = try ClaudeQuestionHook(input: input)
        let fallback = try start(input, environment: environment)
        defer { if fallback.process.isRunning { fallback.process.terminate() } }
        try await waitUntil { !fallback.process.isRunning }
        let fallbackObject =
            try JSONSerialization.jsonObject(
                with: fallback.output.fileHandleForReading.readDataToEndOfFile())
            as? [String: String]
        try AgentMessagingContract.require(
            fallback.process.terminationStatus == 0 && fallbackObject?.isEmpty == true,
            "Missing grant did not preserve the native question flow")
        try service.setAuthorized(origin, allowed: true)
        let unverified = try start(
            input, environment: environment, event: ClaudeQuestionRuntime.installedHookEvent,
            parent: URL(fileURLWithPath: CommandLine.arguments[2] + "/unverified/claude"))
        defer { if unverified.process.isRunning { unverified.process.terminate() } }
        try await waitUntil { !unverified.process.isRunning }
        let unverifiedOutput =
            try JSONSerialization.jsonObject(
                with: unverified.output.fileHandleForReading.readDataToEndOfFile())
            as? [String: String]
        try AgentMessagingContract.require(
            unverified.process.terminationStatus == 0 && unverifiedOutput?.isEmpty == true,
            "An unverified executable named claude bypassed the installed hook gate")
        let question = try start(input, environment: environment)
        defer { if question.process.isRunning { question.process.terminate() } }
        let requests = try hook.requests()
        try await waitUntil {
            service.connection.snapshot(requests[0].requestID)?.state == .pending
        }
        _ = try service.connection.answerLocally(requests[0].requestID, answer: .choice(1))
        try await waitUntil {
            service.connection.snapshot(requests[1].requestID)?.state == .pending
        }
        _ = try service.connection.answerLocally(requests[1].requestID, answer: .text("One"))
        try await waitUntil { !question.process.isRunning }
        let output =
            try JSONSerialization.jsonObject(
                with: question.output.fileHandleForReading.readDataToEndOfFile()) as? NSDictionary
        let expected = try hook.output(answers: [
            AgentMessagingResponse(
                version: 1, requestID: requests[0].requestID, state: "choice", text: "Two",
                choiceIndex: 1),
            AgentMessagingResponse(
                version: 1, requestID: requests[1].requestID, state: "text", text: "One"),
        ])
        let expectedObject = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
        try AgentMessagingContract.require(
            question.process.terminationStatus == 0 && output == expectedObject,
            "Real CLI did not return exact vendor answers")
        let interruptedInput = try AgentMessagingClaudeQuestionContract.input(
            sessionID: sessionID, toolID: "toolu_interrupted")
        let interruptedHook = try ClaudeQuestionHook(input: interruptedInput)
        let interruptedID = try interruptedHook.requests()[0].requestID
        let interrupted = try start(interruptedInput, environment: environment)
        defer { if interrupted.process.isRunning { interrupted.process.terminate() } }
        try await waitUntil { service.connection.snapshot(interruptedID)?.state == .pending }
        interrupted.process.terminate()
        try await waitUntil { !interrupted.process.isRunning }
        try AgentMessagingContract.require(
            service.connection.snapshot(interruptedID)?.state == .resolved(.cancelled),
            "SIGTERM left a Claude question pending in the host")
        let stopped =
            try JSONSerialization.jsonObject(
                with: interrupted.output.fileHandleForReading.readDataToEndOfFile())
            as! [String: Any]
        let specific = stopped["hookSpecificOutput"] as? [String: Any]
        try AgentMessagingContract.require(
            specific?["permissionDecision"] as? String == "deny"
                && specific?["updatedInput"] == nil,
            "Interrupted CLI fabricated a native answer")
        print(
            "PASS: Claude CLI → authenticated host → local answers; native fallback and SIGTERM cancellation"
        )
    }

    private static func start(
        _ input: Data, environment: [String: String], event: String = "PreToolUse",
        parent: URL? = nil
    ) throws
        -> (process: Process, output: Pipe)
    {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let helper = URL(fileURLWithPath: CommandLine.arguments[2] + "/quicktty")
        process.executableURL = parent ?? helper
        process.arguments =
            (parent == nil ? [] : [helper.path]) + ["internal", "hook", "claude", event]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        return (process, stdout)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ClaudeCLIFailure() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ClaudeCLIFailure: Error {}
