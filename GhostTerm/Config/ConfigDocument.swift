import Foundation

struct ConfigDiagnostic: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case malformedAssignment
        case unknownKey
        case emptyValue
        case invalidPresentationMode
        case invalidHotKey(HotKeyDescriptor.ParseError)
        case invalidNumber(expected: String)
        case invalidBoolean
    }

    let line: Int
    let key: String?
    let reason: Reason
}

extension ConfigDiagnostic: LocalizedError {
    var errorDescription: String? {
        let prefix = key.map { "Line \(line), \($0)" } ?? "Line \(line)"
        switch reason {
        case .malformedAssignment:
            return "\(prefix): expected 'key = value'."
        case .unknownKey:
            return "\(prefix): unknown GhostTerm option."
        case .emptyValue:
            return "\(prefix): value is empty."
        case .invalidPresentationMode:
            return "\(prefix): expected 'normal' or 'quake'."
        case .invalidHotKey(let error):
            return "\(prefix): \(error.localizedDescription)"
        case .invalidNumber(let expected):
            return "\(prefix): expected \(expected)."
        case .invalidBoolean:
            return "\(prefix): expected 'true' or 'false'."
        }
    }
}

struct ConfigParseResult: Equatable, Sendable {
    let config: GhostTermConfig
    let diagnostics: [ConfigDiagnostic]
}

struct ConfigDocument: Equatable, Sendable {
    private struct Line: Equatable, Sendable {
        var content: Data
        var terminator: Data
    }

    private struct Assignment {
        let key: String?
        let value: String?
        let valueRange: Range<Int>?
        let belongsToGhostTerm: Bool
        let malformed: Bool
    }

    private var lines: [Line]

    init(data: Data) {
        lines = Self.splitLines(data)
    }

    init(text: String) {
        self.init(data: Data(text.utf8))
    }

    var data: Data {
        lines.reduce(into: Data()) {
            $0.append($1.content)
            $0.append($1.terminator)
        }
    }

    var filteredGhosttyData: Data {
        lines.reduce(into: Data()) { result, line in
            guard !Self.assignment(in: line.content).belongsToGhostTerm else { return }
            result.append(line.content)
            result.append(line.terminator)
        }
    }

    func parse() -> ConfigParseResult {
        var config = GhostTermConfig()
        var diagnostics: [ConfigDiagnostic] = []

        for (index, line) in lines.enumerated() {
            let assignment = Self.assignment(in: line.content)
            guard assignment.belongsToGhostTerm else { continue }
            guard !assignment.malformed, let keyName = assignment.key else {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: index + 1, key: assignment.key, reason: .malformedAssignment)
                )
                continue
            }
            guard let key = GhostTermConfig.Key(rawValue: keyName) else {
                diagnostics.append(
                    ConfigDiagnostic(line: index + 1, key: keyName, reason: .unknownKey)
                )
                continue
            }
            guard let value = assignment.value, !value.isEmpty else {
                diagnostics.append(
                    ConfigDiagnostic(line: index + 1, key: keyName, reason: .emptyValue)
                )
                continue
            }
            Self.apply(
                value,
                for: key,
                line: index + 1,
                to: &config,
                diagnostics: &diagnostics
            )
        }

        return ConfigParseResult(config: config, diagnostics: diagnostics)
    }

    mutating func setValue(_ value: String, for key: GhostTermConfig.Key) {
        for index in lines.indices.reversed() {
            let assignment = Self.assignment(in: lines[index].content)
            guard assignment.key == key.rawValue, let valueRange = assignment.valueRange else {
                continue
            }
            var updated = Data()
            updated.append(lines[index].content.prefix(valueRange.lowerBound))
            updated.append(contentsOf: value.utf8)
            updated.append(lines[index].content.suffix(from: valueRange.upperBound))
            lines[index].content = updated
            return
        }

        let terminator = preferredTerminator
        if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
            lines[lines.count - 1].terminator = terminator
        }
        lines.append(
            Line(
                content: Data("\(key.rawValue) = \(value)".utf8),
                terminator: terminator
            )
        )
    }

    static func formattedQuakeHeight(_ fraction: Double) -> String {
        precondition(fraction.isFinite && fraction > 0 && fraction <= 1)

        var percentage = String(
            format: "%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            fraction * 100
        )
        while percentage.last == "0" {
            percentage.removeLast()
        }
        if percentage.last == "." {
            percentage.removeLast()
        }
        return "\(percentage)%"
    }

    mutating func setPresentationMode(_ mode: PresentationMode) {
        setValue(mode.rawValue, for: .presentationMode)
    }

    mutating func setQuakeHeight(_ fraction: Double) {
        setValue(Self.formattedQuakeHeight(fraction), for: .quakeHeight)
    }

    private var preferredTerminator: Data {
        lines.lazy.map(\.terminator).first(where: { !$0.isEmpty }) ?? Data([0x0A])
    }

    private static func splitLines(_ data: Data) -> [Line] {
        let bytes = [UInt8](data)
        var result: [Line] = []
        var start = 0
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x0A || bytes[index] == 0x0D else {
                index += 1
                continue
            }
            let terminatorEnd =
                bytes[index] == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A
                ? index + 2 : index + 1
            result.append(
                Line(
                    content: Data(bytes[start..<index]),
                    terminator: Data(bytes[index..<terminatorEnd])
                )
            )
            start = terminatorEnd
            index = terminatorEnd
        }

        if start < bytes.count {
            result.append(Line(content: Data(bytes[start...]), terminator: Data()))
        }
        return result
    }

    private static func assignment(in data: Data) -> Assignment {
        let bytes = [UInt8](data)
        var first = 0
        while first < bytes.count, isHorizontalWhitespace(bytes[first]) {
            first += 1
        }
        guard first < bytes.count, bytes[first] != 0x23 else {
            return Assignment(
                key: nil,
                value: nil,
                valueRange: nil,
                belongsToGhostTerm: false,
                malformed: false
            )
        }

        guard let equals = bytes[first...].firstIndex(of: 0x3D) else {
            let tokenEnd = bytes[first...].firstIndex(where: isHorizontalWhitespace) ?? bytes.count
            let token = String(bytes: bytes[first..<tokenEnd], encoding: .utf8)
            let belongs = token?.hasPrefix("ghostterm-") == true
            return Assignment(
                key: token,
                value: nil,
                valueRange: nil,
                belongsToGhostTerm: belongs,
                malformed: belongs
            )
        }

        var keyEnd = equals
        while keyEnd > first, isHorizontalWhitespace(bytes[keyEnd - 1]) {
            keyEnd -= 1
        }
        let key = String(bytes: bytes[first..<keyEnd], encoding: .utf8)
        let belongs = key?.hasPrefix("ghostterm-") == true
        guard belongs else {
            return Assignment(
                key: key,
                value: nil,
                valueRange: nil,
                belongsToGhostTerm: false,
                malformed: false
            )
        }

        var valueStart = equals + 1
        while valueStart < bytes.count, isHorizontalWhitespace(bytes[valueStart]) {
            valueStart += 1
        }
        let commentStart = bytes[valueStart...].firstIndex(of: 0x23) ?? bytes.count
        var valueEnd = commentStart
        while valueEnd > valueStart, isHorizontalWhitespace(bytes[valueEnd - 1]) {
            valueEnd -= 1
        }
        let value = String(bytes: bytes[valueStart..<valueEnd], encoding: .utf8)
        return Assignment(
            key: key,
            value: value,
            valueRange: valueStart..<valueEnd,
            belongsToGhostTerm: true,
            malformed: value == nil
        )
    }

    private static func apply(
        _ value: String,
        for key: GhostTermConfig.Key,
        line: Int,
        to config: inout GhostTermConfig,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        switch key {
        case .presentationMode:
            guard let mode = PresentationMode(rawValue: value) else {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line, key: key.rawValue, reason: .invalidPresentationMode)
                )
                return
            }
            config.presentationMode = mode
        case .globalToggle:
            do {
                config.globalToggle = try HotKeyDescriptor(parsing: value)
            } catch let error as HotKeyDescriptor.ParseError {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidHotKey(error)
                    )
                )
            } catch {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidHotKey(.unsupportedKey(value))
                    )
                )
            }
        case .quakeHeight:
            guard let height = parseHeight(value) else {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidNumber(expected: "a value in 0...1 or 1%...100%")
                    )
                )
                return
            }
            config.quakeHeight = height
        case .quakeAnimationDuration:
            guard let duration = Double(value), duration.isFinite, duration >= 0 else {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidNumber(expected: "non-negative seconds")
                    )
                )
                return
            }
            config.quakeAnimationDuration = duration
        case .quakePadding:
            guard let padding = Double(value), padding.isFinite, padding >= 0 else {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidNumber(expected: "non-negative points")
                    )
                )
                return
            }
            config.quakePadding = padding
        case .hideOnFocusLoss:
            guard value == "true" || value == "false" else {
                diagnostics.append(
                    ConfigDiagnostic(line: line, key: key.rawValue, reason: .invalidBoolean)
                )
                return
            }
            config.hideOnFocusLoss = value == "true"
        }
    }

    private static func parseHeight(_ value: String) -> Double? {
        if value.hasSuffix("%"), let percentage = Double(value.dropLast()),
            percentage.isFinite, percentage > 0, percentage <= 100
        {
            return percentage / 100
        }
        guard let fraction = Double(value), fraction.isFinite, fraction > 0, fraction <= 1 else {
            return nil
        }
        return fraction
    }

    private static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }
}
