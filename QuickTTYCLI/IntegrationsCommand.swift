import Darwin
import Foundation

enum IntegrationsCommand {
    static func run(_ command: QuickTTYCommand) async -> Int32 {
        let action: AgentIntegrationInstallerAction?
        let selected: [String]
        let assumeYes: Bool
        switch command {
        case .integrationsStatus(let adapterIDs):
            action = nil
            selected = adapterIDs
            assumeYes = false
        case .integrationsInstall(let adapterIDs, let yes):
            action = .install
            selected = adapterIDs
            assumeYes = yes
        case .integrationsUninstall(let adapterIDs, let yes):
            action = .uninstall
            selected = adapterIDs
            assumeYes = yes
        default:
            return 2
        }

        if action != nil, !assumeYes, isatty(STDIN_FILENO) != 1 {
            writeError("quicktty: --yes is required when stdin is not a TTY\n")
            return 2
        }

        do {
            let installer = try makeInstaller()
            guard let action else {
                let statuses = try await installer.status(selectedAdapterIDs: selected)
                writeSummaries(statuses)
                return statuses.contains(where: { $0.status == .conflict || $0.status == .failed })
                    ? 1 : 0
            }

            let prepared = try await installer.prepare(
                action: action,
                selectedAdapterIDs: selected
            )
            writeSummaries(prepared.adapters)
            if !assumeYes {
                writeOutput("Apply these changes? Type yes: ")
                guard readLine(strippingNewline: true) == "yes" else {
                    writeOutput("Cancelled.\n")
                    return 0
                }
            }
            let result = try await installer.apply(planID: prepared.planID)
            writeSummaries(result.adapters)
            return result.adapters.contains(where: {
                $0.status == .conflict || $0.status == .failed
            }) ? 1 : 0
        } catch AgentIntegrationInstallerRequestError.unknownAdapter {
            writeError("quicktty: unknown integration ID\n\(QuickTTYCommand.usage)\n")
            return 2
        } catch is CancellationError {
            writeError("quicktty: operation cancelled\n")
            return 1
        } catch {
            writeError("quicktty: integration operation failed\n")
            return 1
        }
    }

    private static func makeInstaller() throws -> AgentIntegrationInstaller {
        guard let homeValue = ProcessInfo.processInfo.environment["HOME"],
            homeValue.hasPrefix("/"),
            let executable = Bundle.main.executableURL
        else { throw AgentIntegrationInstallerError.invalidPath }
        let home = URL(fileURLWithPath: homeValue, isDirectory: true)
        let applicationSupport = home.appending(
            path: "Library/Application Support", directoryHint: .isDirectory)
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let bundledResources = contents.appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "AgentSessionIntegrations", directoryHint: .isDirectory)
        let adjacentResources = executable.deletingLastPathComponent()
            .appending(path: "AgentSessionIntegrations", directoryHint: .isDirectory)
        let resourceRoot =
            FileManager.default.fileExists(atPath: bundledResources.path)
            ? bundledResources : adjacentResources
        return try AgentIntegrationInstaller(
            homeDirectory: home,
            applicationSupportDirectory: applicationSupport,
            resourceRoot: resourceRoot,
            helperExecutable: executable
        )
    }

    private static func writeSummaries(_ summaries: [AgentIntegrationAdapterSummary]) {
        for summary in summaries {
            writeOutput(
                "\(summary.adapterID): \(summary.capability.rawValue) \(summary.status.rawValue)\n"
            )
            for operation in summary.operations {
                let backup = operation.createsBackup ? " backup" : ""
                writeOutput(
                    "  \(operation.kind.rawValue) \(operation.displayPath)\(backup)\n"
                )
            }
        }
    }

    private static func writeOutput(_ message: String) {
        FileHandle.standardOutput.write(Data(message.utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
