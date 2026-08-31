import Foundation
import Testing

@testable import QuickTTY

struct CommandLineLauncherInstallerTests {
    @Test
    func installsExactAbsoluteSymlinkAndIsIdempotent() async throws {
        let fixture = try LauncherFixture()
        defer { fixture.remove() }
        let installer = try fixture.installer()

        let prepared = try await installer.prepare(action: .install)
        #expect(prepared.displayPath == "~/.local/bin/quicktty")
        #expect(prepared.kind == "symlinkCreate")
        #expect(!prepared.createsBackup)
        #expect(try await installer.apply(planID: prepared.planID) == .succeeded)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.launcher.path)
                == fixture.helper.path)
        #expect(try fixture.permissions(at: fixture.home.appending(path: ".local")) == 0o700)
        #expect(
            try fixture.permissions(at: fixture.launcher.deletingLastPathComponent()) == 0o700)

        let second = try await installer.prepare(action: .install)
        #expect(second.status == .noOp)
        #expect(try await installer.apply(planID: second.planID) == .noOp)
    }

    @Test
    func refusesAndPreservesRegularFileDirectoryForeignSymlinkAndHardlink() async throws {
        for conflict in LauncherConflict.allCases {
            let fixture = try LauncherFixture()
            defer { fixture.remove() }
            try fixture.makeConflict(conflict)
            let installer = try fixture.installer()

            let prepared = try await installer.prepare(action: .install)

            #expect(prepared.status == .conflict)
            await #expect(throws: AgentIntegrationInstallerError.conflict) {
                try await installer.apply(planID: prepared.planID)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.launcher.path))
        }
    }

    @Test
    func installAndUninstallPreserveExistingDirectoryModes() async throws {
        let fixture = try LauncherFixture()
        defer { fixture.remove() }
        try fixture.createLauncherDirectory(mode: 0o755)
        let installer = try fixture.installer()

        let install = try await installer.prepare(action: .install)
        #expect(try await installer.apply(planID: install.planID) == .succeeded)
        #expect(try fixture.permissions(at: fixture.home.appending(path: ".local")) == 0o755)
        #expect(
            try fixture.permissions(at: fixture.launcher.deletingLastPathComponent()) == 0o755)

        let uninstall = try await installer.prepare(action: .uninstall)
        #expect(try await installer.apply(planID: uninstall.planID) == .succeeded)
        #expect(try fixture.permissions(at: fixture.home.appending(path: ".local")) == 0o755)
        #expect(
            try fixture.permissions(at: fixture.launcher.deletingLastPathComponent()) == 0o755)
    }

    @Test
    func uninstallRemovesOnlyExactOwnedTargetAndPreviewRaceIsRejected() async throws {
        let fixture = try LauncherFixture()
        defer { fixture.remove() }
        let installer = try fixture.installer()
        let install = try await installer.prepare(action: .install)
        _ = try await installer.apply(planID: install.planID)
        let uninstall = try await installer.prepare(action: .uninstall)
        try FileManager.default.removeItem(at: fixture.launcher)
        try FileManager.default.createSymbolicLink(
            at: fixture.launcher,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/false")
        )

        await #expect(throws: AgentIntegrationInstallerError.changedAfterPreview) {
            try await installer.apply(planID: uninstall.planID)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.launcher.path)
                == "/usr/bin/false")
    }

    @Test
    func uninstallSwapRacePreservesForeignRegularFileAndSymlink() async throws {
        for conflict in [LauncherConflict.regular, .foreignSymlink] {
            let fixture = try LauncherFixture()
            defer { fixture.remove() }
            let launcher = fixture.launcher
            let installer = try fixture.installer(beforeUninstallSwap: {
                try FileManager.default.removeItem(at: launcher)
                switch conflict {
                case .regular:
                    try Data("user".utf8).write(to: launcher)
                case .foreignSymlink:
                    try FileManager.default.createSymbolicLink(
                        at: launcher,
                        withDestinationURL: URL(fileURLWithPath: "/usr/bin/false")
                    )
                case .directory, .hardlink:
                    throw AgentIntegrationInstallerError.ioFailure
                }
            })
            let install = try await installer.prepare(action: .install)
            _ = try await installer.apply(planID: install.planID)
            let uninstall = try await installer.prepare(action: .uninstall)

            await #expect(throws: AgentIntegrationInstallerError.changedAfterPreview) {
                try await installer.apply(planID: uninstall.planID)
            }
            switch conflict {
            case .regular:
                #expect(try Data(contentsOf: fixture.launcher) == Data("user".utf8))
            case .foreignSymlink:
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: fixture.launcher.path) == "/usr/bin/false")
            case .directory, .hardlink:
                Issue.record("Unexpected fixture conflict")
            }
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.launcher.deletingLastPathComponent().path) == ["quicktty"])
        }
    }

    @Test
    func uninstallQuarantineRaceRestoresForeignLauncherAndRejectsConflict() async throws {
        let fixture = try LauncherFixture()
        defer { fixture.remove() }
        let launcher = fixture.launcher
        let installer = try fixture.installer(beforeUninstallQuarantine: {
            try FileManager.default.removeItem(at: launcher)
            try Data("foreign".utf8).write(to: launcher)
        })
        let install = try await installer.prepare(action: .install)
        _ = try await installer.apply(planID: install.planID)
        let uninstall = try await installer.prepare(action: .uninstall)

        await #expect(throws: AgentIntegrationInstallerError.changedAfterPreview) {
            try await installer.apply(planID: uninstall.planID)
        }
        #expect(try Data(contentsOf: launcher) == Data("foreign".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: launcher.deletingLastPathComponent().path) == ["quicktty"])
    }

    @Test
    func uninstallIsIdempotentWhenOwnedLauncherDisappearsBeforeSwap() async throws {
        let fixture = try LauncherFixture()
        defer { fixture.remove() }
        let launcher = fixture.launcher
        let installer = try fixture.installer(beforeUninstallSwap: {
            try FileManager.default.removeItem(at: launcher)
        })
        let install = try await installer.prepare(action: .install)
        _ = try await installer.apply(planID: install.planID)
        let uninstall = try await installer.prepare(action: .uninstall)

        #expect(try await installer.apply(planID: uninstall.planID) == .succeeded)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.launcher.deletingLastPathComponent().path
            ).isEmpty)
    }
}

private enum LauncherConflict: CaseIterable, Sendable {
    case regular
    case directory
    case foreignSymlink
    case hardlink
}

private final class LauncherFixture {
    let base: URL
    let home: URL
    let helper: URL
    let launcher: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(
            path: "quicktty-launcher-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        home = base.appending(path: "home", directoryHint: .isDirectory)
        helper = base.appending(path: "bundled-quicktty")
        launcher = home.appending(path: ".local/bin/quicktty")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    func installer(
        beforeUninstallSwap: (@Sendable () throws -> Void)? = nil,
        beforeUninstallQuarantine: (@Sendable () throws -> Void)? = nil
    ) throws -> CommandLineLauncherInstaller {
        try CommandLineLauncherInstaller(
            homeDirectory: home,
            helperExecutable: helper,
            beforeUninstallSwap: beforeUninstallSwap,
            beforeUninstallQuarantine: beforeUninstallQuarantine
        )
    }

    func createLauncherDirectory(mode: Int) throws {
        let local = home.appending(path: ".local", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: local.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: launcher.deletingLastPathComponent().path
        )
    }

    func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func makeConflict(_ conflict: LauncherConflict) throws {
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeLauncherConflict(conflict)
    }

    func makeLauncherConflict(_ conflict: LauncherConflict) throws {
        switch conflict {
        case .regular:
            try Data("user".utf8).write(to: launcher)
        case .directory:
            try FileManager.default.createDirectory(
                at: launcher, withIntermediateDirectories: false)
        case .foreignSymlink:
            try FileManager.default.createSymbolicLink(
                at: launcher,
                withDestinationURL: URL(fileURLWithPath: "/usr/bin/false")
            )
        case .hardlink:
            try FileManager.default.linkItem(at: helper, to: launcher)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
