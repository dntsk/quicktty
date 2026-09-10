import Foundation
import Testing

@testable import QuickTTY

struct TerminalCLICommandTests {
    private let task = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let mutation = "44444444-5555-6666-7777-888888888888"
    private let pane = "11111111-2222-3333-4444-555555555555"

    private var taskID: UUID { UUID(uuidString: task)! }
    private var requestID: UUID { UUID(uuidString: mutation)! }
    private var paneID: UUID { UUID(uuidString: pane)! }
    private var mutationOptions: [String] { ["--request-id", mutation] }
    private var targetOptions: [String] { ["--task", task] }
    private var launchOptions: [String] {
        mutationOptions + ["--cwd", "/tmp/project", "--policy", "keep"]
    }
    private var syntheticValues: [String: Data] {
        [
            "QUICKTTY_INSTANCE_ID": Data(mutation.utf8),
            "QUICKTTY_PANE_ID": Data(pane.utf8),
            "QUICKTTY_PANE_TOKEN": Data(String(repeating: "a", count: 64).utf8),
            "QUICKTTY_CONTROL_SOCKET": Data("/synthetic/nonexistent/control.sock".utf8),
        ]
    }

    @Test
    func allOperationsForwardExactTypedRequestsAndDefaults() throws {
        let launch = try TerminalControlLaunch(
            executable: "/bin/tool", arguments: [], cwd: "/tmp/project"
        )
        let cases: [([String], TerminalControlRequest.Operation, UUID?)] = [
            (["list"], .list, nil),
            (
                ["create-tab"] + launchOptions + ["--", "/bin/tool"],
                .createTab(launch: launch, policy: .keep, focus: false), requestID
            ),
            (
                ["split"] + launchOptions
                    + ["--direction", "left", "--ratio", "0.5", "--", "/bin/tool"],
                .split(
                    anchorPaneID: nil, direction: .left, ratio: 0.5,
                    launch: launch, policy: .keep, focus: false
                ), requestID
            ),
            (["read"] + targetOptions, .read(taskID: taskID), nil),
            (
                ["wait"] + targetOptions + ["--revision", "7", "--timeout-ms", "1000"],
                .wait(taskID: taskID, revision: 7, timeoutMilliseconds: 1_000), nil
            ),
            (
                ["send-text"] + mutationOptions + targetOptions + [
                    "--revision", "7", "--text", "hello",
                ],
                .sendText(taskID: taskID, expectedRevision: 7, text: "hello"), requestID
            ),
            (
                ["send-key"] + mutationOptions + targetOptions + [
                    "--revision", "7", "--key", "enter",
                ],
                .sendKey(taskID: taskID, expectedRevision: 7, key: .enter), requestID
            ),
            (
                ["request-user-input"] + mutationOptions + targetOptions,
                .requestUserInput(taskID: taskID), requestID
            ),
            (["focus"] + mutationOptions + targetOptions, .focus(taskID: taskID), requestID),
            (
                ["resize"] + mutationOptions + targetOptions + ["--ratio", "0.5"],
                .resize(taskID: taskID, ratio: 0.5), requestID
            ),
            (
                ["interrupt"] + mutationOptions + targetOptions + ["--revision", "7"],
                .interrupt(taskID: taskID, expectedRevision: 7), requestID
            ),
            (["close"] + mutationOptions + targetOptions, .close(taskID: taskID), requestID),
        ]
        for (arguments, operation, id) in cases {
            let command = try TerminalCLICommand.parse(arguments)
            let expected = try TerminalControlRequest(operation: operation, requestID: id)
            #expect(command.request == expected)
            #expect(
                try TerminalControlProtocol.decodeRequest(
                    TerminalControlProtocol.encodeRequest(command.request)
                ) == expected)
            var sends = 0
            let output = command.execute(
                environment: { self.environment() },
                send: { request, identity in
                    sends += 1
                    #expect(request == expected)
                    #expect(identity.instanceID == requestID)
                    #expect(identity.paneID == paneID)
                    #expect(identity.paneToken == String(repeating: "a", count: 64))
                    #expect(identity.socketPath == "/synthetic/nonexistent/control.sock")
                    return TerminalControlResponse(
                        result: .acknowledged(taskID: taskID, revision: 7))
                }
            )
            #expect(sends == 1)
            #expect(output.exitCode == 0)
            #expect(output.standardError.isEmpty)
            let optionEnd = arguments.firstIndex(of: "--") ?? arguments.endIndex
            for index in stride(from: 1, to: optionEnd, by: 2) {
                var missing = arguments
                missing.removeSubrange(index...(index + 1))
                rejects(missing)
                var duplicate = arguments
                duplicate.insert(contentsOf: arguments[index...(index + 1)], at: optionEnd)
                rejects(duplicate)
            }
            if id == nil { rejects(arguments + mutationOptions) }
        }
    }

    @Test
    func allInputEnumsFocusAnchorAndOptionReordering() throws {
        for policy in TerminalTaskLifecyclePolicy.allCases {
            let command = try TerminalCLICommand.parse(
                ["create-tab", "--focus", "--policy", policy.rawValue, "--cwd", "/"]
                    + mutationOptions + ["--", "/bin/tool"]
            )
            #expect(
                command.request.operation
                    == .createTab(
                        launch: try TerminalControlLaunch(
                            executable: "/bin/tool", arguments: [], cwd: "/"),
                        policy: policy, focus: true
                    ))
        }
        for direction in TerminalSplitDirection.allCases {
            let arguments =
                ["split", "--anchor-pane", pane.lowercased(), "--focus"] + launchOptions
                + ["--direction", direction.rawValue, "--ratio", "0.9", "--", "/bin/tool"]
            let command = try TerminalCLICommand.parse(arguments)
            rejects(["split", "--anchor-pane", pane] + Array(arguments.dropFirst()))
            rejects(["split", "--focus"] + Array(arguments.dropFirst()))
            #expect(
                command.request.operation
                    == .split(
                        anchorPaneID: paneID, direction: direction, ratio: 0.9,
                        launch: try TerminalControlLaunch(
                            executable: "/bin/tool", arguments: [], cwd: "/tmp/project"
                        ), policy: .keep, focus: true
                    ))
        }
        for key in TerminalControlKey.allCases {
            let command = try TerminalCLICommand.parse(
                ["send-key", "--key", key.rawValue, "--revision", "0"]
                    + targetOptions + mutationOptions
            )
            #expect(
                command.request.operation
                    == .sendKey(
                        taskID: taskID, expectedRevision: 0, key: key
                    ))
        }
    }

    @Test
    func argvAndTextRemainLiteral() throws {
        let literals = [
            "--", "--request-id", "not-a-uuid", "$(touch x); | > &", "a b", "", "'quoted'", "\n",
        ]
        let command = try TerminalCLICommand.parse(
            ["create-tab"] + launchOptions + ["--", "/bin/tool"] + literals
        )
        #expect(
            command.request.operation
                == .createTab(
                    launch: try TerminalControlLaunch(
                        executable: "/bin/tool", arguments: literals, cwd: "/tmp/project"
                    ), policy: .keep, focus: false
                ))
        for text in literals.filter({ !$0.isEmpty }) + ["\0", "--focus", "--text"] {
            let parsed = try TerminalCLICommand.parse(textArguments(text))
            #expect(
                parsed.request.operation
                    == .sendText(
                        taskID: taskID, expectedRevision: 0, text: text
                    ))
        }
    }

    @Test
    func rejectsMalformedGrammarWithoutReadingEnvironmentOrSending() {
        let malformed = [
            [], ["unknown"], ["--help"], ["--focus", "list"], ["list", "extra"],
            ["list", "--"], ["list", "--focus"], ["list", "--request-id", mutation],
            ["read"], ["read", task], ["read", "--task"],
            ["read", "--task=" + task], ["read", "--ta", task],
            ["read"] + targetOptions + targetOptions,
            ["read"] + targetOptions + ["--revision", "0"],
            ["focus"] + targetOptions,
            ["focus"] + mutationOptions + targetOptions + mutationOptions,
            ["focus"] + mutationOptions + targetOptions + ["--focus"],
            ["create-tab"] + launchOptions + ["/bin/tool"],
            ["create-tab"] + launchOptions + ["--"],
            ["create-tab"] + launchOptions + ["--", "--", "/bin/tool"],
            ["create-tab"] + launchOptions + ["--focus", "--focus", "--", "/bin/tool"],
            ["create-tab"] + launchOptions + ["--focus", "true", "--", "/bin/tool"],
            ["create-tab"] + launchOptions + ["--anchor-pane", pane, "--", "/bin/tool"],
            ["create-tab"] + mutationOptions + [
                "--", "/bin/tool", "--cwd", "/", "--policy", "keep",
            ],
            ["split"] + launchOptions + ["--direction", "left", "--", "/bin/tool"],
            ["split"] + launchOptions + ["--ratio", "0.5", "--", "/bin/tool"],
            textArguments("ok") + ["extra"], textArguments("ok") + ["--text", "again"],
            ["send-text"] + mutationOptions + targetOptions + ["--revision", "0", "--text"],
            ["wait"] + targetOptions + ["--revision", "0", "--timeout", "100"],
        ]
        for arguments in malformed { rejects(arguments) }
        for flag in [
            "--socket", "--instance-id", "--pane-id", "--pane-token", "--adapter-id",
            "--session-id", "--json", "-f",
        ] {
            rejects(["list", flag, "synthetic"])
        }
        for (flag, value) in [("--policy", "Keep"), ("--policy", "closeOnSuccess")] {
            rejects(
                ["create-tab"] + mutationOptions + ["--cwd", "/", flag, value, "--", "/bin/tool"])
        }
        for direction in ["LEFT", "horizontal", "l"] {
            rejects(
                ["split"] + launchOptions + [
                    "--direction", direction, "--ratio", "0.5", "--", "/bin/tool",
                ])
        }
        for key in ["Enter", "control-c", "up", ""] {
            rejects(
                ["send-key"] + mutationOptions + targetOptions + ["--revision", "0", "--key", key])
        }
    }

    @Test
    func strictUUIDsForEveryUUIDOperand() throws {
        #expect(
            try TerminalCLICommand.parse(["read", "--task", task.lowercased()]).request.operation
                == .read(taskID: taskID))
        #expect(
            try TerminalCLICommand.parse(
                ["focus", "--request-id", mutation.lowercased()] + targetOptions
            ).request.requestID == requestID)
        let invalid = [
            "", "not-a-uuid", "1-1-1-1-1", task.replacingOccurrences(of: "-", with: ""),
            "{" + task + "}", " " + task, task + "\n", String(task.dropLast()),
            "GAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "AAAAAAAA_BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        ]
        for value in invalid {
            rejects(["read", "--task", value])
            rejects(["focus", "--request-id", value] + targetOptions)
            rejects(
                ["split"] + launchOptions + [
                    "--anchor-pane", value, "--direction", "up", "--ratio", "0.5", "--",
                    "/bin/tool",
                ])
        }
    }

    @Test
    func strictRevisionTimeoutAndRatioBoundaries() throws {
        for revision in ["0", "0007", String(UInt64.max)] {
            let command = try TerminalCLICommand.parse(
                ["interrupt"] + mutationOptions + targetOptions + ["--revision", revision]
            )
            #expect(
                command.request.operation
                    == .interrupt(
                        taskID: taskID, expectedRevision: try #require(UInt64(revision))
                    ))
        }
        for revision in [
            "", "-1", "+1", " 1", "1 ", "1\n", "1.0", "1e2", "0x10", "١", "18446744073709551616",
        ] {
            rejects(["wait"] + targetOptions + ["--revision", revision, "--timeout-ms", "100"])
            rejects(["interrupt"] + mutationOptions + targetOptions + ["--revision", revision])
            rejects(
                ["send-text"] + mutationOptions + targetOptions + [
                    "--revision", revision, "--text", "x",
                ])
            rejects(
                ["send-key"] + mutationOptions + targetOptions + [
                    "--revision", revision, "--key", "enter",
                ])
        }
        for timeout in [100, 30_000] {
            #expect(
                try TerminalCLICommand.parse(
                    ["wait"] + targetOptions + ["--revision", "0", "--timeout-ms", String(timeout)]
                ).request.operation
                    == .wait(taskID: taskID, revision: 0, timeoutMilliseconds: timeout))
        }
        for timeout in [
            "99", "30001", "-100", "+100", "100.0", " 100", "100 ", "18446744073709551616",
        ] {
            rejects(["wait"] + targetOptions + ["--revision", "0", "--timeout-ms", timeout])
        }
        for ratio in ["0.1", "0.9"] {
            #expect(
                try TerminalCLICommand.parse(
                    ["resize"] + mutationOptions + targetOptions + ["--ratio", ratio]
                ).request.operation == .resize(taskID: taskID, ratio: try #require(Double(ratio))))
            _ = try TerminalCLICommand.parse(
                ["split"] + launchOptions + [
                    "--direction", "down", "--ratio", ratio, "--", "/bin/tool",
                ]
            )
        }
        for ratio in [
            "", "nan", "NaN", "inf", "-inf", "1e999", "0.099999", "0.900001", "0", "1", " 0.5",
            "0.5 ",
        ] {
            rejects(["resize"] + mutationOptions + targetOptions + ["--ratio", ratio])
            rejects(
                ["split"] + launchOptions + [
                    "--direction", "down", "--ratio", ratio, "--", "/bin/tool",
                ])
        }
    }

    @Test
    func canonicalPathsAndByteBoundsWithoutFilesystemChecks() throws {
        let maximumPath = "/" + String(repeating: "p", count: 4_095)
        _ = try TerminalCLICommand.parse(
            ["create-tab"] + mutationOptions + [
                "--cwd", maximumPath, "--policy", "keep", "--", maximumPath,
            ]
        )
        for path in [
            "", "tool", "./tool", "~/tool", "//tool", "/tmp/../tool", "/tmp/./tool", "/tmp//tool",
            "/tmp/tool/", "/tmp/\0tool", "/tmp/\ntool", "/tmp/e\u{301}", maximumPath + "p",
        ] {
            rejects(["create-tab"] + launchOptions + ["--", path])
            rejects(
                ["create-tab"] + mutationOptions + [
                    "--cwd", path, "--policy", "keep", "--", "/bin/tool",
                ])
        }
        let prefix = ["create-tab"] + launchOptions + ["--", "/nonexistent/tool"]
        for arguments in [
            Array(repeating: "", count: 256),
            [String(repeating: "é", count: 2_048)],
            Array(repeating: String(repeating: "a", count: 4_096), count: 8),
        ] {
            _ = try TerminalCLICommand.parse(prefix + arguments)
        }
        for arguments in [
            Array(repeating: "", count: 257), [String(repeating: "é", count: 2_049)],
            Array(repeating: String(repeating: "a", count: 4_096), count: 8) + ["a"], ["a\0b"],
            // WHY: Valid argv byte totals can still overflow the authenticated JSON frame after escaping.
            Array(repeating: String(repeating: "\u{1}", count: 4_096), count: 8),
        ] {
            rejects(prefix + arguments)
        }
        _ = try TerminalCLICommand.parse(textArguments(String(repeating: "é", count: 2_048)))
        rejects(textArguments(""))
        rejects(textArguments(String(repeating: "é", count: 2_049)))
    }

    @Test
    func escapedFrameFitsExactlyAndRejectsTheNextByteBeforeTransport() throws {
        let prefix = ["create-tab"] + launchOptions + ["--", "/bin/tool"]
        let empty = try TerminalCLICommand.parse(prefix + Array(repeating: "", count: 8))
        let overhead = try TerminalControlProtocol.encodeRequest(empty.request).count
        let remaining = TerminalControlProtocol.maximumRequestPayloadSize - overhead
        // WHY: Each U+0001 needs six JSON bytes; empty argv slots keep structural overhead unchanged.
        let literal =
            String(repeating: "\u{1}", count: remaining / 6)
            + String(repeating: "a", count: remaining % 6)
        let arguments = (0..<8).map { index in
            String(literal.dropFirst(index * 4_096).prefix(4_096))
        }
        let exact = try TerminalCLICommand.parse(prefix + arguments)
        #expect(
            try TerminalControlProtocol.encodeRequest(exact.request).count
                == TerminalControlProtocol.maximumRequestPayloadSize)
        var overflow = arguments
        overflow[7] += "a"
        rejects(prefix + overflow)
    }

    @Test
    func environmentReadsOnlyFourBoundedValuesAndAcceptsStrictUTF8() throws {
        var reads: [(String, Int)] = []
        let values = syntheticValues
        let identity = try #require(
            TerminalControlEnvironment.read { key, limit in
                reads.append((key, limit))
                return values[key]
            })
        #expect(
            reads.map(\.0) == [
                "QUICKTTY_INSTANCE_ID", "QUICKTTY_PANE_ID", "QUICKTTY_PANE_TOKEN",
                "QUICKTTY_CONTROL_SOCKET",
            ])
        #expect(reads.map(\.1) == [36, 36, 64, 103])
        #expect(identity.instanceID == requestID)
        #expect(identity.paneID == paneID)
        #expect(identity.socketPath == "/synthetic/nonexistent/control.sock")
        for path in ["/" + String(repeating: "p", count: 102), "/tmp/é.sock"] {
            var changed = values
            changed["QUICKTTY_CONTROL_SOCKET"] = Data(path.utf8)
            #expect(TerminalControlEnvironment.read { key, _ in changed[key] } != nil)
        }
        var lowercase = values
        lowercase["QUICKTTY_INSTANCE_ID"] = Data(task.lowercased().utf8)
        #expect(TerminalControlEnvironment.read { key, _ in lowercase[key] }?.instanceID == taskID)
    }

    @Test
    func invalidEnvironmentCannotSendOrLeakDiagnostics() {
        let invalidByKey: [String: [Data]] = [
            "QUICKTTY_INSTANCE_ID": [Data(), Data("1-1-1-1-1".utf8), Data((mutation + "x").utf8)],
            "QUICKTTY_PANE_ID": [
                Data(), Data(task.replacingOccurrences(of: "-", with: "").utf8),
                Data((pane + "\0").utf8),
            ],
            "QUICKTTY_PANE_TOKEN": [
                Data(), Data(String(repeating: "A", count: 64).utf8),
                Data(String(repeating: "a", count: 63).utf8),
                Data(String(repeating: "a", count: 65).utf8),
            ],
            "QUICKTTY_CONTROL_SOCKET": [
                "", "/", "relative.sock", "/tmp//sock", "/tmp/./sock", "/tmp/../sock", "/tmp/sock/",
                "/tmp/e\u{301}", "/tmp/\0sock", "/tmp/\nsock",
                "/" + String(repeating: "p", count: 103),
                "/" + String(repeating: "é", count: 52),
            ].map { Data($0.utf8) },
        ]
        for (key, invalidValues) in invalidByKey {
            for value in invalidValues.map(Optional.some) + [
                nil, Data([0xFF]), Data([0xC3, 0x28]),
            ] {
                var values = syntheticValues
                values[key] = value
                var sends = 0
                let output = TerminalCLICommand.run(
                    arguments: ["list"],
                    environment: { TerminalControlEnvironment.read { name, _ in values[name] } },
                    send: { _, _ in
                        sends += 1
                        return TerminalControlResponse(
                            result: .acknowledged(taskID: taskID, revision: 0))
                    }
                )
                #expect(sends == 0)
                #expect(output.exitCode == 1)
                #expect(output.standardOutput.isEmpty)
                #expect(
                    output.standardError == Data("quicktty: invalid terminal environment\n".utf8))
            }
        }
    }

    @Test
    func independentCanonicalOutputGoldens() throws {
        let success = runReply(
            TerminalControlResponse(result: .acknowledged(taskID: taskID, revision: 7)))
        #expect(success.exitCode == 0)
        #expect(success.standardError.isEmpty)
        #expect(
            success.standardOutput
                == Data(
                    "{\"response\":\"acknowledged\",\"revision\":7,\"taskID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"version\":1}\n"
                        .utf8
                ))
        let failure = runReply(
            TerminalControlResponse(
                result: .failure(
                    try TerminalControlError(code: .targetNotOwned, message: "Task is not owned")
                )))
        #expect(failure.exitCode == 1)
        #expect(failure.standardError.isEmpty)
        #expect(
            failure.standardOutput
                == Data(
                    "{\"error\":{\"code\":\"targetNotOwned\",\"message\":\"Task is not owned\"},\"response\":\"error\",\"version\":1}\n"
                        .utf8
                ))
    }

    @Test
    func allResponseVariantsMapToCanonicalOutputWithoutTransformingSnapshotText() throws {
        let taskValue = TerminalControlTask(
            taskID: taskID, paneID: paneID, tabID: requestID, workspaceID: requestID,
            state: .running, owner: .agent, policy: .keep, revision: UInt64.max, exitCode: nil
        )
        let workspace = try TerminalControlWorkspaceMetadata(
            workspaceID: requestID, name: "Main", originPaneID: paneID,
            activeTabID: requestID, tabCount: 1, paneCount: 1
        )
        let snapshot = try TerminalControlSnapshot(
            task: taskValue, text: "literal paneToken=synthetic sessionID=synthetic\n\"é\"\t\0",
            isTruncated: false
        )
        var variants: [TerminalControlResponse.Result] = [
            .list(workspace: workspace, tasks: [taskValue]), .task(taskValue), .snapshot(snapshot),
            .acknowledged(taskID: taskID, revision: UInt64.max),
        ]
        for state in TerminalTaskState.allCases {
            for owner in TerminalPaneControlOwner.allCases {
                for policy in TerminalTaskLifecyclePolicy.allCases {
                    variants.append(
                        .task(
                            TerminalControlTask(
                                taskID: taskID, paneID: paneID, tabID: requestID,
                                workspaceID: requestID,
                                state: state, owner: owner, policy: policy, revision: 0, exitCode: 1
                            )))
                }
            }
        }
        for code in TerminalControlErrorCode.allCases {
            variants.append(
                .failure(try TerminalControlError(code: code, message: "Domain message")))
        }
        for variant in variants {
            let response = TerminalControlResponse(result: variant)
            let output = runReply(response)
            let expectedExit: Int32 = if case .failure = variant { 1 } else { 0 }
            #expect(output.exitCode == expectedExit)
            #expect(output.standardError.isEmpty)
            #expect(
                output.standardOutput == (try TerminalControlProtocol.encodeResponse(response))
                    + Data([10]))
            #expect(
                try TerminalControlProtocol.decodeResponse(Data(output.standardOutput.dropLast()))
                    == response)
        }
    }

    @Test
    func transportFailuresSendOnceWithoutRetryOrRawDiagnostics() {
        let errors: [any Error] = [
            TerminalControlSocketClientError.invalidConfiguration,
            TerminalControlSocketClientError.timedOut,
            TerminalControlSocketClientError.serverAuthenticationFailed,
            TerminalControlSocketClientError.responseAuthenticationFailed,
            TerminalControlSocketClientError.invalidResponse,
            TerminalControlSocketClientError.transportFailure,
            AgentSocketClientError.systemCall("synthetic-secret-session-token", 13),
        ]
        for error in errors {
            var sends = 0
            let output = TerminalCLICommand.run(
                arguments: ["close"] + mutationOptions + targetOptions,
                environment: { self.environment() },
                send: { request, _ in
                    sends += 1
                    #expect(request.requestID == requestID)
                    throw error
                }
            )
            #expect(sends == 1)
            #expect(output.exitCode == 1)
            #expect(output.standardOutput.isEmpty)
            #expect(output.standardError == Data("quicktty: terminal operation failed\n".utf8))
        }
    }

    private func environment() -> TerminalControlEnvironment? {
        let values = syntheticValues
        return TerminalControlEnvironment.read { key, _ in values[key] }
    }

    private func textArguments(_ text: String) -> [String] {
        ["send-text"] + mutationOptions + targetOptions + ["--revision", "0", "--text", text]
    }

    private func runReply(_ response: TerminalControlResponse) -> TerminalCLIOutput {
        TerminalCLICommand.run(
            arguments: ["list"],
            environment: { self.environment() },
            send: { _, _ in
                response
            }
        )
    }

    private func rejects(_ arguments: [String]) {
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try TerminalCLICommand.parse(arguments)
        }
        var environmentReads = 0
        var sends = 0
        let output = TerminalCLICommand.run(
            arguments: arguments,
            environment: {
                environmentReads += 1
                return self.environment()
            },
            send: { _, _ in
                sends += 1
                return TerminalControlResponse(result: .acknowledged(taskID: taskID, revision: 0))
            }
        )
        #expect(environmentReads == 0)
        #expect(sends == 0)
        #expect(output.exitCode == 2)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError == Data((TerminalCLICommand.usage + "\n").utf8))
        #expect(output.standardError.count < 4_096)
    }
}
