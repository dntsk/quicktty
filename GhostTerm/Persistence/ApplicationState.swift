import Foundation

struct NormalWindowFrame: Equatable, Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    init?(x: Double, y: Double, width: Double, height: Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            width > 0, height > 0
        else {
            return nil
        }

        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard let frame = Self(x: x, y: y, width: width, height: height) else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription:
                    "Window frame must contain finite coordinates and positive finite dimensions"
            )
        }
        self = frame
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

struct ApplicationState: Equatable, Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    var workspaceStore: WorkspaceStore
    var normalWindowFrame: NormalWindowFrame?

    private enum CodingKeys: String, CodingKey {
        case version
        case workspaces
        case activeWorkspaceID
        case normalWindowFrame
    }

    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        normalWindowFrame: NormalWindowFrame? = nil
    ) {
        version = Self.currentVersion
        self.workspaceStore = workspaceStore
        self.normalWindowFrame = normalWindowFrame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "ApplicationState requires version \(Self.currentVersion)"
            )
        }

        let workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        let activeWorkspaceID = try container.decodeIfPresent(
            WorkspaceID.self,
            forKey: .activeWorkspaceID
        )

        self.version = version
        workspaceStore = try WorkspaceStore(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID
        )
        normalWindowFrame = try container.decodeIfPresent(
            NormalWindowFrame.self,
            forKey: .normalWindowFrame
        )
    }

    func encode(to encoder: Encoder) throws {
        guard version == Self.currentVersion else {
            throw EncodingError.invalidValue(
                version,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "Only application state version \(Self.currentVersion) can be encoded"
                )
            )
        }

        try workspaceStore.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encodeIfPresent(normalWindowFrame, forKey: .normalWindowFrame)
    }
}
