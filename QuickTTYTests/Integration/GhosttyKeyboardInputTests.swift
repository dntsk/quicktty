import AppKit
import Darwin
import Foundation
import Testing

@testable import QuickTTY

extension GhosttyBridgeTests {
    @Test
    func responderRoutesOriginalEventSynchronouslyToSourceSurfaceOnly() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let sourceID = PaneID()
        let otherID = PaneID()
        let source = try bridge.makeSurface(
            id: sourceID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            id: otherID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )

        source.keyDown(with: event)

        let route = try #require(bridge.inputObservationsForTesting.last)
        let processed = try #require(source.inputObservationsForTesting.last)
        #expect(route.paneID == sourceID)
        #expect(route.eventIdentifier == ObjectIdentifier(event))
        #expect(route.wasProcessed)
        #expect(processed.eventIdentifier == ObjectIdentifier(event))
        #expect(processed.translationEventIdentifier == ObjectIdentifier(event))
        #expect(processed.action == .press)
        #expect(other.inputObservationsForTesting.isEmpty)

        bridge.closeSurface(id: sourceID)
        let ignoredEvent = try makeKeyboardEvent(
            type: .keyDown,
            characters: "b",
            charactersIgnoringModifiers: "b",
            keyCode: 11
        )
        let sourceObservationCount = source.inputObservationsForTesting.count

        source.keyDown(with: ignoredEvent)

        let ignoredRoute = try #require(bridge.inputObservationsForTesting.last)
        #expect(ignoredRoute.paneID == sourceID)
        #expect(ignoredRoute.eventIdentifier == ObjectIdentifier(ignoredEvent))
        #expect(!ignoredRoute.wasProcessed)
        #expect(source.inputObservationsForTesting.count == sourceObservationCount)
    }

    @Test
    func installedMonitorRoutesCommandKeyUpOnlyToFocusedSource() throws {
        let initialMonitorCount = GhosttySurfaceView.focusMonitorCountForTesting
        let bridge = try GhosttyBridge(applicationIsActive: { true })
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        other.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(source)
        let commandKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            windowNumber: window.windowNumber
        )

        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount + 2)
        NSApp.sendEvent(commandKeyUp)

        let route = try #require(bridge.inputObservationsForTesting.last)
        let input = try #require(source.inputObservationsForTesting.last)
        #expect(bridge.inputObservationsForTesting.count == 1)
        #expect(route.paneID == source.paneID)
        #expect(route.eventIdentifier == ObjectIdentifier(commandKeyUp))
        #expect(source.inputObservationsForTesting.count == 1)
        #expect(input.eventIdentifier == ObjectIdentifier(commandKeyUp))
        #expect(input.action == .release)
        #expect(other.inputObservationsForTesting.isEmpty)

        let nonCommandKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            timestamp: 2,
            windowNumber: window.windowNumber
        )
        #expect(source.processLocalEventForTesting(nonCommandKeyUp) === nonCommandKeyUp)
        #expect(other.processLocalEventForTesting(nonCommandKeyUp) === nonCommandKeyUp)

        #expect(bridge.inputObservationsForTesting.count == 1)
        #expect(source.inputObservationsForTesting.count == 1)
        #expect(other.inputObservationsForTesting.isEmpty)

        let otherWindow = makeKeyboardTestWindow()
        let otherWindowKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            timestamp: 3,
            windowNumber: otherWindow.windowNumber
        )
        #expect(source.processLocalEventForTesting(otherWindowKeyUp) === otherWindowKeyUp)
    }

    @Test
    func surfaceInputRouteDoesNotRetainBridge() throws {
        weak var weakBridge: GhosttyBridge?
        var retainedSurface: GhosttySurfaceView?
        var bridge: GhosttyBridge? = try GhosttyBridge()
        weakBridge = bridge
        retainedSurface = try bridge?.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        bridge = nil

        #expect(weakBridge == nil)
        #expect(retainedSurface?.isReady == false)
        retainedSurface = nil
    }

    @Test
    func shortcutEventMatcherCoversEveryKeyAndIgnoresOnlyNonConfigurableFlags() throws {
        let ignoredFlags: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad, .help]
        let configurableFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let expectedModifiers = Set(ShortcutModifier.allCases)

        for key in ShortcutKey.allCases {
            let canonical = ShortcutController.keyEquivalent(for: key)
            let characters =
                key.rawValue.count == 1 && key.rawValue.first?.isLetter == true
                ? canonical.uppercased() : canonical

            #expect(
                ShortcutEventMatcher.chord(
                    modifierFlags: configurableFlags.union(ignoredFlags),
                    charactersIgnoringModifiers: characters,
                    unmodifiedCharacters: characters
                ) == ShortcutChord(key: key, modifiers: expectedModifiers),
                "Failed to match \(key.rawValue)"
            )
        }

        let aliases: [(String, ShortcutKey)] = [
            ("\u{3}", .enter),
            ("\u{19}", .tab),
            ("\u{7F}", .delete),
        ]
        for alias in aliases {
            #expect(
                ShortcutEventMatcher.chord(
                    modifierFlags: [],
                    charactersIgnoringModifiers: alias.0,
                    unmodifiedCharacters: alias.0
                ) == ShortcutChord(key: alias.1)
            )
        }
    }

    @Test
    func logicalUnmodifiedOutputWinsOverShiftedSymbolFallback() {
        let modifiers: NSEvent.ModifierFlags = [.command, .shift]

        #expect(
            ShortcutEventMatcher.chord(
                modifierFlags: modifiers,
                charactersIgnoringModifiers: "\"",
                unmodifiedCharacters: "2"
            ) == ShortcutChord(key: .two, modifiers: [.command, .shift])
        )
        #expect(
            ShortcutEventMatcher.chord(
                modifierFlags: modifiers,
                charactersIgnoringModifiers: "@",
                unmodifiedCharacters: "'"
            ) == ShortcutChord(key: .quote, modifiers: [.command, .shift])
        )
        #expect(
            ShortcutEventMatcher.chord(
                modifierFlags: modifiers,
                charactersIgnoringModifiers: "@",
                unmodifiedCharacters: "ж"
            ) == nil
        )
    }

    @Test
    func shiftedPrintableSymbolsMatchCanonicalUnshiftedKeysWithoutKeyCodes() throws {
        let shiftedKeys: [(String, ShortcutKey)] = [
            ("!", .one), ("@", .two), ("#", .three), ("$", .four), ("%", .five),
            ("^", .six), ("&", .seven), ("*", .eight), ("(", .nine), (")", .zero),
            ("~", .grave), ("_", .minus), ("+", .equal), ("{", .leftBracket),
            ("}", .rightBracket), ("|", .backslash), (":", .semicolon), ("\"", .quote),
            ("<", .comma), (">", .period), ("?", .slash),
        ]

        for shiftedKey in shiftedKeys {
            #expect(
                ShortcutEventMatcher.chord(
                    modifierFlags: [.command, .option, .shift],
                    charactersIgnoringModifiers: shiftedKey.0,
                    unmodifiedCharacters: nil
                )
                    == ShortcutChord(
                        key: shiftedKey.1,
                        modifiers: [.command, .option, .shift]
                    ),
                "Failed to match shifted output \(shiftedKey.0)"
            )
        }
    }

    @Test
    func resolvedShortcutOwnersDispatchDynamicallyWithoutRecreatingSurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let surfaceIdentity = ObjectIdentifier(surface)
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let defaultClear = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "k",
            charactersIgnoringModifiers: "k",
            keyCode: 40,
            timestamp: 301
        )
        let defaultNewTab = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .capsLock],
            characters: "T",
            charactersIgnoringModifiers: "T",
            keyCode: 17,
            timestamp: 302
        )

        #expect(surface.performKeyEquivalent(with: defaultClear))
        #expect(surface.terminalActionObservationsForTesting.last?.action == .clearScreen)
        #expect(!surface.performKeyEquivalent(with: defaultNewTab))

        var custom = ShortcutConfiguration.defaults
        custom.assign(
            ShortcutChord(key: .x, modifiers: [.command]),
            to: .clearScreen
        )
        custom.assign(
            ShortcutChord(key: .y, modifiers: [.command]),
            to: .newTab
        )
        bridge.applyShortcutConfiguration(custom)
        let customClear = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .function, .numericPad, .help],
            characters: "x",
            charactersIgnoringModifiers: "x",
            keyCode: 7,
            timestamp: 303
        )
        let customNewTab = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "y",
            charactersIgnoringModifiers: "y",
            keyCode: 16,
            timestamp: 304
        )
        let observationCount = surface.terminalActionObservationsForTesting.count

        #expect(!surface.performKeyEquivalent(with: defaultClear))
        #expect(surface.terminalActionObservationsForTesting.count == observationCount)
        #expect(surface.performKeyEquivalent(with: customClear))
        #expect(surface.terminalActionObservationsForTesting.last?.action == .clearScreen)
        #expect(!surface.performKeyEquivalent(with: customNewTab))
        #expect(ObjectIdentifier(surface) == surfaceIdentity)

        custom.disable(.clearScreen)
        bridge.applyShortcutConfiguration(custom)
        let disabledClear = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "x",
            charactersIgnoringModifiers: "x",
            keyCode: 7,
            timestamp: 305
        )
        let disabledObservationCount = surface.terminalActionObservationsForTesting.count
        #expect(!surface.performKeyEquivalent(with: disabledClear))
        #expect(surface.terminalActionObservationsForTesting.count == disabledObservationCount)
    }

    @Test
    func performableFalseFallsThroughWhileConsumePolicyConsumesFalse() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let copy = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            timestamp: 401
        )

        #expect(!surface.performKeyEquivalent(with: copy))
        #expect(
            surface.terminalActionObservationsForTesting.last
                == GhosttySurfaceTerminalActionObservation(action: .copy, result: false)
        )
        let inputCount = surface.inputObservationsForTesting.count
        surface.keyDown(with: copy)
        #expect(surface.inputObservationsForTesting.count == inputCount + 1)
        #expect(ShortcutPerformPolicy.consume.consumes(performed: false))
        #expect(!ShortcutPerformPolicy.passThroughWhenUnperformed.consumes(performed: false))

        bridge.setTerminalActionResultForTesting(false, for: .selectAll)
        let selectAll = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0,
            timestamp: 402
        )
        let terminalActionCount = surface.terminalActionObservationsForTesting.count
        #expect(surface.performKeyEquivalent(with: selectAll))
        #expect(surface.terminalActionObservationsForTesting.count == terminalActionCount + 1)
        #expect(surface.terminalActionObservationsForTesting.last?.action == .selectAll)
    }

    @Test
    func ordinaryControlInputAndSafeControlEquivalentsKeepTerminalRoute() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let events = try [
            makeKeyboardEvent(
                type: .keyDown,
                modifierFlags: [.control],
                characters: "\u{3}",
                charactersIgnoringModifiers: "c",
                keyCode: 8,
                timestamp: 501
            ),
            makeKeyboardEvent(
                type: .keyDown,
                modifierFlags: [.control],
                characters: "\u{1A}",
                charactersIgnoringModifiers: "z",
                keyCode: 6,
                timestamp: 502
            ),
        ]

        for event in events {
            #expect(!surface.performKeyEquivalent(with: event))
            let count = surface.inputObservationsForTesting.count
            surface.keyDown(with: event)
            #expect(surface.inputObservationsForTesting.count == count + 1)
            #expect(surface.inputObservationsForTesting.last?.modifiers == [.control])
        }
        #expect(surface.terminalActionObservationsForTesting.isEmpty)

        let controlReturn = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: 36,
            timestamp: 503
        )
        let controlSlash = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "\u{1F}",
            charactersIgnoringModifiers: "/",
            keyCode: 44,
            timestamp: 504
        )
        #expect(surface.performKeyEquivalent(with: controlReturn))
        #expect(surface.performKeyEquivalent(with: controlSlash))
        #expect(surface.inputObservationsForTesting.last?.text == "_")
    }

    @Test
    func terminalResponderActionsIgnoreClosedOrDetachedSource() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        surface.copy(nil)
        #expect(surface.terminalActionObservationsForTesting.isEmpty)

        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        surface.copy(nil)
        surface.paste(nil)
        surface.pasteSelection(nil)
        surface.selectAll(nil)
        #expect(
            surface.terminalActionObservationsForTesting.map(\.action) == [
                .copy, .paste, .pasteSelection, .selectAll,
            ]
        )

        bridge.closeSurface(id: surface.paneID)
        surface.copy(nil)
        #expect(surface.terminalActionObservationsForTesting.count == 4)
    }

    @Test
    func nonPasteTerminalShortcutsExecuteOnlyOnFocusedSource() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        bridge.inputTargetProvider = { _ in [source.paneID, other.paneID] }
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        other.frame = source.frame
        window.contentView?.addSubview(other)
        let events = try [
            makeKeyboardEvent(
                type: .keyDown,
                modifierFlags: [.command],
                characters: "c",
                charactersIgnoringModifiers: "c",
                keyCode: 8,
                timestamp: 601
            ),
            makeKeyboardEvent(
                type: .keyDown,
                modifierFlags: [.command],
                characters: "=",
                charactersIgnoringModifiers: "=",
                keyCode: 24,
                timestamp: 602
            ),
            makeKeyboardEvent(
                type: .keyDown,
                modifierFlags: [.command],
                characters: ShortcutController.keyEquivalent(for: .home),
                charactersIgnoringModifiers: ShortcutController.keyEquivalent(for: .home),
                keyCode: 115,
                timestamp: 603
            ),
        ]

        for event in events {
            _ = source.performKeyEquivalent(with: event)
        }

        #expect(
            source.terminalActionObservationsForTesting.map(\.action) == [
                .copy, .fontIncrease, .scrollTop,
            ]
        )
        #expect(other.terminalActionObservationsForTesting.isEmpty)
    }

    @Test
    func keyEquivalentRedispatchesMatchingTimestampWithoutStealingOtherShortcuts() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let redispatchedControlG = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "g",
            charactersIgnoringModifiers: "g",
            keyCode: 5,
            timestamp: 21
        )
        let unrelatedShortcut = try makeKeyboardEvent(
            type: .keyDown,
            characters: "x",
            charactersIgnoringModifiers: "x",
            keyCode: 7,
            timestamp: 22
        )

        let initialRouteCount = bridge.inputObservationsForTesting.count
        #expect(!surface.performKeyEquivalent(with: redispatchedControlG))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)

        #expect(surface.performKeyEquivalent(with: redispatchedControlG))
        let redispatchedRoute = try #require(bridge.inputObservationsForTesting.last)
        #expect(redispatchedRoute.eventIdentifier == ObjectIdentifier(redispatchedControlG))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)

        #expect(!surface.performKeyEquivalent(with: unrelatedShortcut))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)

        window.makeFirstResponder(nil)
        #expect(!surface.performKeyEquivalent(with: redispatchedControlG))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)
    }

    @Test
    func keyUpAndSidedModifierChangesUseProductionRoute() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let keyUp = try makeKeyboardEvent(
            type: .keyUp,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let rightShiftFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let rightShiftDown = try makeKeyboardEvent(
            type: .flagsChanged,
            modifierFlags: rightShiftFlags,
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 0x3C
        )
        let rightShiftUpWhileLeftRemains = try makeKeyboardEvent(
            type: .flagsChanged,
            modifierFlags: [.shift],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 0x3C
        )

        surface.keyUp(with: keyUp)
        surface.flagsChanged(with: rightShiftDown)
        surface.flagsChanged(with: rightShiftUpWhileLeftRemains)

        let observations = surface.inputObservationsForTesting
        #expect(observations.count == 3)
        #expect(observations[0].action == .release)
        #expect(observations[1].action == .press)
        #expect(observations[1].modifiers.contains(.shiftRight))
        #expect(observations[2].action == .release)
        #expect(observations[2].modifiers.contains(.shift))
        #expect(!observations[2].modifiers.contains(.shiftRight))

        surface.setMarkedText("compose", selectedRange: NSRange(), replacementRange: NSRange())
        let countBeforeMarkedFlags = surface.inputObservationsForTesting.count
        surface.flagsChanged(with: rightShiftDown)
        #expect(surface.inputObservationsForTesting.count == countBeforeMarkedFlags)
        surface.unmarkText()
    }

    @Test
    func textInputClientObservesRealPreeditCallsAndIMEGeometry() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeKeyboardTestWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedKeyboardSurface(surface, in: window)
        let initialPreeditCount = surface.preeditObservationsForTesting.count

        surface.setMarkedText(
            NSAttributedString(string: "かな"),
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange()
        )

        #expect(surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange(location: 0, length: 2))
        #expect(surface.selectedRange() == NSRange())
        #expect(surface.validAttributesForMarkedText().isEmpty)
        #expect(
            surface.attributedSubstring(
                forProposedRange: NSRange(location: 0, length: 1),
                actualRange: nil
            ) == nil
        )
        #expect(surface.characterIndex(for: .zero) == 0)
        #expect(surface.preeditObservationsForTesting.count == initialPreeditCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .set(Data("かな".utf8)))

        let initialGeometryCount = surface.imeGeometryObservationsForTesting.count
        let rect = surface.firstRect(
            forCharacterRange: surface.markedRange(),
            actualRange: nil
        )
        let geometry = try #require(surface.imeGeometryObservationsForTesting.last)
        #expect(surface.imeGeometryObservationsForTesting.count == initialGeometryCount + 1)
        let expectedWindowRect = surface.convert(geometry.rawViewRect, to: nil)
        let expectedScreenRect = window.convertToScreen(expectedWindowRect)
        #expect(geometry.screenRect == rect)
        #expect(rectanglesApproximatelyEqual(expectedScreenRect, rect))
        #expect(geometry.rawViewRect.origin.x.isFinite)
        #expect(geometry.rawViewRect.origin.y.isFinite)
        #expect(geometry.rawViewRect.width.isFinite)
        #expect(geometry.rawViewRect.height.isFinite)
        #expect(geometry.rawViewRect.width > 0)
        #expect(geometry.rawViewRect.height > 0)
        #expect(rect.origin.x.isFinite)
        #expect(rect.origin.y.isFinite)
        #expect(rect.width.isFinite)
        #expect(rect.height.isFinite)
        #expect(rect.width > 0)
        #expect(rect.height > 0)

        let beforeUnmarkCount = surface.preeditObservationsForTesting.count
        surface.unmarkText()
        #expect(!surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange())
        #expect(surface.preeditObservationsForTesting.count == beforeUnmarkCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)

        surface.setMarkedText("é", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(surface.preeditObservationsForTesting.last == .set(Data("é".utf8)))
        let beforeCommitCount = surface.preeditObservationsForTesting.count
        surface.insertText(
            NSAttributedString(string: "é"),
            replacementRange: NSRange()
        )
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCommitCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)

        surface.setMarkedText("closing", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(surface.preeditObservationsForTesting.last == .set(Data("closing".utf8)))
        let beforeCloseCount = surface.preeditObservationsForTesting.count
        bridge.closeSurface(id: surface.paneID)
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCloseCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)
        surface.setMarkedText("ignored", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCloseCount + 1)
    }

    @Test
    func markedKeyDownCallsProductionKeyWithComposingState() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeKeyboardTestWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedKeyboardSurface(surface, in: window)
        let functionKey = String(UnicodeScalar(NSF1FunctionKey)!)
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: functionKey,
            charactersIgnoringModifiers: functionKey,
            keyCode: 122
        )

        surface.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange()
        )
        let inputCount = surface.inputObservationsForTesting.count
        surface.keyDown(with: event)

        let observation = try #require(surface.inputObservationsForTesting.last)
        #expect(surface.inputObservationsForTesting.count == inputCount + 1)
        #expect(observation.eventIdentifier == ObjectIdentifier(event))
        #expect(observation.action == .press)
        #expect(observation.keyCode == 122)
        #expect(observation.text == nil)
        #expect(observation.composing)
        #expect(surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange(location: 0, length: 2))
        #expect(surface.preeditObservationsForTesting.last == .set(Data("かな".utf8)))
    }

    @Test
    func realResponderKeyAndMarkedUnicodeCommitReachPTYExactlyOnce() async throws {
        let fixture = try KeyboardPTYFixture(expectedPayloadByteCount: 4)
        defer { fixture.remove() }
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            }
        )
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let (closeEvents, closeContinuation) = AsyncStream.makeStream(
            of: KeyboardSurfaceCloseEvent.self
        )
        defer { closeContinuation.finish() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        ) { paneID, processAlive in
            closeContinuation.yield(
                KeyboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            )
        }
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)

        try await fixture.awaitReady(timeout: .seconds(10))

        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let inputCount = surface.inputObservationsForTesting.count
        surface.keyDown(with: event)
        let keyInput = try #require(surface.inputObservationsForTesting.last)
        #expect(surface.inputObservationsForTesting.count == inputCount + 1)
        #expect(keyInput.text == "a")

        let preeditCount = surface.preeditObservationsForTesting.count
        surface.setMarkedText(
            "猫",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange()
        )
        surface.insertText("猫", replacementRange: NSRange())
        #expect(!surface.hasMarkedText())
        #expect(
            Array(surface.preeditObservationsForTesting.dropFirst(preeditCount))
                == [.set(Data("猫".utf8)), .clear]
        )
        surface.insertText("!", replacementRange: NSRange())

        _ = try await firstValue(from: processExits, timeout: .seconds(10))
        surface.keyDown(with: event)
        let closeEvent = try await firstKeyboardCloseEvent(
            from: closeEvents,
            timeout: .seconds(10)
        )

        #expect(closeEvent == KeyboardSurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(try Data(contentsOf: fixture.resultURL) == Data("a猫".utf8))
    }
    @Test
    func broadcastReplaysPrintableKeyToTwoSurfacesWithoutReinterpretingTheActiveResponder()
        throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let target = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        target.frame = source.frame
        window.contentView?.addSubview(target)
        window.makeFirstResponder(source)
        bridge.inputTargetProvider = { _ in
            [target.paneID, source.paneID, target.paneID]
        }
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let surfaces = [source, target]
        let routeCount = bridge.inputObservationsForTesting.count
        let inputCounts = surfaces.map(\.inputObservationsForTesting.count)
        let interpretedTextCounts = surfaces.map(\.interpretedTextObservationsForTesting.count)

        source.keyDown(with: event)

        #expect(bridge.inputObservationsForTesting.count == routeCount + 2)
        #expect(
            bridge.inputObservationsForTesting.suffix(2).map(\.paneID) == [
                source.paneID,
                target.paneID,
            ]
        )
        for (surface, inputCount) in zip(surfaces, inputCounts) {
            #expect(surface.inputObservationsForTesting.count == inputCount + 1)
            #expect(surface.inputObservationsForTesting.last?.text == "a")
        }
        #expect(source.interpretedTextObservationsForTesting.count == interpretedTextCounts[0] + 1)
        #expect(target.interpretedTextObservationsForTesting.count == interpretedTextCounts[1])
    }

    @Test
    func broadcastReplaysPrintableKeyToThreeSurfacesWithoutActiveDuplicates() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        for target in [second, third] {
            target.frame = source.frame
            window.contentView?.addSubview(target)
        }
        window.makeFirstResponder(source)
        bridge.inputTargetProvider = { _ in
            [second.paneID, third.paneID, source.paneID, second.paneID]
        }
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let surfaces = [source, second, third]
        let routeCount = bridge.inputObservationsForTesting.count
        let inputCounts = surfaces.map(\.inputObservationsForTesting.count)
        let interpretedTextCounts = surfaces.map(\.interpretedTextObservationsForTesting.count)

        source.keyDown(with: event)

        #expect(bridge.inputObservationsForTesting.count == routeCount + 3)
        #expect(
            bridge.inputObservationsForTesting.suffix(3).map(\.paneID) == [
                source.paneID,
                second.paneID,
                third.paneID,
            ]
        )
        for (surface, inputCount) in zip(surfaces, inputCounts) {
            #expect(surface.inputObservationsForTesting.count == inputCount + 1)
            #expect(surface.inputObservationsForTesting.last?.text == "a")
        }
        #expect(source.interpretedTextObservationsForTesting.count == interpretedTextCounts[0] + 1)
        #expect(second.interpretedTextObservationsForTesting.count == interpretedTextCounts[1])
        #expect(third.interpretedTextObservationsForTesting.count == interpretedTextCounts[2])
    }

    @Test
    func broadcastReplaysBackspaceAndDeleteToEverySurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        for target in [second, third] {
            target.frame = source.frame
            window.contentView?.addSubview(target)
        }
        window.makeFirstResponder(source)
        bridge.inputTargetProvider = { _ in
            [second.paneID, third.paneID, source.paneID]
        }
        let backspace = try makeKeyboardEvent(
            type: .keyDown,
            characters: "\u{8}",
            charactersIgnoringModifiers: "\u{8}",
            keyCode: 51
        )
        let delete = try makeKeyboardEvent(
            type: .keyDown,
            characters: String(UnicodeScalar(NSDeleteFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDeleteFunctionKey)!),
            keyCode: 117,
            timestamp: 2
        )
        let surfaces = [source, second, third]

        for event in [backspace, delete] {
            let inputCounts = surfaces.map(\.inputObservationsForTesting.count)

            source.keyDown(with: event)

            #expect(
                bridge.inputObservationsForTesting.suffix(3).map(\.paneID) == [
                    source.paneID,
                    second.paneID,
                    third.paneID,
                ]
            )
            for (surface, inputCount) in zip(surfaces, inputCounts) {
                let observation = try #require(surface.inputObservationsForTesting.last)
                #expect(surface.inputObservationsForTesting.count == inputCount + 1)
                #expect(observation.action == .press)
                #expect(observation.keyCode == UInt32(event.keyCode))
                #expect(observation.text == nil)
            }
        }
    }

    @Test
    func broadcastReplaysKeyUpAndFlagsChangedExactlyOnceToEverySurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        bridge.inputTargetProvider = { _ in
            [third.paneID, source.paneID, second.paneID, third.paneID]
        }
        let keyUp = try makeKeyboardEvent(
            type: .keyUp,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let rightShiftFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let flagsChanged = try makeKeyboardEvent(
            type: .flagsChanged,
            modifierFlags: rightShiftFlags,
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 0x3C,
            timestamp: 2
        )
        let surfaces = [source, second, third]
        let inputCounts = surfaces.map(\.inputObservationsForTesting.count)
        let routeCount = bridge.inputObservationsForTesting.count

        source.keyUp(with: keyUp)
        source.flagsChanged(with: flagsChanged)

        #expect(bridge.inputObservationsForTesting.count == routeCount + 6)
        #expect(
            bridge.inputObservationsForTesting.suffix(6).map(\.paneID) == [
                source.paneID,
                third.paneID,
                second.paneID,
                source.paneID,
                third.paneID,
                second.paneID,
            ]
        )
        for (surface, inputCount) in zip(surfaces, inputCounts) {
            let observations = surface.inputObservationsForTesting
            #expect(observations.count == inputCount + 2)
            #expect(observations[observations.count - 2].action == .release)
            #expect(observations.last?.action == .press)
            #expect(observations.last?.modifiers.contains(.shiftRight) == true)
        }
    }

    @Test
    func broadcastRoutesSameKeyboardEventToEveryDistinctTargetAndDefaultsToSourceOnly() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        bridge.inputTargetProvider = { _ in
            [source.paneID, second.paneID, second.paneID, third.paneID]
        }
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )

        source.keyDown(with: event)

        #expect(
            bridge.inputObservationsForTesting.suffix(3).map(\.paneID) == [
                source.paneID,
                second.paneID,
                third.paneID,
            ])
        for surface in [source, second, third] {
            let observation = try #require(surface.inputObservationsForTesting.last)
            #expect(observation.eventIdentifier == ObjectIdentifier(event))
            #expect(observation.translationEventIdentifier == ObjectIdentifier(event))
        }

        bridge.inputTargetProvider = { [$0] }
        let sourceInputCount = source.inputObservationsForTesting.count
        let secondInputCount = second.inputObservationsForTesting.count
        let thirdInputCount = third.inputObservationsForTesting.count
        let sourceOnlyEvent = try makeKeyboardEvent(
            type: .keyDown,
            characters: "b",
            charactersIgnoringModifiers: "b",
            keyCode: 11,
            timestamp: 2
        )

        source.keyDown(with: sourceOnlyEvent)

        #expect(source.inputObservationsForTesting.count == sourceInputCount + 1)
        #expect(second.inputObservationsForTesting.count == secondInputCount)
        #expect(third.inputObservationsForTesting.count == thirdInputCount)
    }
}

private struct KeyboardSurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

private enum KeyboardInputTestError: Error {
    case fifoCreationFailed(Int32)
    case processFailed(Int32)
    case streamEnded
    case timeout
}

@MainActor
private final class KeyboardPTYFixture {
    let directoryURL: URL
    let configURL: URL
    let resultURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let captureURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init(expectedPayloadByteCount: Int) throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        configURL = directoryURL.appending(path: "config")
        resultURL = directoryURL.appending(path: "result")
        readyFIFOURL = directoryURL.appending(path: "ready.fifo")
        captureURL = directoryURL.appending(path: "capture")
        try Data("abnormal-command-exit-runtime = 0\n".utf8).write(to: configURL)

        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw KeyboardInputTestError.fifoCreationFailed(errno)
        }

        let transmittedByteCount = expectedPayloadByteCount + 1
        let script =
            "stty raw -echo; printf R > \(shellQuote(readyFIFOURL.path)); "
            + "dd bs=1 count=\(transmittedByteCount) of=\(shellQuote(captureURL.path)) 2>/dev/null; "
            + "if [ \"$(dd bs=1 skip=\(expectedPayloadByteCount) count=1 "
            + "if=\(shellQuote(captureURL.path)) 2>/dev/null)\" = '!' ]; then "
            + "dd bs=1 count=\(expectedPayloadByteCount) if=\(shellQuote(captureURL.path)) "
            + "of=\(shellQuote(resultURL.path)) 2>/dev/null; else "
            + "cp \(shellQuote(captureURL.path)) \(shellQuote(resultURL.path)); fi"
        command = "/bin/sh -c \(shellQuote(script))"

        (readyExits, readyExitContinuation) = AsyncStream.makeStream(of: Int32.self)
        readyReader.executableURL = URL(filePath: "/bin/cat")
        readyReader.arguments = [readyFIFOURL.path]
        readyReader.standardOutput = readyOutput
        readyReader.standardError = FileHandle.nullDevice
        let continuation = readyExitContinuation
        readyReader.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
    }

    func startReadyReader() throws {
        try readyReader.run()
    }

    func awaitReady(timeout: Duration) async throws {
        let status = try await firstValue(from: readyExits, timeout: timeout)
        guard status == 0 else {
            throw KeyboardInputTestError.processFailed(status)
        }
        let data = readyOutput.fileHandleForReading.readDataToEndOfFile()
        guard data == Data("R".utf8) else {
            throw KeyboardInputTestError.processFailed(status)
        }
    }

    func remove() {
        readyExitContinuation.finish()
        if readyReader.isRunning {
            readyReader.terminate()
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private func makeKeyboardEvent(
    type: NSEvent.EventType,
    modifierFlags: NSEvent.ModifierFlags = [],
    characters: String,
    charactersIgnoringModifiers: String,
    keyCode: UInt16,
    timestamp: TimeInterval = 1,
    windowNumber: Int = 0
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

@MainActor
private func makeKeyboardTestWindow() -> NSWindow {
    KeyboardTestWindow(
        contentRect: NSRect(x: 120, y: 120, width: 800, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private final class KeyboardTestWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}

@MainActor
private func embedKeyboardSurface(_ surface: GhosttySurfaceView, in window: NSWindow) {
    guard let contentView = window.contentView else {
        Issue.record("Keyboard test window has no content view")
        return
    }
    surface.frame = contentView.bounds
    surface.autoresizingMask = [.width, .height]
    contentView.addSubview(surface)
    window.makeFirstResponder(surface)
}

private func firstKeyboardCloseEvent(
    from stream: AsyncStream<KeyboardSurfaceCloseEvent>,
    timeout: Duration
) async throws -> KeyboardSurfaceCloseEvent {
    try await firstValue(from: stream, timeout: timeout)
}

private func firstValue<Value: Sendable>(
    from stream: AsyncStream<Value>,
    timeout: Duration
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw KeyboardInputTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw KeyboardInputTestError.timeout
        }

        guard let value = try await group.next() else {
            throw KeyboardInputTestError.streamEnded
        }
        group.cancelAll()
        return value
    }
}

private func rectanglesApproximatelyEqual(
    _ lhs: NSRect,
    _ rhs: NSRect,
    tolerance: CGFloat = 0.000_001
) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
