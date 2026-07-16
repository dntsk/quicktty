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
    typealias InputTargetProvider = @MainActor (PaneID) -> [PaneID]

    private static let runtimeBootstrapResult =
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS

    private let applicationIsActive: @MainActor () -> Bool
    private let clipboardClient: GhosttyClipboardClient
    private var configuration: GhosttyConfiguration?
    private var application: ghostty_app_t?
    private var callbackContextOwnership: Unmanaged<CallbackContext>?
    private var surfaces: [PaneID: GhosttySurfaceView] = [:]
    private var surfaceCloseHandlers: [PaneID: SurfaceCloseHandler] = [:]

    var clipboardConfirmationHandler: GhosttyClipboardConfirmationHandler?
    var surfaceFocusHandler: SurfaceFocusHandler?
    var inputTargetProvider: InputTargetProvider = { [$0] }

    #if DEBUG
        private var inputObservations: [GhosttyBridgeInputObservation] = []
        private var surfaceConfigurationsForTesting: [PaneID: GhosttySurfaceConfiguration] = [:]
        private var failsNextSurfaceCreationForTesting = false
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

    init(
        configURL: URL? = nil,
        runtimeActionHandler: RuntimeActionHandler? = nil,
        clipboardClient: GhosttyClipboardClient = .system,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) throws {
        let configuration = try GhosttyConfiguration(configURL: configURL)
        let callbackContext = CallbackContext(runtimeActionHandler: runtimeActionHandler)
        let retainedCallbackContext = Unmanaged.passRetained(callbackContext)

        self.applicationIsActive = applicationIsActive
        self.clipboardClient = clipboardClient
        self.configuration = configuration
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
            if failsNextSurfaceCreationForTesting {
                failsNextSurfaceCreationForTesting = false
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
                clipboardBindingActionRoute: { [weak self] paneID, action in
                    self?.routeClipboardBindingAction(action, from: paneID)
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

    func closeSurface(id: PaneID) {
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        surfaceCloseHandlers.removeValue(forKey: id)

        #if DEBUG
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
            UInt32(GHOSTTY_ACTION_OPEN_CONFIG.rawValue),
            UInt32(GHOSTTY_ACTION_RELOAD_CONFIG.rawValue),
            UInt32(GHOSTTY_ACTION_CONFIG_CHANGE.rawValue),
            UInt32(GHOSTTY_ACTION_SHOW_CHILD_EXITED.rawValue),
        ]
        return actual == [0, 1, 2, 5, 12, 40, 47, 48, 55]
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

        func surfaceConfigurationForTesting(id: PaneID) -> GhosttySurfaceConfiguration? {
            surfaceConfigurationsForTesting[id]
        }

        func failNextSurfaceCreationForTesting() {
            failsNextSurfaceCreationForTesting = true
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

    private func routeClipboardBindingAction(
        _ action: GhosttySurfaceBindingAction,
        from paneID: PaneID
    ) {
        let targetPaneIDs = inputTargetPaneIDs(from: paneID)
        for targetPaneID in targetPaneIDs {
            surfaces[targetPaneID]?.performDirectClipboardBindingAction(action)
        }
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

        init(runtimeActionHandler: RuntimeActionHandler?) {
            self.runtimeActionHandler = runtimeActionHandler
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
            guard action.isSupported, runtimeActionHandler != nil else { return false }

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
            guard isActiveApplication, let runtimeActionHandler else {
                deliveryCompletion?(false)
                return
            }

            runtimeActionHandler(action)
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
