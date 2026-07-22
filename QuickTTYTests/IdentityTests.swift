import Foundation
import Testing

@testable import QuickTTY

struct IdentityTests {
    @Test
    func paneIDCodableRoundTripPreservesEquality() throws {
        let rawValue = try #require(UUID(uuidString: "8A6BB4C3-0DD8-4E99-BB79-F9DA30D93BD2"))
        let paneID = PaneID(rawValue: rawValue)

        let encoded = try JSONEncoder().encode(paneID)
        let decoded = try JSONDecoder().decode(PaneID.self, from: encoded)

        #expect(decoded == paneID)
        #expect(decoded.rawValue == rawValue)
    }

    @Test
    func tabIDCodableRoundTripPreservesEquality() throws {
        let rawValue = try #require(UUID(uuidString: "D2F3A981-E655-46D5-8CF7-F1B35D237778"))
        let tabID = TabID(rawValue: rawValue)

        let encoded = try JSONEncoder().encode(tabID)
        let decoded = try JSONDecoder().decode(TabID.self, from: encoded)

        #expect(decoded == tabID)
        #expect(decoded.rawValue == rawValue)
    }

    @Test
    func workspaceIDCodableRoundTripPreservesEquality() throws {
        let rawValue = try #require(UUID(uuidString: "2FA0ED6C-85EC-4F4F-8D47-22194F566191"))
        let workspaceID = WorkspaceID(rawValue: rawValue)

        let encoded = try JSONEncoder().encode(workspaceID)
        let decoded = try JSONDecoder().decode(WorkspaceID.self, from: encoded)

        #expect(decoded == workspaceID)
        #expect(decoded.rawValue == rawValue)
    }

    @Test
    func identityTypesGenerateIndependentRawValues() {
        let paneID = PaneID()
        let tabID = TabID()
        let workspaceID = WorkspaceID()

        #expect(paneID.rawValue != tabID.rawValue)
        #expect(paneID.rawValue != workspaceID.rawValue)
        #expect(tabID.rawValue != workspaceID.rawValue)
    }
}
