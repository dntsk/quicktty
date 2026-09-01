import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct ApplicationEnvironmentTests {
    @Test
    func detectsCurrentHostedUnitTestProcess() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        #expect(ApplicationEnvironment.isRunningHostedTests)
    }

    @Test
    func effectiveGUIExecutableSearchPathExtendsLaunchServicesPath() {
        let path = ApplicationEnvironment.effectiveGUIExecutableSearchPath(
            environment: [
                "HOME": "/Users/example",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
        )

        #expect(
            path.split(separator: ":").map(String.init)
                == [
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/Users/example/.local/bin",
                ]
        )
    }

    @Test
    func effectiveGUIExecutableSearchPathRejectsInvalidEntriesAndIsBoundedAndDeduplicated() {
        let entries = (0..<200).map { "/tmp/bin\($0)" }
        let path = ApplicationEnvironment.effectiveGUIExecutableSearchPath(
            environment: [
                "HOME": "relative/home",
                "PATH": (["relative", "", "/tmp/bin0"] + entries).joined(separator: ":"),
            ]
        )
        let effectiveEntries = path.split(separator: ":").map(String.init)

        #expect(!effectiveEntries.contains("relative"))
        #expect(effectiveEntries.count <= 128)
        #expect(Set(effectiveEntries).count == effectiveEntries.count)
        #expect(path.utf8.count <= 16_384)
        #expect(Array(effectiveEntries.suffix(2)) == ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test
    func executableAvailabilityRejectsUnsafeSearchPathInput() throws {
        let fixture = try ExecutableAvailabilityFixture()
        defer { fixture.remove() }
        let executableDirectory = try fixture.makeExecutableDirectory(named: "bin")
        let controlDirectory = try fixture.makeExecutableDirectory(named: "control\nbin")

        #expect(
            ApplicationEnvironment.isExecutableAvailable(
                "pi",
                searchPath: executableDirectory.path
            )
        )

        let relativeDirectory = fixture.relativePathFromCurrentDirectory(to: executableDirectory)
        #expect(
            !ApplicationEnvironment.isExecutableAvailable("pi", searchPath: relativeDirectory)
        )
        #expect(
            !ApplicationEnvironment.isExecutableAvailable(
                "pi",
                searchPath: controlDirectory.path
            )
        )

        let oversizedEntry = executableDirectory.path + String(repeating: "/.", count: 512)
        #expect(oversizedEntry.utf8.count > 1_024)
        #expect(
            !ApplicationEnvironment.isExecutableAvailable("pi", searchPath: oversizedEntry)
        )

        let oversizedSearchPath =
            executableDirectory.path + String(repeating: ":/missing", count: 2_048)
        #expect(oversizedSearchPath.utf8.count > 16_384)
        #expect(
            !ApplicationEnvironment.isExecutableAvailable(
                "pi",
                searchPath: oversizedSearchPath
            )
        )

        let tooManyEntries =
            (Array(repeating: "/missing", count: 128) + [executableDirectory.path])
            .joined(separator: ":")
        #expect(
            !ApplicationEnvironment.isExecutableAvailable("pi", searchPath: tooManyEntries)
        )
    }

    @Test
    func executableAvailabilityRequiresRegularFileAndFollowsSymlink() throws {
        let fixture = try ExecutableAvailabilityFixture()
        defer { fixture.remove() }
        let searchDirectory = fixture.rootURL.appending(
            path: "bin",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: searchDirectory,
            withIntermediateDirectories: true
        )
        let targetURL = fixture.rootURL.appending(path: "target")
        try fixture.makeExecutable(at: targetURL)
        let candidateURL = searchDirectory.appending(path: "pi")
        try FileManager.default.createSymbolicLink(
            at: candidateURL,
            withDestinationURL: targetURL
        )

        #expect(
            ApplicationEnvironment.isExecutableAvailable(
                "pi",
                searchPath: searchDirectory.path
            )
        )

        try FileManager.default.removeItem(at: candidateURL)
        try FileManager.default.createDirectory(
            at: candidateURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: candidateURL.path
        )

        #expect(
            !ApplicationEnvironment.isExecutableAvailable(
                "pi",
                searchPath: searchDirectory.path
            )
        )
    }

    @Test
    func hostedApplicationBundleContainsCLIHelper() throws {
        let helperURL = ApplicationEnvironment.bundledAgentHelperURL()

        #expect(helperURL.path.hasSuffix("/QuickTTY.app/Contents/Helpers/quicktty"))
        #expect(FileManager.default.isExecutableFile(atPath: helperURL.path))
    }

    @Test
    func hostedApplicationBundleContainsAgentIntegrationResources() throws {
        let resourceURL = try #require(Bundle.main.resourceURL)
        let integrationURL = resourceURL.appending(
            path: "AgentIntegrations",
            directoryHint: .isDirectory
        )
        let helperURL = integrationURL.appending(path: "quicktty-progress")
        let exampleNames = ["claude-settings.example.json", "codex-hooks.example.json"]

        #expect(FileManager.default.isExecutableFile(atPath: helperURL.path))
        for name in exampleNames {
            let data = try Data(contentsOf: integrationURL.appending(path: name))
            #expect((try JSONSerialization.jsonObject(with: data)) is [String: Any])
        }
    }
}

private struct ExecutableAvailabilityFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-ExecutableAvailability-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func relativePathFromCurrentDirectory(to url: URL) -> String {
        let ascent = Array(
            repeating: "..",
            count: FileManager.default.currentDirectoryPath.split(separator: "/").count
        )
        let destination = url.path.split(separator: "/").map(String.init)
        return (ascent + destination).joined(separator: "/")
    }

    func makeExecutableDirectory(named name: String) throws -> URL {
        let directoryURL = rootURL.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try makeExecutable(at: directoryURL.appending(path: "pi"))
        return directoryURL
    }

    func makeExecutable(at url: URL) throws {
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
