import AppKit
import Sparkle
import Synchronization

enum UpdateChannel: String, CaseIterable, Sendable {
    case stable
    case beta
}

@MainActor
final class UpdateManager {
    private let updater: SPUUpdater
    private let userDriver: SPUStandardUserDriver
    private let feedURLProvider: FeedURLProvider

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    init(
        defaultFeedURL: URL,
        betaFeedURL: URL?,
        initialChannel: UpdateChannel
    ) {
        let feedURLProvider = FeedURLProvider(
            defaultFeedURL: defaultFeedURL,
            betaFeedURL: betaFeedURL,
            initialChannel: initialChannel
        )

        self.feedURLProvider = feedURLProvider

        userDriver = SPUStandardUserDriver(
            hostBundle: .main,
            delegate: nil
        )
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: feedURLProvider
        )

        do {
            try updater.start()
        } catch {
            // Non-fatal: updates are best-effort
            NSLog("QuickTTY: failed to start updater: \(error)")
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func setChannel(_ newChannel: UpdateChannel) {
        feedURLProvider.setChannel(newChannel)
    }
}

private final class FeedURLProvider: NSObject, SPUUpdaterDelegate {
    private let defaultFeedURL: URL
    private let betaFeedURL: URL?
    private let channelLock = Mutex(UpdateChannel.stable)

    init(
        defaultFeedURL: URL,
        betaFeedURL: URL?,
        initialChannel: UpdateChannel
    ) {
        self.defaultFeedURL = defaultFeedURL
        self.betaFeedURL = betaFeedURL
        super.init()
        channelLock.withLock { $0 = initialChannel }
    }

    func setChannel(_ channel: UpdateChannel) {
        channelLock.withLock { $0 = channel }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = channelLock.withLock { $0 }
        switch channel {
        case .stable:
            return defaultFeedURL.absoluteString
        case .beta:
            return betaFeedURL?.absoluteString ?? defaultFeedURL.absoluteString
        }
    }
}
