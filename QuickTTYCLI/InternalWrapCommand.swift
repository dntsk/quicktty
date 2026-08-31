import Darwin
import Foundation
import MachO

private nonisolated(unsafe) var wrapperSignalWriteDescriptor: Int32 = -1

private func wrapperSignalHandler(_ signal: Int32) {
    let savedErrno = errno
    let descriptor = wrapperSignalWriteDescriptor
    if descriptor >= 0 {
        var byte = UInt8(truncatingIfNeeded: signal)
        _ = Darwin.write(descriptor, &byte, 1)
    }
    errno = savedErrno
}

enum InternalWrapCommand {
    private static let adapterExecutables = [
        "amp": "amp",
        "antigravity": "agy",
        "opencode": "opencode",
    ]
    private static let forwardedSignals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGWINCH]
    private static let terminatingSignals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]
    private static let payloadKey = "QUICKTTY_WRAPPER_PAYLOAD"
    private static let wrapperDirectoryKey = "QUICKTTY_WRAPPER_DIR"
    private static let wrapperPathKey = "QUICKTTY_WRAPPER_PATH"
    private static let identityDescriptorKey = "QUICKTTY_WRAPPER_IDENTITY_FD"
    private static let maximumPATHEntries = 128
    private static let maximumIdentityBytes = 4_608

    static func run(adapterID: String, arguments directArguments: [String]) -> Int32 {
        guard let executableName = adapterExecutables[adapterID],
            let arguments = invocationArguments(directArguments),
            let executable = resolveExecutable(named: executableName)
        else { return EXIT_FAILURE }

        let explicitSessionID = explicitOpenCodeSessionID(
            adapterID: adapterID,
            arguments: arguments
        )
        let handledSignals = forwardedSignals + [SIGCONT, SIGCHLD]
        var blockedSet = signalSet(handledSignals)
        var previousMask = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &blockedSet, &previousMask) == 0 else {
            return EXIT_FAILURE
        }
        var activeMask = previousMask
        for signal in handledSignals { sigdelset(&activeMask, signal) }

        var signalPipe = [Int32](repeating: -1, count: 2)
        var identityPipe = [Int32](repeating: -1, count: 2)
        var oldActions: [Int32: sigaction] = [:]
        var environment: [String: String?]?
        var terminal = captureTerminalState()
        var child: pid_t = 0
        var childWasReaped = false
        var ownedSessionID: String?
        defer {
            _ = pthread_sigmask(SIG_BLOCK, &blockedSet, nil)
            if child > 0, !childWasReaped {
                _ = Darwin.kill(-child, SIGKILL)
                waitForChild(child)
            }
            _ = restoreTerminal(&terminal)
            if let ownedSessionID {
                sendUnregister(adapterID: adapterID, sessionID: ownedSessionID)
            }
            if let environment { restoreWrapperEnvironment(environment) }
            wrapperSignalWriteDescriptor = -1
            restoreSignalActions(oldActions)
            closeDescriptors(signalPipe + identityPipe)
            _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        }

        guard pipe(&signalPipe) == 0, pipe(&identityPipe) == 0,
            configurePipe(signalPipe, nonblockingRead: true, nonblockingWrite: true),
            configurePipe(identityPipe, nonblockingRead: true, nonblockingWrite: false)
        else { return EXIT_FAILURE }

        wrapperSignalWriteDescriptor = signalPipe[1]
        for signal in handledSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = wrapperSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            var oldAction = sigaction()
            guard sigaction(signal, &action, &oldAction) == 0 else { return EXIT_FAILURE }
            oldActions[signal] = oldAction
        }
        guard pthread_sigmask(SIG_SETMASK, &activeMask, nil) == 0 else {
            return EXIT_FAILURE
        }

        if let explicitSessionID {
            switch sendRegister(
                adapterID: adapterID,
                sessionID: explicitSessionID,
                signalDescriptor: signalPipe[0]
            ) {
            case .acknowledged:
                ownedSessionID = explicitSessionID
            case .interrupted(let signal):
                return 128 + signal
            case .failed, .rejected:
                break
            }
        }

        guard pthread_sigmask(SIG_BLOCK, &blockedSet, nil) == 0 else {
            return EXIT_FAILURE
        }
        if let signal = firstTerminatingSignal(in: drainSignals(signalPipe[0])) {
            return 128 + signal
        }

        let expectsPluginIdentity = explicitSessionID == nil
        environment = saveWrapperEnvironment()
        unsetWrapperEnvironment()
        if expectsPluginIdentity {
            setenv(identityDescriptorKey, String(identityPipe[1]), 1)
        }

        let spawnResult = spawn(
            executable: executable,
            arguments: arguments,
            childSignalMask: activeMask,
            identityDescriptor: expectsPluginIdentity ? identityPipe[1] : nil,
            child: &child
        )
        if let savedEnvironment = environment {
            restoreWrapperEnvironment(savedEnvironment)
            environment = nil
        }
        Darwin.close(identityPipe[1])
        identityPipe[1] = -1
        guard spawnResult == 0 else { return EXIT_FAILURE }
        if testPostSpawnFailure(child) { return EXIT_FAILURE }
        guard activateChild(child, terminal: &terminal),
            pthread_sigmask(SIG_SETMASK, &activeMask, nil) == 0
        else { return EXIT_FAILURE }

        var observedSessionID = explicitSessionID
        var identityBuffer = Data()
        var status: Int32 = 0
        while true {
            let waitResult = waitpid(child, &status, WNOHANG | WUNTRACED | WCONTINUED)
            if waitResult == child {
                if isStoppedStatus(status) {
                    captureChildTerminalAttributes(&terminal)
                    guard restoreTerminal(&terminal), reflectStop(stopSignal(status)) else {
                        return EXIT_FAILURE
                    }
                    continue
                }
                if isContinuedStatus(status) { continue }

                childWasReaped = true
                guard restoreTerminal(&terminal) else { return EXIT_FAILURE }
                if observedSessionID == nil {
                    readIdentity(from: identityPipe[0], into: &identityBuffer)
                    if let identity = decodeIdentity(identityBuffer, adapterID: adapterID) {
                        observedSessionID = identity.sessionID
                        switch sendRegister(
                            adapterID: adapterID,
                            sessionID: identity.sessionID,
                            cwd: identity.cwd,
                            signalDescriptor: signalPipe[0]
                        ) {
                        case .acknowledged:
                            ownedSessionID = identity.sessionID
                        case .interrupted:
                            break
                        case .failed, .rejected:
                            break
                        }
                    }
                }
                return decodedStatus(status)
            }
            if waitResult == -1, errno != EINTR { return EXIT_FAILURE }

            var pollDescriptors = [
                pollfd(fd: signalPipe[0], events: Int16(POLLIN), revents: 0),
                pollfd(fd: identityPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let pollResult = poll(&pollDescriptors, nfds_t(pollDescriptors.count), -1)
            if pollResult < 0, errno != EINTR { return EXIT_FAILURE }

            if pollDescriptors[0].revents & Int16(POLLIN) != 0 {
                let signals = drainSignals(signalPipe[0])
                for signal in signals where forwardedSignals.contains(signal) {
                    _ = Darwin.kill(-child, signal)
                }
                if signals.contains(SIGCONT), !continueChild(child, terminal: &terminal) {
                    return EXIT_FAILURE
                }
            }
            if observedSessionID == nil,
                pollDescriptors[1].revents & Int16(POLLIN | POLLHUP) != 0
            {
                readIdentity(from: identityPipe[0], into: &identityBuffer)
                if let identity = decodeIdentity(identityBuffer, adapterID: adapterID) {
                    observedSessionID = identity.sessionID
                    switch sendRegister(
                        adapterID: adapterID,
                        sessionID: identity.sessionID,
                        cwd: identity.cwd,
                        signalDescriptor: signalPipe[0]
                    ) {
                    case .acknowledged:
                        ownedSessionID = identity.sessionID
                    case .interrupted(let signal):
                        _ = Darwin.kill(-child, signal)
                    case .failed, .rejected:
                        break
                    }
                }
            }
        }
    }

    private static func invocationArguments(_ directArguments: [String]) -> [String]? {
        guard directArguments.isEmpty, let encoded = getenv(payloadKey) else {
            return getenv(payloadKey) == nil ? directArguments : nil
        }
        let byteCount = strnlen(encoded, 87_385)
        guard byteCount < 87_385 else { return nil }
        let value = String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(encoded).assumingMemoryBound(to: UInt8.self),
                count: byteCount
            ),
            as: UTF8.self
        )
        guard let data = Data(base64Encoded: value), data.count <= 65_536,
            let payload = try? JSONDecoder().decode(InvocationPayload.self, from: data),
            payload.arguments.count <= 256,
            payload.arguments.allSatisfy({ $0.utf8.count <= 4_096 }),
            let canonical = try? canonicalData(payload), canonical == data
        else { return nil }
        return payload.arguments
    }

    private static func canonicalData(_ payload: InvocationPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func resolveExecutable(named name: String) -> String? {
        guard let pathPointer = getenv("PATH") else { return nil }
        let pathCount = strnlen(pathPointer, 32_769)
        guard pathCount <= 32_768 else { return nil }
        let path = String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(pathPointer).assumingMemoryBound(to: UInt8.self),
                count: pathCount
            ),
            as: UTF8.self
        )
        let excludedDirectory = canonicalPath(environmentValue(wrapperDirectoryKey))
        let selfIdentity = fileIdentity(executablePath())
        let wrapperIdentity = fileIdentity(environmentValue(wrapperPathKey))

        let entries = path.split(separator: ":", omittingEmptySubsequences: false)
        guard entries.count <= maximumPATHEntries else { return nil }
        for entryValue in entries {
            let entry = String(entryValue)
            guard entry.hasPrefix("/"), entry.utf8.count <= Int(PATH_MAX),
                canonicalPath(entry) != excludedDirectory
            else { continue }
            let candidate = (entry as NSString).appendingPathComponent(name)
            guard candidate.utf8.count <= Int(PATH_MAX),
                let canonicalCandidate = canonicalPath(candidate),
                canonicalPath((canonicalCandidate as NSString).deletingLastPathComponent)
                    != excludedDirectory,
                isRegularExecutable(canonicalCandidate)
            else { continue }
            let identity = fileIdentity(canonicalCandidate)
            guard identity != selfIdentity, identity != wrapperIdentity else { continue }
            return canonicalCandidate
        }
        return nil
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        childSignalMask: sigset_t,
        identityDescriptor: Int32?,
        child: inout pid_t
    ) -> Int32 {
        var pointers: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            for pointer in pointers { free(pointer) }
            return ENOMEM
        }
        pointers.append(nil)
        defer {
            for pointer in pointers { free(pointer) }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return errno }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return errno }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var mask = childSignalMask
        var defaults = signalSet(forwardedSignals + [SIGCONT, SIGCHLD])
        let flags =
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
            posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0,
            posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO) == 0,
            identityDescriptor.map({
                posix_spawn_file_actions_addinherit_np(&actions, $0) == 0
            }) ?? true
        else { return errno }

        return pointers.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&child, executable, &actions, &attributes, buffer.baseAddress!, environ)
        }
    }

    private static func explicitOpenCodeSessionID(
        adapterID: String,
        arguments: [String]
    ) -> String? {
        guard adapterID == "opencode" else { return nil }
        var found: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let candidate: String?
            if argument == "--session", index + 1 < arguments.count {
                index += 1
                candidate = arguments[index]
            } else if argument.hasPrefix("--session=") {
                candidate = String(argument.dropFirst("--session=".count))
            } else {
                candidate = nil
            }
            if let candidate {
                guard found == nil, isValidSessionID(candidate) else { return nil }
                found = candidate
            }
            index += 1
        }
        return found
    }

    private static func sendRegister(
        adapterID: String,
        sessionID: String,
        cwd: String? = nil,
        signalDescriptor: Int32
    ) -> RegisterResult {
        guard let context = ipcContext(adapterID: adapterID),
            let payload = try? AgentIPCRegisterPayload(
                identity: context.identity,
                sessionID: sessionID,
                cwd: cwd ?? FileManager.default.currentDirectoryPath,
                metadata: [:]
            ),
            let preflight = try? AgentIPCPreflight(
                instanceID: context.identity.instanceID,
                paneID: context.identity.paneID,
                nonce: randomNonce()
            ),
            let frame = try? AgentIPCProtocol.encodeFrame(
                AgentIPCMessage(event: .register(payload)),
                for: preflight
            ),
            let preflightData = try? AgentIPCProtocol.encodePreflight(preflight)
        else { return .failed }

        var address: AgentUnixSocketAddress
        do {
            address = try AgentUnixSocketAddress(path: context.client.socketPath)
        } catch {
            return .failed
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failed }
        defer { Darwin.close(descriptor) }
        guard (try? AgentSocketIO.disableSIGPIPE(on: descriptor)) != nil,
            setNonblocking(descriptor)
        else { return .failed }

        let connectResult = address.withSockAddr { pointer, length in
            Darwin.connect(descriptor, pointer, length)
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { return .failed }
            switch waitForSocket(
                descriptor,
                events: Int16(POLLOUT),
                signalDescriptor: signalDescriptor
            ) {
            case .interrupted(let signal):
                return .interrupted(signal)
            case .failed:
                return .failed
            case .ready:
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard
                    getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &length
                    ) == 0, socketError == 0
                else { return .failed }
            }
        }

        if let result = writeIPCData(
            preflightData,
            to: descriptor,
            signalDescriptor: signalDescriptor
        ) {
            return result
        }
        let challengeStatus: UInt8
        switch readIPCByte(from: descriptor, signalDescriptor: signalDescriptor) {
        case .byte(let byte):
            challengeStatus = byte
        case .interrupted(let signal):
            return .interrupted(signal)
        case .eof, .failed:
            return .failed
        }
        guard challengeStatus == 1 else {
            return challengeStatus == 0 ? .rejected : .failed
        }
        switch readIPCData(
            count: AgentIPCProtocol.proofSize,
            from: descriptor,
            signalDescriptor: signalDescriptor
        ) {
        case .data(let proof):
            guard
                AgentIPCProtocol.verifyServerProof(
                    proof,
                    for: preflight,
                    paneToken: context.identity.paneToken
                )
            else { return .failed }
        case .interrupted(let signal):
            return .interrupted(signal)
        case .failed:
            return .failed
        }
        if let result = writeIPCData(frame, to: descriptor, signalDescriptor: signalDescriptor) {
            return result
        }
        while Darwin.shutdown(descriptor, SHUT_WR) != 0 {
            if errno == EINTR { continue }
            return .failed
        }

        let acknowledgement: UInt8
        switch readIPCByte(from: descriptor, signalDescriptor: signalDescriptor) {
        case .byte(let byte) where byte == 0 || byte == 1:
            acknowledgement = byte
        case .interrupted(let signal):
            return .interrupted(signal)
        case .byte, .eof, .failed:
            return .failed
        }
        switch readIPCByte(from: descriptor, signalDescriptor: signalDescriptor) {
        case .eof:
            return acknowledgement == 1 ? .acknowledged : .rejected
        case .interrupted(let signal):
            return .interrupted(signal)
        case .byte, .failed:
            return .failed
        }
    }

    private static func sendUnregister(adapterID: String, sessionID: String) {
        guard let context = ipcContext(adapterID: adapterID),
            let payload = try? AgentIPCUnregisterPayload(
                identity: context.identity,
                sessionID: sessionID
            )
        else { return }
        _ = try? context.client.send(AgentIPCMessage(event: .unregister(payload)))
    }

    private static func ipcContext(adapterID: String) -> IPCContext? {
        guard let socket = boundedEnvironmentValue("QUICKTTY_AGENT_SOCKET", 103),
            let instance = boundedEnvironmentValue("QUICKTTY_INSTANCE_ID", 36),
            let instanceID = UUID(uuidString: instance),
            let pane = boundedEnvironmentValue("QUICKTTY_PANE_ID", 36),
            let paneID = UUID(uuidString: pane),
            let token = boundedEnvironmentValue("QUICKTTY_PANE_TOKEN", 64),
            let identity = try? AgentIPCIdentity(
                instanceID: instanceID,
                paneID: paneID,
                paneToken: token,
                adapterID: adapterID
            )
        else { return nil }
        return IPCContext(identity: identity, client: AgentSocketClient(socketPath: socket))
    }

    private static func readIdentity(from descriptor: Int32, into buffer: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        while buffer.count <= maximumIdentityBytes {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count == -1, errno == EINTR { continue }
            break
        }
    }

    private static func decodeIdentity(_ data: Data, adapterID: String) -> IdentityPayload? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumIdentityBytes - 4,
            data.count >= 4 + Int(length)
        else { return nil }
        let payloadData = data.subdata(in: 4..<(4 + Int(length)))
        guard let payload = try? JSONDecoder().decode(IdentityPayload.self, from: payloadData),
            payload.adapterID == adapterID,
            isValidSessionID(payload.sessionID),
            payload.cwd.hasPrefix("/"),
            let canonical = try? canonicalData(payload), canonical == payloadData
        else { return nil }
        return payload
    }

    private static func canonicalData(_ payload: IdentityPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        (1...512).contains(value.utf8.count) && !value.hasPrefix("-")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func captureTerminalState() -> TerminalState? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        let foregroundProcessGroup = tcgetpgrp(STDIN_FILENO)
        guard foregroundProcessGroup >= 0 else { return nil }
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return nil }
        let wrapperProcessGroup = getpgrp()
        return TerminalState(
            descriptor: STDIN_FILENO,
            wrapperProcessGroup: wrapperProcessGroup,
            originalForegroundProcessGroup: foregroundProcessGroup,
            originalAttributes: attributes,
            childAttributes: nil,
            childProcessGroup: nil,
            managesForeground: foregroundProcessGroup == wrapperProcessGroup,
            isAvailable: true
        )
    }

    private static func captureChildTerminalAttributes(_ terminal: inout TerminalState?) {
        guard var state = terminal, state.managesForeground, state.isAvailable,
            let childProcessGroup = state.childProcessGroup
        else { return }
        let foregroundProcessGroup = tcgetpgrp(state.descriptor)
        guard foregroundProcessGroup == childProcessGroup else {
            if foregroundProcessGroup == -1, errno == ENOTTY {
                state.isAvailable = false
                terminal = state
            }
            return
        }
        var attributes = termios()
        if tcgetattr(state.descriptor, &attributes) == 0 {
            state.childAttributes = attributes
            terminal = state
        } else if errno == ENOTTY {
            state.isAvailable = false
            terminal = state
        }
    }

    private static func activateChild(
        _ child: pid_t,
        terminal: inout TerminalState?
    ) -> Bool {
        if var state = terminal {
            state.childProcessGroup = child
            terminal = state
        }
        if var state = terminal, state.managesForeground, state.isAvailable {
            if var attributes = state.childAttributes {
                let result = withSIGTTOUBlocked {
                    tcsetattr(state.descriptor, TCSANOW, &attributes)
                }
                if result != 0 {
                    if errno == ENOTTY {
                        state.isAvailable = false
                    } else {
                        return false
                    }
                }
            }
            if state.isAvailable {
                let result = withSIGTTOUBlocked {
                    tcsetpgrp(state.descriptor, child)
                }
                if result != 0 {
                    if errno == ENOTTY {
                        state.isAvailable = false
                    } else {
                        return false
                    }
                }
            }
            terminal = state
        }
        return Darwin.kill(-child, SIGCONT) == 0
    }

    private static func continueChild(
        _ child: pid_t,
        terminal: inout TerminalState?
    ) -> Bool {
        guard var state = terminal, state.managesForeground, state.isAvailable else {
            return Darwin.kill(-child, SIGCONT) == 0
        }
        let foregroundProcessGroup = tcgetpgrp(state.descriptor)
        if foregroundProcessGroup == -1 {
            if errno == ENOTTY {
                state.isAvailable = false
                terminal = state
                return Darwin.kill(-child, SIGCONT) == 0
            }
            return false
        }
        terminal = state
        if foregroundProcessGroup == state.wrapperProcessGroup {
            return activateChild(child, terminal: &terminal)
        }
        return Darwin.kill(-child, SIGCONT) == 0
    }

    private static func restoreTerminal(_ terminal: inout TerminalState?) -> Bool {
        guard var state = terminal, state.managesForeground, state.isAvailable else {
            return true
        }
        let foregroundProcessGroup = tcgetpgrp(state.descriptor)
        if foregroundProcessGroup == -1 {
            if errno == ENOTTY {
                state.isAvailable = false
                terminal = state
                return true
            }
            return false
        }
        guard
            foregroundProcessGroup == state.originalForegroundProcessGroup
                || foregroundProcessGroup == state.childProcessGroup
        else { return true }
        let foregroundResult = withSIGTTOUBlocked {
            tcsetpgrp(state.descriptor, state.originalForegroundProcessGroup)
        }
        if foregroundResult != 0 {
            if errno == ENOTTY {
                state.isAvailable = false
                terminal = state
                return true
            }
            return false
        }
        var attributes = state.originalAttributes
        let attributeResult = withSIGTTOUBlocked {
            tcsetattr(state.descriptor, TCSANOW, &attributes)
        }
        if attributeResult != 0 {
            if errno == ENOTTY {
                state.isAvailable = false
                terminal = state
                return true
            }
            return false
        }
        terminal = state
        return true
    }

    private static func withSIGTTOUBlocked(_ operation: () -> Int32) -> Int32 {
        var blocked = signalSet([SIGTTOU])
        var previous = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else {
            errno = EINVAL
            return -1
        }
        defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
        while true {
            let result = operation()
            if result == -1, errno == EINTR { continue }
            return result
        }
    }

    private static func reflectStop(_ signal: Int32) -> Bool {
        if signal == SIGSTOP {
            return Darwin.kill(-getpgrp(), signal) == 0
        }

        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var previousAction = sigaction()
        guard sigaction(signal, &defaultAction, &previousAction) == 0 else { return false }
        defer {
            var action = previousAction
            _ = sigaction(signal, &action, nil)
        }

        var unblocked = signalSet([signal])
        var previousMask = sigset_t()
        guard pthread_sigmask(SIG_UNBLOCK, &unblocked, &previousMask) == 0 else {
            return false
        }
        defer { _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
        return Darwin.kill(-getpgrp(), signal) == 0
    }

    private static func randomNonce() -> Data {
        var data = Data(count: AgentIPCProtocol.nonceSize)
        data.withUnsafeMutableBytes { bytes in
            arc4random_buf(bytes.baseAddress, bytes.count)
        }
        return data
    }

    private static func writeIPCData(
        _ data: Data,
        to descriptor: Int32,
        signalDescriptor: Int32
    ) -> RegisterResult? {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    switch waitForSocket(
                        descriptor,
                        events: Int16(POLLOUT),
                        signalDescriptor: signalDescriptor
                    ) {
                    case .ready:
                        continue
                    case .interrupted(let signal):
                        return .interrupted(signal)
                    case .failed:
                        return .failed
                    }
                } else {
                    return .failed
                }
            }
            return nil
        }
    }

    private static func readIPCData(
        count: Int,
        from descriptor: Int32,
        signalDescriptor: Int32
    ) -> IPCDataReadResult {
        var data = Data(capacity: count)
        while data.count < count {
            switch readIPCByte(from: descriptor, signalDescriptor: signalDescriptor) {
            case .byte(let byte):
                data.append(byte)
            case .interrupted(let signal):
                return .interrupted(signal)
            case .eof, .failed:
                return .failed
            }
        }
        return .data(data)
    }

    private static func readIPCByte(
        from descriptor: Int32,
        signalDescriptor: Int32
    ) -> IPCByteReadResult {
        while true {
            switch waitForSocket(
                descriptor,
                events: Int16(POLLIN | POLLHUP),
                signalDescriptor: signalDescriptor
            ) {
            case .interrupted(let signal):
                return .interrupted(signal)
            case .failed:
                return .failed
            case .ready:
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor, &byte, 1)
                if count == 1 { return .byte(byte) }
                if count == 0 { return .eof }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return .failed
            }
        }
    }

    private static func waitForSocket(
        _ descriptor: Int32,
        events: Int16,
        signalDescriptor: Int32
    ) -> SocketWaitResult {
        while true {
            var descriptors = [
                pollfd(fd: signalDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: descriptor, events: events, revents: 0),
            ]
            let result = poll(&descriptors, nfds_t(descriptors.count), -1)
            if result == -1 {
                if errno == EINTR { continue }
                return .failed
            }
            if descriptors[0].revents & Int16(POLLIN) != 0,
                let signal = firstTerminatingSignal(in: drainSignals(signalDescriptor))
            {
                return .interrupted(signal)
            }
            if descriptors[1].revents & Int16(events | Int16(POLLERR | POLLHUP)) != 0 {
                return .ready
            }
            if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0
                || descriptors[1].revents & Int16(POLLNVAL) != 0
            {
                return .failed
            }
        }
    }

    private static func setNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func firstTerminatingSignal(in signals: [Int32]) -> Int32? {
        signals.first { terminatingSignals.contains($0) }
    }

    private static func isStoppedStatus(_ status: Int32) -> Bool {
        status & 0x7f == 0x7f && stopSignal(status) != 0x13
    }

    private static func isContinuedStatus(_ status: Int32) -> Bool {
        status & 0x7f == 0x7f && stopSignal(status) == 0x13
    }

    private static func stopSignal(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func drainSignals(_ descriptor: Int32) -> [Int32] {
        var result: [Int32] = []
        var bytes = [UInt8](repeating: 0, count: 64)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count).map(Int32.init))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                return result
            }
        }
    }

    private static func decodedStatus(_ status: Int32) -> Int32 {
        let termination = status & 0x7f
        if termination == 0 { return (status >> 8) & 0xff }
        if termination != 0x7f { return 128 + termination }
        return EXIT_FAILURE
    }

    private static func signalSet(_ signals: [Int32]) -> sigset_t {
        var set = sigset_t()
        sigemptyset(&set)
        for signal in signals { sigaddset(&set, signal) }
        return set
    }

    private static func restoreSignalActions(_ actions: [Int32: sigaction]) {
        for (signal, storedAction) in actions {
            var action = storedAction
            _ = sigaction(signal, &action, nil)
        }
    }

    private static func configurePipe(
        _ descriptors: [Int32],
        nonblockingRead: Bool,
        nonblockingWrite: Bool
    ) -> Bool {
        guard descriptors.count == 2 else { return false }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        }
        for (descriptor, nonblocking) in zip(
            descriptors,
            [nonblockingRead, nonblockingWrite]
        ) where nonblocking {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return false
            }
        }
        return true
    }

    private static func waitForChild(_ child: pid_t) {
        while waitpid(child, nil, 0) == -1, errno == EINTR {}
    }

    #if QUICKTTY_TESTING
        private static func testPostSpawnFailure(_ child: pid_t) -> Bool {
            guard let readyValue = environmentValue("QUICKTTY_TEST_POSTSPAWN_READY_FD"),
                let releaseValue = environmentValue("QUICKTTY_TEST_POSTSPAWN_RELEASE_FD"),
                let readyDescriptor = Int32(readyValue),
                let releaseDescriptor = Int32(releaseValue)
            else { return false }
            var publishedChild = child
            guard
                Darwin.write(
                    readyDescriptor,
                    &publishedChild,
                    MemoryLayout.size(ofValue: publishedChild)
                ) == MemoryLayout.size(ofValue: publishedChild)
            else { return true }
            var byte: UInt8 = 0
            while Darwin.read(releaseDescriptor, &byte, 1) == -1, errno == EINTR {}
            Darwin.close(readyDescriptor)
            Darwin.close(releaseDescriptor)
            return true
        }
    #else
        private static func testPostSpawnFailure(_: pid_t) -> Bool { false }
    #endif

    private static func saveWrapperEnvironment() -> [String: String?] {
        [payloadKey, wrapperDirectoryKey, wrapperPathKey, identityDescriptorKey].reduce(into: [:]) {
            result, key in result[key] = environmentValue(key)
        }
    }

    private static func unsetWrapperEnvironment() {
        for key in [payloadKey, wrapperDirectoryKey, wrapperPathKey, identityDescriptorKey] {
            unsetenv(key)
        }
    }

    private static func restoreWrapperEnvironment(_ values: [String: String?]) {
        for (key, value) in values {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    private static func boundedEnvironmentValue(_ key: String, _ maximum: Int) -> String? {
        guard let pointer = getenv(key) else { return nil }
        let count = strnlen(pointer, maximum + 1)
        guard count <= maximum else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                count: count
            ),
            as: UTF8.self
        )
    }

    private static func environmentValue(_ key: String) -> String? {
        guard let pointer = getenv(key) else { return nil }
        return String(cString: pointer)
    }

    private static func canonicalPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(
            decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return canonicalPath(path)
    }

    private static func fileIdentity(_ path: String?) -> FileIdentity? {
        guard let path else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func isRegularExecutable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && access(path, X_OK) == 0
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    }
}

private enum RegisterResult {
    case acknowledged
    case rejected
    case interrupted(Int32)
    case failed
}

private enum SocketWaitResult {
    case ready
    case interrupted(Int32)
    case failed
}

private enum IPCByteReadResult {
    case byte(UInt8)
    case eof
    case interrupted(Int32)
    case failed
}

private enum IPCDataReadResult {
    case data(Data)
    case interrupted(Int32)
    case failed
}

private struct TerminalState {
    let descriptor: Int32
    let wrapperProcessGroup: pid_t
    let originalForegroundProcessGroup: pid_t
    let originalAttributes: termios
    var childAttributes: termios?
    var childProcessGroup: pid_t?
    let managesForeground: Bool
    var isAvailable: Bool
}

private struct InvocationPayload: Codable {
    let arguments: [String]
}

private struct IdentityPayload: Codable {
    let adapterID: String
    let cwd: String
    let sessionID: String
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct IPCContext {
    let identity: AgentIPCIdentity
    let client: AgentSocketClient
}
