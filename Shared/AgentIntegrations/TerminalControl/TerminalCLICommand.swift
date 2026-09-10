import Foundation

public struct TerminalCLICommand: Equatable, Sendable {
    public let request: TerminalControlRequest

    public static let usage = """
        Usage:
          quicktty terminal list
          quicktty terminal create-tab --request-id UUID --cwd ABS --policy keep|close-on-success [--focus] -- ABS_EXEC [args...]
          quicktty terminal split --request-id UUID [--anchor-pane UUID] --direction left|right|up|down --ratio 0.1...0.9 --cwd ABS --policy keep|close-on-success [--focus] -- ABS_EXEC [args...]
          quicktty terminal read --task UUID
          quicktty terminal wait --task UUID --revision UINT64 --timeout-ms 100...30000
          quicktty terminal send-text --request-id UUID --task UUID --revision UINT64 --text TEXT
          quicktty terminal send-key --request-id UUID --task UUID --revision UINT64 --key KEY
          quicktty terminal request-user-input --request-id UUID --task UUID
          quicktty terminal focus --request-id UUID --task UUID
          quicktty terminal resize --request-id UUID --task UUID --ratio 0.1...0.9
          quicktty terminal interrupt --request-id UUID --task UUID --revision UINT64
          quicktty terminal close --request-id UUID --task UUID
        KEY: enter|tab|escape|arrow-up|arrow-down|arrow-left|arrow-right|backspace|delete|ctrl-c|ctrl-d
        """

    private init(request: TerminalControlRequest) {
        self.request = request
    }

    public static func parse(_ arguments: [String]) throws -> TerminalCLICommand {
        do {
            return try parseValidated(arguments)
        } catch {
            // WHY: Grammar failures must never carry literal text, argv or other caller values into diagnostics.
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
    }

    private static func parseValidated(_ arguments: [String]) throws -> TerminalCLICommand {
        guard let name = arguments.first else { throw QuickTTYCommand.ParseError.invalidGrammar }
        var options = try TerminalCLIOptions(
            Array(arguments.dropFirst()), isLaunch: name == "create-tab" || name == "split"
        )
        let operation: TerminalControlRequest.Operation
        switch name {
        case "list":
            operation = .list
        case "create-tab":
            operation = .createTab(
                launch: try options.launch(),
                policy: try options.policy(),
                focus: options.flag("--focus")
            )
        case "split":
            operation = .split(
                anchorPaneID: try options.optionalUUID("--anchor-pane"),
                direction: try options.direction(),
                ratio: try options.ratio(),
                launch: try options.launch(),
                policy: try options.policy(),
                focus: options.flag("--focus")
            )
        case "read":
            operation = .read(taskID: try options.uuid("--task"))
        case "wait":
            let timeout = try options.decimal("--timeout-ms")
            guard let milliseconds = Int(exactly: timeout) else {
                throw QuickTTYCommand.ParseError.invalidGrammar
            }
            operation = .wait(
                taskID: try options.uuid("--task"),
                revision: try options.decimal("--revision"),
                timeoutMilliseconds: milliseconds
            )
        case "send-text":
            operation = .sendText(
                taskID: try options.uuid("--task"),
                expectedRevision: try options.decimal("--revision"),
                text: try options.value("--text")
            )
        case "send-key":
            operation = .sendKey(
                taskID: try options.uuid("--task"),
                expectedRevision: try options.decimal("--revision"),
                key: try options.key()
            )
        case "request-user-input":
            operation = .requestUserInput(taskID: try options.uuid("--task"))
        case "focus":
            operation = .focus(taskID: try options.uuid("--task"))
        case "resize":
            operation = .resize(taskID: try options.uuid("--task"), ratio: try options.ratio())
        case "interrupt":
            operation = .interrupt(
                taskID: try options.uuid("--task"),
                expectedRevision: try options.decimal("--revision")
            )
        case "close":
            operation = .close(taskID: try options.uuid("--task"))
        default:
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        let requestID = try operation.requiresRequestID ? options.uuid("--request-id") : nil
        guard options.isEmpty else { throw QuickTTYCommand.ParseError.invalidGrammar }
        let request = try TerminalControlRequest(operation: operation, requestID: requestID)
        // WHY: The client connects before framing; escaped JSON must fit before any transport is invoked.
        _ = try TerminalControlProtocol.encodeRequest(request)
        return TerminalCLICommand(request: request)
    }

    static func run(
        arguments: [String],
        environment: () -> TerminalControlEnvironment?,
        send: (TerminalControlRequest, TerminalControlEnvironment) throws -> TerminalControlResponse
    ) -> TerminalCLIOutput {
        guard let command = try? parse(arguments) else { return .grammarError }
        return command.execute(environment: environment, send: send)
    }

    func execute(
        environment: () -> TerminalControlEnvironment?,
        send: (TerminalControlRequest, TerminalControlEnvironment) throws -> TerminalControlResponse
    ) -> TerminalCLIOutput {
        guard let identity = environment() else { return .invalidEnvironment }
        do {
            // WHY: The CLI never retries automatically; the caller owns the retry decision after uncertain delivery.
            // The caller may retry the identical payload with the same request ID.
            let response = try send(request, identity)
            var output = try TerminalControlProtocol.encodeResponse(response)
            output.append(10)
            let exitCode: Int32 = if case .failure = response.result { 1 } else { 0 }
            return TerminalCLIOutput(
                standardOutput: output, standardError: Data(), exitCode: exitCode)
        } catch {
            return .transportFailure
        }
    }
}

struct TerminalCLIOutput: Equatable, Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32

    static let grammarError = TerminalCLIOutput(
        standardOutput: Data(),
        standardError: Data((TerminalCLICommand.usage + "\n").utf8),
        exitCode: 2
    )
    static let invalidEnvironment = TerminalCLIOutput(
        standardOutput: Data(),
        standardError: Data("quicktty: invalid terminal environment\n".utf8),
        exitCode: 1
    )
    static let transportFailure = TerminalCLIOutput(
        standardOutput: Data(),
        standardError: Data("quicktty: terminal operation failed\n".utf8),
        exitCode: 1
    )
}

enum TerminalCLIValueParser {
    static func uuid(_ value: String) -> UUID? {
        // WHY: Foundation accepts more UUID spellings than the CLI contract, but hex case is immaterial here.
        guard value.utf8.count == 36,
            let uuid = UUID(uuidString: value),
            value.uppercased() == uuid.uuidString
        else { return nil }
        return uuid
    }
}

private struct TerminalCLIOptions {
    private var values: [String: String] = [:]
    private var invocation: [String]?

    var isEmpty: Bool { values.isEmpty && invocation == nil }

    init(_ arguments: [String], isLaunch: Bool) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--" {
                guard isLaunch, index + 1 < arguments.count else {
                    throw QuickTTYCommand.ParseError.invalidGrammar
                }
                // WHY: Everything after the executable is argv, not another layer of CLI options.
                invocation = Array(arguments.dropFirst(index + 1))
                break
            }
            guard values[flag] == nil else { throw QuickTTYCommand.ParseError.invalidGrammar }
            switch flag {
            case "--focus":
                values[flag] = "true"
                index += 1
            case "--request-id", "--cwd", "--policy", "--anchor-pane", "--direction", "--ratio",
                "--task", "--revision", "--timeout-ms", "--text", "--key":
                guard index + 1 < arguments.count else {
                    throw QuickTTYCommand.ParseError.invalidGrammar
                }
                values[flag] = arguments[index + 1]
                index += 2
            default:
                throw QuickTTYCommand.ParseError.invalidGrammar
            }
        }
        guard !isLaunch || invocation != nil else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
    }

    mutating func value(_ flag: String) throws -> String {
        guard let value = values.removeValue(forKey: flag) else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        return value
    }

    mutating func flag(_ name: String) -> Bool {
        values.removeValue(forKey: name) != nil
    }

    mutating func uuid(_ flag: String) throws -> UUID {
        guard let uuid = TerminalCLIValueParser.uuid(try value(flag)) else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        return uuid
    }

    mutating func optionalUUID(_ flag: String) throws -> UUID? {
        guard values[flag] != nil else { return nil }
        return try uuid(flag)
    }

    mutating func decimal(_ flag: String) throws -> UInt64 {
        let raw = try value(flag)
        guard !raw.isEmpty,
            raw.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let number = UInt64(raw)
        else { throw QuickTTYCommand.ParseError.invalidGrammar }
        return number
    }

    mutating func ratio() throws -> Double {
        let raw = try value("--ratio")
        guard
            !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }
            ),
            let number = Double(raw)
        else { throw QuickTTYCommand.ParseError.invalidGrammar }
        try TerminalControlValueValidator.validateRatio(number)
        return number
    }

    mutating func policy() throws -> TerminalTaskLifecyclePolicy {
        guard let policy = TerminalTaskLifecyclePolicy(rawValue: try value("--policy")) else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        return policy
    }

    mutating func direction() throws -> TerminalSplitDirection {
        guard let direction = TerminalSplitDirection(rawValue: try value("--direction")) else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        return direction
    }

    mutating func key() throws -> TerminalControlKey {
        guard let key = TerminalControlKey(rawValue: try value("--key")) else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        return key
    }

    mutating func launch() throws -> TerminalControlLaunch {
        guard let invocation, let executable = invocation.first else {
            throw QuickTTYCommand.ParseError.invalidGrammar
        }
        self.invocation = nil
        return try TerminalControlLaunch(
            executable: executable, arguments: Array(invocation.dropFirst()), cwd: value("--cwd")
        )
    }
}
