import Foundation

indirect enum SplitNode: Equatable, Codable, Sendable {
    case pane(PaneID)
    case split(
        id: UUID,
        axis: SplitAxis,
        ratio: Double,
        first: SplitNode,
        second: SplitNode
    )

    private enum Kind: String, Codable {
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
            self = .pane(try container.decode(PaneID.self, forKey: .paneID))
        case .split:
            self = .split(
                id: try container.decode(UUID.self, forKey: .id),
                axis: try container.decode(SplitAxis.self, forKey: .axis),
                ratio: Self.clampedRatio(try container.decode(Double.self, forKey: .ratio)),
                first: try container.decode(SplitNode.self, forKey: .first),
                second: try container.decode(SplitNode.self, forKey: .second)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let paneID):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(paneID, forKey: .paneID)
        case .split(let id, let axis, let ratio, let first, let second):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(axis, forKey: .axis)
            try container.encode(Self.clampedRatio(ratio), forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    var leaves: [PaneID] {
        switch self {
        case .pane(let paneID):
            [paneID]
        case .split(_, _, _, let first, let second):
            first.leaves + second.leaves
        }
    }

    func contains(_ paneID: PaneID) -> Bool {
        switch self {
        case .pane(let candidate):
            candidate == paneID
        case .split(_, _, _, let first, let second):
            first.contains(paneID) || second.contains(paneID)
        }
    }

    mutating func split(
        _ target: PaneID,
        axis: SplitAxis,
        newPane: PaneID,
        ratio: Double
    ) -> Bool {
        switch self {
        case .pane(let paneID):
            guard paneID == target else { return false }
            self = .split(
                id: UUID(),
                axis: axis,
                ratio: Self.clampedRatio(ratio),
                first: .pane(paneID),
                second: .pane(newPane)
            )
            return true
        case .split(let id, let currentAxis, let currentRatio, let first, let second):
            var updatedFirst = first
            if updatedFirst.split(target, axis: axis, newPane: newPane, ratio: ratio) {
                self = .split(
                    id: id,
                    axis: currentAxis,
                    ratio: currentRatio,
                    first: updatedFirst,
                    second: second
                )
                return true
            }

            var updatedSecond = second
            if updatedSecond.split(target, axis: axis, newPane: newPane, ratio: ratio) {
                self = .split(
                    id: id,
                    axis: currentAxis,
                    ratio: currentRatio,
                    first: first,
                    second: updatedSecond
                )
                return true
            }

            return false
        }
    }

    func removing(_ paneID: PaneID) -> SplitNode? {
        switch self {
        case .pane(let candidate):
            candidate == paneID ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            switch (first.removing(paneID), second.removing(paneID)) {
            case (nil, nil):
                nil
            case (nil, let remainingSecond?):
                remainingSecond
            case (let remainingFirst?, nil):
                remainingFirst
            case (let remainingFirst?, let remainingSecond?):
                .split(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    first: remainingFirst,
                    second: remainingSecond
                )
            }
        }
    }

    func contains(splitID: UUID) -> Bool {
        switch self {
        case .pane:
            false
        case .split(let id, _, _, let first, let second):
            id == splitID || first.contains(splitID: splitID) || second.contains(splitID: splitID)
        }
    }

    func updatingRatio(splitID: UUID, ratio: Double) -> SplitNode {
        switch self {
        case .pane:
            return self
        case .split(let id, let axis, let currentRatio, let first, let second):
            if id == splitID {
                return .split(
                    id: id,
                    axis: axis,
                    ratio: Self.clampedRatio(ratio),
                    first: first,
                    second: second
                )
            }
            return .split(
                id: id,
                axis: axis,
                ratio: currentRatio,
                first: first.updatingRatio(splitID: splitID, ratio: ratio),
                second: second.updatingRatio(splitID: splitID, ratio: ratio)
            )
        }
    }

    private static func clampedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, 0.1), 0.9)
    }
}
