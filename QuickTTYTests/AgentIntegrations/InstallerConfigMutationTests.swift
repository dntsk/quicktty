import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct InstallerConfigMutationTests {
    @Test
    func ownedFileSupportsFreshIdempotentUpdateConflictAndUninstall() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(
            root: .home, relativePath: ".config/tool/plugins/quicktty.js"
        )
        let initial = try OwnedFileMutation(
            path: path, operationID: "tool-plugin", contents: Data("version-one".utf8)
        )
        let install = try initial.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
        let installResult = try apply(install, using: environment.fileSystem)
        #expect(installResult.backupPaths.isEmpty)
        let initialRecord = try #require(install.ownershipRecord)

        let idempotent = try initial.prepareInstall(
            fileSystem: environment.fileSystem, ownership: [initialRecord]
        )
        #expect(try apply(idempotent, using: environment.fileSystem).changedPaths.isEmpty)

        let updated = try OwnedFileMutation(
            path: path, operationID: "tool-plugin", contents: Data("version-two".utf8)
        )
        let update = try updated.prepareInstall(
            fileSystem: environment.fileSystem, ownership: [initialRecord]
        )
        #expect(try apply(update, using: environment.fileSystem).backupPaths.count == 1)
        let updatedRecord = try #require(update.ownershipRecord)
        try environment.writeFixture(Data("user-edit".utf8), to: path)
        do {
            _ = try updated.prepareInstall(
                fileSystem: environment.fileSystem, ownership: [updatedRecord]
            )
            Issue.record("Expected owned update conflict")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .ownershipMismatch)
        }
        #expect(try environment.fileSystem.read(path) == Data("user-edit".utf8))

        try environment.writeFixture(Data("version-two".utf8), to: path)
        let uninstall = try updated.prepareUninstall(
            fileSystem: environment.fileSystem, record: updatedRecord
        )
        _ = try apply(uninstall, using: environment.fileSystem)
        #expect(try environment.fileSystem.read(path) == nil)
    }

    @Test
    func ownedFileNeverClaimsAUserFileEvenWhenBytesMatch() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "plugin.js")
        try environment.writeFixture(Data("same".utf8), to: path)
        let mutation = try OwnedFileMutation(
            path: path, operationID: "plugin", contents: Data("same".utf8)
        )
        do {
            _ = try mutation.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
            Issue.record("Expected user-file conflict")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .ownershipMismatch)
        }
    }

    @Test
    func jsonMergePreservesUnknownSemanticsAndRemovesOnlyOwnedNode() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/hooks.json")
        let original = Data(
            "{\"unknown\":{\"token\":\"FIXTURE_SECRET_DO_NOT_LEAK_11\",\"enabled\":true},\"hooks\":{\"start\":[{\"command\":\"quicktty-hook --user-suffix\",\"kind\":\"user\"}]}}"
                .utf8
        )
        try environment.writeFixture(original, to: path)
        let node = Data("{\"command\":\"quicktty-hook\",\"kind\":\"owned\"}".utf8)
        let mutation = try JSONHookMutation(
            path: path, jsonPointer: "/hooks/start", operationID: "tool-hook", commandNode: node
        )
        let install = try mutation.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
        _ = try apply(install, using: environment.fileSystem)
        let record = try #require(install.ownershipRecord)
        let installed = try jsonObject(try #require(try environment.fileSystem.read(path)))
        let unknown = try #require(installed["unknown"] as? [String: Any])
        #expect(unknown["enabled"] as? Bool == true)
        #expect(unknown["token"] as? String == "FIXTURE_SECRET_DO_NOT_LEAK_11")
        let hooks = try #require(installed["hooks"] as? [String: Any])
        #expect((hooks["start"] as? [Any])?.count == 2)

        let idempotent = try mutation.prepareInstall(
            fileSystem: environment.fileSystem, ownership: [record]
        )
        #expect(try apply(idempotent, using: environment.fileSystem).changedPaths.isEmpty)

        let uninstall = try mutation.prepareUninstall(
            fileSystem: environment.fileSystem, record: record
        )
        _ = try apply(uninstall, using: environment.fileSystem)
        let uninstalled = try jsonObject(try #require(try environment.fileSystem.read(path)))
        let remainingHooks = try #require(uninstalled["hooks"] as? [String: Any])
        let remaining = try #require(remainingHooks["start"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect(remaining[0]["command"] as? String == "quicktty-hook --user-suffix")
        #expect(
            (uninstalled["unknown"] as? [String: Any])?["token"] as? String
                == "FIXTURE_SECRET_DO_NOT_LEAK_11")
    }

    @Test
    func jsonRejectsDuplicateKeysEscapedDuplicatesAndNonObjectRoots() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "hooks.json")
        let mutation = try JSONHookMutation(
            path: path,
            jsonPointer: "/hooks/start",
            operationID: "hook",
            commandNode: Data("{\"command\":\"owned\"}".utf8)
        )
        for invalid in [
            "{\"hooks\":{},\"hooks\":{}}",
            "{\"a\":1,\"\\u0061\":2}",
            "[1,2,3]",
        ] {
            try environment.writeFixture(Data(invalid.utf8), to: path)
            do {
                _ = try mutation.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
                Issue.record("Expected strict JSON rejection")
            } catch let error as AgentIntegrationInstallerError {
                #expect(
                    error == .duplicateJSONKey || error == .nonObjectJSONRoot
                        || error == .malformedJSON
                )
            }
        }
    }

    @Test
    func markerBlockPreservesCRLFFinalNewlineAndUserBytesOnUninstall() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/config.toml")
        let original = Data("title = \"preserve\"\r\n[user]\r\nenabled = true\r\n".utf8)
        try environment.writeFixture(original, to: path)
        let mutation = try MarkerBlockMutation(
            path: path,
            operationID: "tool-hook",
            markerVersion: 1,
            body: Data("hook = true".utf8)
        )
        let install = try mutation.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
        _ = try apply(install, using: environment.fileSystem)
        let record = try #require(install.ownershipRecord)
        let installed = try #require(try environment.fileSystem.read(path))
        #expect(installed.starts(with: original))
        #expect(String(decoding: installed, as: UTF8.self).contains("\r\n# >>> QuickTTY:"))
        #expect(installed.last == 0x0a)

        let idempotent = try mutation.prepareInstall(
            fileSystem: environment.fileSystem, ownership: [record]
        )
        #expect(try apply(idempotent, using: environment.fileSystem).changedPaths.isEmpty)
        let uninstall = try mutation.prepareUninstall(
            fileSystem: environment.fileSystem, record: record
        )
        _ = try apply(uninstall, using: environment.fileSystem)
        #expect(try environment.fileSystem.read(path) == original)
    }

    @Test
    func markerUpdateUsesNewlineInsideOwnedBlock() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/config.toml")
        let existingBlock = Data(
            "# >>> QuickTTY:tool-hook:v1 >>>\nhook = false\n# <<< QuickTTY:tool-hook:v1 <<<\n".utf8
        )
        var source = Data("title = \"preserve\"\r\n".utf8)
        source.append(existingBlock)
        try environment.writeFixture(source, to: path)
        let record = AgentIntegrationOwnershipRecord(
            path: path,
            operationID: "tool-hook",
            kind: .markerBlock,
            markerVersion: 1,
            beforeHash: nil,
            ownedHash: AgentIntegrationHash.digest(existingBlock)
        )
        let mutation = try MarkerBlockMutation(
            path: path,
            operationID: "tool-hook",
            markerVersion: 1,
            body: Data("hook = true".utf8)
        )

        let update = try mutation.prepareInstall(
            fileSystem: environment.fileSystem, ownership: [record])
        _ = try apply(update, using: environment.fileSystem)

        let expected = Data(
            "title = \"preserve\"\r\n# >>> QuickTTY:tool-hook:v1 >>>\nhook = true\n# <<< QuickTTY:tool-hook:v1 <<<\n"
                .utf8
        )
        #expect(try environment.fileSystem.read(path) == expected)
    }

    @Test
    func markerTreatsLoneTrailingCRAsContentAcrossRepeatedInstallCycles() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/config.toml")
        let original = Data("title = \"preserve\"\r".utf8)
        try environment.writeFixture(original, to: path)
        let mutation = try MarkerBlockMutation(
            path: path,
            operationID: "tool-hook",
            markerVersion: 1,
            body: Data("hook = true".utf8)
        )

        for _ in 0..<2 {
            let install = try mutation.prepareInstall(
                fileSystem: environment.fileSystem, ownership: [])
            _ = try apply(install, using: environment.fileSystem)
            let record = try #require(install.ownershipRecord)
            let installed = try #require(try environment.fileSystem.read(path))
            #expect(installed.starts(with: Data("title = \"preserve\"\r\n# >>>".utf8)))

            let idempotent = try mutation.prepareInstall(
                fileSystem: environment.fileSystem, ownership: [record])
            #expect(try apply(idempotent, using: environment.fileSystem).changedPaths.isEmpty)

            let uninstall = try mutation.prepareUninstall(
                fileSystem: environment.fileSystem, record: record)
            _ = try apply(uninstall, using: environment.fileSystem)
            #expect(try environment.fileSystem.read(path) == original)
        }
    }

    @Test
    func markerRejectsNestedDuplicateUnbalancedAndConflictingMarkersWithoutLeaks() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "config.yaml")
        let mutation = try MarkerBlockMutation(
            path: path,
            operationID: "owned-hook",
            markerVersion: 1,
            body: Data("command: FIXTURE_SECRET_DO_NOT_LEAK_11".utf8)
        )
        let fixtures = [
            "# >>> QuickTTY:owned-hook:v1 >>>\n# >>> QuickTTY:owned-hook:v1 >>>\n",
            "# <<< QuickTTY:owned-hook:v1 <<<\n",
            "# >>> QuickTTY:foreign:v1 >>>\nvalue\n# <<< QuickTTY:foreign:v1 <<<\n",
        ]
        for fixture in fixtures {
            try environment.writeFixture(Data(fixture.utf8), to: path)
            do {
                _ = try mutation.prepareInstall(fileSystem: environment.fileSystem, ownership: [])
                Issue.record("Expected marker conflict")
            } catch {
                let diagnostic = String(describing: error)
                #expect(!diagnostic.contains("FIXTURE_SECRET_DO_NOT_LEAK_11"))
                #expect(!diagnostic.contains(environment.home.path))
                #expect(diagnostic.utf8.count < 128)
            }
        }
    }

    private func apply(
        _ plan: AgentIntegrationMutationPlan,
        using fileSystem: AgentIntegrationFileSystem
    ) throws -> AgentIntegrationApplyResult {
        try fileSystem.apply([plan.write], matching: [plan.write.preview])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
