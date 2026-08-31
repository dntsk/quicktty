import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct AgentIntegrationOwnershipStoreTests {
    @Test
    func savesCanonicalUserOnlyManifestWithoutOwnedValues() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        let ownedPath = try AgentIntegrationPath(
            root: .home, relativePath: ".config/tool/plugin.js"
        )
        let record = AgentIntegrationOwnershipRecord(
            path: ownedPath,
            operationID: "tool-plugin-v1",
            kind: .ownedFile,
            beforeHash: nil,
            ownedHash: AgentIntegrationHash.digest(Data("FIXTURE_SECRET_DO_NOT_LEAK_11".utf8))
        )

        let prepared = try store.prepareSave([record])
        _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
        #expect(try store.load() == .trusted([record]))
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        let manifest = try #require(try environment.fileSystem.read(manifestPath))
        #expect(
            !String(decoding: manifest, as: UTF8.self).contains("FIXTURE_SECRET_DO_NOT_LEAK_11"))
        #expect(try environment.permissions(of: manifestPath) == 0o600)
    }

    @Test
    func absentManifestIsTrustedEmptyStateAndSecondSaveIsNoOp() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        #expect(try store.load() == .absent)

        let first = try store.prepareSave([])
        _ = try environment.fileSystem.apply([first], matching: [first.preview])
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        let modificationDate = try environment.modificationDate(of: manifestPath)
        let second = try store.prepareSave([])
        let result = try environment.fileSystem.apply([second], matching: [second.preview])
        #expect(result.changedPaths.isEmpty)
        #expect(result.backupPaths.isEmpty)
        #expect(try environment.modificationDate(of: manifestPath) == modificationDate)
    }

    @Test
    func corruptManifestBlocksDestructiveSaveAndOwnedOverwrite() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        try environment.writeFixture(Data("{\"version\":1,\"version\":2}".utf8), to: manifestPath)
        #expect(try store.load() == .untrusted)

        do {
            _ = try store.prepareSave([])
            Issue.record("Expected corrupt manifest rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .corruptManifest)
        }

        let ownedPath = try AgentIntegrationPath(root: .home, relativePath: "existing-plugin")
        try environment.writeFixture(Data("user-content".utf8), to: ownedPath)
        let record = AgentIntegrationOwnershipRecord(
            path: ownedPath,
            operationID: "plugin-v1",
            kind: .ownedFile,
            beforeHash: nil,
            ownedHash: AgentIntegrationHash.digest(Data("owned".utf8))
        )
        do {
            _ = try store.prepareSave([record], allowingInstallOverUntrustedManifest: true)
            Issue.record("Expected purported ownership overwrite rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .corruptManifest)
        }
        #expect(try environment.fileSystem.read(ownedPath) == Data("user-content".utf8))
    }

    @Test
    func corruptManifestAllowsOnlyInstallWhoseOwnedPathIsAbsent() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        try environment.writeFixture(Data("not-json".utf8), to: manifestPath)
        let absentPath = try AgentIntegrationPath(root: .home, relativePath: "new-plugin")
        let record = AgentIntegrationOwnershipRecord(
            path: absentPath,
            operationID: "plugin-v1",
            kind: .ownedFile,
            beforeHash: nil,
            ownedHash: AgentIntegrationHash.digest(Data("owned".utf8))
        )

        let prepared = try store.prepareSave(
            [record], allowingInstallOverUntrustedManifest: true
        )
        _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
        #expect(try store.load() == .trusted([record]))
    }

    @Test
    func malformedRecordAndDuplicateIdentityMakeManifestUntrusted() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "QuickTTY/agent-integration-ownership.json"
        )
        let invalid = Data(
            "{\"records\":[{\"beforeHash\":null,\"kind\":\"ownedFile\",\"markerVersion\":null,\"operationID\":\"x\",\"ownedHash\":\"bad\",\"path\":{\"components\":[\"file\"],\"root\":\"home\"},\"jsonPointer\":null}],\"version\":1}"
                .utf8
        )
        try environment.writeFixture(invalid, to: manifestPath)
        let store = try AgentIntegrationOwnershipStore(fileSystem: environment.fileSystem)
        #expect(try store.load() == .untrusted)
        #expect(!String(describing: try store.load()).contains(environment.home.path))
    }
}
