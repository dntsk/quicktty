import Foundation

public struct MarkerBlockMutation: Sendable {
    public let path: AgentIntegrationPath
    public let operationID: String
    public let markerVersion: Int
    public let body: Data

    public init(
        path: AgentIntegrationPath,
        operationID: String,
        markerVersion: Int,
        body: Data
    ) throws {
        guard !operationID.isEmpty, operationID.utf8.count <= 128,
            operationID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }),
            (1...999).contains(markerVersion),
            body.count <= AgentIntegrationFileSystem.maximumFileBytes / 2,
            String(data: body, encoding: .utf8) != nil
        else { throw AgentIntegrationInstallerError.markerConflict }
        self.path = path
        self.operationID = operationID
        self.markerVersion = markerVersion
        self.body = body
    }

    public func prepareInstall(
        fileSystem: AgentIntegrationFileSystem,
        ownership: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        let before = try fileSystem.read(path)
        let source = before ?? Data()
        let blocks = try scan(source)
        let matchingRecord = ownership.first {
            $0.path == path && $0.operationID == operationID && $0.kind == .markerBlock
                && $0.markerVersion == markerVersion
        }
        let newline: Data
        let after: Data
        if let existing = blocks.first {
            guard blocks.count == 1, let matchingRecord,
                AgentIntegrationHash.digest(source.subdata(in: existing.range))
                    == matchingRecord.ownedHash
            else { throw AgentIntegrationInstallerError.markerConflict }
            newline = try newlineAfterBeginMarker(in: source, block: existing)
            var updated = source
            updated.replaceSubrange(existing.range, with: try block(newline: newline))
            after = updated
        } else {
            newline = Self.newline(in: source)
            var updated = source
            if !updated.isEmpty, !Self.endsInNewline(updated) { updated.append(newline) }
            updated.append(try block(newline: newline))
            after = updated
        }
        let desiredBlock = try block(newline: newline)
        let write = try fileSystem.prepareWrite(path: path, data: after, kind: .markerBlock)
        return AgentIntegrationMutationPlan(
            write: write,
            ownershipRecord: AgentIntegrationOwnershipRecord(
                path: path,
                operationID: operationID,
                kind: .markerBlock,
                markerVersion: markerVersion,
                beforeHash: matchingRecord?.beforeHash ?? before.map(AgentIntegrationHash.digest),
                ownedHash: AgentIntegrationHash.digest(desiredBlock)
            )
        )
    }

    public func prepareUninstall(
        fileSystem: AgentIntegrationFileSystem,
        record: AgentIntegrationOwnershipRecord
    ) throws -> AgentIntegrationMutationPlan {
        guard record.path == path, record.operationID == operationID,
            record.kind == .markerBlock, record.markerVersion == markerVersion,
            let source = try fileSystem.read(path)
        else { throw AgentIntegrationInstallerError.ownershipMismatch }
        let blocks = try scan(source)
        guard blocks.count == 1,
            AgentIntegrationHash.digest(source.subdata(in: blocks[0].range)) == record.ownedHash
        else { throw AgentIntegrationInstallerError.ownershipMismatch }

        var candidates: [Data] = []
        var direct = source
        direct.removeSubrange(blocks[0].range)
        candidates.append(direct)
        if blocks[0].range.lowerBound > 0,
            source[blocks[0].range.lowerBound - 1] == 0x0a
        {
            var withoutLFSeparator = source
            withoutLFSeparator.removeSubrange(
                (blocks[0].range.lowerBound - 1)..<blocks[0].range.upperBound)
            candidates.append(withoutLFSeparator)
            if blocks[0].range.lowerBound > 1,
                source[blocks[0].range.lowerBound - 2] == 0x0d
            {
                var withoutCRLFSeparator = source
                withoutCRLFSeparator.removeSubrange(
                    (blocks[0].range.lowerBound - 2)..<blocks[0].range.upperBound)
                candidates.append(withoutCRLFSeparator)
            }
        }
        let after: Data
        if let beforeHash = record.beforeHash {
            guard
                let matching = candidates.first(where: {
                    AgentIntegrationHash.digest($0) == beforeHash
                })
            else { throw AgentIntegrationInstallerError.ownershipMismatch }
            after = matching
        } else {
            after = candidates[0]
        }
        let write =
            after.isEmpty && record.beforeHash == nil
            ? try fileSystem.prepareRemoval(path: path, kind: .markerBlock)
            : try fileSystem.prepareWrite(path: path, data: after, kind: .markerBlock)
        return AgentIntegrationMutationPlan(write: write, ownershipRecord: nil)
    }

    private struct FoundBlock {
        let range: Range<Int>
    }

    private var beginMarker: String {
        "# >>> QuickTTY:\(operationID):v\(markerVersion) >>>"
    }

    private var endMarker: String {
        "# <<< QuickTTY:\(operationID):v\(markerVersion) <<<"
    }

    private func block(newline: Data) throws -> Data {
        guard let bodyText = String(data: body, encoding: .utf8),
            !bodyText.contains("# >>> QuickTTY:"), !bodyText.contains("# <<< QuickTTY:")
        else { throw AgentIntegrationInstallerError.markerConflict }
        var result = Data(beginMarker.utf8)
        result.append(newline)
        result.append(body)
        if !body.isEmpty, !Self.endsInNewline(body) { result.append(newline) }
        result.append(Data(endMarker.utf8))
        result.append(newline)
        return result
    }

    private func newlineAfterBeginMarker(in source: Data, block: FoundBlock) throws -> Data {
        let start = block.range.lowerBound + beginMarker.utf8.count
        guard start < block.range.upperBound else {
            throw AgentIntegrationInstallerError.markerConflict
        }
        if source[start] == 0x0a { return Data([0x0a]) }
        guard start + 1 < block.range.upperBound,
            source[start] == 0x0d, source[start + 1] == 0x0a
        else { throw AgentIntegrationInstallerError.markerConflict }
        return Data([0x0d, 0x0a])
    }

    private func scan(_ data: Data) throws -> [FoundBlock] {
        let begin = Data(beginMarker.utf8)
        let end = Data(endMarker.utf8)
        var openStart: Int?
        var blocks: [FoundBlock] = []
        for line in Self.lines(data) {
            let bytes = data.subdata(in: line.contentRange)
            let isAnyBegin = bytes.starts(with: Data("# >>> QuickTTY:".utf8))
            let isAnyEnd = bytes.starts(with: Data("# <<< QuickTTY:".utf8))
            if isAnyBegin {
                guard bytes == begin, openStart == nil, blocks.isEmpty else {
                    throw AgentIntegrationInstallerError.markerConflict
                }
                openStart = line.contentRange.lowerBound
            } else if isAnyEnd {
                guard bytes == end, let start = openStart else {
                    throw AgentIntegrationInstallerError.markerConflict
                }
                blocks.append(FoundBlock(range: start..<line.fullRange.upperBound))
                openStart = nil
            }
        }
        guard openStart == nil else { throw AgentIntegrationInstallerError.markerConflict }
        return blocks
    }

    private struct Line {
        let contentRange: Range<Int>
        let fullRange: Range<Int>
    }

    private static func lines(_ data: Data) -> [Line] {
        let bytes = [UInt8](data)
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0a {
                let contentEnd = index > start && bytes[index - 1] == 0x0d ? index - 1 : index
                lines.append(Line(contentRange: start..<contentEnd, fullRange: start..<(index + 1)))
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count {
            lines.append(Line(contentRange: start..<bytes.count, fullRange: start..<bytes.count))
        }
        return lines
    }

    private static func newline(in data: Data) -> Data {
        let bytes = [UInt8](data)
        for index in bytes.indices where bytes[index] == 0x0a {
            return index > 0 && bytes[index - 1] == 0x0d ? Data([0x0d, 0x0a]) : Data([0x0a])
        }
        return Data([0x0a])
    }

    private static func endsInNewline(_ data: Data) -> Bool {
        data.last == 0x0a
    }
}
