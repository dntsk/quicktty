import Darwin
import Foundation

private let maximumSourceSize: off_t = 256 * 1_024 * 1_024
private let stagePrefix = ".quicktty-copy."

private enum CopyCLIHelperError: Error {
    case invalidArguments
    case invalidDestination
    case invalidSource
    case invalidContents
    case invalidHelpers
    case invalidExistingDestination
    case identicalSourceAndDestination
    case stageCreationFailed
    case copyFailed
    case persistenceFailed
    case replacementFailed

    var message: String {
        switch self {
        case .invalidArguments:
            "expected source executable and destination arguments"
        case .invalidDestination:
            "destination must end in QuickTTY.app/Contents/Helpers/quicktty"
        case .invalidSource:
            "source executable is invalid"
        case .invalidContents:
            "app Contents directory is invalid"
        case .invalidHelpers:
            "helper destination directory is invalid"
        case .invalidExistingDestination:
            "existing destination is invalid"
        case .identicalSourceAndDestination:
            "source and destination must differ"
        case .stageCreationFailed:
            "could not create staging file"
        case .copyFailed:
            "could not copy helper executable"
        case .persistenceFailed:
            "could not persist helper executable"
        case .replacementFailed:
            "could not replace helper executable"
        }
    }
}

private func canonicalPath(for descriptor: Int32, error: CopyCLIHelperError) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        fcntl(descriptor, F_GETPATH, pointer.baseAddress!)
    }
    guard result != -1 else {
        throw error
    }
    return String(cString: buffer)
}

private func sync(_ descriptor: Int32) throws {
    while fsync(descriptor) != 0 {
        guard errno == EINTR else {
            throw CopyCLIHelperError.persistenceFailed
        }
    }
}

private func makeStage(in helpersDescriptor: Int32) throws -> (name: String, descriptor: Int32) {
    for _ in 0..<128 {
        let name = stagePrefix + UUID().uuidString.lowercased()
        let descriptor = openat(
            helpersDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o755)
        )
        if descriptor >= 0 {
            return (name, descriptor)
        }
        guard errno == EEXIST else {
            throw CopyCLIHelperError.stageCreationFailed
        }
    }
    throw CopyCLIHelperError.stageCreationFailed
}

#if QUICKTTY_COPY_CLI_HELPER_TESTING
    private func appendToSourceForGrowthTest(_ sourcePath: String) throws {
        guard getenv("QUICKTTY_COPY_CLI_HELPER_APPEND_AFTER_FSTAT") != nil else {
            return
        }

        let descriptor = open(sourcePath, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CopyCLIHelperError.copyFailed
        }
        defer { close(descriptor) }

        var byte: UInt8 = 0
        while true {
            let writeCount = withUnsafePointer(to: &byte) {
                write(descriptor, $0, 1)
            }
            if writeCount == 1 {
                return
            }
            if writeCount < 0, errno == EINTR {
                continue
            }
            throw CopyCLIHelperError.copyFailed
        }
    }
#endif

private func copyBytes(
    from sourceDescriptor: Int32,
    to destinationDescriptor: Int32,
    expectedByteCount: off_t
) throws {
    guard var remainingByteCount = Int(exactly: expectedByteCount), remainingByteCount >= 0 else {
        throw CopyCLIHelperError.copyFailed
    }
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

    while remainingByteCount > 0 {
        let requestedByteCount = min(buffer.count, remainingByteCount)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            read(sourceDescriptor, bytes.baseAddress, requestedByteCount)
        }
        if readCount == 0 {
            throw CopyCLIHelperError.copyFailed
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            throw CopyCLIHelperError.copyFailed
        }
        guard readCount <= requestedByteCount else {
            throw CopyCLIHelperError.copyFailed
        }

        var offset = 0
        while offset < readCount {
            let writeCount = buffer.withUnsafeBytes { bytes in
                write(
                    destinationDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    readCount - offset
                )
            }
            if writeCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw CopyCLIHelperError.copyFailed
            }
            guard writeCount > 0 else {
                throw CopyCLIHelperError.copyFailed
            }
            offset += writeCount
        }
        remainingByteCount -= readCount
    }

    var probeByte: UInt8 = 0
    while true {
        let readCount = withUnsafeMutablePointer(to: &probeByte) {
            read(sourceDescriptor, $0, 1)
        }
        if readCount == 0 {
            return
        }
        if readCount < 0, errno == EINTR {
            continue
        }
        throw CopyCLIHelperError.copyFailed
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw CopyCLIHelperError.invalidArguments
    }

    let sourcePath = CommandLine.arguments[1]
    let destinationPath = CommandLine.arguments[2]
    let destinationSuffix = "/QuickTTY.app/Contents/Helpers/quicktty"
    let helpersSuffix = "/Helpers/quicktty"
    guard destinationPath.hasSuffix(destinationSuffix) else {
        throw CopyCLIHelperError.invalidDestination
    }
    let contentsPath = String(destinationPath.dropLast(helpersSuffix.count))

    let sourceDescriptor = open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else {
        throw CopyCLIHelperError.invalidSource
    }
    defer { close(sourceDescriptor) }

    var sourceStatus = stat()
    guard fstat(sourceDescriptor, &sourceStatus) == 0,
        sourceStatus.st_mode & S_IFMT == S_IFREG,
        sourceStatus.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
        sourceStatus.st_size > 0,
        sourceStatus.st_size <= maximumSourceSize
    else {
        throw CopyCLIHelperError.invalidSource
    }

    #if QUICKTTY_COPY_CLI_HELPER_TESTING
        try appendToSourceForGrowthTest(sourcePath)
    #endif

    let contentsDescriptor = open(
        contentsPath,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard contentsDescriptor >= 0 else {
        throw CopyCLIHelperError.invalidContents
    }
    defer { close(contentsDescriptor) }

    let canonicalContents = try canonicalPath(
        for: contentsDescriptor,
        error: .invalidContents
    )
    guard canonicalContents.hasSuffix("/QuickTTY.app/Contents") else {
        throw CopyCLIHelperError.invalidContents
    }

    if mkdirat(contentsDescriptor, "Helpers", mode_t(0o755)) != 0, errno != EEXIST {
        throw CopyCLIHelperError.invalidHelpers
    }

    let helpersDescriptor = openat(
        contentsDescriptor,
        "Helpers",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard helpersDescriptor >= 0 else {
        throw CopyCLIHelperError.invalidHelpers
    }
    defer { close(helpersDescriptor) }

    let canonicalHelpers = try canonicalPath(
        for: helpersDescriptor,
        error: .invalidHelpers
    )
    guard canonicalHelpers == canonicalContents + "/Helpers" else {
        throw CopyCLIHelperError.invalidHelpers
    }

    var destinationStatus = stat()
    if fstatat(
        helpersDescriptor,
        "quicktty",
        &destinationStatus,
        AT_SYMLINK_NOFOLLOW
    ) == 0 {
        guard destinationStatus.st_mode & S_IFMT == S_IFREG else {
            throw CopyCLIHelperError.invalidExistingDestination
        }
        guard
            sourceStatus.st_dev != destinationStatus.st_dev
                || sourceStatus.st_ino != destinationStatus.st_ino
        else {
            throw CopyCLIHelperError.identicalSourceAndDestination
        }
    } else if errno != ENOENT {
        throw CopyCLIHelperError.invalidExistingDestination
    }

    let stage = try makeStage(in: helpersDescriptor)
    var stageDescriptor = stage.descriptor
    var stageName: String? = stage.name
    defer {
        if stageDescriptor >= 0 {
            close(stageDescriptor)
        }
        if let stageName {
            unlinkat(helpersDescriptor, stageName, 0)
        }
    }

    try copyBytes(
        from: sourceDescriptor,
        to: stageDescriptor,
        expectedByteCount: sourceStatus.st_size
    )
    guard fchmod(stageDescriptor, mode_t(0o755)) == 0 else {
        throw CopyCLIHelperError.copyFailed
    }
    try sync(stageDescriptor)
    guard close(stageDescriptor) == 0 else {
        stageDescriptor = -1
        throw CopyCLIHelperError.persistenceFailed
    }
    stageDescriptor = -1

    guard renameat(helpersDescriptor, stage.name, helpersDescriptor, "quicktty") == 0 else {
        throw CopyCLIHelperError.replacementFailed
    }
    stageName = nil
    try sync(helpersDescriptor)
}

do {
    try run()
} catch let error as CopyCLIHelperError {
    FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
    exit(EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data("error: copy failed\n".utf8))
    exit(EXIT_FAILURE)
}
