import Darwin
import Foundation

enum AgentSocketClientPhase: Equatable, Sendable {
    case connect
    case challenge
    case frameWrite
    case acknowledgement
}

public struct AgentSocketClient: Sendable {
    typealias NonceGenerator = @Sendable () -> Data
    typealias PhaseObserver = @Sendable (AgentSocketClientPhase) -> Void

    public static let defaultTimeoutMilliseconds = 2_000

    public let socketPath: String
    public let timeoutMilliseconds: Int

    private let nonceGenerator: NonceGenerator
    private let phaseObserver: PhaseObserver

    public init(
        socketPath: String,
        timeoutMilliseconds: Int = AgentSocketClient.defaultTimeoutMilliseconds
    ) {
        precondition((1...60_000).contains(timeoutMilliseconds))
        self.socketPath = socketPath
        self.timeoutMilliseconds = timeoutMilliseconds
        nonceGenerator = { @Sendable in AgentSocketClient.randomNonce() }
        phaseObserver = { _ in }
    }

    init(
        socketPath: String,
        timeoutMilliseconds: Int,
        nonceGenerator: @escaping NonceGenerator,
        phaseObserver: @escaping PhaseObserver = { _ in }
    ) {
        precondition((1...60_000).contains(timeoutMilliseconds))
        self.socketPath = socketPath
        self.timeoutMilliseconds = timeoutMilliseconds
        self.nonceGenerator = nonceGenerator
        self.phaseObserver = phaseObserver
    }

    public func send(_ message: AgentIPCMessage) throws -> Bool {
        let deadline = try AgentSocketDeadline(timeoutMilliseconds: timeoutMilliseconds)
        let identity = message.identity
        let preflight = try AgentIPCPreflight(
            instanceID: identity.instanceID,
            paneID: identity.paneID,
            nonce: nonceGenerator()
        )
        let preflightData = try AgentIPCProtocol.encodePreflight(preflight)
        let frame = try AgentIPCProtocol.encodeFrame(message, for: preflight)

        var address: AgentUnixSocketAddress
        do {
            address = try AgentUnixSocketAddress(path: socketPath)
        } catch {
            throw AgentSocketClientError.invalidSocketPath
        }
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AgentSocketClientError.systemCall("socket", errno)
        }
        defer { Darwin.close(fileDescriptor) }

        try AgentSocketIO.disableSIGPIPE(on: fileDescriptor)
        try AgentSocketIO.makeNonblocking(fileDescriptor)
        phaseObserver(.connect)
        try AgentSocketIO.connect(fileDescriptor, to: &address, deadline: deadline)
        try AgentSocketIO.writeAll(preflightData, to: fileDescriptor, deadline: deadline)

        phaseObserver(.challenge)
        guard
            let challengeStatus = try AgentSocketIO.readByte(
                from: fileDescriptor,
                deadline: deadline
            )
        else {
            throw AgentSocketClientError.missingChallenge
        }
        guard challengeStatus == 1 else {
            if challengeStatus == 0 {
                return false
            }
            throw AgentSocketClientError.invalidChallenge
        }
        guard
            let proof = try AgentSocketIO.readExactly(
                AgentIPCProtocol.proofSize,
                from: fileDescriptor,
                deadline: deadline
            )
        else {
            throw AgentSocketClientError.missingChallenge
        }
        guard
            AgentIPCProtocol.verifyServerProof(
                proof,
                for: preflight,
                paneToken: identity.paneToken
            )
        else {
            throw AgentSocketClientError.serverAuthenticationFailed
        }

        phaseObserver(.frameWrite)
        try AgentSocketIO.writeAll(frame, to: fileDescriptor, deadline: deadline)
        try AgentSocketIO.shutdownWrite(fileDescriptor, deadline: deadline)

        phaseObserver(.acknowledgement)
        guard
            let acknowledgement = try AgentSocketIO.readByte(
                from: fileDescriptor,
                deadline: deadline
            )
        else {
            throw AgentSocketClientError.missingAcknowledgement
        }
        guard acknowledgement == 0 || acknowledgement == 1 else {
            throw AgentSocketClientError.invalidAcknowledgement
        }
        guard
            try AgentSocketIO.readByte(from: fileDescriptor, deadline: deadline) == nil
        else {
            throw AgentSocketClientError.trailingAcknowledgement
        }
        return acknowledgement == 1
    }

    public static func send(_ message: AgentIPCMessage, to socketPath: String) throws -> Bool {
        try AgentSocketClient(socketPath: socketPath).send(message)
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<AgentIPCProtocol.nonceSize).map { _ in
                UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            })
    }
}

public enum AgentSocketClientError: Error, Equatable, Sendable {
    case invalidSocketPath
    case timedOut
    case missingChallenge
    case invalidChallenge
    case serverAuthenticationFailed
    case systemCall(String, Int32)
    case missingAcknowledgement
    case invalidAcknowledgement
    case trailingAcknowledgement
}

struct AgentSocketDeadline: Sendable {
    private let deadlineNanoseconds: UInt64

    init(timeoutMilliseconds: Int) throws {
        let now = try Self.monotonicNanoseconds()
        let duration = UInt64(timeoutMilliseconds) * 1_000_000
        let (deadline, overflow) = now.addingReportingOverflow(duration)
        guard !overflow else {
            throw AgentSocketClientError.timedOut
        }
        deadlineNanoseconds = deadline
    }

    func remainingMilliseconds() throws -> Int32 {
        let now = try Self.monotonicNanoseconds()
        guard now < deadlineNanoseconds else {
            throw AgentSocketClientError.timedOut
        }
        let remaining = (deadlineNanoseconds - now + 999_999) / 1_000_000
        return Int32(min(remaining, UInt64(Int32.max)))
    }

    func check() throws {
        _ = try remainingMilliseconds()
    }

    private static func monotonicNanoseconds() throws -> UInt64 {
        var currentTime = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &currentTime) == 0 else {
            throw AgentSocketClientError.systemCall("clock_gettime", errno)
        }
        return UInt64(currentTime.tv_sec) * 1_000_000_000 + UInt64(currentTime.tv_nsec)
    }
}

enum AgentUnixSocketAddressError: Error, Equatable, Sendable {
    case invalidPath
}

struct AgentUnixSocketAddress {
    private var address: sockaddr_un
    private let length: socklen_t

    init(path: String) throws {
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard !pathBytes.isEmpty,
            !pathBytes.contains(0),
            pathBytes.count < pathCapacity
        else {
            throw AgentUnixSocketAddressError.invalidPath
        }

        var address = sockaddr_un()
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        let addressLength = pathOffset + pathBytes.count + 1
        guard addressLength <= Int(UInt8.max) else {
            throw AgentUnixSocketAddressError.invalidPath
        }

        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        self.address = address
        length = socklen_t(addressLength)
    }

    mutating func withSockAddr<Result>(
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }
}

enum AgentSocketIO {
    static func disableSIGPIPE(on fileDescriptor: Int32) throws {
        var enabled: Int32 = 1
        guard
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout.size(ofValue: enabled))
            ) == 0
        else {
            throw AgentSocketClientError.systemCall("setsockopt", errno)
        }
    }

    static func makeNonblocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AgentSocketClientError.systemCall("fcntl", errno)
        }
    }

    static func connect(
        _ fileDescriptor: Int32,
        to address: inout AgentUnixSocketAddress,
        deadline: AgentSocketDeadline
    ) throws {
        try deadline.check()
        while true {
            let result = address.withSockAddr { pointer, length in
                Darwin.connect(fileDescriptor, pointer, length)
            }
            if result == 0 || (result < 0 && errno == EISCONN) {
                return
            }
            if result < 0, errno == EINTR {
                try deadline.check()
                continue
            }
            guard result < 0, errno == EINPROGRESS || errno == EALREADY else {
                throw AgentSocketClientError.systemCall("connect", errno)
            }
            try wait(fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: socketError))
            guard
                getsockopt(fileDescriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0
            else {
                throw AgentSocketClientError.systemCall("getsockopt", errno)
            }
            guard socketError == 0 else {
                if socketError == EINPROGRESS || socketError == EALREADY {
                    continue
                }
                throw AgentSocketClientError.systemCall("connect", socketError)
            }
            return
        }
    }

    static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        let deadline = try AgentSocketDeadline(
            timeoutMilliseconds: AgentSocketClient.defaultTimeoutMilliseconds
        )
        try writeAll(data, to: fileDescriptor, deadline: deadline)
    }

    static func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        deadline: AgentSocketDeadline
    ) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                let result = Darwin.write(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0,
                    errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
                {
                    continue
                } else {
                    throw AgentSocketClientError.systemCall("write", errno)
                }
            }
        }
    }

    static func shutdownWrite(_ fileDescriptor: Int32) throws {
        let deadline = try AgentSocketDeadline(
            timeoutMilliseconds: AgentSocketClient.defaultTimeoutMilliseconds
        )
        try shutdownWrite(fileDescriptor, deadline: deadline)
    }

    static func shutdownWrite(
        _ fileDescriptor: Int32,
        deadline: AgentSocketDeadline
    ) throws {
        while true {
            try deadline.check()
            if Darwin.shutdown(fileDescriptor, SHUT_WR) == 0 {
                return
            }
            guard errno == EINTR else {
                throw AgentSocketClientError.systemCall("shutdown", errno)
            }
        }
    }

    static func readByte(from fileDescriptor: Int32) throws -> UInt8? {
        let deadline = try AgentSocketDeadline(
            timeoutMilliseconds: AgentSocketClient.defaultTimeoutMilliseconds
        )
        return try readByte(from: fileDescriptor, deadline: deadline)
    }

    static func readByte(
        from fileDescriptor: Int32,
        deadline: AgentSocketDeadline
    ) throws -> UInt8? {
        var byte: UInt8 = 0
        while true {
            try wait(fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let result = Darwin.read(fileDescriptor, &byte, 1)
            if result == 1 {
                return byte
            }
            if result == 0 {
                return nil
            }
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw AgentSocketClientError.systemCall("read", errno)
            }
        }
    }

    static func readExactly(
        _ count: Int,
        from fileDescriptor: Int32,
        deadline: AgentSocketDeadline
    ) throws -> Data? {
        var data = Data(count: count)
        let bytesRead = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < count {
                try wait(fileDescriptor, events: Int16(POLLIN), deadline: deadline)
                let result = Darwin.read(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    return offset
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw AgentSocketClientError.systemCall("read", errno)
                }
            }
            return offset
        }
        return bytesRead == count ? data : nil
    }

    private static func wait(
        _ fileDescriptor: Int32,
        events: Int16,
        deadline: AgentSocketDeadline
    ) throws {
        while true {
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, try deadline.remainingMilliseconds())
            if result > 0 {
                try deadline.check()
                return
            }
            if result == 0 {
                throw AgentSocketClientError.timedOut
            }
            if errno != EINTR {
                throw AgentSocketClientError.systemCall("poll", errno)
            }
        }
    }
}
