import Darwin
import Foundation

@MainActor
final class ConfigController {
    typealias ReloadGhostty = @MainActor (URL) throws -> Void
    typealias DiagnosticsHandler = @MainActor ([ConfigDiagnostic]) -> Void

    struct FileClient {
        let fileExists: @MainActor (URL) -> Bool
        let createDirectory: @MainActor (URL) throws -> Void
        let read: @MainActor (URL) throws -> Data
        let createFile: @MainActor (Data, URL) throws -> Void
        let writeAtomic: @MainActor (Data, URL) throws -> Void
        let remove: @MainActor (URL) throws -> Void

        static func production() -> FileClient {
            FileClient(
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                createDirectory: {
                    try FileManager.default.createDirectory(
                        at: $0,
                        withIntermediateDirectories: true
                    )
                },
                read: { try Data(contentsOf: $0) },
                createFile: { data, url in
                    try data.write(to: url, options: .withoutOverwriting)
                },
                writeAtomic: { data, url in
                    try ConfigController.atomicWrite(data, to: url)
                },
                remove: { url in
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    try FileManager.default.removeItem(at: url)
                }
            )
        }
    }

    private(set) var activeConfig = QuickTTYConfig()
    private(set) var activeDocument: ConfigDocument?

    let configURL: URL
    let effectiveGhosttyURL: URL

    private let starterData: Data
    private let fileClient: FileClient
    private let reloadGhostty: ReloadGhostty
    private let onUpdate: @MainActor (QuickTTYConfig) -> Void
    private let onDiagnostics: DiagnosticsHandler
    private let onError: @MainActor (ConfigControllerError) -> Void
    private let watcherScheduler: ConfigFileWatcher.Scheduler?
    private let watcherEventSource: ConfigFileWatcher.EventSource
    private var watcher: ConfigFileWatcher?

    init(
        configURL: URL,
        effectiveGhosttyURL: URL,
        starterData: Data,
        fileClient: FileClient? = nil,
        watcherScheduler: ConfigFileWatcher.Scheduler? = nil,
        watcherEventSource: ConfigFileWatcher.EventSource = .production,
        reloadGhostty: @escaping ReloadGhostty,
        onUpdate: @escaping @MainActor (QuickTTYConfig) -> Void = { _ in },
        onDiagnostics: @escaping DiagnosticsHandler = { _ in },
        onError: @escaping @MainActor (ConfigControllerError) -> Void = { _ in }
    ) {
        self.configURL = configURL
        self.effectiveGhosttyURL = effectiveGhosttyURL
        self.starterData = starterData
        self.fileClient = fileClient ?? .production()
        self.watcherScheduler = watcherScheduler
        self.watcherEventSource = watcherEventSource
        self.reloadGhostty = reloadGhostty
        self.onUpdate = onUpdate
        self.onDiagnostics = onDiagnostics
        self.onError = onError
    }

    isolated deinit {
        watcher?.stop()
    }

    static func production(
        bundle: Bundle = .main,
        reloadGhostty: @escaping ReloadGhostty,
        onUpdate: @escaping @MainActor (QuickTTYConfig) -> Void = { _ in },
        onDiagnostics: @escaping DiagnosticsHandler = { _ in },
        onError: @escaping @MainActor (ConfigControllerError) -> Void = { _ in }
    ) throws -> ConfigController {
        guard let starterURL = bundle.url(forResource: "default-config", withExtension: nil) else {
            throw ConfigControllerError.starterResourceMissing
        }
        let starterData: Data
        do {
            starterData = try Data(contentsOf: starterURL)
        } catch {
            throw ConfigControllerError.starterResourceReadFailed(String(describing: error))
        }
        let urls = productionURLs(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        return ConfigController(
            configURL: urls.configURL,
            effectiveGhosttyURL: urls.effectiveGhosttyURL,
            starterData: starterData,
            reloadGhostty: reloadGhostty,
            onUpdate: onUpdate,
            onDiagnostics: onDiagnostics,
            onError: onError
        )
    }

    static func productionURLs(homeDirectoryURL: URL) -> (
        configURL: URL,
        effectiveGhosttyURL: URL
    ) {
        let directory = homeDirectoryURL
            .appending(path: ".config", directoryHint: .isDirectory)
            .appending(path: "quicktty", directoryHint: .isDirectory)

        return (
            configURL: directory.appending(path: "config"),
            effectiveGhosttyURL: directory.appending(path: ".ghostty-effective-config")
        )
    }

    func load() throws {
        try ensureStarterConfig()
        try reload()
    }

    func start() throws {
        try load()
        let watcher = ConfigFileWatcher(
            url: configURL,
            scheduler: watcherScheduler,
            eventSource: watcherEventSource,
            onChange: { [weak self] in
                guard let self else { return }
                do {
                    try reload()
                } catch let error as ConfigControllerError {
                    onError(error)
                } catch {
                    onError(.sourceReadFailed(String(describing: error)))
                }
            },
            onError: { [weak self] error in
                self?.onError(.watcherFailed(error))
            }
        )
        do {
            try watcher.start()
            self.watcher = watcher
        } catch let error as ConfigFileWatcherError {
            throw ConfigControllerError.watcherFailed(error)
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func reload() throws {
        let source: Data
        do {
            source = try fileClient.read(configURL)
        } catch {
            throw ConfigControllerError.sourceReadFailed(String(describing: error))
        }
        let document = ConfigDocument(data: source)
        guard document != activeDocument else { return }
        try apply(document)
    }

    func updatePresentationMode(_ mode: PresentationMode) throws {
        let source: Data
        do {
            source = try fileClient.read(configURL)
        } catch {
            throw ConfigControllerError.sourceReadFailed(String(describing: error))
        }
        var document = ConfigDocument(data: source)
        document.setPresentationMode(mode)
        do {
            try fileClient.writeAtomic(document.data, configURL)
        } catch {
            throw ConfigControllerError.sourceWriteFailed(String(describing: error))
        }
        try apply(document)
    }

    func updateQuakeHeight(_ fraction: Double) throws {
        let source: Data
        do {
            source = try fileClient.read(configURL)
        } catch {
            throw ConfigControllerError.sourceReadFailed(String(describing: error))
        }
        var document = ConfigDocument(data: source)
        document.setQuakeHeight(fraction)
        do {
            try fileClient.writeAtomic(document.data, configURL)
        } catch {
            throw ConfigControllerError.sourceWriteFailed(String(describing: error))
        }
        try apply(document)
    }

    private func ensureStarterConfig() throws {
        guard !fileClient.fileExists(configURL) else { return }
        do {
            try fileClient.createDirectory(configURL.deletingLastPathComponent())
        } catch {
            throw ConfigControllerError.directoryCreationFailed(String(describing: error))
        }
        do {
            try fileClient.createFile(starterData, configURL)
        } catch {
            throw ConfigControllerError.starterCreationFailed(String(describing: error))
        }
    }

    private func apply(_ document: ConfigDocument) throws {
        let result = document.parse()

        let previousConfig = activeConfig
        let previousDocument = activeDocument
        let previousEffectiveExists = fileClient.fileExists(effectiveGhosttyURL)
        let previousEffectiveData: Data?
        if previousEffectiveExists {
            do {
                previousEffectiveData = try fileClient.read(effectiveGhosttyURL)
            } catch {
                throw ConfigControllerError.effectiveReadFailed(String(describing: error))
            }
        } else {
            previousEffectiveData = nil
        }

        activeConfig = result.config
        do {
            try fileClient.writeAtomic(document.effectiveGhosttyData, effectiveGhosttyURL)
        } catch {
            activeConfig = previousConfig
            throw ConfigControllerError.effectiveWriteFailed(String(describing: error))
        }

        do {
            try reloadGhostty(effectiveGhosttyURL)
        } catch {
            activeConfig = previousConfig
            activeDocument = previousDocument
            do {
                if let previousEffectiveData {
                    try fileClient.writeAtomic(previousEffectiveData, effectiveGhosttyURL)
                } else {
                    try fileClient.remove(effectiveGhosttyURL)
                }
            } catch let rollbackError {
                throw ConfigControllerError.effectiveRollbackFailed(
                    primary: String(describing: error),
                    rollback: String(describing: rollbackError)
                )
            }
            throw ConfigControllerError.ghosttyReloadFailed(String(describing: error))
        }

        activeDocument = document
        onUpdate(result.config)
        guard activeDocument == document else { return }
        onDiagnostics(result.diagnostics)
    }

    private static func atomicWrite(
        _ data: Data,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporaryURL = directoryURL.appending(
            path: ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let result = temporaryURL.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

enum ConfigControllerError: Error, Equatable, LocalizedError, Sendable {
    case starterResourceMissing
    case starterResourceReadFailed(String)
    case directoryCreationFailed(String)
    case starterCreationFailed(String)
    case sourceReadFailed(String)
    case sourceWriteFailed(String)
    case invalidConfig([ConfigDiagnostic])
    case effectiveReadFailed(String)
    case effectiveWriteFailed(String)
    case ghosttyReloadFailed(String)
    case effectiveRollbackFailed(primary: String, rollback: String)
    case watcherFailed(ConfigFileWatcherError)

    var errorDescription: String? {
        switch self {
        case .starterResourceMissing:
            return "The default configuration resource is missing."
        case .starterResourceReadFailed(let error):
            return "The default configuration resource could not be read: \(error)"
        case .directoryCreationFailed(let error):
            return "The configuration directory could not be created: \(error)"
        case .starterCreationFailed(let error):
            return "The default configuration file could not be created: \(error)"
        case .sourceReadFailed(let error):
            return "The configuration file could not be read: \(error)"
        case .sourceWriteFailed(let error):
            return "The configuration file could not be written: \(error)"
        case .invalidConfig(let diagnostics):
            guard !diagnostics.isEmpty else {
                return "The configuration contains invalid values."
            }
            return diagnostics.map(\.localizedDescription).joined(separator: "\n")
        case .effectiveReadFailed(let error):
            return "The effective Ghostty configuration could not be read: \(error)"
        case .effectiveWriteFailed(let error):
            return "The effective Ghostty configuration could not be written: \(error)"
        case .ghosttyReloadFailed(let error):
            return "Ghostty could not reload the configuration: \(error)"
        case .effectiveRollbackFailed(let primary, let rollback):
            return
                "Ghostty reload failed: \(primary). The previous effective configuration could not be restored: \(rollback)"
        case .watcherFailed(.openFailed(let path, let code)):
            return "The configuration file could not be watched at \(path) (POSIX error \(code))."
        }
    }
}
