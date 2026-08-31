import Foundation

public struct AgentIntegrationOwnershipStore: Sendable {
    public static let maximumRecordCount = 256
    public static let maximumManifestBytes = 262_144

    private let fileSystem: AgentIntegrationFileSystem
    private let manifestPath: AgentIntegrationPath

    public init(fileSystem: AgentIntegrationFileSystem) throws {
        self.fileSystem = fileSystem
        manifestPath = try AgentIntegrationPath(
            root: .applicationSupport,
            components: ["QuickTTY", "agent-integration-ownership.json"]
        )
    }

    public func load() throws -> AgentIntegrationManifestState {
        guard let data = try fileSystem.read(manifestPath) else { return .absent }
        guard data.count <= Self.maximumManifestBytes else { return .untrusted }
        do {
            try StrictJSON.validate(data)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1,
                manifest.records.count <= Self.maximumRecordCount,
                Set(
                    manifest.records.map {
                        RecordIdentity(path: $0.path, operationID: $0.operationID)
                    }
                )
                .count == manifest.records.count,
                manifest.records.allSatisfy(Self.isValid)
            else { return .untrusted }
            let canonical = try Self.encode(manifest.records)
            guard canonical == data else { return .untrusted }
            return .trusted(manifest.records)
        } catch {
            return .untrusted
        }
    }

    public func prepareSave(
        _ records: [AgentIntegrationOwnershipRecord],
        allowingInstallOverUntrustedManifest: Bool = false
    ) throws -> AgentIntegrationPreparedWrite {
        guard records.count <= Self.maximumRecordCount,
            records.allSatisfy(Self.isValid)
        else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        if case .untrusted = try load() {
            guard allowingInstallOverUntrustedManifest else {
                throw AgentIntegrationInstallerError.corruptManifest
            }
            for record in records where try fileSystem.read(record.path) != nil {
                throw AgentIntegrationInstallerError.corruptManifest
            }
        }
        let data = try Self.encode(records)
        return try fileSystem.prepareWrite(
            path: manifestPath,
            data: data,
            kind: .ownershipManifest,
            createParentDirectories: true
        )
    }

    public func record(
        for path: AgentIntegrationPath,
        operationID: String,
        in records: [AgentIntegrationOwnershipRecord]
    ) -> AgentIntegrationOwnershipRecord? {
        records.first { $0.path == path && $0.operationID == operationID }
    }

    private struct Manifest: Codable {
        let version: Int
        let records: [AgentIntegrationOwnershipRecord]
    }

    private struct RecordIdentity: Hashable {
        let path: AgentIntegrationPath
        let operationID: String
    }

    private static func encode(_ records: [AgentIntegrationOwnershipRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Manifest(version: 1, records: records))
        guard data.count <= maximumManifestBytes else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        return data
    }

    private static func isValid(_ record: AgentIntegrationOwnershipRecord) -> Bool {
        isHash(record.ownedHash) && (record.beforeHash.map(isHash) ?? true)
            && !record.operationID.isEmpty && record.operationID.utf8.count <= 128
            && !record.operationID.utf8.contains(0)
            && (record.markerVersion.map { (1...999).contains($0) } ?? true)
            && (record.jsonPointer.map {
                $0.utf8.count <= 1_024 && $0.hasPrefix("/") && !$0.contains("\u{0}")
            } ?? true)
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
