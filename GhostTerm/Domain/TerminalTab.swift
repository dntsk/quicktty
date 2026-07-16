import Foundation

enum TerminalTabError: Error, Equatable, Sendable {
    case emptyPaneLayout
    case duplicatePaneLeaf(PaneID)
    case duplicatePaneDescriptor(PaneID)
    case missingPaneDescriptor(PaneID)
    case unexpectedPaneDescriptor(PaneID)
    case invalidActivePane(PaneID)
    case paneAlreadyExists(PaneID)
}

struct TerminalTab: Codable, Equatable, Sendable {
    let id: TabID
    var title: String
    private(set) var root: SplitNode
    private(set) var paneDescriptors: [TerminalPaneDescriptor]
    private(set) var activePaneID: PaneID
    private(set) var isBroadcasting: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case root
        case paneDescriptors
        case activePaneID
    }

    init(
        id: TabID = TabID(),
        title: String,
        root: SplitNode,
        paneDescriptors: [TerminalPaneDescriptor],
        activePaneID: PaneID? = nil,
        isBroadcasting: Bool = false
    ) throws {
        let leaves = try Self.validatedLeaves(
            root: root,
            paneDescriptors: paneDescriptors
        )
        guard let firstPaneID = leaves.first else {
            throw TerminalTabError.emptyPaneLayout
        }

        self.id = id
        self.title = title
        self.root = root
        self.paneDescriptors = paneDescriptors
        self.activePaneID = activePaneID.flatMap { leaves.contains($0) ? $0 : nil } ?? firstPaneID
        self.isBroadcasting = isBroadcasting
    }

    init(
        id: TabID = TabID(),
        title: String,
        pane: TerminalPaneDescriptor
    ) {
        self.id = id
        self.title = title
        root = .pane(pane.id)
        paneDescriptors = [pane]
        activePaneID = pane.id
        isBroadcasting = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRoot = try container.decode(SplitNode.self, forKey: .root)
        let decodedDescriptors = try container.decode(
            [TerminalPaneDescriptor].self,
            forKey: .paneDescriptors
        )
        let decodedActivePaneID = try container.decodeIfPresent(
            PaneID.self,
            forKey: .activePaneID
        )

        do {
            try self.init(
                id: container.decode(TabID.self, forKey: .id),
                title: container.decode(String.self, forKey: .title),
                root: decodedRoot,
                paneDescriptors: decodedDescriptors,
                activePaneID: decodedActivePaneID
            )
        } catch let error as TerminalTabError {
            throw DecodingError.dataCorruptedError(
                forKey: .paneDescriptors,
                in: container,
                debugDescription: "Invalid terminal tab pane structure: \(error)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        let leaves: [PaneID]
        do {
            leaves = try Self.validatedLeaves(root: root, paneDescriptors: paneDescriptors)
        } catch let error as TerminalTabError {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid terminal tab pane structure: \(error)"
                )
            )
        }
        guard let firstPaneID = leaves.first else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A terminal tab requires at least one pane"
                )
            )
        }
        let encodedActivePaneID =
            leaves.contains(activePaneID) ? activePaneID : firstPaneID

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(root, forKey: .root)
        try container.encode(paneDescriptors, forKey: .paneDescriptors)
        try container.encode(encodedActivePaneID, forKey: .activePaneID)
    }

    func paneDescriptor(for paneID: PaneID) -> TerminalPaneDescriptor? {
        paneDescriptors.first { $0.id == paneID }
    }

    func mappingPaneDescriptors(
        _ transform: (TerminalPaneDescriptor) -> TerminalPaneDescriptor
    ) throws -> TerminalTab {
        try TerminalTab(
            id: id,
            title: title,
            root: root,
            paneDescriptors: paneDescriptors.map(transform),
            activePaneID: activePaneID,
            isBroadcasting: isBroadcasting
        )
    }

    func validateInvariant() throws {
        let leaves = try Self.validatedLeaves(root: root, paneDescriptors: paneDescriptors)
        guard leaves.contains(activePaneID) else {
            throw TerminalTabError.invalidActivePane(activePaneID)
        }
    }

    @discardableResult
    mutating func splitPane(
        _ targetPaneID: PaneID,
        with newPane: TerminalPaneDescriptor,
        axis: SplitAxis,
        ratio: Double
    ) throws -> Bool {
        guard root.contains(targetPaneID) else { return false }
        guard paneDescriptor(for: newPane.id) == nil, !root.contains(newPane.id) else {
            throw TerminalTabError.paneAlreadyExists(newPane.id)
        }

        var updatedRoot = root
        guard
            updatedRoot.split(
                targetPaneID,
                axis: axis,
                newPane: newPane.id,
                ratio: ratio
            )
        else {
            return false
        }

        var updatedDescriptors = paneDescriptors
        guard let targetIndex = updatedDescriptors.firstIndex(where: { $0.id == targetPaneID })
        else {
            throw TerminalTabError.missingPaneDescriptor(targetPaneID)
        }
        updatedDescriptors.insert(newPane, at: targetIndex + 1)
        _ = try Self.validatedLeaves(
            root: updatedRoot,
            paneDescriptors: updatedDescriptors
        )

        root = updatedRoot
        paneDescriptors = updatedDescriptors
        activePaneID = newPane.id
        return true
    }

    @discardableResult
    mutating func removePane(_ paneID: PaneID) -> Bool {
        let originalLeaves = root.leaves
        guard originalLeaves.count > 1,
            let removedIndex = originalLeaves.firstIndex(of: paneID),
            let updatedRoot = root.removing(paneID)
        else {
            return false
        }

        let remainingLeaves = originalLeaves.filter { $0 != paneID }
        let updatedActivePaneID: PaneID
        if activePaneID == paneID {
            let nextIndex = min(removedIndex, remainingLeaves.count - 1)
            updatedActivePaneID = remainingLeaves[nextIndex]
        } else {
            updatedActivePaneID = activePaneID
        }

        root = updatedRoot
        paneDescriptors.removeAll { $0.id == paneID }
        activePaneID = updatedActivePaneID
        return true
    }

    @discardableResult
    mutating func activatePane(_ paneID: PaneID) -> Bool {
        guard root.contains(paneID) else { return false }
        activePaneID = paneID
        return true
    }

    @discardableResult
    mutating func updateSplitRatio(_ splitID: UUID, ratio: Double) -> Bool {
        guard root.contains(splitID: splitID) else { return false }
        root = root.updatingRatio(splitID: splitID, ratio: ratio)
        return true
    }

    mutating func setBroadcasting(_ isBroadcasting: Bool) {
        self.isBroadcasting = isBroadcasting
    }

    mutating func resetBroadcasting() {
        isBroadcasting = false
    }

    private static func validatedLeaves(
        root: SplitNode,
        paneDescriptors: [TerminalPaneDescriptor]
    ) throws -> [PaneID] {
        let leaves = root.leaves
        var uniqueLeaves = Set<PaneID>()
        for paneID in leaves where !uniqueLeaves.insert(paneID).inserted {
            throw TerminalTabError.duplicatePaneLeaf(paneID)
        }

        var uniqueDescriptorIDs = Set<PaneID>()
        for descriptor in paneDescriptors
        where !uniqueDescriptorIDs.insert(descriptor.id).inserted {
            throw TerminalTabError.duplicatePaneDescriptor(descriptor.id)
        }

        if let missingPaneID = leaves.first(where: { !uniqueDescriptorIDs.contains($0) }) {
            throw TerminalTabError.missingPaneDescriptor(missingPaneID)
        }
        if let unexpectedPaneID = paneDescriptors.lazy.map(\.id).first(where: {
            !uniqueLeaves.contains($0)
        }) {
            throw TerminalTabError.unexpectedPaneDescriptor(unexpectedPaneID)
        }
        return leaves
    }
}
