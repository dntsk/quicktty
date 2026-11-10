import Darwin
import Foundation

struct AgentMessagingSocketClient: Sendable {
    let identity: TerminalControlEnvironment

    func send(_ request: AgentMessagingRequest) throws -> AgentMessagingResponse {
        try request.validate()
        let deadline = try AgentSocketDeadline(timeoutMilliseconds: 40_000)
        let preflight = try TerminalControlPreflight(
            instanceID: identity.instanceID, paneID: identity.paneID,
            nonce: AgentMessagingProtocol.randomBytes()
        )
        var address = try AgentUnixSocketAddress(path: identity.socketPath)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentMessagingProtocolError.transportFailure }
        defer { Darwin.close(descriptor) }
        try AgentSocketIO.disableSIGPIPE(on: descriptor)
        try AgentSocketIO.makeNonblocking(descriptor)
        try AgentSocketIO.connect(descriptor, to: &address, deadline: deadline)
        try AgentSocketIO.writeAll(
            TerminalControlProtocol.encodePreflight(preflight), to: descriptor, deadline: deadline)
        guard try AgentSocketIO.readByte(from: descriptor, deadline: deadline) == 1,
            let challenge = try AgentSocketIO.readExactly(32, from: descriptor, deadline: deadline),
            let proof = try AgentSocketIO.readExactly(32, from: descriptor, deadline: deadline),
            AgentMessagingProtocol.verifyServerProof(
                proof, preflight: preflight, challenge: challenge, token: identity.paneToken)
        else { throw AgentMessagingProtocolError.authenticationFailed }
        let frame = try AgentMessagingProtocol.requestFrame(
            request, preflight: preflight, challenge: challenge, token: identity.paneToken)
        try AgentSocketIO.writeAll(frame, to: descriptor, deadline: deadline)
        try AgentSocketIO.shutdownWrite(descriptor, deadline: deadline)
        guard let header = try AgentSocketIO.readExactly(4, from: descriptor, deadline: deadline)
        else {
            throw AgentMessagingProtocolError.transportFailure
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= AgentMessagingProtocol.maximumResponseBytes,
            let body = try AgentSocketIO.readExactly(
                Int(length) + 32, from: descriptor, deadline: deadline)
        else { throw AgentMessagingProtocolError.invalidPayload }
        let response = try AgentMessagingProtocol.decodeResponseFrame(
            header + body, request: request, preflight: preflight,
            challenge: challenge, token: identity.paneToken
        )
        guard try AgentSocketIO.readByte(from: descriptor, deadline: deadline) == nil else {
            throw AgentMessagingProtocolError.invalidPayload
        }
        return response
    }
}
