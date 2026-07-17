import Foundation
import Testing

@testable import GhostTerm

struct ConfigDocumentTests {
    @Test
    func defaultsMatchTaskSevenContract() {
        let config = GhostTermConfig()

        #expect(config.presentationMode == .normal)
        #expect(config.globalToggle == HotKeyDescriptor(key: .f12))
        #expect(config.globalToggle.stringValue == "f12")
        #expect(config.quakeHeight == 0.75)
        #expect(config.quakeAnimationDuration == 0.18)
        #expect(config.quakePadding == 0)
        #expect(config.hideOnFocusLoss)
        #expect(config.restoreWorkspaces)
        #expect(config.configEditor == "nano")
    }

    @Test
    func parsesWorkspaceRestoreAndEditorValuesIncludingArguments() {
        let document = ConfigDocument(
            text: """
                ghostterm-restore-workspaces = false
                ghostterm-config-editor = \t nvim --nofork \t
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
            text: "ghostterm-restore-workspaces = \(value)\n"
        ).parse()

        #expect(result.config.restoreWorkspaces)
        #expect(
            result.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: GhostTermConfig.Key.restoreWorkspaces.rawValue,
                    reason: .invalidBoolean
                )
            ]
        )
    }

    @Test
    func configEditorRejectsNUL() {
        let result = ConfigDocument(
            text: "ghostterm-config-editor = na\0no\n"
        ).parse()

        #expect(result.config.configEditor == "nano")
        #expect(
            result.diagnostics == [
                ConfigDiagnostic(
                    line: 1,
                    key: GhostTermConfig.Key.configEditor.rawValue,
                    reason: .invalidConfigEditor
                )
            ]
        )
    }

    @Test
    func duplicateWorkspaceRestoreAndEditorAssignmentsUseLastValidValue() {
        let result = ConfigDocument(
            text: """
                ghostterm-restore-workspaces = false
                ghostterm-restore-workspaces = true
                ghostterm-config-editor = vim
                ghostterm-config-editor = code --wait
                """
        ).parse()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.restoreWorkspaces)
        #expect(result.config.configEditor == "code --wait")
    }

    @Test
    func hotKeyParserHasStableRoundTripAndTypedFailures() throws {
        let descriptor = try HotKeyDescriptor(parsing: "cmd+f12")

        #expect(descriptor == HotKeyDescriptor(command: true, key: .f12))
        #expect(try HotKeyDescriptor(parsing: descriptor.stringValue) == descriptor)
        #expect(try HotKeyDescriptor(parsing: "f12") == HotKeyDescriptor(key: .f12))
        #expect(throws: HotKeyDescriptor.ParseError.duplicateModifier(.command)) {
            try HotKeyDescriptor(parsing: "cmd+cmd+f12")
        }
        #expect(throws: HotKeyDescriptor.ParseError.unsupportedKey("space")) {
            try HotKeyDescriptor(parsing: "cmd+space")
        }
    }

    @Test
    func preservesEveryOriginalByteIncludingMixedTerminatorsAndInvalidUnknownData() {
        let bytes = Data(
            Array("# comment\r\nfont-size = 14\r\nghostterm-presentation-mode = quake\r".utf8)
                + [0xFF, 0x00, 0x0A]
        )

        let document = ConfigDocument(data: bytes)

        #expect(document.data == bytes)
        #expect(document.parse().config.presentationMode == .quake)
    }

    @Test
    func lastDuplicateIsEffectiveAndOnlyItsValueBytesChange() {
        let source =
            "ghostterm-presentation-mode=normal\r\n"
            + "# keep me\r\n"
            + "ghostterm-presentation-mode  =  quake  # effective\r\n"
            + "font-family = Mono"
        var document = ConfigDocument(data: Data(source.utf8))

        #expect(document.parse().config.presentationMode == .quake)
        document.setPresentationMode(.normal)

        #expect(
            document.data
                == Data(
                    ("ghostterm-presentation-mode=normal\r\n"
                        + "# keep me\r\n"
                        + "ghostterm-presentation-mode  =  normal  # effective\r\n"
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
            data: Data("ghostterm-quake-height  =  75%  # preserved\r\nfont-size = 14\r\n".utf8)
        )
        document.setQuakeHeight(0.73125)

        #expect(
            document.data
                == Data(
                    "ghostterm-quake-height  =  73.125%  # preserved\r\nfont-size = 14\r\n".utf8
                )
        )
    }

    @Test
    func appendPreservesExistingUnterminatedBytesAndUsesExistingTerminatorStyle() {
        var document = ConfigDocument(data: Data("font-size = 13".utf8))

        document.setPresentationMode(.quake)

        #expect(
            document.data
                == Data("font-size = 13\nghostterm-presentation-mode = quake\n".utf8)
        )
    }

    @Test
    func diagnosticsIdentifyExactGhostTermLineAndUnknownTerminalLinesAreIgnored() throws {
        let document = ConfigDocument(
            text: """
                font-size = definitely-not-a-number
                ghostterm-quake-height = huge
                ghostterm-hide-on-focus-loss = maybe
                """
        )

        let result = document.parse()

        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics[0].line == 2)
        #expect(result.diagnostics[0].key == GhostTermConfig.Key.quakeHeight.rawValue)
        #expect(result.diagnostics[1].line == 3)
        #expect(result.config == GhostTermConfig())
    }

    @Test
    func parsesAllValuesAndFiltersEntireNamespaceWithoutChangingOtherBytes() throws {
        let source = Data(
            ("# terminal\r\n"
                + "font-size = 15\r\n"
                + "ghostterm-presentation-mode = quake\r\n"
                + "ghostterm-global-toggle = cmd+opt+f11\r\n"
                + "ghostterm-quake-height = 80%\r\n"
                + "ghostterm-quake-animation-duration = 0.2\r\n"
                + "ghostterm-quake-padding = 8\r\n"
                + "ghostterm-hide-on-focus-loss = false\r\n"
                + "ghostterm-restore-workspaces = false\r\n"
                + "ghostterm-config-editor = code --wait\r\n"
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
    func effectiveGhosttyDataInjectsClipboardDefaultOnlyWithoutTerminalAssignment() {
        let source = Data(
            "ghostterm-config-editor = vim\r\nfont-size = 14\r\n".utf8
        )
        let document = ConfigDocument(data: source)

        #expect(document.filteredGhosttyData == Data("font-size = 14\r\n".utf8))
        #expect(
            document.effectiveGhosttyData
                == Data("copy-on-select = clipboard\nfont-size = 14\r\n".utf8)
        )
    }

    @Test(arguments: ["false", "true", "clipboard"])
    func effectiveGhosttyDataPreservesExplicitCopyOnSelect(_ value: String) {
        let source = Data(
            "ghostterm-restore-workspaces = false\r\ncopy-on-select = \(value)\r\n".utf8
        )
        let document = ConfigDocument(data: source)

        #expect(document.effectiveGhosttyData == Data("copy-on-select = \(value)\r\n".utf8))
    }
}
