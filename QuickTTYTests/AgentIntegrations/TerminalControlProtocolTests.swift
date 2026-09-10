import CryptoKit
import Foundation
import Testing

@testable import QuickTTY

struct TerminalControlProtocolTests {
    private let taskID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let paneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let tabID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    private let workspaceID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
    private let requestID = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!

    @Test
    func everyRequestOperationRoundTripsWithExactFields() throws {
        let launch = try makeLaunch()
        let operations: [(TerminalControlRequest.Operation, UUID?, String, Set<String>)] = [
            (.list, nil, "list", ["operation", "version"]),
            (
                .createTab(launch: launch, policy: .keep, focus: true),
                requestID,
                "create-tab",
                ["focus", "launch", "operation", "policy", "requestID", "version"]
            ),
            (
                .split(
                    anchorPaneID: nil,
                    direction: .left,
                    ratio: 0.25,
                    launch: launch,
                    policy: .closeOnSuccess,
                    focus: false
                ),
                requestID,
                "split",
                [
                    "anchorPaneID", "direction", "focus", "launch", "operation", "policy",
                    "ratio", "requestID", "version",
                ]
            ),
            (.read(taskID: taskID), nil, "read", ["operation", "taskID", "version"]),
            (
                .wait(taskID: taskID, revision: 7, timeoutMilliseconds: 1_000),
                nil,
                "wait",
                ["operation", "revision", "taskID", "timeoutMilliseconds", "version"]
            ),
            (
                .sendText(taskID: taskID, expectedRevision: 7, text: "printf /tmp/path\n"),
                requestID,
                "send-text",
                ["expectedRevision", "operation", "requestID", "taskID", "text", "version"]
            ),
            (
                .sendKey(taskID: taskID, expectedRevision: 7, key: .controlC),
                requestID,
                "send-key",
                ["expectedRevision", "key", "operation", "requestID", "taskID", "version"]
            ),
            (
                .requestUserInput(taskID: taskID),
                requestID,
                "request-user-input",
                ["operation", "requestID", "taskID", "version"]
            ),
            (
                .focus(taskID: taskID),
                requestID,
                "focus",
                ["operation", "requestID", "taskID", "version"]
            ),
            (
                .resize(taskID: taskID, ratio: 0.75),
                requestID,
                "resize",
                ["operation", "ratio", "requestID", "taskID", "version"]
            ),
            (
                .interrupt(taskID: taskID, expectedRevision: 7),
                requestID,
                "interrupt",
                ["expectedRevision", "operation", "requestID", "taskID", "version"]
            ),
            (
                .close(taskID: taskID),
                requestID,
                "close",
                ["operation", "requestID", "taskID", "version"]
            ),
        ]

        for (operation, mutationID, discriminator, expectedFields) in operations {
            let request = try TerminalControlRequest(operation: operation, requestID: mutationID)
            let encoded = try TerminalControlProtocol.encodeRequest(request)
            let object = try jsonObject(encoded)

            #expect(Set(object.keys) == expectedFields)
            #expect(object["operation"] as? String == discriminator)
            #expect(try TerminalControlProtocol.decodeRequest(encoded) == request)
            #expect(object["paneToken"] == nil)
            #expect(!encoded.contains(Data("paneToken".utf8)))
        }
    }

    @Test
    func nestedLaunchUsesExactCanonicalFields() throws {
        let request = try TerminalControlRequest(
            operation: .createTab(launch: makeLaunch(), policy: .keep, focus: false),
            requestID: requestID
        )
        let object = try jsonObject(TerminalControlProtocol.encodeRequest(request))
        let launch = try #require(object["launch"] as? [String: Any])

        #expect(Set(launch.keys) == ["arguments", "cwd", "executable"])
    }

    @Test
    func everyResponseVariantRoundTripsWithExactFields() throws {
        let task = makeTask()
        let snapshot = try TerminalControlSnapshot(
            task: task,
            text: "hello /tmp/world\n",
            isTruncated: false
        )
        let workspace = try TerminalControlWorkspaceMetadata(
            workspaceID: workspaceID,
            name: "Main",
            originPaneID: paneID,
            activeTabID: tabID,
            tabCount: 2,
            paneCount: 3
        )
        let failure = try TerminalControlError(
            code: .targetNotOwned,
            message: "Task is not owned"
        )
        let responses: [(TerminalControlResponse, String, Set<String>)] = [
            (
                TerminalControlResponse(result: .list(workspace: workspace, tasks: [task])),
                "list",
                ["response", "tasks", "version", "workspace"]
            ),
            (
                TerminalControlResponse(result: .task(task)),
                "task",
                ["response", "task", "version"]
            ),
            (
                TerminalControlResponse(result: .snapshot(snapshot)),
                "snapshot",
                ["response", "snapshot", "version"]
            ),
            (
                TerminalControlResponse(result: .acknowledged(taskID: taskID, revision: 8)),
                "acknowledged",
                ["response", "revision", "taskID", "version"]
            ),
            (
                TerminalControlResponse(result: .failure(failure)),
                "error",
                ["error", "response", "version"]
            ),
        ]

        for (response, discriminator, fields) in responses {
            let encoded = try TerminalControlProtocol.encodeResponse(response)
            let object = try jsonObject(encoded)

            #expect(Set(object.keys) == fields)
            #expect(object["response"] as? String == discriminator)
            #expect(try TerminalControlProtocol.decodeResponse(encoded) == response)
            #expect(object["paneToken"] == nil)
            #expect(!encoded.contains(Data("paneToken".utf8)))
        }
    }

    @Test
    func nestedResponseModelsUseExactFields() throws {
        let task = makeTask()
        let snapshot = try TerminalControlSnapshot(task: task, text: "ready", isTruncated: true)
        let workspace = try TerminalControlWorkspaceMetadata(
            workspaceID: workspaceID,
            name: "Main",
            originPaneID: paneID,
            activeTabID: tabID,
            tabCount: 1,
            paneCount: 1
        )
        let listObject = try jsonObject(
            TerminalControlProtocol.encodeResponse(
                TerminalControlResponse(result: .list(workspace: workspace, tasks: [task]))
            )
        )
        let workspaceObject = try #require(listObject["workspace"] as? [String: Any])
        let taskObject = try #require((listObject["tasks"] as? [[String: Any]])?.first)
        let snapshotObject = try jsonObject(
            TerminalControlProtocol.encodeResponse(
                TerminalControlResponse(result: .snapshot(snapshot))
            )
        )
        let nestedSnapshot = try #require(snapshotObject["snapshot"] as? [String: Any])
        let errorObject = try jsonObject(
            TerminalControlProtocol.encodeResponse(
                TerminalControlResponse(
                    result: .failure(
                        try TerminalControlError(code: .timeout, message: "Timed out")
                    )
                )
            )
        )
        let nestedError = try #require(errorObject["error"] as? [String: Any])

        #expect(
            Set(workspaceObject.keys)
                == ["activeTabID", "name", "originPaneID", "paneCount", "tabCount", "workspaceID"]
        )
        #expect(
            Set(taskObject.keys)
                == [
                    "exitCode", "owner", "paneID", "policy", "revision", "state", "tabID",
                    "taskID", "workspaceID",
                ]
        )
        #expect(Set(nestedSnapshot.keys) == ["isTruncated", "task", "text"])
        #expect(Set(nestedError.keys) == ["code", "message"])
    }

    @Test
    func stableEnumRawValuesAreFrozen() {
        #expect(
            TerminalTaskLifecyclePolicy.allCases.map(\.rawValue) == ["keep", "close-on-success"])
        #expect(
            TerminalTaskState.allCases.map(\.rawValue)
                == [
                    "creating", "running", "waiting-for-user", "succeeded", "failed",
                    "finished-unknown", "cancelled",
                ]
        )
        #expect(TerminalPaneControlOwner.allCases.map(\.rawValue) == ["agent", "user", "finished"])
        #expect(TerminalSplitDirection.allCases.map(\.rawValue) == ["left", "right", "up", "down"])
        #expect(
            TerminalControlKey.allCases.map(\.rawValue)
                == [
                    "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left",
                    "arrow-right", "backspace", "delete", "ctrl-c", "ctrl-d",
                ]
        )
        #expect(
            TerminalControlErrorCode.allCases.map(\.rawValue)
                == [
                    "permissionRequired", "permissionDenied", "permissionRevoked",
                    "permissionUnavailable", "invalidSession", "staleSession", "targetNotFound",
                    "targetNotOwned", "staleTerminalRevision", "userControlsPane",
                    "processFinished", "resourceLimit", "invalidLaunchRequest", "invalidRequest",
                    "requestIDConflict", "surfaceCreationFailed", "modelMutationFailed",
                    "closeConfirmationDenied", "timeout", "cancelled", "internalFailure",
                ]
        )
    }

    @Test
    func mutatingRequestIDsHaveStrictShape() throws {
        #expect(throws: TerminalControlValidationError.missingRequestID) {
            try TerminalControlRequest(
                operation: .focus(taskID: taskID),
                requestID: nil
            )
        }
        #expect(throws: TerminalControlValidationError.unexpectedRequestID) {
            try TerminalControlRequest(operation: .read(taskID: taskID), requestID: requestID)
        }

        let missing = Data(
            "{\"operation\":\"close\",\"taskID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"version\":1}"
                .utf8
        )
        let extra = Data(
            "{\"operation\":\"read\",\"requestID\":\"44444444-5555-6666-7777-888888888888\",\"taskID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"version\":1}"
                .utf8
        )
        for payload in [missing, extra] {
            #expect(throws: TerminalControlProtocolError.invalidPayload) {
                try TerminalControlProtocol.decodeRequest(payload)
            }
        }
    }

    @Test
    func validatesLaunchTextRatioTimeoutAndSnapshotBounds() throws {
        _ = try TerminalControlLaunch(
            executable: "/" + String(repeating: "e", count: 4_095),
            arguments: Array(repeating: String(repeating: "a", count: 128), count: 256),
            cwd: "/" + String(repeating: "w", count: 4_095)
        )
        #expect(throws: TerminalControlValidationError.invalidExecutable) {
            try TerminalControlLaunch(executable: "bin/tool", arguments: [], cwd: "/tmp")
        }
        #expect(throws: TerminalControlValidationError.invalidExecutable) {
            try TerminalControlLaunch(executable: "/tmp/../bin/tool", arguments: [], cwd: "/tmp")
        }
        #expect(throws: TerminalControlValidationError.invalidExecutable) {
            try TerminalControlLaunch(
                executable: "/" + String(repeating: "e", count: 4_096),
                arguments: [],
                cwd: "/tmp"
            )
        }
        #expect(throws: TerminalControlValidationError.invalidWorkingDirectory) {
            try TerminalControlLaunch(executable: "/bin/tool", arguments: [], cwd: "tmp")
        }
        #expect(throws: TerminalControlValidationError.invalidWorkingDirectory) {
            try TerminalControlLaunch(
                executable: "/bin/tool",
                arguments: [],
                cwd: "/" + String(repeating: "w", count: 4_096)
            )
        }
        #expect(throws: TerminalControlValidationError.invalidArguments) {
            try TerminalControlLaunch(
                executable: "/bin/tool",
                arguments: Array(repeating: "", count: 257),
                cwd: "/tmp"
            )
        }
        #expect(throws: TerminalControlValidationError.invalidArguments) {
            try TerminalControlLaunch(
                executable: "/bin/tool",
                arguments: [String(repeating: "a", count: 4_097)],
                cwd: "/tmp"
            )
        }
        #expect(throws: TerminalControlValidationError.invalidArguments) {
            try TerminalControlLaunch(
                executable: "/bin/tool",
                arguments: Array(repeating: String(repeating: "a", count: 129), count: 256),
                cwd: "/tmp"
            )
        }

        for text in ["", String(repeating: "é", count: 2_049)] {
            #expect(throws: TerminalControlValidationError.invalidText) {
                try TerminalControlRequest(
                    operation: .sendText(taskID: taskID, expectedRevision: 0, text: text),
                    requestID: requestID
                )
            }
        }
        for ratio in [Double.nan, .infinity, -.infinity, 0.09, 0.91] {
            #expect(throws: TerminalControlValidationError.invalidRatio) {
                try TerminalControlRequest(
                    operation: .resize(taskID: taskID, ratio: ratio),
                    requestID: requestID
                )
            }
        }
        for timeout in [99, 30_001] {
            #expect(throws: TerminalControlValidationError.invalidTimeout) {
                try TerminalControlRequest(
                    operation: .wait(
                        taskID: taskID,
                        revision: 0,
                        timeoutMilliseconds: timeout
                    )
                )
            }
        }
        #expect(throws: TerminalControlValidationError.snapshotTooLarge) {
            try TerminalControlSnapshot(
                task: makeTask(),
                text: String(repeating: "é", count: 32_769),
                isTruncated: true
            )
        }
    }

    @Test
    func rejectsUnknownMissingDuplicateUnsupportedAndNoncanonicalRequests() throws {
        let valid = try TerminalControlProtocol.encodeRequest(
            TerminalControlRequest(operation: .read(taskID: taskID))
        )
        let canonical = try #require(String(data: valid, encoding: .utf8))
        let invalidPayloads = [
            canonical.replacingOccurrences(of: "{", with: "{\"unknown\":true,", options: .anchored),
            canonical.replacingOccurrences(of: ",\"version\":1", with: ""),
            canonical.replacingOccurrences(
                of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            canonical.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            canonical.replacingOccurrences(
                of: taskID.uuidString,
                with: "not-a-uuid"
            ),
            " " + canonical,
            canonical.replacingOccurrences(of: "{\"operation\"", with: "{ \"operation\""),
            canonical.replacingOccurrences(
                of: "\"operation\":\"read\"",
                with: "\"operation\":\"read\",\"paneToken\":\"old-secret\""
            ),
        ]

        for payload in invalidPayloads {
            #expect(throws: TerminalControlProtocolError.invalidPayload) {
                try TerminalControlProtocol.decodeRequest(Data(payload.utf8))
            }
        }
        var invalidUTF8 = valid
        invalidUTF8[invalidUTF8.index(before: invalidUTF8.endIndex)] = 0xFF
        #expect(throws: TerminalControlProtocolError.invalidPayload) {
            try TerminalControlProtocol.decodeRequest(invalidUTF8)
        }
    }

    @Test
    func rejectsStrictNestedFieldViolationsAndInvalidNumbers() throws {
        let create = try #require(
            String(
                data: TerminalControlProtocol.encodeRequest(
                    TerminalControlRequest(
                        operation: .createTab(
                            launch: makeLaunch(),
                            policy: .keep,
                            focus: false
                        ),
                        requestID: requestID
                    )
                ),
                encoding: .utf8
            )
        )
        let invalidLaunches = [
            create.replacingOccurrences(
                of: "\"arguments\":[\"-lc\",\"printf /tmp/path\"]",
                with: "\"arguments\":[\"-lc\",\"printf /tmp/path\"],\"environment\":{}"
            ),
            create.replacingOccurrences(of: "\"cwd\":\"/tmp/project\",", with: ""),
            create.replacingOccurrences(
                of: "\"executable\":\"/bin/sh\"",
                with: "\"executable\":\"/bin/sh\",\"executable\":\"/bin/zsh\""
            ),
        ]
        for payload in invalidLaunches {
            #expect(throws: TerminalControlProtocolError.invalidPayload) {
                try TerminalControlProtocol.decodeRequest(Data(payload.utf8))
            }
        }

        let ratioPayload =
            create
            .replacingOccurrences(
                of: "\"operation\":\"create-tab\"",
                with:
                    "\"anchorPaneID\":null,\"direction\":\"left\",\"operation\":\"split\",\"ratio\":NaN"
            )
        #expect(throws: TerminalControlProtocolError.invalidPayload) {
            try TerminalControlProtocol.decodeRequest(Data(ratioPayload.utf8))
        }
    }

    @Test
    func rejectsStrictResponseViolationsAndOversizedFrames() throws {
        let response = TerminalControlResponse(
            result: .failure(
                try TerminalControlError(code: .invalidRequest, message: "Invalid request")
            )
        )
        let valid = try TerminalControlProtocol.encodeResponse(response)
        let canonical = try #require(String(data: valid, encoding: .utf8))
        let invalidPayloads = [
            canonical.replacingOccurrences(of: "{", with: "{\"extra\":0,", options: .anchored),
            canonical.replacingOccurrences(
                of: ",\"message\":\"Invalid request\"",
                with: ""
            ),
            canonical.replacingOccurrences(
                of: "\"code\":\"invalidRequest\"",
                with: "\"code\":\"invalidRequest\",\"paneToken\":\"old-secret\""
            ),
            "\n" + canonical,
        ]
        for payload in invalidPayloads {
            #expect(throws: TerminalControlProtocolError.invalidPayload) {
                try TerminalControlProtocol.decodeResponse(Data(payload.utf8))
            }
        }

        #expect(throws: TerminalControlProtocolError.requestTooLarge) {
            try TerminalControlProtocol.decodeRequest(
                Data(
                    repeating: UInt8(ascii: " "),
                    count: TerminalControlProtocol.maximumRequestSize + 1)
            )
        }
        #expect(throws: TerminalControlProtocolError.responseTooLarge) {
            try TerminalControlProtocol.decodeResponse(
                Data(
                    repeating: UInt8(ascii: " "),
                    count: TerminalControlProtocol.maximumResponseSize + 1)
            )
        }
    }

    @Test
    func preflightAndAuthenticationDataAreDomainSeparatedAndContextBound() throws {
        let preflight = try makePreflight()
        let challenge = Data(repeating: 0x24, count: TerminalControlProtocol.challengeSize)
        let encodedPreflight = try TerminalControlProtocol.encodePreflight(preflight)
        let lifecyclePreflightPrefix = try AgentIPCProtocol.encodePreflight(
            makeLifecyclePreflight()
        ).prefix(8)
        let request = try TerminalControlRequest(operation: .read(taskID: taskID))
        let response = TerminalControlResponse(
            result: .acknowledged(taskID: taskID, revision: 4)
        )
        let requestPayload = try TerminalControlProtocol.encodeRequest(request)
        let responsePayload = try TerminalControlProtocol.encodeResponse(response)
        let proofData = try TerminalControlProtocol.serverProofAuthenticationData(
            for: preflight,
            challenge: challenge
        )
        let requestData = try TerminalControlProtocol.requestFrameAuthenticationData(
            for: preflight,
            challenge: challenge,
            canonicalRequest: requestPayload
        )
        let responseData = try TerminalControlProtocol.responseFrameAuthenticationData(
            for: preflight,
            challenge: challenge,
            canonicalRequest: requestPayload,
            canonicalResponse: responsePayload
        )

        #expect(TerminalControlProtocol.version == 1)
        #expect(encodedPreflight.count == TerminalControlProtocol.preflightSize)
        #expect(try TerminalControlProtocol.decodePreflight(encodedPreflight) == preflight)
        #expect(TerminalControlProtocol.preflightMagic != lifecyclePreflightPrefix)
        #expect(
            TerminalControlProtocol.serverProofDomain
                != TerminalControlProtocol.requestFrameMACDomain)
        #expect(
            TerminalControlProtocol.requestFrameMACDomain
                != TerminalControlProtocol.responseFrameMACDomain)
        #expect(proofData != requestData)
        #expect(requestData != responseData)
        #expect(
            responseData.range(of: Data(SHA256Digest.fixtureDigest(of: requestPayload))) != nil
        )

        let changedRequest = try TerminalControlProtocol.encodeRequest(
            TerminalControlRequest(operation: .read(taskID: UUID()))
        )
        #expect(
            try TerminalControlProtocol.responseFrameAuthenticationData(
                for: preflight,
                challenge: challenge,
                canonicalRequest: changedRequest,
                canonicalResponse: responsePayload
            ) != responseData
        )
        #expect(throws: TerminalControlProtocolError.invalidPayload) {
            try TerminalControlProtocol.requestFrameAuthenticationData(
                for: preflight,
                challenge: challenge,
                canonicalRequest: Data(" \(String(decoding: requestPayload, as: UTF8.self))".utf8)
            )
        }
    }

    @Test
    func goldenCanonicalBytesAreStable() throws {
        let read = try TerminalControlRequest(operation: .read(taskID: taskID))
        let create = try TerminalControlRequest(
            operation: .createTab(
                launch: makeLaunch(),
                policy: .closeOnSuccess,
                focus: true
            ),
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let success = TerminalControlResponse(
            result: .acknowledged(taskID: taskID, revision: 7)
        )
        let failure = TerminalControlResponse(
            result: .failure(
                try TerminalControlError(code: .targetNotOwned, message: "Task is not owned")
            )
        )

        #expect(
            try TerminalControlProtocol.encodeRequest(read)
                == Data(
                    "{\"operation\":\"read\",\"taskID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"version\":1}"
                        .utf8
                )
        )
        #expect(
            try TerminalControlProtocol.encodeRequest(create)
                == Data(
                    "{\"focus\":true,\"launch\":{\"arguments\":[\"-lc\",\"printf /tmp/path\"],\"cwd\":\"/tmp/project\",\"executable\":\"/bin/sh\"},\"operation\":\"create-tab\",\"policy\":\"close-on-success\",\"requestID\":\"11111111-2222-3333-4444-555555555555\",\"version\":1}"
                        .utf8
                )
        )
        #expect(
            try TerminalControlProtocol.encodeResponse(success)
                == Data(
                    "{\"response\":\"acknowledged\",\"revision\":7,\"taskID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"version\":1}"
                        .utf8
                )
        )
        #expect(
            try TerminalControlProtocol.encodeResponse(failure)
                == Data(
                    "{\"error\":{\"code\":\"targetNotOwned\",\"message\":\"Task is not owned\"},\"response\":\"error\",\"version\":1}"
                        .utf8
                )
        )
    }

    private func makeLaunch() throws -> TerminalControlLaunch {
        try TerminalControlLaunch(
            executable: "/bin/sh",
            arguments: ["-lc", "printf /tmp/path"],
            cwd: "/tmp/project"
        )
    }

    private func makeTask() -> TerminalControlTask {
        TerminalControlTask(
            taskID: taskID,
            paneID: paneID,
            tabID: tabID,
            workspaceID: workspaceID,
            state: .running,
            owner: .agent,
            policy: .keep,
            revision: 7,
            exitCode: nil
        )
    }

    private func makePreflight() throws -> TerminalControlPreflight {
        try TerminalControlPreflight(
            instanceID: UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            paneID: paneID,
            nonce: Data(repeating: 0x42, count: TerminalControlProtocol.nonceSize)
        )
    }

    private func makeLifecyclePreflight() throws -> AgentIPCPreflight {
        try AgentIPCPreflight(
            instanceID: UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            paneID: paneID,
            nonce: Data(repeating: 0x42, count: AgentIPCProtocol.nonceSize)
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum SHA256Digest {
    static func fixtureDigest(of data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
