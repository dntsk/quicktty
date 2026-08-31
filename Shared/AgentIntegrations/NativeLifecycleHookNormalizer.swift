import Foundation

public enum NativeLifecycleHookNormalizer {
    public static let maximumInputBytes = AgentIPCProtocol.maximumPayloadSize

    public static func normalize(
        adapterID: String,
        event: String,
        input: Data,
        identity: AgentIPCIdentity
    ) -> AgentIPCMessage? {
        guard identity.adapterID == adapterID,
            input.count <= maximumInputBytes,
            let object = strictObject(input),
            validateOptionalMetadata(object["metadata"])
        else { return nil }

        switch action(adapterID: adapterID, event: event, object: object) {
        case .register:
            guard let sessionID = object["session_id"] as? String,
                !sessionID.hasPrefix("-"),
                let cwd = object["cwd"] as? String,
                let payload = try? AgentIPCRegisterPayload(
                    identity: identity,
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: [:]
                )
            else { return nil }
            return AgentIPCMessage(event: .register(payload))

        case .replace:
            guard let previousSessionID = object["previous_session_id"] as? String,
                !previousSessionID.hasPrefix("-"),
                let sessionID = object["session_id"] as? String,
                !sessionID.hasPrefix("-"),
                let cwd = object["cwd"] as? String,
                let payload = try? AgentIPCReplaceSessionPayload(
                    identity: identity,
                    previousSessionID: previousSessionID,
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: [:]
                )
            else { return nil }
            return AgentIPCMessage(event: .replaceSession(payload))

        case .unregister:
            guard let sessionID = object["session_id"] as? String,
                !sessionID.hasPrefix("-"),
                let payload = try? AgentIPCUnregisterPayload(
                    identity: identity,
                    sessionID: sessionID
                )
            else { return nil }
            return AgentIPCMessage(event: .unregister(payload))

        case nil:
            return nil
        }
    }

    private enum Action {
        case register
        case replace
        case unregister
    }

    private static func action(
        adapterID: String,
        event: String,
        object: [String: Any]
    ) -> Action? {
        switch (adapterID, event) {
        case ("claude", "SessionStart"), ("codex", "SessionStart"),
            ("gemini", "SessionStart"), ("kimi", "SessionStart"),
            ("cursor", "session_start"), ("copilot", "session_start"),
            ("droid", "session_start"), ("qoder", "session_start"),
            ("hermes", "start"), ("hermes", "pre_llm"),
            ("pi", "session_start"), ("omp", "session_start"):
            return .register

        case ("pi", "session_switch"), ("omp", "session_switch"):
            return .replace

        case ("claude", "SessionEnd"), ("codex", "SessionEnd"),
            ("gemini", "SessionEnd"), ("kimi", "SessionEnd"),
            ("cursor", "session_end"), ("copilot", "session_end"),
            ("droid", "session_end"), ("qoder", "session_end"),
            ("hermes", "finalize"):
            return .unregister

        case ("pi", "session_shutdown"), ("omp", "session_shutdown"):
            return object["reason"] as? String == "quit" ? .unregister : nil

        default:
            return nil
        }
    }

    private static func strictObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, (try? StrictJSON.validate(data)) != nil,
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else { return nil }
        return object
    }

    private static func validateOptionalMetadata(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let metadata = value as? [String: String] else { return false }
        return
            (try? AgentIPCRegisterPayload(
                identity: AgentIPCIdentity.fixtureForValidation,
                sessionID: "validation",
                cwd: "/",
                metadata: metadata
            )) != nil
    }
}

extension AgentIPCIdentity {
    fileprivate static var fixtureForValidation: AgentIPCIdentity {
        try! AgentIPCIdentity(
            instanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            paneToken: String(repeating: "0", count: 64),
            adapterID: "validation"
        )
    }
}
