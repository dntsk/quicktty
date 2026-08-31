import Foundation
import Testing

@testable import QuickTTY

struct AgentIPCProtocolTests {
    private let token = String(repeating: "a", count: 64)

    @Test
    func preflightAndDomainSeparatedProofAreCanonicalAndContextBound() throws {
        let preflight = try makePreflight()
        let encoded = try AgentIPCProtocol.encodePreflight(preflight)
        let proof = try AgentIPCProtocol.makeServerProof(for: preflight, paneToken: token)

        #expect(encoded.count == AgentIPCProtocol.preflightSize)
        #expect(try AgentIPCProtocol.decodePreflight(encoded) == preflight)
        #expect(proof.count == AgentIPCProtocol.proofSize)
        #expect(AgentIPCProtocol.verifyServerProof(proof, for: preflight, paneToken: token))
        #expect(
            !AgentIPCProtocol.verifyServerProof(
                proof,
                for: preflight,
                paneToken: String(repeating: "b", count: 64)
            ))
        #expect(throws: AgentIPCProtocolError.invalidPreflight) {
            try AgentIPCProtocol.decodePreflight(encoded.dropLast())
        }
    }

    @Test
    func roundTripsTokenlessCanonicalEnvelopeForEveryEvent() throws {
        let identity = try makeIdentity()
        let messages = [
            AgentIPCMessage(
                event: .register(
                    try AgentIPCRegisterPayload(
                        identity: identity,
                        sessionID: "session-1",
                        cwd: "/tmp/project",
                        metadata: ["model": "opus"]
                    ))),
            AgentIPCMessage(
                event: .replaceSession(
                    try AgentIPCReplaceSessionPayload(
                        identity: identity,
                        previousSessionID: "session-1",
                        sessionID: "session-2",
                        cwd: "/tmp/project",
                        metadata: ["model": "opus"]
                    ))),
            AgentIPCMessage(
                event: .unregister(
                    try AgentIPCUnregisterPayload(identity: identity, sessionID: "session-2")
                )),
        ]
        let expectedPayloadKeys: [Set<String>] = [
            [
                "version", "event", "instanceID", "paneID", "adapterID", "sessionID", "cwd",
                "metadata",
            ],
            [
                "version", "event", "instanceID", "paneID", "adapterID", "previousSessionID",
                "sessionID", "cwd", "metadata",
            ],
            ["version", "event", "instanceID", "paneID", "adapterID", "sessionID"],
        ]
        let preflight = try makePreflight()

        for (message, expectedKeys) in zip(messages, expectedPayloadKeys) {
            let frame = try AgentIPCProtocol.encodeFrame(message, for: preflight)
            #expect(
                try AgentIPCProtocol.decodeFrame(
                    frame,
                    for: preflight,
                    paneToken: token
                ) == message
            )
            let envelope = try wireObject(from: frame)
            #expect(Set(envelope.keys) == ["frameMAC", "payload"])
            let payload = try #require(envelope["payload"] as? [String: Any])
            #expect(Set(payload.keys) == expectedKeys)
            #expect(payload["paneToken"] == nil)
            #expect(frame.range(of: Data(token.utf8)) == nil)
            #expect(frame.range(of: Data("paneToken".utf8)) == nil)
        }
    }

    @Test
    func frameMACRejectsCredentialNonceAndPayloadSubstitution() throws {
        let message = try registerMessage()
        let preflight = try makePreflight()
        let frame = try AgentIPCProtocol.encodeFrame(message, for: preflight)

        #expect(
            try AgentIPCProtocol.decodeFrame(frame, for: preflight, paneToken: token) == message
        )
        #expect(throws: AgentIPCProtocolError.invalidPayload) {
            try AgentIPCProtocol.decodeFrame(
                frame,
                for: preflight,
                paneToken: String(repeating: "b", count: 64)
            )
        }
        let otherNonce = try makePreflight(nonceByte: 0x43)
        #expect(throws: AgentIPCProtocolError.invalidPayload) {
            try AgentIPCProtocol.decodeFrame(frame, for: otherNonce, paneToken: token)
        }

        let mutations: [(String, Any)] = [
            ("adapterID", "codex"),
            ("sessionID", "altered"),
            ("cwd", "/altered"),
            ("metadata", ["model": "altered"]),
            ("event", "unregister"),
            ("instanceID", UUID().uuidString),
            ("paneID", UUID().uuidString),
        ]
        for (key, value) in mutations {
            let altered = try mutatePayload(in: frame, key: key, value: value)
            #expect(throws: AgentIPCProtocolError.invalidPayload) {
                try AgentIPCProtocol.decodeFrame(altered, for: preflight, paneToken: token)
            }
        }
    }

    @Test
    func rejectsDuplicateNoncanonicalAndOldTokenBearingFrames() throws {
        let message = try registerMessage()
        let preflight = try makePreflight()
        let frame = try AgentIPCProtocol.encodeFrame(message, for: preflight)
        let canonical = try #require(String(data: frame.dropFirst(4), encoding: .utf8))
        let duplicateEnvelope = canonical.replacingOccurrences(
            of: #"{"frameMAC":"#,
            with: #"{"frameMAC":"ignored","frameMAC":"#,
            options: .anchored
        )
        let duplicatePayload = canonical.replacingOccurrences(
            of: #""adapterID":"claude-code""#,
            with: #""adapterID":"claude-code","adapterID":"codex""#
        )
        let noncanonical = " " + canonical

        for payload in [duplicateEnvelope, duplicatePayload, noncanonical] {
            #expect(throws: AgentIPCProtocolError.invalidPayload) {
                try AgentIPCProtocol.decodeFrame(
                    lengthPrefixed(Data(payload.utf8)),
                    for: preflight,
                    paneToken: token
                )
            }
        }

        let oldTokenBearingPayload = try canonicalDomainMessage(message)
        #expect(oldTokenBearingPayload.range(of: Data("paneToken".utf8)) != nil)
        #expect(throws: AgentIPCProtocolError.invalidPayload) {
            try AgentIPCProtocol.decodeFrame(
                lengthPrefixed(oldTokenBearingPayload),
                for: preflight,
                paneToken: token
            )
        }
    }

    @Test
    func rejectsMalformedFrameLengthsAndPayloads() throws {
        let preflight = try makePreflight()
        let malformed: [(Data, AgentIPCProtocolError)] = [
            (Data([0, 0, 0]), .truncatedHeader),
            (Data([0, 0, 0, 0]), .emptyPayload),
            (lengthPrefixed(Data(), declaredLength: 65_537), .payloadTooLarge),
            (lengthPrefixed(Data([1]), declaredLength: 2), .truncatedPayload),
            (lengthPrefixed(Data("{}".utf8)), .invalidPayload),
        ]
        for (frame, expectedError) in malformed {
            #expect(throws: expectedError) {
                try AgentIPCProtocol.decodeFrame(frame, for: preflight, paneToken: token)
            }
        }

        var trailing = try AgentIPCProtocol.encodeFrame(registerMessage(), for: preflight)
        trailing.append(0)
        #expect(throws: AgentIPCProtocolError.trailingBytes) {
            try AgentIPCProtocol.decodeFrame(trailing, for: preflight, paneToken: token)
        }
    }

    @Test
    func validatesIdentitySessionWorkingDirectoryAndMetadataBoundaries() throws {
        #expect(throws: AgentIPCValidationError.invalidPaneToken) {
            try AgentIPCIdentity(
                instanceID: UUID(),
                paneID: UUID(),
                paneToken: String(repeating: "a", count: 63),
                adapterID: "codex"
            )
        }
        let identity = try makeIdentity()
        for sessionID in ["", String(repeating: "x", count: 513), "session\u{7f}"] {
            #expect(throws: AgentIPCValidationError.invalidSessionID) {
                try AgentIPCRegisterPayload(
                    identity: identity,
                    sessionID: sessionID,
                    cwd: "/tmp",
                    metadata: [:]
                )
            }
        }
        for cwd in ["", "tmp", "//tmp", "/tmp/../project", "/tmp/"] {
            #expect(throws: AgentIPCValidationError.invalidWorkingDirectory) {
                try AgentIPCRegisterPayload(
                    identity: identity,
                    sessionID: "session",
                    cwd: cwd,
                    metadata: [:]
                )
            }
        }
        #expect(throws: AgentIPCValidationError.invalidMetadata) {
            try AgentIPCRegisterPayload(
                identity: identity,
                sessionID: "session",
                cwd: "/tmp",
                metadata: ["auth_token": "secret"]
            )
        }
    }

    private func makeIdentity() throws -> AgentIPCIdentity {
        try AgentIPCIdentity(
            instanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            paneID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            paneToken: token,
            adapterID: "claude-code"
        )
    }

    private func registerMessage() throws -> AgentIPCMessage {
        AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: makeIdentity(),
                    sessionID: "session",
                    cwd: "/tmp",
                    metadata: [:]
                )))
    }

    private func makePreflight(nonceByte: UInt8 = 0x42) throws -> AgentIPCPreflight {
        let identity = try makeIdentity()
        return try AgentIPCPreflight(
            instanceID: identity.instanceID,
            paneID: identity.paneID,
            nonce: Data(repeating: nonceByte, count: AgentIPCProtocol.nonceSize)
        )
    }

    private func mutatePayload(in frame: Data, key: String, value: Any) throws -> Data {
        var envelope = try wireObject(from: frame)
        var payload = try #require(envelope["payload"] as? [String: Any])
        payload[key] = value
        envelope["payload"] = payload
        return lengthPrefixed(
            try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    private func canonicalDomainMessage(_ message: AgentIPCMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    private func wireObject(from frame: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: frame.dropFirst(4))
        return try #require(object as? [String: Any])
    }

    private func lengthPrefixed(_ payload: Data, declaredLength: Int? = nil) -> Data {
        var length = UInt32(declaredLength ?? payload.count).bigEndian
        var frame = Data()
        Swift.withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

struct AgentInvocationPayloadTests {
    @Test
    func roundTripsAdversarialArgumentsThroughCanonicalCodec() throws {
        let arguments = ["$(rm -rf /)", "; echo injected", "line\nbreak", "", "--flag=value"]
        let payload = try AgentInvocationPayload(
            executable: "/usr/bin/example",
            arguments: arguments,
            workingDirectory: "/tmp/project"
        )
        let data = try AgentInvocationPayloadCodec.encode(payload)
        let expected =
            "{\"arguments\":[\"$(rm -rf /)\",\"; echo injected\",\"line\\nbreak\",\"\",\"--flag=value\"],\"executable\":\"/usr/bin/example\",\"workingDirectory\":\"/tmp/project\"}"

        #expect(data == Data(expected.utf8))
        #expect(try AgentInvocationPayloadCodec.decode(data) == payload)
        #expect(payload.arguments == arguments)
    }

    @Test
    func base64TransportRequiresCanonicalBoundedEncoding() throws {
        let payload = try AgentInvocationPayload(
            executable: "/bin/agent",
            arguments: ["space value", "quote'\"", "$(command)", ";", "line\nbreak", "", "猫"],
            workingDirectory: "/tmp/project"
        )

        let encoded = try AgentInvocationPayloadCodec.encodeBase64(payload)
        let canonicalBase64 = try AgentInvocationPayloadCodec.encode(payload).base64EncodedString()

        #expect(encoded == canonicalBase64)
        #expect(try AgentInvocationPayloadCodec.decodeBase64(encoded) == payload)
        #expect(throws: AgentInvocationPayloadCodecError.invalidPayload) {
            try AgentInvocationPayloadCodec.decodeBase64(encoded + "\n")
        }
        #expect(throws: AgentInvocationPayloadCodecError.invalidPayload) {
            try AgentInvocationPayloadCodec.decodeBase64("!!!!")
        }
        #expect(throws: AgentInvocationPayloadCodecError.payloadTooLarge) {
            try AgentInvocationPayloadCodec.decodeBase64(
                String(repeating: "A", count: AgentInvocationPayloadCodec.maximumBase64Size + 1)
            )
        }
    }

    @Test
    func acceptsExactCodecSizeBoundaryAndRejectsOversizedEncoding() throws {
        let emptyArguments = Array(repeating: "", count: 8)
        let emptyPayload = try AgentInvocationPayload(
            executable: "/bin/tool",
            arguments: emptyArguments
        )
        let overhead = try AgentInvocationPayloadCodec.encode(emptyPayload).count
        let encodedArgumentBytes = AgentInvocationPayloadCodec.maximumPayloadSize - overhead
        var remainingNewlines = encodedArgumentBytes / 2
        var arguments: [String] = []

        for _ in 0..<emptyArguments.count {
            let count = min(4_096, remainingNewlines)
            arguments.append(String(repeating: "\n", count: count))
            remainingNewlines -= count
        }
        if encodedArgumentBytes.isMultiple(of: 2) == false {
            arguments[arguments.count - 1].append("x")
        }

        let boundaryPayload = try AgentInvocationPayload(
            executable: "/bin/tool",
            arguments: arguments
        )
        let boundaryData = try AgentInvocationPayloadCodec.encode(boundaryPayload)
        #expect(boundaryData.count == AgentInvocationPayloadCodec.maximumPayloadSize)
        #expect(try AgentInvocationPayloadCodec.decode(boundaryData) == boundaryPayload)

        arguments[arguments.count - 1].append("\n")
        let oversizedPayload = try AgentInvocationPayload(
            executable: "/bin/tool",
            arguments: arguments
        )
        #expect(throws: AgentInvocationPayloadCodecError.payloadTooLarge) {
            try AgentInvocationPayloadCodec.encode(oversizedPayload)
        }
    }

    @Test
    func validatesInvocationBoundaries() throws {
        _ = try AgentInvocationPayload(
            executable: "/" + String(repeating: "x", count: 4_095),
            arguments: Array(repeating: String(repeating: "a", count: 512), count: 64),
            workingDirectory: "/" + String(repeating: "w", count: 4_095)
        )
        #expect(throws: AgentInvocationPayloadError.invalidExecutable) {
            try AgentInvocationPayload(executable: "relative", arguments: [])
        }
        #expect(throws: AgentInvocationPayloadError.invalidExecutable) {
            try AgentInvocationPayload(executable: "/bad\npath", arguments: [])
        }
        #expect(throws: AgentInvocationPayloadError.invalidExecutable) {
            try AgentInvocationPayload(executable: "/bad\0path", arguments: [])
        }
        #expect(throws: AgentInvocationPayloadError.invalidExecutable) {
            try AgentInvocationPayload(
                executable: "/" + String(repeating: "x", count: 4_096),
                arguments: []
            )
        }
        #expect(throws: AgentInvocationPayloadError.invalidArguments) {
            try AgentInvocationPayload(
                executable: "/bin/tool", arguments: Array(repeating: "", count: 65))
        }
        #expect(throws: AgentInvocationPayloadError.invalidArguments) {
            try AgentInvocationPayload(
                executable: "/bin/tool",
                arguments: [String(repeating: "x", count: 4_097)]
            )
        }
        #expect(throws: AgentInvocationPayloadError.invalidArguments) {
            try AgentInvocationPayload(executable: "/bin/tool", arguments: ["nul\0byte"])
        }
        #expect(throws: AgentInvocationPayloadError.invalidArguments) {
            try AgentInvocationPayload(
                executable: "/bin/tool",
                arguments: Array(repeating: String(repeating: "x", count: 513), count: 64)
            )
        }
        #expect(throws: AgentInvocationPayloadError.invalidWorkingDirectory) {
            try AgentInvocationPayload(
                executable: "/bin/tool",
                arguments: [],
                workingDirectory: "relative"
            )
        }
        #expect(throws: AgentInvocationPayloadError.invalidWorkingDirectory) {
            try AgentInvocationPayload(
                executable: "/bin/tool",
                arguments: [],
                workingDirectory: "/bad\0path"
            )
        }
        #expect(throws: AgentInvocationPayloadError.invalidWorkingDirectory) {
            try AgentInvocationPayload(
                executable: "/bin/tool",
                arguments: [],
                workingDirectory: "/" + String(repeating: "w", count: 4_096)
            )
        }
    }

    @Test
    func canonicalCodecRejectsUnknownMissingInvalidDuplicateAndNoncanonicalFields() throws {
        let invalidPayloads = [
            "{\"arguments\":[\"arg\"],\"command\":\"forbidden\",\"executable\":\"/bin/tool\",\"workingDirectory\":null}",
            "{\"arguments\":[\"arg\"],\"executable\":\"/bin/tool\"}",
            "{\"arguments\":[\"arg\"],\"executable\":\"relative\",\"workingDirectory\":null}",
            "{\"arguments\":[\"nul\\u0000byte\"],\"executable\":\"/bin/tool\",\"workingDirectory\":null}",
            "{\"arguments\":[\"arg\"],\"executable\":\"/bin/tool\",\"executable\":\"/bin/other\",\"workingDirectory\":null}",
            "{\"arguments\":[\"arg\"],\"arguments\":[\"other\"],\"executable\":\"/bin/tool\",\"workingDirectory\":null}",
            " {\"arguments\":[\"arg\"],\"executable\":\"/bin/tool\",\"workingDirectory\":null}",
            "{\"executable\":\"/bin/tool\",\"arguments\":[\"arg\"],\"workingDirectory\":null}",
            "{\"arguments\":[\"arg\"],\"executable\":\"\\/bin\\/tool\",\"workingDirectory\":null}",
        ]

        for payload in invalidPayloads {
            #expect(throws: AgentInvocationPayloadCodecError.invalidPayload) {
                try AgentInvocationPayloadCodec.decode(Data(payload.utf8))
            }
        }
        #expect(throws: AgentInvocationPayloadCodecError.payloadTooLarge) {
            try AgentInvocationPayloadCodec.decode(
                Data(repeating: UInt8(ascii: " "), count: 65_537)
            )
        }
    }
}
