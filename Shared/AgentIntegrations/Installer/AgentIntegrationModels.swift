import Darwin
import Foundation

public enum AgentIntegrationRoot: String, Codable, Equatable, Sendable {
    case home
    case applicationSupport
}

public struct AgentIntegrationPath: Codable, Equatable, Hashable, Sendable {
    public static let maximumComponentCount = 32
    public static let maximumUTF8Length = 4_096

    public let root: AgentIntegrationRoot
    public let components: [String]

    public init(root: AgentIntegrationRoot, components: [String]) throws {
        let byteCount = components.reduce(0) { $0 + $1.utf8.count + 1 }
        guard !components.isEmpty,
            components.count <= Self.maximumComponentCount,
            byteCount <= Self.maximumUTF8Length,
            components.allSatisfy(Self.isSafeComponent)
        else {
            throw AgentIntegrationInstallerError.invalidPath
        }
        self.root = root
        self.components = components
    }

    public init(root: AgentIntegrationRoot, relativePath: String) throws {
        guard !relativePath.hasPrefix("/") else {
            throw AgentIntegrationInstallerError.invalidPath
        }
        try self.init(root: root, components: relativePath.split(separator: "/").map(String.init))
    }

    public var relativePath: String { components.joined(separator: "/") }

    private enum CodingKeys: String, CodingKey {
        case root
        case components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            root: container.decode(AgentIntegrationRoot.self, forKey: .root),
            components: container.decode([String].self, forKey: .components)
        )
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && component != ".env"
            && component.utf8.count <= 255
            && !component.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
            && !component.contains("/")
    }
}

public enum AgentIntegrationMutationKind: String, Codable, Equatable, Sendable {
    case jsonHook
    case markerBlock
    case ownedFile
    case ownershipManifest
}

public enum AgentIntegrationFileMode: String, Codable, Equatable, Sendable {
    case configuration = "0600"
    case executable = "0755"

    var permissions: mode_t {
        switch self {
        case .configuration: 0o600
        case .executable: 0o755
        }
    }
}

public enum AgentIntegrationMutationOperation: String, Codable, Equatable, Sendable {
    case create
    case update
    case remove
    case noOp
}

public struct AgentIntegrationMutationPreview: Codable, Equatable, Sendable {
    public let operationID: String
    public let fingerprint: String
    public let path: AgentIntegrationPath
    public let kind: AgentIntegrationMutationKind
    public let operation: AgentIntegrationMutationOperation
    public let mode: AgentIntegrationFileMode?
    public let changesFile: Bool
    public let createsBackup: Bool

    public init(
        operationID: String,
        fingerprint: String,
        path: AgentIntegrationPath,
        kind: AgentIntegrationMutationKind,
        operation: AgentIntegrationMutationOperation,
        mode: AgentIntegrationFileMode?,
        changesFile: Bool,
        createsBackup: Bool
    ) {
        self.operationID = operationID
        self.fingerprint = fingerprint
        self.path = path
        self.kind = kind
        self.operation = operation
        self.mode = mode
        self.changesFile = changesFile
        self.createsBackup = createsBackup
    }
}

struct AgentIntegrationFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

public struct AgentIntegrationPreparedWrite: Sendable {
    public let preview: AgentIntegrationMutationPreview
    let replacement: Data?
    let expectedData: Data?
    let expectedIdentity: AgentIntegrationFileIdentity?
    let expectedPermissions: mode_t?
    let replacementMode: AgentIntegrationFileMode?
    let createParentDirectories: Bool

    init(
        preview: AgentIntegrationMutationPreview,
        replacement: Data?,
        expectedData: Data?,
        expectedIdentity: AgentIntegrationFileIdentity?,
        expectedPermissions: mode_t?,
        replacementMode: AgentIntegrationFileMode?,
        createParentDirectories: Bool = false
    ) {
        self.preview = preview
        self.replacement = replacement
        self.expectedData = expectedData
        self.expectedIdentity = expectedIdentity
        self.expectedPermissions = expectedPermissions
        self.replacementMode = replacementMode
        self.createParentDirectories = createParentDirectories
    }
}

public struct AgentIntegrationApplyResult: Equatable, Sendable {
    public let changedPaths: [AgentIntegrationPath]
    public let backupPaths: [AgentIntegrationPath]
}

public struct AgentIntegrationMutationPlan: Sendable {
    public let write: AgentIntegrationPreparedWrite
    public let ownershipRecords: [AgentIntegrationOwnershipRecord]

    public var ownershipRecord: AgentIntegrationOwnershipRecord? {
        ownershipRecords.count == 1 ? ownershipRecords[0] : nil
    }

    public init(
        write: AgentIntegrationPreparedWrite,
        ownershipRecord: AgentIntegrationOwnershipRecord?
    ) {
        self.write = write
        ownershipRecords = ownershipRecord.map { [$0] } ?? []
    }

    init(
        write: AgentIntegrationPreparedWrite,
        ownershipRecords: [AgentIntegrationOwnershipRecord]
    ) {
        self.write = write
        self.ownershipRecords = ownershipRecords
    }
}

public struct AgentIntegrationOwnershipRecord: Codable, Equatable, Sendable {
    public let path: AgentIntegrationPath
    public let operationID: String
    public let kind: AgentIntegrationMutationKind
    public let markerVersion: Int?
    public let jsonPointer: String?
    public let beforeHash: String?
    public let ownedHash: String

    public init(
        path: AgentIntegrationPath,
        operationID: String,
        kind: AgentIntegrationMutationKind,
        markerVersion: Int? = nil,
        jsonPointer: String? = nil,
        beforeHash: String?,
        ownedHash: String
    ) {
        self.path = path
        self.operationID = operationID
        self.kind = kind
        self.markerVersion = markerVersion
        self.jsonPointer = jsonPointer
        self.beforeHash = beforeHash
        self.ownedHash = ownedHash
    }
}

public enum AgentIntegrationManifestState: Equatable, Sendable {
    case absent
    case trusted([AgentIntegrationOwnershipRecord])
    case untrusted
}

public enum AgentIntegrationInstallerError: Error, Equatable, Sendable {
    case invalidPath
    case pathRejected
    case resourceLimit
    case changedAfterPreview
    case previewMismatch
    case conflict
    case corruptManifest
    case malformedJSON
    case duplicateJSONKey
    case nonObjectJSONRoot
    case invalidJSONPointer
    case markerConflict
    case ownershipMismatch
    case verificationFailed
    case rollbackFailed
    case indeterminate
    case ioFailure
}

enum AgentIntegrationHash {
    static func digest(_ data: Data?) -> String {
        guard let data else { return "absent" }
        return SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }

    static func operationID(
        path: AgentIntegrationPath,
        kind: AgentIntegrationMutationKind,
        before: Data?,
        after: Data?
    ) -> String {
        var material = Data("QuickTTY-installer-v1\u{0}".utf8)
        material.append(Data(path.root.rawValue.utf8))
        material.append(0)
        material.append(Data(path.relativePath.utf8))
        material.append(0)
        material.append(Data(kind.rawValue.utf8))
        material.append(0)
        material.append(Data(digest(before).utf8))
        material.append(0)
        material.append(Data(digest(after).utf8))
        return digest(material)
    }
}

private enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(
            contentsOf: (0..<8).reversed().map { UInt8((bitLength >> UInt64($0 * 8)) & 0xff) })

        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] =
                    UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16
                    | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let a = words[index - 15]
                let b = words[index - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var work = state
            for index in 0..<64 {
                let s1 = rotate(work[4], 6) ^ rotate(work[4], 11) ^ rotate(work[4], 25)
                let choice = (work[4] & work[5]) ^ (~work[4] & work[6])
                let temporary1 = work[7] &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(work[0], 2) ^ rotate(work[0], 13) ^ rotate(work[0], 22)
                let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
                let temporary2 = s0 &+ majority
                work = [
                    temporary1 &+ temporary2, work[0], work[1], work[2],
                    work[3] &+ temporary1, work[4], work[5], work[6],
                ]
            }
            for index in 0..<8 { state[index] &+= work[index] }
        }
        return state.flatMap { word in
            [
                UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff),
            ]
        }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
