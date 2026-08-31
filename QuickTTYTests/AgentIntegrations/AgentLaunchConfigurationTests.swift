import Foundation
import Testing

@testable import QuickTTY

struct AgentLaunchConfigurationTests {
    @Test
    func buildsFixedHelperCommandAndCanonicalPayloadEnvironment() throws {
        let arguments = [
            "space value", "single'quote", "double\"quote", "$(touch /tmp/injected)",
            "; touch /tmp/injected", "line\nbreak", "", "猫 Привет 👩🏽‍💻",
        ]
        let invocation = try ExecutableInvocation(
            executablePath: "/opt/Agent Tools/agent",
            arguments: arguments,
            workingDirectory: "/tmp/Project With Spaces"
        )

        let configuration = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )

        #expect(
            configuration.command
                == "'/Applications/QuickTTY.app/Contents/Helpers/quicktty' internal launch"
        )
        for value in [invocation.executablePath, invocation.workingDirectory] + arguments {
            #expect(!configuration.command.contains(value))
        }

        let encodedPayload = try #require(
            configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]
        )
        let payload = try AgentInvocationPayloadCodec.decodeBase64(encodedPayload)
        let expectedPayload = try AgentInvocationPayload(
            executable: invocation.executablePath,
            arguments: arguments,
            workingDirectory: invocation.workingDirectory
        )
        #expect(payload == expectedPayload)
        #expect(
            configuration.environment[AgentInvocationPayloadEnvironment.helperKey]
                == "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )
        #expect(encodedPayload.utf8.count <= AgentInvocationPayloadCodec.maximumBase64Size)
    }

    @Test
    func generatedCommandLaunchesHelperAtApostrophePathWithExactArguments() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY Agent's Launch Test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let helperURL = temporaryDirectory.appending(path: "fake helper")
        let argumentsURL = temporaryDirectory.appending(path: "arguments")
        let markerURL = temporaryDirectory.appending(path: "marker")
        let helper = """
            #!/bin/sh
            set -eu
            printf '%s\\n' "$#" "$@" >"\(argumentsURL.path)"
            : >"\(markerURL.path)"
            """
        try Data(helper.utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: [],
            workingDirectory: "/tmp"
        )
        let configuration = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: helperURL.path
        )
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", configuration.command]
        shell.environment = configuration.environment

        try shell.run()
        shell.waitUntilExit()

        #expect(shell.terminationReason == .exit)
        #expect(shell.terminationStatus == 0)
        #expect(try String(contentsOf: argumentsURL, encoding: .utf8) == "2\ninternal\nlaunch\n")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func quotesApostropheInBundledHelperPathForPOSIXShell() throws {
        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: [],
            workingDirectory: "/tmp"
        )

        let configuration = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: "/Applications/Quick'TTY.app/Contents/Helpers/quicktty"
        )

        #expect(
            configuration.command
                == "'/Applications/Quick'\"'\"'TTY.app/Contents/Helpers/quicktty' internal launch"
        )
    }

    @Test
    func canonicalCodecRejectsFullyValidNoncanonicalJSON() throws {
        let payload = try AgentInvocationPayload(
            executable: "/opt/Agent Tools/agent",
            arguments: ["space value", "single'quote"],
            workingDirectory: "/tmp/Project With Spaces"
        )
        let canonicalData = try AgentInvocationPayloadCodec.encode(payload)
        let noncanonicalData = Data(
            """
            {
              "workingDirectory": "/tmp/Project With Spaces",
              "executable": "/opt/Agent Tools/agent",
              "arguments": ["space value", "single'quote"]
            }
            """.utf8
        )
        let canonicalObject = try JSONSerialization.jsonObject(with: canonicalData) as? NSDictionary
        let noncanonicalObject =
            try JSONSerialization.jsonObject(with: noncanonicalData) as? NSDictionary

        #expect(noncanonicalObject == canonicalObject)
        #expect(noncanonicalData != canonicalData)
        #expect(throws: AgentInvocationPayloadCodecError.invalidPayload) {
            try AgentInvocationPayloadCodec.decode(noncanonicalData)
        }
    }

    @Test
    func appOwnedReservedEnvironmentOverridesCallerCollisions() throws {
        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: ["resume"],
            workingDirectory: "/tmp"
        )
        let configuration = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )
        let paneEnvironment = [
            "QUICKTTY_PANE_ID": "pane-id",
            "QUICKTTY_AGENT_SOCKET": "/tmp/socket",
            "QUICKTTY_INSTANCE_ID": "instance-id",
            "QUICKTTY_PANE_TOKEN": "pane-token",
            AgentInvocationPayloadEnvironment.payloadKey: "caller-payload",
            AgentInvocationPayloadEnvironment.helperKey: "/caller/helper",
            "CALLER_VALUE": "preserved",
        ]

        let merged = configuration.mergingPaneEnvironment(paneEnvironment)

        #expect(merged["QUICKTTY_PANE_ID"] == "pane-id")
        #expect(merged["QUICKTTY_AGENT_SOCKET"] == "/tmp/socket")
        #expect(merged["QUICKTTY_INSTANCE_ID"] == "instance-id")
        #expect(merged["QUICKTTY_PANE_TOKEN"] == "pane-token")
        #expect(merged["CALLER_VALUE"] == "preserved")
        #expect(
            merged[AgentInvocationPayloadEnvironment.payloadKey]
                == configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]
        )
        #expect(
            merged[AgentInvocationPayloadEnvironment.helperKey]
                == configuration.environment[AgentInvocationPayloadEnvironment.helperKey]
        )
    }

    @Test
    func rejectsInvalidHelperPathsAndOversizedEncodedPayload() throws {
        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: [],
            workingDirectory: "/tmp"
        )

        for helperPath in [
            "relative/quicktty", "/bad\0quicktty", "/bad\nquicktty",
            "/" + String(repeating: "x", count: 4_096),
        ] {
            #expect(throws: AgentLaunchConfigurationError.invalidHelperPath) {
                try AgentLaunchConfiguration(
                    invocation: invocation,
                    bundledHelperPath: helperPath
                )
            }
        }

        let oversizedInvocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: Array(repeating: String(repeating: "\u{1}", count: 512), count: 64),
            workingDirectory: "/tmp"
        )
        #expect(throws: AgentLaunchConfigurationError.invalidPayload) {
            try AgentLaunchConfiguration(
                invocation: oversizedInvocation,
                bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
            )
        }
    }

    @Test
    func launchPayloadRemainsOutsidePersistedApplicationState() throws {
        let state = ApplicationState()
        let stateBeforeLaunch = try JSONEncoder().encode(state)
        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: ["sensitive-runtime-argument"],
            workingDirectory: "/tmp"
        )

        _ = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )

        let stateAfterLaunch = try JSONEncoder().encode(state)
        #expect(stateAfterLaunch == stateBeforeLaunch)
        #expect(!stateAfterLaunch.contains(Data("QUICKTTY_LAUNCH_PAYLOAD".utf8)))
        #expect(!stateAfterLaunch.contains(Data("sensitive-runtime-argument".utf8)))
    }
}
