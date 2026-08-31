import CoreFoundation
import Foundation

enum StateMigrationError: Error, Equatable, Sendable {
    case missingVersion
    case nullVersion
    case nonIntegerVersion
    case decodedVersionMismatch(expected: Int, actual: Int)
    case unsupportedOlderVersion(Int)
    case unsupportedNewerVersion(Int)
}

enum StateMigration {
    static func decode(_ data: Data) throws -> ApplicationState {
        let version = try probeVersion(in: data)
        switch version {
        case 1:
            return try JSONDecoder().decode(V1ApplicationState.self, from: data)
                .migrated()
        case ApplicationState.currentVersion:
            return try JSONDecoder().decode(ApplicationState.self, from: data)
        case ..<ApplicationState.currentVersion:
            throw StateMigrationError.unsupportedOlderVersion(version)
        default:
            throw StateMigrationError.unsupportedNewerVersion(version)
        }
    }

    private struct V1PaneID: Decodable {
        let rawValue: UUID

        func migrated() -> PaneID {
            PaneID(rawValue: rawValue)
        }
    }

    private struct V1TabID: Decodable {
        let rawValue: UUID

        func migrated() -> TabID {
            TabID(rawValue: rawValue)
        }
    }

    private struct V1WorkspaceID: Decodable {
        let rawValue: UUID

        func migrated() -> WorkspaceID {
            WorkspaceID(rawValue: rawValue)
        }
    }

    private struct V1ApplicationState: Decodable {
        let version: Int
        let workspaces: [V1Workspace]
        let activeWorkspaceID: V1WorkspaceID?
        let normalWindowFrame: V1NormalWindowFrame?

        private enum CodingKeys: String, CodingKey {
            case version
            case workspaces
            case activeWorkspaceID
            case normalWindowFrame
        }

        func migrated() throws -> ApplicationState {
            guard version == 1 else {
                throw StateMigrationError.decodedVersionMismatch(
                    expected: 1,
                    actual: version
                )
            }

            let migratedWorkspaces = try workspaces.map { try $0.migrated() }
            let workspaceStore = try WorkspaceStore(
                workspaces: migratedWorkspaces,
                activeWorkspaceID: activeWorkspaceID?.migrated()
            )
            return ApplicationState(
                workspaceStore: workspaceStore,
                normalWindowFrame: try normalWindowFrame.map { try $0.migrated() }
            )
        }
    }

    private struct V1NormalWindowFrame: Decodable {
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

        func migrated() throws -> NormalWindowFrame {
            guard let frame = NormalWindowFrame(x: x, y: y, width: width, height: height) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription:
                            "Window frame must contain finite coordinates and positive finite dimensions"
                    )
                )
            }
            return frame
        }
    }

    private struct V1Workspace: Decodable {
        let id: V1WorkspaceID
        let name: String
        let tabs: [V1TerminalTab]
        let activeTabID: V1TabID?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case tabs
            case activeTabID
        }

        func migrated() throws -> Workspace {
            Workspace(
                id: id.migrated(),
                name: name,
                tabs: try tabs.map { try $0.migrated() },
                activeTabID: activeTabID?.migrated()
            )
        }
    }

    private struct V1TerminalTab: Decodable {
        let id: V1TabID
        let title: String
        let titleOverride: String?
        let root: V1SplitNode
        let paneDescriptors: [V1TerminalPaneDescriptor]
        let activePaneID: V1PaneID?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case titleOverride
            case root
            case paneDescriptors
            case activePaneID
        }

        func migrated() throws -> TerminalTab {
            try TerminalTab(
                id: id.migrated(),
                title: title,
                titleOverride: titleOverride,
                root: root.migrated(),
                paneDescriptors: paneDescriptors.map { $0.migrated() },
                activePaneID: activePaneID?.migrated(),
                isBroadcasting: false
            )
        }
    }

    private indirect enum V1SplitNode: Decodable {
        case pane(V1PaneID)
        case split(
            id: UUID,
            axis: V1SplitAxis,
            ratio: Double,
            first: V1SplitNode,
            second: V1SplitNode
        )

        private enum Kind: String, Decodable {
            case pane
            case split
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case paneID
            case id
            case axis
            case ratio
            case first
            case second
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .pane:
                self = .pane(try container.decode(V1PaneID.self, forKey: .paneID))
            case .split:
                self = .split(
                    id: try container.decode(UUID.self, forKey: .id),
                    axis: try container.decode(V1SplitAxis.self, forKey: .axis),
                    ratio: try container.decode(Double.self, forKey: .ratio),
                    first: try container.decode(V1SplitNode.self, forKey: .first),
                    second: try container.decode(V1SplitNode.self, forKey: .second)
                )
            }
        }

        func migrated() -> SplitNode {
            switch self {
            case .pane(let paneID):
                return .pane(paneID.migrated())
            case .split(let id, let axis, let ratio, let first, let second):
                let migratedRatio = ratio.isFinite ? min(max(ratio, 0.1), 0.9) : 0.5
                return .split(
                    id: id,
                    axis: axis.migrated(),
                    ratio: migratedRatio,
                    first: first.migrated(),
                    second: second.migrated()
                )
            }
        }
    }

    private enum V1SplitAxis: String, Decodable {
        case horizontal
        case vertical

        func migrated() -> SplitAxis {
            switch self {
            case .horizontal:
                .horizontal
            case .vertical:
                .vertical
            }
        }
    }

    private struct V1TerminalPaneDescriptor: Decodable {
        let id: V1PaneID
        let cwd: String
        let startupCommand: V1StartupCommand

        private enum CodingKeys: String, CodingKey {
            case id
            case cwd
            case startupCommand
        }

        func migrated() -> TerminalPaneDescriptor {
            TerminalPaneDescriptor(
                id: id.migrated(),
                cwd: cwd,
                startupCommand: startupCommand.migrated(),
                agentResumeBinding: nil
            )
        }
    }

    private enum V1StartupCommand: Decodable {
        case shell
        case custom(String)

        private enum Kind: String, Decodable {
            case shell
            case custom
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case command
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .shell:
                self = .shell
            case .custom:
                self = .custom(try container.decode(String.self, forKey: .command))
            }
        }

        func migrated() -> StartupCommand {
            switch self {
            case .shell:
                .shell
            case .custom(let command):
                .custom(command)
            }
        }
    }

    private static func probeVersion(in data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any],
            let value = document["version"]
        else {
            throw StateMigrationError.missingVersion
        }
        guard !(value is NSNull) else {
            throw StateMigrationError.nullVersion
        }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw StateMigrationError.nonIntegerVersion
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
            doubleValue.rounded(.towardZero) == doubleValue,
            let version = Int(exactly: doubleValue)
        else {
            throw StateMigrationError.nonIntegerVersion
        }
        return version
    }
}
