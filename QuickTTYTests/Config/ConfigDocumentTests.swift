import Foundation
import Testing

@testable import QuickTTY

struct ConfigDocumentTests {
    @Test
    func defaultsMatchTaskSevenContract() {
        let config = QuickTTYConfig()

        #expect(config.presentationMode == .normal)
        #expect(config.globalToggle == ShortcutChord(key: .f12))
        #expect(config.globalToggle.stringValue == "f12")
        #expect(config.quakeHeight == 0.75)
        #expect(config.quakeAnimationDuration == 0.18)
        #expect(config.quakePadding == 0)
        #expect(config.hideOnFocusLoss)
        #expect(config.restoreWorkspaces)
        #expect(config.configEditor == "nano")
        #expect(config.shortcuts == .defaults)
    }

    @Test
    func keysUseTheExactQuickTTYNamespace() {
        #expect(
            QuickTTYConfig.Key.allCases.map(\.rawValue)
                == [
                    "quicktty-presentation-mode",
                    "quicktty-global-toggle",
                    "quicktty-shortcut",
                    "quicktty-quake-height",
                    "quicktty-quake-animation-duration",
                    "quicktty-quake-padding",
                    "quicktty-hide-on-focus-loss",
                    "quicktty-restore-workspaces",
                    "quicktty-config-editor",
                ]
        )
    }

    @Test
    func parsesShortcutAssignmentsWithTrimmedActionAndChordAndExplicitDisabled() throws {
        let document = ConfigDocument(
            text: """
                quicktty-shortcut =  copy = ctrl+c
                quicktty-shortcut = paste=disabled
                quicktty-quake-height = 80%
                """
        )

        let result = document.parse()

        #expect(result.diagnostics.isEmpty)
        #expect(
            result.config.shortcuts.chord(for: .copy)
                == (try ShortcutChord(parsing: "ctrl+c"))
        )
        #expect(result.config.shortcuts.chord(for: .paste) == nil)
        #expect(result.config.quakeHeight == 0.8)
    }

    @Test
    func malformedKnownShortcutKeepsDefaultAtStartup() {
        let result = ConfigDocument(
            text: "quicktty-shortcut = copy\n"
        ).parse()

        #expect(result.config.shortcuts.chord(for: .copy) == ShortcutAction.copy.defaultChord)
        #expect(
            result.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: "quicktty-shortcut",
                    reason: .malformedShortcutInstruction
                )
            ]
        )
    }

    @Test
    func shortcutDiagnosticsDistinguishMalformedUnknownAndInvalidKnownAssignments() throws {
        let document = ConfigDocument(
            text: """
                quicktty-shortcut =
                quicktty-shortcut = copy
                quicktty-shortcut = =cmd+t
                quicktty-shortcut = not-an-action=cmd+t
                quicktty-shortcut = copy=
                quicktty-shortcut = copy=cmd++c
                quicktty-shortcut = new-tab=ctrl+t
                """
        )

        let result = document.parse()

        #expect(result.config.shortcuts.chord(for: .copy) == ShortcutAction.copy.defaultChord)
        #expect(
            result.config.shortcuts.chord(for: .newTab)
                == (try ShortcutChord(parsing: "ctrl+t"))
        )
        #expect(
            result.diagnostics
                == [
                    ConfigDiagnostic(
                        line: 1,
                        key: "quicktty-shortcut",
                        reason: .emptyShortcutInstruction
                    ),
                    ConfigDiagnostic(
                        line: 2,
                        key: "quicktty-shortcut",
                        reason: .malformedShortcutInstruction
                    ),
                    ConfigDiagnostic(
                        line: 3,
                        key: "quicktty-shortcut",
                        reason: .emptyShortcutAction
                    ),
                    ConfigDiagnostic(
                        line: 4,
                        key: "quicktty-shortcut",
                        reason: .unknownShortcutAction("not-an-action")
                    ),
                    ConfigDiagnostic(
                        line: 5,
                        key: "quicktty-shortcut",
                        reason: .emptyShortcutChord(.copy)
                    ),
                    ConfigDiagnostic(
                        line: 6,
                        key: "quicktty-shortcut",
                        reason: .invalidShortcutChord(
                            .copy,
                            .emptyComponent(position: 2)
                        )
                    ),
                ]
        )
    }

    @Test
    func repeatedShortcutUsesLastValidAssignmentAndConflictUsesLastOwner() throws {
        let chord = try ShortcutChord(parsing: "ctrl+shift+x")
        let document = ConfigDocument(
            text: """
                quicktty-shortcut = copy=ctrl+c
                quicktty-shortcut = copy=disabled
                quicktty-shortcut = copy=ctrl+shift+x
                quicktty-shortcut = paste=ctrl+shift+x
                """
        )

        let result = document.parse()

        #expect(result.config.shortcuts.chord(for: .copy) == nil)
        #expect(result.config.shortcuts.chord(for: .paste) == chord)
        #expect(
            result.diagnostics
                == [
                    ConfigDiagnostic(
                        line: 4,
                        key: "quicktty-shortcut",
                        reason: .shortcutConflict(
                            ShortcutConflict(chord: chord, previous: .copy, winner: .paste)
                        )
                    )
                ]
        )
    }

    @Test
    func globalShortcutTakesPrecedenceOverLocalOwner() throws {
        let chord = try ShortcutChord(parsing: "f12")
        let result = ConfigDocument(
            text: """
                quicktty-global-toggle = f12
                quicktty-shortcut = copy=f12
                """
        ).parse()

        #expect(result.config.globalToggle == ShortcutChord(key: .f12))
        #expect(result.config.shortcuts.chord(for: .copy) == nil)
        #expect(
            result.diagnostics
                == [
                    ConfigDiagnostic(
                        line: 2,
                        key: "quicktty-shortcut",
                        reason: .globalShortcutConflict(chord: chord, local: .copy)
                    )
                ]
        )
    }

    @Test
    func parsesWorkspaceRestoreAndEditorValuesIncludingArguments() {
        let document = ConfigDocument(
            text: """
                quicktty-restore-workspaces = false
                quicktty-config-editor = \t nvim --nofork \t
                """
        )

        let result = document.parse()

        #expect(result.diagnostics.isEmpty)
        #expect(!result.config.restoreWorkspaces)
        #expect(result.config.configEditor == "nvim --nofork")
    }

    @Test(arguments: ["TRUE", "False", "yes", "0"])
    func restoreWorkspacesRejectsNonExactBooleanValues(_ value: String) {
        let result = ConfigDocument(
            text: "quicktty-restore-workspaces = \(value)\n"
        ).parse()

        #expect(result.config.restoreWorkspaces)
        #expect(
            result.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: QuickTTYConfig.Key.restoreWorkspaces.rawValue,
                    reason: .invalidBoolean
                )
            ]
        )
    }

    @Test
    func configEditorRejectsNUL() {
        let result = ConfigDocument(
            text: "quicktty-config-editor = na\0no\n"
        ).parse()

        #expect(result.config.configEditor == "nano")
        #expect(
            result.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: QuickTTYConfig.Key.configEditor.rawValue,
                    reason: .invalidConfigEditor
                )
            ]
        )
    }

    @Test
    func duplicateWorkspaceRestoreAndEditorAssignmentsUseLastValidValue() {
        let result = ConfigDocument(
            text: """
                quicktty-restore-workspaces = false
                quicktty-restore-workspaces = true
                quicktty-config-editor = vim
                quicktty-config-editor = code --wait
                """
        ).parse()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.restoreWorkspaces)
        #expect(result.config.configEditor == "code --wait")
    }

    @Test
    func globalToggleUsesSharedShortcutGrammarAndTypedFailures() throws {
        let result = ConfigDocument(
            text: "quicktty-global-toggle = cmd+opt+space\n"
        ).parse()
        let chord = try ShortcutChord(parsing: "cmd+opt+space")

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.globalToggle == chord)
        #expect(try ShortcutChord(parsing: chord.stringValue) == chord)

        let invalid = ConfigDocument(
            text: "quicktty-global-toggle = cmd+cmd+space\n"
        ).parse()
        #expect(invalid.config.globalToggle == ShortcutChord(key: .f12))
        #expect(
            invalid.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: QuickTTYConfig.Key.globalToggle.rawValue,
                    reason: .invalidHotKey(.duplicateModifier(.command))
                )
            ]
        )
    }

    @Test
    func preservesEveryOriginalByteIncludingMixedTerminatorsAndInvalidUnknownData() {
        let bytes = Data(
            Array("# comment\r\nfont-size = 14\r\nquicktty-presentation-mode = quake\r".utf8)
                + [0xFF, 0x00, 0x0A]
        )

        let document = ConfigDocument(data: bytes)

        #expect(document.data == bytes)
        #expect(document.parse().config.presentationMode == .quake)
    }

    @Test
    func lastDuplicateIsEffectiveAndOnlyItsValueBytesChange() {
        let source =
            "quicktty-presentation-mode=normal\r\n"
            + "# keep me\r\n"
            + "quicktty-presentation-mode  =  quake  # effective\r\n"
            + "font-family = Mono"
        var document = ConfigDocument(data: Data(source.utf8))

        #expect(document.parse().config.presentationMode == .quake)
        document.setPresentationMode(.normal)

        #expect(
            document.data
                == Data(
                    ("quicktty-presentation-mode=normal\r\n"
                        + "# keep me\r\n"
                        + "quicktty-presentation-mode  =  normal  # effective\r\n"
                        + "font-family = Mono").utf8
                )
        )
    }

    @Test
    func quakeHeightFormattingAndUpdatePreserveInlineCommentAndCRLF() {
        #expect(ConfigDocument.formattedQuakeHeight(0.29) == "29%")
        #expect(ConfigDocument.formattedQuakeHeight(0.07) == "7%")
        #expect(ConfigDocument.formattedQuakeHeight(0.75) == "75%")
        #expect(ConfigDocument.formattedQuakeHeight(0.731234) == "73.1234%")
        #expect(ConfigDocument.formattedQuakeHeight(0.73125) == "73.125%")

        var document = ConfigDocument(
            data: Data("quicktty-quake-height  =  75%  # preserved\r\nfont-size = 14\r\n".utf8)
        )
        document.setQuakeHeight(0.73125)

        #expect(
            document.data
                == Data(
                    "quicktty-quake-height  =  73.125%  # preserved\r\nfont-size = 14\r\n".utf8
                )
        )
    }

    @Test
    func appendPreservesExistingUnterminatedBytesAndUsesExistingTerminatorStyle() {
        var document = ConfigDocument(data: Data("font-size = 13".utf8))

        document.setPresentationMode(.quake)

        #expect(
            document.data
                == Data("font-size = 13\nquicktty-presentation-mode = quake\n".utf8)
        )
    }

    @Test
    func diagnosticsIdentifyExactQuickTTYLineAndUnknownTerminalLinesAreIgnored() throws {
        let document = ConfigDocument(
            text: """
                font-size = definitely-not-a-number
                quicktty-quake-height = huge
                quicktty-hide-on-focus-loss = maybe
                """
        )

        let result = document.parse()

        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics[0].line == 2)
        #expect(result.diagnostics[0].key == QuickTTYConfig.Key.quakeHeight.rawValue)
        #expect(result.diagnostics[1].line == 3)
        #expect(result.config == QuickTTYConfig())
    }

    @Test
    func parsesAllValuesAndFiltersEntireNamespaceWithoutChangingOtherBytes() throws {
        let source = Data(
            ("# terminal\r\n"
                + "font-size = 15\r\n"
                + "quicktty-presentation-mode = quake\r\n"
                + "quicktty-global-toggle = cmd+opt+f11\r\n"
                + "quicktty-quake-height = 80%\r\n"
                + "quicktty-quake-animation-duration = 0.2\r\n"
                + "quicktty-quake-padding = 8\r\n"
                + "quicktty-hide-on-focus-loss = false\r\n"
                + "quicktty-restore-workspaces = false\r\n"
                + "quicktty-config-editor = code --wait\r\n"
                + "include = themes/local.conf").utf8
        )
        let document = ConfigDocument(data: source)

        let result = document.parse()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.presentationMode == .quake)
        #expect(result.config.globalToggle.stringValue == "cmd+opt+f11")
        #expect(result.config.quakeHeight == 0.8)
        #expect(result.config.quakeAnimationDuration == 0.2)
        #expect(result.config.quakePadding == 8)
        #expect(!result.config.hideOnFocusLoss)
        #expect(!result.config.restoreWorkspaces)
        #expect(result.config.configEditor == "code --wait")
        #expect(
            document.filteredGhosttyData
                == Data(
                    ("# terminal\r\nfont-size = 15\r\ninclude = themes/local.conf").utf8
                )
        )
    }

    @Test
    func effectiveGhosttyDataSilentlyRemovesOnlyExactKeybindAssignmentsAndEndsWithClear() {
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        let source =
            byteOrderMark
            + Data(
                ("# keybind = cmd+t=new_tab\r\n"
                    + "keybinds = preserved\r\n"
                    + " keybind = cmd+t=new_tab\r\n"
                    + "quicktty-shortcut = new-tab=ctrl+t\r\n"
                    + "include = local.conf").utf8
            )
        let document = ConfigDocument(data: source)

        #expect(document.parse().diagnostics.isEmpty)
        #expect(
            document.effectiveGhosttyData
                == byteOrderMark
                + Data(
                    ("copy-on-select = clipboard\n"
                        + "# keybind = cmd+t=new_tab\r\n"
                        + "keybinds = preserved\r\n"
                        + "include = local.conf\r\n"
                        + "keybind = clear\r\n").utf8
                )
        )
        #expect(
            String(decoding: document.effectiveGhosttyData, as: UTF8.self)
                .components(separatedBy: "keybind = clear").count == 2
        )
    }

    @Test
    func effectiveGhosttyDataInjectsClipboardDefaultOnlyWithoutTerminalAssignment() {
        let source = Data(
            "quicktty-config-editor = vim\r\nfont-size = 14\r\n".utf8
        )
        let document = ConfigDocument(data: source)

        #expect(document.filteredGhosttyData == Data("font-size = 14\r\n".utf8))
        #expect(
            document.effectiveGhosttyData
                == Data(
                    "copy-on-select = clipboard\nfont-size = 14\r\nkeybind = clear\r\n".utf8
                )
        )
    }

    @Test
    func effectiveGhosttyDataPreservesByteOrderMarkWhenInjectingClipboardDefault() {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("font-size = 14\r\n".utf8)
        let document = ConfigDocument(data: source)

        #expect(document.data == source)
        #expect(
            document.effectiveGhosttyData
                == Data([0xEF, 0xBB, 0xBF])
                + Data(
                    "copy-on-select = clipboard\nfont-size = 14\r\nkeybind = clear\r\n".utf8
                )
        )
    }

    @Test
    func byteOrderMarkPrefixedQuickTTYAssignmentParsesAndIsFiltered() {
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        let source =
            byteOrderMark
            + Data("quicktty-restore-workspaces = false\r\nfont-size = 14\r\n".utf8)
        let document = ConfigDocument(data: source)

        let result = document.parse()

        #expect(result.diagnostics.isEmpty)
        #expect(!result.config.restoreWorkspaces)
        #expect(document.filteredGhosttyData == byteOrderMark + Data("font-size = 14\r\n".utf8))
        #expect(
            document.effectiveGhosttyData
                == byteOrderMark
                + Data(
                    "copy-on-select = clipboard\nfont-size = 14\r\nkeybind = clear\r\n".utf8
                )
        )
    }

    @Test
    func setValuePreservesByteOrderMarkOnFirstQuickTTYAssignment() {
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        var document = ConfigDocument(
            data: byteOrderMark + Data("quicktty-restore-workspaces = false\r\n".utf8)
        )

        document.setValue("true", for: .restoreWorkspaces)

        #expect(
            document.data
                == byteOrderMark + Data("quicktty-restore-workspaces = true\r\n".utf8)
        )
    }

    @Test
    func effectiveGhosttyDataPreservesByteOrderMarkWithExplicitCopyOnSelect() {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("copy-on-select = false\r\n".utf8)
        let document = ConfigDocument(data: source)

        #expect(document.data == source)
        #expect(
            document.effectiveGhosttyData
                == source + Data("keybind = clear\r\n".utf8)
        )
    }

    @Test(arguments: ["false", "true", "clipboard"])
    func effectiveGhosttyDataPreservesExplicitCopyOnSelect(_ value: String) {
        let source = Data(
            "quicktty-restore-workspaces = false\r\ncopy-on-select = \(value)\r\n".utf8
        )
        let document = ConfigDocument(data: source)

        #expect(
            document.effectiveGhosttyData
                == Data("copy-on-select = \(value)\r\nkeybind = clear\r\n".utf8)
        )
    }

    @Test
    func effectiveGhosttyDataInjectsClipboardDefaultWhenKeyOnlyStartsWithCopyOnSelect() {
        let source = Data("copy-on-select-extra = false\r\nfont-size = 14\r\n".utf8)
        let document = ConfigDocument(data: source)

        #expect(
            document.effectiveGhosttyData
                == Data(
                    ("copy-on-select = clipboard\n"
                        + "copy-on-select-extra = false\r\n"
                        + "font-size = 14\r\n"
                        + "keybind = clear\r\n").utf8
                )
        )
    }
}
