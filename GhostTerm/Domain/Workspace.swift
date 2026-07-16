import Foundation

struct Workspace: Codable, Equatable, Sendable {
    let id: WorkspaceID
    private(set) var name: String
    var tabs: [TerminalTab]
    var activeTabID: TabID?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case tabs
        case activeTabID
    }

    init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        tabs: [TerminalTab] = [],
        activeTabID: TabID? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tabs = try container.decode([TerminalTab].self, forKey: .tabs)
        activeTabID = try container.decodeIfPresent(TabID.self, forKey: .activeTabID)
    }

    mutating func rename(to name: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
