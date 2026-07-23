import Testing

@testable import QuickTTY

struct ShortcutConfigurationTests {
    @Test
    func parserAcceptsEverySupportedKeyToken() throws {
        let expectedTokens = Set(
            Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
                + Array("0123456789").map(String.init)
                + (1...20).map { "f\($0)" }
                + [
                    "left", "right", "up", "down",
                    "home", "end", "page-up", "page-down",
                    "tab", "enter", "escape", "space", "delete", "forward-delete",
                    "grave", "minus", "equal", "left-bracket", "right-bracket", "backslash",
                    "semicolon", "quote", "comma", "period", "slash",
                ]
        )

        #expect(Set(ShortcutKey.allCases.map(\.rawValue)) == expectedTokens)
        for token in expectedTokens {
            let chord = try ShortcutChord(parsing: token)
            #expect(chord.key.rawValue == token)
            #expect(chord.modifiers.isEmpty)
            #expect(chord.stringValue == token)
        }
    }

    @Test
    func parserAcceptsModifiersInAnyOrderAndSerializesCanonically() throws {
        let chord = try ShortcutChord(parsing: "shift+ctrl+cmd+opt+page-down")

        #expect(chord.key == .pageDown)
        #expect(chord.modifiers == [.command, .option, .control, .shift])
        #expect(chord.stringValue == "cmd+opt+ctrl+shift+page-down")
        #expect(try ShortcutChord(parsing: chord.stringValue) == chord)
    }

    @Test
    func parserAcceptsModifierlessChord() throws {
        #expect(
            try ShortcutChord(parsing: "f12")
                == ShortcutChord(key: .f12)
        )
    }

    @Test
    func parserRejectsInvalidGrammarWithTypedErrors() {
        #expect(throws: ShortcutChord.ParseError.empty) {
            try ShortcutChord(parsing: "")
        }
        #expect(throws: ShortcutChord.ParseError.emptyComponent(position: 1)) {
            try ShortcutChord(parsing: "+a")
        }
        #expect(throws: ShortcutChord.ParseError.emptyComponent(position: 2)) {
            try ShortcutChord(parsing: "cmd++a")
        }
        #expect(throws: ShortcutChord.ParseError.emptyComponent(position: 3)) {
            try ShortcutChord(parsing: "cmd+a+")
        }
        #expect(throws: ShortcutChord.ParseError.missingKey) {
            try ShortcutChord(parsing: "cmd+shift")
        }
        #expect(throws: ShortcutChord.ParseError.duplicateModifier(.command)) {
            try ShortcutChord(parsing: "cmd+cmd+a")
        }
        #expect(throws: ShortcutChord.ParseError.multipleKeys("a", "b")) {
            try ShortcutChord(parsing: "a+b")
        }
        #expect(throws: ShortcutChord.ParseError.unsupportedModifier("super")) {
            try ShortcutChord(parsing: "super+a")
        }
        #expect(throws: ShortcutChord.ParseError.unsupportedKey("f21")) {
            try ShortcutChord(parsing: "cmd+f21")
        }
    }

    @Test
    func parserRejectsAliasesLiteralPunctuationAndDisabled() {
        for token in [
            "command+a", "option+a", "control+a", "alt+a", "return", "esc", "del",
            "pagedown", "[", "]", "`", "-", "=", "\\", ";", "'", ",", ".", "/",
        ] {
            #expect(throws: ShortcutChord.ParseError.self) {
                try ShortcutChord(parsing: token)
            }
        }
        #expect(throws: ShortcutChord.ParseError.unsupportedKey("disabled")) {
            try ShortcutChord(parsing: "disabled")
        }
    }

    @Test
    func registryContainsExactStableIDsAndDefaultsWithoutDuplicates() {
        let expected: [String: String?] = [
            "quit": "cmd+q",
            "open-config": "cmd+comma",
            "toggle-presentation": "cmd+opt+p",
            "new-tab": "cmd+t",
            "close-pane": "cmd+w",
            "close-tab": "cmd+opt+w",
            "split-right": "cmd+d",
            "split-down": "cmd+shift+d",
            "previous-pane": "cmd+left-bracket",
            "next-pane": "cmd+right-bracket",
            "focus-left": "cmd+opt+left",
            "focus-right": "cmd+opt+right",
            "focus-up": "cmd+opt+up",
            "focus-down": "cmd+opt+down",
            "select-tab-1": "cmd+1",
            "select-tab-2": "cmd+2",
            "select-tab-3": "cmd+3",
            "select-tab-4": "cmd+4",
            "select-tab-5": "cmd+5",
            "select-tab-6": "cmd+6",
            "select-tab-7": "cmd+7",
            "select-tab-8": "cmd+8",
            "select-tab-9": "cmd+9",
            "toggle-broadcast": "cmd+b",
            "new-workspace": nil,
            "rename-workspace": nil,
            "delete-workspace": nil,
            "select-workspace-1": "cmd+opt+1",
            "select-workspace-2": "cmd+opt+2",
            "select-workspace-3": "cmd+opt+3",
            "select-workspace-4": "cmd+opt+4",
            "select-workspace-5": "cmd+opt+5",
            "select-workspace-6": "cmd+opt+6",
            "select-workspace-7": "cmd+opt+7",
            "select-workspace-8": "cmd+opt+8",
            "select-workspace-9": "cmd+opt+9",
            "copy": "cmd+c",
            "paste": "cmd+v",
            "paste-selection": "cmd+shift+v",
            "select-all": "cmd+a",
            "copy-url": nil,
            "clear-screen": "cmd+k",
            "reset-terminal": nil,
            "font-increase": "cmd+equal",
            "font-decrease": "cmd+minus",
            "font-reset": "cmd+0",
            "scroll-top": "cmd+home",
            "scroll-bottom": "cmd+end",
            "scroll-page-up": "cmd+page-up",
            "scroll-page-down": "cmd+page-down",
            "scroll-to-selection": "cmd+j",
            "previous-prompt": "cmd+shift+up",
            "next-prompt": "cmd+shift+down",
            "selection-left": "shift+left",
            "selection-right": "shift+right",
            "selection-up": "shift+up",
            "selection-down": "shift+down",
            "selection-page-up": "shift+page-up",
            "selection-page-down": "shift+page-down",
            "selection-home": "shift+home",
            "selection-end": "shift+end",
        ]
        let actions = ShortcutAction.allCases
        let ids = actions.map(\.rawValue)
        let defaultChords = actions.compactMap(\.defaultChord)
        let actual = Dictionary(
            uniqueKeysWithValues: actions.map { action in
                (action.rawValue, action.defaultChord?.stringValue)
            })

        #expect(Set(ids) == Set(expected.keys))
        #expect(ids.count == Set(ids).count)
        #expect(defaultChords.count == Set(defaultChords).count)
        #expect(actual.count == expected.count)
        for (id, defaultValue) in expected {
            #expect(actual[id] == defaultValue)
        }
        #expect(!ids.contains("quicktty-global-toggle"))
    }

    @Test
    func terminalRegistryUsesExactTypedAllowlist() {
        let expected = [
            "copy": "copy_to_clipboard",
            "paste": "paste_from_clipboard",
            "paste-selection": "paste_from_selection",
            "select-all": "select_all",
            "copy-url": "copy_url_to_clipboard",
            "clear-screen": "clear_screen",
            "reset-terminal": "reset",
            "font-increase": "increase_font_size:1",
            "font-decrease": "decrease_font_size:1",
            "font-reset": "reset_font_size",
            "scroll-top": "scroll_to_top",
            "scroll-bottom": "scroll_to_bottom",
            "scroll-page-up": "scroll_page_up",
            "scroll-page-down": "scroll_page_down",
            "scroll-to-selection": "scroll_to_selection",
            "previous-prompt": "jump_to_prompt:-1",
            "next-prompt": "jump_to_prompt:1",
            "selection-left": "adjust_selection:left",
            "selection-right": "adjust_selection:right",
            "selection-up": "adjust_selection:up",
            "selection-down": "adjust_selection:down",
            "selection-page-up": "adjust_selection:page_up",
            "selection-page-down": "adjust_selection:page_down",
            "selection-home": "adjust_selection:home",
            "selection-end": "adjust_selection:end",
        ]
        let terminalMappings: [(String, String)] = ShortcutAction.allCases.compactMap { action in
            guard case .terminal(let terminalAction) = action.executionRoute else { return nil }
            return (action.rawValue, terminalAction.coreAction)
        }
        let actual = Dictionary(uniqueKeysWithValues: terminalMappings)

        #expect(actual == expected)
        #expect(ShortcutAction.paste.targetPolicy == .activeTab)
        #expect(ShortcutAction.copy.targetPolicy == .focusedPane)
        #expect(ShortcutAction.copy.performPolicy == .passThroughWhenUnperformed)
        #expect(ShortcutAction.paste.performPolicy == .consume)
    }

    @Test
    func defaultsAssignEveryEnabledActionToItsDeclaredChord() {
        let configuration = ShortcutConfiguration.defaults

        for action in ShortcutAction.allCases {
            #expect(configuration.chord(for: action) == action.defaultChord)
            if let chord = action.defaultChord {
                #expect(configuration.owner(of: chord) == action)
            }
        }
    }

    @Test
    func assigningOwnedChordUsesLastOwnerAndReportsTypedConflict() throws {
        var configuration = ShortcutConfiguration.defaults
        let chord = try #require(ShortcutAction.newTab.defaultChord)

        let conflict = configuration.assign(chord, to: .copy)

        #expect(
            conflict
                == ShortcutConflict(chord: chord, previous: .newTab, winner: .copy)
        )
        #expect(configuration.chord(for: .newTab) == nil)
        #expect(configuration.chord(for: .copy) == chord)
        #expect(configuration.owner(of: chord) == .copy)
    }

    @Test
    func assigningNewChordReleasesWinnersOldChord() throws {
        var configuration = ShortcutConfiguration.defaults
        let oldChord = try #require(ShortcutAction.copy.defaultChord)
        let newChord = try ShortcutChord(parsing: "ctrl+shift+c")

        #expect(configuration.assign(newChord, to: .copy) == nil)
        #expect(configuration.owner(of: oldChord) == nil)
        #expect(configuration.owner(of: newChord) == .copy)
        #expect(configuration.chord(for: .copy) == newChord)
    }

    @Test
    func disablingActionReleasesChordAndAssignmentEnumSupportsBothStates() throws {
        var configuration = ShortcutConfiguration.defaults
        let defaultChord = try #require(ShortcutAction.copy.defaultChord)
        let replacement = try ShortcutChord(parsing: "ctrl+c")

        #expect(configuration.apply(.disabled, to: .copy) == nil)
        #expect(configuration.chord(for: .copy) == nil)
        #expect(configuration.owner(of: defaultChord) == nil)
        #expect(configuration.apply(.chord(replacement), to: .copy) == nil)
        #expect(configuration.chord(for: .copy) == replacement)
        #expect(configuration.disable(.copy) == nil)
        #expect(configuration.owner(of: replacement) == nil)
    }
}
