import Darwin
import Dispatch
import Foundation

@MainActor
final class ConfigFileWatcher {
    typealias Scheduler =
        (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    struct EventSource {
        let start:
            @MainActor (URL, @escaping @MainActor @Sendable () -> Void) throws
                -> @MainActor () -> Void

        static let production = EventSource { url, handler in
            let descriptor = Darwin.open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                throw ConfigFileWatcherError.openFailed(path: url.path, code: errno)
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend],
                queue: .main
            )
            source.setEventHandler {
                handler()
            }
            source.setCancelHandler {
                _ = Darwin.close(descriptor)
            }
            source.resume()
            return {
                source.cancel()
            }
        }
    }

    private let url: URL
    private let scheduler: Scheduler
    private let eventSource: EventSource
    private let onChange: @MainActor () -> Void
    private let onError: @MainActor (ConfigFileWatcherError) -> Void
    private var cancelObservation: (@MainActor () -> Void)?
    private var cancelScheduledChange: (@MainActor () -> Void)?
    private var generation: UInt = 0
    private var isStarted = false

    init(
        url: URL,
        scheduler: Scheduler? = nil,
        eventSource: EventSource = .production,
        onChange: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (ConfigFileWatcherError) -> Void = { _ in }
    ) {
        self.url = url
        self.scheduler = scheduler ?? Self.productionScheduler
        self.eventSource = eventSource
        self.onChange = onChange
        self.onError = onError
    }

    isolated deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }
        isStarted = true
        do {
            try beginObservation()
        } catch {
            isStarted = false
            throw error
        }
    }

    func stop() {
        isStarted = false
        generation &+= 1
        cancelScheduledChange?()
        cancelScheduledChange = nil
        cancelObservation?()
        cancelObservation = nil
    }

    private func beginObservation() throws {
        cancelObservation = try eventSource.start(url) { [weak self] in
            self?.receiveEvent()
        }
    }

    private func receiveEvent() {
        guard isStarted else { return }
        generation &+= 1
        let scheduledGeneration = generation
        cancelScheduledChange?()
        cancelScheduledChange = scheduler { [weak self] in
            guard let self, isStarted, generation == scheduledGeneration else { return }
            cancelScheduledChange = nil
            onChange()
            rearmObservation()
        }
    }

    private func rearmObservation() {
        guard isStarted else { return }
        cancelObservation?()
        cancelObservation = nil
        do {
            try beginObservation()
        } catch let error as ConfigFileWatcherError {
            onError(error)
        } catch {
            onError(.openFailed(path: url.path, code: 0))
        }
    }

    private static func productionScheduler(
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            action()
        }
        return {
            task.cancel()
        }
    }
}

enum ConfigFileWatcherError: Error, Equatable, Sendable {
    case openFailed(path: String, code: Int32)
}
