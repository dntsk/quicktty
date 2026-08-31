import Testing

@testable import QuickTTY

struct QuickTTYCommandTests {
    @Test
    func parsesPublicIntegrationGrammarExactly() throws {
        #expect(
            try QuickTTYCommand.parse(["integrations", "status"])
                == .integrationsStatus(adapterIDs: [])
        )
        #expect(
            try QuickTTYCommand.parse(["integrations", "status", "claude-code", "codex"])
                == .integrationsStatus(adapterIDs: ["claude-code", "codex"])
        )
        #expect(
            try QuickTTYCommand.parse(["integrations", "install"])
                == .integrationsInstall(adapterIDs: [], assumeYes: false)
        )
        #expect(
            try QuickTTYCommand.parse(["integrations", "install", "codex", "--yes"])
                == .integrationsInstall(adapterIDs: ["codex"], assumeYes: true)
        )
        #expect(
            try QuickTTYCommand.parse(["integrations", "uninstall", "claude-code"])
                == .integrationsUninstall(adapterIDs: ["claude-code"], assumeYes: false)
        )
        #expect(
            try QuickTTYCommand.parse([
                "integrations", "uninstall", "claude-code", "codex", "--yes",
            ])
                == .integrationsUninstall(
                    adapterIDs: ["claude-code", "codex"],
                    assumeYes: true
                )
        )
    }

    @Test
    func rejectsUnknownDuplicateAndMisplacedFlags() {
        #expect(throws: QuickTTYCommand.ParseError.unknownFlag("--json")) {
            try QuickTTYCommand.parse(["integrations", "status", "--json"])
        }
        #expect(throws: QuickTTYCommand.ParseError.yesNotAllowed) {
            try QuickTTYCommand.parse(["integrations", "status", "--yes"])
        }
        #expect(throws: QuickTTYCommand.ParseError.duplicateYes) {
            try QuickTTYCommand.parse(["integrations", "install", "--yes", "--yes"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try QuickTTYCommand.parse(["integrations", "install", "--yes", "codex"])
        }
        #expect(throws: QuickTTYCommand.ParseError.unknownFlag("-x")) {
            try QuickTTYCommand.parse(["integrations", "uninstall", "-x"])
        }
    }

    @Test
    func rejectsMissingUnknownAndUnsafePublicCommands() {
        #expect(throws: QuickTTYCommand.ParseError.missingCommand) {
            try QuickTTYCommand.parse([])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try QuickTTYCommand.parse(["integrations"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try QuickTTYCommand.parse(["integrations", "enable"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try QuickTTYCommand.parse(["status"])
        }

        for adapterID in [
            "", "-codex", "codex-", "Claude", "claude_code", "../codex",
            String(repeating: "a", count: 65),
        ] {
            #expect(throws: QuickTTYCommand.ParseError.self) {
                try QuickTTYCommand.parse(["integrations", "status", adapterID])
            }
        }
    }

    @Test
    func parsesHiddenInternalGrammarWithoutExecutingIt() throws {
        #expect(
            try QuickTTYCommand.parse(["internal", "hook", "claude-code", "session-start"])
                == .internalHook(adapterID: "claude-code", event: "session-start")
        )
        #expect(
            try QuickTTYCommand.parse(["internal", "hook", "codex", "replaceSession"])
                == .internalHook(adapterID: "codex", event: "replaceSession")
        )
        #expect(try QuickTTYCommand.parse(["internal", "launch"]) == .internalLaunch)

        let wrapped = try QuickTTYCommand.parse([
            "internal", "wrap", "amp", "--", "--flag", "a b", ";echo", "",
        ])
        #expect(
            wrapped
                == .internalWrap(
                    adapterID: "amp",
                    arguments: ["--flag", "a b", ";echo", ""]
                )
        )
    }

    @Test
    func rejectsMalformedInternalGrammar() {
        let malformed = [
            ["internal"],
            ["internal", "hook", "codex"],
            ["internal", "hook", "codex", "event", "extra"],
            ["internal", "launch", "extra"],
            ["internal", "wrap", "codex"],
            ["internal", "unknown"],
        ]
        for arguments in malformed {
            #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
                try QuickTTYCommand.parse(arguments)
            }
        }

        #expect(throws: QuickTTYCommand.ParseError.invalidAdapterID("unsafe_ID")) {
            try QuickTTYCommand.parse(["internal", "hook", "unsafe_ID", "event"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidHookEvent("unsafe_event")) {
            try QuickTTYCommand.parse(["internal", "hook", "codex", "unsafe_event"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidGrammar) {
            try QuickTTYCommand.parse(["internal", "wrap", "amp", "--injected"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidWrapperAdapter("codex")) {
            try QuickTTYCommand.parse(["internal", "wrap", "codex", "--"])
        }
        #expect(throws: QuickTTYCommand.ParseError.invalidArguments) {
            try QuickTTYCommand.parse([
                "internal", "wrap", "amp", "--", String(repeating: "x", count: 4_097),
            ])
        }
    }
}
