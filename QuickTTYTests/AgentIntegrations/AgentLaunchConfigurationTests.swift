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
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty",
            executableSearchPath: "/sentinel/runtime/bin:/opt/homebrew/bin"
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
        #expect(configuration.environment["PATH"] == "/sentinel/runtime/bin:/opt/homebrew/bin")
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
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty",
            executableSearchPath: "/sentinel/runtime/bin:/opt/homebrew/bin"
        )
        let paneEnvironment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
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
        #expect(merged["PATH"] == "/sentinel/runtime/bin:/opt/homebrew/bin")
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
    func executableInvocationAccepts256ArgumentsWithinExistingByteBounds() throws {
        let boundedArgument = String(repeating: "a", count: 128)
        _ = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: Array(repeating: boundedArgument, count: 255),
            workingDirectory: "/tmp"
        )
        _ = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: Array(repeating: boundedArgument, count: 256),
            workingDirectory: "/tmp"
        )
        _ = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: Array(repeating: String(repeating: "x", count: 4_096), count: 8),
            workingDirectory: "/tmp"
        )

        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: "/bin/agent",
                arguments: Array(repeating: "", count: 257),
                workingDirectory: "/tmp"
            )
        }
        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: "/bin/agent",
                arguments: [String(repeating: "x", count: 4_097)],
                workingDirectory: "/tmp"
            )
        }
        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: "/bin/agent",
                arguments: Array(repeating: String(repeating: "x", count: 4_096), count: 8)
                    + ["x"],
                workingDirectory: "/tmp"
            )
        }
    }

    @Test
    func terminalTaskLaunchUsesOnlyFixedHelperCommandAndAppOwnedEnvironment() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY Task's Launch Test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let helperURL = temporaryDirectory.appending(path: "quicktty")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let targetDirectory = temporaryDirectory.appending(
            path: "User's Agent Tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: targetDirectory, withIntermediateDirectories: true)
        let executableURL = targetDirectory.appending(path: "$(agent);echo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let launch = try TerminalControlLaunch(
            executable: executableURL.path,
            arguments: ["$(touch /tmp/injected)", "; echo injected", "line\nbreak", "猫"],
            cwd: "/tmp/User's Project $(pwd);echo"
        )
        let helperPath = helperURL.path
        let expectedCommand =
            "'" + helperPath.replacingOccurrences(of: "'", with: "'\"'\"'")
            + "' internal launch"

        let configuration = try TerminalTaskLaunchConfiguration(
            launch: launch,
            bundledHelperPath: helperPath,
            executableSearchPath: "/app/bin:/usr/bin"
        )

        #expect(configuration.command == expectedCommand)
        #expect(configuration.helperPath == helperPath)
        #expect(GhosttySurfaceConfiguration().managedHelperPath == nil)
        let managed = GhosttySurfaceConfiguration(managedHelperPath: configuration.helperPath)
        #expect(managed.managedHelperPath == helperPath)
        #expect(managed.environment.isEmpty)
        for value in [launch.executable, launch.cwd] + launch.arguments {
            #expect(!configuration.command.contains(value))
        }
        #expect(
            Set(configuration.environment.keys)
                == [
                    "PATH",
                    AgentInvocationPayloadEnvironment.payloadKey,
                    AgentInvocationPayloadEnvironment.helperKey,
                ]
        )
        #expect(configuration.environment["PATH"] == "/app/bin:/usr/bin")
        #expect(
            configuration.environment[AgentInvocationPayloadEnvironment.helperKey] == helperPath)
        for key in [
            "QUICKTTY_INSTANCE_ID",
            "QUICKTTY_PANE_ID",
            "QUICKTTY_PANE_TOKEN",
            "QUICKTTY_AGENT_SOCKET",
            "QUICKTTY_CONTROL_SOCKET",
        ] {
            #expect(configuration.environment[key] == nil)
        }

        let encodedPayload = try #require(
            configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]
        )
        #expect(
            try AgentInvocationPayloadCodec.decodeBase64(encodedPayload)
                == AgentInvocationPayload(
                    executable: launch.executable,
                    arguments: launch.arguments,
                    workingDirectory: launch.cwd
                )
        )
    }

    @Test
    func terminalTaskLaunchRejectsInvalidBundledHelperPaths() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Invalid-Helper-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let nonExecutableURL = temporaryDirectory.appending(path: "non-executable")
        try Data("not executable".utf8).write(to: nonExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: nonExecutableURL.path
        )

        // WHY: An invalid helper must retain precedence even when the target is also missing.
        let launch = try TerminalControlLaunch(
            executable: temporaryDirectory.appending(path: "missing-target").path,
            arguments: [],
            cwd: "/tmp"
        )
        let nonexistentPath = temporaryDirectory.appending(path: "missing").path
        let invalidPaths = [
            "quicktty",
            temporaryDirectory.path + "/./quicktty",
            temporaryDirectory.path + "//quicktty",
            temporaryDirectory.path + "/quicktty/",
            "/bad\nquicktty",
            nonexistentPath,
            nonExecutableURL.path,
        ]

        for helperPath in invalidPaths {
            #expect(throws: AgentLaunchConfigurationError.invalidHelperPath) {
                try TerminalTaskLaunchConfiguration(
                    launch: launch,
                    bundledHelperPath: helperPath
                )
            }
        }
    }

    @Test
    func terminalTaskLaunchPreflightsActualExecutableFilesAndSymlinks() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(
            path: "QuickTTY-Target-Preflight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appending(path: "executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let nonExecutable = directory.appending(path: "non-executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonExecutable)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
        let searchableDirectory = directory.appending(
            path: "searchable", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: searchableDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: searchableDirectory.path)
        let missing = directory.appending(path: "missing")
        let executableLink = directory.appending(path: "executable-link")
        try fileManager.createSymbolicLink(at: executableLink, withDestinationURL: executable)
        let directoryLink = directory.appending(path: "directory-link")
        try fileManager.createSymbolicLink(
            at: directoryLink, withDestinationURL: searchableDirectory)
        let danglingLink = directory.appending(path: "dangling-link")
        try fileManager.createSymbolicLink(at: danglingLink, withDestinationURL: missing)
        let nonExecutableLink = directory.appending(path: "non-executable-link")
        try fileManager.createSymbolicLink(at: nonExecutableLink, withDestinationURL: nonExecutable)

        try #require(fileManager.isExecutableFile(atPath: executable.path))
        try #require(fileManager.isExecutableFile(atPath: searchableDirectory.path))
        try #require(!fileManager.isExecutableFile(atPath: nonExecutable.path))
        try #require(!fileManager.fileExists(atPath: missing.path))
        for target in [
            missing, nonExecutable, searchableDirectory, directoryLink, danglingLink,
            nonExecutableLink,
        ] {
            let launch = try TerminalControlLaunch(
                executable: target.path, arguments: [], cwd: directory.path)
            #expect(throws: AgentLaunchConfigurationError.invalidPayload) {
                try TerminalTaskLaunchConfiguration(
                    launch: launch, bundledHelperPath: executable.path)
            }
        }
        for target in [executable, executableLink] {
            let launch = try TerminalControlLaunch(
                executable: target.path, arguments: ["literal argument"], cwd: directory.path)
            let configuration = try TerminalTaskLaunchConfiguration(
                launch: launch, bundledHelperPath: executable.path)
            let payload = try AgentInvocationPayloadCodec.decodeBase64(
                #require(configuration.environment[AgentInvocationPayloadEnvironment.payloadKey]))
            #expect(payload.executable == target.path)
            #expect(payload.arguments == launch.arguments)
            #expect(payload.workingDirectory == directory.path)
        }
    }

    @Test
    func launchPayloadRemainsOutsidePersistedApplicationState() throws {
        let state = ApplicationState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stateBeforeLaunch = try encoder.encode(state)
        let invocation = try ExecutableInvocation(
            executablePath: "/bin/agent",
            arguments: ["sensitive-runtime-argument"],
            workingDirectory: "/tmp"
        )

        _ = try AgentLaunchConfiguration(
            invocation: invocation,
            bundledHelperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )

        let stateAfterLaunch = try encoder.encode(state)
        #expect(stateAfterLaunch == stateBeforeLaunch)
        #expect(!stateAfterLaunch.contains(Data("QUICKTTY_LAUNCH_PAYLOAD".utf8)))
        #expect(!stateAfterLaunch.contains(Data("sensitive-runtime-argument".utf8)))
    }
}
