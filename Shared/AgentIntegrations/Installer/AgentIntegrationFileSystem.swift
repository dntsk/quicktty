import Darwin
import Foundation
import Synchronization

public final class AgentIntegrationFileSystem: Sendable {
    public static let maximumFileBytes = 1_048_576
    public static let maximumWriteCount = 32
    public static let maximumTransactionBytes = 8_388_608

    private static let maximumRootUTF8Length = 4_096
    private static let maximumPinnedSymlinks = 8

    private struct PinnedDirectorySymlink: Sendable {
        let identity: AgentIntegrationFileIdentity
        let destination: String
        let targetIdentity: AgentIntegrationFileIdentity
        let targetDescriptor: Int32
    }

    private struct PinnedSymlinkState: Sendable {
        var entries: [String: PinnedDirectorySymlink] = [:]
    }

    private let homeRootDescriptor: Int32
    private let applicationSupportRootDescriptor: Int32
    private let homeRootPath: String
    private let applicationSupportRootPath: String
    private let pinnedSymlinks = Mutex(PinnedSymlinkState())
    private let beforeSwap: (@Sendable (AgentIntegrationPath) throws -> Void)?
    private let afterSwap: (@Sendable (AgentIntegrationPath) throws -> Void)?

    public convenience init(homeDirectory: URL, applicationSupportDirectory: URL) throws {
        try self.init(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            beforeSwap: nil,
            afterSwap: nil
        )
    }

    init(
        homeDirectory: URL,
        applicationSupportDirectory: URL,
        beforeSwap: (@Sendable (AgentIntegrationPath) throws -> Void)?,
        afterSwap: (@Sendable (AgentIntegrationPath) throws -> Void)? = nil
    ) throws {
        guard homeDirectory.isFileURL, applicationSupportDirectory.isFileURL else {
            throw AgentIntegrationInstallerError.invalidPath
        }
        let homeRootPath = Self.normalizedRootPath(homeDirectory.path)
        let applicationSupportRootPath = Self.normalizedRootPath(applicationSupportDirectory.path)
        let homeRootDescriptor = try Self.openRoot(homeRootPath)
        do {
            self.applicationSupportRootDescriptor = try Self.openRoot(
                applicationSupportRootPath)
        } catch {
            Darwin.close(homeRootDescriptor)
            throw error
        }
        self.homeRootDescriptor = homeRootDescriptor
        self.homeRootPath = homeRootPath
        self.applicationSupportRootPath = applicationSupportRootPath
        self.beforeSwap = beforeSwap
        self.afterSwap = afterSwap
    }

    deinit {
        let entries = pinnedSymlinks.withLock { state in
            let entries = Array(state.entries.values)
            state.entries.removeAll(keepingCapacity: false)
            return entries
        }
        for entry in entries {
            Darwin.close(entry.targetDescriptor)
        }
        Darwin.close(homeRootDescriptor)
        Darwin.close(applicationSupportRootDescriptor)
    }

    public func read(_ path: AgentIntegrationPath) throws -> Data? {
        try readSnapshot(path)?.data
    }

    public func prepareWrite(
        path: AgentIntegrationPath,
        data: Data,
        kind: AgentIntegrationMutationKind,
        mode: AgentIntegrationFileMode = .configuration,
        createParentDirectories: Bool = false
    ) throws -> AgentIntegrationPreparedWrite {
        guard data.count <= Self.maximumFileBytes else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        let snapshot = try readSnapshot(path)
        let before = snapshot?.data
        let changesFile = before != data || snapshot?.permissions != mode.permissions
        let operationID = AgentIntegrationHash.operationID(
            path: path,
            kind: kind,
            before: before,
            after: data
        )
        let preview = AgentIntegrationMutationPreview(
            operationID: operationID,
            fingerprint: AgentIntegrationHash.digest(before),
            path: path,
            kind: kind,
            operation: changesFile ? (before == nil ? .create : .update) : .noOp,
            mode: mode,
            changesFile: changesFile,
            createsBackup: before != nil && changesFile
        )
        return AgentIntegrationPreparedWrite(
            preview: preview,
            replacement: data,
            expectedData: before,
            expectedIdentity: snapshot?.identity,
            expectedPermissions: snapshot?.permissions,
            replacementMode: mode,
            createParentDirectories: createParentDirectories
        )
    }

    public func prepareRemoval(
        path: AgentIntegrationPath,
        kind: AgentIntegrationMutationKind
    ) throws -> AgentIntegrationPreparedWrite {
        let snapshot = try readSnapshot(path)
        let before = snapshot?.data
        let operationID = AgentIntegrationHash.operationID(
            path: path,
            kind: kind,
            before: before,
            after: nil
        )
        return AgentIntegrationPreparedWrite(
            preview: AgentIntegrationMutationPreview(
                operationID: operationID,
                fingerprint: AgentIntegrationHash.digest(before),
                path: path,
                kind: kind,
                operation: before == nil ? .noOp : .remove,
                mode: nil,
                changesFile: before != nil,
                createsBackup: before != nil
            ),
            replacement: nil,
            expectedData: before,
            expectedIdentity: snapshot?.identity,
            expectedPermissions: snapshot?.permissions,
            replacementMode: nil
        )
    }

    public func validate(
        _ writes: [AgentIntegrationPreparedWrite],
        matching previews: [AgentIntegrationMutationPreview]
    ) throws {
        try validateRequest(writes, matching: previews)
    }

    public func apply(
        _ writes: [AgentIntegrationPreparedWrite],
        matching previews: [AgentIntegrationMutationPreview],
        verification: (@Sendable (Int) throws -> Bool)? = nil,
        transactionVerification: (@Sendable () throws -> Bool)? = nil
    ) throws -> AgentIntegrationApplyResult {
        try validateRequest(writes, matching: previews)

        let changed = writes.filter(\.preview.changesFile)
        guard !changed.isEmpty else {
            guard try transactionVerification?() ?? true else {
                throw AgentIntegrationInstallerError.verificationFailed
            }
            return AgentIntegrationApplyResult(changedPaths: [], backupPaths: [])
        }

        var applied: [AppliedMutation] = []
        var backups: [AppliedMutation] = []
        do {
            for (index, write) in changed.enumerated() {
                if let original = write.expectedData {
                    let backupPath = try makeBackupPath(for: write.preview.path)
                    let backupState = try casMutate(
                        backupPath,
                        expectedData: nil,
                        expectedIdentity: nil,
                        expectedPermissions: nil,
                        replacement: original,
                        replacementPermissions: AgentIntegrationFileMode.configuration.permissions,
                        createDirectories: false,
                        invokeHook: false
                    )
                    backups.append(
                        AppliedMutation(
                            path: backupPath,
                            originalData: nil,
                            originalPermissions: nil,
                            installedState: backupState
                        ))
                }
                var installedState = try casMutate(
                    write.preview.path,
                    expectedData: write.expectedData,
                    expectedIdentity: write.expectedIdentity,
                    expectedPermissions: write.expectedPermissions,
                    replacement: write.replacement,
                    replacementPermissions: write.replacementMode?.permissions,
                    createDirectories: write.createParentDirectories,
                    invokeHook: true
                )
                if let afterSwap {
                    try afterSwap(write.preview.path)
                    installedState = try mutationState(write.preview.path)
                }
                let mutation = AppliedMutation(
                    path: write.preview.path,
                    originalData: write.expectedData,
                    originalPermissions: write.expectedPermissions,
                    installedState: installedState
                )
                applied.append(mutation)
                guard try matches(write.preview.path, state: installedState),
                    try verification?(index) ?? true
                else {
                    throw AgentIntegrationInstallerError.verificationFailed
                }
            }
            guard try transactionVerification?() ?? true else {
                throw AgentIntegrationInstallerError.verificationFailed
            }
        } catch {
            let primaryError = error
            var rollbackErrors: [Error] = []
            for mutation in applied.reversed() {
                do {
                    try rollback(mutation)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            for backup in backups.reversed() {
                do {
                    try rollback(backup)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            if rollbackErrors.contains(where: {
                ($0 as? AgentIntegrationInstallerError) == .indeterminate
            }) {
                throw AgentIntegrationInstallerError.indeterminate
            }
            if !rollbackErrors.isEmpty {
                throw AgentIntegrationInstallerError.rollbackFailed
            }
            throw primaryError
        }

        return AgentIntegrationApplyResult(
            changedPaths: changed.map(\.preview.path),
            backupPaths: backups.map(\.path)
        )
    }

    func verifyInstalled(_ writes: [AgentIntegrationPreparedWrite]) throws -> Bool {
        for write in writes {
            let snapshot = try readSnapshot(write.preview.path)
            if let replacement = write.replacement, let mode = write.replacementMode {
                guard snapshot?.data == replacement,
                    snapshot?.permissions == mode.permissions
                else { return false }
            } else if snapshot != nil {
                return false
            }
        }
        return true
    }

    private func mutationState(_ path: AgentIntegrationPath) throws -> MutationState {
        let snapshot = try readSnapshot(path)
        return MutationState(
            data: snapshot?.data,
            identity: snapshot?.identity,
            permissions: snapshot?.permissions
        )
    }

    private func validateRequest(
        _ writes: [AgentIntegrationPreparedWrite],
        matching previews: [AgentIntegrationMutationPreview]
    ) throws {
        guard writes.count == previews.count,
            writes.count <= Self.maximumWriteCount,
            Set(writes.map(\.preview.path)).count == writes.count,
            zip(writes, previews).allSatisfy({ $0.preview == $1 }),
            writes.reduce(0, { $0 + ($1.replacement?.count ?? 0) })
                <= Self.maximumTransactionBytes
        else {
            throw AgentIntegrationInstallerError.previewMismatch
        }

        for write in writes {
            guard
                try matches(
                    write.preview.path,
                    data: write.expectedData,
                    identity: write.expectedIdentity,
                    permissions: write.expectedPermissions)
            else {
                throw AgentIntegrationInstallerError.changedAfterPreview
            }
        }
    }

    private struct ParentDescriptor {
        let descriptor: Int32
        let name: String
    }

    private struct FileSnapshot {
        let data: Data
        let identity: AgentIntegrationFileIdentity
        let permissions: mode_t
    }

    private struct MutationState {
        let data: Data?
        let identity: AgentIntegrationFileIdentity?
        let permissions: mode_t?
    }

    private struct AppliedMutation {
        let path: AgentIntegrationPath
        let originalData: Data?
        let originalPermissions: mode_t?
        let installedState: MutationState
    }

    private static func normalizedRootPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func openRoot(_ path: String) throws -> Int32 {
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2f, bytes.count <= maximumRootUTF8Length else {
            throw AgentIntegrationInstallerError.invalidPath
        }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard
            components.allSatisfy({ component in
                !component.isEmpty && component != "." && component != ".."
                    && component.utf8.count <= 255
                    && !component.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
            })
        else {
            throw AgentIntegrationInstallerError.invalidPath
        }

        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
        do {
            for component in components {
                let next = openat(
                    descriptor,
                    String(component),
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
                var status = stat()
                guard fstat(next, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                    Darwin.close(next)
                    throw AgentIntegrationInstallerError.pathRejected
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func rootDescriptor(for root: AgentIntegrationRoot) -> Int32 {
        switch root {
        case .home: homeRootDescriptor
        case .applicationSupport: applicationSupportRootDescriptor
        }
    }

    private func rootPath(for root: AgentIntegrationRoot) -> String {
        switch root {
        case .home: homeRootPath
        case .applicationSupport: applicationSupportRootPath
        }
    }

    private func openParent(
        _ path: AgentIntegrationPath,
        createDirectories: Bool,
        allowMissingParent: Bool = false
    ) throws -> ParentDescriptor? {
        var descriptor = fcntl(rootDescriptor(for: path.root), F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.ioFailure }
        var succeeded = false
        defer { if !succeeded { Darwin.close(descriptor) } }

        var traversedComponents: [String] = []
        for component in path.components.dropLast() {
            traversedComponents.append(component)
            var namedStatus = stat()
            var statusResult = fstatat(descriptor, component, &namedStatus, AT_SYMLINK_NOFOLLOW)
            if statusResult < 0, errno == ENOENT, createDirectories {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw AgentIntegrationInstallerError.ioFailure
                }
                statusResult = fstatat(
                    descriptor,
                    component,
                    &namedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if statusResult < 0, errno == ENOENT, allowMissingParent { return nil }
            guard statusResult == 0 else { throw AgentIntegrationInstallerError.pathRejected }

            let next: Int32
            if namedStatus.st_mode & S_IFMT == S_IFLNK {
                next = try openPinnedDirectorySymlink(
                    parent: descriptor,
                    name: component,
                    namedStatus: namedStatus,
                    key: path.root.rawValue + ":" + traversedComponents.joined(separator: "/"),
                    rootPath: rootPath(for: path.root)
                )
            } else {
                guard namedStatus.st_mode & S_IFMT == S_IFDIR else {
                    throw AgentIntegrationInstallerError.pathRejected
                }
                next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
                var openedStatus = stat()
                guard fstat(next, &openedStatus) == 0,
                    openedStatus.st_mode & S_IFMT == S_IFDIR,
                    openedStatus.st_dev == namedStatus.st_dev,
                    openedStatus.st_ino == namedStatus.st_ino
                else {
                    Darwin.close(next)
                    throw AgentIntegrationInstallerError.pathRejected
                }
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        succeeded = true
        return ParentDescriptor(descriptor: descriptor, name: path.components.last!)
    }

    private func openPinnedDirectorySymlink(
        parent: Int32,
        name: String,
        namedStatus: stat,
        key: String,
        rootPath: String
    ) throws -> Int32 {
        guard namedStatus.st_uid == geteuid() else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        let symlinkIdentity = identity(namedStatus)
        let destination = try readSymlink(parent: parent, name: name)

        return try pinnedSymlinks.withLock { state in
            if let pinned = state.entries[key] {
                guard pinned.identity == symlinkIdentity,
                    pinned.destination == destination
                else {
                    throw AgentIntegrationInstallerError.pathRejected
                }
                let currentTarget = openat(
                    parent,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC
                )
                guard currentTarget >= 0 else {
                    throw AgentIntegrationInstallerError.pathRejected
                }
                defer { Darwin.close(currentTarget) }
                var currentStatus = stat()
                guard fstat(currentTarget, &currentStatus) == 0,
                    currentStatus.st_mode & S_IFMT == S_IFDIR,
                    identity(currentStatus) == pinned.targetIdentity
                else {
                    throw AgentIntegrationInstallerError.pathRejected
                }
                let duplicate = fcntl(pinned.targetDescriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else {
                    throw AgentIntegrationInstallerError.ioFailure
                }
                return duplicate
            }

            guard state.entries.count < Self.maximumPinnedSymlinks else {
                throw AgentIntegrationInstallerError.resourceLimit
            }
            let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard target >= 0 else {
                throw AgentIntegrationInstallerError.pathRejected
            }
            var targetOwnedByState = false
            defer {
                if !targetOwnedByState { Darwin.close(target) }
            }
            var targetStatus = stat()
            guard fstat(target, &targetStatus) == 0,
                targetStatus.st_mode & S_IFMT == S_IFDIR,
                targetStatus.st_uid == geteuid()
            else {
                throw AgentIntegrationInstallerError.pathRejected
            }
            let canonicalTarget = try descriptorPath(target)
            guard canonicalTarget == rootPath || canonicalTarget.hasPrefix(rootPath + "/") else {
                throw AgentIntegrationInstallerError.pathRejected
            }
            let targetIdentity = identity(targetStatus)
            state.entries[key] = PinnedDirectorySymlink(
                identity: symlinkIdentity,
                destination: destination,
                targetIdentity: targetIdentity,
                targetDescriptor: target
            )
            targetOwnedByState = true
            let duplicate = fcntl(target, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else {
                state.entries.removeValue(forKey: key)
                targetOwnedByState = false
                throw AgentIntegrationInstallerError.ioFailure
            }
            return duplicate
        }
    }

    private func readSymlink(parent: Int32, name: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: Self.maximumRootUTF8Length + 1)
        let count = buffer.withUnsafeMutableBytes { bytes in
            readlinkat(parent, name, bytes.baseAddress, Self.maximumRootUTF8Length)
        }
        guard count > 0, count < Self.maximumRootUTF8Length,
            let destination = String(
                data: Data(buffer.prefix(Int(count))),
                encoding: .utf8
            ),
            !destination.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
        else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        return destination
    }

    private func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0,
            let terminator = buffer.firstIndex(of: 0),
            let path = String(
                bytes: buffer[..<terminator].map { UInt8(bitPattern: $0) },
                encoding: .utf8
            )
        else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        return Self.normalizedRootPath(path)
    }

    private func readSnapshot(_ path: AgentIntegrationPath) throws -> FileSnapshot? {
        let parent = try openParent(path, createDirectories: false, allowMissingParent: true)
        guard let parent else { return nil }
        defer { Darwin.close(parent.descriptor) }
        return try readEntry(parent.descriptor, name: parent.name)
    }

    private func readEntry(_ parent: Int32, name: String) throws -> FileSnapshot? {
        var namedStatus = stat()
        guard fstatat(parent, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw AgentIntegrationInstallerError.pathRejected
        }
        guard namedStatus.st_mode & S_IFMT == S_IFREG, namedStatus.st_nlink == 1,
            namedStatus.st_size >= 0, namedStatus.st_size <= Self.maximumFileBytes
        else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.pathRejected }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & S_IFMT == S_IFREG,
            openedStatus.st_nlink == 1,
            openedStatus.st_dev == namedStatus.st_dev,
            openedStatus.st_ino == namedStatus.st_ino
        else {
            throw AgentIntegrationInstallerError.pathRejected
        }
        let data = try readData(descriptor)
        return FileSnapshot(
            data: data,
            identity: identity(openedStatus),
            permissions: openedStatus.st_mode & 0o7777
        )
    }

    private func readData(_ descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw AgentIntegrationInstallerError.ioFailure
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentIntegrationInstallerError.ioFailure
            }
            guard data.count + count <= Self.maximumFileBytes else {
                throw AgentIntegrationInstallerError.resourceLimit
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func identity(_ status: stat) -> AgentIntegrationFileIdentity {
        AgentIntegrationFileIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino)
        )
    }

    private func matches(
        _ path: AgentIntegrationPath,
        data: Data?,
        identity: AgentIntegrationFileIdentity?,
        permissions: mode_t?
    ) throws -> Bool {
        let snapshot = try readSnapshot(path)
        switch (snapshot, data, identity, permissions) {
        case (nil, nil, nil, nil):
            return true
        case (let snapshot?, let data?, let identity?, let permissions?):
            return snapshot.identity == identity && snapshot.data == data
                && snapshot.permissions == permissions
                && AgentIntegrationHash.digest(snapshot.data) == AgentIntegrationHash.digest(data)
        default:
            return false
        }
    }

    private func matches(_ path: AgentIntegrationPath, state: MutationState) throws -> Bool {
        try matches(
            path,
            data: state.data,
            identity: state.identity,
            permissions: state.permissions
        )
    }

    private func rollback(_ mutation: AppliedMutation) throws {
        do {
            _ = try casMutate(
                mutation.path,
                expectedData: mutation.installedState.data,
                expectedIdentity: mutation.installedState.identity,
                expectedPermissions: mutation.installedState.permissions,
                replacement: mutation.originalData,
                replacementPermissions: mutation.originalPermissions,
                createDirectories: false,
                invokeHook: false
            )
        } catch AgentIntegrationInstallerError.indeterminate {
            throw AgentIntegrationInstallerError.indeterminate
        } catch {
            throw AgentIntegrationInstallerError.rollbackFailed
        }
    }

    private func casMutate(
        _ path: AgentIntegrationPath,
        expectedData: Data?,
        expectedIdentity: AgentIntegrationFileIdentity?,
        expectedPermissions: mode_t?,
        replacement: Data?,
        replacementPermissions: mode_t?,
        createDirectories: Bool,
        invokeHook: Bool
    ) throws -> MutationState {
        guard (expectedData?.count ?? 0) <= Self.maximumFileBytes,
            (replacement?.count ?? 0) <= Self.maximumFileBytes
        else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        guard
            let parent = try openParent(
                path,
                createDirectories: createDirectories,
                allowMissingParent: expectedData == nil && replacement == nil)
        else {
            return MutationState(data: nil, identity: nil, permissions: nil)
        }
        defer { Darwin.close(parent.descriptor) }

        if expectedData == nil, replacement == nil {
            return MutationState(data: nil, identity: nil, permissions: nil)
        }

        let temporaryName = ".quicktty-\(UUID().uuidString).tmp"
        let temporaryData = replacement ?? Data()
        let temporaryPermissions = replacementPermissions ?? 0o600
        let descriptor = try createTemporary(
            parent: parent.descriptor,
            name: temporaryName,
            data: temporaryData,
            permissions: temporaryPermissions
        )
        defer { Darwin.close(descriptor) }
        var temporaryContainsOwnedData = true
        defer {
            if temporaryContainsOwnedData {
                _ = unlinkat(parent.descriptor, temporaryName, 0)
            }
        }
        var temporaryStatus = stat()
        guard fstat(descriptor, &temporaryStatus) == 0 else {
            throw AgentIntegrationInstallerError.ioFailure
        }
        let replacementIdentity = identity(temporaryStatus)

        if expectedData == nil {
            guard replacement != nil else {
                throw AgentIntegrationInstallerError.changedAfterPreview
            }
            if invokeHook { try beforeSwap?(path) }
            guard
                renameatx_np(
                    parent.descriptor,
                    temporaryName,
                    parent.descriptor,
                    parent.name,
                    UInt32(RENAME_EXCL)
                ) == 0
            else {
                if errno == EEXIST { throw AgentIntegrationInstallerError.changedAfterPreview }
                throw AgentIntegrationInstallerError.ioFailure
            }
            temporaryContainsOwnedData = false
            guard Darwin.fsync(parent.descriptor) == 0 else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            return MutationState(
                data: replacement,
                identity: replacementIdentity,
                permissions: temporaryPermissions
            )
        }

        guard let expectedData, let expectedIdentity, let expectedPermissions else {
            throw AgentIntegrationInstallerError.changedAfterPreview
        }
        if invokeHook { try beforeSwap?(path) }
        guard
            renameatx_np(
                parent.descriptor,
                temporaryName,
                parent.descriptor,
                parent.name,
                UInt32(RENAME_SWAP)
            ) == 0
        else {
            if errno == ENOENT { throw AgentIntegrationInstallerError.changedAfterPreview }
            throw AgentIntegrationInstallerError.ioFailure
        }
        temporaryContainsOwnedData = false

        let swappedOut = try readEntry(parent.descriptor, name: temporaryName)
        guard swappedOut?.identity == expectedIdentity,
            swappedOut?.data == expectedData,
            swappedOut?.permissions == expectedPermissions,
            AgentIntegrationHash.digest(swappedOut?.data)
                == AgentIntegrationHash.digest(expectedData)
        else {
            guard
                renameatx_np(
                    parent.descriptor,
                    parent.name,
                    parent.descriptor,
                    temporaryName,
                    UInt32(RENAME_SWAP)
                ) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            temporaryContainsOwnedData = true
            guard Darwin.fsync(parent.descriptor) == 0,
                unlinkat(parent.descriptor, temporaryName, 0) == 0,
                Darwin.fsync(parent.descriptor) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            temporaryContainsOwnedData = false
            throw AgentIntegrationInstallerError.changedAfterPreview
        }

        guard Darwin.fsync(parent.descriptor) == 0 else {
            guard
                renameatx_np(
                    parent.descriptor,
                    parent.name,
                    parent.descriptor,
                    temporaryName,
                    UInt32(RENAME_SWAP)
                ) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            temporaryContainsOwnedData = true
            guard Darwin.fsync(parent.descriptor) == 0,
                unlinkat(parent.descriptor, temporaryName, 0) == 0,
                Darwin.fsync(parent.descriptor) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            temporaryContainsOwnedData = false
            throw AgentIntegrationInstallerError.ioFailure
        }

        if let replacement {
            guard unlinkat(parent.descriptor, temporaryName, 0) == 0 else {
                guard
                    renameatx_np(
                        parent.descriptor,
                        parent.name,
                        parent.descriptor,
                        temporaryName,
                        UInt32(RENAME_SWAP)
                    ) == 0
                else {
                    throw AgentIntegrationInstallerError.indeterminate
                }
                temporaryContainsOwnedData = true
                guard Darwin.fsync(parent.descriptor) == 0,
                    unlinkat(parent.descriptor, temporaryName, 0) == 0,
                    Darwin.fsync(parent.descriptor) == 0
                else {
                    throw AgentIntegrationInstallerError.indeterminate
                }
                temporaryContainsOwnedData = false
                throw AgentIntegrationInstallerError.ioFailure
            }
            guard Darwin.fsync(parent.descriptor) == 0 else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            return MutationState(
                data: replacement,
                identity: replacementIdentity,
                permissions: temporaryPermissions
            )
        }

        try finishRemoval(
            parent: parent,
            temporaryName: temporaryName,
            tombstoneIdentity: replacementIdentity
        )
        return MutationState(data: nil, identity: nil, permissions: nil)
    }

    private func createTemporary(
        parent: Int32,
        name: String,
        data: Data,
        permissions: mode_t
    ) throws -> Int32 {
        let descriptor = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw AgentIntegrationInstallerError.ioFailure }
        do {
            var offset = 0
            try data.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw AgentIntegrationInstallerError.ioFailure
                    }
                    offset += count
                }
            }
            guard fchmod(descriptor, permissions) == 0, Darwin.fsync(descriptor) == 0 else {
                throw AgentIntegrationInstallerError.ioFailure
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            _ = unlinkat(parent, name, 0)
            throw error
        }
    }

    private func finishRemoval(
        parent: ParentDescriptor,
        temporaryName: String,
        tombstoneIdentity: AgentIntegrationFileIdentity
    ) throws {
        let removalName = ".quicktty-\(UUID().uuidString).remove"
        guard
            renameatx_np(
                parent.descriptor,
                parent.name,
                parent.descriptor,
                removalName,
                UInt32(RENAME_EXCL)
            ) == 0
        else {
            if errno == ENOENT {
                guard unlinkat(parent.descriptor, temporaryName, 0) == 0,
                    Darwin.fsync(parent.descriptor) == 0
                else {
                    throw AgentIntegrationInstallerError.indeterminate
                }
                return
            }
            throw AgentIntegrationInstallerError.indeterminate
        }

        let removed = try readEntry(parent.descriptor, name: removalName)
        guard removed?.identity == tombstoneIdentity, removed?.data.isEmpty == true else {
            guard
                renameatx_np(
                    parent.descriptor,
                    removalName,
                    parent.descriptor,
                    parent.name,
                    UInt32(RENAME_EXCL)
                ) == 0,
                unlinkat(parent.descriptor, temporaryName, 0) == 0,
                Darwin.fsync(parent.descriptor) == 0
            else {
                throw AgentIntegrationInstallerError.indeterminate
            }
            throw AgentIntegrationInstallerError.changedAfterPreview
        }
        guard unlinkat(parent.descriptor, removalName, 0) == 0,
            unlinkat(parent.descriptor, temporaryName, 0) == 0,
            Darwin.fsync(parent.descriptor) == 0
        else {
            throw AgentIntegrationInstallerError.indeterminate
        }
    }

    private func makeBackupPath(for path: AgentIntegrationPath) throws -> AgentIntegrationPath {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        var components = path.components
        components[components.count - 1] += ".quicktty-backup-\(timestamp)-\(UUID().uuidString)"
        return try AgentIntegrationPath(root: path.root, components: components)
    }
}
