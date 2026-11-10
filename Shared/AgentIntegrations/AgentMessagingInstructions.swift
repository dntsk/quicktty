import Foundation

enum AgentMessagingInstructions {
    private struct ContextOutput: Encodable {
        struct Specific: Encodable {
            let hookEventName = "SessionStart"
            let additionalContext: String
        }
        let hookSpecificOutput: Specific
    }

    static func sessionStartOutput(adapterID: String, event: String, helperPath: String) -> Data? {
        guard ["claude", "codex", "gemini"].contains(adapterID), event == "SessionStart",
            helperPath.utf8.count <= 4_096,
            AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(helperPath),
            let executable = try? AgentIntegrationInstaller.posixSingleQuoted(helperPath)
        else { return nil }
        let context =
            "For the quicktty command below, use this exact executable: \(executable)\n\n" + text
        return try? AgentMessagingProtocol.encode(
            ContextOutput(hookSpecificOutput: .init(additionalContext: context)))
    }

    static let text = """
        QuickTTY remote questions and one-time decisions

        When Telegram is enabled in QuickTTY > Agent Integrations, the saved bot reconnects on
        launch and registered agents in every workspace receive messaging access automatically.
        Use `quicktty agent request` for this live registered session; no copied instructions or
        per-workspace/session setup is needed. The installed CLI and lifecycle integration must be
        current. Host authentication still decides access. This does not approve any action, change
        settings or replace native harness policy.

        When you need a human answer, submit a minimal non-secret question through this CLI rather
        than merely ending the turn with an unanswered question. Send one JSON object on stdin;
        do not put prompts in shell-interpolated code. The CLI returns one JSON object on stdout.
        Never read, print or copy app credentials, native session metadata or the bot token.

        Generate a UUID once per logical question/action (for example with uuidgen). Keep that UUID
        and the full unchanged payload for recovery; never create a new UUID just to bypass a failure.
        Every request has version: 1 and requestID: that UUID.

        - Question: operation: "question", text: the question, optional choices: up to eight unique
          strings, optional timeoutMilliseconds: 1000...1800000 (default 900000).
        - Action: operation: "action", text: the exact operation, resources: the affected resources,
          consequences: the effects. Elevated confirmation is the default; do not downgrade risk to
          avoid confirmation. This request executes nothing. Wait for its result before issuing the
          protected action in a later tool/model turn; never batch an action with its confirmation.
        - Wait: operation: "wait", requestID: the original UUID, timeoutMilliseconds: 30000.
          A bounded wait returning pending is not approval. Avoid tight polling or unbounded loops.
        - Status: operation: "status", requestID: the original UUID. Use this to inspect a known
          request after uncertain delivery instead of submitting a new operation.
        - Cancel: operation: "cancel", requestID: the original UUID. This closes only a pending
          request; it cannot undo an accepted answer or an executed external action.
        - Notice: operation: "notify", a fresh requestID, status: "completed", "failed" or "waiting",
          and text: a brief non-secret summary. accepted means queued, not proven delivery.

        A question returns state text with text, or choice with choiceIndex (zero-based) and text.
        Only state approved for the exact unchanged action permits that action, once. Denied,
        cancelled, expired, revoked, error, pending and process exit code 0 are not approval.
        Re-reading an old approved result is not a new authorization to execute again. Native
        permission dialogs and all other user/system restrictions remain in force.

        On permissionRequired or unavailable, ask the user locally; Telegram may be paused or the
        session may not be registered. Do not change settings, install integrations or retry
        repeatedly to pressure the user. On deliveryUncertain, inspect status
        for the same UUID. On requestIDConflict, stop and reconcile the original payload.
        Never reissue a denied request without a new explicit user instruction.

        Bot chats are not end-to-end encrypted. Do not send passwords, secrets, raw tool arguments,
        terminal dumps, transcripts or private session identifiers. Questions are limited to 2304
        UTF-8 bytes; each choice to 64; action text to 1024; resources/consequences to 768 each;
        notices to 512. Do not truncate an action to hide relevant details: ask locally if it cannot
        be represented safely. A failed/aborted run is not successful completion.
        """
}
