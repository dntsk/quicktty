import Foundation

struct ExecutableInvocation: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String

    init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String
    ) throws {
        guard (1...4_096).contains(executablePath.utf8.count),
            executablePath.hasPrefix("/"),
            !executablePath.containsControlCharacter
        else {
            throw ExecutableInvocationValidationError.invalidExecutable
        }
        guard arguments.count <= 64,
            arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
            arguments.reduce(into: 0, { $0 += $1.utf8.count }) <= 32_768
        else {
            throw ExecutableInvocationValidationError.invalidInvocation
        }
        guard (1...4_096).contains(workingDirectory.utf8.count),
            workingDirectory.hasPrefix("/"),
            !workingDirectory.containsControlCharacter
        else {
            throw ExecutableInvocationValidationError.invalidWorkingDirectory
        }

        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

enum ExecutableInvocationValidationError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidWorkingDirectory
    case invalidInvocation
}

extension String {
    fileprivate var containsControlCharacter: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
