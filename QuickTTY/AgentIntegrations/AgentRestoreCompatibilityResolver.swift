import Darwin
import Foundation

struct AgentVersionProbeRequest: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let environmentPath: String
}

enum AgentVersionProbeResult: Equatable, Sendable {
    case exited(status: Int32, output: Data)
    case timedOut
    case outputOverflow
    case failedToLaunch
}

struct AgentRestoreCompatibilityResolver: Sendable {
    typealias Probe =
        @Sendable (AgentVersionProbeRequest, TimeInterval) async -> AgentVersionProbeResult

    static let defaultProbeTimeout: TimeInterval = 0.75
    static let defaultAggregateTimeout: TimeInterval = 0.9
    static let maximumOutputBytes = 4_096

    private static let maximumAdapterCount = 64
    private static let maximumCandidateCount = 16
    private static let maximumCandidateBytes = 256
    private static let maximumPathBytes = 16_384
    private static let maximumPathEntryCount = 128
    private static let maximumPathEntryBytes = 1_024
    private static let maximumResolvedPathBytes = 4_096
    private static let maximumVersionLineBytes = 128

    private let probe: Probe
    private let probeTimeout: TimeInterval
    private let aggregateTimeout: TimeInterval

    init(
        probeTimeout: TimeInterval = defaultProbeTimeout,
        aggregateTimeout: TimeInterval = defaultAggregateTimeout,
        probe: @escaping Probe = AgentVersionProcessProbe.run
    ) {
        self.probeTimeout = min(max(probeTimeout, 0), Self.defaultProbeTimeout)
        self.aggregateTimeout = min(max(aggregateTimeout, 0), Self.defaultAggregateTimeout)
        self.probe = probe
    }

    init(probe: @escaping Probe) {
        self.init(
            probeTimeout: Self.defaultProbeTimeout,
            aggregateTimeout: Self.defaultAggregateTimeout,
            probe: probe
        )
    }

    func resolve(
        adapterIDs: [AgentAdapterID],
        path: String?
    ) async -> [AgentAdapterID: AgentRestoreCompatibility] {
        let deadline = Self.deadline(after: aggregateTimeout)
        let pathEntries = Self.boundedAbsolutePathEntries(path)
        let definitions = Set(adapterIDs.prefix(Self.maximumAdapterCount)).compactMap {
            AgentIntegrationRegistry.definition(for: $0)
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        var result: [AgentAdapterID: AgentRestoreCompatibility] = [:]

        for definition in definitions {
            guard !Task.isCancelled else {
                result[definition.id] = AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: nil
                )
                continue
            }
            guard case .requiresVerifiedInstalledVersion = definition.compatibilityPolicy else {
                continue
            }
            guard Self.remainingTime(until: deadline) > 0 else {
                result[definition.id] = AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: nil
                )
                continue
            }
            guard
                let executablePath = Self.resolveExecutable(
                    candidates: definition.executableCandidates,
                    pathEntries: pathEntries,
                    deadline: deadline
                )
            else {
                result[definition.id] = AgentRestoreCompatibility(
                    status: Task.isCancelled ? .unverifiedVersion : .missingExecutable,
                    resolvedExecutablePath: nil
                )
                continue
            }

            guard !Task.isCancelled else {
                result[definition.id] = AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: executablePath
                )
                continue
            }
            switch definition.versionProbePolicy {
            case .blocked:
                result[definition.id] = AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: nil
                )
            case .unverified:
                result[definition.id] = AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: executablePath
                )
            case .exact(let arguments, let acceptedLine, let version):
                let remaining = Self.remainingTime(until: deadline)
                guard remaining > 0 else {
                    result[definition.id] = AgentRestoreCompatibility(
                        status: .unverifiedVersion,
                        resolvedExecutablePath: executablePath
                    )
                    continue
                }
                guard !Task.isCancelled else {
                    result[definition.id] = AgentRestoreCompatibility(
                        status: .unverifiedVersion,
                        resolvedExecutablePath: executablePath
                    )
                    continue
                }
                let probeResult = await probe(
                    AgentVersionProbeRequest(
                        executablePath: executablePath,
                        arguments: arguments,
                        environmentPath: pathEntries.joined(separator: ":")
                    ),
                    min(probeTimeout, remaining)
                )
                let status: AgentCompatibilityStatus
                if !Task.isCancelled,
                    case .exited(let exitStatus, let output) = probeResult,
                    exitStatus == 0,
                    Self.printableVersionLine(from: output) == acceptedLine
                {
                    status = .compatible(version: version)
                } else {
                    status = .unverifiedVersion
                }
                result[definition.id] = AgentRestoreCompatibility(
                    status: status,
                    resolvedExecutablePath: executablePath
                )
            }
        }

        return result
    }

    private static func boundedAbsolutePathEntries(_ path: String?) -> [String] {
        guard let path, path.utf8.count <= maximumPathBytes else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: false)
            .prefix(maximumPathEntryCount)
            .compactMap { entry -> String? in
                guard !Task.isCancelled else { return nil }
                guard !entry.isEmpty, entry.utf8.count <= maximumPathEntryBytes else {
                    return nil
                }
                let value = String(entry)
                guard value.hasPrefix("/"),
                    !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
                else { return nil }
                return value
            }
    }

    private static func resolveExecutable(
        candidates: [String],
        pathEntries: [String],
        deadline: UInt64
    ) -> String? {
        for candidate in candidates.prefix(maximumCandidateCount) {
            guard !Task.isCancelled else { return nil }
            guard !candidate.isEmpty,
                candidate.utf8.count <= maximumCandidateBytes,
                !candidate.contains("/"),
                !candidate.contains("\0")
            else { continue }

            for directory in pathEntries {
                guard !Task.isCancelled, remainingTime(until: deadline) > 0 else { return nil }
                let candidatePath = directory + "/" + candidate
                guard candidatePath.utf8.count <= maximumResolvedPathBytes,
                    let canonicalPath = canonicalExecutablePath(candidatePath)
                else { continue }
                return canonicalPath
            }
        }
        return nil
    }

    private static func canonicalExecutablePath(_ path: String) -> String? {
        guard let resolvedPointer = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolvedPointer) }
        let resolved = String(cString: resolvedPointer)
        guard resolved.hasPrefix("/"),
            resolved.utf8.count <= maximumResolvedPathBytes,
            !resolved.contains("\0")
        else { return nil }

        var information = stat()
        guard resolved.withCString({ Darwin.lstat($0, &information) }) == 0,
            information.st_mode & S_IFMT == S_IFREG,
            resolved.withCString({ Darwin.access($0, X_OK) }) == 0
        else { return nil }
        return resolved
    }

    private static func printableVersionLine(from output: Data) -> String? {
        guard !output.isEmpty, output.count <= maximumOutputBytes else { return nil }
        var bytes = Array(output)
        if bytes.last == 0x0A {
            bytes.removeLast()
        }
        guard !bytes.isEmpty,
            bytes.count <= maximumVersionLineBytes,
            bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
            let line = String(bytes: bytes, encoding: .utf8)
        else { return nil }
        return line
    }

    private static func deadline(after interval: TimeInterval) -> UInt64 {
        let duration = UInt64(interval * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(duration).partialValue
    }

    private static func remainingTime(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        return TimeInterval(deadline - now) / 1_000_000_000
    }
}

private enum AgentVersionProcessProbe {
    private static let terminationGrace: TimeInterval = 0.05

    static func run(
        _ request: AgentVersionProbeRequest,
        timeout: TimeInterval
    ) async -> AgentVersionProbeResult {
        guard !Task.isCancelled,
            timeout > 0,
            request.executablePath.hasPrefix("/"),
            request.arguments.count <= 16,
            request.arguments.allSatisfy({
                !$0.contains("\0") && $0.utf8.count <= 256
            }),
            !request.environmentPath.contains("\0"),
            request.environmentPath.utf8.count <= 16_384
        else { return .failedToLaunch }

        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else { return .failedToLaunch }
        let readDescriptor = descriptors[0]
        var writeDescriptor = descriptors[1]
        defer {
            _ = Darwin.close(readDescriptor)
            if writeDescriptor >= 0 {
                _ = Darwin.close(writeDescriptor)
            }
        }
        guard setCloseOnExec(readDescriptor), setCloseOnExec(writeDescriptor) else {
            return .failedToLaunch
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failedToLaunch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard
            posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            ) == 0,
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, readDescriptor) == 0,
            posix_spawn_file_actions_addclose(&actions, writeDescriptor) == 0
        else { return .failedToLaunch }

        let values = [request.executablePath] + request.arguments
        let allocatedArguments = values.map { value in
            value.withCString { strdup($0) }
        }
        guard allocatedArguments.allSatisfy({ $0 != nil }) else {
            for argument in allocatedArguments {
                free(argument)
            }
            return .failedToLaunch
        }
        defer {
            for argument in allocatedArguments {
                free(argument)
            }
        }
        var arguments = allocatedArguments + [nil]
        guard let pathEnvironment = strdup("PATH=\(request.environmentPath)") else {
            return .failedToLaunch
        }
        defer { free(pathEnvironment) }
        var environment: [UnsafeMutablePointer<CChar>?] = [pathEnvironment, nil]
        var processID = pid_t()
        let spawnResult = request.executablePath.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processID,
                        executable,
                        &actions,
                        nil,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard spawnResult == 0 else { return .failedToLaunch }
        _ = Darwin.close(writeDescriptor)
        writeDescriptor = -1
        guard setNonBlocking(readDescriptor) else {
            terminateAndReap(processID)
            return .failedToLaunch
        }

        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            UInt64(timeout * 1_000_000_000)
        ).partialValue
        var output = Data()
        var status: Int32 = 0

        while true {
            guard !Task.isCancelled else {
                terminateAndReap(processID)
                return .failedToLaunch
            }
            switch drain(readDescriptor, into: &output) {
            case .overflow:
                terminateAndReap(processID)
                return .outputOverflow
            case .failed:
                terminateAndReap(processID)
                return .failedToLaunch
            case .drained:
                break
            }

            let waitResult = Darwin.waitpid(processID, &status, WNOHANG)
            if waitResult == processID {
                if drain(readDescriptor, into: &output) == .overflow {
                    return .outputOverflow
                }
                return .exited(status: exitStatus(status), output: output)
            }
            if waitResult == -1 {
                terminateAndReap(processID)
                return .failedToLaunch
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else {
                terminateAndReap(processID)
                return .timedOut
            }
            let remainingMilliseconds = max(
                1,
                min(10, Int32((deadline - now) / 1_000_000))
            )
            var descriptor = pollfd(
                fd: readDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult < 0, errno != EINTR {
                terminateAndReap(processID)
                return .failedToLaunch
            }
        }
    }

    private enum DrainResult {
        case drained
        case overflow
        case failed
    }

    private static func drain(_ descriptor: Int32, into output: inout Data) -> DrainResult {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= AgentRestoreCompatibilityResolver.maximumOutputBytes
                else { return .overflow }
                output.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return .drained
            }
            if errno == EINTR { continue }
            return .failed
        }
    }

    private static func terminateAndReap(_ processID: pid_t) {
        _ = Darwin.kill(processID, SIGTERM)
        let deadline =
            DispatchTime.now().uptimeNanoseconds
            + UInt64(
                terminationGrace * 1_000_000_000
            )
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID || (result == -1 && errno == ECHILD) { return }
            if result == -1, errno != EINTR { break }
            usleep(1_000)
        }
        _ = Darwin.kill(processID, SIGKILL)
        while Darwin.waitpid(processID, &status, 0) == -1, errno == EINTR {}
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }
}
