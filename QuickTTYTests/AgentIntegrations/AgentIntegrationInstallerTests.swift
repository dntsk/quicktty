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
