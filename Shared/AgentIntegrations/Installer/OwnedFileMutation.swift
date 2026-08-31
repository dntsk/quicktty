import Foundation

public struct OwnedFileMutation: Sendable {
    public let path: AgentIntegrationPath
    public let operationID: String
    public let contents: Data
    public let mode: AgentIntegrationFileMode

    public init(
        path: AgentIntegrationPath,
        operationID: String,
        contents: Data,
        mode: AgentIntegrationFileMode = .configuration
    ) throws {
        guard !operationID.isEmpty, operationID.utf8.count <= 128,
            contents.count <= AgentIntegrationFileSystem.maximumFileBytes
        else { throw AgentIntegrationInstallerError.resourceLimit }
        self.path = path
        self.operationID = operationID
        self.contents = contents
        self.mode = mode
    }

    public func prepareInstall(
        fileSystem: AgentIntegrationFileSystem,
        ownership: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        let before = try fileSystem.read(path)
        let record = ownership.first {
            $0.path == path && $0.operationID == operationID && $0.kind == .ownedFile
        }
        if let before {
            guard let record,
                AgentIntegrationHash.digest(before) == record.ownedHash
            else { throw AgentIntegrationInstallerError.ownershipMismatch }
        } else if record != nil {
            throw AgentIntegrationInstallerError.ownershipMismatch
        }
        let write = try fileSystem.prepareWrite(
            path: path,
            data: contents,
            kind: .ownedFile,
            mode: mode,
            createParentDirectories: true
        )
        return AgentIntegrationMutationPlan(
            write: write,
            ownershipRecord: AgentIntegrationOwnershipRecord(
                path: path,
                operationID: operationID,
                kind: .ownedFile,
                beforeHash: nil,
                ownedHash: AgentIntegrationHash.digest(contents)
            )
        )
    }

    public func prepareUninstall(
        fileSystem: AgentIntegrationFileSystem,
        record: AgentIntegrationOwnershipRecord
    ) throws -> AgentIntegrationMutationPlan {
        guard record.path == path, record.operationID == operationID,
            record.kind == .ownedFile, record.beforeHash == nil,
            let current = try fileSystem.read(path),
            AgentIntegrationHash.digest(current) == record.ownedHash
        else { throw AgentIntegrationInstallerError.ownershipMismatch }
        return AgentIntegrationMutationPlan(
            write: try fileSystem.prepareRemoval(path: path, kind: .ownedFile),
            ownershipRecord: nil
        )
    }
}
