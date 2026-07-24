import Foundation

struct TerminalDestination: Equatable, Hashable, Sendable {
    private static let version = "1"
    private static let keys: Set<String> = ["version", "workspaceID", "tabID", "paneID"]

    let workspaceID: WorkspaceID
    let tabID: TabID
    let paneID: PaneID

    var userInfo: [String: String] {
        [
            "version": Self.version,
            "workspaceID": workspaceID.rawValue.uuidString,
            "tabID": tabID.rawValue.uuidString,
            "paneID": paneID.rawValue.uuidString,
        ]
    }

    init(workspaceID: WorkspaceID, tabID: TabID, paneID: PaneID) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }

    init?(userInfo: [String: String]) {
        guard Set(userInfo.keys) == Self.keys,
            userInfo["version"] == Self.version,
            let workspaceValue = userInfo["workspaceID"],
            let workspaceUUID = UUID(uuidString: workspaceValue),
            let tabValue = userInfo["tabID"],
            let tabUUID = UUID(uuidString: tabValue),
            let paneValue = userInfo["paneID"],
            let paneUUID = UUID(uuidString: paneValue)
        else {
            return nil
        }
        workspaceID = WorkspaceID(rawValue: workspaceUUID)
        tabID = TabID(rawValue: tabUUID)
        paneID = PaneID(rawValue: paneUUID)
    }

    static func userInfo(from value: [AnyHashable: Any]) -> [String: String]? {
        guard value.count == keys.count else { return nil }
        var result: [String: String] = [:]
        for (key, value) in value {
            guard let key = key as? String, let value = value as? String else { return nil }
            result[key] = value
        }
        return result
    }
}
