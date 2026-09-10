import AppKit
import Darwin
import Foundation
import Testing

@testable import QuickTTY

// WHY: These assertions require a separately authorized hosted run with the pinned native library.
// Synthetic unknown-status and duplicate/late callback policy coverage remains in
// WindowCoordinatorTerminalAutomationTests; this suite never manufactures a native exit.
@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct TerminalControlGhosttyIntegrationTests {
    @Test
    func managedStreamsAreTTYAndInteractiveRequestUsesRealHelperArgv() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let absenceChecks = NativeControlPTYFixture.credentialNames.map {
            "[ \"${\($0)+x}\" != x ] || exit 81"
        }.joined(separator: "\n")
        let child = try await fixture.launch(
            script: #"""
                /usr/bin/tty || exit 80
                [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 80
                printf 'ALL-STREAMS-TTY\n'
                \#(absenceChecks)
                printf 'CREDENTIALS-ABSENT\n'
                [ "$1" = 'two words' ] && [ "$2" = 'literal;$HOME' ] || exit 82
                printf 'ARGV-INTACT\n'
                printf 'STDOUT-MARKER\n'
                printf 'STDERR-MARKER\n' >&2
                printf 'INPUT-PROMPT\n'
                IFS= read -r -t 15 reply || exit 83
                [ "$reply" = 'synthetic answer' ] || exit 84
                printf 'REPLY-ACCEPTED\n'
                gate
                printf 'INTERACTIVE-FINAL\n'
                exit 0
                """#,
            arguments: ["two words", "literal;$HOME"])
        try child.release()
        let prompt = try await fixture.text("INPUT-PROMPT", from: child)
        #expect(prompt.text.contains("/dev/tty"))
        for marker in [
            "ALL-STREAMS-TTY", "CREDENTIALS-ABSENT", "ARGV-INTACT", "STDOUT-MARKER",
            "STDERR-MARKER",
        ] {
            #expect(prompt.text.contains(marker))
        }
        #expect(!prompt.isTruncated)
        #expect(!prompt.text.contains("\u{1B}"))
        #expect(prompt.task.state == .running && prompt.task.exitCode == nil)
        #expect(fixture.controller.environment(for: child.paneID) == nil)
        let originEnvironment = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: fixture.originPaneID)?.environment)
        // WHY: Absence is not vacuous: the owned origin really received lifecycle/control identity.
        #expect(
            NativeControlPTYFixture.credentialNames.dropLast().allSatisfy {
                originEnvironment[$0] != nil
            })

        // WHY: Echo is disabled, so only the child's comparison can acknowledge this input.
        try await fixture.sendText("synthetic answer", to: child)
        try await fixture.sendKey(.enter, to: child)
        _ = try await fixture.text("REPLY-ACCEPTED", from: child)
        let beforeExit = try await fixture.read(child)
        try child.release()
        let changed = try nativeControlTask(
            await fixture.request(
                .wait(
                    taskID: child.task.taskID, revision: beforeExit.task.revision,
                    timeoutMilliseconds: 5_000)))
        #expect(changed.revision > beforeExit.task.revision)
        let final = try await fixture.completed(child)
        #expect(final.task.state == .succeeded && final.task.exitCode == 0)
        #expect(final.task.owner == .finished)
        #expect(final.text.contains("INTERACTIVE-FINAL"))
    }

    @Test
    func realHistoryIsBoundedAndFullscreenRedrawReturnsRenderedCells() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let child = try await fixture.launch(
            script: #"""
                printf 'EARLIEST-PREFIX\n'
                i=0
                while [ "$i" -lt 4000 ]; do printf 'HISTORY-ROW-%s\n' "$i"; i=$((i + 1)); done
                printf 'HISTORY-END\n'
                gate
                printf '\033[?1049h\033[HOLD-FRAME'
                gate
                printf '\033[2J\033[H\033[32mREDRAW-FINAL\033[0m'
                printf '\033]0;REDRAW-READY\007'
                gate
                printf '\033[?1049l\r\nRENDER-FINAL\n'
                exit 0
                """#)
        try child.release()
        let history = try await fixture.text("HISTORY-END", from: child)
        #expect(history.isTruncated)
        #expect(history.text.utf8.count <= TerminalControlProtocol.maximumSnapshotSize)
        #expect(!history.text.contains("EARLIEST-PREFIX"))
        #expect(history.text.contains("HISTORY-ROW-3999"))
        #expect(!history.text.contains("\u{1B}"))
        try child.release()
        _ = try await fixture.text("OLD-FRAME", from: child)
        try child.release()
        try await nativeControlWait("alternate screen grid") {
            guard let size = child.surface.sizeSnapshotForTesting else { return false }
            return child.surface.currentTitle == "REDRAW-READY"
                && child.surface.scrollbarStateForTesting?.total == UInt64(size.rows)
        }
        let redraw = try await fixture.text("REDRAW-FINAL", from: child)
        #expect(!redraw.text.contains("OLD-FRAME"))
        #expect(!redraw.text.contains("HISTORY-ROW"))
        #expect(!redraw.text.contains("\u{1B}"))
        #expect(!redraw.isTruncated)
        try child.release()
        let final = try await fixture.completed(child)
        #expect(final.task.exitCode == 0)
        #expect(final.text.contains("RENDER-FINAL"))
    }

    @Test
    func echoDisabledPasswordUsesManualNativeInputUntilExplicitReturnControl() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        // WHY: This fixed nonsecret is never taken from a person, environment or credential store.
        let password = "pppppppp"
        let child = try await fixture.launch(
            script: #"""
                /bin/stty -echo
                printf 'SYNTHETIC-PASSWORD-PROMPT\n'
                IFS= read -r -t 15 password || exit 85
                [ "$password" = 'pppppppp' ] || exit 86
                unset password
                printf 'MANUAL-INPUT-ACCEPTED\n'
                IFS= read -r -t 15 resumed || exit 87
                [ "$resumed" = 'agent-resumed' ] || exit 88
                printf 'PASSWORD-FINAL\n'
                exit 0
                """#)
        try child.release()
        let prompt = try await fixture.text("SYNTHETIC-PASSWORD-PROMPT", from: child)
        #expect(!prompt.text.contains(password))
        let waiting = try nativeControlTask(
            await fixture.request(.requestUserInput(taskID: child.task.taskID)))
        #expect(waiting.owner == .user && waiting.state == .waitingForUser)
        #expect(waiting.revision > prompt.task.revision)
        #expect(fixture.coordinator.activeWindowForTesting?.firstResponder === child.surface)
        nativeControlFailure(
            try await fixture.request(
                .sendText(
                    taskID: child.task.taskID, expectedRevision: waiting.revision,
                    text: "agent-must-not-type")), .userControlsPane)
        let automationInputs = child.surface.automationTextObservationsForTesting.count
        for _ in password {
            try fixture.manualKey("p", keyCode: 35, on: child)
        }
        try fixture.manualKey("\r", keyCode: 36, on: child)
        // WHY: Child acknowledgement, not a sleep, proves the entire manual line was consumed.
        let accepted = try await fixture.text("MANUAL-INPUT-ACCEPTED", from: child)
        #expect(!accepted.text.contains(password))
        #expect(accepted.task.owner == .user && accepted.task.state == .waitingForUser)
        #expect(child.surface.automationTextObservationsForTesting.count == automationInputs)
        nativeControlFailure(
            try await fixture.request(
                .sendKey(
                    taskID: child.task.taskID, expectedRevision: accepted.task.revision,
                    key: .enter)), .userControlsPane)
        #expect(fixture.coordinator.returnControlToAgent(taskID: child.task.taskID))
        let returned = try await fixture.read(child)
        #expect(returned.task.owner == .agent && returned.task.state == .running)
        #expect(returned.task.revision > accepted.task.revision)
        try await fixture.sendText("agent-resumed", to: child)
        try await fixture.sendKey(.enter, to: child)
        let final = try await fixture.completed(child)
        #expect(final.task.exitCode == 0 && final.task.owner == .finished)
        #expect(final.text.contains("PASSWORD-FINAL"))
        #expect(!final.text.contains(password))
    }

    @Test(arguments: [TerminalSplitDirection.right, .down])
    func splitResizeReachesChildAndWireKeysHaveExactRawBytes(direction: TerminalSplitDirection)
        async throws
    {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let keys: [TerminalControlKey] = [
            .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .tab, .escape, .delete,
            .controlD, .backspace,
        ]
        let expected = Data([
            0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x42, 0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x43,
            0x09, 0x1B, 0x1B, 0x5B, 0x33, 0x7E, 0x04, 0x7F,
        ])
        let child = try await fixture.launch(
            script: #"""
                printf 'SIZE-BEFORE '; /bin/stty size
                printf 'SIZE-BEFORE-DONE\n'
                gate
                sample=0
                while :; do
                    printf 'SIZE-AFTER-%s ' "$sample"
                    /bin/stty size || exit 91
                    printf 'SIZE-AFTER-%s-DONE\n' "$sample"
                    gate
                    [ "$token" = 'SIZE-ACCEPTED' ] && break
                    sample=$((sample + 1))
                done
                /bin/stty raw -echo min 0 time 50 || exit 91
                printf '\033[?1l\033[?2004lWIRE-READY'
                /bin/dd bs=1 count=\#(expected.count + 1) of=wire-bytes 2>/dev/null
                /bin/stty sane -echo || exit 91
                printf '\r\nWIRE-DONE\n'
                gate
                printf 'KEYS-FINAL\n'
                exit 0
                """#, splitDirection: direction)
        try child.release()
        let before = try nativeControlSize(
            in: await fixture.text("SIZE-BEFORE-DONE", from: child), prefix: "SIZE-BEFORE")
        let oldGrid = try #require(child.surface.sizeSnapshotForTesting)
        #expect(before == [Int(oldGrid.rows), Int(oldGrid.columns)])
        _ = try nativeControlTask(
            await fixture.request(.resize(taskID: child.task.taskID, ratio: 0.25)))
        try await nativeControlWait("resized native grid") {
            fixture.layout()
            guard let size = child.surface.sizeSnapshotForTesting else { return false }
            return size.rows > 0 && size.columns > 0
                && (direction == .right
                    ? size.columns != oldGrid.columns : size.rows != oldGrid.rows)
        }
        let expectedGrid = try #require(child.surface.sizeSnapshotForTesting)
        let expectedSize = [Int(expectedGrid.rows), Int(expectedGrid.columns)]
        // WHY: The native grid precedes the coalesced PTY ioctl. Each FIFO release requests
        // a NEW child stty measurement; only a matching measurement is a resize barrier.
        // All samples share one deadline, including rendered-output polling (no extra sleep).
        let sizeDeadline = ContinuousClock.now + .seconds(8)
        var sample = 0
        var after: [Int]
        repeat {
            try Task.checkCancellation()
            guard ContinuousClock.now < sizeDeadline else {
                throw NativeControlPTYError.timeout("child PTY size: \(expectedSize)")
            }
            try child.release()
            let prefix = "SIZE-AFTER-\(sample)"
            after = try nativeControlSize(
                in: await fixture.text(prefix + "-DONE", from: child, deadline: sizeDeadline),
                prefix: prefix)
            sample += 1
        } while after != expectedSize
        let grid = try #require(child.surface.sizeSnapshotForTesting)
        #expect(after == [Int(grid.rows), Int(grid.columns)])
        #expect(after != before)
        #expect(after[direction == .right ? 1 : 0] < before[direction == .right ? 1 : 0])
        try child.release("SIZE-ACCEPTED")
        _ = try await fixture.text("WIRE-READY", from: child)
        for key in keys { try await fixture.sendKey(key, to: child) }
        // WHY: A trailing sentinel detects excess/missing key bytes without an unbounded reader.
        try await fixture.sendText("!", to: child)
        _ = try await fixture.text("WIRE-DONE", from: child)
        #expect(
            try Data(contentsOf: child.directory.appending(path: "wire-bytes"))
                == expected + Data("!".utf8))
        try child.release()
        let final = try await fixture.completed(child)
        #expect(final.task.exitCode == 0)
        #expect(final.text.contains("KEYS-FINAL"))
    }

    @Test
    func realQuickExitsRetainFinalTailBeforePolicyClosureWithoutOSC() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        // WHY: Four normal policy combinations and two real signals share one origin/window.
        let cases: [(String, Int32, TerminalTaskLifecyclePolicy)] = [
            ("exit 0", 0, .keep), ("exit 7", 7, .keep),
            ("exit 0", 0, .closeOnSuccess), ("exit 7", 7, .closeOnSuccess),
            ("kill -TERM \"$$\"", 128 + SIGTERM, .closeOnSuccess),
            ("kill -KILL \"$$\"", 128 + SIGKILL, .closeOnSuccess),
        ]
        for (ending, code, policy) in cases {
            let marker = "FINAL-TAIL-\(UUID().uuidString.prefix(8))"
            let child = try await fixture.launch(
                script: #"""
                    i=0
                    while [ "$i" -lt 512 ]; do
                        printf 'TAIL-ROW-%s-abcdefghijklmnopqrstuvwxyz\n' "$i"
                        i=$((i + 1))
                    done
                    printf '\#(marker)\n'
                    \#(ending)
                    """#, policy: policy)
            let observer = NativeControlReadObserver(surface: child.surface, bridge: fixture.bridge)
            // WHY: Force obsolete metadata immediately before the actual native tail read.
            observer.staleScrollbarBeforeRead = true
            fixture.bridge.setTerminalAutomationClientForTesting(observer.client)
            let session = try fixture.session()
            var exits: [GhosttyProcessExited] = []
            let installed = try #require(fixture.bridge.surfaceProcessExitedHandler)
            fixture.bridge.surfaceProcessExitedHandler = { pane, event in
                if pane == child.paneID { exits.append(event) }
                installed(pane, event)
            }
            var retainedAtClose: TerminalControlSnapshot?
            fixture.commits.onCommit = { [weak coordinator = fixture.coordinator] in
                guard let coordinator,
                    coordinator.surfaceForTesting(id: child.paneID) == nil,
                    case .snapshot(let snapshot) = coordinator.readManagedTask(
                        taskID: child.task.taskID, expectedSession: session)
                else { return }
                retainedAtClose = snapshot
            }
            defer {
                fixture.commits.onCommit = nil
                fixture.bridge.setTerminalAutomationClientForTesting(.live)
            }
            // WHY: Do not pre-read the host cache: its 250 ms throttle would hide an EOF race.
            // The only release barrier is a real mounted/drawn grid, never a fake completion.
            try child.release()
            let final = try await fixture.completed(child)
            #expect(exits.count == 1)
            #expect(exits.first?.exitCode.map { Int32($0) } == code)
            #expect(final.task.exitCode == code)
            #expect(final.task.state == (code == 0 ? .succeeded : .failed))
            #expect(final.task.owner == .finished && final.task.policy == policy)
            #expect(final.text.contains(marker))
            #expect(final.text.utf8.count <= TerminalControlProtocol.maximumSnapshotSize)
            #expect(!final.text.contains("\u{1B}"))
            #expect(observer.finalReadBeforeClose)
            #expect(observer.finalReadAttempts == 1)
            #expect(observer.finalReadOutputStates == [.complete])
            #expect(
                observer.finalBytes.map {
                    String(decoding: $0, as: UTF8.self).contains(marker)
                } == true)
            let closes = code == 0 && policy == .closeOnSuccess
            #expect((fixture.coordinator.surfaceForTesting(id: child.paneID) == nil) == closes)
            if closes { #expect(retainedAtClose == final) }
            #expect(try await fixture.read(child) == final)
            // WHY: Retained text must survive a real close even for keep/failed tasks.
            _ = try nativeControlTask(
                await fixture.request(.close(taskID: child.task.taskID)))
            #expect(try await fixture.read(child) == final)
            #expect(retainedAtClose == final)
            #expect(
                fixture.bridge.successfulSurfaceCloseObservationsForTesting.filter {
                    $0 == child.paneID
                }.count == 1)
            #expect(observer.readCount == observer.freeCount)
        }
    }

    @Test
    func realUnicodeTailIsBoundedByNativeBytesDespiteStaleScrollbar() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let child = try await fixture.launch(
            script: #"""
                i=0
                while [ "$i" -lt 4000 ]; do
                    printf '猫é👩🏽‍💻-UNICODE-%s\n' "$i"
                    i=$((i + 1))
                done
                printf 'UNICODE-FINAL-猫'
                exit 0
                """#)
        try child.release()
        let final = try await fixture.completed(child)
        #expect(final.text.contains("UNICODE-FINAL-猫"))
        #expect(final.isTruncated)
        #expect(fixture.bridge.outputState(id: child.paneID) == .complete)
        for limit in [1, 3, 7, 1024, 65_536] {
            #expect(child.surface.scheduleScrollbarCallbackForTesting(total: 1, offset: 0, len: 1))
            let tail = try fixture.bridge.readRenderedText(
                id: child.paneID, maximumUTF8Bytes: limit)
            #expect(tail.text.utf8.count <= limit)
            #expect(tail.isTruncated)
            #expect(String(data: Data(tail.text.utf8), encoding: .utf8) == tail.text)
            // WHY: Native suffixes preserve scalars, not necessarily whole grapheme clusters.
            #expect(Data(final.text.utf8).suffix(tail.text.utf8.count) == Data(tail.text.utf8))
        }
    }

    @Test
    func darwinControllingProcessExitRevokesDescendantTTYAndCompletesOutput() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        do {
            try await fixture.show()
            for writesContinuously in [false, true] {
                // WHY: Darwin _exit(2) revokes ALL current controlling-terminal access.
                // Ghostty pty.zig childPreExec uses setsid + TIOCSCTTY, so the managed root
                // is that controlling process; an inherited slave does not postpone native EOF.
                // Pending timeout/no-autoclose/manual-fallback safety belongs to the policy spy suite.
                let descendantProgram =
                    writesContinuously
                    ? #"""
                    printf 'DESCENDANT-OUTPUT\n' 2>/dev/null || exit 92
                    : > descendant-ready || exit 92
                    while printf 'DESCENDANT-OUTPUT\n' 2>/dev/null; do :; done
                    """#
                    : #"""
                    : > descendant-ready || exit 92
                    gate
                    if printf 'DESCENDANT-AFTER-ROOT\n' 2>/dev/null; then
                        : > descendant-write-unexpectedly-succeeded
                        exit 93
                    fi
                    """#
                let child = try await fixture.launch(
                    script: #"""
                        if [ -f descendant-stop ]; then
                            : > descendant-not-started
                            exit 0
                        fi
                        (
                            trap '' HUP
                            [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 92
                            \#(descendantProgram)
                            : > descendant-write-failed || exit 92
                            exit 0
                        ) <&0 &
                        printf 'DESCENDANT:%s\n' "$!" > descendant-pid || exit 92
                        : > descendant-pid-ready || exit 92
                        while [ ! -f descendant-ready ]; do
                            [ -f descendant-stop ] && break
                        done
                        printf 'ROOT-FINAL\n'
                        exit 0
                        """#, policy: .keep, requiresDescendantExit: true)
                let observer = NativeControlReadObserver(
                    surface: child.surface, bridge: fixture.bridge)
                fixture.bridge.setTerminalAutomationClientForTesting(observer.client)
                defer { fixture.bridge.setTerminalAutomationClientForTesting(.live) }
                let clock = ContinuousClock()
                var observedAt: ContinuousClock.Instant?
                var exits: [GhosttyProcessExited] = []
                let installed = try #require(fixture.bridge.surfaceProcessExitedHandler)
                defer { fixture.bridge.surfaceProcessExitedHandler = installed }
                fixture.bridge.surfaceProcessExitedHandler = { pane, event in
                    if pane == child.paneID {
                        observedAt = clock.now
                        exits.append(event)
                    }
                    installed(pane, event)
                }
                // WHY: No interim cache read may mask a premature final capture.
                try child.release()
                let final = try await fixture.completed(child)
                let observation = try #require(observedAt)
                #expect(observation.duration(to: clock.now) < .seconds(5))
                #expect(exits.count == 1 && exits.first?.exitCode == 0)
                #expect(final.task.state == .succeeded && final.task.exitCode == 0)
                #expect(final.task.owner == .finished && final.task.policy == .keep)
                #expect(final.text.contains("ROOT-FINAL"))
                #expect(final.text.utf8.count <= TerminalControlProtocol.maximumSnapshotSize)
                #expect(!final.text.contains("\u{1B}"))
                #expect(observer.finalReadBeforeClose && observer.finalReadAttempts == 1)
                #expect(observer.finalReadOutputStates == [.complete])
                #expect(observer.readCount == 1 && observer.freeCount == 1)
                #expect(
                    observer.finalBytes.map {
                        String(decoding: $0, as: UTF8.self).contains("ROOT-FINAL")
                    } == true)
                try #require(fixture.bridge.outputState(id: child.paneID) == .complete)
                try #require(
                    fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface
                        && child.surface.isReady)
                try #require(
                    !fixture.bridge.successfulSurfaceCloseObservationsForTesting.contains(
                        child.paneID))
                try #require(
                    FileManager.default.fileExists(
                        atPath: child.directory.appending(path: "descendant-pid-ready").path))
                let descendantPID = try nativeControlPID(
                    in: String(
                        contentsOf: child.directory.appending(path: "descendant-pid"),
                        encoding: .utf8), prefix: "DESCENDANT:")
                let writeFailure = child.directory.appending(path: "descendant-write-failed")
                if !writesContinuously {
                    // WHY: EOF does not mean all descendants died. Release the HUP-ignoring
                    // child only AFTER root capture, while the original master/surface is kept.
                    try #require(Darwin.kill(descendantPID, 0) == 0)
                    try #require(!FileManager.default.fileExists(atPath: writeFailure.path))
                    try child.release()
                }
                // WHY: The continuous writer must stop on printf's real error, not a stop file.
                // Its exit may precede root observation; only the quiet case must still be alive.
                try await nativeControlWait("descendant inherited-TTY write failure and exit") {
                    FileManager.default.fileExists(atPath: writeFailure.path)
                        && Darwin.kill(descendantPID, 0) == -1 && errno == ESRCH
                }
                child.resources.descendantExitPending = false
                #expect(
                    !FileManager.default.fileExists(
                        atPath: child.directory.appending(
                            path: "descendant-write-unexpectedly-succeeded"
                        ).path))
                #expect(
                    !FileManager.default.fileExists(
                        atPath: child.directory.appending(path: "descendant-stop").path))
                #expect(fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface)
                #expect(child.surface.isReady)
                #expect(fixture.bridge.outputState(id: child.paneID) == .complete)
                #expect(try await fixture.read(child) == final)
                _ = try nativeControlTask(await fixture.request(.close(taskID: child.task.taskID)))
                #expect(!child.surface.isReady)
                #expect(try await fixture.read(child) == final)
                #expect(observer.readCount == 1 && observer.readCount == observer.freeCount)
            }
        } catch {
            // WHY: Async cleanup must finish even when launch/grid/read assertions throw or cancel.
            do { try await fixture.stopDescendants() } catch {
                Issue.record("Could not confirm owned descendant exit: \(error)")
            }
            throw error
        }
    }

    @Test
    func oscCommandFinishedIsActivityWhileManagedShellRemainsAlive() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let child = try await fixture.launch(
            script: #"""
                printf '\033]133;A\007\033]133;B\007\033]133;C\007'
                printf 'SHELL-COMMAND-OUTPUT\n'
                printf '\033]133;D;0\007'
                printf 'LIVE-SHELL-PROMPT\n'
                IFS= read -r -t 15 reply || exit 87
                [ "$reply" = 'still alive' ] || exit 88
                printf 'SHELL-STILL-ALIVE\n'
                gate
                printf 'SHELL-REAL-FINAL\n'
                exit 7
                """#, policy: .closeOnSuccess)
        var commandCount = 0
        let installed = try #require(fixture.bridge.surfaceCommandFinishedHandler)
        fixture.bridge.surfaceCommandFinishedHandler = { pane, command in
            if pane == child.paneID { commandCount += 1 }
            installed(pane, command)
        }
        try child.release()
        _ = try await fixture.text("LIVE-SHELL-PROMPT", from: child)
        try await nativeControlWait("real OSC command-finished callback") { commandCount > 0 }
        let live = try await fixture.read(child)
        #expect(live.task.state == .running && live.task.owner == .agent)
        #expect(live.task.exitCode == nil)
        #expect(!child.surface.processExitedForTesting)
        #expect(
            fixture.coordinator.managedCompletionTaskForTesting(taskID: child.task.taskID) == nil)
        try await fixture.sendText("still alive", to: child)
        try await fixture.sendKey(.enter, to: child)
        _ = try await fixture.text("SHELL-STILL-ALIVE", from: child)
        try child.release()
        let final = try await fixture.completed(child)
        #expect(final.task.state == .failed && final.task.exitCode == 7)
        #expect(final.text.contains("SHELL-REAL-FINAL"))
        #expect(fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface)
    }

    @Test
    func controlCAndInterruptTerminateRealForegroundProcess() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        for useInterrupt in [false, true] {
            let child = try await fixture.launch(
                script: #"printf 'CAT-INPUT-READY\n'; exec /bin/cat"#, policy: .closeOnSuccess)
            try child.release()
            _ = try await fixture.text("CAT-INPUT-READY", from: child)
            // WHY: With kernel echo off, this acknowledgement proves exec reached the actual cat.
            try await fixture.sendText("CAT-READY", to: child)
            try await fixture.sendKey(.enter, to: child)
            _ = try await fixture.text("CAT-READY", from: child)
            if useInterrupt {
                let current = try await fixture.read(child)
                try nativeControlAcknowledged(
                    await fixture.request(
                        .interrupt(
                            taskID: child.task.taskID, expectedRevision: current.task.revision)))
            } else {
                try await fixture.sendKey(.controlC, to: child)
            }
            let final = try await fixture.completed(child)
            #expect(final.task.state == .failed)
            #expect(final.task.exitCode == 128 + SIGINT)
            #expect(final.task.owner == .finished)
            #expect(fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface)
            _ = try nativeControlTask(await fixture.request(.close(taskID: child.task.taskID)))
        }
    }

    @Test
    func liveManagedProjectionRoundTripsIntoFreshShellWithoutRuntimeCapabilities() async throws {
        let fixture = try NativeControlPTYFixture()
        defer { fixture.shutdown() }
        try await fixture.show()
        let executable = fixture.directory.appending(path: "task13-managed-executable")
        try Data("#!/bin/sh\nexec /bin/sh \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let argument = "task13-argv-\(UUID().uuidString)"
        let output = "task13-output-\(UUID().uuidString)"
        let child = try await fixture.launch(
            script: #"""
                [ "$1" = '\#(argument)' ] || exit 82
                printf '\#(output)\n'
                printf 'OLD-MANAGED-PID:%s\n' "$$"
                gate
                exit 0
                """#,
            arguments: [argument], policy: .closeOnSuccess, splitDirection: .right,
            executable: executable.path)
        try child.release()
        let live = try await fixture.text("OLD-MANAGED-PID:", from: child)
        #expect(live.text.contains(output))
        #expect(live.task.owner == .agent && live.task.policy == .closeOnSuccess)
        #expect(live.task.state == .running && live.task.exitCode == nil)
        let oldPID = try nativeControlPID(in: live.text, prefix: "OLD-MANAGED-PID:")
        #expect(Darwin.kill(oldPID, 0) == 0)
        let session = try fixture.session()
        #expect(fixture.commits.permissionSessions == [session])
        let oldToken = try #require(
            fixture.controller.environment(for: fixture.originPaneID)?["QUICKTTY_PANE_TOKEN"])
        let configuration = try #require(
            fixture.bridge.surfaceConfigurationForTesting(id: child.paneID))
        let encodedPayload = try #require(
            configuration.environment[AgentInvocationPayloadEnvironment.payloadKey])
        let payload = try AgentInvocationPayloadCodec.decodeBase64(encodedPayload)
        #expect(payload.executable == executable.path)
        #expect(payload.arguments.last == argument)
        #expect(payload.workingDirectory == child.directory.path)
        // WHY: This accepted mutation also leaves a real replay entry and a non-default split ratio.
        let replay = try TerminalControlRequest(
            operation: .resize(taskID: child.task.taskID, ratio: 0.37), requestID: UUID())
        _ = try nativeControlTask(await fixture.request(replay))
        let projection = try #require(fixture.commits.latest)
        #expect(projection == fixture.coordinator.workspaceStoreForPersistence)
        let tab = try #require(projection.tab(id: TabID(rawValue: child.task.tabID)))
        #expect(tab.root.leaves.count == 2)
        #expect(tab.activePaneID == child.paneID)
        let oldSplitID = try #require(
            fixture.coordinator.managedSplitIDForTesting(taskID: child.task.taskID))
        guard case .split(let splitID, let axis, let ratio, let first, let second) = tab.root else {
            throw NativeControlPTYError.timeout("persisted managed split")
        }
        #expect(splitID == oldSplitID && axis == .horizontal)
        #expect(abs(ratio - 0.63) < 0.001)
        #expect(first == .pane(fixture.originPaneID) && second == .pane(child.paneID))
        let descriptor = try #require(tab.paneDescriptor(for: child.paneID))
        #expect(descriptor.cwd == child.directory.path)
        #expect(descriptor.startupCommand == .shell && descriptor.agentResumeBinding == nil)

        let stateURL = fixture.directory.appending(path: "state.json")
        let codec = try StateStore(url: stateURL, homeDirectoryURL: fixture.directory)
        try codec.saveNow(ApplicationState(workspaceStore: projection))
        let bytes = try Data(contentsOf: stateURL)
        // WHY: Inspect the real codec bytes independently of decoding. Nothing is filtered out
        // by the test; the origin's legitimate resume binding and pane/layout UUIDs may persist.
        for sentinel in [
            executable.path, argument, output, encodedPayload, oldToken,
            child.task.taskID.uuidString, session.instanceID.uuidString,
            try #require(replay.requestID).uuidString,
            "\"executable\"", "\"arguments\"", "\"output\"", "\"owner\"", "\"agent\"",
            "\"policy\"", "close-on-success", "\"grants\"", "\"taskID\"",
            "\"ownedPaneIDs\"", "\"paneCredentialGeneration\"",
            AgentInvocationPayloadEnvironment.payloadKey,
        ] {
            #expect(
                !bytes.contains(Data(sentinel.utf8)), "Serialized runtime sentinel: \(sentinel)")
        }
        let decoded = try codec.load()
        #expect(decoded.workspaceStore == projection)

        // WHY: Retain CWD directories, not the old runtime. The new start must traverse
        // restoreWorkspaceSurfaces using exactly the decoded store, with no descriptor rewrite.
        fixture.stopRuntime()
        #expect(!child.surface.isReady && fixture.bridge.activeSurfaceCount == 0)
        try await nativeControlWait("old managed process reaped before restart") {
            Darwin.kill(oldPID, 0) == -1 && errno == ESRCH
        }
        let restored = try NativeControlPTYFixture(restoring: decoded)
        defer { restored.shutdown() }
        try await restored.show()
        let shell = try #require(restored.coordinator.surfaceForTesting(id: child.paneID))
        try await restored.waitForGrid(shell)
        #expect(restored.bridge !== fixture.bridge && restored.coordinator !== fixture.coordinator)
        #expect(
            restored.controller !== fixture.controller && restored.instanceID != fixture.instanceID)
        #expect(shell !== child.surface && shell.isReady && !shell.processExitedForTesting)
        #expect(restored.coordinator.workspaceStoreForPersistence == projection)
        let shellConfiguration = try #require(
            restored.bridge.surfaceConfigurationForTesting(id: child.paneID))
        #expect(shellConfiguration.command == nil && shellConfiguration.initialInput == nil)
        #expect(shellConfiguration.managedHelperPath == nil)
        #expect(restored.bridge.outputState(id: child.paneID) == .failed)
        #expect(shellConfiguration.workingDirectory == child.directory.path)
        #expect(shellConfiguration.environment[AgentInvocationPayloadEnvironment.payloadKey] == nil)
        #expect(restored.coordinator.managedTaskCountForTesting == 0)
        #expect(restored.coordinator.managedTaskForTesting(taskID: child.task.taskID) == nil)
        #expect(
            restored.coordinator.managedCompletionTaskForTesting(taskID: child.task.taskID) == nil)
        #expect(restored.coordinator.managedSplitIDForTesting(taskID: child.task.taskID) == nil)
        #expect(!restored.coordinator.returnControlToAgent(taskID: child.task.taskID))
        #expect(restored.commits.permissionSessions.isEmpty)
        let freshSession = try restored.session()
        #expect(freshSession != session)
        #expect(
            restored.controller.environment(for: restored.originPaneID)?["QUICKTTY_PANE_TOKEN"]
                != oldToken)
        let oldPreflight = try TerminalControlPreflight(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            nonce: Data(repeating: 1, count: TerminalControlProtocol.nonceSize))
        #expect(restored.controller.credential(for: oldPreflight) == nil)
        nativeControlFailure(
            await restored.coordinator.handleTerminalAutomationRequest(
                TerminalControlSocketRequest(
                    instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                    request: replay), context: TerminalControlRequestContext()), .invalidSession)
        let listing = try await restored.request(.list)
        guard case .list(_, let tasks) = listing.result else {
            throw NativeControlPTYError.response(listing)
        }
        #expect(tasks.isEmpty)
        #expect(restored.commits.permissionSessions == [freshSession])
        // WHY: Even AFTER a fresh permission grant, old replay/task/pane/tab UUIDs confer no control.
        nativeControlFailure(try await restored.request(replay), .targetNotOwned)
        for id in [child.task.taskID, child.task.paneID, child.task.tabID, oldSplitID] {
            nativeControlFailure(try await restored.request(.read(taskID: id)), .targetNotOwned)
            nativeControlFailure(try await restored.request(.close(taskID: id)), .targetNotOwned)
        }
        #expect(restored.coordinator.managedTaskCountForTesting == 0)
        #expect(restored.coordinator.workspaceStoreForPersistence == projection)

        // WHY: The configured default is an isolated interactive shell, NOT another managed cat.
        // Expansion of $$/$PWD and a fresh challenge prove the process started by actual restore.
        let challenge = UUID().uuidString.prefix(8)
        let prefix = "FRESH-SHELL-\(challenge):"
        try restored.bridge.sendAutomationText(
            id: child.paneID,
            text: "printf '\\n\(prefix)%s\\n' \"$$\"; "
                + "[ \"$PWD\" = \(nativeControlQuote(child.directory.path)) ] "
                + "&& printf '\\nFRESH-CWD-OK\\n'")
        try restored.bridge.sendAutomationKey(id: child.paneID, key: .enter)
        var shellText = ""
        try await nativeControlWait("restored shell expansion through PTY") {
            shellText = try restored.bridge.readRenderedText(
                id: child.paneID, maximumUTF8Bytes: TerminalControlProtocol.maximumSnapshotSize
            ).text
            return (try? nativeControlPID(in: shellText, prefix: prefix)) != nil
                && shellText.contains("\nFRESH-CWD-OK\n")
        }
        let freshPID = try nativeControlPID(in: shellText, prefix: prefix)
        #expect(freshPID != oldPID && Darwin.kill(freshPID, 0) == 0)
        #expect(!shellText.contains(output) && !shellText.contains(argument))
        #expect(!shell.processExitedForTesting)
        restored.shutdown()
        #expect(!shell.isReady && restored.bridge.activeSurfaceCount == 0)
        try await nativeControlWait("restored shell process reaped") {
            Darwin.kill(freshPID, 0) == -1 && errno == ESRCH
        }
        fixture.shutdown()
        #expect(!FileManager.default.fileExists(atPath: restored.directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test
    func terminationFreezeRevokesPendingWaitButRetainsLiveManagedProcess() async throws {
        let fixture = try NativeControlPTYFixture(startControlService: true)
        defer { fixture.shutdown() }
        try await fixture.show()
        let child = try await fixture.launch(
            script: #"""
                printf 'FREEZE-PID:%s\n' "$$"
                printf 'FREEZE-READY\n'
                gate
                IFS= read -r -t 15 reply || exit 83
                [ "$reply" = 'live-input-after-freeze' ] || exit 84
                printf 'ALIVE-AFTER-FREEZE:%s\n' "$$"
                gate
                exit 0
                """#, policy: .closeOnSuccess, splitDirection: .right)
        try child.release()
        let before = try await fixture.text("FREEZE-READY", from: child)
        let pid = try nativeControlPID(in: before.text, prefix: "FREEZE-PID:")
        let session = try fixture.session()
        let layout = fixture.coordinator.workspaceStoreForPersistence
        #expect(fixture.commits.latest == layout)
        #expect(fixture.commits.permissionSessions == [session])
        let environment = try #require(fixture.controller.environment(for: fixture.originPaneID))
        let token = try #require(environment["QUICKTTY_PANE_TOKEN"])
        let preflight = try TerminalControlPreflight(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            nonce: Data(repeating: 1, count: TerminalControlProtocol.nonceSize))
        #expect(fixture.controlRouter.credential(for: preflight) == token)
        let lifecyclePreflight = try AgentIPCPreflight(
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
            nonce: Data(repeating: 1, count: AgentIPCProtocol.nonceSize))
        #expect(fixture.lifecycleRouter.credential(for: lifecyclePreflight) == token)
        let binding = try #require(
            layout.workspaces.flatMap(\.tabs).flatMap(\.paneDescriptors)
                .first { $0.id == fixture.originPaneID }?.agentResumeBinding)
        let lifecycleMessage = AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: AgentIPCIdentity(
                        instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                        paneToken: token, adapterID: binding.adapterID.rawValue),
                    sessionID: binding.sessionID, cwd: binding.workingDirectory,
                    metadata: binding.launchMetadata)))
        let validatedLifecycle = try #require(fixture.controller.validate(lifecycleMessage))
        #expect(await fixture.lifecycleRouter.route(lifecycleMessage))
        let client = try TerminalControlSocketClient(
            socketPath: #require(environment["QUICKTTY_CONTROL_SOCKET"]),
            instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue, paneToken: token,
            nonceGenerator: {
                Data(UUID().uuidString.utf8.prefix(TerminalControlProtocol.nonceSize))
            },
            timeoutMilliseconds: 8_000)
        let replay = try TerminalControlRequest(
            operation: .focus(taskID: child.task.taskID), requestID: UUID())
        _ = try nativeControlTask(await Task.detached { try client.send(replay) }.value)
        let baseline = try await fixture.read(child)
        #expect(
            fixture.coordinator.terminalAutomationHost.inspectTask(
                taskID: child.task.taskID, expectedSession: session) == .owned(baseline.task))
        fixture.socketObserver.response = nil
        let waitRequest = try TerminalControlRequest(
            operation: .wait(
                taskID: child.task.taskID, revision: baseline.task.revision,
                timeoutMilliseconds: 5_000))
        let pending = Task.detached { try client.send(waitRequest) }
        defer { pending.cancel() }
        try await nativeControlWait("authenticated router/domain wait") {
            fixture.socketObserver.request == waitRequest
                && fixture.coordinator.hasPendingTerminalControlWaitForTesting(
                    taskID: child.task.taskID, session: session)
        }
        let socketContext = try #require(fixture.socketObserver.context)
        let routedContext = fixture.controlRouter.requestContext(socketContext)
        #expect(socketContext.isActive && routedContext.isActive)
        let codec = try StateStore(
            url: fixture.directory.appending(path: "final-state.json"),
            homeDirectoryURL: fixture.directory)
        var events: [String] = []
        var teardown: [@MainActor () -> Void] = []
        var didPersist = false
        let cancellationDeadline = ContinuousClock.now + .seconds(2)
        // WHY: This is the production ordering seam used by applicationWillTerminate and its
        // lifecycle tests. Freeze callbacks perform the same real operations as AppDelegate.
        // The seam is synchronous: ONLY its late stop/teardown hooks are deferred so the test
        // can observe async wait completion and NEW child output at the retained boundary.
        AppDelegate.performApplicationTermination(
            freezeTerminalControlDelivery: {
                events.append("control freeze")
                fixture.controlRouter.disable()
                fixture.coordinator.freezeTerminalControlForApplicationTermination()
            },
            freezeAgentLifecycleDelivery: {
                events.append("credential freeze")
                fixture.lifecycleRouter.disable()
                fixture.controller.freeze()
                fixture.actionRouter.disable()
            },
            persistFinalState: {
                events.append("persistence")
                #expect(!socketContext.isActive && !routedContext.isActive)
                #expect(fixture.controlRouter.credential(for: preflight) == nil)
                #expect(fixture.lifecycleRouter.credential(for: lifecyclePreflight) == nil)
                #expect(fixture.controller.credential(for: preflight) == nil)
                #expect(fixture.controller.credential(for: lifecyclePreflight) == nil)
                #expect(fixture.controller.validate(lifecycleMessage) == nil)
                #expect(!fixture.controller.handle(validatedLifecycle))
                #expect(
                    !fixture.actionRouter.route(
                        .register(
                            paneID: fixture.originPaneID, binding: binding)))
                #expect(fixture.controller.environment(for: fixture.originPaneID) == nil)
                #expect(fixture.controller.register(paneID: fixture.originPaneID) == nil)
                #expect(fixture.controller.rotate(paneID: fixture.originPaneID) == nil)
                #expect(
                    !fixture.coordinator.hasPendingTerminalControlWaitForTesting(
                        taskID: child.task.taskID, session: session))
                #expect(
                    fixture.coordinator.terminalAutomationHost.inspectTask(
                        taskID: child.task.taskID, expectedSession: session) == .notOwned)
                #expect(
                    fixture.coordinator.readManagedTask(
                        taskID: child.task.taskID, expectedSession: session)
                        == .failure(.staleSession))
                #expect(fixture.coordinator.workspaceStoreForPersistence == layout)
                #expect(fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface)
                #expect(child.surface.isReady && !child.surface.processExitedForTesting)
                #expect(Darwin.kill(pid, 0) == 0)
                codec.scheduleSave(
                    ApplicationState(
                        workspaceStore: fixture.coordinator.workspaceStoreForPersistence))
                try codec.flushPendingSave()
                didPersist = true
            },
            logSaveError: { Issue.record("Final persistence failed: \($0)") },
            stopAgentSocket: {
                // WHY: This fixture owns a control listener, not a lifecycle listener.
                events.append("stop lifecycle")
            },
            stopControlSocket: {
                events.append("defer stop control")
                teardown.append { fixture.controlServer?.stopImmediately() }
            },
            prepareForTermination: {
                events.append("defer prepare")
                teardown.append { fixture.coordinator.prepareForApplicationTermination() }
            },
            shutdownRuntime: {
                events.append("defer shutdown")
                teardown.append { fixture.bridge.shutdown() }
            })
        #expect(
            events == [
                "control freeze", "credential freeze", "persistence", "stop lifecycle",
                "defer stop control", "defer prepare", "defer shutdown",
            ])
        try #require(didPersist)
        try await nativeControlWait("revoked authenticated wait") {
            fixture.socketObserver.response != nil
        }
        nativeControlFailure(try #require(fixture.socketObserver.response), .cancelled)
        nativeControlFailure(try await pending.value, .cancelled)
        #expect(ContinuousClock.now < cancellationDeadline)
        nativeControlFailure(
            await fixture.controlRouter.route(
                TerminalControlSocketRequest(
                    instanceID: fixture.instanceID, paneID: fixture.originPaneID.rawValue,
                    request: replay), context: socketContext), .cancelled)
        nativeControlFailure(try await fixture.request(replay), .cancelled)
        nativeControlFailure(
            try await fixture.request(.read(taskID: child.task.taskID)), .cancelled)
        let rejectedCredential = await Task.detached { () -> TerminalControlSocketClientError? in
            do {
                _ = try client.send(replay)
                return nil
            } catch let error as TerminalControlSocketClientError { return error } catch {
                return .transportFailure
            }
        }.value
        #expect(rejectedCredential == .serverAuthenticationFailed)
        #expect(!(await fixture.lifecycleRouter.route(lifecycleMessage)))
        #expect(
            fixture.coordinator.managedTaskForTesting(taskID: child.task.taskID)?.owner == .user)
        #expect(!fixture.coordinator.returnControlToAgent(taskID: child.task.taskID))
        #expect(try codec.load().workspaceStore == layout)
        try child.release()
        // WHY: Kernel echo is off. Neither the pre-freeze marker nor a cached native view can
        // acknowledge this post-freeze PTY input with the same child PID.
        try fixture.bridge.sendAutomationText(id: child.paneID, text: "live-input-after-freeze")
        try fixture.bridge.sendAutomationKey(id: child.paneID, key: .enter)
        try await nativeControlWait("child alive after integrated freeze") {
            try fixture.bridge.readRenderedText(
                id: child.paneID, maximumUTF8Bytes: TerminalControlProtocol.maximumSnapshotSize
            ).text.contains("ALIVE-AFTER-FREEZE:\(pid)")
        }
        #expect(Darwin.kill(pid, 0) == 0)
        #expect(!child.surface.processExitedForTesting)
        #expect(fixture.coordinator.surfaceForTesting(id: child.paneID) === child.surface)
        #expect(fixture.coordinator.workspaceStoreForPersistence == layout)
        for action in teardown { action() }
        await fixture.controlServer?.stop()
        fixture.shutdown()
        try await nativeControlWait("terminated fixture process reaped") {
            Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
        #expect(!child.surface.isReady && fixture.bridge.activeSurfaceCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }
}

@MainActor
private final class NativeControlPTYFixture {
    static let credentialNames = [
        "QUICKTTY_PANE_ID", "QUICKTTY_AGENT_SOCKET", "QUICKTTY_INSTANCE_ID",
        "QUICKTTY_PANE_TOKEN", "QUICKTTY_AGENT_HELPER", "QUICKTTY_CONTROL_SOCKET",
        "QUICKTTY_LAUNCH_PAYLOAD",
    ]

    let directory: URL
    let bridge: GhosttyBridge
    let controller: AgentSessionController
    let coordinator: WindowCoordinator
    let originPaneID: PaneID
    let instanceID: UUID
    let commits: NativeControlCommitObserver
    let controlRouter: TerminalControlMessageRouter
    let lifecycleRouter: AgentMessageRouter
    let actionRouter: AgentLifecycleActionRouter
    let controlServer: TerminalControlSocketServer?
    let socketObserver: NativeControlSocketObserver
    private var children: [NativeControlPTYChild] = []
    private var eventTimestamp: TimeInterval = 1
    private var originalWindowLevel: NSWindow.Level?
    private var runtimeStopped = false
    private var stopped = false

    init(restoring state: ApplicationState? = nil, startControlService: Bool = false) throws {
        // WHY: /tmp resolves to /private/tmp; create exclusively and never borrow a user's HOME.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
            .appending(path: "qtty-pty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try nativeControlDirectory(root)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: root) } }
        directory = root
        let origin = root.appending(path: "origin", directoryHint: .isDirectory)
        try nativeControlDirectory(origin)
        let helper = ApplicationEnvironment.bundledAgentHelperURL(in: Bundle.main)
        var helperIsDirectory = ObjCBool(false)
        try #require(
            FileManager.default.fileExists(atPath: helper.path, isDirectory: &helperIsDirectory)
                && !helperIsDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: helper.path),
            "The debug test host must bundle its executable Contents/Helpers/quicktty")
        let config = root.appending(path: "config")
        // WHY: Restore drops per-surface commands. Its owned config must select a real shell
        // without login/profile/rc/history reads, rather than borrowing the user's default shell.
        let defaultCommand: String
        if state != nil {
            try #require(FileManager.default.isExecutableFile(atPath: "/bin/bash"))
            let shellLauncher = root.appending(path: "restored-shell")
            try Data("#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n".utf8).write(
                to: shellLauncher)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: shellLauncher.path)
            defaultCommand = shellLauncher.path
        } else {
            defaultCommand = "/bin/cat"
        }
        try Data("command = \(defaultCommand)\nabnormal-command-exit-runtime = 0\n".utf8).write(
            to: config)
        let runtime = try GhosttyBridge(
            configURL: config,
            clipboardClient: GhosttyClipboardClient(read: { _ in nil }, write: { _, _ in }))
        defer { if !initialized { runtime.shutdown() } }
        bridge = runtime
        try #require(runtime.diagnostics.isEmpty)
        instanceID = UUID()
        let initialStore: WorkspaceStore
        if let state {
            initialStore = state.workspaceStore
            originPaneID = try #require(
                initialStore.workspaces.flatMap(\.tabs).flatMap(\.paneDescriptors)
                    .first { $0.agentResumeBinding != nil }?.id)
        } else {
            originPaneID = PaneID()
            // WHY: The integrated service also validates real lifecycle messages against the
            // registry; retain the original domain-only fixture identity for the other PTY tests.
            let binding = try AgentResumeBinding(
                adapterID: AgentAdapterID(rawValue: startControlService ? "claude" : "claude-code"),
                sessionID: "synthetic-pty-origin", workingDirectory: origin.path,
                registeredAt: Date(timeIntervalSince1970: 1_000),
                launchMetadata: startControlService ? [:] : ["source": "test"],
                restoreState: .active)
            let tab = TerminalTab(
                title: "PTY test origin",
                pane: TerminalPaneDescriptor(
                    id: originPaneID, cwd: origin.path, startupCommand: .custom("exec /bin/cat"),
                    agentResumeBinding: binding))
            let workspace = Workspace(name: "PTY tests", tabs: [tab], activeTabID: tab.id)
            initialStore = try WorkspaceStore(
                workspaces: [workspace], activeWorkspaceID: workspace.id)
        }
        let router = TerminalControlMessageRouter()
        controlRouter = router
        let observer = NativeControlSocketObserver()
        socketObserver = observer
        let actions = AgentLifecycleActionRouter()
        actionRouter = actions
        let lifecycle = AgentMessageRouter()
        lifecycleRouter = lifecycle
        let server: TerminalControlSocketServer?
        if startControlService {
            server = TerminalControlSocketServer(
                temporaryBaseDirectory: "/private/tmp", credentialProvider: router.credential
            ) { request, context in
                await observer.route(request, context: context, router: router)
            }
        } else {
            server = nil
        }
        controlServer = server
        defer { if !initialized { server?.stopImmediately() } }
        let controlPath = try server?.start() ?? root.appending(path: "control.sock").path
        let tokenByte: UInt8 = state == nil ? 0xAB : 0xCD
        controller = try AgentSessionController(
            socketPath: root.appending(path: "agent.sock").path, helperPath: helper.path,
            controlSocketPath: controlPath, instanceID: instanceID,
            tokenGenerator: { Array(repeating: tokenByte, count: 32) }, onAction: actions.route)
        lifecycle.install(controller)
        let commitObserver = NativeControlCommitObserver()
        commits = commitObserver
        // WHY: These overrides reach EVERY surface before any outer shell/helper starts,
        // including state == nil. --noprofile/--norc alone do not suppress BASH_ENV or readline.
        // Never read inherited hook values or change HOME; credentials still traverse the real
        // managed-launch sanitizer and are checked in the actual child, without output filtering.
        let shellEnvironment = [
            "ENV": "/dev/null", "BASH_ENV": "/dev/null", "INPUTRC": "/dev/null",
            "HISTFILE": "/dev/null", "PROMPT_COMMAND": "",
            "PS1": "quicktty-test> ", "PS2": "> ", "PS4": "+ ",
        ]
        let windowCoordinator = WindowCoordinator(
            ghosttyBridge: runtime,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: origin.path, command: "exec /bin/cat",
                environment: Dictionary(
                    uniqueKeysWithValues: Self.credentialNames.map { ($0, "synthetic-origin-only") }
                ).merging(shellEnvironment) { _, value in value }),
            executableSearchPath: "/usr/bin:/bin:/usr/sbin:/sbin",
            agentSessionController: controller,
            initialWorkspaceStore: initialStore,
            agentRestoreHomeDirectory: { origin.path },
            terminalAutomationPermissionPresenter: { session in
                commitObserver.permissionSessions.append(session.identity)
                return .allowed
            },
            persistWorkspaceStore: { commitObserver.record($0) })
        coordinator = windowCoordinator
        defer { if !initialized { windowCoordinator.prepareForBridgeShutdownForTesting() } }
        actions.install(windowCoordinator)
        router.install(controller, coordinator: windowCoordinator)
        if state != nil {
            var configuration = QuickTTYConfig()
            configuration.restoreAgentSessions = false
            windowCoordinator.applyConfiguration(configuration)
        }
        try windowCoordinator.start()
        try #require(windowCoordinator.surfaceForTesting(id: originPaneID)?.isReady == true)
        initialized = true
    }

    func show() async throws {
        let window = try #require(coordinator.activeWindowForTesting)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        window.setContentSize(NSSize(width: 1000, height: 650))
        let size = NSSize(
            width: min(window.frame.width, visibleFrame.width),
            height: min(window.frame.height, visibleFrame.height))
        window.setFrame(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height),
            display: false)
        // WHY: A separately running QuickTTY Quake window can cover the test host at floating
        // level. Elevate only this fixture-owned window so test isolation never requires changing
        // the user's application; polling still observes real visibility and renderer draws.
        if originalWindowLevel == nil { originalWindowLevel = window.level }
        window.level = .statusBar
        NSApplication.shared.unhideWithoutActivation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try await nativeControlWait(
            "owned visible window", diagnostics: { self.windowDiagnostics(window) },
            {
                self.layout()
                return window.isVisible && window.occlusionState.contains(.visible)
            })
        // WHY: Restore can select a different pane; readiness must describe the mounted surface.
        try await waitForGrid(try #require(coordinator.activeSurfaceForTesting))
    }

    private func windowDiagnostics(_ window: NSWindow?) -> String {
        "visible=\(window?.isVisible == true) "
            + "occlusion=\(String(describing: window?.occlusionState)) "
            + "active=\(NSApplication.shared.isActive) hidden=\(NSApplication.shared.isHidden) "
            + "key=\(window?.isKeyWindow == true) miniaturized=\(window?.isMiniaturized == true) "
            + "frame=\(String(describing: window?.frame)) "
            + "activeSpace=\(String(describing: window?.isOnActiveSpace)) "
            + "screen=\(String(describing: window?.screen?.visibleFrame))"
    }

    func layout() {
        coordinator.activeWindowForTesting?.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceViewControllerForTesting.view.layoutSubtreeIfNeeded()
        coordinator.activeWindowForTesting?.displayIfNeeded()
    }

    func session() throws -> TerminalAutomationSessionIdentity {
        try #require(
            coordinator.terminalAutomationHost.resolveAuthenticatedSession(
                instanceID: instanceID, originPaneID: originPaneID)
        ).identity
    }

    func request(_ operation: TerminalControlRequest.Operation) async throws
        -> TerminalControlResponse
    {
        let requestID: UUID?
        switch operation {
        case .list, .read, .wait: requestID = nil
        default: requestID = UUID()
        }
        return try await request(TerminalControlRequest(operation: operation, requestID: requestID))
    }

    func request(_ request: TerminalControlRequest) async throws -> TerminalControlResponse {
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        return await coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: instanceID, paneID: originPaneID.rawValue, request: request),
            context: TerminalControlRequestContext { ContinuousClock().now < deadline })
    }

    func launch(
        script: String, arguments: [String] = [], policy: TerminalTaskLifecyclePolicy = .keep,
        splitDirection: TerminalSplitDirection? = nil, executable: String = "/bin/sh",
        requiresDescendantExit: Bool = false
    ) async throws -> NativeControlPTYChild {
        let resources = try NativeControlPTYResources(parent: directory)
        var transferred = false
        defer { if !transferred { resources.close() } }
        // WHY: macOS /bin/sh's read uses only ancillary fd 3 for the gate. Managed 0/1/2
        // remain the original Ghostty PTY; no Process/Pipe or nested PTY replaces them.
        let program = #"""
            exec 3<> \#(nativeControlQuote(resources.fifo.path))
            gate() { IFS= read -r -u 3 -t 15 token || exit 90; }
            gate
            /bin/stty sane -echo || exit 91
            printf '\033[2J\033[3J\033[H'
            \#(script)
            """#
        let launch = try TerminalControlLaunch(
            executable: executable, arguments: ["-c", program, "quicktty-pty"] + arguments,
            cwd: resources.directory.path)
        let operation: TerminalControlRequest.Operation
        if let splitDirection {
            operation = .split(
                anchorPaneID: nil, direction: splitDirection, ratio: 0.5, launch: launch,
                policy: policy, focus: true)
        } else {
            operation = .createTab(launch: launch, policy: policy, focus: true)
        }
        let task = try nativeControlTask(await request(operation))
        let surface = try #require(coordinator.surfaceForTesting(id: PaneID(rawValue: task.paneID)))
        let child = NativeControlPTYChild(task: task, surface: surface, resources: resources)
        // WHY: Register before the first throwing grid wait, while the initial FIFO still gates spawn.
        resources.descendantExitPending = requiresDescendantExit
        children.append(child)
        transferred = true
        try await waitForGrid(surface)
        return child
    }

    func waitForGrid(_ surface: GhosttySurfaceView) async throws {
        // WHY: Managed tab/split/reparent/show paths may reorder this fixture-owned window.
        let window = try #require(coordinator.activeWindowForTesting)
        window.orderFrontRegardless()
        try await nativeControlWait(
            "mounted child grid",
            diagnostics: {
                self.windowDiagnostics(self.coordinator.activeWindowForTesting)
                    + " mounted=\(surface.window === self.coordinator.activeWindowForTesting) "
                    + "ready=\(surface.isReady) "
                    + "grid=\(String(describing: surface.sizeSnapshotForTesting)) "
                    + "scrollbar=\(String(describing: surface.scrollbarStateForTesting))"
            },
            {
                self.layout()
                guard let window = self.coordinator.activeWindowForTesting,
                    surface.window === window, surface.isReady,
                    window.isVisible, window.occlusionState.contains(.visible),
                    let size = surface.sizeSnapshotForTesting,
                    size.rows > 0, size.columns >= 20,
                    let scrollbar = surface.scrollbarStateForTesting
                else { return false }
                // WHY: Login output may already exist. Do not filter it or claim an empty initial screen.
                return scrollbar.total >= UInt64(size.rows) && scrollbar.len == UInt64(size.rows)
            })
    }

    func read(_ child: NativeControlPTYChild) async throws -> TerminalControlSnapshot {
        let response = try await request(.read(taskID: child.task.taskID))
        guard case .snapshot(let snapshot) = response.result else {
            throw NativeControlPTYError.response(response)
        }
        return snapshot
    }

    func text(
        _ marker: String, from child: NativeControlPTYChild,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> TerminalControlSnapshot {
        let clock = ContinuousClock()
        let deadline = deadline ?? clock.now.advanced(by: .seconds(8))
        while true {
            let snapshot = try await read(child)
            if snapshot.text.contains(marker), clock.now < deadline { return snapshot }
            try Task.checkCancellation()
            guard snapshot.task.owner != .finished, clock.now < deadline else {
                throw NativeControlPTYError.timeout("rendered marker: \(marker)")
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(25))))
        }
    }

    func completed(_ child: NativeControlPTYChild) async throws -> TerminalControlSnapshot {
        try await nativeControlWait("real process completion and final capture") {
            self.coordinator.managedTaskForTesting(taskID: child.task.taskID)?.owner == .finished
                && self.coordinator.managedCompletionTaskForTesting(taskID: child.task.taskID)
                    == nil
        }
        // WHY: Never wait for the desired final marker or retry a bad tail into a passing test.
        return try await read(child)
    }

    func sendText(_ text: String, to child: NativeControlPTYChild) async throws {
        let current = try await read(child)
        try nativeControlAcknowledged(
            await request(
                .sendText(
                    taskID: child.task.taskID, expectedRevision: current.task.revision,
                    text: text)))
    }

    func sendKey(_ key: TerminalControlKey, to child: NativeControlPTYChild) async throws {
        let current = try await read(child)
        try nativeControlAcknowledged(
            await request(
                .sendKey(
                    taskID: child.task.taskID, expectedRevision: current.task.revision, key: key)))
    }

    func manualKey(_ text: String, keyCode: UInt16, on child: NativeControlPTYChild) throws {
        eventTimestamp += 1
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: eventTimestamp,
                windowNumber: child.surface.window?.windowNumber ?? 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                keyCode: keyCode))
        child.surface.keyDown(with: event)
    }

    func stopDescendants() async throws {
        // WHY: An unstructured task does not inherit caller cancellation. Await it, never fire-and-forget.
        try await Task { @MainActor in
            var failure: Error?
            for child in self.children where child.resources.descendantExitPending {
                do { try await self.stopDescendant(child) } catch {
                    if failure == nil { failure = error }
                }
            }
            if let failure { throw failure }
        }.value
    }

    private func stopDescendant(_ child: NativeControlPTYChild) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var releaseFailure: Error?
        do {
            try Data().write(to: child.directory.appending(path: "descendant-stop"))
        } catch { releaseFailure = error }
        // WHY: Release both an unreleased initial gate and an already orphaned quiet reader.
        // Attempt this even if writing the stop marker failed; PTY closure also stops the writer.
        do { try child.release() } catch {
            if releaseFailure == nil { releaseFailure = error }
        }
        var pid: Int32?
        while true {
            if FileManager.default.fileExists(
                atPath: child.directory.appending(path: "descendant-not-started").path)
            {
                // WHY: Cleanup reached the initial gate first; this branch cannot spawn a descendant.
                break
            }
            if pid == nil,
                FileManager.default.fileExists(
                    atPath: child.directory.appending(path: "descendant-pid-ready").path)
            {
                // WHY: The parent publishes $!, then a separate barrier after the PID write finishes.
                // Never use $$ in a subshell, infer a PID, or send signals to a potentially reused PID.
                pid = try nativeControlPID(
                    in: String(
                        contentsOf: child.directory.appending(path: "descendant-pid"),
                        encoding: .utf8), prefix: "DESCENDANT:")
                bridge.closeSurface(id: child.paneID)
            }
            if let pid, Darwin.kill(pid, 0) == -1, errno == ESRCH { break }
            guard clock.now < deadline else {
                throw NativeControlPTYError.timeout(
                    "owned descendant exit before directory cleanup")
            }
            // WHY: Poll actual process disappearance asynchronously, not a fixed sleep as a barrier.
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
        }
        child.resources.descendantExitPending = false
        if let releaseFailure { throw releaseFailure }
    }

    func stopRuntime() {
        guard !runtimeStopped else { return }
        runtimeStopped = true
        controlRouter.disable()
        lifecycleRouter.disable()
        actionRouter.disable()
        controlServer?.stopImmediately()
        commits.onCommit = nil
        if let window = coordinator.activeWindowForTesting {
            if let originalWindowLevel { window.level = originalWindowLevel }
            window.orderOut(nil)
        }
        coordinator.prepareForBridgeShutdownForTesting()
        // WHY: Freeze is not process teardown. Free every owned native PTY, including blocked
        // readers and partial creations, before closing gates/removing their working directories.
        for pane in bridge.activeSurfaceIDs { bridge.closeSurface(id: pane) }
        bridge.setTerminalAutomationClientForTesting(.live)
        bridge.shutdown()
        controller.freeze()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        stopRuntime()
        for child in children { child.resources.close() }
        // WHY: A cleanup timeout is a test failure, never permission to remove a live child's stop file.
        guard !children.contains(where: { $0.resources.descendantExitPending }) else {
            Issue.record(
                "Unconfirmed descendant exit; retained owned PTY fixture directory: \(directory.path)"
            )
            return
        }
        children.removeAll()
        do { try FileManager.default.removeItem(at: directory) } catch {
            Issue.record("Could not remove owned PTY fixture directory: \(error)")
        }
    }
}

@MainActor
private struct NativeControlPTYChild {
    let task: TerminalControlTask
    let surface: GhosttySurfaceView
    let resources: NativeControlPTYResources
    var paneID: PaneID { PaneID(rawValue: task.paneID) }
    var directory: URL { resources.directory }
    func release(_ token: String = "G") throws { try resources.release(token) }
}

@MainActor
private final class NativeControlPTYResources {
    let directory: URL
    let fifo: URL
    var descendantExitPending = false
    private var descriptor: Int32 = -1

    init(parent: URL) throws {
        directory = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try nativeControlDirectory(directory)
        fifo = directory.appending(path: "gate")
        let result = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        guard result == 0 else { throw NativeControlPTYError.posix(errno) }
        descriptor = fifo.path.withCString { Darwin.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NativeControlPTYError.posix(errno) }
    }

    func release(_ token: String) throws {
        let bytes = Array((token + "\n").utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw NativeControlPTYError.posix(errno) }
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

@MainActor
private final class NativeControlCommitObserver {
    private(set) var latest: WorkspaceStore?
    var permissionSessions: [TerminalAutomationSessionIdentity] = []
    var onCommit: (() -> Void)?

    func record(_ store: WorkspaceStore) {
        latest = store
        onCommit?()
    }
}

@MainActor
private final class NativeControlSocketObserver {
    var request: TerminalControlRequest?
    var context: TerminalControlSocketRequestContext?
    var response: TerminalControlResponse?

    func route(
        _ envelope: TerminalControlSocketRequest, context: TerminalControlSocketRequestContext,
        router: TerminalControlMessageRouter
    ) async -> TerminalControlResponse {
        request = envelope.request
        self.context = context
        let result = await router.route(envelope, context: context)
        response = result
        return result
    }
}

@MainActor
private final class NativeControlReadObserver {
    let surface: GhosttySurfaceView
    let bridge: GhosttyBridge
    var finalReadOutputStates: [GhosttyOutputState] = []
    var finalBytes: Data?
    var staleScrollbarBeforeRead = false
    var finalReadBeforeClose = false
    var finalReadAttempts = 0
    var readCount = 0
    var freeCount = 0

    init(surface: GhosttySurfaceView, bridge: GhosttyBridge) {
        self.surface = surface
        self.bridge = bridge
    }

    var client: GhosttyTerminalAutomationClient {
        GhosttyTerminalAutomationClient(
            readText: { [self] _, liveRead in
                readCount += 1
                if staleScrollbarBeforeRead {
                    #expect(
                        surface.scheduleScrollbarCallbackForTesting(total: 1, offset: 0, len: 1))
                }
                let isFinalRead = surface.processExitedForTesting
                if isFinalRead {
                    // WHY: Sample the live typed EOF accessor BEFORE reading terminal memory;
                    // a later closed surface returning .failed cannot establish the EOF gate.
                    finalReadOutputStates.append(bridge.outputState(id: surface.paneID))
                }
                // WHY: Observe the real native buffer without altering bytes or ownership.
                let result = liveRead()
                if isFinalRead {
                    finalReadAttempts += 1
                    if finalReadAttempts == 1, case .success(let buffer) = result {
                        finalReadBeforeClose = surface.isReady
                        finalBytes = buffer.bytes
                    }
                }
                return result
            },
            freeText: { [self] buffer in
                buffer.release()
                freeCount += 1
            })
    }
}

private enum NativeControlPTYError: Error {
    case timeout(String)
    case posix(Int32)
    case response(TerminalControlResponse)
}

@MainActor
private func nativeControlWait(
    _ phase: String, diagnostics: () -> String = { "" }, _ condition: () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while try !condition() {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw NativeControlPTYError.timeout(phase + " " + diagnostics())
        }
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
    }
}

private func nativeControlTask(_ response: TerminalControlResponse) throws -> TerminalControlTask {
    guard case .task(let task) = response.result else {
        throw NativeControlPTYError.response(response)
    }
    return task
}

private func nativeControlAcknowledged(_ response: TerminalControlResponse) throws {
    guard case .acknowledged = response.result else {
        throw NativeControlPTYError.response(response)
    }
}

private func nativeControlFailure(
    _ response: TerminalControlResponse, _ code: TerminalControlErrorCode
) {
    guard case .failure(let error) = response.result else {
        Issue.record("Expected terminal-control failure")
        return
    }
    #expect(error.code == code)
}

private func nativeControlSize(in snapshot: TerminalControlSnapshot, prefix: String) throws -> [Int]
{
    let line = try #require(
        snapshot.text.split(separator: "\n").first { $0.hasPrefix(prefix + " ") })
    let values = line.dropFirst(prefix.count)
        .split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
    try #require(values.count == 2 && values.allSatisfy { $0 > 0 })
    return values
}

private func nativeControlDirectory(_ directory: URL) throws {
    // WHY: EEXIST must fail; cleanup may remove only a directory this invocation created.
    let result = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
    guard result == 0 else { throw NativeControlPTYError.posix(errno) }
    var verified = false
    defer { if !verified { try? FileManager.default.removeItem(at: directory) } }
    try #require(directory.path == directory.resolvingSymlinksInPath().path)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    try #require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    verified = true
}

private func nativeControlPID(in text: String, prefix: String) throws -> Int32 {
    for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
        if let pid = Int32(
            line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 1
        {
            return pid
        }
    }
    throw NativeControlPTYError.timeout("child PID: \(prefix)")
}

private func nativeControlQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
