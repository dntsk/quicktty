import Foundation
import Testing

@testable import QuickTTY

struct AgentIntegrationInstallerTests {
    @Test
    func statusAndEmptySelectionUseExactRegistryOrder() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: false)

        let statuses = try await installer.status()

        #expect(statuses.map(\.adapterID) == AgentIntegrationInstaller.adapterIDs)
        #expect(statuses.count == 20)
        #expect(statuses.filter { $0.capability == .blocked }.count == 6)
        #expect(statuses.filter { $0.status == .blocked }.count == 6)
        #expect(statuses.filter { $0.status == .missing }.count == 14)
        #expect(statuses.allSatisfy { $0.operations.isEmpty })
    }

    @Test
    func prepareExposesOnlyBoundedRelativePreviewAndPlanIsOneTime() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: true)

        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )
        let adapter = try #require(prepared.adapters.first)
        let operation = try #require(adapter.operations.first)
        #expect(prepared.planID.utf8.count == 72)
        #expect(operation.displayPath.hasPrefix("~/"))
        #expect(!operation.displayPath.contains(environment.home.path))
        #expect(operation.displayPath.utf8.count <= 512)
        #expect(operation.operation == .create)
        #expect(operation.mode == .configuration)
        #expect(
            adapter.operations.contains {
                $0.kind == .ownershipManifest
                    && $0.displayPath
                        == "Application Support/QuickTTY/agent-integration-ownership.json"
            }
        )

        let applied = try await installer.apply(planID: prepared.planID)
        #expect(applied.adapters.map(\.status) == [.succeeded])
        await #expect(throws: AgentIntegrationInstallerRequestError.invalidPlan) {
            try await installer.apply(planID: prepared.planID)
        }
    }

    @Test
    func piInstallAndUninstallPreservePinnedExtensionsDirectorySymlink() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let agentDirectory = environment.home.appending(
            path: ".pi/agent",
            directoryHint: .isDirectory
        )
        let sharedExtensions = environment.home.appending(
            path: "shared-extensions",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: agentDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sharedExtensions,
            withIntermediateDirectories: false
        )
        let extensionsLink = agentDirectory.appending(
            path: "extensions",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: extensionsLink,
            withDestinationURL: sharedExtensions
        )
        let installer = try makeInstaller(environment: environment, available: true)

        let install = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )
        let installed = try await installer.apply(planID: install.planID)

        #expect(installed.adapters.map(\.status) == [.succeeded])
        #expect(
            FileManager.default.fileExists(
                atPath: sharedExtensions.appending(path: "quicktty-session/index.ts").path
            )
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: extensionsLink.path)
                == sharedExtensions.path
        )

        let uninstall = try await installer.prepare(
            action: .uninstall,
            selectedAdapterIDs: ["pi"]
        )
        let removed = try await installer.apply(planID: uninstall.planID)

        #expect(removed.adapters.map(\.status) == [.succeeded])
        #expect(
            !FileManager.default.fileExists(
                atPath: sharedExtensions.appending(path: "quicktty-session/index.ts").path
            )
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: extensionsLink.path)
                == sharedExtensions.path
        )
    }

    @Test
    func changedAfterPreviewConflictsWithoutWritingManifest() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: true)
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )
        let path = try AgentIntegrationPath(
            root: .home,
            relativePath: ".pi/agent/extensions/quicktty-session/index.ts"
        )
        try environment.writeFixture(Data("user-owned".utf8), to: path)

        let result = try await installer.apply(planID: prepared.planID)

        #expect(result.adapters.map(\.status) == [.conflict])
        #expect(try environment.fileSystem.read(path) == Data("user-owned".utf8))
        #expect(
            try environment.fileSystem.read(
                AgentIntegrationPath(
                    root: .applicationSupport,
                    relativePath: "QuickTTY/agent-integration-ownership.json"
                )) == nil
        )
    }

    @Test
    func currentPiOwnershipWithBeforeHashConflictsWithoutMutation() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: true)
        let install = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )
        let installed = try await installer.apply(planID: install.planID)
        try #require(installed.adapters.map(\.status) == [.succeeded])
        let path = try AgentIntegrationPath(
            root: .home,
            relativePath: ".pi/agent/extensions/quicktty-session/index.ts"
        )
        let contents = try #require(try environment.fileSystem.read(path))
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        guard case .trusted(let records) = try store.load() else {
            Issue.record("Expected trusted Pi ownership")
            return
        }
        let record = try #require(records.first { $0.operationID == "agent-pi-v1" })
        let wrongRecord = AgentIntegrationOwnershipRecord(
            path: record.path,
            operationID: record.operationID,
            kind: record.kind,
            markerVersion: record.markerVersion,
            jsonPointer: record.jsonPointer,
            beforeHash: record.ownedHash,
            ownedHash: record.ownedHash
        )
        let manifestWrite = try store.prepareSave([wrongRecord])
        _ = try environment.fileSystem.apply(
            [manifestWrite],
            matching: [manifestWrite.preview]
        )
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        let manifestContents = try #require(try environment.fileSystem.read(manifestPath))

        let statuses = try await installer.status(selectedAdapterIDs: ["pi"])
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )

        #expect(statuses.map(\.status) == [.conflict])
        #expect(prepared.adapters.map(\.status) == [.conflict])
        #expect(prepared.adapters.allSatisfy { $0.operations.isEmpty })
        #expect(try environment.fileSystem.read(path) == contents)
        #expect(try environment.fileSystem.read(manifestPath) == manifestContents)
    }

    @Test
    func postWriteCorruptionFailsProductionVerificationAndRollsBack() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installedPath = try AgentIntegrationPath(
            root: .home,
            relativePath: ".pi/agent/extensions/quicktty-session/index.ts"
        )
        let destination = environment.url(for: installedPath)
        let installer = try makeInstaller(
            environment: environment,
            available: true,
            postWriteHook: { path in
                guard path == installedPath else { return }
                try Data("corrupted-after-write".utf8).write(to: destination)
            }
        )
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )

        let result = try await installer.apply(planID: prepared.planID)

        #expect(result.adapters.map(\.status) == [.failed])
        #expect(try environment.fileSystem.read(installedPath) == nil)
        #expect(
            try environment.fileSystem.read(
                AgentIntegrationPath(
                    root: .applicationSupport,
                    relativePath: "QuickTTY/agent-integration-ownership.json"
                )) == nil
        )
    }

    @Test
    func expandedClaudeOwnershipSubsetPreparesAndAppliesSafeUpdate() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let oldState = try await installOldClaudeState(environment: environment)
        let installer = try makeInstaller(environment: environment, available: true)

        let statuses = try await installer.status(selectedAdapterIDs: ["claude"])

        #expect(statuses.map(\.status) == [.updateAvailable])
        #expect(statuses.allSatisfy { $0.operations.isEmpty })

        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["claude"]
        )
        let adapter = try #require(prepared.adapters.first)
        #expect(adapter.status == .updateAvailable)
        #expect(
            adapter.operations.map(\.displayPath) == [
                "~/.claude/settings.json",
                "Application Support/QuickTTY/agent-integration-ownership.json",
            ]
        )
        #expect(adapter.operations.map(\.kind) == [.jsonHook, .ownershipManifest])
        #expect(adapter.operations.map(\.operation) == [.update, .update])
        #expect(adapter.operations.allSatisfy { $0.createsBackup })

        let applied = try await installer.apply(planID: prepared.planID)

        #expect(applied.adapters.map(\.status) == [.succeeded])
        let finalStatuses = try await installer.status(selectedAdapterIDs: ["claude"])
        #expect(finalStatuses.map(\.status) == [.installed])
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        guard case .trusted(let finalRecords) = try store.load() else {
            Issue.record("Expected trusted Claude ownership")
            return
        }
        #expect(
            Set(finalRecords.map(\.operationID)) == [
                "agent-claude-v1-SessionStart",
                "agent-claude-v1-SessionEnd",
            ]
        )
        #expect(finalRecords.allSatisfy { $0.beforeHash == nil })

        let uninstall = try await installer.prepare(
            action: .uninstall,
            selectedAdapterIDs: ["claude"]
        )
        let uninstalled = try await installer.apply(planID: uninstall.planID)

        #expect(uninstalled.adapters.map(\.status) == [.succeeded])
        #expect(try environment.fileSystem.read(oldState.path) == nil)
        guard case .trusted(let remainingRecords) = try store.load() else {
            Issue.record("Expected trusted ownership after Claude uninstall")
            return
        }
        #expect(
            remainingRecords.allSatisfy {
                !Set([
                    "agent-claude-v1-SessionStart",
                    "agent-claude-v1-SessionEnd",
                ]).contains($0.operationID)
            }
        )
    }

    @Test
    func expandedClaudeOwnershipSubsetConflictsWithForeignSessionEndObject() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let oldState = try await installOldClaudeState(
            environment: environment,
            useForeignSessionEndObject: true
        )
        let installer = try makeInstaller(environment: environment, available: true)

        let statuses = try await installer.status(selectedAdapterIDs: ["claude"])

        #expect(statuses.map(\.status) == [.conflict])
        #expect(statuses.allSatisfy { $0.operations.isEmpty })
        #expect(try environment.fileSystem.read(oldState.path) == oldState.contents)

        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["claude"]
        )
        #expect(prepared.adapters.map(\.status) == [.conflict])
        #expect(prepared.adapters.allSatisfy { $0.operations.isEmpty })
        #expect(try environment.fileSystem.read(oldState.path) == oldState.contents)

        let applied = try await installer.apply(planID: prepared.planID)

        #expect(applied.adapters.map(\.status) == [.conflict])
        #expect(applied.adapters.allSatisfy { $0.operations.isEmpty })
        #expect(try environment.fileSystem.read(oldState.path) == oldState.contents)
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        guard case .trusted(let finalRecords) = try store.load() else {
            Issue.record("Expected trusted old Claude ownership")
            return
        }
        #expect(finalRecords.map(\.operationID) == ["agent-claude-v1-SessionStart"])
    }

    @Test
    func currentClaudeOwnershipWithWrongMetadataConflictsWithoutMutation() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let settingsPath = try AgentIntegrationPath(
            root: .home,
            relativePath: ".claude/settings.json"
        )
        let settingsContents = Data("{}".utf8)
        try environment.writeFixture(settingsContents, to: settingsPath)
        let wrongRecord = AgentIntegrationOwnershipRecord(
            path: settingsPath,
            operationID: "agent-claude-v1-SessionStart",
            kind: .jsonHook,
            jsonPointer: "/hooks/SessionEnd",
            beforeHash: AgentIntegrationHash.digest(settingsContents),
            ownedHash: AgentIntegrationHash.digest(Data("owned-hook".utf8))
        )
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        let manifestWrite = try store.prepareSave([wrongRecord])
        _ = try environment.fileSystem.apply(
            [manifestWrite],
            matching: [manifestWrite.preview]
        )
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        let manifestContents = try #require(try environment.fileSystem.read(manifestPath))
        let installer = try makeInstaller(environment: environment, available: true)

        let statuses = try await installer.status(selectedAdapterIDs: ["claude"])

        #expect(statuses.map(\.status) == [.conflict])
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["claude"]
        )
        #expect(prepared.adapters.map(\.status) == [.conflict])

        let applied = try await installer.apply(planID: prepared.planID)

        #expect(applied.adapters.map(\.status) == [.conflict])
        let finalSettingsContents = try #require(try environment.fileSystem.read(settingsPath))
        #expect(finalSettingsContents == settingsContents)
        #expect(try environment.fileSystem.read(manifestPath) == manifestContents)
        let finalSettings = try #require(
            JSONSerialization.jsonObject(with: finalSettingsContents) as? [String: Any]
        )
        #expect((finalSettings["hooks"] as? [String: Any])?["SessionEnd"] == nil)
        guard case .trusted(let finalRecords) = try store.load() else {
            Issue.record("Expected trusted mismatched Claude ownership")
            return
        }
        #expect(finalRecords == [wrongRecord])
    }

    @Test
    func blockedAndMissingAdaptersAreSkippedWithoutMutation() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: false)
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["claude", "grok"]
        )

        let result = try await installer.apply(planID: prepared.planID)

        #expect(result.adapters.map(\.status) == [.skipped, .skipped])
        #expect(try environment.homeEntries().isEmpty)
    }

    @Test
    func unknownSelectionIsUsageErrorAndInvalidatesPendingPlan() async throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let installer = try makeInstaller(environment: environment, available: true)
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["pi"]
        )

        await #expect(throws: AgentIntegrationInstallerRequestError.unknownAdapter) {
            try await installer.prepare(
                action: .install,
                selectedAdapterIDs: ["unknown"]
            )
        }
        await #expect(throws: AgentIntegrationInstallerRequestError.invalidPlan) {
            try await installer.apply(planID: prepared.planID)
        }
    }

    private func installOldClaudeState(
        environment: InstallerTestEnvironment,
        useForeignSessionEndObject: Bool = false
    ) async throws -> (path: AgentIntegrationPath, contents: Data) {
        try FileManager.default.createDirectory(
            at: environment.home.appending(path: ".claude", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let installer = try makeInstaller(environment: environment, available: true)
        let prepared = try await installer.prepare(
            action: .install,
            selectedAdapterIDs: ["claude"]
        )
        let applied = try await installer.apply(planID: prepared.planID)
        try #require(applied.adapters.map(\.status) == [.succeeded])

        let path = try AgentIntegrationPath(
            root: .home,
            relativePath: ".claude/settings.json"
        )
        let current = try #require(try environment.fileSystem.read(path))
        var root = try #require(
            JSONSerialization.jsonObject(with: current) as? [String: Any]
        )
        var hooks = try #require(root["hooks"] as? [String: Any])
        try #require(hooks["SessionStart"] != nil)
        try #require(hooks["SessionEnd"] != nil)
        if useForeignSessionEndObject {
            hooks["SessionEnd"] = ["foreign": "preserve"]
        } else {
            hooks.removeValue(forKey: "SessionEnd")
        }
        root["hooks"] = hooks
        let oldContents = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try environment.writeFixture(oldContents, to: path)

        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        guard case .trusted(let records) = try store.load() else {
            throw AgentIntegrationInstallerError.corruptManifest
        }
        let startRecord = try #require(
            records.first { $0.operationID == "agent-claude-v1-SessionStart" }
        )
        let manifestWrite = try store.prepareSave([startRecord])
        _ = try environment.fileSystem.apply(
            [manifestWrite],
            matching: [manifestWrite.preview]
        )
        return (path, oldContents)
    }

    private func makeInstaller(
        environment: InstallerTestEnvironment,
        available: Bool,
        postWriteHook: (@Sendable (AgentIntegrationPath) throws -> Void)? = nil
    ) throws -> AgentIntegrationInstaller {
        try AgentIntegrationInstaller(
            homeDirectory: environment.home,
            applicationSupportDirectory: environment.applicationSupport,
            resourceRoot: try builtResourceRoot(),
            helperExecutable: URL(
                fileURLWithPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty"),
            executableAvailable: { _ in available },
            postWriteHook: postWriteHook
        )
    }

    private func builtResourceRoot() throws -> URL {
        var directory = Bundle(for: AgentIntegrationInstallerTestsBundleToken.self).bundleURL
            .deletingLastPathComponent()
        var builtApplication: URL?
        while directory.path != "/" {
            let candidate =
                directory.lastPathComponent == "QuickTTY.app"
                ? directory
                : directory.appending(path: "QuickTTY.app", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                builtApplication = candidate
                break
            }
            directory.deleteLastPathComponent()
        }

        let application = try #require(builtApplication)
        let resourceRoot = application.appending(
            path: "Contents/Resources/AgentSessionIntegrations",
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false
        try #require(
            FileManager.default.fileExists(atPath: resourceRoot.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        )
        return resourceRoot
    }
}

private final class AgentIntegrationInstallerTestsBundleToken {}
