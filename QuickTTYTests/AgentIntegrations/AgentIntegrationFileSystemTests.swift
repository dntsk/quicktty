import Darwin
import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct AgentIntegrationFileSystemTests {
    @Test
    func absentFreshAndIdempotentApplyAreSafe() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/plugin.js")

        #expect(try environment.fileSystem.read(path) == nil)
        let prepared = try environment.fileSystem.prepareWrite(
            path: path,
            data: Data("owned".utf8),
            kind: .ownedFile,
            createParentDirectories: true
        )
        let first = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
        #expect(first.changedPaths == [path])
        #expect(first.backupPaths.isEmpty)
        #expect(try environment.fileSystem.read(path) == Data("owned".utf8))
        #expect(try environment.permissions(of: path) == 0o600)

        let modificationDate = try environment.modificationDate(of: path)
        let secondPrepared = try environment.fileSystem.prepareWrite(
            path: path,
            data: Data("owned".utf8),
            kind: .ownedFile
        )
        let second = try environment.fileSystem.apply(
            [secondPrepared], matching: [secondPrepared.preview]
        )
        #expect(second.changedPaths.isEmpty)
        #expect(second.backupPaths.isEmpty)
        #expect(try environment.modificationDate(of: path) == modificationDate)
    }

    @Test
    func changedAfterPreviewRefusesBeforeAnyWriteOrBackup() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "config.json")
        try environment.writeFixture(Data("first".utf8), to: path)
        let prepared = try environment.fileSystem.prepareWrite(
            path: path, data: Data("planned".utf8), kind: .jsonHook
        )
        try environment.writeFixture(Data("changed".utf8), to: path)

        do {
            _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
            Issue.record("Expected changed-after-preview rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .changedAfterPreview)
        }
        #expect(try environment.fileSystem.read(path) == Data("changed".utf8))
        #expect(try environment.homeEntries().allSatisfy { !$0.contains("quicktty-backup") })
    }

    @Test
    func swapCASRejectsConcurrentReplacementAndPreservesItsBytes() throws {
        let environment = try InstallerTestEnvironment(
            beforeSwapReplacement: Data("concurrent".utf8))
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "config.json")
        try environment.writeFixture(Data("original".utf8), to: path)
        let prepared = try environment.fileSystem.prepareWrite(
            path: path, data: Data("planned".utf8), kind: .jsonHook
        )

        do {
            _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
            Issue.record("Expected changed-after-preview rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .changedAfterPreview)
        }
        #expect(try environment.fileSystem.read(path) == Data("concurrent".utf8))
        #expect(try environment.homeEntries().allSatisfy { !$0.contains("quicktty-") })
    }

    @Test
    func absentCASPreservesFileCreatedImmediatelyBeforeExclusiveRename() throws {
        let environment = try InstallerTestEnvironment(
            beforeSwapReplacement: Data("concurrent".utf8))
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "new-config.json")
        let prepared = try environment.fileSystem.prepareWrite(
            path: path, data: Data("planned".utf8), kind: .jsonHook
        )

        do {
            _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
            Issue.record("Expected changed-after-preview rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .changedAfterPreview)
        }
        #expect(try environment.fileSystem.read(path) == Data("concurrent".utf8))
    }

    @Test
    func verificationFailureRollsBackBoundedTransaction() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let firstPath = try AgentIntegrationPath(root: .home, relativePath: "first.json")
        let secondPath = try AgentIntegrationPath(root: .home, relativePath: "second.json")
        try environment.writeFixture(Data("first-original".utf8), to: firstPath)
        try environment.writeFixture(Data("second-original".utf8), to: secondPath)
        let first = try environment.fileSystem.prepareWrite(
            path: firstPath, data: Data("first-new".utf8), kind: .jsonHook
        )
        let second = try environment.fileSystem.prepareWrite(
            path: secondPath, data: Data("second-new".utf8), kind: .jsonHook
        )

        do {
            _ = try environment.fileSystem.apply(
                [first, second],
                matching: [first.preview, second.preview],
                verification: { $0 == 0 }
            )
            Issue.record("Expected verification failure")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .verificationFailed)
        }
        #expect(try environment.fileSystem.read(firstPath) == Data("first-original".utf8))
        #expect(try environment.fileSystem.read(secondPath) == Data("second-original".utf8))
    }

    @Test
    func rollbackCollisionReportsFailureAndPreservesConcurrentBytes() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let path = try AgentIntegrationPath(root: .home, relativePath: "config.json")
        try environment.writeFixture(Data("original".utf8), to: path)
        let prepared = try environment.fileSystem.prepareWrite(
            path: path, data: Data("planned".utf8), kind: .jsonHook
        )
        let destination = environment.url(for: path)

        do {
            _ = try environment.fileSystem.apply(
                [prepared],
                matching: [prepared.preview],
                verification: { _ in
                    try Data("concurrent".utf8).write(to: destination)
                    return false
                }
            )
            Issue.record("Expected rollback failure")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .rollbackFailed)
        }
        #expect(try environment.fileSystem.read(path) == Data("concurrent".utf8))
    }

    @Test
    func pinsRootTraversalAndRejectsIntermediateRootSymlink() throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "quicktty-root-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let actual = base.appending(path: "actual", directoryHint: .isDirectory)
        let home = actual.appending(path: "home", directoryHint: .isDirectory)
        let support = actual.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let link = base.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        do {
            _ = try AgentIntegrationFileSystem(
                homeDirectory: link.appending(path: "home", directoryHint: .isDirectory),
                applicationSupportDirectory: link.appending(
                    path: "support", directoryHint: .isDirectory)
            )
            Issue.record("Expected intermediate root symlink rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .pathRejected)
        }
    }

    @Test
    func pinnedRootsDoNotFollowReplacedIntermediateDirectory() throws {
        let temporaryDirectoryPath = try #require(
            FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }
        )
        defer { free(temporaryDirectoryPath) }
        let canonicalTemporaryDirectory = URL(
            fileURLWithPath: String(cString: temporaryDirectoryPath), isDirectory: true)
        let base = canonicalTemporaryDirectory.appending(
            path: "quicktty-root-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let roots = base.appending(path: "roots", directoryHint: .isDirectory)
        let home = roots.appending(path: "home", directoryHint: .isDirectory)
        let support = roots.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let fileSystem = try AgentIntegrationFileSystem(
            homeDirectory: home, applicationSupportDirectory: support)

        let pinnedRoots = base.appending(path: "pinned-roots", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: roots, to: pinnedRoots)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = try AgentIntegrationPath(root: .home, relativePath: "config.json")
        let prepared = try fileSystem.prepareWrite(
            path: path, data: Data("pinned".utf8), kind: .jsonHook)
        _ = try fileSystem.apply([prepared], matching: [prepared.preview])

        let pinnedFile = pinnedRoots.appending(path: "home/config.json")
        #expect(try Data(contentsOf: pinnedFile) == Data("pinned".utf8))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "config.json").path))
    }

    @Test
    func allowsPinnedUserOwnedDirectorySymlinkWithinHomeRoot() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let target = environment.home.appending(
            path: "shared-extensions",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: environment.home.appending(path: "linked", directoryHint: .isDirectory),
            withDestinationURL: target
        )
        let path = try AgentIntegrationPath(root: .home, relativePath: "linked/file")
        let prepared = try environment.fileSystem.prepareWrite(
            path: path,
            data: Data("installed".utf8),
            kind: .ownedFile
        )

        _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])

        #expect(
            try Data(contentsOf: target.appending(path: "file")) == Data("installed".utf8)
        )
    }

    @Test
    func rejectsDirectorySymlinkReplacementAfterPreview() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let first = environment.home.appending(path: "first", directoryHint: .isDirectory)
        let second = environment.home.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let link = environment.home.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let path = try AgentIntegrationPath(root: .home, relativePath: "linked/file")
        let prepared = try environment.fileSystem.prepareWrite(
            path: path,
            data: Data("installed".utf8),
            kind: .ownedFile
        )
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        do {
            _ = try environment.fileSystem.apply([prepared], matching: [prepared.preview])
            Issue.record("Expected replaced directory symlink rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .pathRejected)
        }
        #expect(!FileManager.default.fileExists(atPath: first.appending(path: "file").path))
        #expect(!FileManager.default.fileExists(atPath: second.appending(path: "file").path))
    }

    @Test
    func rejectsOutsideSymlinkParentSymlinkTargetAndHardLink() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        let outside = environment.base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: environment.home.appending(path: "linked", directoryHint: .isDirectory),
            withDestinationURL: outside
        )
        let symlinkParent = try AgentIntegrationPath(root: .home, relativePath: "linked/file")
        try expectPathRejected { _ = try environment.fileSystem.read(symlinkParent) }

        let regular = try AgentIntegrationPath(root: .home, relativePath: "regular")
        try environment.writeFixture(Data("value".utf8), to: regular)
        try FileManager.default.createSymbolicLink(
            at: environment.home.appending(path: "target-link"),
            withDestinationURL: environment.home.appending(path: "regular")
        )
        let targetLink = try AgentIntegrationPath(root: .home, relativePath: "target-link")
        try expectPathRejected { _ = try environment.fileSystem.read(targetLink) }

        let hardLinkURL = environment.home.appending(path: "hard-link")
        #expect(Darwin.link(environment.url(for: regular).path, hardLinkURL.path) == 0)
        try expectPathRejected { _ = try environment.fileSystem.read(regular) }
    }

    @Test
    func envPathsAndDiagnosticsNeverExposeSensitiveValuesOrRoots() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }
        do {
            _ = try AgentIntegrationPath(root: .home, relativePath: ".env")
            Issue.record("Expected .env rejection")
        } catch let error as AgentIntegrationInstallerError {
            let diagnostic = String(describing: error)
            #expect(!diagnostic.contains("FIXTURE_SECRET_DO_NOT_LEAK_11"))
            #expect(!diagnostic.contains(environment.home.path))
        }
        do {
            _ = try AgentIntegrationPath(root: .home, relativePath: "nested/.env/value")
            Issue.record("Expected nested .env rejection")
        } catch {
            #expect(String(describing: error).utf8.count < 128)
        }
    }

    private func expectPathRejected(_ operation: () throws -> Void) throws {
        do {
            try operation()
            Issue.record("Expected path rejection")
        } catch let error as AgentIntegrationInstallerError {
            #expect(error == .pathRejected)
        }
    }
}

final class InstallerTestEnvironment {
    let base: URL
    let home: URL
    let applicationSupport: URL
    let fileSystem: AgentIntegrationFileSystem

    init(beforeSwapReplacement: Data? = nil) throws {
        let temporaryDirectoryPath = try #require(
            FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }
        )
        defer { free(temporaryDirectoryPath) }
        let canonicalTemporaryDirectory = URL(
            fileURLWithPath: String(cString: temporaryDirectoryPath), isDirectory: true)
        let baseURL = canonicalTemporaryDirectory.appending(
            path: "quicktty-installer-tests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let homeURL = baseURL.appending(path: "home", directoryHint: .isDirectory)
        let applicationSupportURL = baseURL.appending(
            path: "application-support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: applicationSupportURL, withIntermediateDirectories: true
        )
        let hook: (@Sendable (AgentIntegrationPath) throws -> Void)?
        if let beforeSwapReplacement {
            hook = { path in
                let root = path.root == .home ? homeURL : applicationSupportURL
                let destination = path.components.reduce(root) {
                    $0.appending(path: $1)
                }
                try beforeSwapReplacement.write(to: destination)
            }
        } else {
            hook = nil
        }
        base = baseURL
        home = homeURL
        applicationSupport = applicationSupportURL
        fileSystem = try AgentIntegrationFileSystem(
            homeDirectory: homeURL,
            applicationSupportDirectory: applicationSupportURL,
            beforeSwap: hook
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func url(for path: AgentIntegrationPath) -> URL {
        let root = path.root == .home ? home : applicationSupport
        return path.components.reduce(root) { $0.appending(path: $1) }
    }

    func writeFixture(_ data: Data, to path: AgentIntegrationPath) throws {
        let url = url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func permissions(of path: AgentIntegrationPath) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url(for: path).path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func modificationDate(of path: AgentIntegrationPath) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url(for: path).path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    func homeEntries() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: home.path)
    }
}
