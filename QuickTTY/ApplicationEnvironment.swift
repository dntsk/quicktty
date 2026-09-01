import Darwin
import Foundation

enum ApplicationEnvironment {
    private static let maximumPathBytes = 16_384
    private static let maximumPathEntryCount = 128
    private static let maximumPathEntryBytes = 1_024
    private static let maximumExecutableCandidateBytes = 256
    private static let maximumResolvedPathBytes = 4_096

    static var isRunningHostedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func effectiveGUIExecutableSearchPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var additionalEntries = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let home = environment["HOME"], isValidAbsolutePathEntry(home) {
            let localBin = (home as NSString).appendingPathComponent(".local/bin")
            if isValidAbsolutePathEntry(localBin) {
                additionalEntries.append(localBin)
            }
        }

        var entries: [String] = []
        var seen: Set<String> = []
        var byteCount = 0
        let reservedBytes = additionalEntries.reduce(0) { $0 + $1.utf8.count + 1 }
        let maximumEnvironmentEntryCount = maximumPathEntryCount - additionalEntries.count
        let environmentByteLimit = maximumPathBytes - reservedBytes

        if let path = environment["PATH"], path.utf8.count <= maximumPathBytes {
            for rawEntry in path.split(separator: ":", omittingEmptySubsequences: false)
                .prefix(maximumPathEntryCount)
            {
                let entry = String(rawEntry)
                guard entries.count < maximumEnvironmentEntryCount,
                    isValidAbsolutePathEntry(entry),
                    !seen.contains(entry)
                else { continue }
                let addedBytes = entry.utf8.count + (entries.isEmpty ? 0 : 1)
                guard byteCount + addedBytes <= environmentByteLimit else { continue }
                entries.append(entry)
                seen.insert(entry)
                byteCount += addedBytes
            }
        }

        for entry in additionalEntries where !seen.contains(entry) {
            let addedBytes = entry.utf8.count + (entries.isEmpty ? 0 : 1)
            guard entries.count < maximumPathEntryCount,
                byteCount + addedBytes <= maximumPathBytes
            else { continue }
            entries.append(entry)
            seen.insert(entry)
            byteCount += addedBytes
        }
        return entries.joined(separator: ":")
    }

    static func isExecutableAvailable(_ executable: String, searchPath: String) -> Bool {
        guard !executable.isEmpty,
            executable.utf8.count <= maximumExecutableCandidateBytes,
            !executable.contains("/"),
            !executable.contains("\0"),
            searchPath.utf8.count <= maximumPathBytes
        else { return false }

        return searchPath.split(separator: ":", omittingEmptySubsequences: false)
            .prefix(maximumPathEntryCount)
            .contains(where: { rawDirectory in
                let directory = String(rawDirectory)
                guard isValidAbsolutePathEntry(directory) else { return false }
                let candidate = directory + "/" + executable
                guard let resolvedPointer = candidate.withCString({ realpath($0, nil) }) else {
                    return false
                }
                defer { free(resolvedPointer) }
                let resolved = String(cString: resolvedPointer)
                guard resolved.hasPrefix("/"),
                    resolved.utf8.count <= maximumResolvedPathBytes,
                    !resolved.contains("\0")
                else { return false }

                var information = stat()
                return resolved.withCString({ Darwin.lstat($0, &information) }) == 0
                    && information.st_mode & S_IFMT == S_IFREG
                    && resolved.withCString({ Darwin.access($0, X_OK) }) == 0
            })
    }

    static func bundledAgentHelperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "quicktty")
            .standardizedFileURL
    }

    private static func isValidAbsolutePathEntry(_ entry: String) -> Bool {
        !entry.isEmpty
            && entry.utf8.count <= maximumPathEntryBytes
            && (entry as NSString).isAbsolutePath
            && !entry.utf8.contains { $0 < 0x20 || $0 == 0x3A || $0 == 0x7F }
    }
}
