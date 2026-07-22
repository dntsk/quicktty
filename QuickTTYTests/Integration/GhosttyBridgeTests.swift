import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct GhosttyBridgeTests {
    @Test
    func configurationSourceDistinguishesBuiltInDefaultsFromExplicitFile() throws {
        let fixture = try TemporaryConfig()
        defer { fixture.remove() }

        let builtInConfiguration = try GhosttyConfiguration(configURL: nil)
        let fileConfiguration = try GhosttyConfiguration(configURL: fixture.url)

        #expect(builtInConfiguration.source == .builtInDefaults)
        #expect(fileConfiguration.source == .file(fixture.url))
    }

    @Test
    func explicitConfigLoadsRecursiveIncludes() throws {
        let fixture = try TemporaryConfig(contents: "config-file = included-config\n")
        defer { fixture.remove() }
        let includedURL = fixture.directoryURL.appending(path: "included-config")
        try Data("not-a-ghostty-option = true\n".utf8).write(to: includedURL)

        let configuration = try GhosttyConfiguration(configURL: fixture.url)

        #expect(!configuration.diagnostics.isEmpty)
    }

    @Test
    func productionBootstrapUsesBuiltInDefaults() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        #expect(bridge.isReady)
        #expect(bridge.diagnostics.isEmpty)
    }

    @Test
    func initializesWithMinimalConfig() throws {
        let fixture = try TemporaryConfig()
        defer { fixture.remove() }

        let bridge = try GhosttyBridge(configURL: fixture.url)
        defer { bridge.shutdown() }

        #expect(bridge.isReady)
        #expect(bridge.diagnostics.isEmpty)
    }

    @Test
    func diagnosticsRemainStableAfterConfigurationTeardown() throws {
        let fixture = try TemporaryConfig(contents: "not-a-ghostty-option = true\n")
        defer { fixture.remove() }

        let bridge = try GhosttyBridge(configURL: fixture.url)
        let diagnostics = bridge.diagnostics

        #expect(bridge.isReady)
        #expect(!diagnostics.isEmpty)

        bridge.shutdown()

        #expect(bridge.diagnostics == diagnostics)
    }

    @Test
    func shutdownIsIdempotent() throws {
        let fixture = try TemporaryConfig()
        defer { fixture.remove() }
        let bridge = try GhosttyBridge(configURL: fixture.url)

        bridge.shutdown()
        bridge.shutdown()

        #expect(!bridge.isReady)
    }

    @Test
    func configurationExtractsChromePaletteFromFinalizedHandle() throws {
        let fixture = try TemporaryConfig(
            contents: "background = 112233\nforeground = ddeeff\n"
        )
        defer { fixture.remove() }

        let configuration = try GhosttyConfiguration(configURL: fixture.url)

        #expect(
            configuration.chromePalette
                == GhosttyChromePalette(
                    background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
                    foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
                )
        )
    }

    @Test
    func reloadReplacesChromePaletteTransactionally() throws {
        let initial = try TemporaryConfig(contents: "background = 112233\nforeground = ddeeff\n")
        let replacement = try TemporaryConfig(
            contents: "background = 445566\nforeground = aabbcc\n")
        defer {
            initial.remove()
            replacement.remove()
        }
        let bridge = try GhosttyBridge(configURL: initial.url)
        defer { bridge.shutdown() }

        try bridge.reloadConfig(at: replacement.url)

        #expect(
            bridge.chromePalette
                == GhosttyChromePalette(
                    background: GhosttyRGB(red: 0x44, green: 0x55, blue: 0x66),
                    foreground: GhosttyRGB(red: 0xAA, green: 0xBB, blue: 0xCC)
                )
        )
    }

    @Test
    func invalidReloadIsRejectedAndNextValidReloadQueuesConfigChanged() async throws {
        let initial = try TemporaryConfig(contents: "background-opacity = 0.5\n")
        let malformed = try TemporaryConfig(contents: "not-a-ghostty-option = true\n")
        let replacement = try TemporaryConfig(contents: "background-opacity = 0.75\n")
        defer {
            initial.remove()
            malformed.remove()
            replacement.remove()
        }

        let (actions, continuation) = AsyncStream.makeStream(of: GhosttyRuntimeAction.self)
        defer { continuation.finish() }
        let bridge = try GhosttyBridge(configURL: initial.url) { action in
            continuation.yield(action)
        }
        defer { bridge.shutdown() }

        do {
            try bridge.reloadConfig(at: malformed.url)
            Issue.record("Malformed replacement configuration was accepted")
        } catch let error as GhosttyBridgeError {
            #expect(error == .invalidConfiguration(bridge.diagnostics))
        }

        #expect(bridge.isReady)
        #expect(!bridge.diagnostics.isEmpty)

        try bridge.reloadConfig(at: replacement.url)
        let action = try await firstRuntimeAction(from: actions, timeout: .seconds(2))

        #expect(bridge.isReady)
        #expect(bridge.diagnostics.isEmpty)
        #expect(action == .configChanged)
    }

    @Test
    func callbackContextRetainedOwnershipEndsAtShutdown() throws {
        let fixture = try TemporaryConfig()
        defer { fixture.remove() }
        let initialContextCount = GhosttyBridge.callbackContextCountForTesting
        let bridge = try GhosttyBridge(configURL: fixture.url)

        #expect(GhosttyBridge.callbackContextCountForTesting == initialContextCount + 1)

        bridge.shutdown()

        #expect(GhosttyBridge.callbackContextCountForTesting == initialContextCount)
    }

    @Test
    func callbackContextDoesNotRetainBridgeAndDeinitIsSafeFallback() throws {
        let fixture = try TemporaryConfig()
        defer { fixture.remove() }
        let initialContextCount = GhosttyBridge.callbackContextCountForTesting

        weak var weakBridge: GhosttyBridge?
        var bridge: GhosttyBridge? = try GhosttyBridge(configURL: fixture.url)
        weakBridge = bridge

        #expect(GhosttyBridge.callbackContextCountForTesting == initialContextCount + 1)

        bridge = nil

        #expect(weakBridge == nil)
        #expect(GhosttyBridge.callbackContextCountForTesting == initialContextCount)
    }

    @Test
    func bootstrapResultIsStableAcrossRepeatedCalls() {
        let firstResult = GhosttyBridge.bootstrapRuntime()
        let secondResult = GhosttyBridge.bootstrapRuntime()

        #expect(firstResult)
        #expect(secondResult == firstResult)
    }

    @Test
    func runtimeActionTagsMatchPinnedHeader() {
        #expect(GhosttyBridge.runtimeActionTagsMatchPinnedHeader)
    }

    @Test
    func supportedRuntimeActionIsQueuedAsynchronously() async throws {
        let (deliveries, continuation) = AsyncStream.makeStream(of: Bool.self)
        defer { continuation.finish() }
        var deliveredAction: GhosttyRuntimeAction?
        let bridge = try GhosttyBridge { action in
            deliveredAction = action
        }
        defer { bridge.shutdown() }

        let handled = bridge.scheduleRuntimeActionForTesting(.openConfig) { delivered in
            continuation.yield(delivered)
        }

        #expect(handled)
        #expect(deliveredAction == nil)

        let delivered = try await firstRuntimeActionDelivery(
            from: deliveries,
            timeout: .seconds(2)
        )

        #expect(delivered)
        #expect(deliveredAction == .openConfig)
    }

    @Test
    func runtimeActionWithoutHandlerIsNotConsumed() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        #expect(!bridge.scheduleRuntimeActionForTesting(.openConfig))
    }

    @Test
    func unsupportedRuntimeActionIsNotDispatched() throws {
        let bridge = try GhosttyBridge { _ in
            Issue.record("Unknown runtime action was dispatched")
        }
        defer { bridge.shutdown() }

        let handled = bridge.scheduleRuntimeActionForTesting(.unknown(rawValue: .max)) { _ in
            Issue.record("Unknown runtime action queued a completion")
        }

        #expect(!handled)
    }

    @Test
    func queuedRuntimeActionIsDroppedAfterShutdown() async throws {
        let (deliveries, continuation) = AsyncStream.makeStream(of: Bool.self)
        defer { continuation.finish() }
        var deliveredAction: GhosttyRuntimeAction?
        let bridge = try GhosttyBridge { action in
            deliveredAction = action
        }

        let handled = bridge.scheduleRuntimeActionForTesting(.openConfig) { delivered in
            continuation.yield(delivered)
        }
        bridge.shutdown()

        #expect(handled)
        #expect(deliveredAction == nil)

        let delivered = try await firstRuntimeActionDelivery(
            from: deliveries,
            timeout: .seconds(2)
        )

        #expect(!delivered)
        #expect(deliveredAction == nil)
    }

    @Test
    func realCReloadActionConversionPreservesSoftPayload() {
        let hardReload = GhosttyBridge.runtimeReloadActionForTesting(soft: false)
        let softReload = GhosttyBridge.runtimeReloadActionForTesting(soft: true)

        #expect(hardReload == .reloadConfig(soft: false))
        #expect(softReload == .reloadConfig(soft: true))
    }
}

private enum RuntimeActionTestError: Error {
    case eventStreamEnded
    case timeout
}

private func firstRuntimeAction(
    from stream: AsyncStream<GhosttyRuntimeAction>,
    timeout: Duration
) async throws -> GhosttyRuntimeAction {
    try await withThrowingTaskGroup(of: GhosttyRuntimeAction.self) { group in
        group.addTask {
            for await action in stream {
                return action
            }
            throw RuntimeActionTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RuntimeActionTestError.timeout
        }

        guard let action = try await group.next() else {
            throw RuntimeActionTestError.eventStreamEnded
        }
        group.cancelAll()
        return action
    }
}

private func firstRuntimeActionDelivery(
    from stream: AsyncStream<Bool>,
    timeout: Duration
) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await delivered in stream {
                return delivered
            }
            throw RuntimeActionTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RuntimeActionTestError.timeout
        }

        guard let delivered = try await group.next() else {
            throw RuntimeActionTestError.eventStreamEnded
        }
        group.cancelAll()
        return delivered
    }
}

private struct TemporaryConfig {
    let directoryURL: URL
    let url: URL

    init(contents: String = "# GhostTerm integration test\n") throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        url = directoryURL.appending(path: "config")
        try Data(contents.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
