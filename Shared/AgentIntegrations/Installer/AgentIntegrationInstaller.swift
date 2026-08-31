import Darwin
import Foundation

public enum AgentIntegrationInstallerAction: Equatable, Sendable {
    case install
    case uninstall
}

public enum AgentIntegrationInstallerCapability: String, Codable, Equatable, Sendable {
    case nativeLifecycle
    case wrapperLifecycle
    case blocked
}

public enum AgentIntegrationInstallerStatus: String, Codable, Equatable, Sendable {
    case available
    case installed
    case updateAvailable
    case noOp
    case missing
    case blocked
    case unverified
    case conflict
    case succeeded
    case failed
    case skipped
}

public struct AgentIntegrationOperationSummary: Codable, Equatable, Sendable {
    public let displayPath: String
    public let kind: AgentIntegrationMutationKind
    public let operation: AgentIntegrationMutationOperation
    public let mode: AgentIntegrationFileMode?
    public let createsBackup: Bool

    public init(
        displayPath: String,
        kind: AgentIntegrationMutationKind,
        createsBackup: Bool,
        operation: AgentIntegrationMutationOperation = .update,
        mode: AgentIntegrationFileMode? = nil
    ) {
        self.displayPath = displayPath
        self.kind = kind
        self.operation = operation
        self.mode = mode
        self.createsBackup = createsBackup
    }
}

public struct AgentIntegrationAdapterSummary: Codable, Equatable, Sendable {
    public let adapterID: String
    public let capability: AgentIntegrationInstallerCapability
    public let status: AgentIntegrationInstallerStatus
    public let operations: [AgentIntegrationOperationSummary]

    public init(
        adapterID: String,
        capability: AgentIntegrationInstallerCapability,
        status: AgentIntegrationInstallerStatus,
        operations: [AgentIntegrationOperationSummary]
    ) {
        self.adapterID = adapterID
        self.capability = capability
        self.status = status
        self.operations = operations
    }
}

public struct AgentIntegrationPreparedSummary: Codable, Equatable, Sendable {
    public let planID: String
    public let adapters: [AgentIntegrationAdapterSummary]

    public init(planID: String, adapters: [AgentIntegrationAdapterSummary]) {
        self.planID = planID
        self.adapters = adapters
    }
}

public struct AgentIntegrationApplySummary: Codable, Equatable, Sendable {
    public let adapters: [AgentIntegrationAdapterSummary]

    public init(adapters: [AgentIntegrationAdapterSummary]) {
        self.adapters = adapters
    }
}

public enum AgentIntegrationInstallerRequestError: Error, Equatable, Sendable {
    case unknownAdapter
    case invalidPlan
    case expiredPlan
}

public actor AgentIntegrationInstaller {
    public static let adapterIDs = [
        "claude", "codex", "grok", "pi", "omp", "campfire", "amp", "cursor",
        "gemini", "kiro", "antigravity", "opencode", "rovo-dev", "hermes", "copilot",
        "codebuddy", "droid", "qoder", "kimi", "ollama",
    ]

    public static let maximumPendingAdapters = 20
    public static let planLifetime: TimeInterval = 300

    private let fileSystem: AgentIntegrationFileSystem
    private let ownershipStore: AgentIntegrationOwnershipStore
    private let policies: [Policy]
    private let executableAvailable: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private var pending: PendingPlan?

    public init(
        homeDirectory: URL,
        applicationSupportDirectory: URL,
        resourceRoot: URL,
        helperExecutable: URL,
        executableAvailable: @escaping @Sendable (String) -> Bool = {
            @Sendable executable in
            AgentIntegrationInstaller.defaultExecutableAvailability(executable)
        },
        postWriteHook: (@Sendable (AgentIntegrationPath) throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { @Sendable in Date() }
    ) throws {
        let fileSystem = try AgentIntegrationFileSystem(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            beforeSwap: nil,
            afterSwap: postWriteHook
        )
        self.fileSystem = fileSystem
        ownershipStore = try AgentIntegrationOwnershipStore(fileSystem: fileSystem)
        policies = try Self.makePolicies(
            resourceRoot: resourceRoot,
            helperExecutable: helperExecutable
        )
        self.executableAvailable = executableAvailable
        self.now = now
    }

    public func status(selectedAdapterIDs: [String] = []) throws
        -> [AgentIntegrationAdapterSummary]
    {
        pending = nil
        let selected = try selectedPolicies(selectedAdapterIDs)
        let manifest = try ownershipStore.load()
        return selected.map { policy in
            summary(
                policy: policy,
                status: status(policy: policy, manifest: manifest),
                previews: []
            )
        }
    }

    public func prepare(
        action: AgentIntegrationInstallerAction,
        selectedAdapterIDs: [String] = []
    ) throws -> AgentIntegrationPreparedSummary {
        pending = nil
        let selected = try selectedPolicies(selectedAdapterIDs)
        guard selected.count <= Self.maximumPendingAdapters else {
            throw AgentIntegrationInstallerError.resourceLimit
        }

        let manifestState = try ownershipStore.load()
        let initialRecords: [AgentIntegrationOwnershipRecord]
        switch manifestState {
        case .absent:
            initialRecords = []
        case .trusted(let records):
            initialRecords = records
        case .untrusted:
            initialRecords = []
        }

        var adapterPlans: [AdapterPlan] = []
        var summaries: [AgentIntegrationAdapterSummary] = []

        for policy in selected {
            let baseStatus = status(policy: policy, manifest: manifestState)
            guard policy.capability != .blocked, executableAvailable(policy.executable) else {
                summaries.append(summary(policy: policy, status: baseStatus, previews: []))
                adapterPlans.append(AdapterPlan(policy: policy, state: .skipped(baseStatus)))
                continue
            }
            guard case .untrusted = manifestState else {
                do {
                    let mutationPlans = try prepareMutations(
                        policy: policy,
                        action: action,
                        ownership: initialRecords
                    )
                    let previews = mutationPlans.map(\.write.preview)
                    let preparedStatus = preparedStatus(
                        action: action,
                        hadOwnership: hasOwnership(for: policy, in: initialRecords),
                        previews: previews
                    )
                    summaries.append(
                        summary(policy: policy, status: preparedStatus, previews: previews)
                    )
                    adapterPlans.append(
                        AdapterPlan(
                            policy: policy,
                            state: .ready(mutationPlans, preparedStatus)
                        ))
                } catch {
                    summaries.append(summary(policy: policy, status: .conflict, previews: []))
                    adapterPlans.append(AdapterPlan(policy: policy, state: .conflict))
                }
                continue
            }
            summaries.append(summary(policy: policy, status: .conflict, previews: []))
            adapterPlans.append(AdapterPlan(policy: policy, state: .conflict))
        }

        var finalRecords = initialRecords
        for adapter in adapterPlans {
            if case .ready(let mutations, _) = adapter.state {
                finalRecords = recordsAfter(
                    action: action,
                    policy: adapter.policy,
                    mutations: mutations,
                    records: finalRecords
                )
            }
        }
        let manifestWrite =
            adapterPlans.contains(where: {
                if case .ready = $0.state { return true }
                return false
            }) ? try ownershipStore.prepareSave(finalRecords) : nil
        if let manifestPreview = manifestWrite?.preview,
            let summaryIndex = adapterPlans.firstIndex(where: {
                if case .ready = $0.state { return true }
                return false
            })
        {
            let current = summaries[summaryIndex]
            summaries[summaryIndex] = AgentIntegrationAdapterSummary(
                adapterID: current.adapterID,
                capability: current.capability,
                status: current.status,
                operations: current.operations + [
                    AgentIntegrationOperationSummary(
                        displayPath: Self.displayPath(manifestPreview.path),
                        kind: manifestPreview.kind,
                        createsBackup: manifestPreview.createsBackup,
                        operation: manifestPreview.operation,
                        mode: manifestPreview.mode
                    )
                ]
            )
        }

        let planID = Self.randomPlanID()
        pending = PendingPlan(
            id: planID,
            action: action,
            createdAt: now(),
            finalRecords: finalRecords,
            manifestWrite: manifestWrite,
            adapters: adapterPlans
        )
        return AgentIntegrationPreparedSummary(planID: planID, adapters: summaries)
    }

    public func apply(planID: String) async throws -> AgentIntegrationApplySummary {
        try Task.checkCancellation()
        guard let plan = pending, Self.isOpaquePlanID(planID), plan.id == planID else {
            pending = nil
            throw AgentIntegrationInstallerRequestError.invalidPlan
        }
        pending = nil
        guard now().timeIntervalSince(plan.createdAt) <= Self.planLifetime else {
            throw AgentIntegrationInstallerRequestError.expiredPlan
        }

        let readyAdapters = plan.adapters.compactMap { adapter -> AdapterPlan? in
            if case .ready = adapter.state { return adapter }
            return nil
        }
        let mutationWrites = readyAdapters.flatMap { adapter -> [AgentIntegrationPreparedWrite] in
            guard case .ready(let mutations, _) = adapter.state else { return [] }
            return mutations.map(\.write)
        }
        let writes = mutationWrites + (plan.manifestWrite.map { [$0] } ?? [])

        var failureStatus: AgentIntegrationInstallerStatus?
        if !writes.isEmpty {
            do {
                _ = try fileSystem.apply(
                    writes,
                    matching: writes.map(\.preview),
                    transactionVerification: { [fileSystem, ownershipStore] in
                        try Task.checkCancellation()
                        guard try fileSystem.verifyInstalled(writes) else { return false }
                        return try readyAdapters.allSatisfy { adapter in
                            guard case .ready(let mutations, _) = adapter.state else {
                                return false
                            }
                            return try Self.verifyAdapterTransaction(
                                policy: adapter.policy,
                                action: plan.action,
                                expectedOwnership: plan.finalRecords,
                                mutations: mutations,
                                fileSystem: fileSystem,
                                ownershipStore: ownershipStore
                            )
                        }
                    }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AgentIntegrationInstallerError
                where error == .changedAfterPreview || error == .previewMismatch
                || error == .ownershipMismatch || error == .markerConflict
                || error == .conflict || error == .corruptManifest
            {
                failureStatus = .conflict
            } catch {
                failureStatus = .failed
            }
        }

        let results = plan.adapters.map { adapter in
            switch adapter.state {
            case .skipped:
                summary(policy: adapter.policy, status: .skipped, previews: [])
            case .conflict:
                summary(policy: adapter.policy, status: .conflict, previews: [])
            case .ready(_, let preparedStatus):
                summary(
                    policy: adapter.policy,
                    status: failureStatus ?? (preparedStatus == .noOp ? .noOp : .succeeded),
                    previews: []
                )
            }
        }
        return AgentIntegrationApplySummary(adapters: results)
    }

    private nonisolated static func verifyAdapterTransaction(
        policy: Policy,
        action: AgentIntegrationInstallerAction,
        expectedOwnership: [AgentIntegrationOwnershipRecord],
        mutations: [AgentIntegrationMutationPlan],
        fileSystem: AgentIntegrationFileSystem,
        ownershipStore: AgentIntegrationOwnershipStore
    ) throws -> Bool {
        guard try ownershipStore.load() == .trusted(expectedOwnership) else { return false }
        let expectedRecords = expectedOwnership.filter {
            policy.operationIDs.contains($0.operationID)
        }

        switch action {
        case .install:
            let verified = try policy.mutations.map {
                try $0.prepareInstall(fileSystem: fileSystem, ownership: expectedOwnership)
            }
            guard verified.allSatisfy({ !$0.write.preview.changesFile }),
                verified.flatMap(\.ownershipRecords) == expectedRecords
            else { return false }
            return try fileSystem.verifyInstalled(verified.map(\.write))
        case .uninstall:
            guard expectedRecords.isEmpty else { return false }
            return try fileSystem.verifyInstalled(mutations.map(\.write))
        }
    }

    public nonisolated static func defaultExecutableAvailability(_ executable: String) -> Bool {
        guard !executable.isEmpty, !executable.contains("/") else { return false }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: executable).path
            return access(candidate, X_OK) == 0
        }
    }

    private func selectedPolicies(_ selectedIDs: [String]) throws -> [Policy] {
        if selectedIDs.isEmpty { return policies }
        guard selectedIDs.count <= Self.maximumPendingAdapters,
            Set(selectedIDs).count == selectedIDs.count
        else { throw AgentIntegrationInstallerRequestError.unknownAdapter }
        let selected = Set(selectedIDs)
        guard selected.isSubset(of: Set(Self.adapterIDs)) else {
            throw AgentIntegrationInstallerRequestError.unknownAdapter
        }
        return policies.filter { selected.contains($0.id) }
    }

    private func status(
        policy: Policy,
        manifest: AgentIntegrationManifestState
    ) -> AgentIntegrationInstallerStatus {
        if policy.capability == .blocked { return .blocked }
        guard executableAvailable(policy.executable) else { return .missing }
        switch manifest {
        case .absent:
            return .available
        case .untrusted:
            return .conflict
        case .trusted(let records):
            let ownedOperationIDs = Set(records.map(\.operationID)).intersection(
                policy.operationIDs)
            if ownedOperationIDs.isEmpty { return .available }
            guard ownedOperationIDs == policy.operationIDs else { return .conflict }
            do {
                let plans = try prepareMutations(
                    policy: policy,
                    action: .install,
                    ownership: records
                )
                return plans.contains(where: { $0.write.preview.changesFile })
                    ? .updateAvailable : .installed
            } catch {
                return .conflict
            }
        }
    }

    private func hasOwnership(
        for policy: Policy,
        in records: [AgentIntegrationOwnershipRecord]
    ) -> Bool {
        policy.operationIDs.isSubset(of: Set(records.map(\.operationID)))
    }

    private func prepareMutations(
        policy: Policy,
        action: AgentIntegrationInstallerAction,
        ownership: [AgentIntegrationOwnershipRecord]
    ) throws -> [AgentIntegrationMutationPlan] {
        switch action {
        case .install:
            return try policy.mutations.map {
                try $0.prepareInstall(fileSystem: fileSystem, ownership: ownership)
            }
        case .uninstall:
            return try policy.mutations.compactMap { mutation in
                let records = ownership.filter {
                    mutation.operationIDs.contains($0.operationID) && $0.path == mutation.path
                }
                guard !records.isEmpty else { return nil }
                return try mutation.prepareUninstall(fileSystem: fileSystem, records: records)
            }
        }
    }

    private func recordsAfter(
        action: AgentIntegrationInstallerAction,
        policy: Policy,
        mutations: [AgentIntegrationMutationPlan],
        records: [AgentIntegrationOwnershipRecord]
    ) -> [AgentIntegrationOwnershipRecord] {
        let retained = records.filter { !policy.operationIDs.contains($0.operationID) }
        switch action {
        case .install:
            return retained + mutations.flatMap(\.ownershipRecords)
        case .uninstall:
            return retained
        }
    }

    private func preparedStatus(
        action: AgentIntegrationInstallerAction,
        hadOwnership: Bool,
        previews: [AgentIntegrationMutationPreview]
    ) -> AgentIntegrationInstallerStatus {
        guard previews.contains(where: \.changesFile) else { return .noOp }
        switch action {
        case .install:
            return hadOwnership ? .updateAvailable : .available
        case .uninstall:
            return .installed
        }
    }

    private func summary(
        policy: Policy,
        status: AgentIntegrationInstallerStatus,
        previews: [AgentIntegrationMutationPreview]
    ) -> AgentIntegrationAdapterSummary {
        AgentIntegrationAdapterSummary(
            adapterID: policy.id,
            capability: policy.capability,
            status: status,
            operations: previews.map {
                AgentIntegrationOperationSummary(
                    displayPath: Self.displayPath($0.path),
                    kind: $0.kind,
                    createsBackup: $0.createsBackup,
                    operation: $0.operation,
                    mode: $0.mode
                )
            }
        )
    }

    private static func displayPath(_ path: AgentIntegrationPath) -> String {
        let prefix = path.root == .home ? "~/" : "Application Support/"
        let value = prefix + path.relativePath
        return String(value.prefix(512))
    }

    private static func randomPlanID() -> String {
        UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
    }

    private static func isOpaquePlanID(_ value: String) -> Bool {
        value.utf8.count == 72 && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func makePolicies(resourceRoot: URL, helperExecutable: URL) throws -> [Policy] {
        guard resourceRoot.isFileURL, helperExecutable.isFileURL,
            helperExecutable.path.hasPrefix("/")
        else { throw AgentIntegrationInstallerError.invalidPath }

        let definitions:
            [(String, String, AgentIntegrationInstallerCapability, String, MutationShape)] = [
                (
                    "claude", "claude", .nativeLifecycle, "SessionStart",
                    .json(".claude/settings.json")
                ),
                ("codex", "codex", .nativeLifecycle, "SessionStart", .json(".codex/hooks.json")),
                ("grok", "grok", .blocked, "", .none),
                (
                    "pi", "pi", .nativeLifecycle, "session_start",
                    .owned(".pi/agent/extensions/quicktty-session/index.ts", "index.ts")
                ),
                (
                    "omp", "omp", .nativeLifecycle, "session_start",
                    .owned(".omp/extensions/quicktty-session.json", "integration.json")
                ),
                ("campfire", "the-campfire", .blocked, "", .none),
                (
                    "amp", "amp", .wrapperLifecycle, "",
                    .wrapper("amp", ".config/amp/quicktty/plugin.json", "plugin.json")
                ),
                ("cursor", "agent", .nativeLifecycle, "session_start", .json(".cursor/hooks.json")),
                (
                    "gemini", "gemini", .nativeLifecycle, "SessionStart",
                    .json(".gemini/settings.json")
                ),
                ("kiro", "kiro-cli", .blocked, "", .none),
                (
                    "antigravity", "agy", .wrapperLifecycle, "",
                    .wrapper("agy", ".config/antigravity/hooks/quicktty.json", "hook.json")
                ),
                (
                    "opencode", "opencode", .wrapperLifecycle, "",
                    .wrapper("opencode", ".config/opencode/plugins/quicktty.js", "plugin.js")
                ),
                ("rovo-dev", "acli", .blocked, "", .none),
                (
                    "hermes", "hermes", .nativeLifecycle, "start",
                    .owned(".hermes/hooks/quicktty-session.json", "integration.json")
                ),
                (
                    "copilot", "copilot", .nativeLifecycle, "session_start",
                    .json(".copilot/hooks.json")
                ),
                ("codebuddy", "codebuddy", .blocked, "", .none),
                ("droid", "droid", .nativeLifecycle, "session_start", .json(".factory/hooks.json")),
                (
                    "qoder", "qodercli", .nativeLifecycle, "session_start",
                    .json(".qoder/hooks.json")
                ),
                ("kimi", "kimi", .nativeLifecycle, "SessionStart", .marker(".kimi/config.toml")),
                ("ollama", "ollama", .blocked, "", .none),
            ]

        return try definitions.map { id, executable, capability, event, shape in
            let operationID = "agent-\(id)-v1"
            let mutations: [PolicyMutation]
            let events = lifecycleEvents(adapterID: id, startEvent: event)
            switch shape {
            case .none:
                mutations = []
            case .json(let relativePath):
                let hooks = try events.map { lifecycleEvent in
                    let command =
                        "\(try posixSingleQuoted(helperExecutable.path)) internal hook \(id) \(lifecycleEvent)"
                    let node = try JSONSerialization.data(
                        withJSONObject: [
                            "hooks": [["command": command, "type": "command"]]
                        ],
                        options: [.sortedKeys, .withoutEscapingSlashes]
                    )
                    return (
                        jsonPointer: "/hooks/\(lifecycleEvent)",
                        operationID: "\(operationID)-\(lifecycleEvent)",
                        commandNode: node
                    )
                }
                mutations = [
                    .json(
                        try JSONHookMutation(
                            path: AgentIntegrationPath(root: .home, relativePath: relativePath),
                            hooks: hooks
                        ))
                ]
            case .marker(let relativePath):
                let commands = try events.map { lifecycleEvent in
                    let key = lifecycleEvent == event ? "session_start_hook" : "session_end_hook"
                    let command =
                        "\(try posixSingleQuoted(helperExecutable.path)) internal hook \(id) \(lifecycleEvent)"
                    return "\(key) = \(try tomlBasicString(command))"
                }
                mutations = [
                    .marker(
                        try MarkerBlockMutation(
                            path: AgentIntegrationPath(root: .home, relativePath: relativePath),
                            operationID: operationID,
                            markerVersion: 1,
                            body: Data(commands.joined(separator: "\n").utf8)
                        ))
                ]
            case .owned(let relativePath, let resource):
                var contents = try boundedResource(resourceRoot, id, resource)
                if id == "pi" {
                    contents = try renderPiExtension(
                        contents,
                        helperExecutablePath: helperExecutable.path
                    )
                }
                mutations = [
                    .owned(
                        try OwnedFileMutation(
                            path: AgentIntegrationPath(root: .home, relativePath: relativePath),
                            operationID: operationID,
                            contents: contents
                        ))
                ]
            case .wrapper(let executableName, let pluginPath, let pluginResource):
                let wrapper = try boundedResource(
                    resourceRoot, id, "wrapper/\(executableName)")
                let plugin = try boundedResource(resourceRoot, id, pluginResource)
                mutations = [
                    .owned(
                        try OwnedFileMutation(
                            path: AgentIntegrationPath(
                                root: .applicationSupport,
                                relativePath: "AgentSessionIntegrations/wrappers/\(executableName)"
                            ),
                            operationID: "\(operationID)-wrapper",
                            contents: wrapper,
                            mode: .executable
                        )),
                    .owned(
                        try OwnedFileMutation(
                            path: AgentIntegrationPath(root: .home, relativePath: pluginPath),
                            operationID: "\(operationID)-plugin",
                            contents: plugin
                        )),
                ]
            }
            return Policy(
                id: id,
                executable: executable,
                capability: capability,
                mutations: mutations
            )
        }
    }

    static func posixSingleQuoted(_ value: String) throws -> String {
        guard !value.isEmpty,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AgentIntegrationInstallerError.invalidPath }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func tomlBasicString(_ value: String) throws -> String {
        guard
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw AgentIntegrationInstallerError.conflict }
        var encoded = "\""
        for character in value {
            switch character {
            case "\\": encoded += "\\\\"
            case "\"": encoded += "\\\""
            case "$": encoded += "\\u0024"
            case "`": encoded += "\\u0060"
            default: encoded.append(character)
            }
        }
        return encoded + "\""
    }

    private static func lifecycleEvents(adapterID: String, startEvent: String) -> [String] {
        let endEvent: String?
        switch adapterID {
        case "claude", "codex", "gemini", "kimi": endEvent = "SessionEnd"
        case "cursor", "copilot", "droid", "qoder": endEvent = "session_end"
        default: endEvent = nil
        }
        return [startEvent] + (endEvent.map { [$0] } ?? [])
    }

    private static func renderPiExtension(
        _ template: Data,
        helperExecutablePath: String
    ) throws -> Data {
        guard var source = String(data: template, encoding: .utf8) else {
            throw AgentIntegrationInstallerError.conflict
        }
        let placeholder = "\"__QUICKTTY_HELPER_PATH__\""
        guard source.components(separatedBy: placeholder).count == 2 else {
            throw AgentIntegrationInstallerError.conflict
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: [helperExecutablePath],
            options: [.withoutEscapingSlashes]
        )
        let array = String(decoding: encoded, as: UTF8.self)
        guard array.first == "[", array.last == "]" else {
            throw AgentIntegrationInstallerError.conflict
        }
        source.replaceSubrange(
            source.range(of: placeholder)!,
            with: String(array.dropFirst().dropLast())
        )
        let rendered = Data(source.utf8)
        guard rendered.count <= AgentIntegrationFileSystem.maximumFileBytes else {
            throw AgentIntegrationInstallerError.resourceLimit
        }
        return rendered
    }

    private static func boundedResource(_ root: URL, _ id: String, _ relative: String) throws
        -> Data
    {
        let url = root.appending(path: id, directoryHint: .isDirectory).appending(path: relative)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
            let size = values.fileSize,
            size <= AgentIntegrationFileSystem.maximumFileBytes
        else { throw AgentIntegrationInstallerError.resourceLimit }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

private struct Policy: Sendable {
    let id: String
    let executable: String
    let capability: AgentIntegrationInstallerCapability
    let mutations: [PolicyMutation]

    var operationIDs: Set<String> { Set(mutations.flatMap(\.operationIDs)) }
}

private enum MutationShape {
    case none
    case json(String)
    case marker(String)
    case owned(String, String)
    case wrapper(String, String, String)
}

private enum PolicyMutation: Sendable {
    case owned(OwnedFileMutation)
    case json(JSONHookMutation)
    case marker(MarkerBlockMutation)

    var path: AgentIntegrationPath {
        switch self {
        case .owned(let mutation): mutation.path
        case .json(let mutation): mutation.path
        case .marker(let mutation): mutation.path
        }
    }

    var operationIDs: Set<String> {
        switch self {
        case .owned(let mutation): [mutation.operationID]
        case .json(let mutation): mutation.operationIDs
        case .marker(let mutation): [mutation.operationID]
        }
    }

    func prepareInstall(
        fileSystem: AgentIntegrationFileSystem,
        ownership: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        switch self {
        case .owned(let mutation):
            try mutation.prepareInstall(fileSystem: fileSystem, ownership: ownership)
        case .json(let mutation):
            try mutation.prepareInstall(fileSystem: fileSystem, ownership: ownership)
        case .marker(let mutation):
            try mutation.prepareInstall(fileSystem: fileSystem, ownership: ownership)
        }
    }

    func prepareUninstall(
        fileSystem: AgentIntegrationFileSystem,
        records: [AgentIntegrationOwnershipRecord]
    ) throws -> AgentIntegrationMutationPlan {
        switch self {
        case .owned(let mutation):
            try mutation.prepareUninstall(fileSystem: fileSystem, record: records[0])
        case .json(let mutation):
            try mutation.prepareUninstall(fileSystem: fileSystem, records: records)
        case .marker(let mutation):
            try mutation.prepareUninstall(fileSystem: fileSystem, record: records[0])
        }
    }
}

private struct AdapterPlan: Sendable {
    let policy: Policy
    let state: AdapterPlanState
}

private enum AdapterPlanState: Sendable {
    case ready([AgentIntegrationMutationPlan], AgentIntegrationInstallerStatus)
    case skipped(AgentIntegrationInstallerStatus)
    case conflict
}

private struct PendingPlan: Sendable {
    let id: String
    let action: AgentIntegrationInstallerAction
    let createdAt: Date
    let finalRecords: [AgentIntegrationOwnershipRecord]
    let manifestWrite: AgentIntegrationPreparedWrite?
    let adapters: [AdapterPlan]
}
