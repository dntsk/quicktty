import AppKit
import Foundation
import GhosttyKit
import Synchronization

#if DEBUG
    struct GhosttyBridgeInputObservation: Equatable {
        let paneID: PaneID
        let eventIdentifier: ObjectIdentifier
        let wasProcessed: Bool
    }
#endif

#if DEBUG
    private let ghosttyCallbackContextOwnershipCount = Mutex(0)
#endif

struct GhosttySurfaceAccess {
    fileprivate init() {}
}

private func makeGhosttyRuntimeConfiguration(
    userdata: UnsafeMutableRawPointer
) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
        userdata: userdata,
        supports_selection_clipboard: true,
        wakeup_cb: ghosttyRuntimeWakeupCallback,
        action_cb: ghosttyRuntimeActionCallback,
        read_clipboard_cb: ghosttyRuntimeReadClipboardCallback,
        confirm_read_clipboard_cb: ghosttyRuntimeConfirmReadClipboardCallback,
        write_clipboard_cb: ghosttyRuntimeWriteClipboardCallback,
        close_surface_cb: ghosttyRuntimeCloseSurfaceCallback
    )
}

private func ghosttyRuntimeWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let context = Unmanaged<GhosttyBridge.CallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.scheduleTick()
}

private func ghosttyRuntimeActionCallback(
    _ application: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    if action.tag == GHOSTTY_ACTION_MOUSE_SHAPE,
        target.tag == GHOSTTY_TARGET_SURFACE,
        let surface = target.target.surface,
        let userdata = ghostty_surface_userdata(surface)
    {
        let context = Unmanaged<SurfaceCallbackContext>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        return context.scheduleMouseShape(
            GhosttyMouseShape(cValue: action.action.mouse_shape)
        )
    }

    if action.tag == GHOSTTY_ACTION_PWD,
        target.tag == GHOSTTY_TARGET_SURFACE,
        let surface = target.target.surface,
        let userdata = ghostty_surface_userdata(surface),
        let pwd = action.action.pwd.pwd,
        let workingDirectory = String(validatingCString: pwd)
    {
        let context = Unmanaged<SurfaceCallbackContext>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        return context.scheduleWorkingDirectoryChange(workingDirectory)
    }

    guard let application,
        let userdata = ghostty_app_userdata(application)
    else { return false }

    let context = Unmanaged<GhosttyBridge.CallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    let stableAction = GhosttyBridge.runtimeAction(from: action)
    return context.handleRuntimeAction(
        stableAction,
        from: application,
        deliveryCompletion: nil
    )
}

#if DEBUG
    func ghosttyRuntimeMouseShapeCallbackForTesting(
        surface: ghostty_surface_t,
        rawValue: Int32
    ) -> Bool {
        var targetValue = ghostty_target_u()
        targetValue.surface = surface
        var payload = ghostty_action_u()
        payload.mouse_shape = ghostty_action_mouse_shape_e(
            rawValue: UInt32(bitPattern: rawValue)
        )
        return ghosttyRuntimeActionCallback(
            nil,
            ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: targetValue),
            ghostty_action_s(tag: GHOSTTY_ACTION_MOUSE_SHAPE, action: payload)
        )
    }
#endif

private func ghosttyRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata,
        let state,
        let location = GhosttyClipboardLocation(cValue: location)
    else { return false }

    let context = Unmanaged<SurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    return context.registerClipboardRead(
        token: UInt(bitPattern: state),
        location: location
    )
}

private func ghosttyRuntimeConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata,
        let string,
        let state,
        let kind = GhosttyClipboardConfirmationKind(cValue: request)
    else { return }

    let data = String(cString: string)
    let context = Unmanaged<SurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.registerClipboardReadConfirmation(
        token: UInt(bitPattern: state),
        data: data,
        kind: kind
    )
}

private func ghosttyRuntimeWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard let userdata,
        let location = GhosttyClipboardLocation(cValue: location),
        let content,
        count > 0
    else { return }

    let contents = GhosttyClipboardContent.copying(content, count: count)
    guard !contents.isEmpty else { return }

    let context = Unmanaged<SurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    if confirm {
        context.registerClipboardWriteConfirmation(
            location: location,
            contents: contents
        )
    } else {
        context.scheduleClipboardWrite(location: location, contents: contents)
    }
}

@MainActor
final class GhosttyBridge {
    typealias RuntimeActionHandler = @MainActor @Sendable (GhosttyRuntimeAction) -> Void
    typealias RuntimeActionDeliveryCompletion = @MainActor @Sendable (Bool) -> Void
    typealias SurfaceCloseHandler = GhosttySurfaceCloseHandler
    typealias SurfaceFocusHandler = @MainActor (PaneID) -> Void
    typealias SurfaceWorkingDirectoryHandler = @MainActor (PaneID, String) -> Void
    typealias InputTargetProvider = @MainActor (PaneID) -> [PaneID]

    private static let runtimeBootstrapResult =
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS

    private let applicationIsActive: @MainActor () -> Bool
    private let clipboardClient: GhosttyClipboardClient
    private var configuration: GhosttyConfiguration?
    private var shortcutConfiguration: ShortcutConfiguration
    private var application: ghostty_app_t?
    private var callbackContextOwnership: Unmanaged<CallbackContext>?
    private var surfaces: [PaneID: GhosttySurfaceView] = [:]
    private var surfaceCloseHandlers: [PaneID: SurfaceCloseHandler] = [:]

    var clipboardConfirmationHandler: GhosttyClipboardConfirmationHandler?
    var surfaceFocusHandler: SurfaceFocusHandler?
    var surfaceWorkingDirectoryHandler: SurfaceWorkingDirectoryHandler?
    var inputTargetProvider: InputTargetProvider = { [$0] }

    #if DEBUG
        private var inputObservations: [GhosttyBridgeInputObservation] = []
        private var successfulSurfaceCloseObservations: [PaneID] = []
        private var surfaceConfigurationsForTesting: [PaneID: GhosttySurfaceConfiguration] = [:]
        private var terminalActionResultsForTesting: [TerminalShortcutAction: Bool] = [:]
        private var failsNextSurfaceCreationForTesting = false
        private var failingSurfaceCreationPaneIDForTesting: PaneID?
    #endif

    private(set) var diagnostics: [String]
    private(set) var chromePalette: GhosttyChromePalette

    var isReady: Bool {
        application != nil
    }

    var activeSurfaceIDs: [PaneID] {
        surfaces.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    var activeSurfaceCount: Int {
        surfaces.count
    }

    var latestWorkingDirectoriesForPersistence: [PaneID: String] {
        Dictionary(
            uniqueKeysWithValues: surfaces.compactMap { paneID, surface in
                surface.latestWorkingDirectoryForPersistence.map { (paneID, $0) }
            }
        )
    }

    init(
        configURL: URL? = nil,
        shortcutConfiguration: ShortcutConfiguration = .defaults,
        runtimeActionHandler: RuntimeActionHandler? = nil,
        workspaceURLClient: GhosttyWorkspaceURLClient = .system,
        clipboardClient: GhosttyClipboardClient = .system,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) throws {
        let configuration = try GhosttyConfiguration(configURL: configURL)
        let callbackContext = CallbackContext(
            runtimeActionHandler: runtimeActionHandler,
            workspaceURLClient: workspaceURLClient
        )
        let retainedCallbackContext = Unmanaged.passRetained(callbackContext)

        self.applicationIsActive = applicationIsActive
        self.clipboardClient = clipboardClient
        self.configuration = configuration
        self.shortcutConfiguration = shortcutConfiguration
        application = nil
        callbackContextOwnership = retainedCallbackContext
        diagnostics = configuration.diagnostics
        chromePalette = configuration.chromePalette

        #if DEBUG
            ghosttyCallbackContextOwnershipCount.withLock { count in
                count += 1
            }
        #endif

        var runtimeConfiguration = makeGhosttyRuntimeConfiguration(
            userdata: retainedCallbackContext.toOpaque()
        )

        var newApplication: ghostty_app_t?
        configuration.withHandle { handle in
            newApplication = ghostty_app_new(&runtimeConfiguration, handle)
        }

        guard let newApplication else {
            releaseCallbackContextOwnership()
            configuration.release()
            self.configuration = nil
            throw GhosttyBridgeError.applicationCreationFailed
        }

        application = newApplication
        callbackContext.activate(application: newApplication)
    }

    isolated deinit {
        tearDownRuntime()
    }

    static func bootstrapRuntime() -> Bool {
        runtimeBootstrapResult
    }

    func tick() {
        guard let application else { return }
        ghostty_app_tick(application)
    }

    func setApplicationFocused(_ focused: Bool) {
        guard let application else { return }
        ghostty_app_set_focus(application, focused)
    }

    func makeSurface(
        id: PaneID = PaneID(),
        configuration: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration(),
        closeHandler: SurfaceCloseHandler? = nil
    ) throws -> GhosttySurfaceView {
        guard let application else {
            throw GhosttyBridgeError.runtimeNotReady
        }
        guard surfaces[id] == nil else {
            throw GhosttyBridgeError.duplicatePaneID(id)
        }

        #if DEBUG
            if failsNextSurfaceCreationForTesting
                || failingSurfaceCreationPaneIDForTesting == id
            {
                failsNextSurfaceCreationForTesting = false
                failingSurfaceCreationPaneIDForTesting = nil
                throw GhosttyBridgeError.surfaceCreationFailed(id)
            }
        #endif

        guard
            let surface = GhosttySurfaceView(
                application: application,
                paneID: id,
                configuration: configuration,
                access: GhosttySurfaceAccess(),
                applicationIsActive: applicationIsActive,
                inputRoute: { [weak self] paneID, event in
                    self?.routeInput(event, from: paneID)
                },
                focusRoute: { [weak self] paneID in
                    self?.routeSurfaceFocus(from: paneID)
                },
                shortcutRoute: { [weak self] paneID, event in
                    self?.routeShortcut(event, from: paneID) ?? .unmatched
                },
                terminalActionRoute: { [weak self] paneID, action in
                    self?.routeTerminalShortcutAction(action, from: paneID) ?? false
                },
                clipboardClient: clipboardClient,
                callbackRoute: { [weak self] paneID, event in
                    self?.routeSurfaceCallback(event, from: paneID)
                },
                clipboardInvalidationRoute: { [weak self] paneID in
                    self?.clipboardConfirmationHandler?(.invalidate(paneID))
                }
            )
        else {
            throw GhosttyBridgeError.surfaceCreationFailed(id)
        }

        surfaces[id] = surface
        surfaceCloseHandlers[id] = closeHandler

        #if DEBUG
            surfaceConfigurationsForTesting[id] = configuration
        #endif

        return surface
    }

    func applyShortcutConfiguration(_ configuration: ShortcutConfiguration) {
        shortcutConfiguration = configuration
    }

    func closeSurface(id: PaneID) {
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        surfaceCloseHandlers.removeValue(forKey: id)

        #if DEBUG
            if successfulSurfaceCloseObservations.count < 64 {
                successfulSurfaceCloseObservations.append(id)
            }
            surfaceConfigurationsForTesting.removeValue(forKey: id)
        #endif

        surface.close()
    }

    func surfaceNeedsConfirmQuit(id: PaneID) -> Bool {
        surfaces[id]?.needsConfirmQuit() ?? false
    }

    func reloadConfig(at configURL: URL) throws {
        guard let application else {
            throw GhosttyBridgeError.runtimeNotReady
        }

        let replacement = try GhosttyConfiguration(configURL: configURL)
        guard replacement.diagnostics.isEmpty else {
            diagnostics = replacement.diagnostics
            replacement.release()
            throw GhosttyBridgeError.invalidConfiguration(diagnostics)
        }

        replacement.withHandle { handle in
            ghostty_app_update_config(application, handle)
        }

        diagnostics = []
        chromePalette = replacement.chromePalette
        configuration?.release()
        configuration = replacement
    }

    func shutdown() {
        tearDownRuntime()
    }

    static var supportsSelectionClipboard: Bool {
        true
    }

    static var clipboardABIMatchesPinnedHeader: Bool {
        let locations = [
            GHOSTTY_CLIPBOARD_STANDARD.rawValue,
            GHOSTTY_CLIPBOARD_SELECTION.rawValue,
        ]
        let requests = [
            GHOSTTY_CLIPBOARD_REQUEST_PASTE.rawValue,
            GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ.rawValue,
            GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE.rawValue,
        ]
        return locations == [0, 1] && requests == [0, 1, 2]
    }

    static var runtimeActionTagsMatchPinnedHeader: Bool {
        let actual: [UInt32] = [
            UInt32(GHOSTTY_ACTION_QUIT.rawValue),
            UInt32(GHOSTTY_ACTION_NEW_WINDOW.rawValue),
            UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue),
            UInt32(GHOSTTY_ACTION_CLOSE_ALL_WINDOWS.rawValue),
            UInt32(GHOSTTY_ACTION_TOGGLE_VISIBILITY.rawValue),
            UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
            UInt32(GHOSTTY_ACTION_OPEN_CONFIG.rawValue),
            UInt32(GHOSTTY_ACTION_RELOAD_CONFIG.rawValue),
            UInt32(GHOSTTY_ACTION_CONFIG_CHANGE.rawValue),
            UInt32(GHOSTTY_ACTION_OPEN_URL.rawValue),
            UInt32(GHOSTTY_ACTION_SHOW_CHILD_EXITED.rawValue),
        ]
        return actual == [0, 1, 2, 5, 12, 36, 40, 47, 48, 54, 55]
    }

    #if DEBUG
        static var callbackContextCountForTesting: Int {
            ghosttyCallbackContextOwnershipCount.withLock { $0 }
        }

        static var surfaceCallbackContextCountForTesting: Int {
            GhosttySurfaceView.callbackContextCountForTesting
        }

        var inputObservationsForTesting: [GhosttyBridgeInputObservation] {
            inputObservations
        }

        var shortcutConfigurationForTesting: ShortcutConfiguration {
            shortcutConfiguration
        }

        var successfulSurfaceCloseObservationsForTesting: [PaneID] {
            successfulSurfaceCloseObservations
        }

        func surfaceConfigurationForTesting(id: PaneID) -> GhosttySurfaceConfiguration? {
            surfaceConfigurationsForTesting[id]
        }

        func setTerminalActionResultForTesting(
            _ result: Bool,
            for action: TerminalShortcutAction
        ) {
            terminalActionResultsForTesting[action] = result
        }

        func failNextSurfaceCreationForTesting() {
            failsNextSurfaceCreationForTesting = true
        }

        func failSurfaceCreationForTesting(id: PaneID) {
            failingSurfaceCreationPaneIDForTesting = id
        }

        static func runtimeReloadActionForTesting(soft: Bool) -> GhosttyRuntimeAction {
            var payload = ghostty_action_u()
            payload.reload_config = ghostty_action_reload_config_s(soft: soft)
            return runtimeAction(
                from: ghostty_action_s(
                    tag: GHOSTTY_ACTION_RELOAD_CONFIG,
                    action: payload
                )
            )
        }

        static func runtimeOpenURLActionForTesting(
            bytes: inout [UInt8],
            kind: GhosttyOpenURL.Kind
        ) -> GhosttyRuntimeAction {
            bytes.withUnsafeBufferPointer { buffer in
                let cKind: ghostty_action_open_url_kind_e =
                    switch kind {
                    case .unknown: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
                    case .text: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
                    case .html: GHOSTTY_ACTION_OPEN_URL_KIND_HTML
                    }
                var payload = ghostty_action_u()
                payload.open_url = ghostty_action_open_url_s(
                    kind: cKind,
                    url: buffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
                    },
                    len: UInt(buffer.count)
                )
                return runtimeAction(
                    from: ghostty_action_s(
                        tag: GHOSTTY_ACTION_OPEN_URL,
                        action: payload
                    )
                )
            }
        }

        static func copyScopedClipboardContentsForTesting(
            _ contents: [GhosttyClipboardContent]
        ) -> [GhosttyClipboardContent] {
            var scopedContents: [ghostty_clipboard_content_s] = []
            return withScopedClipboardContents(
                contents,
                at: contents.startIndex,
                scopedContents: &scopedContents
            ) { values in
                guard let baseAddress = values.baseAddress else { return [] }
                return GhosttyClipboardContent.copying(
                    baseAddress,
                    count: values.count
                )
            }
        }

        private static func withScopedClipboardContents<Result>(
            _ contents: [GhosttyClipboardContent],
            at index: Int,
            scopedContents: inout [ghostty_clipboard_content_s],
            _ body: (UnsafeBufferPointer<ghostty_clipboard_content_s>) -> Result
        ) -> Result {
            guard index < contents.endIndex else {
                return scopedContents.withUnsafeBufferPointer(body)
            }

            let content = contents[index]
            return content.mime.withCString { mime in
                content.data.withCString { data in
                    scopedContents.append(
                        ghostty_clipboard_content_s(mime: mime, data: data)
                    )
                    defer { scopedContents.removeLast() }
                    return withScopedClipboardContents(
                        contents,
                        at: contents.index(after: index),
                        scopedContents: &scopedContents,
                        body
                    )
                }
            }
        }

        func scheduleRuntimeActionForTesting(
            _ action: GhosttyRuntimeAction,
            deliveryCompletion: RuntimeActionDeliveryCompletion? = nil
        ) -> Bool {
            guard let application,
                let callbackContext = callbackContextOwnership?.takeUnretainedValue()
            else { return false }

            return callbackContext.handleRuntimeAction(
                action,
                from: application,
                deliveryCompletion: deliveryCompletion
            )
        }
    #endif

    fileprivate nonisolated static func runtimeAction(
        from action: ghostty_action_s
    ) -> GhosttyRuntimeAction {
        let tagRawValue = UInt32(action.tag.rawValue)

        switch tagRawValue {
        case UInt32(GHOSTTY_ACTION_QUIT.rawValue):
            return .quit
        case UInt32(GHOSTTY_ACTION_NEW_WINDOW.rawValue):
            return .newWindow
        case UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue):
            return .newTab
        case UInt32(GHOSTTY_ACTION_CLOSE_ALL_WINDOWS.rawValue):
            return .closeAllWindows
        case UInt32(GHOSTTY_ACTION_TOGGLE_VISIBILITY.rawValue):
            return .toggleVisibility
        case UInt32(GHOSTTY_ACTION_OPEN_CONFIG.rawValue):
            return .openConfig
        case UInt32(GHOSTTY_ACTION_RELOAD_CONFIG.rawValue):
            return .reloadConfig(soft: action.action.reload_config.soft)
        case UInt32(GHOSTTY_ACTION_CONFIG_CHANGE.rawValue):
            // The callback-scoped config handle intentionally stays inside the bridge.
            return .configChanged
        case UInt32(GHOSTTY_ACTION_OPEN_URL.rawValue):
            let openURL = action.action.open_url
            guard openURL.len > 0,
                openURL.len <= UInt(Int.max),
                let bytes = openURL.url
            else { return .unknown(rawValue: tagRawValue) }

            let data = Data(bytes: bytes, count: Int(openURL.len))
            guard let url = String(data: data, encoding: .utf8), !url.isEmpty else {
                return .unknown(rawValue: tagRawValue)
            }
            let kind: GhosttyOpenURL.Kind =
                switch openURL.kind {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: .html
                default: .unknown
                }
            return .openURL(GhosttyOpenURL(kind: kind, url: url))
        case UInt32(GHOSTTY_ACTION_SHOW_CHILD_EXITED.rawValue):
            return .showChildExited
        default:
            return .unknown(rawValue: tagRawValue)
        }
    }

    private func routeSurfaceFocus(from paneID: PaneID) {
        guard surfaces[paneID] != nil else { return }
        surfaceFocusHandler?(paneID)
    }

    private func routeSurfaceCallback(
        _ event: GhosttySurfaceCallbackEvent,
        from paneID: PaneID
    ) {
        guard let surface = surfaces[paneID] else { return }
        switch event {
        case .close(let processAlive):
            surfaceDidRequestClose(id: paneID, processAlive: processAlive)
        case .pwdChanged(let workingDirectory):
            surface.processCallbackEvent(
                event,
                confirmationHandler: clipboardConfirmationHandler
            )
            surfaceWorkingDirectoryHandler?(paneID, workingDirectory)
        default:
            surface.processCallbackEvent(
                event,
                confirmationHandler: clipboardConfirmationHandler
            )
        }
    }

    private func routeInput(_ event: NSEvent, from paneID: PaneID) {
        let targetPaneIDs = inputTargetPaneIDs(from: paneID)
        guard let source = surfaces[paneID] else {
            #if DEBUG
                inputObservations.append(
                    GhosttyBridgeInputObservation(
                        paneID: paneID,
                        eventIdentifier: ObjectIdentifier(event),
                        wasProcessed: false
                    )
                )
            #endif
            return
        }

        let capture = source.captureInputEvent(event)

        #if DEBUG
            inputObservations.append(
                GhosttyBridgeInputObservation(
                    paneID: paneID,
                    eventIdentifier: ObjectIdentifier(event),
                    wasProcessed: capture.wasProcessed
                )
            )
        #endif

        guard let replay = capture.replay else { return }
        for targetPaneID in targetPaneIDs where targetPaneID != paneID {
            let wasProcessed =
                surfaces[targetPaneID]?.replayInputEvent(
                    event,
                    replay: replay
                ) ?? false

            #if DEBUG
                inputObservations.append(
                    GhosttyBridgeInputObservation(
                        paneID: targetPaneID,
                        eventIdentifier: ObjectIdentifier(event),
                        wasProcessed: wasProcessed
                    )
                )
            #endif
        }
    }

    private func routeShortcut(
        _ event: NSEvent,
        from paneID: PaneID
    ) -> GhosttyShortcutDispatchResult {
        guard let chord = ShortcutEventMatcher.chord(matching: event),
            let action = shortcutConfiguration.owner(of: chord)
        else { return .unmatched }

        guard case .terminal(let terminalAction) = action.executionRoute else {
            return .appKit
        }

        let performed = routeTerminalShortcutAction(terminalAction, from: paneID)
        return action.performPolicy.consumes(performed: performed) ? .handled : .passThrough
    }

    @discardableResult
    private func routeTerminalShortcutAction(
        _ action: TerminalShortcutAction,
        from paneID: PaneID
    ) -> Bool {
        guard let source = surfaces[paneID], source.isShortcutDispatchSource else {
            return false
        }

        let targetPaneIDs = TerminalInputRouter.targetPaneIDs(
            for: action,
            sourcePaneID: paneID,
            broadcastPaneIDs: inputTargetPaneIDs(from: paneID)
        )
        var sourceResult = false
        for targetPaneID in targetPaneIDs {
            let coreResult = surfaces[targetPaneID]?.performTerminalShortcutAction(action) ?? false
            #if DEBUG
                let result = terminalActionResultsForTesting[action] ?? coreResult
            #else
                let result = coreResult
            #endif
            if targetPaneID == paneID {
                sourceResult = result
            }
        }
        return sourceResult
    }

    private func inputTargetPaneIDs(from sourcePaneID: PaneID) -> [PaneID] {
        var seen = Set<PaneID>()
        var targetPaneIDs = inputTargetProvider(sourcePaneID).filter {
            seen.insert($0).inserted
        }
        if seen.insert(sourcePaneID).inserted {
            targetPaneIDs.insert(sourcePaneID, at: 0)
        }
        return targetPaneIDs
    }

    private func surfaceDidRequestClose(id: PaneID, processAlive: Bool) {
        guard let surface = surfaces[id] else { return }

        if processAlive {
            surfaceCloseHandlers[id]?(id, true)
            return
        }

        surfaces.removeValue(forKey: id)
        let closeHandler = surfaceCloseHandlers.removeValue(forKey: id)

        #if DEBUG
            surfaceConfigurationsForTesting.removeValue(forKey: id)
        #endif

        surface.close()
        closeHandler?(id, false)
    }

    private func tearDownRuntime() {
        let activeSurfaces = Array(surfaces.values)
        surfaces.removeAll()
        surfaceCloseHandlers.removeAll()

        #if DEBUG
            surfaceConfigurationsForTesting.removeAll()
        #endif

        for surface in activeSurfaces {
            surface.close()
        }

        callbackContextOwnership?.takeUnretainedValue().deactivate()

        if let application {
            ghostty_app_free(application)
            self.application = nil
        }

        releaseCallbackContextOwnership()
        configuration?.release()
        configuration = nil
    }

    private func releaseCallbackContextOwnership() {
        guard let callbackContextOwnership else { return }
        self.callbackContextOwnership = nil
        callbackContextOwnership.release()

        #if DEBUG
            ghosttyCallbackContextOwnershipCount.withLock { count in
                count -= 1
            }
        #endif
    }

    fileprivate final class CallbackContext: Sendable {
        private struct State: Sendable {
            var applicationAddress: UInt?
            var tickPending = false
        }

        private let state = Mutex(State())
        private let runtimeActionHandler: RuntimeActionHandler?
        private let workspaceURLClient: GhosttyWorkspaceURLClient

        init(
            runtimeActionHandler: RuntimeActionHandler?,
            workspaceURLClient: GhosttyWorkspaceURLClient
        ) {
            self.runtimeActionHandler = runtimeActionHandler
            self.workspaceURLClient = workspaceURLClient
        }

        func activate(application: ghostty_app_t) {
            let shouldSchedule = state.withLock { state in
                precondition(state.applicationAddress == nil)
                state.applicationAddress = UInt(bitPattern: application)
                return state.tickPending
            }

            if shouldSchedule {
                enqueueTick()
            }
        }

        func deactivate() {
            state.withLock { state in
                state.applicationAddress = nil
                state.tickPending = false
            }
        }

        func scheduleTick() {
            let shouldSchedule = state.withLock { state in
                guard !state.tickPending else { return false }
                state.tickPending = true
                return state.applicationAddress != nil
            }

            if shouldSchedule {
                enqueueTick()
            }
        }

        func handleRuntimeAction(
            _ action: GhosttyRuntimeAction,
            from application: ghostty_app_t,
            deliveryCompletion: RuntimeActionDeliveryCompletion?
        ) -> Bool {
            guard action.isSupported else { return false }
            if case .openURL = action {
                // URL opening is owned by the bridge even without an external action handler.
            } else if runtimeActionHandler == nil {
                return false
            }

            let applicationAddress = UInt(bitPattern: application)
            let isActiveApplication = state.withLock { state in
                state.applicationAddress == applicationAddress
            }
            guard isActiveApplication else { return false }

            Task { @MainActor [self] in
                deliverRuntimeActionIfActive(
                    action,
                    from: applicationAddress,
                    deliveryCompletion: deliveryCompletion
                )
            }
            return true
        }

        @MainActor
        private func deliverRuntimeActionIfActive(
            _ action: GhosttyRuntimeAction,
            from applicationAddress: UInt,
            deliveryCompletion: RuntimeActionDeliveryCompletion?
        ) {
            let isActiveApplication = state.withLock { state in
                state.applicationAddress == applicationAddress
            }
            guard isActiveApplication else {
                deliveryCompletion?(false)
                return
            }

            if case .openURL(let openURL) = action {
                workspaceURLClient.open(openURL)
            }
            runtimeActionHandler?(action)
            deliveryCompletion?(true)
        }

        private func enqueueTick() {
            Task { @MainActor [self] in
                tickIfActive()
            }
        }

        @MainActor
        private func tickIfActive() {
            let applicationAddress = state.withLock { state -> UInt? in
                guard state.tickPending else { return nil }
                state.tickPending = false
                return state.applicationAddress
            }
            guard let applicationAddress,
                let application = UnsafeMutableRawPointer(bitPattern: applicationAddress)
            else { return }

            ghostty_app_tick(application)
        }
    }
}
