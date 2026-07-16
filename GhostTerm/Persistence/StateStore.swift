import Darwin
import Foundation
import OSLog

enum StateStoreError: Error, Equatable, Sendable {
    case productionLocationUnavailable(String)
    case invalidHomeDirectory(path: String)
    case readFailed(path: String, reason: String)
    case backupFailed(sourcePath: String, backupPath: String, reason: String)
    case createDirectoryFailed(path: String, reason: String)
    case staleTemporaryEnumerationFailed(directoryPath: String, reason: String)
    case staleTemporaryCleanupFailed(path: String, reason: String)
    case encodeFailed(String)
    case temporaryWriteFailed(path: String, reason: String)
    case fileSynchronizationFailed(path: String, reason: String)
    indirect case temporaryCleanupFailed(
        path: String,
        reason: String,
        primaryError: StateStoreError
    )
    case atomicReplaceFailed(destinationPath: String, reason: String)
    case directorySynchronizationFailed(path: String, reason: String)
}

extension StateStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .productionLocationUnavailable(let reason):
            "Could not locate application support: \(reason)"
        case .invalidHomeDirectory(let path):
            "Home directory is not an existing absolute directory: \(path)"
        case .readFailed(let path, let reason):
            "Could not read state at \(path): \(reason)"
        case .backupFailed(let sourcePath, let backupPath, let reason):
            "Could not move invalid state from \(sourcePath) to \(backupPath): \(reason)"
        case .createDirectoryFailed(let path, let reason):
            "Could not create state directory at \(path): \(reason)"
        case .staleTemporaryEnumerationFailed(let directoryPath, let reason):
            "Could not enumerate stale state files in \(directoryPath): \(reason)"
        case .staleTemporaryCleanupFailed(let path, let reason):
            "Could not remove stale state file at \(path): \(reason)"
        case .encodeFailed(let reason):
            "Could not encode application state: \(reason)"
        case .temporaryWriteFailed(let path, let reason):
            "Could not write temporary state at \(path): \(reason)"
        case .fileSynchronizationFailed(let path, let reason):
            "Could not synchronize temporary state at \(path): \(reason)"
        case .temporaryCleanupFailed(let path, let reason, let primaryError):
            "Could not remove temporary state at \(path) after \(primaryError.localizedDescription): \(reason)"
        case .atomicReplaceFailed(let destinationPath, let reason):
            "Could not atomically replace state at \(destinationPath): \(reason)"
        case .directorySynchronizationFailed(let path, let reason):
            "Could not synchronize state directory at \(path): \(reason)"
        }
    }
}

@MainActor
final class StateStore {
    typealias Schedule =
        (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    @MainActor
    struct FileOperations {
        let contentsOfDirectory: @MainActor (URL) throws -> [URL]
        let removeItem: @MainActor (URL) throws -> Void
        let writeTemporary: @MainActor (Data, URL) throws -> Void
        let synchronizeFile: @MainActor (URL) throws -> Void
        let moveTemporary: @MainActor (URL, URL) throws -> Void
        let replaceDestination: @MainActor (URL, URL) throws -> Void
        let synchronizeDirectory: @MainActor (URL) throws -> Void

        static func production(fileManager: FileManager = .default) -> FileOperations {
            FileOperations(
                contentsOfDirectory: { url in
                    try fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil
                    )
                },
                removeItem: { url in
                    try fileManager.removeItem(at: url)
                },
                writeTemporary: { data, url in
                    try data.write(to: url, options: .withoutOverwriting)
                },
                synchronizeFile: StateStore.synchronizeFile,
                moveTemporary: { sourceURL, destinationURL in
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                },
                replaceDestination: StateStore.replaceDestination,
                synchronizeDirectory: StateStore.synchronizeDirectory
            )
        }
    }

    private static let logger = Logger(
        subsystem: "com.dntsk.GhostTerm",
        category: "StateStore"
    )

    private let url: URL
    private let homeDirectoryURL: URL
    private let fileManager: FileManager
    private let fileOperations: FileOperations
    private let backupSuffix: @MainActor () -> String
    private let schedule: Schedule
    private let reportScheduledError: (StateStoreError) -> Void
    private var pendingState: ApplicationState?
    private var scheduledCancellation: (@MainActor () -> Void)?
    private var scheduleGeneration: UInt = 0

    init(
        url: URL,
        homeDirectoryURL: URL,
        fileManager: FileManager = .default,
        backupSuffix: @escaping @MainActor () -> String = StateStore.makeTimestampSuffix,
        schedule: Schedule? = nil,
        reportScheduledError: ((StateStoreError) -> Void)? = nil,
        fileOperations: FileOperations? = nil
    ) throws {
        guard homeDirectoryURL.isFileURL,
            Self.isExistingAbsoluteDirectory(homeDirectoryURL.path, fileManager: fileManager)
        else {
            throw StateStoreError.invalidHomeDirectory(path: homeDirectoryURL.path)
        }

        self.url = url
        self.homeDirectoryURL = homeDirectoryURL
        self.fileManager = fileManager
        self.fileOperations = fileOperations ?? .production(fileManager: fileManager)
        self.backupSuffix = backupSuffix
        self.schedule = schedule ?? Self.productionSchedule
        self.reportScheduledError =
            reportScheduledError ?? { error in
                Self.logger.error(
                    "Debounced state save failed: \(error.localizedDescription, privacy: .public)")
            }
    }

    isolated deinit {
        scheduledCancellation?()
    }

    static func production(fileManager: FileManager = .default) throws -> StateStore {
        let applicationSupportURL: URL
        do {
            applicationSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw StateStoreError.productionLocationUnavailable(String(describing: error))
        }

        return try StateStore(
            url:
                applicationSupportURL
                .appending(path: "GhostTerm", directoryHint: .isDirectory)
                .appending(path: "state.json"),
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
    }

    func load() throws -> ApplicationState {
        try removeStaleTemporaryItems()
        guard fileManager.fileExists(atPath: url.path) else {
            return ApplicationState()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StateStoreError.readFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }

        do {
            let state = try StateMigration.decode(data)
            return try normalizingWorkingDirectories(in: state)
        } catch {
            try backupInvalidState()
            return ApplicationState()
        }
    }

    func saveNow(_ state: ApplicationState) throws {
        cancelScheduledCallback()
        pendingState = nil
        try write(state)
    }

    func scheduleSave(_ state: ApplicationState) {
        cancelScheduledCallback()
        pendingState = state
        let generation = scheduleGeneration
        scheduledCancellation = schedule { [weak self] in
            guard let self,
                scheduleGeneration == generation,
                let pendingState
            else {
                return
            }

            scheduledCancellation = nil
            self.pendingState = nil
            do {
                try write(pendingState)
            } catch let error as StateStoreError {
                reportScheduledError(error)
            } catch {
                reportScheduledError(.encodeFailed(String(describing: error)))
            }
        }
    }

    func flushPendingSave() throws {
        guard let pendingState else { return }
        cancelScheduledCallback()
        try write(pendingState)
        self.pendingState = nil
    }

    private func normalizingWorkingDirectories(
        in state: ApplicationState
    ) throws -> ApplicationState {
        var normalizedState = state
        normalizedState.workspaceStore = try state.workspaceStore.mappingPaneDescriptors {
            descriptor in
            var descriptor = descriptor
            if !Self.isExistingAbsoluteDirectory(descriptor.cwd, fileManager: fileManager) {
                descriptor.cwd = homeDirectoryURL.path
            }
            return descriptor
        }
        return normalizedState
    }

    private func backupInvalidState() throws {
        let backupURL = url.deletingLastPathComponent().appending(
            path: "\(url.lastPathComponent).backup-\(backupSuffix())"
        )
        do {
            try fileManager.moveItem(at: url, to: backupURL)
        } catch {
            throw StateStoreError.backupFailed(
                sourcePath: url.path,
                backupPath: backupURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func write(_ state: ApplicationState) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(state)
        } catch {
            throw StateStoreError.encodeFailed(String(describing: error))
        }

        let parentURL = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw StateStoreError.createDirectoryFailed(
                path: parentURL.path,
                reason: String(describing: error)
            )
        }
        try removeStaleTemporaryItems()

        let temporaryURL = parentURL.appending(
            path: "\(temporaryFilePrefix)\(UUID().uuidString)"
        )
        do {
            try fileOperations.writeTemporary(data, temporaryURL)
        } catch {
            try failAfterCleaningTemporaryItem(
                at: temporaryURL,
                primaryError: .temporaryWriteFailed(
                    path: temporaryURL.path,
                    reason: String(describing: error)
                )
            )
        }

        do {
            try fileOperations.synchronizeFile(temporaryURL)
        } catch {
            try failAfterCleaningTemporaryItem(
                at: temporaryURL,
                primaryError: .fileSynchronizationFailed(
                    path: temporaryURL.path,
                    reason: String(describing: error)
                )
            )
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileOperations.replaceDestination(url, temporaryURL)
            } else {
                try fileOperations.moveTemporary(temporaryURL, url)
            }
        } catch {
            try failAfterCleaningTemporaryItem(
                at: temporaryURL,
                primaryError: .atomicReplaceFailed(
                    destinationPath: url.path,
                    reason: String(describing: error)
                )
            )
        }

        do {
            try fileOperations.synchronizeDirectory(parentURL)
        } catch {
            try failAfterCleaningTemporaryItem(
                at: temporaryURL,
                primaryError: .directorySynchronizationFailed(
                    path: parentURL.path,
                    reason: String(describing: error)
                )
            )
        }
    }

    private var temporaryFilePrefix: String {
        "\(url.lastPathComponent).tmp-"
    }

    private func removeStaleTemporaryItems() throws {
        let parentURL = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentURL.path) else { return }

        let siblings: [URL]
        do {
            siblings = try fileOperations.contentsOfDirectory(parentURL)
        } catch {
            throw StateStoreError.staleTemporaryEnumerationFailed(
                directoryPath: parentURL.path,
                reason: String(describing: error)
            )
        }

        for sibling in siblings where sibling.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            do {
                try fileOperations.removeItem(sibling)
            } catch {
                throw StateStoreError.staleTemporaryCleanupFailed(
                    path: sibling.path,
                    reason: String(describing: error)
                )
            }
        }
    }

    private func failAfterCleaningTemporaryItem(
        at temporaryURL: URL,
        primaryError: StateStoreError
    ) throws -> Never {
        do {
            try fileOperations.removeItem(temporaryURL)
        } catch  where Self.isNoSuchFileError(error) {
            throw primaryError
        } catch {
            throw StateStoreError.temporaryCleanupFailed(
                path: temporaryURL.path,
                reason: String(describing: error),
                primaryError: primaryError
            )
        }
        throw primaryError
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
            return true
        }
        guard let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isNoSuchFileError(underlyingError)
    }

    private static func isExistingAbsoluteDirectory(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            if Darwin.fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                let fullSyncError = errno
                guard fullSyncError == ENOTSUP else {
                    throw posixError(
                        code: fullSyncError,
                        operation: "F_FULLFSYNC",
                        path: url.path
                    )
                }

                // Some filesystems explicitly reject F_FULLFSYNC; fsync is the strongest supported fallback.
                if Darwin.fsync(handle.fileDescriptor) == -1 {
                    throw posixError(
                        code: errno,
                        operation: "fsync fallback",
                        path: url.path
                    )
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func replaceDestination(
        _ destinationURL: URL,
        _ temporaryURL: URL
    ) throws {
        let result = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw posixError(
                code: errno,
                operation: "rename",
                path: destinationURL.path
            )
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw posixError(
                code: errno,
                operation: "open directory",
                path: url.path
            )
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(
                code: errno,
                operation: "fsync directory",
                path: url.path
            )
        }
    }

    private static func posixError(
        code: Int32,
        operation: String,
        path: String
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(code)))"
            ]
        )
    }

    private func cancelScheduledCallback() {
        scheduleGeneration &+= 1
        let cancellation = scheduledCancellation
        scheduledCancellation = nil
        cancellation?()
    }

    private static func productionSchedule(
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            action()
        }
        return {
            task.cancel()
        }
    }

    private static func makeTimestampSuffix() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
