import Foundation

enum AgentWorkingDirectoryValidator {
    private static let maximumUTF8ByteCount = 4_096
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard (1...maximumUTF8ByteCount).contains(bytes.count),
            bytes[0] == slash,
            !containsControlByteSequence(bytes),
            path.precomposedStringWithCanonicalMapping.utf8.elementsEqual(bytes)
        else {
            return false
        }
        guard bytes.count > 1 else { return true }
        guard bytes[1] != slash, bytes[bytes.count - 1] != slash else { return false }

        var segmentStart = 1
        for index in 1..<bytes.count where bytes[index] == slash {
            guard isCanonicalSegment(bytes[segmentStart..<index]) else { return false }
            segmentStart = index + 1
        }
        return isCanonicalSegment(bytes[segmentStart..<bytes.count])
    }

    private static func isCanonicalSegment(_ segment: ArraySlice<UInt8>) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.count == 1 {
            return segment.first != dot
        }
        if segment.count == 2 {
            let start = segment.startIndex
            return segment[start] != dot || segment[segment.index(after: start)] != dot
        }
        return true
    }

    private static func containsControlByteSequence(_ bytes: [UInt8]) -> Bool {
        for index in bytes.indices {
            let byte = bytes[index]
            if byte < 0x20 || byte == 0x7f {
                return true
            }
            if byte == 0xc2,
                index + 1 < bytes.count,
                (0x80...0x9f).contains(bytes[index + 1])
            {
                return true
            }
        }
        return false
    }
}
