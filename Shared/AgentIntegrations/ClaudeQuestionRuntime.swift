import CryptoKit
import Darwin
import Foundation

enum ClaudeQuestionRuntime {
    static let installedHookEvent = AgentIntegrationInstaller.claudeQuestionHookEvent
    static let verifiedVersion = "2.1.318"

    struct Caller: Sendable {
        let parentPID: pid_t
        let uid: uid_t
        let executable: String
    }

    static func isVerified(
        parentPID: pid_t = getppid(), uid: uid_t = geteuid(),
        caller: (pid_t) -> Caller? = lookup,
        fingerprint: (String) throws -> String = ClaudeQuestionRuntime.fingerprint
    ) -> Bool {
        var pid = parentPID
        for _ in 0..<4 {
            guard pid > 1, let current = caller(pid), current.uid == uid else { return false }
            if ["/bin/sh", "/bin/bash", "/bin/zsh"].contains(current.executable) {
                pid = current.parentPID
                continue
            }
            // Only system shells are transparent: renamed/new callers cannot borrow an ancestor's version.
            // Compatibility follows the verified artifact bytes, not a user-controlled filename.
            return (try? fingerprint(current.executable))
                == "677a2ea7bf576cedd20e191d973914ed8a41796f53a63b1923381ddc4d5b5e7d"
        }
        return false
    }

    static func fingerprint(_ path: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var digest = SHA256()
        var total = 0
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            total += bytes.count
            guard total <= 536_870_912 else { throw AgentMessagingProtocolError.invalidPayload }
            digest.update(data: bytes)
        }
        guard total > 0 else { throw AgentMessagingProtocolError.invalidPayload }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func lookup(_ pid: pid_t) -> Caller? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
            let executable = String(
                validating: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self)
        else { return nil }
        return Caller(parentPID: pid_t(info.pbi_ppid), uid: info.pbi_uid, executable: executable)
    }
}
