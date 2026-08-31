import Foundation

public enum QuickTTYCommand: Equatable, Sendable {
    case integrationsStatus(adapterIDs: [String])
    case integrationsInstall(adapterIDs: [String], assumeYes: Bool)
    case integrationsUninstall(adapterIDs: [String], assumeYes: Bool)
    case internalHook(adapterID: String, event: String)
    case internalLaunch
    case internalWrap(adapterID: String, arguments: [String])

    public static let usage = """
        Usage:
          quicktty integrations status [ids...]
          quicktty integrations install [ids...] [--yes]
          quicktty integrations uninstall [ids...] [--yes]
        """

    public static func parse(_ arguments: [String]) throws -> QuickTTYCommand {
        guard let command = arguments.first else {
            throw ParseError.missingCommand
        }

        switch command {
        case "integrations":
            return try parseIntegrations(Array(arguments.dropFirst()))
        case "internal":
            return try parseInternal(Array(arguments.dropFirst()))
        default:
            if command.hasPrefix("-") {
                throw ParseError.unknownFlag(command)
            }
            throw ParseError.invalidGrammar
        }
    }

    public static func parse(arguments: [String]) throws -> QuickTTYCommand {
        try parse(arguments)
    }

    private static func parseIntegrations(_ arguments: [String]) throws -> QuickTTYCommand {
        guard let action = arguments.first else {
            throw ParseError.invalidGrammar
        }
        let operands = Array(arguments.dropFirst())

        switch action {
        case "status":
            if operands.contains("--yes") {
                throw ParseError.yesNotAllowed
            }
            return .integrationsStatus(adapterIDs: try parseAdapterIDs(operands))
        case "install":
            let parsed = try parseMutatingIntegrationOperands(operands)
            return .integrationsInstall(
                adapterIDs: parsed.adapterIDs,
                assumeYes: parsed.assumeYes
            )
        case "uninstall":
            let parsed = try parseMutatingIntegrationOperands(operands)
            return .integrationsUninstall(
                adapterIDs: parsed.adapterIDs,
                assumeYes: parsed.assumeYes
            )
        default:
            if action.hasPrefix("-") {
                throw ParseError.unknownFlag(action)
            }
            throw ParseError.invalidGrammar
        }
    }

    private static func parseMutatingIntegrationOperands(
        _ arguments: [String]
    ) throws -> (adapterIDs: [String], assumeYes: Bool) {
        guard arguments.filter({ $0 == "--yes" }).count <= 1 else {
            throw ParseError.duplicateYes
        }

        var adapterIDs: [String] = []
        var assumeYes = false

        for argument in arguments {
            if argument == "--yes" {
                assumeYes = true
                continue
            }
            if argument.hasPrefix("-") {
                throw ParseError.unknownFlag(argument)
            }
            guard !assumeYes else {
                throw ParseError.invalidGrammar
            }
            try validateAdapterID(argument)
            adapterIDs.append(argument)
        }

        return (adapterIDs, assumeYes)
    }

    private static func parseAdapterIDs(_ arguments: [String]) throws -> [String] {
        try arguments.map { argument in
            if argument.hasPrefix("-") {
                throw ParseError.unknownFlag(argument)
            }
            try validateAdapterID(argument)
            return argument
        }
    }

    private static func parseInternal(_ arguments: [String]) throws -> QuickTTYCommand {
        guard let action = arguments.first else {
            throw ParseError.invalidGrammar
        }

        switch action {
        case "hook":
            guard arguments.count == 3 else {
                throw ParseError.invalidGrammar
            }
            let adapterID = arguments[1]
            let event = arguments[2]
            try validateAdapterID(adapterID)
            guard isValidHookEvent(event) else {
                throw ParseError.invalidHookEvent(event)
            }
            return .internalHook(adapterID: adapterID, event: event)
        case "launch":
            guard arguments.count == 1 else {
                throw ParseError.invalidGrammar
            }
            return .internalLaunch
        case "wrap":
            guard arguments.count >= 3, arguments[2] == "--" else {
                throw ParseError.invalidGrammar
            }
            let adapterID = arguments[1]
            guard ["amp", "antigravity", "opencode"].contains(adapterID) else {
                throw ParseError.invalidWrapperAdapter(adapterID)
            }
            let invocationArguments = Array(arguments.dropFirst(3))
            guard invocationArguments.count <= 256,
                invocationArguments.allSatisfy({ $0.utf8.count <= 4_096 })
            else { throw ParseError.invalidArguments }
            return .internalWrap(adapterID: adapterID, arguments: invocationArguments)
        default:
            if action.hasPrefix("-") {
                throw ParseError.unknownFlag(action)
            }
            throw ParseError.invalidGrammar
        }
    }

    private static func validateAdapterID(_ adapterID: String) throws {
        guard AgentIPCValueValidator.isValidStableID(adapterID) else {
            throw ParseError.invalidAdapterID(adapterID)
        }
    }

    private static func isValidHookEvent(_ event: String) -> Bool {
        let bytes = event.utf8
        guard (1...64).contains(bytes.count) else { return false }
        if event.contains("_") {
            return [
                "session_start", "session_switch", "session_shutdown", "session_end",
                "pre_llm",
            ].contains(event)
        }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingCommand
        case invalidGrammar
        case unknownFlag(String)
        case duplicateYes
        case yesNotAllowed
        case invalidAdapterID(String)
        case invalidHookEvent(String)
        case invalidWrapperAdapter(String)
        case invalidExecutable
        case invalidArguments

        public var description: String {
            switch self {
            case .missingCommand:
                "missing command"
            case .invalidGrammar:
                "invalid command"
            case .unknownFlag:
                "unknown option"
            case .duplicateYes:
                "--yes may be specified only once"
            case .yesNotAllowed:
                "--yes is not valid for status"
            case .invalidAdapterID:
                "invalid integration ID"
            case .invalidHookEvent:
                "invalid hook event"
            case .invalidWrapperAdapter:
                "unknown wrapper integration"
            case .invalidExecutable:
                "internal wrap executable is invalid"
            case .invalidArguments:
                "internal wrap arguments exceed protocol bounds"
            }
        }
    }
}

public typealias QuickTTYCommandError = QuickTTYCommand.ParseError
