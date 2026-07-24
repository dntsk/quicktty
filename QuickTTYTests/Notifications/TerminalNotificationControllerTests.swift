import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct TerminalNotificationControllerTests {
    @Test
    func destinationUserInfoIsVersionedUUIDOnlyAndRoundTripsExactly() throws {
        let destination = makeDestination()

        #expect(
            destination.userInfo.keys.sorted() == ["paneID", "tabID", "version", "workspaceID"])
        #expect(destination.userInfo["version"] == "1")
        #expect(destination.userInfo["workspaceID"] == destination.workspaceID.rawValue.uuidString)
        #expect(destination.userInfo["tabID"] == destination.tabID.rawValue.uuidString)
        #expect(destination.userInfo["paneID"] == destination.paneID.rawValue.uuidString)
        #expect(TerminalDestination(userInfo: destination.userInfo) == destination)
        #expect(
            TerminalDestination(userInfo: destination.userInfo.merging(["extra": "value"]) { $1 })
                == nil)
        #expect(TerminalDestination(userInfo: ["version": "1"]) == nil)
    }

    @Test
    func eligibilityUsesExactCompletionThresholdAndImmediateAttentionStates() {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let destinations = DestinationRegistry()
        let controller = makeController(client: client, registry: destinations)
        let shortPaneID = destinations.addDestination().paneID
        let exactPaneID = destinations.addDestination().paneID
        let waitingPaneID = destinations.addDestination().paneID
        let failedPaneID = destinations.addDestination().paneID
        let clearedPaneID = destinations.addDestination().paneID

        controller.handle(.completed(paneID: shortPaneID, elapsed: 4.999))
        controller.handle(.completed(paneID: exactPaneID, elapsed: 5.0))
        controller.handle(.waiting(paneID: waitingPaneID))
        controller.handle(.failed(paneID: failedPaneID))
        controller.handle(.cleared(paneID: clearedPaneID))

        #expect(client.authorizationStatusCallCount == 1)
        #expect(
            client.addedRequests.map(\.body) == [
                "A terminal task completed.",
                "A terminal task needs attention.",
                "A terminal task failed.",
            ])
    }

    @Test
    func shortSuppressedDisabledAndStaleEffectsDoNotCheckAuthorization() {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let registry = DestinationRegistry()
        let short = registry.addDestination()
        let suppressed = registry.addDestination()
        let disabled = registry.addDestination()
        let stalePaneID = PaneID()
        let context = NotificationTestContext()
        context.suppressedDestinations = [suppressed]
        let controller = makeController(
            client: client,
            registry: registry,
            enabled: { context.enabled },
            suppressed: { context.suppressedDestinations.contains($0) }
        )

        controller.handle(.completed(paneID: short.paneID, elapsed: 4.999))
        controller.handle(.waiting(paneID: suppressed.paneID))
        context.enabled = false
        controller.handle(.failed(paneID: disabled.paneID))
        context.enabled = true
        controller.handle(.waiting(paneID: stalePaneID))

        #expect(client.authorizationStatusCallCount == 0)
        #expect(client.authorizationRequestCallCount == 0)
        #expect(client.addedRequests.isEmpty)
    }

    @Test
    func suppressionRequiresKeyWindowAndExactSelectedWorkspaceAndTabButIgnoresPane() {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let registry = DestinationRegistry()
        let source = registry.addDestination()
        let context = NotificationTestContext()
        context.isKey = true
        context.selectedWorkspaceID = source.workspaceID
        context.selectedTabID = source.tabID
        let controller = makeController(
            client: client,
            registry: registry,
            suppressed: { destination in
                context.isKey && context.selectedWorkspaceID == destination.workspaceID
                    && context.selectedTabID == destination.tabID
            }
        )

        controller.handle(.waiting(paneID: source.paneID))
        controller.handle(.failed(paneID: source.paneID))
        #expect(client.authorizationStatusCallCount == 0)

        context.isKey = false
        controller.handle(.waiting(paneID: source.paneID))
        context.isKey = true
        context.selectedWorkspaceID = WorkspaceID()
        controller.handle(.failed(paneID: source.paneID))
        context.selectedWorkspaceID = source.workspaceID
        context.selectedTabID = TabID()
        controller.handle(.completed(paneID: source.paneID, elapsed: 5))

        #expect(client.addedRequests.count == 3)
    }

    @Test
    func concurrentEligibleEffectsShareOneAuthorizationAndEachDeliverOnce() {
        let client = FakeTerminalNotificationClient(status: nil)
        let registry = DestinationRegistry()
        let waiting = registry.addDestination()
        let failed = registry.addDestination()
        let controller = makeController(client: client, registry: registry)

        controller.handle(.waiting(paneID: waiting.paneID))
        controller.handle(.waiting(paneID: waiting.paneID))
        controller.handle(.failed(paneID: failed.paneID))

        #expect(client.authorizationStatusCallCount == 1)
        #expect(client.authorizationRequestCallCount == 0)
        client.resolveAuthorizationStatus(.notDetermined)
        #expect(client.authorizationRequestCallCount == 1)
        client.resolveAuthorizationRequest(.success(true))

        #expect(client.addedRequests.count == 2)
        #expect(
            Set(client.addedRequests.compactMap { TerminalDestination(userInfo: $0.userInfo) })
                == [waiting, failed]
        )
    }

    @Test
    func authorizedProvisionalAndEphemeralStatusesDeliverWithoutPrompt() {
        for status in [
            TerminalNotificationAuthorizationStatus.authorized,
            .provisional,
            .ephemeral,
        ] {
            let client = FakeTerminalNotificationClient(status: status)
            let registry = DestinationRegistry()
            let destination = registry.addDestination()
            let controller = makeController(client: client, registry: registry)

            controller.handle(.waiting(paneID: destination.paneID))

            #expect(client.authorizationRequestCallCount == 0)
            #expect(client.addedRequests.count == 1)
        }
    }

    @Test
    func deniedAuthorizationIsRememberedWithoutRepeatedPrompt() {
        let client = FakeTerminalNotificationClient(status: .notDetermined)
        let registry = DestinationRegistry()
        let first = registry.addDestination()
        let second = registry.addDestination()
        let controller = makeController(client: client, registry: registry)

        controller.handle(.waiting(paneID: first.paneID))
        #expect(client.authorizationRequestCallCount == 1)
        client.resolveAuthorizationRequest(.success(false))
        controller.handle(.failed(paneID: second.paneID))

        #expect(client.authorizationStatusCallCount == 1)
        #expect(client.authorizationRequestCallCount == 1)
        #expect(client.addedRequests.isEmpty)
    }

    @Test
    func destinationThatBecomesStaleBeforePromptDoesNotRequestAuthorization() {
        let client = FakeTerminalNotificationClient(status: nil)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let controller = makeController(client: client, registry: registry)

        controller.handle(.waiting(paneID: destination.paneID))
        registry.remove(destination.paneID)
        client.resolveAuthorizationStatus(.notDetermined)

        #expect(client.authorizationRequestCallCount == 0)
        #expect(client.addedRequests.isEmpty)
    }

    @Test
    func waitingToWorkingWhileAuthorizationIsUnresolvedDoesNotPromptOrDeliver() {
        let client = FakeTerminalNotificationClient(status: nil)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let context = NotificationTestContext()
        context.currentEffects[destination.paneID] = .waiting(paneID: destination.paneID)
        let controller = makeController(
            client: client,
            registry: registry,
            currentEffect: { context.currentEffects[$0.paneID] == $0 }
        )

        controller.handle(.waiting(paneID: destination.paneID))
        context.currentEffects[destination.paneID] = nil
        client.resolveAuthorizationStatus(.notDetermined)

        #expect(client.authorizationRequestCallCount == 0)
        #expect(client.addedRequests.isEmpty)
        #expect(controller.trackedNotificationCountForTesting == 0)
    }

    @Test
    func waitingToRemoveWhileAuthorizationIsRequestingDoesNotDeliver() {
        let client = FakeTerminalNotificationClient(status: .notDetermined)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let context = NotificationTestContext()
        context.currentEffects[destination.paneID] = .waiting(paneID: destination.paneID)
        let controller = makeController(
            client: client,
            registry: registry,
            currentEffect: { context.currentEffects[$0.paneID] == $0 }
        )

        controller.handle(.waiting(paneID: destination.paneID))
        #expect(client.authorizationRequestCallCount == 1)
        context.currentEffects[destination.paneID] = nil
        client.resolveAuthorizationRequest(.success(true))

        #expect(client.addedRequests.isEmpty)
        #expect(controller.trackedNotificationCountForTesting == 0)
    }

    @Test
    func staleOrDisabledDestinationWhileAuthorizationWaitsIsDiscarded() {
        let client = FakeTerminalNotificationClient(status: .notDetermined)
        let registry = DestinationRegistry()
        let stale = registry.addDestination()
        let disabled = registry.addDestination()
        let context = NotificationTestContext()
        let controller = makeController(
            client: client,
            registry: registry,
            enabled: { context.enabled }
        )

        controller.handle(.waiting(paneID: stale.paneID))
        controller.handle(.failed(paneID: disabled.paneID))
        registry.remove(stale.paneID)
        context.enabled = false
        client.resolveAuthorizationRequest(.success(true))

        #expect(client.addedRequests.isEmpty)
    }

    @Test
    func manyEventsForOnePaneKeepOneMappingAndDefaultClickConsumesIt() throws {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let context = NotificationTestContext()
        var activations: [TerminalDestination] = []
        let controller = makeController(
            client: client,
            registry: registry,
            currentEffect: { context.currentEffects[$0.paneID] == $0 },
            activate: { activations.append($0) }
        )

        for index in 0..<100 {
            let effect: TerminalActivityEffect =
                index.isMultiple(of: 2)
                ? .waiting(paneID: destination.paneID)
                : .failed(paneID: destination.paneID)
            context.currentEffects[destination.paneID] = effect
            controller.handle(effect)
            #expect(controller.trackedNotificationCountForTesting <= 1)
            #expect(controller.destinationMappingCountForTesting <= 1)
        }
        let request = try #require(client.addedRequests.last)

        controller.handleDefaultResponse(identifier: request.identifier, userInfo: request.userInfo)
        controller.handleDefaultResponse(identifier: request.identifier, userInfo: request.userInfo)

        #expect(activations == [destination])
        #expect(controller.trackedNotificationCountForTesting == 0)
        #expect(controller.destinationMappingCountForTesting == 0)
    }

    @Test
    func invalidationRemovesPendingAndDeliveredMappings() {
        let pendingClient = FakeTerminalNotificationClient(status: nil)
        let pendingRegistry = DestinationRegistry()
        let pendingDestination = pendingRegistry.addDestination()
        let pendingController = makeController(client: pendingClient, registry: pendingRegistry)
        pendingController.handle(.waiting(paneID: pendingDestination.paneID))
        #expect(pendingController.trackedNotificationCountForTesting == 1)

        pendingController.invalidate(paneID: pendingDestination.paneID)
        #expect(pendingController.trackedNotificationCountForTesting == 0)

        let deliveredClient = FakeTerminalNotificationClient(status: .authorized)
        let deliveredRegistry = DestinationRegistry()
        let deliveredDestination = deliveredRegistry.addDestination()
        let deliveredController = makeController(
            client: deliveredClient,
            registry: deliveredRegistry
        )
        deliveredController.handle(.failed(paneID: deliveredDestination.paneID))
        #expect(deliveredController.destinationMappingCountForTesting == 1)

        deliveredController.invalidate(paneID: deliveredDestination.paneID)
        #expect(deliveredController.trackedNotificationCountForTesting == 0)
        #expect(deliveredController.destinationMappingCountForTesting == 0)
    }

    @Test
    func lateSupersededAddFailureCannotRemoveNewPaneMapping() throws {
        let client = FakeTerminalNotificationClient(status: .authorized)
        client.addResult = nil
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let context = NotificationTestContext()
        var logged: [TerminalNotificationClientError] = []
        let controller = makeController(
            client: client,
            registry: registry,
            currentEffect: { context.currentEffects[$0.paneID] == $0 },
            logger: { logged.append($0) }
        )
        let waiting = TerminalActivityEffect.waiting(paneID: destination.paneID)
        context.currentEffects[destination.paneID] = waiting
        controller.handle(waiting)
        let failed = TerminalActivityEffect.failed(paneID: destination.paneID)
        context.currentEffects[destination.paneID] = failed
        controller.handle(failed)
        let latestRequest = try #require(client.addedRequests.last)

        client.resolveNextAdd(.failure(TerminalNotificationClientError(domain: "late", code: 1)))

        #expect(logged.isEmpty)
        #expect(controller.destinationMappingCountForTesting == 1)
        var decisions: [Bool] = []
        controller.willPresent(
            identifier: latestRequest.identifier,
            userInfo: latestRequest.userInfo
        ) { decisions.append($0) }
        #expect(decisions == [true])
    }

    @Test
    func payloadIsGenericAndLoggerReceivesOnlyErrorDomainAndCode() throws {
        let error = TerminalNotificationClientError(domain: "UNErrorDomain", code: 7)
        let client = FakeTerminalNotificationClient(status: .authorized)
        client.addResult = .failure(error)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        var logged: [TerminalNotificationClientError] = []
        let controller = makeController(
            client: client,
            registry: registry,
            logger: { logged.append($0) }
        )

        controller.handle(.failed(paneID: destination.paneID))
        let request = try #require(client.addedRequests.first)

        #expect(request.title == "QuickTTY")
        #expect(request.body == "A terminal task failed.")
        #expect(request.userInfo == destination.userInfo)
        #expect(!request.title.contains("/"))
        #expect(!request.body.contains("/"))
        #expect(logged == [error])
    }

    @Test
    func foregroundPresentationRechecksStateAndCompletesExactlyOnce() throws {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        let context = NotificationTestContext()
        let effect = TerminalActivityEffect.waiting(paneID: destination.paneID)
        context.currentEffects[destination.paneID] = effect
        let controller = makeController(
            client: client,
            registry: registry,
            enabled: { context.enabled },
            currentEffect: { context.currentEffects[$0.paneID] == $0 },
            suppressed: { _ in context.isSuppressed }
        )
        controller.handle(effect)
        let request = try #require(client.addedRequests.first)
        var decisions: [Bool] = []

        controller.willPresent(identifier: request.identifier, userInfo: request.userInfo) {
            decisions.append($0)
        }
        context.currentEffects[destination.paneID] = nil
        controller.willPresent(identifier: request.identifier, userInfo: request.userInfo) {
            decisions.append($0)
        }
        context.currentEffects[destination.paneID] = effect
        context.isSuppressed = true
        controller.willPresent(identifier: request.identifier, userInfo: request.userInfo) {
            decisions.append($0)
        }
        context.isSuppressed = false
        context.enabled = false
        controller.willPresent(identifier: request.identifier, userInfo: request.userInfo) {
            decisions.append($0)
        }
        context.enabled = true
        registry.remove(destination.paneID)
        controller.willPresent(identifier: request.identifier, userInfo: request.userInfo) {
            decisions.append($0)
        }
        controller.willPresent(identifier: "missing", userInfo: request.userInfo) {
            decisions.append($0)
        }

        #expect(decisions == [true, false, false, false, false, false])
    }

    @Test
    func defaultClickActivatesExactMappedDestinationAndInvalidOrShutdownClicksNoOp() throws {
        let client = FakeTerminalNotificationClient(status: .authorized)
        let registry = DestinationRegistry()
        let destination = registry.addDestination()
        var activations: [TerminalDestination] = []
        let controller = makeController(
            client: client,
            registry: registry,
            activate: { activations.append($0) }
        )
        controller.handle(.waiting(paneID: destination.paneID))
        let request = try #require(client.addedRequests.first)

        controller.handleDefaultResponse(identifier: request.identifier, userInfo: request.userInfo)
        #expect(controller.destinationMappingCountForTesting == 0)
        controller.handleDefaultResponse(
            identifier: request.identifier,
            userInfo: request.userInfo.merging(["paneID": UUID().uuidString]) { $1 }
        )
        controller.handleDefaultResponse(identifier: "missing", userInfo: request.userInfo)
        controller.shutdown()
        controller.handleDefaultResponse(identifier: request.identifier, userInfo: request.userInfo)

        #expect(activations == [destination])
    }

    @Test
    func invalidationAndShutdownMakeLateAuthorizationAndAddCallbacksNoOps() {
        let addClient = FakeTerminalNotificationClient(status: .authorized)
        addClient.addResult = nil
        let addRegistry = DestinationRegistry()
        let addDestination = addRegistry.addDestination()
        var logged: [TerminalNotificationClientError] = []
        let addController = makeController(
            client: addClient,
            registry: addRegistry,
            logger: { logged.append($0) }
        )
        addController.handle(.waiting(paneID: addDestination.paneID))
        addController.invalidate(paneID: addDestination.paneID)
        addClient.resolveAdds(.failure(TerminalNotificationClientError(domain: "late", code: 1)))
        #expect(logged.isEmpty)
        #expect(addController.destinationMappingCountForTesting == 0)

        let client = FakeTerminalNotificationClient(status: .notDetermined)
        let registry = DestinationRegistry()
        let invalidated = registry.addDestination()
        let controller = makeController(client: client, registry: registry)

        controller.handle(.waiting(paneID: invalidated.paneID))
        controller.invalidate(paneID: invalidated.paneID)
        client.resolveAuthorizationRequest(.success(true))
        #expect(client.addedRequests.isEmpty)

        let lateClient = FakeTerminalNotificationClient(status: nil)
        let lateRegistry = DestinationRegistry()
        let late = lateRegistry.addDestination()
        let lateController = makeController(client: lateClient, registry: lateRegistry)
        lateController.handle(.failed(paneID: late.paneID))
        lateController.shutdown()
        lateClient.resolveAuthorizationStatus(.authorized)
        #expect(lateClient.addedRequests.isEmpty)
    }

    private func makeController(
        client: FakeTerminalNotificationClient,
        registry: DestinationRegistry,
        enabled: @escaping @MainActor () -> Bool = { true },
        currentEffect: @escaping @MainActor (TerminalActivityEffect) -> Bool = { _ in true },
        suppressed: @escaping @MainActor (TerminalDestination) -> Bool = { _ in false },
        activate: @escaping @MainActor (TerminalDestination) -> Void = { _ in },
        logger: @escaping @MainActor (TerminalNotificationClientError) -> Void = { _ in }
    ) -> TerminalNotificationController {
        TerminalNotificationController(
            client: client,
            desktopNotificationsEnabled: enabled,
            destinationProvider: { registry.destinations[$0] },
            isCurrentEffect: currentEffect,
            isSuppressed: suppressed,
            activateDestination: activate,
            logger: logger
        )
    }

    private func makeDestination() -> TerminalDestination {
        TerminalDestination(workspaceID: WorkspaceID(), tabID: TabID(), paneID: PaneID())
    }
}

@MainActor
private final class NotificationTestContext {
    var enabled = true
    var isSuppressed = false
    var suppressedDestinations: Set<TerminalDestination> = []
    var isKey = false
    var selectedWorkspaceID: WorkspaceID?
    var selectedTabID: TabID?
    var currentEffects: [PaneID: TerminalActivityEffect] = [:]
}

@MainActor
private final class DestinationRegistry {
    var destinations: [PaneID: TerminalDestination] = [:]

    @discardableResult
    func addDestination() -> TerminalDestination {
        let destination = TerminalDestination(
            workspaceID: WorkspaceID(),
            tabID: TabID(),
            paneID: PaneID()
        )
        destinations[destination.paneID] = destination
        return destination
    }

    func replace(_ paneID: PaneID, with destination: TerminalDestination) {
        destinations[paneID] = destination
    }

    func remove(_ paneID: PaneID) {
        destinations.removeValue(forKey: paneID)
    }
}

@MainActor
private final class FakeTerminalNotificationClient: TerminalNotificationClient {
    private let immediateStatus: TerminalNotificationAuthorizationStatus?
    private var statusCompletions:
        [@MainActor @Sendable (TerminalNotificationAuthorizationStatus) -> Void] = []
    private var authorizationCompletions:
        [@MainActor @Sendable (Result<Bool, TerminalNotificationClientError>) -> Void] = []
    private var addCompletions:
        [@MainActor @Sendable (Result<Void, TerminalNotificationClientError>) -> Void] = []

    private(set) var authorizationStatusCallCount = 0
    private(set) var authorizationRequestCallCount = 0
    private(set) var addedRequests: [TerminalNotificationRequest] = []
    var addResult: Result<Void, TerminalNotificationClientError>? = .success(())

    init(status: TerminalNotificationAuthorizationStatus?) {
        immediateStatus = status
    }

    func authorizationStatus(
        completion:
            @escaping @MainActor @Sendable (
                TerminalNotificationAuthorizationStatus
            ) -> Void
    ) {
        authorizationStatusCallCount += 1
        if let immediateStatus {
            completion(immediateStatus)
        } else {
            statusCompletions.append(completion)
        }
    }

    func requestAuthorization(
        completion:
            @escaping @MainActor @Sendable (
                Result<Bool, TerminalNotificationClientError>
            ) -> Void
    ) {
        authorizationRequestCallCount += 1
        authorizationCompletions.append(completion)
    }

    func add(
        _ request: TerminalNotificationRequest,
        completion:
            @escaping @MainActor @Sendable (
                Result<Void, TerminalNotificationClientError>
            ) -> Void
    ) {
        addedRequests.append(request)
        if let addResult {
            completion(addResult)
        } else {
            addCompletions.append(completion)
        }
    }

    func resolveAuthorizationStatus(_ status: TerminalNotificationAuthorizationStatus) {
        let completions = statusCompletions
        statusCompletions.removeAll()
        for completion in completions {
            completion(status)
        }
    }

    func resolveAuthorizationRequest(
        _ result: Result<Bool, TerminalNotificationClientError>
    ) {
        let completions = authorizationCompletions
        authorizationCompletions.removeAll()
        for completion in completions {
            completion(result)
        }
    }

    func resolveNextAdd(_ result: Result<Void, TerminalNotificationClientError>) {
        guard !addCompletions.isEmpty else { return }
        addCompletions.removeFirst()(result)
    }

    func resolveAdds(_ result: Result<Void, TerminalNotificationClientError>) {
        let completions = addCompletions
        addCompletions.removeAll()
        for completion in completions {
            completion(result)
        }
    }
}
