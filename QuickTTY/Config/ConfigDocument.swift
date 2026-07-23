import Foundation

struct ConfigDiagnostic: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case malformedAssignment
        case unknownKey
        case emptyValue
        case invalidPresentationMode
        case invalidHotKey(ShortcutChord.ParseError)
        case emptyShortcutInstruction
        case malformedShortcutInstruction
        case emptyShortcutAction
        case unknownShortcutAction(String)
        case emptyShortcutChord(ShortcutAction)
        case invalidShortcutChord(ShortcutAction, ShortcutChord.ParseError)
        case shortcutConflict(ShortcutConflict)
        case globalShortcutConflict(chord: ShortcutChord, local: ShortcutAction)
        case invalidNumber(expected: String)
        case invalidBoolean
        case invalidConfigEditor
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
            return "\(prefix): unknown QuickTTY option."
        case .emptyValue:
            return "\(prefix): value is empty."
        case .invalidPresentationMode:
            return "\(prefix): expected 'normal' or 'quake'."
        case .invalidHotKey(let error):
            return "\(prefix): \(error.localizedDescription)"
        case .emptyShortcutInstruction:
            return "\(prefix): shortcut instruction is empty."
        case .malformedShortcutInstruction:
            return "\(prefix): expected 'action-id=chord' or 'action-id=disabled'."
        case .emptyShortcutAction:
            return "\(prefix): shortcut action ID is empty."
        case .unknownShortcutAction(let actionID):
            return "\(prefix): unknown shortcut action '\(actionID)'."
        case .emptyShortcutChord(let action):
            return "\(prefix): shortcut chord for '\(action.rawValue)' is empty."
        case .invalidShortcutChord(let action, let error):
            return
                "\(prefix): invalid chord for '\(action.rawValue)': \(error.localizedDescription)"
        case .shortcutConflict(let conflict):
            return
                "\(prefix): chord '\(conflict.chord.stringValue)' moved from '\(conflict.previous.rawValue)' to '\(conflict.winner.rawValue)'; '\(conflict.previous.rawValue)' was disabled."
        case .globalShortcutConflict(let chord, let local):
            return
                "\(prefix): global action 'quicktty-global-toggle' owns '\(chord.stringValue)'; local action '\(local.rawValue)' was disabled."
        case .invalidNumber(let expected):
            return "\(prefix): expected \(expected)."
        case .invalidBoolean:
            return "\(prefix): expected 'true' or 'false'."
        case .invalidConfigEditor:
            return "\(prefix): must not contain NUL or line breaks."
        }
    }
}

struct ConfigParseResult: Equatable, Sendable {
    let config: QuickTTYConfig
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
        let belongsToQuickTTY: Bool
        let malformed: Bool
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

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
            let assignment = Self.assignment(in: line.content)
            guard
                assignment.belongsToQuickTTY
                    || Self.isExactAssignment(in: line.content, key: "keybind")
            else {
                result.append(line.content)
                result.append(line.terminator)
                return
            }
            result.append(
                contentsOf: line.content.prefix(Self.byteOrderMarkLength(in: [UInt8](line.content)))
            )
        }
    }

    var effectiveGhosttyData: Data {
        var effectiveData = filteredGhosttyData
        if !lines.contains(where: { Self.isTerminalCopyOnSelectAssignment(in: $0.content) }) {
            let defaultAssignment = Data("copy-on-select = clipboard\n".utf8)
            let byteOrderMark = Data(Self.byteOrderMark)
            if effectiveData.starts(with: byteOrderMark) {
                effectiveData =
                    byteOrderMark + defaultAssignment
                    + effectiveData.dropFirst(byteOrderMark.count)
            } else {
                effectiveData = defaultAssignment + effectiveData
            }
        }

        let byteOrderMarkLength = Self.byteOrderMarkLength(in: [UInt8](effectiveData))
        if effectiveData.count > byteOrderMarkLength,
            effectiveData.last != 0x0A,
            effectiveData.last != 0x0D
        {
            effectiveData.append(preferredTerminator)
        }
        effectiveData.append(contentsOf: "keybind = clear".utf8)
        effectiveData.append(preferredTerminator)
        return effectiveData
    }

    func parse(previousConfig: QuickTTYConfig? = nil) -> ConfigParseResult {
        typealias ValidShortcut = (
            line: Int, action: ShortcutAction, assignment: ShortcutAssignment
        )

        var config = QuickTTYConfig()
        var diagnostics: [ConfigDiagnostic] = []
        var validShortcuts: [ValidShortcut] = []
        var validShortcutActions = Set<ShortcutAction>()
        var invalidShortcutLines: [ShortcutAction: Int] = [:]
        var hasValidGlobalToggle = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let assignment = Self.assignment(in: line.content)
            guard assignment.belongsToQuickTTY else { continue }
            guard !assignment.malformed, let keyName = assignment.key else {
                let reason: ConfigDiagnostic.Reason =
                    assignment.key == QuickTTYConfig.Key.shortcut.rawValue
                    ? .malformedShortcutInstruction : .malformedAssignment
                diagnostics.append(
                    ConfigDiagnostic(line: lineNumber, key: assignment.key, reason: reason)
                )
                continue
            }
            guard let key = QuickTTYConfig.Key(rawValue: keyName) else {
                diagnostics.append(
                    ConfigDiagnostic(line: lineNumber, key: keyName, reason: .unknownKey)
                )
                continue
            }
            guard let value = assignment.value, !value.isEmpty else {
                let reason: ConfigDiagnostic.Reason =
                    key == .shortcut ? .emptyShortcutInstruction : .emptyValue
                diagnostics.append(
                    ConfigDiagnostic(line: lineNumber, key: keyName, reason: reason)
                )
                continue
            }

            if key == .shortcut {
                Self.parseShortcut(
                    value,
                    line: lineNumber,
                    validShortcuts: &validShortcuts,
                    validActions: &validShortcutActions,
                    invalidLines: &invalidShortcutLines,
                    diagnostics: &diagnostics
                )
                continue
            }

            Self.apply(
                value,
                for: key,
                line: lineNumber,
                previousConfig: previousConfig,
                hasValidGlobalToggle: &hasValidGlobalToggle,
                to: &config,
                diagnostics: &diagnostics
            )
        }

        var shortcuts = ShortcutConfiguration.defaults
        var assignmentLines: [ShortcutAction: Int] = [:]
        for (action, line) in invalidShortcutLines.sorted(by: { $0.value < $1.value })
        where !validShortcutActions.contains(action) {
            let effectiveFallback: ShortcutAssignment
            if let previousConfig {
                effectiveFallback =
                    previousConfig.shortcuts.chord(for: action).map(ShortcutAssignment.chord)
                    ?? .disabled
            } else {
                effectiveFallback = action.defaultChord.map(ShortcutAssignment.chord) ?? .disabled
            }
            if let conflict = shortcuts.apply(effectiveFallback, to: action) {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: QuickTTYConfig.Key.shortcut.rawValue,
                        reason: .shortcutConflict(conflict)
                    )
                )
            }
            assignmentLines[action] = line
        }

        for shortcut in validShortcuts {
            if let conflict = shortcuts.apply(shortcut.assignment, to: shortcut.action) {
                diagnostics.append(
                    ConfigDiagnostic(
                        line: shortcut.line,
                        key: QuickTTYConfig.Key.shortcut.rawValue,
                        reason: .shortcutConflict(conflict)
                    )
                )
            }
            assignmentLines[shortcut.action] = shortcut.line
        }

        let globalChord = config.globalToggle
        if let localOwner = shortcuts.owner(of: globalChord) {
            shortcuts.disable(localOwner)
            diagnostics.append(
                ConfigDiagnostic(
                    line: assignmentLines[localOwner] ?? 1,
                    key: QuickTTYConfig.Key.shortcut.rawValue,
                    reason: .globalShortcutConflict(chord: globalChord, local: localOwner)
                )
            )
        }
        config.shortcuts = shortcuts
        diagnostics.sort { $0.line < $1.line }

        return ConfigParseResult(config: config, diagnostics: diagnostics)
    }

    mutating func setValue(_ value: String, for key: QuickTTYConfig.Key) {
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
        let first = firstContentByteIndex(in: bytes)
        guard first < bytes.count, bytes[first] != 0x23 else {
            return Assignment(
                key: nil,
                value: nil,
                valueRange: nil,
                belongsToQuickTTY: false,
                malformed: false
            )
        }

        guard let equals = bytes[first...].firstIndex(of: 0x3D) else {
            let tokenEnd = bytes[first...].firstIndex(where: isHorizontalWhitespace) ?? bytes.count
            let token = String(bytes: bytes[first..<tokenEnd], encoding: .utf8)
            let belongs = token?.hasPrefix("quicktty-") == true
            return Assignment(
                key: token,
                value: nil,
                valueRange: nil,
                belongsToQuickTTY: belongs,
                malformed: belongs
            )
        }

        var keyEnd = equals
        while keyEnd > first, isHorizontalWhitespace(bytes[keyEnd - 1]) {
            keyEnd -= 1
        }
        let key = String(bytes: bytes[first..<keyEnd], encoding: .utf8)
        let belongs = key?.hasPrefix("quicktty-") == true
        guard belongs else {
            return Assignment(
                key: key,
                value: nil,
                valueRange: nil,
                belongsToQuickTTY: false,
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
            belongsToQuickTTY: true,
            malformed: value == nil
        )
    }

    private static func isTerminalCopyOnSelectAssignment(in data: Data) -> Bool {
        isExactAssignment(in: data, key: "copy-on-select")
    }

    private static func isExactAssignment(in data: Data, key: String) -> Bool {
        let bytes = [UInt8](data)
        let first = firstContentByteIndex(in: bytes)
        guard first < bytes.count, bytes[first] != 0x23,
            let equals = bytes[first...].firstIndex(of: 0x3D)
        else {
            return false
        }

        var keyEnd = equals
        while keyEnd > first, isHorizontalWhitespace(bytes[keyEnd - 1]) {
            keyEnd -= 1
        }
        return bytes[first..<keyEnd].elementsEqual(key.utf8)
    }

    private static func parseShortcut(
        _ value: String,
        line: Int,
        validShortcuts:
            inout [(
                line: Int, action: ShortcutAction, assignment: ShortcutAssignment
            )],
        validActions: inout Set<ShortcutAction>,
        invalidLines: inout [ShortcutAction: Int],
        diagnostics: inout [ConfigDiagnostic]
    ) {
        let key = QuickTTYConfig.Key.shortcut.rawValue
        guard let separator = value.firstIndex(of: "=") else {
            let actionID = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let action = ShortcutAction(rawValue: actionID) {
                invalidLines[action] = line
            }
            diagnostics.append(
                ConfigDiagnostic(line: line, key: key, reason: .malformedShortcutInstruction)
            )
            return
        }

        let actionID = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let chordValue = value[value.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionID.isEmpty else {
            diagnostics.append(
                ConfigDiagnostic(line: line, key: key, reason: .emptyShortcutAction)
            )
            return
        }
        guard let action = ShortcutAction(rawValue: actionID) else {
            diagnostics.append(
                ConfigDiagnostic(
                    line: line,
                    key: key,
                    reason: .unknownShortcutAction(actionID)
                )
            )
            return
        }
        guard !chordValue.isEmpty else {
            invalidLines[action] = line
            diagnostics.append(
                ConfigDiagnostic(line: line, key: key, reason: .emptyShortcutChord(action))
            )
            return
        }

        let shortcutAssignment: ShortcutAssignment
        if chordValue == "disabled" {
            shortcutAssignment = .disabled
        } else {
            do {
                shortcutAssignment = .chord(try ShortcutChord(parsing: chordValue))
            } catch let error as ShortcutChord.ParseError {
                invalidLines[action] = line
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key,
                        reason: .invalidShortcutChord(action, error)
                    )
                )
                return
            } catch {
                invalidLines[action] = line
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key,
                        reason: .invalidShortcutChord(action, .unsupportedKey(chordValue))
                    )
                )
                return
            }
        }

        validActions.insert(action)
        validShortcuts.append((line: line, action: action, assignment: shortcutAssignment))
    }

    private static func apply(
        _ value: String,
        for key: QuickTTYConfig.Key,
        line: Int,
        previousConfig: QuickTTYConfig?,
        hasValidGlobalToggle: inout Bool,
        to config: inout QuickTTYConfig,
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
                config.globalToggle = try ShortcutChord(parsing: value)
                hasValidGlobalToggle = true
            } catch let error as ShortcutChord.ParseError {
                if !hasValidGlobalToggle, let previousConfig {
                    config.globalToggle = previousConfig.globalToggle
                }
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidHotKey(error)
                    )
                )
            } catch {
                if !hasValidGlobalToggle, let previousConfig {
                    config.globalToggle = previousConfig.globalToggle
                }
                diagnostics.append(
                    ConfigDiagnostic(
                        line: line,
                        key: key.rawValue,
                        reason: .invalidHotKey(.unsupportedKey(value))
                    )
                )
            }
        case .shortcut:
            preconditionFailure("Shortcut assignments are parsed sequentially")
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
        case .restoreWorkspaces:
            guard value == "true" || value == "false" else {
                diagnostics.append(
                    ConfigDiagnostic(line: line, key: key.rawValue, reason: .invalidBoolean)
                )
                return
            }
            config.restoreWorkspaces = value == "true"
        case .configEditor:
            guard !value.utf8.contains(0), !value.contains("\n"), !value.contains("\r") else {
                diagnostics.append(
                    ConfigDiagnostic(line: line, key: key.rawValue, reason: .invalidConfigEditor)
                )
                return
            }
            config.configEditor = value
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

    private static func firstContentByteIndex(in bytes: [UInt8]) -> Int {
        var index = byteOrderMarkLength(in: bytes)
        while index < bytes.count, isHorizontalWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func byteOrderMarkLength(in bytes: [UInt8]) -> Int {
        bytes.starts(with: byteOrderMark) ? byteOrderMark.count : 0
    }

    private static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }
}

extension ShortcutChord.ParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty:
            "Shortcut chord is empty."
        case .emptyComponent(let position):
            "Shortcut chord component \(position) is empty."
        case .missingKey:
            "Shortcut chord does not contain a key."
        case .duplicateModifier(let modifier):
            "Shortcut chord repeats modifier '\(modifier.rawValue)'."
        case .unsupportedModifier(let modifier):
            "Unsupported shortcut modifier '\(modifier)'."
        case .unsupportedKey(let key):
            "Unsupported shortcut key '\(key)'."
        case .multipleKeys(let first, let second):
            "Shortcut chord contains multiple keys: '\(first)' and '\(second)'."
        }
    }
}
