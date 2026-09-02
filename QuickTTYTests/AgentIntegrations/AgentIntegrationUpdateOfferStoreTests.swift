import Foundation
import Testing

@testable import QuickTTY

@MainActor
struct AgentIntegrationUpdateOfferStoreTests {
    @Test
    func exactBuildIsOfferedOnce() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(build: "100", defaults: suite.defaults)
        )

        #expect(store.shouldOffer)
        store.recordOffered()
        #expect(!store.shouldOffer)
        #expect(
            AgentIntegrationUpdateOfferStore(build: "100", defaults: suite.defaults)?.shouldOffer
                == false
        )
    }

    @Test
    func recordingBeforeCancellationIsIdempotent() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        let store = try #require(
            AgentIntegrationUpdateOfferStore(build: "cancelled-build", defaults: suite.defaults)
        )

        store.recordOffered()
        store.recordOffered()

        #expect(!store.shouldOffer)
    }

    @Test
    func nextBuildCanOfferAgain() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }
        let first = try #require(
            AgentIntegrationUpdateOfferStore(build: "100", defaults: suite.defaults)
        )
        first.recordOffered()

        let next = try #require(
            AgentIntegrationUpdateOfferStore(build: "101", defaults: suite.defaults)
        )

        #expect(next.shouldOffer)
    }

    @Test
    func invalidBuildsDisableOffers() throws {
        let suite = try makeDefaults()
        defer { suite.remove() }

        #expect(AgentIntegrationUpdateOfferStore(build: "", defaults: suite.defaults) == nil)
        #expect(
            AgentIntegrationUpdateOfferStore(build: "12\n3", defaults: suite.defaults) == nil
        )
        #expect(
            AgentIntegrationUpdateOfferStore(
                build: String(repeating: "1", count: 129),
                defaults: suite.defaults
            ) == nil
        )
    }

    private func makeDefaults() throws -> DefaultsSuite {
        let name = "AgentIntegrationUpdateOfferStoreTests.\(UUID().uuidString)"
        return DefaultsSuite(
            name: name,
            defaults: try #require(UserDefaults(suiteName: name))
        )
    }
}

@MainActor
private struct DefaultsSuite {
    let name: String
    let defaults: UserDefaults

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}
