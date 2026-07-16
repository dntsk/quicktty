import Foundation
import Testing

@testable import GhostTerm

struct ConfigDocumentTests {
    @Test
    func defaultsMatchTaskSevenContract() {
        let config = GhostTermConfig()

        #expect(config.presentationMode == .normal)
        #expect(config.globalToggle == HotKeyDescriptor(command: true, key: .f12))
        #expect(config.globalToggle.stringValue == "cmd+f12")
        #expect(config.quakeHeight == 0.75)
        #expect(config.quakeAnimationDuration == 0.18)
        #expect(config.quakePadding == 0)
        #expect(config.hideOnFocusLoss)
    }

    @Test
    func hotKeyParserHasStableRoundTripAndTypedFailures() throws {
        let descriptor = try HotKeyDescriptor(parsing: "cmd+f12")

        #expect(descriptor == HotKeyDescriptor(command: true, key: .f12))
        #expect(try HotKeyDescriptor(parsing: descriptor.stringValue) == descriptor)
        #expect(throws: HotKeyDescriptor.ParseError.missingModifier) {
            try HotKeyDescriptor(parsing: "f12")
        }
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
        #expect(
            document.filteredGhosttyData
                == Data(
                    ("# terminal\r\nfont-size = 15\r\ninclude = themes/local.conf").utf8
                )
        )
    }
}
