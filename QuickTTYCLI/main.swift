import Foundation

private func runIntegrationCommandAndExit(_ command: QuickTTYCommand) -> Never {
    Task {
        exit(await IntegrationsCommand.run(command))
    }
    dispatchMain()
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

do {
    let command = try QuickTTYCommand.parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .integrationsStatus, .integrationsInstall, .integrationsUninstall:
        runIntegrationCommandAndExit(command)
    case .internalHook(let adapterID, let event):
        exit(InternalHookCommand.run(adapterID: adapterID, event: event))
    case .internalLaunch:
        exit(InternalLaunchCommand.run())
    case .internalWrap(let adapterID, let arguments):
        exit(InternalWrapCommand.run(adapterID: adapterID, arguments: arguments))
    }
} catch let error as QuickTTYCommand.ParseError {
    writeStandardError("quicktty: \(error.description)\n\(QuickTTYCommand.usage)\n")
    exit(2)
} catch {
    writeStandardError("quicktty: invalid command\n\(QuickTTYCommand.usage)\n")
    exit(2)
}
