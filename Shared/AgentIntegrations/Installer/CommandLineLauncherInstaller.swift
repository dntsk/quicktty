import Darwin
import Foundation

public enum CommandLineLauncherAction: Equatable, Sendable {
    case install
    case uninstall
}

public enum CommandLineLauncherStatus: String, Codable, Equatable, Sendable {
    case available
    case installed
    case noOp
    case conflict
    case succeeded
}

public struct CommandLineLauncherSummary: Codable, Equatable, Sendable {
    public let planID: String
    public let displayPath: String
    public let kind: String
    public let createsBackup: Bool
    public let status: CommandLineLauncherStatus

    public init(
        planID: String,
        displayPath: String,
        kind: String,
        createsBackup: Bool,
        status: CommandLineLauncherStatus
    ) {
        self.planID = planID
        self.displayPath = displayPath
        self.kind = kind
        self.createsBackup = createsBackup
        self.status = status
    }
}

public actor CommandLineLauncherInstaller {
    public static let displayPath = "~/.local/bin/quicktty"
    public static let planLifetime: TimeInterval = 300

    private let homeDescriptor: Int32
    private let helperTarget: String
    private let now: @Sendable () -> Date
    private let beforeUninstallSwap: (@Sendable () throws -> Void)?
    private let beforeUninstallQuarantine: (@Sendable () throws -> Void)?
    private var pending: PendingLauncherPlan?

    public init(
        homeDirectory: URL,
        helperExecutable: URL,
        now: @escaping @Sendable () -> Date = { @Sendable in Date() }
    ) throws {
        let configuration = try Self.openConfiguration(
            homeDirectory: homeDirectory,
            helperExecutable: helperExecutable
        )
        homeDescriptor = configuration.homeDescriptor
        helperTarget = configuration.helperTarget
        self.now = now
        beforeUninstallSwap = nil
        beforeUninstallQuarantine = nil
    }

    init(
        homeDirectory: URL,
        helperExecutable: URL,
        now: @escaping @Sendable () -> Date = { @Sendable in Date() },
        beforeUninstallSwap: (@Sendable () throws -> Void)? = nil,
        beforeUninstallQuarantine: (@Sendable () throws -> Void)? = nil
    ) throws {
        let configuration = try Self.openConfiguration(
            homeDirectory: homeDirectory,
            helperExecutable: helperExecutable
        )
        homeDescriptor = configuration.homeDescriptor
        helperTarget = configuration.helperTarget
        self.now = now
        self.beforeUninstallSwap = beforeUninstallSwap
        self.beforeUninstallQuarantine = beforeUninstallQuarantine
    }

    deinit {
        Darwin.close(homeDescriptor)
    }

    public func status() throws -> CommandLineLauncherStatus {
        pending = nil
        switch try snapshot() {
        case .absent:
            return .available
        case .owned:
            return .installed
        case .conflict:
            return .conflict
        }
    }

    public func prepare(action: CommandLineLauncherAction) throws -> CommandLineLauncherSummary {
        pending = nil
        let state = try snapshot()
        let status: CommandLineLauncherStatus
        switch (action, state) {
        case (.install, .absent):
            status = .available
        case (.install, .owned), (.uninstall, .absent):
            status = .noOp
        case (.uninstall, .owned):
            status = .installed
        case (_, .conflict):
            status = .conflict
        }
        let planID = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        pending = PendingLauncherPlan(
            id: planID,
            action: action,
            createdAt: now(),
            snapshot: state
        )
        return CommandLineLauncherSummary(
            planID: planID,
            displayPath: Self.displayPath,
            kind: action == .install ? "symlinkCreate" : "symlinkRemove",
            createsBackup: false,
            status: status
        )
    }

    public func apply(planID: String) async throws -> CommandLineLauncherStatus {
        try Task.checkCancellation()
        guard let plan = pending, plan.id == planID else {
            pending = nil
            throw AgentIntegrationInstallerRequestError.invalidPlan
        }
        pending = nil
        guard now().timeIntervalSince(plan.createdAt) <= Self.planLifetime else {
            throw AgentIntegrationInstallerRequestError.expiredPlan
        }
        guard try snapshot() == plan.snapshot else {
            throw AgentIntegrationInstallerError.changedAfterPreview
        }

        switch (plan.action, plan.snapshot) {
        case (.install, .owned), (.uninstall, .absent):
            return .noOp
        case (_, .conflict):
            throw AgentIntegrationInstallerError.conflict
        case (.install, .absent):
            try Task.checkCancellation()
            try createLauncher()
            return .succeeded
        case (.uninstall, .owned(let expectedIdentity)):
            try Task.checkCancellation()
            try removeLauncher(expectedIdentity: expectedIdentity)
            return .succeeded
        }
    }

    fileprivate enum Snapshot: Equatable, Sendable {
        case absent([EntryIdentity])
        case owned(EntryIdentity)
        case conflict(EntryIdentity)
    }

    fileprivate struct EntryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let links: UInt64
        let target: String?
    }

    private func snapshot() throws -> Snapshot {
        var descriptor = fcntl(homeDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.ioFailure }
        defer { Darwin.close(descriptor) }
        var parents: [EntryIdentity] = []

        for component in [".local", "bin"] {
            var status = stat()
            guard fstatat(descriptor, component, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return .absent(parents) }
                throw AgentIntegrationInstallerError.pathRejected
            }
            let identity = Self.identity(status, target: nil)
            guard status.st_mode & S_IFMT == S_IFDIR, status.st_nlink >= 1 else {
                return .conflict(identity)
            }
            parents.append(identity)
            let next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
            Darwin.close(descriptor)
            descriptor = next
        }

        var status = stat()
        guard fstatat(descriptor, "quicktty", &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .absent(parents) }
            throw AgentIntegrationInstallerError.pathRejected
        }
        guard status.st_mode & S_IFMT == S_IFLNK else {
            return .conflict(Self.identity(status, target: nil))
        }
        let target = try readLink(parent: descriptor, name: "quicktty")
        let identity = Self.identity(status, target: target)
        return target == helperTarget ? .owned(identity) : .conflict(identity)
    }

    private func createLauncher() throws {
        var descriptor = fcntl(homeDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.ioFailure }
        defer { Darwin.close(descriptor) }
        var created: [(Int32, String)] = []
        do {
            for component in [".local", "bin"] {
                var next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                var directoryWasCreated = false
                if next < 0, errno == ENOENT {
                    guard mkdirat(descriptor, component, 0o700) == 0 else {
                        throw AgentIntegrationInstallerError.changedAfterPreview
                    }
                    directoryWasCreated = true
                    created.append((fcntl(descriptor, F_DUPFD_CLOEXEC, 0), component))
                    next = openat(
                        descriptor,
                        component,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard next >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
                var status = stat()
                guard fstat(next, &status) == 0,
                    status.st_mode & S_IFMT == S_IFDIR,
                    !directoryWasCreated || fchmod(next, 0o700) == 0
                else {
                    Darwin.close(next)
                    throw AgentIntegrationInstallerError.pathRejected
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            try Task.checkCancellation()
            guard symlinkat(helperTarget, descriptor, "quicktty") == 0,
                Darwin.fsync(descriptor) == 0
            else { throw AgentIntegrationInstallerError.changedAfterPreview }
            for (parent, _) in created { Darwin.close(parent) }
        } catch {
            for (parent, component) in created.reversed() {
                _ = unlinkat(parent, component, AT_REMOVEDIR)
                Darwin.close(parent)
            }
            throw error
        }
    }

    private func removeLauncher(expectedIdentity: EntryIdentity) throws {
        var descriptor = fcntl(homeDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.ioFailure }
        defer { Darwin.close(descriptor) }
        for component in [".local", "bin"] {
            let next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if next < 0, errno == ENOENT { return }
            guard next >= 0 else { throw AgentIntegrationInstallerError.changedAfterPreview }
            Darwin.close(descriptor)
            descriptor = next
        }

        let sentinel = try createSentinel(parent: descriptor)
        var sentinelIsAtTemporaryName = true
        defer {
            if sentinelIsAtTemporaryName {
                removeIfOwnedSentinel(parent: descriptor, sentinel: sentinel)
            }
        }

        try beforeUninstallSwap?()
        guard try entryIdentity(parent: descriptor, name: sentinel.name) == sentinel.identity else {
            throw AgentIntegrationInstallerError.changedAfterPreview
        }
        guard
            renameatx_np(
                descriptor,
                sentinel.name,
                descriptor,
                "quicktty",
                UInt32(RENAME_SWAP)
            ) == 0
        else {
            if errno == ENOENT, entryIsAbsent(parent: descriptor, name: "quicktty") {
                removeIfOwnedSentinel(parent: descriptor, sentinel: sentinel)
                sentinelIsAtTemporaryName = false
                guard entryIsAbsent(parent: descriptor, name: sentinel.name),
                    Darwin.fsync(descriptor) == 0
                else {
                    throw AgentIntegrationInstallerError.indeterminate
                }
                return
            }
            throw AgentIntegrationInstallerError.changedAfterPreview
        }
        sentinelIsAtTemporaryName = false

        guard try entryIdentity(parent: descriptor, name: "quicktty") == sentinel.identity else {
            removeIfMatching(parent: descriptor, name: sentinel.name, identity: expectedIdentity)
            throw AgentIntegrationInstallerError.changedAfterPreview
        }
        let swappedIdentity: EntryIdentity
        do {
            swappedIdentity = try entryIdentity(parent: descriptor, name: sentinel.name)
        } catch {
            try restoreAfterConflict(parent: descriptor, sentinel: sentinel)
            throw error
        }
        guard swappedIdentity == expectedIdentity,
            swappedIdentity.mode == UInt16(S_IFLNK),
            swappedIdentity.target == helperTarget
        else {
            try restoreAfterConflict(parent: descriptor, sentinel: sentinel)
            throw AgentIntegrationInstallerError.changedAfterPreview
        }

        try beforeUninstallQuarantine?()
        let sentinelQuarantine: String
        do {
            sentinelQuarantine = try quarantineEntry(
                parent: descriptor,
                name: "quicktty",
                expectedIdentity: sentinel.identity
            )
        } catch {
            let launcherQuarantine = try quarantineEntry(
                parent: descriptor,
                name: sentinel.name,
                expectedIdentity: expectedIdentity
            )
            guard
                removeQuarantinedEntry(
                    parent: descriptor,
                    name: launcherQuarantine,
                    identity: expectedIdentity
                ), Darwin.fsync(descriptor) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            throw error
        }
        let launcherQuarantine: String
        do {
            launcherQuarantine = try quarantineEntry(
                parent: descriptor,
                name: sentinel.name,
                expectedIdentity: expectedIdentity
            )
        } catch {
            try restoreQuarantinedEntry(
                parent: descriptor,
                quarantineName: sentinelQuarantine,
                name: "quicktty",
                identity: sentinel.identity
            )
            throw error
        }

        guard
            removeQuarantinedEntry(
                parent: descriptor,
                name: sentinelQuarantine,
                identity: sentinel.identity
            ),
            removeQuarantinedEntry(
                parent: descriptor,
                name: launcherQuarantine,
                identity: expectedIdentity
            ),
            Darwin.fsync(descriptor) == 0
        else {
            throw AgentIntegrationInstallerError.indeterminate
        }
    }

    private struct Sentinel {
        let name: String
        let identity: EntryIdentity
    }

    private static func openConfiguration(
        homeDirectory: URL,
        helperExecutable: URL
    ) throws -> (homeDescriptor: Int32, helperTarget: String) {
        guard homeDirectory.isFileURL, helperExecutable.isFileURL,
            homeDirectory.path.hasPrefix("/"), helperExecutable.path.hasPrefix("/"),
            helperExecutable.path.utf8.count <= 4_096
        else { throw AgentIntegrationInstallerError.invalidPath }
        let descriptor = Darwin.open(
            homeDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
        var helperStatus = stat()
        guard lstat(helperExecutable.path, &helperStatus) == 0,
            helperStatus.st_mode & S_IFMT == S_IFREG
        else {
            Darwin.close(descriptor)
            throw AgentIntegrationInstallerError.pathRejected
        }
        return (descriptor, helperExecutable.path)
    }

    private func createSentinel(parent: Int32) throws -> Sentinel {
        for _ in 0..<8 {
            let name = ".quicktty-\(UUID().uuidString).remove"
            if symlinkat(helperTarget, parent, name) == 0 {
                let identity = try entryIdentity(parent: parent, name: name)
                guard identity.mode == UInt16(S_IFLNK), identity.target == helperTarget else {
                    removeIfMatching(parent: parent, name: name, identity: identity)
                    throw AgentIntegrationInstallerError.ioFailure
                }
                return Sentinel(name: name, identity: identity)
            }
            if errno != EEXIST { throw AgentIntegrationInstallerError.ioFailure }
        }
        throw AgentIntegrationInstallerError.ioFailure
    }

    private func restoreAfterConflict(parent: Int32, sentinel: Sentinel) throws {
        guard try entryIdentity(parent: parent, name: "quicktty") == sentinel.identity else {
            throw AgentIntegrationInstallerError.indeterminate
        }
        guard
            renameatx_np(
                parent,
                "quicktty",
                parent,
                sentinel.name,
                UInt32(RENAME_SWAP)
            ) == 0
        else { throw AgentIntegrationInstallerError.indeterminate }
        guard Darwin.fsync(parent) == 0 else {
            throw AgentIntegrationInstallerError.indeterminate
        }
        removeIfOwnedSentinel(parent: parent, sentinel: sentinel)
        guard entryIsAbsent(parent: parent, name: sentinel.name), Darwin.fsync(parent) == 0 else {
            throw AgentIntegrationInstallerError.indeterminate
        }
    }

    private func quarantineEntry(
        parent: Int32,
        name: String,
        expectedIdentity: EntryIdentity
    ) throws -> String {
        for _ in 0..<8 {
            let quarantineName = ".quicktty-\(UUID().uuidString).cleanup"
            guard
                renameatx_np(
                    parent,
                    name,
                    parent,
                    quarantineName,
                    UInt32(RENAME_EXCL)
                ) == 0
            else {
                if errno == EEXIST { continue }
                throw AgentIntegrationInstallerError.changedAfterPreview
            }
            guard try entryIdentity(parent: parent, name: quarantineName) == expectedIdentity else {
                try restoreQuarantinedEntry(
                    parent: parent,
                    quarantineName: quarantineName,
                    name: name,
                    identity: nil
                )
                throw AgentIntegrationInstallerError.changedAfterPreview
            }
            return quarantineName
        }
        throw AgentIntegrationInstallerError.ioFailure
    }

    private func restoreQuarantinedEntry(
        parent: Int32,
        quarantineName: String,
        name: String,
        identity: EntryIdentity?
    ) throws {
        if let identity,
            try entryIdentity(parent: parent, name: quarantineName) != identity
        {
            throw AgentIntegrationInstallerError.indeterminate
        }
        guard
            renameatx_np(
                parent,
                quarantineName,
                parent,
                name,
                UInt32(RENAME_EXCL)
            ) == 0,
            Darwin.fsync(parent) == 0
        else { throw AgentIntegrationInstallerError.indeterminate }
    }

    private func removeQuarantinedEntry(
        parent: Int32,
        name: String,
        identity: EntryIdentity
    ) -> Bool {
        guard (try? entryIdentity(parent: parent, name: name)) == identity else { return false }
        return unlinkat(parent, name, 0) == 0
    }

    private func removeIfOwnedSentinel(parent: Int32, sentinel: Sentinel) {
        removeIfMatching(parent: parent, name: sentinel.name, identity: sentinel.identity)
    }

    private func removeIfMatching(parent: Int32, name: String, identity: EntryIdentity) {
        guard (try? entryIdentity(parent: parent, name: name)) == identity else { return }
        _ = unlinkat(parent, name, 0)
    }

    private func entryIsAbsent(parent: Int32, name: String) -> Bool {
        var status = stat()
        return fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    private func entryIdentity(parent: Int32, name: String) throws -> EntryIdentity {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw AgentIntegrationInstallerError.changedAfterPreview }
            throw AgentIntegrationInstallerError.ioFailure
        }
        let target =
            status.st_mode & S_IFMT == S_IFLNK
            ? try readLink(parent: parent, name: name) : nil
        return Self.identity(status, target: target)
    }

    private func readLink(parent: Int32, name: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 4_097)
        let count = readlinkat(parent, name, &buffer, buffer.count)
        guard count > 0, count <= 4_096 else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    private static func identity(_ status: stat, target: String?) -> EntryIdentity {
        EntryIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            mode: UInt16(status.st_mode & S_IFMT),
            links: UInt64(status.st_nlink),
            target: target
        )
    }
}

private struct PendingLauncherPlan: Sendable {
    let id: String
    let action: CommandLineLauncherAction
    let createdAt: Date
    let snapshot: CommandLineLauncherInstaller.Snapshot
}
