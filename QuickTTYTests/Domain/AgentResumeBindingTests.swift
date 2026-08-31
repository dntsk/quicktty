import Foundation
import Testing

@testable import QuickTTY

struct AgentResumeBindingTests {
    @Test
    func validBindingRoundTripsWithStableJSONShape() throws {
        let registeredAt = Date(timeIntervalSinceReferenceDate: 123_456)
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude-code"),
            sessionID: "session-猫-123",
            workingDirectory: "/Users/example/猫",
            registeredAt: registeredAt,
            launchMetadata: ["model.name": "opus", "resume-mode": "automatic"],
            restoreState: .active
        )

        let data = try JSONEncoder().encode(binding)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(
            Set(object.keys)
                == [
                    "adapterID", "sessionID", "workingDirectory", "registeredAt",
                    "launchMetadata", "restoreState",
                ]
        )
        #expect(object["adapterID"] as? String == "claude-code")
        #expect(object["sessionID"] as? String == "session-猫-123")
        #expect(object["workingDirectory"] as? String == "/Users/example/猫")
        #expect(object["launchMetadata"] as? [String: String] == binding.launchMetadata)
        #expect(object["restoreState"] as? [String: String] == ["kind": "active"])
        #expect(try JSONDecoder().decode(AgentResumeBinding.self, from: data) == binding)
    }

    @Test(arguments: ["a", "agent-1", String(repeating: "a", count: 64)])
    func adapterIDAcceptsStableBoundaries(rawValue: String) throws {
        let adapterID = try AgentAdapterID(rawValue: rawValue)
        let data = try JSONEncoder().encode(adapterID)

        #expect(String(data: data, encoding: .utf8) == "\"\(rawValue)\"")
        #expect(try JSONDecoder().decode(AgentAdapterID.self, from: data) == adapterID)
    }

    @Test(arguments: [
        "",
        String(repeating: "a", count: 65),
        "Agent",
        "-agent",
        "agent-",
        "agent_name",
        "agént",
    ])
    func adapterIDRejectsInvalidPersistedValues(rawValue: String) throws {
        let data = try JSONEncoder().encode(rawValue)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentAdapterID.self, from: data)
        }
    }

    @Test(arguments: ["active", "restoring", "unverified"])
    func nonfailedResumeStatesUseStableTaggedShape(kind: String) throws {
        let state: AgentResumeState =
            switch kind {
            case "active": .active
            case "restoring": .restoring
            default: .unverified
            }

        let data = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.count == 1)
        #expect(object["kind"] as? String == kind)
        #expect(try JSONDecoder().decode(AgentResumeState.self, from: data) == state)
    }

    @Test(arguments: AgentResumeDiagnosticCode.allCases)
    func failedResumeStateUsesStableTaggedShape(
        diagnosticCode: AgentResumeDiagnosticCode
    ) throws {
        let failedAt = Date(timeIntervalSinceReferenceDate: 654_321)
        let state = AgentResumeState.failed(
            diagnosticCode: diagnosticCode,
            failedAt: failedAt
        )

        let data = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(
            Set(object.keys) == ["kind", "diagnosticCode", "failedAt"]
        )
        #expect(object["kind"] as? String == "failed")
        #expect(object["diagnosticCode"] as? String == diagnosticCode.rawValue)
        #expect(object["diagnosticText"] == nil)
        #expect(try JSONDecoder().decode(AgentResumeState.self, from: data) == state)
    }

    @Test(arguments: [
        "{\"kind\":\"future\"}",
        "{\"kind\":\"failed\"}",
        "{\"kind\":\"failed\",\"diagnosticCode\":\"future\",\"failedAt\":0}",
        "{\"kind\":\"failed\",\"diagnosticCode\":\"missingAdapter\"}",
        "{\"kind\":\"failed\",\"failedAt\":0}",
        "{\"kind\":\"active\",\"diagnosticCode\":\"missingAdapter\"}",
        "{\"kind\":\"active\",\"failedAt\":0}",
        "{\"kind\":\"active\",\"future\":true}",
        "{\"kind\":\"failed\",\"diagnosticCode\":\"missingAdapter\",\"failedAt\":0,\"future\":true}",
    ])
    func malformedOrExtendedResumeStateIsRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResumeState.self, from: Data(json.utf8))
        }
    }

    @Test
    func sessionIDAcceptsUTF8ByteBoundaries() throws {
        let oneByte = try binding(sessionID: "s")
        let maximum = try binding(sessionID: String(repeating: "é", count: 256))

        #expect(oneByte.sessionID.utf8.count == 1)
        #expect(maximum.sessionID.utf8.count == 512)
    }

    @Test(arguments: [
        "",
        String(repeating: "s", count: 513),
        "session\0id",
        "session\nid",
        "session\u{0085}id",
    ])
    func sessionIDRejectsInvalidPersistedValues(sessionID: String) throws {
        try expectBindingDecodingError(replacing: "sessionID", with: sessionID)
    }

    @Test
    func workingDirectoryAcceptsCanonicalAbsoluteUTF8ByteBoundaries() throws {
        let root = try binding(workingDirectory: "/")
        let unicode = try binding(workingDirectory: "/Volumes/External/猫-é")
        let maximum = try binding(
            workingDirectory: "/" + String(repeating: "é", count: 2_047) + "a"
        )

        #expect(root.workingDirectory == "/")
        #expect(unicode.workingDirectory == "/Volumes/External/猫-é")
        #expect(maximum.workingDirectory.utf8.count == 4_096)
    }

    @Test(arguments: [
        "",
        "relative/path",
        "~",
        "~/tmp",
        "~user/tmp",
        "//",
        "//tmp",
        "/tmp//project",
        "/./tmp",
        "/tmp/./project",
        "/../tmp",
        "/tmp/../project",
        "/tmp/",
        "/tmp/e\u{301}",
        "/" + String(repeating: "a", count: 4_096),
        "/tmp/with\0nul",
        "/tmp/with\tcontrol",
        "/tmp/with\u{0085}control",
    ])
    func workingDirectoryRejectsNoncanonicalValues(workingDirectory: String) throws {
        #expect(throws: (any Error).self) {
            try binding(workingDirectory: workingDirectory)
        }
        try expectBindingDecodingError(replacing: "workingDirectory", with: workingDirectory)
    }

    @Test
    func launchMetadataAcceptsCountKeyValueAndPayloadBoundaries() throws {
        let sixteenEntries = Dictionary(
            uniqueKeysWithValues: (0..<16).map { ("key\($0)", "value") }
        )
        let boundaryKeys = [
            "a": "",
            String(repeating: "k", count: 64): String(repeating: "v", count: 1_024),
            "AZaz09._-": "猫",
        ]
        let maximumPayload = metadata(payloadBytes: 8_192)

        #expect(try binding(launchMetadata: sixteenEntries).launchMetadata.count == 16)
        #expect(try binding(launchMetadata: boundaryKeys).launchMetadata == boundaryKeys)
        #expect(try binding(launchMetadata: maximumPayload).launchMetadata == maximumPayload)
    }

    @Test
    func launchMetadataRejectsEntryCountAboveBoundary() throws {
        let metadata = Dictionary(
            uniqueKeysWithValues: (0..<17).map { ("key\($0)", "value") }
        )

        try expectBindingDecodingError(replacing: "launchMetadata", with: metadata)
    }

    @Test(arguments: [
        "",
        String(repeating: "k", count: 65),
        "invalid key",
        "nonascii-猫",
        "control\nkey",
    ])
    func launchMetadataRejectsInvalidKeys(key: String) throws {
        try expectBindingDecodingError(replacing: "launchMetadata", with: [key: "value"])
    }

    @Test(arguments: [
        String(repeating: "v", count: 1_025),
        "value\0nul",
        "value\rcontrol",
        "value\u{0085}control",
    ])
    func launchMetadataRejectsInvalidValues(value: String) throws {
        try expectBindingDecodingError(replacing: "launchMetadata", with: ["key": value])
    }

    @Test
    func launchMetadataRejectsPayloadAboveBoundary() throws {
        try expectBindingDecodingError(
            replacing: "launchMetadata",
            with: metadata(payloadBytes: 8_193)
        )
    }

    @Test(arguments: [
        "token",
        "refresh-token-value",
        "client.secret.name",
        "PASSWORD_HINT",
        "credential-id",
        "preferred.api-key.provider",
        "secretary",
    ])
    func launchMetadataRejectsSecretLikeKeysAfterSeparatorRemoval(key: String) throws {
        try expectBindingDecodingError(replacing: "launchMetadata", with: [key: "value"])
    }

    @Test(arguments: [
        "resume.socket.path",
        "AGENT_INSTANCE_ID",
        "process-argv-value",
        "launch.environment",
    ])
    func launchMetadataInitializerRejectsTransientKeysAfterNormalization(key: String) {
        #expect(throws: (any Error).self) {
            try binding(launchMetadata: [key: "value"])
        }
    }

    @Test(arguments: [
        "resume.socket.path",
        "AGENT_INSTANCE_ID",
        "process-argv-value",
        "launch.environment",
    ])
    func launchMetadataDecoderRejectsTransientKeysAfterNormalization(key: String) throws {
        try expectBindingDecodingError(replacing: "launchMetadata", with: [key: "value"])
    }

    @Test
    func encodedBindingContainsNoTransientCredentialOrLaunchProcessKeys() throws {
        let binding = try binding(
            launchMetadata: ["model.name": "opus", "resume.mode": "automatic"]
        )
        let data = try JSONEncoder().encode(binding)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(object["launchMetadata"] as? [String: String])
        let normalizedKeys = metadata.keys.map {
            $0.lowercased().filter { character in
                character != "." && character != "_" && character != "-"
            }
        }

        for forbiddenFragment in [
            "socket", "token", "secret", "password", "credential", "apikey", "instance",
            "argv", "environment",
        ] {
            #expect(normalizedKeys.allSatisfy { !$0.contains(forbiddenFragment) })
        }
        #expect(metadata == binding.launchMetadata)
        #expect(object.keys.count == 6)
    }

    @Test
    func descriptorDecodeFallsBackPaneLocallyForOlderOrInvalidBindingJSON() throws {
        let descriptor = TerminalPaneDescriptor(
            id: PaneID(),
            cwd: "/shell",
            agentResumeBinding: try binding()
        )
        let data = try JSONEncoder().encode(descriptor)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["agentResumeBinding"] != nil)
        #expect(try JSONDecoder().decode(TerminalPaneDescriptor.self, from: data) == descriptor)

        var invalidObject = object
        var invalidBinding = try #require(invalidObject["agentResumeBinding"] as? [String: Any])
        invalidBinding["workingDirectory"] = "/tmp/../project"
        invalidObject["agentResumeBinding"] = invalidBinding
        let invalidDescriptor = try JSONDecoder().decode(
            TerminalPaneDescriptor.self,
            from: JSONSerialization.data(withJSONObject: invalidObject)
        )
        #expect(invalidDescriptor.id == descriptor.id)
        #expect(invalidDescriptor.cwd == "/shell")
        #expect(invalidDescriptor.agentResumeBinding == nil)

        object.removeValue(forKey: "agentResumeBinding")
        let olderDescriptor = try JSONDecoder().decode(
            TerminalPaneDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(olderDescriptor.agentResumeBinding == nil)
    }

    private func binding(
        sessionID: String = "session-1",
        workingDirectory: String = "/tmp",
        launchMetadata: [String: String] = [:]
    ) throws -> AgentResumeBinding {
        try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude-code"),
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            registeredAt: Date(timeIntervalSinceReferenceDate: 123_456),
            launchMetadata: launchMetadata,
            restoreState: .active
        )
    }

    private func expectBindingDecodingError(
        replacing key: String,
        with value: Any
    ) throws {
        var object = validBindingObject()
        object[key] = value
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResumeBinding.self, from: data)
        }
    }

    private func validBindingObject() -> [String: Any] {
        [
            "adapterID": "claude-code",
            "sessionID": "session-1",
            "workingDirectory": "/tmp",
            "registeredAt": 0,
            "launchMetadata": [:],
            "restoreState": ["kind": "active"],
        ]
    }

    private func metadata(payloadBytes: Int) -> [String: String] {
        let keys = (0..<16).map { "k\($0)" }
        var remainingValueBytes = payloadBytes - keys.reduce(0) { $0 + $1.utf8.count }
        return Dictionary(
            uniqueKeysWithValues: keys.map { key in
                let valueByteCount = min(max(remainingValueBytes, 0), 1_024)
                remainingValueBytes -= valueByteCount
                return (key, String(repeating: "v", count: valueByteCount))
            }
        )
    }
}
