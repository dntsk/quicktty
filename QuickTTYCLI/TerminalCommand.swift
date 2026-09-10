import Foundation

enum TerminalCommand {
    static func run(_ command: TerminalCLICommand) -> Int32 {
        let output = command.execute(
            environment: { TerminalControlEnvironment.read() },
            send: { request, identity in
                // WHY: The shared client owns authentication and the permission-aware deadline policy.
                try TerminalControlSocketClient(
                    socketPath: identity.socketPath,
                    instanceID: identity.instanceID,
                    paneID: identity.paneID,
                    paneToken: identity.paneToken
                ).send(request)
            }
        )
        return write(output)
    }

    static func invalidGrammar() -> Int32 {
        write(.grammarError)
    }

    private static func write(_ output: TerminalCLIOutput) -> Int32 {
        if !output.standardOutput.isEmpty {
            FileHandle.standardOutput.write(output.standardOutput)
        }
        if !output.standardError.isEmpty {
            FileHandle.standardError.write(output.standardError)
        }
        return output.exitCode
    }
}
