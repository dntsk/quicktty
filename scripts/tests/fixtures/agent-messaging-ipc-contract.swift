import Foundation
import Synchronization

struct AgentMessagingIPCContract {
    static func run() async throws {
        let token = String(repeating: "ab", count: 32)
        let preflight = try TerminalControlPreflight(
            instanceID: UUID(), paneID: UUID(), nonce: AgentMessagingProtocol.randomBytes())
        let challenge = AgentMessagingProtocol.randomBytes()
        let request = AgentMessagingRequest(
            version: 1, operation: .question,
            requestID: UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!, text: "Choose?",
            choices: ["A", "B"])
        let proof = try AgentMessagingProtocol.serverProof(
            preflight, challenge: challenge, token: token)
        try AgentMessagingContract.require(
            AgentMessagingProtocol.verifyServerProof(
                proof, preflight: preflight, challenge: challenge, token: token),
            "Messaging proof failed")
        let terminalProof = try TerminalControlProtocol.makeServerProof(
            for: preflight, challenge: challenge, paneToken: token)
        try AgentMessagingContract.require(
            !AgentMessagingProtocol.verifyServerProof(
                terminalProof, preflight: preflight, challenge: challenge, token: token),
            "Terminal proof crossed messaging domain")
        let frame = try AgentMessagingProtocol.requestFrame(
            request, preflight: preflight, challenge: challenge, token: token)
        try AgentMessagingContract.require(
            try AgentMessagingProtocol.decodeRequestFrame(
                frame, preflight: preflight, challenge: challenge, token: token) == request,
            "Signed request roundtrip failed")
        var altered = frame
        altered[altered.count - 1] ^= 1
        try mustReject {
            _ = try AgentMessagingProtocol.decodeRequestFrame(
                altered, preflight: preflight, challenge: challenge, token: token)
        }
        try mustReject {
            _ = try AgentMessagingProtocol.decodeRequestFrame(
                frame, preflight: preflight, challenge: AgentMessagingProtocol.randomBytes(),
                token: token)
        }
        let response = AgentMessagingResponse(
            version: 1, requestID: request.requestID, state: "pending")
        let responseFrame = try AgentMessagingProtocol.responseFrame(
            response, request: request, preflight: preflight, challenge: challenge, token: token)
        try AgentMessagingContract.require(
            try AgentMessagingProtocol.decodeResponseFrame(
                responseFrame, request: request, preflight: preflight, challenge: challenge,
                token: token) == response, "Response proof failed")
        var different = request
        different.text = "Changed operation"
        try mustReject {
            _ = try AgentMessagingProtocol.decodeResponseFrame(
                responseFrame, request: different, preflight: preflight, challenge: challenge,
                token: token)
        }
        try mustReject {
            let wrongID = AgentMessagingResponse(version: 1, requestID: UUID(), state: "approved")
            _ = try AgentMessagingProtocol.responseFrame(
                wrongID, request: request, preflight: preflight, challenge: challenge, token: token)
        }
        try mustReject {
            let malformed = AgentMessagingResponse(
                version: 1, requestID: request.requestID, state: "approved", text: "extra payload")
            _ = try AgentMessagingProtocol.responseFrame(
                malformed, request: request, preflight: preflight, challenge: challenge,
                token: token)
        }
        let canonical = try AgentMessagingProtocol.encode(request)
        let object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        let unknown = object.merging(["command": "not an executable API"]) { _, new in new }
        try mustReject {
            _ = try AgentMessagingProtocol.decodeRequest(
                JSONSerialization.data(withJSONObject: unknown), canonical: false)
        }
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try AgentMessagingContract.require(
            try AgentMessagingProtocol.decodeRequest(pretty, canonical: false) == request,
            "CLI whitespace was not accepted")
        try mustReject { _ = try AgentMessagingProtocol.decodeRequest(pretty) }
        var lowercase = object
        lowercase["requestID"] = request.requestID.uuidString.lowercased()
        let lowercaseJSON = try JSONSerialization.data(withJSONObject: lowercase)
        try AgentMessagingContract.require(
            try AgentMessagingProtocol.decodeRequest(lowercaseJSON, canonical: false) == request,
            "CLI rejected the lowercase UUID emitted by Node crypto.randomUUID")
        try mustReject { _ = try AgentMessagingProtocol.decodeRequest(lowercaseJSON) }
        let duplicate = String(decoding: canonical, as: UTF8.self).replacingOccurrences(
            of: "\"version\":1", with: "\"version\":1,\"version\":1")
        try mustReject {
            _ = try AgentMessagingProtocol.decodeRequest(Data(duplicate.utf8), canonical: false)
        }
        let invalidWait = AgentMessagingRequest(
            version: 1, operation: .wait, requestID: request.requestID, timeoutMilliseconds: 30_001)
        try mustReject { try invalidWait.validate() }
        try AgentMessagingContract.require(
            try QuickTTYCommand.parse(["agent", "request"]) == .agentRequest,
            "Messaging CLI grammar missing")
        try mustReject { _ = try QuickTTYCommand.parse(["agent", "request", "--yes"]) }

        for adapter in ["claude", "codex", "gemini"] {
            guard
                let context = AgentMessagingInstructions.sessionStartOutput(
                    adapterID: adapter, event: "SessionStart",
                    helperPath: "/test/Helper's Directory/quicktty")
            else { throw IPCFailure() }
            let root = try JSONSerialization.jsonObject(with: context) as! [String: Any]
            let output = root["hookSpecificOutput"] as! [String: Any]
            let text = output["additionalContext"] as! String
            try AgentMessagingContract.require(
                output["hookEventName"] as? String == "SessionStart"
                    && text.contains(AgentMessagingInstructions.text)
                    && text.contains("Host authentication still decides access")
                    && text.contains("This does not approve any action")
                    && !text.contains("explicitly granted this exact live session"),
                "SessionStart did not use the automatic, authentication-bounded instruction")
        }
        for (adapter, event, helper) in [
            ("pi", "session_start", "/test/quicktty"),
            ("cursor", "sessionStart", "/test/quicktty"),
            ("claude", "SessionEnd", "/test/quicktty"),
            ("claude", "PreToolUse", "/test/quicktty"),
            ("codex", "SessionStart", "relative/quicktty"),
        ] {
            try AgentMessagingContract.require(
                AgentMessagingInstructions.sessionStartOutput(
                    adapterID: adapter, event: event, helperPath: helper) == nil,
                "Unsupported hook/path received model context")
        }
        let received = Mutex([AgentMessagingRequest]())
        let server = AgentMessagingSocketServer(
            credentialProvider: { candidate in
                candidate.instanceID == preflight.instanceID && candidate.paneID == preflight.paneID
                    ? token : nil
            },
            handler: { request, context in
                guard context.isActive else {
                    return .failure("cancelled", requestID: request.requestID)
                }
                received.withLock { $0.append(request) }
                return AgentMessagingResponse(
                    version: 1, requestID: request.requestID, state: "pending")
            }
        )
        let socket = try server.start()
        let environment = [
            "QUICKTTY_INSTANCE_ID": preflight.instanceID.uuidString,
            "QUICKTTY_PANE_ID": preflight.paneID.uuidString,
            "QUICKTTY_PANE_TOKEN": token,
            "QUICKTTY_MESSAGE_SOCKET": socket,
        ]
        guard
            let identity = TerminalControlEnvironment.read(
                socketKey: "QUICKTTY_MESSAGE_SOCKET",
                value: { key, _ in environment[key].map { Data($0.utf8) } })
        else { throw IPCFailure() }
        let result = try await Task.detached {
            try AgentMessagingSocketClient(identity: identity).send(request)
        }.value
        try AgentMessagingContract.require(result == response, "Actual socket handshake failed")
        let count = received.withLock { $0.count }
        try AgentMessagingContract.require(
            count == 1, "Actual socket delivered wrong number of requests")
        var wrongEnvironment = environment
        wrongEnvironment["QUICKTTY_PANE_TOKEN"] = String(repeating: "cd", count: 32)
        guard
            let wrong = TerminalControlEnvironment.read(
                socketKey: "QUICKTTY_MESSAGE_SOCKET",
                value: { key, _ in wrongEnvironment[key].map { Data($0.utf8) } })
        else { throw IPCFailure() }
        do {
            _ = try await Task.detached {
                try AgentMessagingSocketClient(identity: wrong).send(request)
            }.value
            throw IPCFailure()
        } catch let error as AgentMessagingProtocolError {
            try AgentMessagingContract.require(
                error == .authenticationFailed, "Wrong peer was not rejected at proof")
        }
        try AgentMessagingContract.require(
            received.withLock { $0.count } == 1, "Unauthenticated request reached handler")
        await server.stop()
        print("PASS: agent messaging IPC contracts (real local socket, no GUI)")
    }

    private static func mustReject(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw IPCFailure()
    }
}

private struct IPCFailure: Error {}
