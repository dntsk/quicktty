import AppKit
import Darwin
import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct GhosttySplitTreeViewTests {
    @Test
    func surfaceFailurePresentationPreservesMessageAndValueSemantics() {
        let message = "The terminal failed to start."
        let presentation = SurfaceFailurePresentation(message: message)

        #expect(presentation.message == message)
        #expect(presentation == SurfaceFailurePresentation(message: message))
        #expect(presentation != SurfaceFailurePresentation(message: "A different error"))
        requireSendable(presentation)
    }

    @Test
    func descriptorRecursivelyMapsNestedSplitTreeForUpstreamRendering() {
        let firstPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let outerSplitID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let innerSplitID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let root = SplitNode.split(
            id: outerSplitID,
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(firstPaneID),
            second: .split(
                id: innerSplitID,
                axis: .vertical,
                ratio: 0.7,
                first: .pane(secondPaneID),
                second: .pane(thirdPaneID)
            )
        )

        #expect(
            GhosttySplitTreeDescriptor(root: root)
                == .split(
                    id: outerSplitID,
                    direction: .horizontal,
                    ratio: 0.4,
                    first: .pane(firstPaneID),
                    second: .split(
                        id: innerSplitID,
                        direction: .vertical,
                        ratio: 0.7,
                        first: .pane(secondPaneID),
                        second: .pane(thirdPaneID)
                    )
                )
        )
    }

    @Test
    func paneDecorationUsesOnlyActivePaneAndIgnoresWindowKeyState() {
        let activePaneID = PaneID()
        let inactivePaneID = PaneID()
        let appearance = GhosttySplitAppearance(
            unfocusedFill: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
            unfocusedOverlayOpacity: 0.35
        )
        let presentationState = WorkspacePresentationState(isKeyWindow: true)

        let activeWhenKey = PaneFocusDecoration.resolve(
            paneID: activePaneID,
            activePaneID: activePaneID,
            appearance: appearance
        )
        let inactiveWhenKey = PaneFocusDecoration.resolve(
            paneID: inactivePaneID,
            activePaneID: activePaneID,
            appearance: appearance
        )
        presentationState.setKeyWindow(false)
        let activeWhenNotKey = PaneFocusDecoration.resolve(
            paneID: activePaneID,
            activePaneID: activePaneID,
            appearance: appearance
        )
        let inactiveWhenNotKey = PaneFocusDecoration.resolve(
            paneID: inactivePaneID,
            activePaneID: activePaneID,
            appearance: appearance
        )

        #expect(
            activeWhenKey
                == PaneFocusDecoration(
                    overlayFill: appearance.unfocusedFill,
                    overlayOpacity: 0
                )
        )
        #expect(
            inactiveWhenKey
                == PaneFocusDecoration(
                    overlayFill: appearance.unfocusedFill,
                    overlayOpacity: appearance.unfocusedOverlayOpacity
                )
        )
        #expect(activeWhenNotKey == activeWhenKey)
        #expect(inactiveWhenNotKey == inactiveWhenKey)
        #expect(!presentationState.isKeyWindow)
        #expect(
            PaneFocusDecoration.resolve(
                paneID: activePaneID,
                activePaneID: nil,
                appearance: appearance
            ).overlayOpacity == appearance.unfocusedOverlayOpacity
        )
    }

    @Test
    func switchingPaneRootsReplacesTheActualHostedSurfaceView() async throws {
        let fixture = try SizeSensitiveChildFixture()
        defer { fixture.remove() }
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        try fixture.startReadyReader()
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        )
        try await fixture.awaitReady(timeout: .seconds(10))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])

        controller.displayTerminal(
            root: .pane(second.paneID),
            surfaces: [second.paneID: second],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(second)])

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)

        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])
        #expect(!first.processExitedForTesting)
        #expect(!second.processExitedForTesting)
        let firstObservations = first.sizeRequestObservationsForTesting
        #expect(!firstObservations.isEmpty)
        #expect(
            firstObservations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
        let secondObservations = second.sizeRequestObservationsForTesting
        #expect(!secondObservations.isEmpty)
        #expect(
            secondObservations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
    }

    @Test
    func activePaneDecorationUpdatesWithoutReplacingSurfacesAndPassesThroughHits() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/sleep 60")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/sleep 60")
        )
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .pane(first.paneID),
            second: .pane(second.paneID)
        )
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        defer { window.orderOut(nil) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        controller.displayTerminal(
            root: root,
            surfaces: [first.paneID: first, second.paneID: second],
            failures: [:],
            palette: .fallback,
            activePaneID: first.paneID,
            splitAppearance: GhosttySplitAppearance(
                unfocusedFill: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
                unfocusedOverlayOpacity: 0.3
            ),
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)
        let hostID = try #require(controller.splitHostingControllerIdentifierForTesting)
        let originalSurfaceIDs = controller.hostedSurfaceIdentifiersForTesting
        let firstSizeRequestCount = first.sizeRequestObservationsForTesting.count
        let secondSizeRequestCount = second.sizeRequestObservationsForTesting.count
        let hitPoint = first.convert(first.bounds.center, to: controller.view)
        let hitView = controller.view.hitTest(hitPoint)
        #expect(hitView === first || hitView?.isDescendant(of: first) == true)

        controller.displayTerminal(
            root: root,
            surfaces: [first.paneID: first, second.paneID: second],
            failures: [:],
            palette: .fallback,
            activePaneID: second.paneID,
            splitAppearance: GhosttySplitAppearance(
                unfocusedFill: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
                unfocusedOverlayOpacity: 0.3
            ),
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)

        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        #expect(controller.hostedSurfaceIdentifiersForTesting == originalSurfaceIDs)
        #expect(
            Set(controller.renderedSurfaceIdentifiersForTesting)
                == Set([ObjectIdentifier(first), ObjectIdentifier(second)])
        )

        let replacementWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { replacementWindow.orderOut(nil) }
        let replacementContent = try #require(replacementWindow.contentView)
        controller.view.removeFromSuperview()
        controller.view.frame = replacementContent.bounds
        replacementContent.addSubview(controller.view)
        await settleWorkspace(controller, in: replacementWindow)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: replacementWindow
        )
        await settleWorkspace(controller, in: replacementWindow)

        #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
        #expect(controller.hostedSurfaceIdentifiersForTesting == originalSurfaceIDs)
        #expect(
            Set(controller.renderedSurfaceIdentifiersForTesting)
                == Set([ObjectIdentifier(first), ObjectIdentifier(second)])
        )
        #expect(!first.processExitedForTesting)
        #expect(!second.processExitedForTesting)
        let newFirstSizeRequests = first.sizeRequestObservationsForTesting.dropFirst(
            firstSizeRequestCount
        )
        let newSecondSizeRequests = second.sizeRequestObservationsForTesting.dropFirst(
            secondSizeRequestCount
        )
        #expect(
            newFirstSizeRequests.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            }
        )
        #expect(
            newSecondSizeRequests.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            }
        )
    }

    @Test
    func managedPresentationBoundsNamesAndRepresentsEveryStateAndOwner() {
        let taskID = UUID()
        let states: [(TerminalTaskState, String)] = [
            (.creating, "Creating"), (.running, "Running"),
            (.waitingForUser, "Waiting for user"), (.succeeded, "Succeeded"),
            (.failed, "Failed"), (.finishedUnknown, "Finished"), (.cancelled, "Cancelled"),
        ]
        #expect(
            Set(states.map { $0.0.rawValue }) == Set(TerminalTaskState.allCases.map(\.rawValue)))
        for (state, text) in states {
            for owner in TerminalPaneControlOwner.allCases {
                let value = TerminalAutomationPresentation(
                    taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: state,
                    controlOwner: owner, canReturnControl: true)
                let expectedText = state == .running && owner == .user ? "User controlled" : text
                #expect(value.stateText == expectedText)
                #expect(value.badgeText == "Trusted Agent · \(expectedText)")
                #expect(value.accessibilityLabel == "Managed terminal, Trusted Agent")
                let ownerText: String
                switch owner {
                case .agent: ownerText = "Agent controls pane"
                case .user: ownerText = "User controls pane"
                case .finished: ownerText = "Control finished"
                }
                #expect(value.ownerText == ownerText)
                #expect(value.accessibilityValue == "\(expectedText), \(ownerText)")
                #expect(
                    value.canReturnControl
                        == (owner == .user
                            && (state == .running || state == .waitingForUser)))
                #expect(value.taskID == taskID)
                #expect(value.taskState == state && value.controlOwner == owner)
                #expect(
                    value
                        == TerminalAutomationPresentation(
                            taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: state,
                            controlOwner: owner, canReturnControl: true))
                requireSendable(value)
                let denied = TerminalAutomationPresentation(
                    taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: state,
                    controlOwner: owner, canReturnControl: false)
                #expect(!denied.canReturnControl)
                let revoked = TerminalAutomationPresentation(
                    taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: state,
                    controlOwner: owner, isRevoked: true, canReturnControl: true)
                #expect(revoked.stateText == "Revoked" && !revoked.canReturnControl)
            }
        }
        for name in [
            String(repeating: "A", count: 10_000),
            "A" + String(repeating: "\u{301}", count: 10_000),
            String(repeating: "👩🏽‍💻", count: 1_000),
            "Agent\n\r\t\u{1B}\u{202E}name", " \n\t ", "",
        ] {
            let value = TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: name, taskState: .running,
                controlOwner: .agent, canReturnControl: false)
            #expect(!value.adapterDisplayName.isEmpty)
            #expect(
                value.adapterDisplayName.utf8.count
                    <= TerminalAutomationPresentation.maximumAdapterNameBytes)
            #expect(
                value.adapterDisplayName.unicodeScalars.allSatisfy {
                    ![.control, .format, .lineSeparator, .paragraphSeparator].contains(
                        $0.properties.generalCategory)
                })
            #expect(value.badgeText.utf8.count < 160)
            #expect(value.accessibilityLabel.utf8.count < 160)
        }
    }

    @Test
    func managedBadgeMountedHitsAccessibilityAndUpdatesPreserveSurfaces() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        defer { window.orderOut(nil) }
        let taskID = UUID()
        var returned: [UUID] = []
        controller.displayTerminal(
            root: .split(
                id: UUID(), axis: .horizontal, ratio: 0.5,
                first: .pane(first.paneID), second: .pane(second.paneID)),
            surfaces: [first.paneID: first, second.paneID: second], failures: [:],
            palette: .fallback, activePaneID: first.paneID,
            onResize: { _, _ in }, onEqualize: { _ in },
            onRetryUnavailablePane: { _ in }, onCloseUnavailablePane: { _ in },
            onReturnControlToAgent: { returned.append($0) })
        await settleWorkspace(controller, in: window)
        #expect(window.makeFirstResponder(first))
        let hostID = controller.splitHostingControllerIdentifierForTesting
        let surfaceIDs = controller.hostedSurfaceIdentifiersForTesting
        let frames = [first.frame, second.frame]
        let sizeCounts = [
            first.sizeRequestObservationsForTesting.count,
            second.sizeRequestObservationsForTesting.count,
        ]
        let values: [TerminalAutomationPresentation] =
            TerminalTaskState.allCases.map { state in
                TerminalAutomationPresentation(
                    taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: state,
                    controlOwner: state == .running || state == .waitingForUser ? .user : .finished,
                    canReturnControl: true)
            } + [
                TerminalAutomationPresentation(
                    taskID: taskID, adapterDisplayName: "Trusted Agent", taskState: .running,
                    controlOwner: .user, isRevoked: true, canReturnControl: true)
            ]
        for value in values {
            controller.refreshTerminalAutomationPresentations([second.paneID: value])
            await settleWorkspace(controller, in: window)
            let views = mountedViews(in: controller.view)
            let badge = try #require(views.compactMap { $0 as? TerminalAutomationBadgeView }.first)
            let group = try #require(
                views.first { $0.accessibilityLabel() == value.accessibilityLabel })
            #expect(group.isAccessibilityElement() && group.accessibilityRole() == .group)
            #expect(group.accessibilityValue() as? String == value.accessibilityValue)
            let label = try #require(textField(with: value.badgeText, in: views))
            let panelFrame = group.convert(group.bounds, to: badge)
            #expect(panelFrame.minY == badge.bounds.minY + 6)
            #expect(panelFrame.maxX == badge.bounds.maxX - 6)
            #expect(panelFrame.width <= 300 && panelFrame.height <= 52)
            #expect(
                colorsMatch(
                    label.textColor, NSColor(ghosttyRGB: GhosttyChromePalette.fallback.foreground)))
            #expect(!badge.isHiddenOrHasHiddenAncestor)
            let returnButton = try #require(
                button(titled: TerminalAutomationPresentation.returnControlTitle, in: views))
            #expect(returnButton.isHidden == !value.canReturnControl)
            #expect(returnButton.isEnabled == value.canReturnControl)
            #expect(
                returnButton.accessibilityLabel()
                    == TerminalAutomationPresentation.returnControlTitle)
            #expect(!returnButton.acceptsFirstResponder)
            for hitPoint in [
                label.convert(label.bounds.center, to: controller.view),
                group.convert(NSPoint(x: 2, y: 2), to: controller.view),
            ] {
                let hit = controller.view.hitTest(hitPoint)
                #expect(hit === second || hit?.isDescendant(of: second) == true)
            }
            let before = returned.count
            if value.canReturnControl {
                let hitPoint = returnButton.convert(returnButton.bounds.center, to: controller.view)
                let hit = controller.view.hitTest(hitPoint)
                #expect(hit === returnButton || hit?.isDescendant(of: returnButton) == true)
                #expect(
                    (group.accessibilityChildren() ?? []).contains {
                        ($0 as? NSButton) === returnButton
                    })
                returnButton.performClick(nil)
                #expect(returned.count == before + 1 && returned.last == taskID)
            } else {
                returnButton.performClick(nil)
                #expect(returned.count == before)
            }
            #expect(controller.splitHostingControllerIdentifierForTesting == hostID)
            #expect(controller.hostedSurfaceIdentifiersForTesting == surfaceIDs)
            #expect(Set(controller.renderedSurfaceIdentifiersForTesting) == Set(surfaceIDs.values))
            #expect([first.frame, second.frame] == frames)
            #expect(
                [
                    first.sizeRequestObservationsForTesting.count,
                    second.sizeRequestObservationsForTesting.count,
                ] == sizeCounts)
            #expect(window.firstResponder === first)
        }
        controller.refreshTerminalAutomationPresentations([:])
        await settleWorkspace(controller, in: window)
        #expect(!mountedViews(in: controller.view).contains { $0 is TerminalAutomationBadgeView })
        #expect(controller.hostedSurfaceIdentifiersForTesting == surfaceIDs)
    }

    @Test(arguments: [true, false])
    func inactiveManagedPaneRoutesButtonAndFocusClicksThroughMonitor(applicationIsActive: Bool)
        async throws
    {
        let bridge = try GhosttyBridge(applicationIsActive: { applicationIsActive })
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller, window: makeSplitMonitorWindow())
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let taskID = UUID()
        var returnedTaskIDs: [UUID] = []
        var focusedPaneIDs: [PaneID] = []
        bridge.surfaceFocusHandler = { focusedPaneIDs.append($0) }
        controller.displayTerminal(
            root: .split(
                id: UUID(), axis: .horizontal, ratio: 0.5,
                first: .pane(first.paneID), second: .pane(second.paneID)),
            surfaces: [first.paneID: first, second.paneID: second], failures: [:],
            palette: .fallback, activePaneID: first.paneID,
            onResize: { _, _ in }, onEqualize: { _ in },
            onRetryUnavailablePane: { _ in }, onCloseUnavailablePane: { _ in },
            onReturnControlToAgent: { returnedTaskIDs.append($0) })
        await settleWorkspace(controller, in: window)
        let contentView = try #require(window.contentView)
        let firstFrame = first.convert(first.bounds, to: contentView)
        let secondFrame = second.convert(second.bounds, to: contentView)
        #expect(secondFrame.minX > firstFrame.minX)
        #expect(secondFrame.minX > contentView.bounds.minX)
        #expect(
            first.focusClickMonitorInstalledForTesting
                && second.focusClickMonitorInstalledForTesting)

        for owner in [TerminalPaneControlOwner.user, .agent] {
            let value = TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .running,
                controlOwner: owner, canReturnControl: true)
            controller.refreshTerminalAutomationPresentations([second.paneID: value])
            await settleWorkspace(controller, in: window)
            #expect(window.makeFirstResponder(first))
            focusedPaneIDs.removeAll()
            let views = mountedViews(in: controller.view)
            let label = try #require(textField(with: value.badgeText, in: views))
            let panel = try #require(
                views.first { $0.accessibilityLabel() == value.accessibilityLabel })
            let returnButton = try #require(
                button(titled: TerminalAutomationPresentation.returnControlTitle, in: views))
            if value.canReturnControl {
                let down = try splitMouseEvent(.leftMouseDown, in: returnButton, window: window)
                #expect(
                    second.processFocusClickForTesting(down, applicationIsActive: true) === down)
                #expect(
                    second.processFocusClickForTesting(down, applicationIsActive: false) === down)
                try deliverBadgeMouseClick(returnButton, through: [first, second], in: window)
                #expect(returnedTaskIDs == [taskID])
                #expect(window.firstResponder === first)
                #expect(focusedPaneIDs.isEmpty)
                #expect(first.mouseButtonObservationsForTesting.isEmpty)
                #expect(second.mouseButtonObservationsForTesting.isEmpty)
            } else {
                #expect(returnButton.isHidden)
            }

            let dividerDown = try splitMouseEvent(
                .leftMouseDown, in: contentView, window: window,
                point: NSPoint(x: (firstFrame.maxX + secondFrame.minX) / 2, y: secondFrame.midY))
            let dividerHit = try mountedWindowHit(for: dividerDown, in: window)
            #expect(dividerHit !== first && dividerHit !== second)
            #expect(first.processLocalEventForTesting(dividerDown) === dividerDown)
            #expect(second.processLocalEventForTesting(dividerDown) === dividerDown)
            #expect(window.firstResponder === first)
            #expect(focusedPaneIDs.isEmpty)

            // WHY: Read-only badge pixels must retain ordinary inactive-pane first-click semantics.
            for (view, point) in [
                (label as NSView, label.bounds.center),
                (panel, NSPoint(x: 2, y: 2)),
                (second as NSView, second.bounds.center),
            ] {
                #expect(window.makeFirstResponder(first))
                focusedPaneIDs.removeAll()
                let down = try splitMouseEvent(
                    .leftMouseDown, in: view, window: window, point: point)
                let up = try splitMouseEvent(.leftMouseUp, in: view, window: window, point: point)
                #expect(try mountedWindowHit(for: down, in: window) === second)
                let before = second.mouseButtonObservationsForTesting.count
                #expect(first.processLocalEventForTesting(down) === down)
                let routed = second.processLocalEventForTesting(down)
                #expect(window.firstResponder === second)
                #expect(focusedPaneIDs == [second.paneID])
                if applicationIsActive {
                    #expect(routed == nil)
                    second.mouseUp(with: up)
                    #expect(second.mouseButtonObservationsForTesting.count == before)
                } else {
                    #expect(routed === down)
                    #expect(!second.acceptsFirstMouse(for: down))
                    second.mouseDown(with: down)
                    second.mouseUp(with: up)
                    #expect(second.mouseButtonObservationsForTesting.count == before + 2)
                }
                // WHY: Once focused, the next terminal click must no longer be consumed.
                #expect(second.processLocalEventForTesting(down) === down)
                #expect(returnedTaskIDs == [taskID])
            }
        }
        #expect(first.mouseButtonObservationsForTesting.isEmpty)
    }

    @Test(arguments: [true, false])
    func mountedSearchAndManagedBadgeCoexistWithoutReplacingOrResizingSurface(horizontalSplit: Bool)
        async throws
    {
        let bridge = try GhosttyBridge(applicationIsActive: { true })
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller, window: makeSplitMonitorWindow())
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let taskID = UUID()
        var returnedTaskIDs: [UUID] = []
        controller.displayTerminal(
            root: .split(
                id: UUID(), axis: horizontalSplit ? .horizontal : .vertical, ratio: 0.5,
                first: .pane(first.paneID), second: .pane(second.paneID)),
            surfaces: [first.paneID: first, second.paneID: second], failures: [:],
            palette: .fallback, activePaneID: first.paneID,
            onResize: { _, _ in }, onEqualize: { _ in },
            onRetryUnavailablePane: { _ in }, onCloseUnavailablePane: { _ in },
            onReturnControlToAgent: { returnedTaskIDs.append($0) })
        await settleWorkspace(controller, in: window)
        #expect(window.makeFirstResponder(second))
        #expect(first.searchReservedTopInset == 0 && second.searchReservedTopInset == 0)
        _ = second.performTerminalShortcutAction(.find)
        try await settleWorkspace(
            controller, in: window,
            until: {
                second.searchInteractionRegionForTesting != nil
                    && second.isSearchFieldFocusedForTesting
                    && window.firstResponder is NSTextView
            })
        let initialState = try #require(second.searchState)
        let initialSearchHost = try #require(second.searchOverlayViewForTesting)
        let initialRegion = try #require(second.searchInteractionRegionForTesting)
        #expect(abs(initialRegion.swiftUIFrame.minY - 8) < 1)
        initialState.needle = "task9-query"
        await settleWorkspace(controller, in: window)
        let initialResponder = try #require(window.firstResponder)
        let splitHostID = controller.splitHostingControllerIdentifierForTesting
        let surfaceIDs = controller.hostedSurfaceIdentifiersForTesting
        let frames = [first.frame, second.frame]
        let sizes = [first.sizeSnapshotForTesting, second.sizeSnapshotForTesting]
        let nativeSizes = try sizes.map { try #require($0) }
        let sizeHistories = [
            first.sizeRequestObservationsForTesting,
            second.sizeRequestObservationsForTesting,
        ]
        try #require(sizeHistories.allSatisfy { $0.count < 256 })

        @MainActor
        func expectUnchangedNativeSizeRequests() throws {
            for (index, surface) in [first, second].enumerated() {
                let baselineHistory = sizeHistories[index]
                let observations = surface.sizeRequestObservationsForTesting
                // WHY: The bounded history must retain every request, including transient resizes.
                try #require(observations.count < 256)
                try #require(observations.count >= baselineHistory.count)
                try #require(Array(observations.prefix(baselineHistory.count)) == baselineHistory)
                let baselineSize = nativeSizes[index]
                // WHY: Ghostty ignores identical pixel sizes; request count alone is not a PTY resize.
                for observation in observations.dropFirst(baselineHistory.count) {
                    #expect(observation.requestedWidthPixels == baselineSize.widthPixels)
                    #expect(observation.requestedHeightPixels == baselineSize.heightPixels)
                    #expect(observation.resultingSize == baselineSize)
                }
            }
        }

        let focusRequests = second.searchFocusRequestsForTesting
        let values = [
            TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .running,
                controlOwner: .agent, canReturnControl: false),
            TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .running,
                controlOwner: .user, canReturnControl: true),
            TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .waitingForUser,
                controlOwner: .user, canReturnControl: true),
            TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .succeeded,
                controlOwner: .finished, canReturnControl: false),
            TerminalAutomationPresentation(
                taskID: taskID, adapterDisplayName: "Target agent", taskState: .running,
                controlOwner: .user, isRevoked: true, canReturnControl: true),
        ]
        var managedRegion: GhosttySearchInteractionRegion?
        for value in values {
            controller.refreshTerminalAutomationPresentations([second.paneID: value])
            try await settleWorkspace(
                controller, in: window,
                until: {
                    guard let region = second.searchInteractionRegionForTesting else {
                        return false
                    }
                    return abs(region.swiftUIFrame.minY - 66) < 1
                })
            await settleWorkspace(controller, in: window)
            let currentRegion = try #require(second.searchInteractionRegionForTesting)
            if let managedRegion {
                #expect(currentRegion == managedRegion)
            }
            managedRegion = currentRegion
            #expect(second.searchReservedTopInset == 58)
            #expect(first.searchReservedTopInset == 0)
            #expect(second.searchState === initialState)
            #expect(second.searchState?.needle == "task9-query")
            #expect(second.searchOverlayViewForTesting === initialSearchHost)
            #expect(initialSearchHost.frame == second.bounds)
            #expect(second.isSearchFieldFocusedForTesting)
            #expect(window.firstResponder === initialResponder)
            #expect(second.searchFocusRequestsForTesting == focusRequests)
            try expectSearchAndBadgeHits(
                on: second, adjacent: first, presentation: value, controller: controller,
                window: window)
            if value.canReturnControl {
                let returnButton = try #require(
                    button(
                        titled: TerminalAutomationPresentation.returnControlTitle,
                        in: mountedViews(in: controller.view)))
                let before = returnedTaskIDs.count
                try deliverBadgeMouseClick(returnButton, through: [first, second], in: window)
                #expect(returnedTaskIDs.count == before + 1 && returnedTaskIDs.last == taskID)
                #expect(window.firstResponder === initialResponder)
                #expect(second.isSearchFieldFocusedForTesting)
            }
            #expect(controller.splitHostingControllerIdentifierForTesting == splitHostID)
            #expect(controller.hostedSurfaceIdentifiersForTesting == surfaceIDs)
            #expect(Set(controller.renderedSurfaceIdentifiersForTesting) == Set(surfaceIDs.values))
            #expect([first.frame, second.frame] == frames)
            #expect([first.sizeSnapshotForTesting, second.sizeSnapshotForTesting] == sizes)
            try expectUnchangedNativeSizeRequests()
        }
        #expect(returnedTaskIDs == [taskID, taskID])

        let waitingValue = values[2]
        controller.refreshTerminalAutomationPresentations([second.paneID: waitingValue])
        await settleWorkspace(controller, in: window)
        second.closeSearchFromUIForTesting()
        try await settleWorkspace(controller, in: window, until: { second.searchState == nil })
        #expect(second.searchOverlayViewForTesting == nil)
        #expect(window.firstResponder === second)
        #expect(second.searchReservedTopInset == 58)
        #expect(mountedViews(in: controller.view).contains { $0 is TerminalAutomationBadgeView })

        _ = second.performTerminalShortcutAction(.find)
        try await settleWorkspace(
            controller, in: window,
            until: {
                second.searchInteractionRegionForTesting != nil
                    && second.isSearchFieldFocusedForTesting
                    && window.firstResponder is NSTextView
            })
        await settleWorkspace(controller, in: window)
        let reopenedState = try #require(second.searchState)
        let reopenedHost = try #require(second.searchOverlayViewForTesting)
        let reopenedResponder = try #require(window.firstResponder)
        #expect(reopenedState !== initialState && reopenedHost !== initialSearchHost)
        #expect(abs((second.searchInteractionRegionForTesting?.swiftUIFrame.minY ?? 0) - 66) < 1)
        try expectSearchAndBadgeHits(
            on: second, adjacent: first, presentation: waitingValue, controller: controller,
            window: window)
        let reopenedButton = try #require(
            button(
                titled: TerminalAutomationPresentation.returnControlTitle,
                in: mountedViews(in: controller.view)))
        try deliverBadgeMouseClick(reopenedButton, through: [first, second], in: window)
        #expect(returnedTaskIDs == [taskID, taskID, taskID])
        #expect(window.firstResponder === reopenedResponder)

        controller.refreshTerminalAutomationPresentations([:])
        try await settleWorkspace(
            controller, in: window,
            until: {
                guard let region = second.searchInteractionRegionForTesting else { return false }
                return abs(region.swiftUIFrame.minY - 8) < 1
            })
        await settleWorkspace(controller, in: window)
        #expect(first.searchReservedTopInset == 0 && second.searchReservedTopInset == 0)
        #expect(reopenedHost.rootView.reservedTopInset == 0)
        #expect(second.searchState === reopenedState)
        #expect(second.searchOverlayViewForTesting === reopenedHost)
        #expect(window.firstResponder === reopenedResponder)
        #expect(second.isSearchFieldFocusedForTesting)
        #expect(!mountedViews(in: controller.view).contains { $0 is TerminalAutomationBadgeView })
        let restoredField = try #require(
            mountedViews(in: reopenedHost).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        )
        let restoredSearchDown = try splitMouseEvent(
            .leftMouseDown, in: restoredField, window: window)
        let restoredSearchHit = try mountedWindowHit(for: restoredSearchDown, in: window)
        #expect(
            restoredSearchHit === reopenedHost || restoredSearchHit.isDescendant(of: reopenedHost))
        #expect(first.processLocalEventForTesting(restoredSearchDown) === restoredSearchDown)
        #expect(second.processLocalEventForTesting(restoredSearchDown) === restoredSearchDown)
        #expect(window.firstResponder === reopenedResponder)
        #expect(controller.splitHostingControllerIdentifierForTesting == splitHostID)
        #expect(controller.hostedSurfaceIdentifiersForTesting == surfaceIDs)
        #expect([first.frame, second.frame] == frames)
        #expect([first.sizeSnapshotForTesting, second.sizeSnapshotForTesting] == sizes)
        try expectUnchangedNativeSizeRequests()
        #expect(first.mouseButtonObservationsForTesting.isEmpty)
        #expect(second.mouseButtonObservationsForTesting.isEmpty)
    }

    private func expectSearchAndBadgeHits(
        on surface: GhosttySurfaceView, adjacent: GhosttySurfaceView,
        presentation: TerminalAutomationPresentation, controller: WorkspaceViewController,
        window: NSWindow
    ) throws {
        let contentView = try #require(window.contentView)
        let searchHost = try #require(surface.searchOverlayViewForTesting)
        let region = try #require(surface.searchInteractionRegionForTesting).swiftUIFrame
        let searchLocalFrame = NSRect(
            x: searchHost.bounds.minX + region.minX,
            y: searchHost.isFlipped
                ? searchHost.bounds.minY + region.minY : searchHost.bounds.maxY - region.maxY,
            width: region.width, height: region.height)
        let searchFrame = searchHost.convert(searchLocalFrame, to: contentView)
        let views = mountedViews(in: controller.view)
        let panel = try #require(
            views.first { $0.accessibilityLabel() == presentation.accessibilityLabel })
        let panelFrame = panel.convert(panel.bounds, to: contentView)
        let leafFrame = surface.convert(surface.bounds, to: contentView)
        let adjacentFrame = adjacent.convert(adjacent.bounds, to: contentView)
        #expect(leafFrame.contains(searchFrame) && leafFrame.contains(panelFrame))
        #expect(!searchFrame.intersects(panelFrame))
        #expect(!searchFrame.intersects(adjacentFrame) && !panelFrame.intersects(adjacentFrame))
        let field = try #require(
            mountedViews(in: searchHost).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let fieldFrame = field.convert(field.bounds, to: contentView)
        #expect(searchFrame.contains(fieldFrame.center))
        let searchDown = try splitMouseEvent(.leftMouseDown, in: field, window: window)
        let searchHit = try mountedWindowHit(for: searchDown, in: window)
        #expect(searchHit === searchHost || searchHit.isDescendant(of: searchHost))
        let responder = window.firstResponder
        #expect(adjacent.processLocalEventForTesting(searchDown) === searchDown)
        #expect(surface.processLocalEventForTesting(searchDown) === searchDown)
        #expect(window.firstResponder === responder)
        let returnButton = try #require(
            button(titled: TerminalAutomationPresentation.returnControlTitle, in: views))
        if presentation.canReturnControl {
            let buttonFrame = returnButton.convert(returnButton.bounds, to: contentView)
            #expect(leafFrame.contains(buttonFrame) && !searchFrame.intersects(buttonFrame))
            let buttonDown = try splitMouseEvent(.leftMouseDown, in: returnButton, window: window)
            let buttonHit = try mountedWindowHit(for: buttonDown, in: window)
            #expect(buttonHit === returnButton || buttonHit.isDescendant(of: returnButton))
        }
        let adjacentDown = try splitMouseEvent(.leftMouseDown, in: adjacent, window: window)
        #expect(try mountedWindowHit(for: adjacentDown, in: window) === adjacent)
    }

    private func deliverBadgeMouseClick(
        _ returnButton: NSButton, through surfaces: [GhosttySurfaceView], in window: NSWindow
    ) throws {
        let down = try splitMouseEvent(.leftMouseDown, in: returnButton, window: window)
        let up = try splitMouseEvent(.leftMouseUp, in: returnButton, window: window)
        var routed: NSEvent? = down
        for surface in surfaces {
            let incoming = try #require(routed)
            routed = surface.processLocalEventForTesting(incoming)
            #expect(routed === down)
        }
        let delivered = try #require(routed)
        let hit = try mountedWindowHit(for: delivered, in: window)
        try #require(hit === returnButton || hit.isDescendant(of: returnButton))
        // WHY: A queued release bounds native button tracking without sleeps or performClick bypasses.
        NSApp.postEvent(up, atStart: true)
        hit.mouseDown(with: delivered)
    }

    private func splitMouseEvent(
        _ type: NSEvent.EventType, in view: NSView, window: NSWindow, point: NSPoint? = nil
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point ?? view.bounds.center, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func mountedWindowHit(for event: NSEvent, in window: NSWindow) throws -> NSView {
        let contentView = try #require(window.contentView)
        let point =
            contentView.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        return try #require(contentView.hitTest(point))
    }

    private func makeSplitMonitorWindow() -> NSWindow {
        SplitMonitorTestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func settleWorkspace(
        _ controller: WorkspaceViewController, in window: NSWindow,
        until condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            layoutWorkspace(controller, in: window)
            if condition() { return }
            await Task.yield()
            runMainLoopOnce()
        }
        layoutWorkspace(controller, in: window)
        try #require(condition())
    }

    @Test(arguments: [0.1, 0.9])
    func narrowManagedBadgeClipsToMountedLeafAndPreservesDividerHits(ratio: Double) async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat"))
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        defer { window.orderOut(nil) }
        controller.displayTerminal(
            root: .split(
                id: UUID(), axis: .horizontal, ratio: ratio,
                first: .pane(first.paneID), second: .pane(second.paneID)),
            surfaces: [first.paneID: first, second.paneID: second], failures: [:],
            palette: .fallback, onResize: { _, _ in }, onEqualize: { _ in },
            onRetryUnavailablePane: { _ in }, onCloseUnavailablePane: { _ in })
        await settleWorkspace(controller, in: window)
        let firstFrame = first.convert(first.bounds, to: controller.view)
        let secondFrame = second.convert(second.bounds, to: controller.view)
        let dividerPoint = NSPoint(
            x: (firstFrame.maxX + secondFrame.minX) / 2, y: secondFrame.maxY - 20)
        let dividerHit = try #require(controller.view.hitTest(dividerPoint))
        let surface = ratio < 0.5 ? first : second
        let value = TerminalAutomationPresentation(
            taskID: UUID(), adapterDisplayName: String(repeating: "Long name", count: 100),
            taskState: .waitingForUser, controlOwner: .user, canReturnControl: true)
        controller.refreshTerminalAutomationPresentations([surface.paneID: value])
        await settleWorkspace(controller, in: window)
        let views = mountedViews(in: controller.view)
        let badge = try #require(views.compactMap { $0 as? TerminalAutomationBadgeView }.first)
        let returnButton = try #require(
            button(titled: TerminalAutomationPresentation.returnControlTitle, in: views))
        let paneFrame = surface.convert(surface.bounds, to: controller.view)
        #expect(paneFrame.width < 100)
        #expect(badge.clipsToBounds)
        #expect(badge.convert(badge.bounds, to: controller.view) == paneFrame)
        #expect(paneFrame.contains(returnButton.convert(returnButton.bounds, to: controller.view)))
        let buttonHit = controller.view.hitTest(
            returnButton.convert(returnButton.bounds.center, to: controller.view))
        #expect(buttonHit === returnButton || buttonHit?.isDescendant(of: returnButton) == true)
        #expect(controller.view.hitTest(dividerPoint) === dividerHit)
        let adjacent = surface === first ? second : first
        let adjacentHit = controller.view.hitTest(
            adjacent.convert(adjacent.bounds.center, to: controller.view))
        #expect(adjacentHit === adjacent || adjacentHit?.isDescendant(of: adjacent) == true)
        let escaped = badge.convert(
            NSPoint(x: badge.bounds.minX - 1, y: badge.bounds.midY), to: badge.superview)
        #expect(badge.hitTest(escaped) == nil)
    }

    private func settleWorkspace(_ controller: WorkspaceViewController, in window: NSWindow) async {
        for _ in 0..<4 {
            layoutWorkspace(controller, in: window)
            await Task.yield()
            runMainLoopOnce()
        }
        layoutWorkspace(controller, in: window)
    }

    private func layoutWorkspace(_ controller: WorkspaceViewController, in window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    private func runMainLoopOnce() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func mountWorkspace(
        _ controller: WorkspaceViewController, window suppliedWindow: NSWindow? = nil
    ) -> NSWindow {
        let window =
            suppliedWindow
            ?? NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
        guard let contentView = window.contentView else {
            preconditionFailure("Expected test window content view")
        }
        let controllerView = controller.view
        controllerView.frame = contentView.bounds
        controllerView.autoresizingMask = [.width, .height]
        contentView.addSubview(controllerView)
        contentView.layoutSubtreeIfNeeded()
        controllerView.layoutSubtreeIfNeeded()
        return window
    }

    @Test
    func splitCallbacksKeepSplitAndUnavailablePaneIdentity() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let unavailablePaneID = PaneID()
        var resized: (UUID, Double)?
        var equalized: UUID?
        var retriedPaneID: PaneID?
        var closedPaneID: PaneID?
        let callbacks = GhosttySplitTreeCallbacks(
            onResize: { id, ratio in resized = (id, ratio) },
            onEqualize: { id in equalized = id },
            onRetryUnavailablePane: { retriedPaneID = $0 },
            onCloseUnavailablePane: { closedPaneID = $0 }
        )

        callbacks.resize(splitID, ratio: 0.625)
        callbacks.equalize(splitID)
        callbacks.retryUnavailablePane(unavailablePaneID)
        callbacks.closeUnavailablePane(unavailablePaneID)

        #expect(resized?.0 == splitID)
        #expect(resized?.1 == 0.625)
        #expect(equalized == splitID)
        #expect(retriedPaneID == unavailablePaneID)
        #expect(closedPaneID == unavailablePaneID)
    }

    @Test
    func unavailablePaneMountsPlaceholderAndButtonsRouteItsPaneIdentity() async throws {
        let controller = WorkspaceViewController()
        let paneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let message = "Surface creation failed for this pane."
        let initialPalette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
            foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
        )
        var retriedPaneIDs: [PaneID] = []
        var closedPaneIDs: [PaneID] = []
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(paneID),
            surfaces: [:],
            failures: [paneID: SurfaceFailurePresentation(message: message)],
            palette: initialPalette,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { retriedPaneIDs.append($0) },
            onCloseUnavailablePane: { closedPaneIDs.append($0) }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let splitHostID = try #require(controller.splitHostingControllerIdentifierForTesting)
        var hostedViews = mountedViews(in: splitHost)
        #expect(hostedViews.contains { $0 is SurfaceErrorPlaceholderView })
        #expect(mountedText(in: hostedViews).contains("Terminal unavailable"))
        #expect(mountedText(in: hostedViews).contains(message))
        #expect(buttonTitles(in: hostedViews) == ["Retry", "Close Pane"])

        let replacementPalette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x66, green: 0x55, blue: 0x44),
            foreground: GhosttyRGB(red: 0x30, green: 0xE0, blue: 0x90)
        )
        controller.applyChromePalette(replacementPalette)
        await settleWorkspace(controller, in: window)

        #expect(controller.splitHostingControllerIdentifierForTesting == splitHostID)
        #expect(controller.splitPresentationPaletteForTesting == replacementPalette)
        hostedViews = mountedViews(in: splitHost)
        let placeholder = try #require(
            hostedViews.compactMap { $0 as? SurfaceErrorPlaceholderView }.first
        )
        let placeholderBackground = try #require(placeholder.layer?.backgroundColor)
        #expect(
            colorsMatch(
                NSColor(cgColor: placeholderBackground),
                NSColor(ghosttyRGB: replacementPalette.background)
            )
        )
        let retryButton = try #require(button(titled: "Retry", in: hostedViews))
        let closeButton = try #require(button(titled: "Close Pane", in: hostedViews))
        #expect(retryButton.accessibilityLabel() == "Retry")
        #expect(closeButton.accessibilityLabel() == "Close Pane")
        #expect(
            colorsMatch(
                retryButton.contentTintColor,
                NSColor(ghosttyRGB: replacementPalette.foreground)
            )
        )
        #expect(
            colorsMatch(
                closeButton.contentTintColor,
                NSColor(ghosttyRGB: replacementPalette.foreground)
            )
        )

        for button in [retryButton, closeButton] {
            let hitPoint = button.convert(button.bounds.center, to: controller.view)
            let hitView = controller.view.hitTest(hitPoint)
            #expect(hitView === button || hitView?.isDescendant(of: button) == true)
        }

        retryButton.performClick(nil)
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs.isEmpty)
        closeButton.performClick(nil)
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs == [paneID])
        #expect(controller.hostedSurfaceIdentifiersForTesting.isEmpty)
        #expect(!controller.emptyWorkspaceLabelIsVisibleForTesting)
    }

    @Test
    func placeholderAppliesCustomPaletteToAllVisibleControls() throws {
        let palette = GhosttyChromePalette(
            background: GhosttyRGB(red: 17, green: 49, blue: 83),
            foreground: GhosttyRGB(red: 211, green: 187, blue: 149)
        )
        let message = "Surface creation failed for this pane."
        let placeholder = SurfaceErrorPlaceholderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )

        placeholder.apply(
            presentation: SurfaceFailurePresentation(message: message),
            palette: palette,
            onRetry: {},
            onClosePane: {}
        )
        placeholder.layoutSubtreeIfNeeded()

        let views = mountedViews(in: placeholder)
        let expectedBackground = NSColor(ghosttyRGB: palette.background)
        let expectedForeground = NSColor(ghosttyRGB: palette.foreground)
        let backgroundColor = try #require(placeholder.layer?.backgroundColor)
        let titleLabel = try #require(textField(with: "Terminal unavailable", in: views))
        let messageLabel = try #require(textField(with: message, in: views))
        let retryButton = try #require(button(titled: "Retry", in: views))
        let closeButton = try #require(button(titled: "Close Pane", in: views))

        #expect(colorsMatch(NSColor(cgColor: backgroundColor), expectedBackground))
        #expect(colorsMatch(titleLabel.textColor, expectedForeground))
        #expect(colorsMatch(messageLabel.textColor, expectedForeground))
        #expect(colorsMatch(retryButton.contentTintColor, expectedForeground))
        #expect(colorsMatch(closeButton.contentTintColor, expectedForeground))
    }

    @Test
    func tinyPlaceholderScrollsToBothPaneActionsAndRestoresAfterResize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)
        let placeholder = SurfaceErrorPlaceholderView(
            frame: NSRect(x: 0, y: 0, width: 80, height: 60)
        )
        let adjacentLeaf = NSView(frame: NSRect(x: 80, y: 0, width: 720, height: 600))
        host.addSubview(placeholder)
        host.addSubview(adjacentLeaf)

        let paneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let message = "Surface creation failed for this pane."
        var retriedPaneIDs: [PaneID] = []
        var closedPaneIDs: [PaneID] = []
        let callbacks = GhosttySplitTreeCallbacks(
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { retriedPaneIDs.append($0) },
            onCloseUnavailablePane: { closedPaneIDs.append($0) }
        )
        placeholder.apply(
            presentation: SurfaceFailurePresentation(message: message),
            palette: .fallback,
            onRetry: { callbacks.retryUnavailablePane(paneID) },
            onClosePane: { callbacks.closeUnavailablePane(paneID) }
        )
        host.layoutSubtreeIfNeeded()
        placeholder.layoutSubtreeIfNeeded()

        var views = mountedViews(in: placeholder)
        let scrollView = try #require(views.compactMap { $0 as? NSScrollView }.first)
        let retryButton = try #require(button(titled: "Retry", in: views))
        let closeButton = try #require(button(titled: "Close Pane", in: views))
        #expect(buttonTitles(in: views) == ["Retry", "Close Pane"])
        #expect(placeholder.clipsToBounds)
        #expect(scrollView.contentView.clipsToBounds)
        #expect(scrollView.frame == placeholder.bounds)
        for view in views {
            #expect(!view.hasAmbiguousLayout)
            #expect(hasFiniteNonnegativeSize(view))
        }
        #expect(mountedText(in: views).contains("Terminal unavailable"))
        #expect(mountedText(in: views).contains(message))
        #expect(retryButton.accessibilityLabel() == "Retry")
        #expect(closeButton.accessibilityLabel() == "Close Pane")

        let documentView = try #require(scrollView.documentView)
        let clipView = scrollView.contentView
        let viewport = clipView.bounds
        #expect(documentView.frame.width > viewport.width)
        #expect(documentView.frame.height > viewport.height)
        #expect(documentView.bounds.contains(scrollView.documentVisibleRect))
        #expect(scrollView.documentVisibleRect.width <= viewport.width)
        #expect(scrollView.documentVisibleRect.height <= viewport.height)

        for button in [retryButton, closeButton] {
            let buttonFrame = button.convert(button.bounds, to: documentView)
            let maximumOrigin = NSPoint(
                x: documentView.frame.width - clipView.bounds.width,
                y: documentView.frame.height - clipView.bounds.height
            )
            clipView.scroll(
                to: NSPoint(
                    x: buttonFrame.midX < documentView.bounds.midX ? maximumOrigin.x : 0,
                    y: 0
                )
            )
            scrollView.reflectScrolledClipView(clipView)
            #expect(!scrollView.documentVisibleRect.contains(buttonFrame.center))

            clipView.scroll(
                to: NSPoint(
                    x: min(max(0, buttonFrame.midX - (clipView.bounds.width / 2)), maximumOrigin.x),
                    y: min(max(0, buttonFrame.midY - (clipView.bounds.height / 2)), maximumOrigin.y)
                )
            )
            scrollView.reflectScrolledClipView(clipView)

            #expect(scrollView.documentVisibleRect.contains(buttonFrame.center))
            let pointInHost = button.convert(button.bounds.center, to: host)
            let hitView = host.hitTest(pointInHost)
            #expect(hitView === button || hitView?.isDescendant(of: button) == true)
            button.performClick(nil)
        }
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs == [paneID])

        let pointOverAdjacentLeaf = NSPoint(x: adjacentLeaf.frame.minX + 1, y: 30)
        #expect(!placeholder.frame.contains(pointOverAdjacentLeaf))
        let outsideHit = host.hitTest(pointOverAdjacentLeaf)
        #expect(
            outsideHit === adjacentLeaf
                || outsideHit?.isDescendant(of: adjacentLeaf) == true
        )

        placeholder.frame.size = NSSize(width: 640, height: 320)
        adjacentLeaf.frame = NSRect(x: 640, y: 0, width: 160, height: 600)
        host.layoutSubtreeIfNeeded()
        placeholder.layoutSubtreeIfNeeded()
        views = mountedViews(in: placeholder)
        for view in views {
            #expect(!view.hasAmbiguousLayout)
            #expect(hasFiniteNonnegativeSize(view))
        }
        for button in [retryButton, closeButton] {
            let frame = button.convert(button.bounds, to: placeholder)
            #expect(placeholder.bounds.contains(frame))
            let point = button.convert(button.bounds.center, to: host)
            let hitView = host.hitTest(point)
            #expect(hitView === button || hitView?.isDescendant(of: button) == true)
        }
    }

    @Test
    func placeholderMatchesDefaultAppKitHitTestingInAllHostConfigurations() throws {
        let leafFrame = NSRect(x: 700, y: 500, width: 640, height: 320)
        for host in [
            NSView(frame: NSRect(x: 0, y: 0, width: 1_500, height: 1_200)),
            FlippedHitTestHostView(frame: NSRect(x: 0, y: 0, width: 1_500, height: 1_200)),
        ] {
            let defaultLeaf = NSView(frame: leafFrame)
            host.addSubview(defaultLeaf)
            let insideLeaf = NSPoint(x: leafFrame.midX, y: leafFrame.midY)
            let outsideLeaf = NSPoint(x: leafFrame.minX - 1, y: leafFrame.midY)
            #expect(defaultLeaf.hitTest(insideLeaf) === defaultLeaf)
            #expect(defaultLeaf.hitTest(outsideLeaf) == nil)
            defaultLeaf.removeFromSuperview()

            let placeholder = SurfaceErrorPlaceholderView(frame: leafFrame)
            placeholder.apply(
                presentation: SurfaceFailurePresentation(message: "Surface creation failed."),
                palette: .fallback,
                onRetry: {},
                onClosePane: {}
            )
            host.addSubview(placeholder)
            host.layoutSubtreeIfNeeded()
            placeholder.layoutSubtreeIfNeeded()

            let views = mountedViews(in: placeholder)
            let retryButton = try #require(button(titled: "Retry", in: views))
            let closeButton = try #require(button(titled: "Close Pane", in: views))
            for button in [retryButton, closeButton] {
                let pointInHost = button.convert(button.bounds.center, to: host)
                let hitView = placeholder.hitTest(pointInHost)
                #expect(hitView === button || hitView?.isDescendant(of: button) == true)
            }
            #expect(placeholder.hitTest(outsideLeaf) == nil)
        }

        let defaultDetachedLeaf = NSView(frame: leafFrame)
        let detachedPlaceholder = SurfaceErrorPlaceholderView(frame: leafFrame)
        detachedPlaceholder.layoutSubtreeIfNeeded()
        let insideDetachedLeaf = NSPoint(x: leafFrame.midX, y: leafFrame.midY)
        let outsideDetachedLeaf = NSPoint(x: leafFrame.minX - 1, y: leafFrame.midY)
        #expect(defaultDetachedLeaf.hitTest(insideDetachedLeaf) === defaultDetachedLeaf)
        #expect(defaultDetachedLeaf.hitTest(outsideDetachedLeaf) == nil)
        #expect(detachedPlaceholder.hitTest(insideDetachedLeaf) != nil)
        #expect(detachedPlaceholder.hitTest(outsideDetachedLeaf) == nil)
    }

    @Test
    func liveSurfaceTakesPriorityOverFailureForTheSamePane() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        let controller = WorkspaceViewController()
        let message = "This failure must not replace a live terminal."
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(surface.paneID),
            surfaces: [surface.paneID: surface],
            failures: [surface.paneID: SurfaceFailurePresentation(message: message)],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let mountedViews = mountedViews(in: splitHost)
        let renderedSurfaces = mountedViews.compactMap { $0 as? GhosttySurfaceView }
        #expect(renderedSurfaces.map(ObjectIdentifier.init) == [ObjectIdentifier(surface)])
        #expect(!mountedViews.contains { $0 is SurfaceErrorPlaceholderView })
        #expect(!mountedText(in: mountedViews).contains("Terminal unavailable"))
        #expect(!mountedText(in: mountedViews).contains(message))
        #expect(button(titled: "Retry", in: mountedViews) == nil)
        #expect(button(titled: "Close Pane", in: mountedViews) == nil)
    }

    @Test
    func missingLeafPreservesSplitHostAndOnlyNilRootShowsEmptyWorkspace() throws {
        let controller = WorkspaceViewController()
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(
            root: .pane(firstPaneID),
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        let originalHost = try #require(controller.splitHostingControllerIdentifierForTesting)

        controller.displayTerminal(
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(firstPaneID),
                second: .pane(secondPaneID)
            ),
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == originalHost)
        #expect(!controller.emptyWorkspaceLabelIsVisibleForTesting)

        controller.displayTerminal(
            root: nil,
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == nil)
        #expect(controller.emptyWorkspaceLabelIsVisibleForTesting)
    }

    @Test
    func agentResumePlaceholderUsesBoundedRedactedCopyAndRoutesRetryAndForget() async throws {
        let controller = WorkspaceViewController()
        let paneID = PaneID()
        let presentation = AgentResumePresentation.failed(diagnosticCode: .immediateExit)
        let sensitiveSentinels = [
            "session-sensitive-123",
            "/Users/private/project",
            "--resume session-sensitive-123",
            "/usr/local/bin/agent",
            String(repeating: "ab", count: 32),
        ]
        var retriedPaneIDs: [PaneID] = []
        var forgottenPaneIDs: [PaneID] = []
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(paneID),
            surfaces: [:],
            failures: [:],
            agentResumePresentations: [paneID: presentation],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in },
            onRetryAgentResume: { retriedPaneIDs.append($0) },
            onForgetAgentResume: { forgottenPaneIDs.append($0) }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let views = mountedViews(in: splitHost)
        let placeholder = try #require(
            views.compactMap { $0 as? SurfaceErrorPlaceholderView }.first
        )
        let renderedText = mountedText(in: views)
        let retryButton = try #require(button(titled: "Retry Resume", in: views))
        let forgetButton = try #require(button(titled: "Forget Agent Session", in: views))
        let accessibilityStrings = [
            placeholder.accessibilityLabel() ?? "",
            placeholder.accessibilityValue() as? String ?? "",
            retryButton.accessibilityLabel() ?? "",
            forgetButton.accessibilityLabel() ?? "",
        ]

        #expect(renderedText.contains(presentation.title))
        #expect(renderedText.contains(presentation.message))
        #expect(retryButton.accessibilityLabel() == "Retry Resume")
        #expect(forgetButton.accessibilityLabel() == "Forget Agent Session")
        #expect(
            (Array(renderedText) + accessibilityStrings).allSatisfy {
                $0.utf8.count <= AgentResumePresentation.maximumCopyBytes
            }
        )
        for sentinel in sensitiveSentinels {
            #expect(
                (Array(renderedText) + accessibilityStrings).allSatisfy { !$0.contains(sentinel) })
        }

        retryButton.performClick(nil)
        forgetButton.performClick(nil)
        #expect(retriedPaneIDs == [paneID])
        #expect(forgottenPaneIDs == [paneID])
    }

    @Test
    func liveSurfaceTakesPriorityOverAgentResumePresentation() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(surface.paneID),
            surfaces: [surface.paneID: surface],
            failures: [:],
            agentResumePresentations: [
                surface.paneID: .failed(diagnosticCode: .immediateExit)
            ],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in },
            onRetryAgentResume: { _ in },
            onForgetAgentResume: { _ in }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let views = mountedViews(in: splitHost)
        #expect(
            views.compactMap { $0 as? GhosttySurfaceView }.map(ObjectIdentifier.init)
                == [ObjectIdentifier(surface)]
        )
        #expect(!views.contains { $0 is SurfaceErrorPlaceholderView })
        #expect(button(titled: "Retry Resume", in: views) == nil)
        #expect(button(titled: "Forget Agent Session", in: views) == nil)
    }
}

@MainActor
private func mountedViews(in rootView: NSView) -> [NSView] {
    [rootView] + rootView.subviews.flatMap(mountedViews)
}

@MainActor
private func mountedText(in views: [NSView]) -> Set<String> {
    Set(views.compactMap { ($0 as? NSTextField)?.stringValue })
}

@MainActor
private func textField(with value: String, in views: [NSView]) -> NSTextField? {
    views.compactMap { $0 as? NSTextField }.first { $0.stringValue == value }
}

@MainActor
private func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard
        let lhs = lhs?.usingColorSpace(.deviceRGB),
        let rhs = rhs.usingColorSpace(.deviceRGB)
    else {
        return false
    }
    let tolerance = CGFloat(1) / 255
    return abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
}

@MainActor
private func button(titled title: String, in views: [NSView]) -> NSButton? {
    views.compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func buttonTitles(in views: [NSView]) -> Set<String> {
    Set(views.compactMap { ($0 as? NSButton)?.title })
}

@MainActor
private final class SplitMonitorTestWindow: NSWindow {
    // WHY: Exercise active-app focus consumption without activating the test runner's application.
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class FlippedHitTestHostView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func hasFiniteNonnegativeSize(_ view: NSView) -> Bool {
    let frame = view.frame
    return frame.origin.x.isFinite && frame.origin.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.width >= 0 && frame.height >= 0
}

extension NSRect {
    fileprivate var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private func requireSendable<T: Sendable>(_: T) {}

private enum SizeSensitiveChildError: Error {
    case fifoCreationFailed(Int32)
    case childProcessFailed(Int32)
    case eventStreamEnded
    case timeout
}

@MainActor
private final class SizeSensitiveChildFixture {
    let directoryURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        readyFIFOURL = directoryURL.appending(path: "ready.fifo")
        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw SizeSensitiveChildError.fifoCreationFailed(errno)
        }

        let scriptURL = directoryURL.appending(path: "size-sensitive-child")
        let script = """
            #!/bin/sh
            check_size() {
                set -- $(stty size)
                [ "$#" -eq 2 ] && [ "$1" -ge 2 ] && [ "$2" -ge 5 ] || exit 91
            }
            trap 'check_size' WINCH
            printf R > \(shellQuoteSizeSensitiveChild(readyFIFOURL.path))
            while :; do
                sleep 1 &
                wait $!
            done
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        command = "/bin/sh \(shellQuoteSizeSensitiveChild(scriptURL.path))"

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
        let status = try await firstSizeSensitiveChildExit(
            from: readyExits,
            timeout: timeout
        )
        guard status == 0 else {
            throw SizeSensitiveChildError.childProcessFailed(status)
        }
        guard readyOutput.fileHandleForReading.readDataToEndOfFile() == Data("R".utf8) else {
            throw SizeSensitiveChildError.childProcessFailed(status)
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

private func firstSizeSensitiveChildExit(
    from stream: AsyncStream<Int32>,
    timeout: Duration
) async throws -> Int32 {
    try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
            for await status in stream {
                return status
            }
            throw SizeSensitiveChildError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SizeSensitiveChildError.timeout
        }

        guard let status = try await group.next() else {
            throw SizeSensitiveChildError.eventStreamEnded
        }
        group.cancelAll()
        return status
    }
}

private func shellQuoteSizeSensitiveChild(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
