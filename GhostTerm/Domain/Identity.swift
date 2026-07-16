import Foundation

struct PaneID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct TabID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct WorkspaceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
