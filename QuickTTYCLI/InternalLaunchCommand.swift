import Darwin
import Foundation

enum InternalLaunchCommand {
    private static let failureMessage = "quicktty: internal launch failed\n"

    static func run() -> Int32 {
        guard let payloadValue = getenv(AgentInvocationPayloadEnvironment.payloadKey) else {
            return fail()
        }
        let payloadByteCount = strnlen(
            payloadValue,
            AgentInvocationPayloadCodec.maximumBase64Size + 1
        )
        guard payloadByteCount <= AgentInvocationPayloadCodec.maximumBase64Size else {
            return fail()
        }
        let payloadBytes = UnsafeRawPointer(payloadValue).assumingMemoryBound(to: UInt8.self)
        let encodedPayload = String(
            decoding: UnsafeBufferPointer(start: payloadBytes, count: payloadByteCount),
            as: UTF8.self
        )
        guard let payload = try? AgentInvocationPayloadCodec.decodeBase64(encodedPayload) else {
            return fail()
        }

        var argumentPointers = ([payload.executable] + payload.arguments).map { strdup($0) }
        guard argumentPointers.allSatisfy({ $0 != nil }) else {
            for pointer in argumentPointers {
                free(pointer)
            }
            return fail()
        }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers {
                free(pointer)
            }
        }

        unsetenv(AgentInvocationPayloadEnvironment.payloadKey)
        unsetenv(AgentInvocationPayloadEnvironment.helperKey)

        if let workingDirectory = payload.workingDirectory, chdir(workingDirectory) != 0 {
            return fail()
        }

        let result = argumentPointers.withUnsafeMutableBufferPointer { pointers in
            execv(pointers[0], pointers.baseAddress!)
        }
        precondition(result == -1)
        return fail()
    }

    private static func fail() -> Int32 {
        FileHandle.standardError.write(Data(failureMessage.utf8))
        return EXIT_FAILURE
    }
}
