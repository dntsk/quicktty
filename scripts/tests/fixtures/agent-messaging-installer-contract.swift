import Foundation

struct AgentMessagingInstallerContract {
    static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw InstallerContractFailure() }
        let repository = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            .appending(path: "owned-pi-upgrade", directoryHint: .isDirectory)
        let home = temporary.appending(path: "home", directoryHint: .isDirectory)
        let support = temporary.appending(path: "support", directoryHint: .isDirectory)
        let resources = repository.appending(
            path: "QuickTTY/Resources", directoryHint: .isDirectory)
        let oldResources = temporary.appending(path: "old-resources", directoryHint: .isDirectory)
        for directory in [oldResources, home, support] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        for directory in ["AgentSessionIntegrations", "AgentSkills"] {
            try FileManager.default.copyItem(
                at: resources.appending(path: directory),
                to: oldResources.appending(path: directory))
        }
        let legacy =
            "const helper = \"__QUICKTTY_HELPER_PATH__\"; export default function legacy() {}\n"
        try Data(legacy.utf8).write(
            to: oldResources.appending(path: "AgentSessionIntegrations/pi/index.ts"))
        let helper = URL(fileURLWithPath: "/test/quicktty")
        let oldInstaller = try AgentIntegrationInstaller(
            homeDirectory: home, applicationSupportDirectory: support,
            resourceRoot: oldResources.appending(path: "AgentSessionIntegrations"),
            helperExecutable: helper, executableAvailable: { $0 == "pi" }
        )
        let installation = try await oldInstaller.prepare(
            action: .install, selectedAdapterIDs: ["pi"])
        let installed = try await oldInstaller.apply(planID: installation.planID)
        try AgentMessagingContract.require(
            installed.adapters.first?.status == .succeeded, "Legacy fixture did not install")
        let currentInstaller = try AgentIntegrationInstaller(
            homeDirectory: home, applicationSupportDirectory: support,
            resourceRoot: resources.appending(path: "AgentSessionIntegrations"),
            helperExecutable: helper, executableAvailable: { $0 == "pi" }
        )
        let status = try await currentInstaller.status(selectedAdapterIDs: ["pi"])
        try AgentMessagingContract.require(
            status.first?.status == .updateAvailable,
            "Owned older Pi extension was not offered as an update")
        let update = try await currentInstaller.prepare(
            action: .install, selectedAdapterIDs: ["pi"])
        try AgentMessagingContract.require(
            update.adapters.first?.status == .updateAvailable, "Pi update preview missing")
        let extensionPath = "~/.pi/agent/extensions/quicktty-session/index.ts"
        try AgentMessagingContract.require(
            update.adapters.first?.operations.contains {
                $0.displayPath == extensionPath && $0.createsBackup && $0.operation == .update
            } == true, "Pi extension update did not preview backup")
        let applied = try await currentInstaller.apply(planID: update.planID)
        try AgentMessagingContract.require(
            applied.adapters.first?.status == .succeeded, "Pi extension update failed")
        let installedFile = home.appending(path: ".pi/agent/extensions/quicktty-session/index.ts")
        let source = try String(contentsOf: installedFile, encoding: .utf8)
        try AgentMessagingContract.require(
            source.contains("quicktty_ask_user") && source.contains("quicktty_confirm_action")
                && source.contains("quicktty_notify"),
            "Updated owned extension is missing messaging tools")
        let after = try await currentInstaller.status(selectedAdapterIDs: ["pi"])
        try AgentMessagingContract.require(
            after.first?.status == .installed, "Pi update did not converge")
        let removal = try await currentInstaller.prepare(
            action: .uninstall, selectedAdapterIDs: ["pi"])
        let removed = try await currentInstaller.apply(planID: removal.planID)
        try AgentMessagingContract.require(
            removed.adapters.first?.status == .succeeded
                && !FileManager.default.fileExists(atPath: installedFile.path),
            "Updated extension could not be uninstalled by ownership")
        print("PASS: owned Pi extension upgrade/backup/uninstall (temporary HOME only)")
        try await claudeContract(
            repository: repository, temporary: temporary.deletingLastPathComponent())
    }

    private static func claudeContract(repository: URL, temporary: URL) async throws {
        for scenario in ["upgrade", "uninstall", "tamper"] {
            let root = temporary.appending(path: "owned-claude-\(scenario)")
            let home = root.appending(path: "home")
            let support = root.appending(path: "support")
            let config = home.appending(path: ".claude/settings.json")
            try FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let foreign: [String: Any] = [
                "theme": "user-choice",
                "hooks": [
                    "PreToolUse": [
                        [
                            "matcher": "^Bash$",
                            "hooks": [["type": "command", "command": "foreign-policy"]],
                        ]
                    ]
                ],
            ]
            let baseline = try JSONSerialization.data(withJSONObject: foreign)
            try baseline.write(to: config)
            let helper = URL(fileURLWithPath: "/test/Helper's Directory/quicktty")
            let installer = try AgentIntegrationInstaller(
                homeDirectory: home, applicationSupportDirectory: support,
                resourceRoot: repository.appending(
                    path: "QuickTTY/Resources/AgentSessionIntegrations"),
                helperExecutable: helper, executableAvailable: { $0 == "claude" })
            let install = try await installer.prepare(
                action: .install, selectedAdapterIDs: ["claude"])
            let applied = try await installer.apply(planID: install.planID)
            try AgentMessagingContract.require(
                applied.adapters.first?.status == .succeeded, "Claude fixture install failed")
            var object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            var hooks = object["hooks"] as! [String: Any]
            var pre = hooks["PreToolUse"] as! [[String: Any]]
            guard
                let ownedIndex = pre.firstIndex(where: {
                    $0["matcher"] as? String == "^AskUserQuestion$"
                })
            else {
                throw InstallerContractFailure()
            }
            let commands = pre[ownedIndex]["hooks"] as! [[String: Any]]
            let expected =
                try AgentIntegrationInstaller.posixSingleQuoted(helper.path)
                + " internal hook claude " + ClaudeQuestionRuntime.installedHookEvent
            try AgentMessagingContract.require(
                commands.count == 1 && commands[0]["command"] as? String == expected
                    && commands[0]["timeout"] as? Int == 330,
                "Installer did not limit the question hook to the verified runtime entry")
            if scenario == "tamper" {
                pre[ownedIndex]["matcher"] = ".*"
                hooks["PreToolUse"] = pre
                object["hooks"] = hooks
                try JSONSerialization.data(withJSONObject: object).write(to: config)
                let status = try await installer.status(selectedAdapterIDs: ["claude"])
                try AgentMessagingContract.require(
                    status.first?.status == .conflict, "Modified owned Claude hook was overwritten")
                continue
            }
            pre.remove(at: ownedIndex)
            hooks["PreToolUse"] = pre
            object["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: object).write(to: config)
            let fs = try AgentIntegrationFileSystem(
                homeDirectory: home, applicationSupportDirectory: support)
            let store = try AgentIntegrationOwnershipStore(fileSystem: fs)
            guard case .trusted(let records) = try store.load() else {
                throw InstallerContractFailure()
            }
            let legacy = records.filter { $0.operationID != "agent-claude-v1-PreToolUse" }
            let saved = try store.prepareSave(legacy)
            _ = try fs.apply([saved], matching: [saved.preview])
            if scenario == "upgrade" {
                let status = try await installer.status(selectedAdapterIDs: ["claude"])
                try AgentMessagingContract.require(
                    status.first?.status == .updateAvailable,
                    "Legacy Claude did not offer question-hook update")
                let update = try await installer.prepare(
                    action: .install, selectedAdapterIDs: ["claude"])
                try AgentMessagingContract.require(
                    update.adapters.first?.operations.contains { $0.createsBackup } == true,
                    "Claude update did not preview a backup")
                let result = try await installer.apply(planID: update.planID)
                try AgentMessagingContract.require(
                    result.adapters.first?.status == .succeeded, "Claude update failed")
            }
            let remove = try await installer.prepare(
                action: .uninstall, selectedAdapterIDs: ["claude"])
            let removed = try await installer.apply(planID: remove.planID)
            let remaining =
                try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary
            let remainingHooks = remaining?["hooks"] as? [String: Any]
            let foreignHooks = foreign["hooks"] as! [String: Any]
            try AgentMessagingContract.require(
                removed.adapters.first?.status == .succeeded
                    && remaining?["theme"] as? String == "user-choice"
                    && remainingHooks?["PreToolUse"] as? NSArray == foreignHooks["PreToolUse"]
                        as? NSArray
                    && ((remainingHooks?["SessionStart"] as? NSArray)?.count ?? 0) == 0
                    && ((remainingHooks?["SessionEnd"] as? NSArray)?.count ?? 0) == 0,
                "Claude uninstall lost foreign hooks or rejected a legacy owned subset (\(scenario))"
            )
        }
        print(
            "PASS: guarded Claude hook preview/legacy upgrade+uninstall/foreign preservation/tamper protection"
        )
    }
}

private struct InstallerContractFailure: Error {}
