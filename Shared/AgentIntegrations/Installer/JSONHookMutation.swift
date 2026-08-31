import Foundation

public struct JSONHookMutation: Sendable {
    public let path: AgentIntegrationPath
    public let jsonPointer: String
    public let operationID: String
    public let commandNode: Data

    private let hooks: [Hook]

    private struct Hook: Sendable {
        let jsonPointer: String
        let operationID: String
        let commandNode: Data
    }

    public init(
        path: AgentIntegrationPath,
        jsonPointer: String,
        operationID: String,
        commandNode: Data
    ) throws {
        try self.init(
            path: path,
            hooks: [(jsonPointer: jsonPointer, operationID: operationID, commandNode: commandNode)]
        )
    }

    init(
        path: AgentIntegrationPath,
        hooks: [(jsonPointer: String, operationID: String, commandNode: Data)]
    ) throws {
        guard !hooks.isEmpty,
            Set(hooks.map(\.operationID)).count == hooks.count,
            Set(hooks.map(\.jsonPointer)).count == hooks.count
        else { throw AgentIntegrationInstallerError.conflict }
        for hook in hooks {
            guard !hook.operationID.isEmpty, hook.operationID.utf8.count <= 128 else {
                throw AgentIntegrationInstallerError.conflict
            }
            let components = try Self.pointerComponents(hook.jsonPointer)
            guard !components.isEmpty else {
                throw AgentIntegrationInstallerError.invalidJSONPointer
            }
            try StrictJSON.validate(hook.commandNode)
            guard try JSONSerialization.jsonObject(with: hook.commandNode) is [String: Any] else {
                throw AgentIntegrationInstallerError.malformedJSON
            }
        }
        self.path = path
        jsonPointer = hooks[0].jsonPointer
        operationID = hooks[0].operationID
        commandNode = hooks[0].commandNode
        self.hooks = hooks.map {
            Hook(
                jsonPointer: $0.jsonPointer, operationID: $0.operationID,
                commandNode: $0.commandNode)
        }
    }

    var operationIDs: Set<String> { Set(hooks.map(\.operationID)) }

    public func prepareInstall(
        fileSystem: AgentIntegrationFileSystem,
        ownership: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        let before = try fileSystem.read(path)
        var root = try Self.object(from: before ?? Data("{}".utf8))
        var installedRecords: [AgentIntegrationOwnershipRecord] = []

        for hook in hooks {
            let desired = try JSONSerialization.jsonObject(
                with: hook.commandNode, options: [.fragmentsAllowed])
            let desiredCanonical = try Self.canonical(desired)
            let records = ownership.filter {
                $0.path == path && $0.operationID == hook.operationID && $0.kind == .jsonHook
                    && $0.jsonPointer == hook.jsonPointer
            }
            let components = try Self.pointerComponents(hook.jsonPointer)
            let existingNodes = try Self.nodes(in: root, at: components)

            if existingNodes.contains(where: { (try? Self.canonical($0)) == desiredCanonical }) {
                guard
                    records.contains(where: {
                        $0.ownedHash == AgentIntegrationHash.digest(desiredCanonical)
                    })
                else { throw AgentIntegrationInstallerError.conflict }
            } else if let record = records.first {
                guard
                    let index = existingNodes.firstIndex(where: {
                        (try? AgentIntegrationHash.digest(Self.canonical($0))) == record.ownedHash
                    })
                else { throw AgentIntegrationInstallerError.ownershipMismatch }
                try Self.replaceNode(in: &root, at: components, index: index, with: desired)
            } else {
                try Self.appendNode(desired, in: &root, at: components)
            }

            installedRecords.append(
                AgentIntegrationOwnershipRecord(
                    path: path,
                    operationID: hook.operationID,
                    kind: .jsonHook,
                    jsonPointer: hook.jsonPointer,
                    beforeHash: records.first?.beforeHash
                        ?? before.map(AgentIntegrationHash.digest),
                    ownedHash: AgentIntegrationHash.digest(desiredCanonical)
                ))
        }

        let after = try Self.canonical(root)
        return AgentIntegrationMutationPlan(
            write: try fileSystem.prepareWrite(path: path, data: after, kind: .jsonHook),
            ownershipRecords: installedRecords
        )
    }

    public func prepareUninstall(
        fileSystem: AgentIntegrationFileSystem,
        record: AgentIntegrationOwnershipRecord
    ) throws -> AgentIntegrationMutationPlan {
        try prepareUninstall(fileSystem: fileSystem, records: [record])
    }

    func prepareUninstall(
        fileSystem: AgentIntegrationFileSystem,
        records: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        guard let before = try fileSystem.read(path), records.count == hooks.count else {
            throw AgentIntegrationInstallerError.ownershipMismatch
        }
        var root = try Self.object(from: before)
        for hook in hooks {
            guard let record = records.first(where: { $0.operationID == hook.operationID }),
                record.path == path, record.kind == .jsonHook,
                record.jsonPointer == hook.jsonPointer
            else { throw AgentIntegrationInstallerError.ownershipMismatch }
            let components = try Self.pointerComponents(hook.jsonPointer)
            let nodes = try Self.nodes(in: root, at: components)
            guard
                let index = nodes.firstIndex(where: {
                    (try? AgentIntegrationHash.digest(Self.canonical($0))) == record.ownedHash
                })
            else { throw AgentIntegrationInstallerError.ownershipMismatch }
            try Self.removeNode(in: &root, at: components, index: index)
            if record.beforeHash == nil {
                Self.pruneEmptyPath(in: &root, components: components[...])
            }
        }
        if root.isEmpty, records.allSatisfy({ $0.beforeHash == nil }) {
            return AgentIntegrationMutationPlan(
                write: try fileSystem.prepareRemoval(path: path, kind: .jsonHook),
                ownershipRecord: nil
            )
        }
        return AgentIntegrationMutationPlan(
            write: try fileSystem.prepareWrite(
                path: path,
                data: try Self.canonical(root),
                kind: .jsonHook
            ),
            ownershipRecord: nil
        )
    }

    private static func object(from data: Data) throws -> [String: Any] {
        try StrictJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIntegrationInstallerError.nonObjectJSONRoot
        }
        return object
    }

    private static func canonical(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw AgentIntegrationInstallerError.malformedJSON
        }
        return try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func pointerComponents(_ pointer: String) throws -> [String] {
        guard pointer.hasPrefix("/"), pointer.utf8.count <= 1_024 else {
            throw AgentIntegrationInstallerError.invalidJSONPointer
        }
        return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            var result = ""
            var index = $0.startIndex
            while index < $0.endIndex {
                if $0[index] == "~" {
                    let next = $0.index(after: index)
                    guard next < $0.endIndex else {
                        throw AgentIntegrationInstallerError.invalidJSONPointer
                    }
                    if $0[next] == "0" {
                        result.append("~")
                    } else if $0[next] == "1" {
                        result.append("/")
                    } else {
                        throw AgentIntegrationInstallerError.invalidJSONPointer
                    }
                    index = $0.index(after: next)
                } else {
                    result.append($0[index])
                    index = $0.index(after: index)
                }
            }
            guard !result.isEmpty, result != ".env" else {
                throw AgentIntegrationInstallerError.invalidJSONPointer
            }
            return result
        }
    }

    private static func nodes(in root: [String: Any], at components: [String]) throws -> [Any] {
        var value: Any = root
        for component in components {
            guard let object = value as? [String: Any], let next = object[component] else {
                return []
            }
            value = next
        }
        guard let nodes = value as? [Any] else {
            throw AgentIntegrationInstallerError.conflict
        }
        return nodes
    }

    private static func appendNode(
        _ node: Any, in root: inout [String: Any], at components: [String]
    ) throws {
        try mutateArray(in: &root, components: components[...]) { $0.append(node) }
    }

    private static func replaceNode(
        in root: inout [String: Any], at components: [String], index: Int, with node: Any
    ) throws {
        try mutateArray(in: &root, components: components[...]) { nodes in
            guard nodes.indices.contains(index) else {
                throw AgentIntegrationInstallerError.conflict
            }
            nodes[index] = node
        }
    }

    private static func removeNode(
        in root: inout [String: Any], at components: [String], index: Int
    ) throws {
        try mutateArray(in: &root, components: components[...]) { nodes in
            guard nodes.indices.contains(index) else {
                throw AgentIntegrationInstallerError.conflict
            }
            nodes.remove(at: index)
        }
    }

    private static func pruneEmptyPath(
        in object: inout [String: Any], components: ArraySlice<String>
    ) {
        guard let component = components.first else { return }
        if components.count == 1 {
            if let array = object[component] as? [Any], array.isEmpty {
                object.removeValue(forKey: component)
            }
            return
        }
        guard var child = object[component] as? [String: Any] else { return }
        pruneEmptyPath(in: &child, components: components.dropFirst())
        if child.isEmpty {
            object.removeValue(forKey: component)
        } else {
            object[component] = child
        }
    }

    private static func mutateArray(
        in object: inout [String: Any],
        components: ArraySlice<String>,
        mutation: (inout [Any]) throws -> Void
    ) throws {
        guard let component = components.first else {
            throw AgentIntegrationInstallerError.invalidJSONPointer
        }
        if components.count == 1 {
            var array: [Any]
            if let existing = object[component] {
                guard let existingArray = existing as? [Any] else {
                    throw AgentIntegrationInstallerError.conflict
                }
                array = existingArray
            } else {
                array = []
            }
            try mutation(&array)
            object[component] = array
            return
        }
        var child: [String: Any]
        if let existing = object[component] {
            guard let existingObject = existing as? [String: Any] else {
                throw AgentIntegrationInstallerError.conflict
            }
            child = existingObject
        } else {
            child = [:]
        }
        try mutateArray(in: &child, components: components.dropFirst(), mutation: mutation)
        object[component] = child
    }
}

enum StrictJSON {
    static func validate(_ data: Data) throws {
        guard data.count <= AgentIntegrationFileSystem.maximumFileBytes else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        var parser = Parser(bytes: [UInt8](data))
        try parser.parse()
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw AgentIntegrationInstallerError.malformedJSON
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func parse() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw AgentIntegrationInstallerError.malformedJSON }
        }

        mutating func parseValue() throws {
            guard index < bytes.count, depth < 64 else {
                throw AgentIntegrationInstallerError.malformedJSON
            }
            switch bytes[index] {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6e: try consume("null")
            case 0x2d, 0x30...0x39: try parseNumber()
            default: throw AgentIntegrationInstallerError.malformedJSON
            }
        }

        mutating func parseObject() throws {
            depth += 1
            defer { depth -= 1 }
            index += 1
            skipWhitespace()
            if consumeIf(0x7d) { return }
            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw AgentIntegrationInstallerError.malformedJSON
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw AgentIntegrationInstallerError.duplicateJSONKey
                }
                skipWhitespace()
                guard consumeIf(0x3a) else { throw AgentIntegrationInstallerError.malformedJSON }
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consumeIf(0x7d) { return }
                guard consumeIf(0x2c) else { throw AgentIntegrationInstallerError.malformedJSON }
                skipWhitespace()
            }
        }

        mutating func parseArray() throws {
            depth += 1
            defer { depth -= 1 }
            index += 1
            skipWhitespace()
            if consumeIf(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consumeIf(0x5d) { return }
                guard consumeIf(0x2c) else { throw AgentIntegrationInstallerError.malformedJSON }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard
                        let value = try? JSONSerialization.jsonObject(
                            with: token, options: [.fragmentsAllowed]
                        ) as? String
                    else { throw AgentIntegrationInstallerError.malformedJSON }
                    return value
                }
                if byte < 0x20 { throw AgentIntegrationInstallerError.malformedJSON }
                if byte == 0x5c {
                    index += 1
                    guard index < bytes.count else {
                        throw AgentIntegrationInstallerError.malformedJSON
                    }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count,
                            bytes[(index + 1)...(index + 4)].allSatisfy({
                                (48...57).contains($0) || (65...70).contains($0)
                                    || (97...102).contains($0)
                            })
                        else { throw AgentIntegrationInstallerError.malformedJSON }
                        index += 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(
                        bytes[index])
                    {
                        throw AgentIntegrationInstallerError.malformedJSON
                    }
                }
                index += 1
            }
            throw AgentIntegrationInstallerError.malformedJSON
        }

        mutating func parseNumber() throws {
            let start = index
            if consumeIf(0x2d), index == bytes.count {
                throw AgentIntegrationInstallerError.malformedJSON
            }
            if consumeIf(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw AgentIntegrationInstallerError.malformedJSON
                }
            } else {
                guard consumeDigits() else { throw AgentIntegrationInstallerError.malformedJSON }
            }
            if consumeIf(0x2e), !consumeDigits() {
                throw AgentIntegrationInstallerError.malformedJSON
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d { index += 1 }
                guard consumeDigits() else { throw AgentIntegrationInstallerError.malformedJSON }
            }
            guard index > start else { throw AgentIntegrationInstallerError.malformedJSON }
        }

        mutating func consumeDigits() -> Bool {
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index > start
        }

        mutating func consume(_ string: StaticString) throws {
            let value = Array("\(string)".utf8)
            guard index + value.count <= bytes.count,
                Array(bytes[index..<(index + value.count)]) == value
            else { throw AgentIntegrationInstallerError.malformedJSON }
            index += value.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }
    }
}
