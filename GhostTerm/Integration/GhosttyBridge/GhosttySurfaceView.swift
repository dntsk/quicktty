import AppKit
import Foundation
import GhosttyKit
import QuartzCore
import Synchronization

#if DEBUG
    private let ghosttySurfaceCallbackContextOwnershipCount = Mutex(0)
    private let ghosttySurfaceFocusMonitorOwnershipCount = Mutex(0)
    private let ghosttyMouseObservationLimit = 256
    private let ghosttyClipboardObservationLimit = 256

    struct GhosttySurfaceInputObservation: Equatable {
        let eventIdentifier: ObjectIdentifier
        let translationEventIdentifier: ObjectIdentifier?
        let action: GhosttyInputAction
        let keyCode: UInt32
        let modifiers: GhosttyInputModifiers
        let text: String?
        let composing: Bool
        let result: Bool
    }

    struct GhosttySurfaceSizeSnapshot: Equatable {
        let columns: UInt16
        let rows: UInt16
        let widthPixels: UInt32
        let heightPixels: UInt32
        let cellWidthPixels: UInt32
        let cellHeightPixels: UInt32
    }

    enum GhosttySurfacePreeditObservation: Equatable {
        case set(Data)
        case clear
    }

    struct GhosttySurfaceIMEGeometryObservation: Equatable {
        let rawViewRect: NSRect
        let screenRect: NSRect
    }

    struct GhosttySurfaceMouseButtonObservation: Equatable {
        let eventIdentifier: ObjectIdentifier
        let action: GhosttyMouseAction
        let button: GhosttyMouseButton
        let modifiers: GhosttyInputModifiers
        let consumed: Bool
    }

    struct GhosttySurfaceMousePositionObservation: Equatable {
        let eventIdentifier: ObjectIdentifier
        let x: Double
        let y: Double
        let modifiers: GhosttyInputModifiers
    }

    struct GhosttySurfaceMouseScrollObservation: Equatable {
        let eventIdentifier: ObjectIdentifier
        let x: Double
        let y: Double
        let packedModifiers: Int32
    }

    enum GhosttySurfaceClipboardObservation: Equatable, Sendable {
        case binding(action: String, result: Bool)
        case completion(data: String, confirmed: Bool)
        case write(location: GhosttyClipboardLocation, contents: [GhosttyClipboardContent])
    }

    private func appendBoundedMouseObservation<Value>(
        _ observation: Value,
        to observations: inout [Value]
    ) {
        if observations.count == ghosttyMouseObservationLimit {
            observations.removeFirst()
        }
        observations.append(observation)
    }
#endif

typealias GhosttySurfaceCloseHandler = @MainActor @Sendable (PaneID, Bool) -> Void
typealias GhosttySurfaceInputRoute = @MainActor (PaneID, NSEvent) -> Void
typealias GhosttySurfaceFocusRoute = @MainActor (PaneID) -> Void
typealias GhosttySurfaceCallbackRoute =
    @MainActor @Sendable (PaneID, GhosttySurfaceCallbackEvent) -> Void
typealias GhosttyClipboardInvalidationRoute = @MainActor (PaneID) -> Void

enum GhosttySurfaceCallbackEvent: Sendable {
    case clipboardRead(token: UInt, location: GhosttyClipboardLocation)
    case clipboardConfirmation(GhosttyClipboardConfirmationRequest)
    case clipboardWrite(
        location: GhosttyClipboardLocation,
        contents: [GhosttyClipboardContent]
    )
    case close(processAlive: Bool)
    case pwdChanged(String)
}

func ghosttyRuntimeCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    let context = Unmanaged<SurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.scheduleClose(processAlive: processAlive)
}

@MainActor
final class GhosttySurfaceView: NSView, @MainActor NSTextInputClient {
    let paneID: PaneID

    private let inputRoute: GhosttySurfaceInputRoute
    private let focusRoute: GhosttySurfaceFocusRoute
    private let applicationIsActive: @MainActor () -> Bool
    private let clipboardClient: GhosttyClipboardClient
    private let clipboardInvalidationRoute: GhosttyClipboardInvalidationRoute
    private var surface: ghostty_surface_t?
    private var callbackContextOwnership: Unmanaged<SurfaceCallbackContext>?
    private var mouseTrackingArea: NSTrackingArea?
    private var focusClickMonitor: Any?
    private var suppressNextLeftMouseUp = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private(set) var isActive = false
    private(set) var currentWorkingDirectory: String?

    #if DEBUG
        private var inputObservations: [GhosttySurfaceInputObservation] = []
        private var preeditObservations: [GhosttySurfacePreeditObservation] = []
        private var imeGeometryObservations: [GhosttySurfaceIMEGeometryObservation] = []
        private var mouseButtonObservations: [GhosttySurfaceMouseButtonObservation] = []
        private var mousePositionObservations: [GhosttySurfaceMousePositionObservation] = []
        private var mouseScrollObservations: [GhosttySurfaceMouseScrollObservation] = []
        private var clipboardObservations: [GhosttySurfaceClipboardObservation] = []
        var clipboardObservationHandlerForTesting:
            (@MainActor @Sendable (GhosttySurfaceClipboardObservation) -> Void)?
    #endif

    var isReady: Bool {
        surface != nil
    }

    func needsConfirmQuit() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        inputRoute(paneID, event)
    }

    override func keyUp(with event: NSEvent) {
        inputRoute(paneID, event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputRoute(paneID, event)
    }

    init?(
        application: ghostty_app_t,
        paneID: PaneID,
        configuration: GhosttySurfaceConfiguration,
        access _: GhosttySurfaceAccess,
        applicationIsActive: @escaping @MainActor () -> Bool,
        inputRoute: @escaping GhosttySurfaceInputRoute,
        focusRoute: @escaping GhosttySurfaceFocusRoute,
        clipboardClient: GhosttyClipboardClient,
        callbackRoute: @escaping GhosttySurfaceCallbackRoute,
        clipboardInvalidationRoute: @escaping GhosttyClipboardInvalidationRoute
    ) {
        self.paneID = paneID
        self.inputRoute = inputRoute
        self.focusRoute = focusRoute
        self.applicationIsActive = applicationIsActive
        self.clipboardClient = clipboardClient
        self.clipboardInvalidationRoute = clipboardInvalidationRoute
        currentWorkingDirectory = configuration.workingDirectory
        surface = nil

        let callbackContext = SurfaceCallbackContext(
            paneID: paneID,
            eventHandler: callbackRoute
        )
        let callbackContextOwnership = Unmanaged.passRetained(callbackContext)
        self.callbackContextOwnership = callbackContextOwnership

        #if DEBUG
            ghosttySurfaceCallbackContextOwnershipCount.withLock { count in
                count += 1
            }
        #endif

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        let newSurface = configuration.withCValue(
            view: self,
            userdata: callbackContextOwnership.toOpaque()
        ) { configuration in
            ghostty_surface_new(application, &configuration)
        }

        guard let newSurface else {
            callbackContext.deactivateAndDrain()
            releaseCallbackContextOwnership()
            return nil
        }

        surface = newSurface
        isActive = true
        installFocusClickMonitor()
        updateTrackingAreas()
        synchronizeWindowState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        close()
    }

    func close() {
        guard let surface else {
            callbackContextOwnership?.takeUnretainedValue().deactivateAndDrain()
            stopLocalEventHandling()
            suppressNextLeftMouseUp = false
            clearLocalInputState()
            releaseCallbackContextOwnership()
            return
        }

        let readTokens =
            callbackContextOwnership?.takeUnretainedValue().deactivateAndDrain() ?? []
        for token in readTokens {
            completeClipboardRequest(
                surface: surface,
                token: token,
                data: "",
                confirmed: true
            )
        }

        clipboardInvalidationRoute(paneID)
        stopLocalEventHandling()
        suppressNextLeftMouseUp = false
        clearLocalInputState()
        ghostty_surface_preedit(surface, nil, 0)

        #if DEBUG
            preeditObservations.append(.clear)
        #endif

        self.surface = nil
        isActive = false

        // The renderer and IO threads must stop while the unretained platform view is alive.
        ghostty_surface_free(surface)
        releaseCallbackContextOwnership()
    }

    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            setSurfaceFocused(window?.isKeyWindow == true)
            focusRoute(paneID)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            setSurfaceFocused(false)
        }
        return result
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingWindow(window)
            setSurfaceFocused(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow(window)
        synchronizeWindowState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeBackingScaleAndSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeSurfaceSize()
    }

    // Adapted from SurfaceView_AppKit.swift at 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeMouseTrackingArea()
        guard surface != nil else { return }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )
        mouseTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    #if DEBUG
        static var callbackContextCountForTesting: Int {
            ghosttySurfaceCallbackContextOwnershipCount.withLock { $0 }
        }

        static var focusMonitorCountForTesting: Int {
            ghosttySurfaceFocusMonitorOwnershipCount.withLock { $0 }
        }

        var focusClickMonitorInstalledForTesting: Bool {
            focusClickMonitor != nil
        }

        var sizeSnapshotForTesting: GhosttySurfaceSizeSnapshot? {
            guard let surface else { return nil }
            let size = ghostty_surface_size(surface)
            return GhosttySurfaceSizeSnapshot(
                columns: size.columns,
                rows: size.rows,
                widthPixels: size.width_px,
                heightPixels: size.height_px,
                cellWidthPixels: size.cell_width_px,
                cellHeightPixels: size.cell_height_px
            )
        }

        var inputObservationsForTesting: [GhosttySurfaceInputObservation] {
            inputObservations
        }

        var preeditObservationsForTesting: [GhosttySurfacePreeditObservation] {
            preeditObservations
        }

        var imeGeometryObservationsForTesting: [GhosttySurfaceIMEGeometryObservation] {
            imeGeometryObservations
        }

        var mouseButtonObservationsForTesting: [GhosttySurfaceMouseButtonObservation] {
            mouseButtonObservations
        }

        var mousePositionObservationsForTesting: [GhosttySurfaceMousePositionObservation] {
            mousePositionObservations
        }

        var mouseScrollObservationsForTesting: [GhosttySurfaceMouseScrollObservation] {
            mouseScrollObservations
        }

        var clipboardObservationsForTesting: [GhosttySurfaceClipboardObservation] {
            clipboardObservations
        }

        var pendingClipboardReadCountForTesting: Int {
            callbackContextOwnership?.takeUnretainedValue().pendingReadCount ?? 0
        }

        var pendingClipboardWriteCountForTesting: Int {
            callbackContextOwnership?.takeUnretainedValue().pendingWriteCount ?? 0
        }

        func processFocusClickForTesting(
            _ event: NSEvent,
            applicationIsActive: Bool
        ) -> NSEvent? {
            processFocusClick(event, applicationIsActive: applicationIsActive)
        }

        func processLocalEventForTesting(_ event: NSEvent) -> NSEvent? {
            processLocalEvent(event, applicationIsActive: applicationIsActive())
        }

        func scheduleRuntimeCloseForTesting(processAlive: Bool) {
            ghosttyRuntimeCloseSurfaceCallback(
                callbackContextOwnership?.toOpaque(),
                processAlive
            )
        }

        @discardableResult
        func scheduleWorkingDirectoryChangeForTesting(
            _ workingDirectory: String
        ) -> Bool {
            callbackContextOwnership?.takeUnretainedValue()
                .scheduleWorkingDirectoryChange(workingDirectory) ?? false
        }

        func isPlainCommandDigitForTesting(_ event: NSEvent) -> Bool {
            isPlainCommandDigit(event)
        }

        func isSplitPaneShortcutForTesting(_ event: NSEvent) -> Bool {
            isSplitPaneShortcut(event)
        }

        func isPaneNavigationShortcutForTesting(_ event: NSEvent) -> Bool {
            isPaneNavigationShortcut(event)
        }
    #endif

    private func startObservingWindow(_ window: NSWindow?) {
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowFocusDidChange),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowFocusDidChange),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowScreenDidChange),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    private func stopObservingWindow(_ window: NSWindow?) {
        guard let window else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
        center.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @objc private func windowFocusDidChange() {
        synchronizeFocus()
    }

    @objc private func windowScreenDidChange() {
        synchronizeDisplayID()
        synchronizeBackingScaleAndSize()
    }

    @objc private func windowOcclusionDidChange() {
        synchronizeOcclusion()
    }

    private func synchronizeWindowState() {
        synchronizeDisplayID()
        synchronizeBackingScaleAndSize()
        synchronizeFocus()
        synchronizeOcclusion()
    }

    private func synchronizeFocus() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        setSurfaceFocused(focused)
    }

    private func setSurfaceFocused(_ focused: Bool) {
        if !focused {
            suppressNextLeftMouseUp = false
        }
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func synchronizeOcclusion() {
        let visible = window?.occlusionState.contains(.visible) == true
        setOccluded(!visible)
    }

    private func synchronizeDisplayID() {
        guard let surface else { return }
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID =
            (window?.screen?.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
        ghostty_surface_set_display_id(surface, displayID ?? 0)
    }

    private func synchronizeBackingScaleAndSize() {
        guard let surface else { return }

        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        let backingBounds = convertToBacking(bounds)
        let xScale = bounds.width > 0 ? backingBounds.width / bounds.width : 1
        let yScale = bounds.height > 0 ? backingBounds.height / bounds.height : 1
        ghostty_surface_set_content_scale(surface, Double(xScale), Double(yScale))
        synchronizeSurfaceSize()
    }

    private func synchronizeSurfaceSize() {
        guard let surface else { return }
        let backingSize = convertToBacking(bounds.size)
        let width = UInt32(max(1, backingSize.width.rounded(.down)))
        let height = UInt32(max(1, backingSize.height.rounded(.down)))
        ghostty_surface_set_size(surface, width, height)
    }

    private func clearLocalInputState() {
        markedText.mutableString.setString("")
        keyTextAccumulator = nil
        lastPerformKeyEvent = nil
    }

    // Adapted from SurfaceView_AppKit.swift at 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
    private func installFocusClickMonitor() {
        guard surface != nil, focusClickMonitor == nil else { return }
        focusClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyUp, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return processLocalEvent(event, applicationIsActive: applicationIsActive())
        }

        #if DEBUG
            ghosttySurfaceFocusMonitorOwnershipCount.withLock { count in
                count += 1
            }
        #endif
    }

    private func processLocalEvent(
        _ event: NSEvent,
        applicationIsActive: Bool
    ) -> NSEvent? {
        switch event.type {
        case .keyUp:
            processCommandKeyUp(event, applicationIsActive: applicationIsActive)
        case .leftMouseDown:
            processFocusClick(event, applicationIsActive: applicationIsActive)
        default:
            event
        }
    }

    private func processCommandKeyUp(
        _ event: NSEvent,
        applicationIsActive: Bool
    ) -> NSEvent? {
        guard surface != nil,
            event.modifierFlags.contains(.command),
            applicationIsActive,
            let window,
            event.window != nil,
            event.window === window,
            window.isKeyWindow,
            window.firstResponder === self
        else { return event }

        inputRoute(paneID, event)
        return nil
    }

    private func processFocusClick(
        _ event: NSEvent,
        applicationIsActive: Bool
    ) -> NSEvent? {
        guard surface != nil,
            let window,
            event.window != nil,
            event.window === window
        else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) === self else { return event }

        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }

        if applicationIsActive && window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }

        window.makeFirstResponder(self)
        return event
    }

    private func stopLocalEventHandling() {
        removeMouseTrackingArea()
        guard let focusClickMonitor else { return }
        NSEvent.removeMonitor(focusClickMonitor)
        self.focusClickMonitor = nil

        #if DEBUG
            ghosttySurfaceFocusMonitorOwnershipCount.withLock { count in
                count -= 1
            }
        #endif
    }

    private func removeMouseTrackingArea() {
        guard let mouseTrackingArea else { return }
        removeTrackingArea(mouseTrackingArea)
        self.mouseTrackingArea = nil
    }

    private func releaseCallbackContextOwnership() {
        guard let callbackContextOwnership else { return }
        self.callbackContextOwnership = nil
        callbackContextOwnership.release()

        #if DEBUG
            ghosttySurfaceCallbackContextOwnershipCount.withLock { count in
                count -= 1
            }
        #endif
    }
}

// Adapted from SurfaceView_AppKit.swift at 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
extension GhosttySurfaceView {
    override func mouseDown(with event: NSEvent) {
        _ = sendMouseButton(.press, button: .left, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        _ = sendMouseButton(.release, button: .left, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let consumed = sendMouseButton(.press, button: .right, event: event) else {
            return
        }
        if !consumed {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let consumed = sendMouseButton(.release, button: .right, event: event) else {
            return
        }
        if !consumed {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        _ = sendMouseButton(
            .press,
            button: GhosttyMouseButton(buttonNumber: event.buttonNumber),
            event: event
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = sendMouseButton(
            .release,
            button: GhosttyMouseButton(buttonNumber: event.buttonNumber),
            event: event
        )
    }

    override func mouseEntered(with event: NSEvent) {
        guard surface != nil else { return }
        super.mouseEntered(with: event)
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard surface != nil else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        sendMousePosition(event, x: -1, y: -1)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        let modifiers = GhosttyScrollModifiers(
            precision: precision,
            momentum: GhosttyScrollMomentum(event.momentumPhase)
        )
        ghostty_surface_mouse_scroll(surface, x, y, modifiers.cValue)

        #if DEBUG
            appendBoundedMouseObservation(
                GhosttySurfaceMouseScrollObservation(
                    eventIdentifier: ObjectIdentifier(event),
                    x: x,
                    y: y,
                    packedModifiers: modifiers.rawValue
                ),
                to: &mouseScrollObservations
            )
        #endif
    }

    @discardableResult
    private func sendMouseButton(
        _ action: GhosttyMouseAction,
        button: GhosttyMouseButton,
        event: NSEvent
    ) -> Bool? {
        guard let surface else { return nil }
        let modifiers = GhosttyInput.modifiers(from: event.modifierFlags)
        let consumed = ghostty_surface_mouse_button(
            surface,
            action.cValue,
            button.cValue,
            modifiers.cValue
        )

        #if DEBUG
            appendBoundedMouseObservation(
                GhosttySurfaceMouseButtonObservation(
                    eventIdentifier: ObjectIdentifier(event),
                    action: action,
                    button: button,
                    modifiers: modifiers,
                    consumed: consumed
                ),
                to: &mouseButtonObservations
            )
        #endif

        return consumed
    }

    private func sendMousePosition(
        _ event: NSEvent,
        x explicitX: Double? = nil,
        y explicitY: Double? = nil
    ) {
        guard let surface else { return }
        let location = convert(event.locationInWindow, from: nil)
        let x = explicitX ?? location.x
        let y = explicitY ?? (bounds.height - location.y)
        let modifiers = GhosttyInput.modifiers(from: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, x, y, modifiers.cValue)

        #if DEBUG
            appendBoundedMouseObservation(
                GhosttySurfaceMousePositionObservation(
                    eventIdentifier: ObjectIdentifier(event),
                    x: x,
                    y: y,
                    modifiers: modifiers
                ),
                to: &mousePositionObservations
            )
        #endif
    }
}

extension GhosttySurfaceView {
    func processInputEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            processKeyDown(event)
        case .keyUp:
            keyAction(.release, event: event)
        case .flagsChanged:
            processFlagsChanged(event)
        default:
            false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            window?.isKeyWindow == true,
            window?.firstResponder === self,
            let surface
        else { return false }

        guard
            !isPlainCommandT(event),
            !isPlainCommandDigit(event),
            !isSplitPaneShortcut(event),
            !isPaneNavigationShortcut(event)
        else {
            lastPerformKeyEvent = nil
            return false
        }

        let bindingEvent = event.ghosttyKeyEvent(.press, text: event.characters ?? "")
        var bindingFlags = GHOSTTY_BINDING_FLAGS_CONSUMED
        let isBinding = bindingEvent.withCValue { value in
            ghostty_surface_key_is_binding(surface, value, &bindingFlags)
        }
        if isBinding {
            inputRoute(paneID, event)
            return true
        }

        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            inputRoute(paneID, event)
            return true

        case "/":
            guard event.modifierFlags.contains(.control),
                event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            inputRoute(paneID, event)
            return true

        default:
            guard event.timestamp != 0 else { return false }
            guard
                event.modifierFlags.contains(.command)
                    || event.modifierFlags.contains(.control)
            else {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    inputRoute(paneID, event)
                    return true
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }
    }

    private func isPlainCommandT(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "t"
            && isPlainCommandShortcut(event)
    }

    private func isPlainCommandDigit(_ event: NSEvent) -> Bool {
        guard let character = event.charactersIgnoringModifiers?.first else { return false }
        return "123456789".contains(character) && isPlainCommandShortcut(event)
    }

    private func isSplitPaneShortcut(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "d"
            && event.modifierFlags.contains(.command)
            && event.modifierFlags.isDisjoint(with: [.control, .option])
    }

    private func isPaneNavigationShortcut(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers else { return false }
        if key == "[" || key == "]" {
            return isPlainCommandShortcut(event)
        }

        switch key {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            String(UnicodeScalar(NSRightArrowFunctionKey)!),
            String(UnicodeScalar(NSUpArrowFunctionKey)!),
            String(UnicodeScalar(NSDownArrowFunctionKey)!):
            return event.modifierFlags.contains([.command, .option])
                && event.modifierFlags.isDisjoint(with: [.shift, .control])
        default:
            return false
        }
    }

    private func isPlainCommandShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.modifierFlags.isDisjoint(with: [.shift, .control, .option])
    }

    override func doCommand(by _: Selector) {
        guard let lastPerformKeyEvent,
            let currentEvent = NSApp.currentEvent,
            lastPerformKeyEvent == currentEvent.timestamp
        else { return }

        NSApp.sendEvent(currentEvent)
    }

    private func processKeyDown(_ event: NSEvent) -> Bool {
        guard let surface else { return false }

        let reportedTranslationModifiers = GhosttyInput.modifierFlags(
            from: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.modifiers(from: event.modifierFlags).cValue
            )
        )
        let translationModifiers = GhosttyInput.translationModifiers(
            original: event.modifierFlags,
            reported: reportedTranslationModifiers
        )

        let translationEvent: NSEvent
        if translationModifiers == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent =
                NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationModifiers,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationModifiers) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
        }

        let action: GhosttyInputAction = event.isARepeat ? .repeat : .press
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        let keyboardLayoutBefore = hadMarkedText ? nil : GhosttyInput.currentKeyboardLayoutID

        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])

        if !hadMarkedText,
            keyboardLayoutBefore != GhosttyInput.currentKeyboardLayoutID
        {
            return true
        }

        syncPreedit(clearIfNeeded: hadMarkedText)

        if let accumulatedText = keyTextAccumulator,
            !accumulatedText.isEmpty
        {
            var result = false
            for text in accumulatedText {
                result = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
                if callbackContextOwnership?.takeUnretainedValue()
                    .hasTerminalClosePending == true
                {
                    break
                }
            }
            return result
        }

        return keyAction(
            action,
            event: event,
            translationEvent: translationEvent,
            text: controlSlashText(for: event) ?? translationEvent.ghosttyCharacters,
            composing: markedText.length > 0 || hadMarkedText
        )
    }

    private func processFlagsChanged(_ event: NSEvent) -> Bool {
        let modifier: GhosttyInputModifiers
        switch event.keyCode {
        case 0x39:
            modifier = .capsLock
        case 0x38, 0x3C:
            modifier = .shift
        case 0x3B, 0x3E:
            modifier = .control
        case 0x3A, 0x3D:
            modifier = .option
        case 0x37, 0x36:
            modifier = .command
        default:
            return false
        }

        guard !hasMarkedText() else { return false }

        let modifiers = GhosttyInput.modifiers(from: event.modifierFlags)
        var action: GhosttyInputAction = .release
        if !modifiers.intersection(modifier).isEmpty {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed =
                    event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed =
                    event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed =
                    event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed =
                    event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = .press
            }
        }

        return keyAction(action, event: event)
    }

    private func keyAction(
        _ action: GhosttyInputAction,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        let encodedText: String?
        if let text,
            !text.isEmpty,
            let firstByte = text.utf8.first,
            firstByte >= 0x20
        {
            encodedText = text
        } else {
            encodedText = nil
        }

        let keyEvent = event.ghosttyKeyEvent(
            action,
            translationModifiers: translationEvent?.modifierFlags,
            text: encodedText,
            composing: composing
        )
        let result = keyEvent.withCValue { value in
            ghostty_surface_key(surface, value)
        }

        #if DEBUG
            inputObservations.append(
                GhosttySurfaceInputObservation(
                    eventIdentifier: ObjectIdentifier(event),
                    translationEventIdentifier: translationEvent.map(ObjectIdentifier.init),
                    action: action,
                    keyCode: keyEvent.keyCode,
                    modifiers: keyEvent.modifiers,
                    text: keyEvent.text,
                    composing: keyEvent.composing,
                    result: result
                )
            )
        #endif

        // A true result can mean consumed input or a closed surface; do not use the C handle here.
        return result
    }

    private func controlSlashText(for event: NSEvent) -> String? {
        guard event.charactersIgnoringModifiers == "/",
            event.modifierFlags.contains(.control),
            event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
        else { return nil }

        return "_"
    }
}

extension GhosttySurfaceView {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange()
    }

    func setMarkedText(
        _ string: Any,
        selectedRange _: NSRange,
        replacementRange _: NSRange
    ) {
        guard surface != nil else { return }

        switch string {
        case let attributedString as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributedString)
        case let string as String:
            markedText = NSMutableAttributedString(string: string)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange _: NSRange,
        actualRange _: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }

    func firstRect(
        forCharacterRange _: NSRange,
        actualRange _: NSRangePointer?
    ) -> NSRect {
        guard let surface else { return .zero }

        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSRect(
            x: x,
            y: bounds.height - y,
            width: width,
            height: height
        )
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? windowRect

        #if DEBUG
            imeGeometryObservations.append(
                GhosttySurfaceIMEGeometryObservation(
                    rawViewRect: viewRect,
                    screenRect: screenRect
                )
            )
        #endif

        return screenRect
    }

    func insertText(_ string: Any, replacementRange _: NSRange) {
        guard let surface else { return }

        let text: String
        switch string {
        case let attributedString as NSAttributedString:
            text = attributedString.string
        case let string as String:
            text = string
        default:
            return
        }

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
            return
        }

        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let text = markedText.string
            let byteCount = text.utf8.count
            text.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(byteCount))
            }

            #if DEBUG
                preeditObservations.append(.set(Data(text.utf8)))
            #endif
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)

            #if DEBUG
                preeditObservations.append(.clear)
            #endif
        }
    }
}

// Adapted from Ghostty.App.swift and SurfaceView_AppKit.swift at
// 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
extension GhosttySurfaceView {
    @IBAction func copy(_ sender: Any?) {
        performClipboardBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        performClipboardBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteSelection(_ sender: Any?) {
        performClipboardBindingAction("paste_from_selection")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        performClipboardBindingAction("select_all")
    }

    func processCallbackEvent(
        _ event: GhosttySurfaceCallbackEvent,
        confirmationHandler: GhosttyClipboardConfirmationHandler?
    ) {
        switch event {
        case .clipboardRead(let token, let location):
            processClipboardRead(token: token, location: location)
        case .clipboardConfirmation(let request):
            processClipboardConfirmation(request, handler: confirmationHandler)
        case .clipboardWrite(let location, let contents):
            processClipboardWrite(location: location, contents: contents)
        case .close:
            break
        case .pwdChanged(let workingDirectory):
            currentWorkingDirectory = workingDirectory
        }
    }

    private func performClipboardBindingAction(_ action: String) {
        guard let surface else { return }
        let result = action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }

        #if DEBUG
            appendClipboardObservation(.binding(action: action, result: result))
        #endif
    }

    private func processClipboardRead(token: UInt, location: GhosttyClipboardLocation) {
        guard let context = callbackContextOwnership?.takeUnretainedValue(),
            context.beginInitialCompletion(token: token),
            let surface
        else { return }

        let data = clipboardClient.read(location) ?? ""
        completeClipboardRequest(
            surface: surface,
            token: token,
            data: data,
            confirmed: false
        )
        context.finishInitialCompletion(token: token)
    }

    private func processClipboardConfirmation(
        _ request: GhosttyClipboardConfirmationRequest,
        handler: GhosttyClipboardConfirmationHandler?
    ) {
        let response: @MainActor @Sendable (GhosttyClipboardConfirmationResponse) -> Void = {
            [weak self] response in
            self?.completeClipboardConfirmation(id: request.id, response: response)
        }

        guard let handler else {
            response(.deny)
            return
        }
        handler(.request(request, response: response))
    }

    private func completeClipboardConfirmation(
        id: UUID,
        response: GhosttyClipboardConfirmationResponse
    ) {
        guard
            let resolution = callbackContextOwnership?.takeUnretainedValue()
                .resolveClipboardConfirmation(id: id, response: response)
        else { return }

        switch resolution {
        case .read(let token, let data):
            guard let surface else { return }
            completeClipboardRequest(
                surface: surface,
                token: token,
                data: data,
                confirmed: true
            )
        case .write(let location, let contents):
            guard surface != nil else { return }
            clipboardClient.write(location, contents)

            #if DEBUG
                appendClipboardObservation(.write(location: location, contents: contents))
            #endif
        case .deniedWrite:
            break
        }
    }

    private func processClipboardWrite(
        location: GhosttyClipboardLocation,
        contents: [GhosttyClipboardContent]
    ) {
        guard surface != nil else { return }
        clipboardClient.write(location, contents)

        #if DEBUG
            appendClipboardObservation(.write(location: location, contents: contents))
        #endif
    }

    private func completeClipboardRequest(
        surface: ghostty_surface_t,
        token: UInt,
        data: String,
        confirmed: Bool
    ) {
        guard let state = UnsafeMutableRawPointer(bitPattern: token) else { return }
        data.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                confirmed
            )
        }

        #if DEBUG
            appendClipboardObservation(.completion(data: data, confirmed: confirmed))
        #endif
    }

    #if DEBUG
        private func appendClipboardObservation(
            _ observation: GhosttySurfaceClipboardObservation
        ) {
            if clipboardObservations.count == ghosttyClipboardObservationLimit {
                clipboardObservations.removeFirst()
            }
            clipboardObservations.append(observation)
            clipboardObservationHandlerForTesting?(observation)
        }
    #endif
}

final class SurfaceCallbackContext: Sendable {
    enum ClipboardConfirmationResolution: Sendable {
        case read(token: UInt, data: String)
        case write(
            location: GhosttyClipboardLocation,
            contents: [GhosttyClipboardContent]
        )
        case deniedWrite
    }

    private enum ReadPhase: Sendable {
        case queued
        case completingInitial
        case confirmationQueued(GhosttyClipboardConfirmationRequest)
    }

    private struct PendingRead: Sendable {
        let location: GhosttyClipboardLocation
        var phase: ReadPhase
    }

    private struct State: Sendable {
        var isActive = true
        var pendingProcessAlive: Bool?
        var pendingWorkingDirectory: String?
        var reads: [UInt: PendingRead] = [:]
        var writes: [UUID: GhosttyClipboardConfirmationRequest] = [:]
    }

    let paneID: PaneID

    private let state = Mutex(State())
    private let eventHandler: GhosttySurfaceCallbackRoute

    init(paneID: PaneID, eventHandler: @escaping GhosttySurfaceCallbackRoute) {
        self.paneID = paneID
        self.eventHandler = eventHandler
    }

    @discardableResult
    func deactivateAndDrain() -> [UInt] {
        state.withLock { state in
            guard state.isActive else { return [] }
            state.isActive = false
            state.pendingProcessAlive = nil
            state.pendingWorkingDirectory = nil
            let tokens = Array(state.reads.keys)
            state.reads.removeAll()
            state.writes.removeAll()
            return tokens
        }
    }

    var hasTerminalClosePending: Bool {
        state.withLock { state in
            !state.isActive || state.pendingProcessAlive == false
        }
    }

    var pendingReadCount: Int {
        state.withLock { $0.reads.count }
    }

    var pendingWriteCount: Int {
        state.withLock { $0.writes.count }
    }

    func registerClipboardRead(
        token: UInt,
        location: GhosttyClipboardLocation
    ) -> Bool {
        let accepted = state.withLock { state in
            guard state.isActive, state.reads[token] == nil else { return false }
            state.reads[token] = PendingRead(location: location, phase: .queued)
            return true
        }
        guard accepted else { return false }

        Task { @MainActor [self] in
            deliverClipboardReadIfActive(token: token, location: location)
        }
        return true
    }

    func beginInitialCompletion(token: UInt) -> Bool {
        state.withLock { state in
            guard state.isActive,
                var pending = state.reads[token],
                case .queued = pending.phase
            else { return false }
            pending.phase = .completingInitial
            state.reads[token] = pending
            return true
        }
    }

    func finishInitialCompletion(token: UInt) {
        state.withLock { state in
            guard let pending = state.reads[token],
                case .completingInitial = pending.phase
            else { return }
            state.reads.removeValue(forKey: token)
        }
    }

    func registerClipboardReadConfirmation(
        token: UInt,
        data: String,
        kind: GhosttyClipboardConfirmationKind
    ) {
        let request = state.withLock { state -> GhosttyClipboardConfirmationRequest? in
            guard state.isActive,
                var pending = state.reads[token],
                case .completingInitial = pending.phase
            else { return nil }

            let request = GhosttyClipboardConfirmationRequest(
                id: UUID(),
                paneID: paneID,
                kind: kind,
                location: pending.location,
                contents: [GhosttyClipboardContent(mime: "text/plain", data: data)]
            )
            pending.phase = .confirmationQueued(request)
            state.reads[token] = pending
            return request
        }
        guard let request else { return }

        Task { @MainActor [self] in
            deliverClipboardConfirmationIfActive(request)
        }
    }

    func scheduleClipboardWrite(
        location: GhosttyClipboardLocation,
        contents: [GhosttyClipboardContent]
    ) {
        let isActive = state.withLock { $0.isActive }
        guard isActive else { return }

        Task { @MainActor [self] in
            let isActive = state.withLock { $0.isActive }
            guard isActive else { return }
            eventHandler(
                paneID,
                .clipboardWrite(location: location, contents: contents)
            )
        }
    }

    func registerClipboardWriteConfirmation(
        location: GhosttyClipboardLocation,
        contents: [GhosttyClipboardContent]
    ) {
        let request = GhosttyClipboardConfirmationRequest(
            id: UUID(),
            paneID: paneID,
            kind: .osc52Write,
            location: location,
            contents: contents
        )
        let accepted = state.withLock { state in
            guard state.isActive else { return false }
            state.writes[request.id] = request
            return true
        }
        guard accepted else { return }

        Task { @MainActor [self] in
            deliverClipboardConfirmationIfActive(request)
        }
    }

    func resolveClipboardConfirmation(
        id: UUID,
        response: GhosttyClipboardConfirmationResponse
    ) -> ClipboardConfirmationResolution? {
        state.withLock { state in
            guard state.isActive else { return nil }

            for (token, pending) in state.reads {
                guard case .confirmationQueued(let request) = pending.phase,
                    request.id == id
                else { continue }
                state.reads.removeValue(forKey: token)
                let data =
                    response == .allow
                    ? request.contents.first(where: { $0.mime == "text/plain" })?.data ?? ""
                    : ""
                return .read(token: token, data: data)
            }

            guard let request = state.writes.removeValue(forKey: id) else { return nil }
            switch response {
            case .deny:
                return .deniedWrite
            case .allow:
                return .write(location: request.location, contents: request.contents)
            }
        }
    }

    @discardableResult
    func scheduleWorkingDirectoryChange(_ workingDirectory: String) -> Bool {
        let result = state.withLock { state in
            guard state.isActive else { return (accepted: false, shouldSchedule: false) }
            let shouldSchedule = state.pendingWorkingDirectory == nil
            state.pendingWorkingDirectory = workingDirectory
            return (accepted: true, shouldSchedule: shouldSchedule)
        }
        guard result.accepted else { return false }

        if result.shouldSchedule {
            Task { @MainActor [self] in
                deliverWorkingDirectoryChangeIfActive()
            }
        }
        return true
    }

    func scheduleClose(processAlive: Bool) {
        let shouldSchedule = state.withLock { state in
            guard state.isActive else { return false }
            if let pendingProcessAlive = state.pendingProcessAlive {
                state.pendingProcessAlive = pendingProcessAlive && processAlive
                return false
            }
            state.pendingProcessAlive = processAlive
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [self] in
            deliverCloseIfActive()
        }
    }

    @MainActor
    private func deliverClipboardReadIfActive(
        token: UInt,
        location: GhosttyClipboardLocation
    ) {
        let isQueued = state.withLock { state in
            guard state.isActive,
                let pending = state.reads[token],
                pending.location == location,
                case .queued = pending.phase
            else { return false }
            return true
        }
        guard isQueued else { return }
        eventHandler(paneID, .clipboardRead(token: token, location: location))
    }

    @MainActor
    private func deliverClipboardConfirmationIfActive(
        _ request: GhosttyClipboardConfirmationRequest
    ) {
        let isQueued = state.withLock { state in
            guard state.isActive else { return false }
            if state.writes[request.id] != nil {
                return true
            }
            return state.reads.values.contains { pending in
                guard case .confirmationQueued(let queued) = pending.phase else {
                    return false
                }
                return queued.id == request.id
            }
        }
        guard isQueued else { return }
        eventHandler(paneID, .clipboardConfirmation(request))
    }

    @MainActor
    private func deliverWorkingDirectoryChangeIfActive() {
        let workingDirectory = state.withLock { state -> String? in
            guard state.isActive else { return nil }
            let workingDirectory = state.pendingWorkingDirectory
            state.pendingWorkingDirectory = nil
            return workingDirectory
        }
        guard let workingDirectory else { return }
        eventHandler(paneID, .pwdChanged(workingDirectory))
    }

    @MainActor
    private func deliverCloseIfActive() {
        let processAlive = state.withLock { state -> Bool? in
            guard state.isActive, let processAlive = state.pendingProcessAlive else {
                return nil
            }
            state.pendingProcessAlive = nil
            return processAlive
        }
        guard let processAlive else { return }
        eventHandler(paneID, .close(processAlive: processAlive))
    }
}

extension GhosttySurfaceConfiguration {
    @MainActor
    fileprivate func withCValue<Result>(
        view: GhosttySurfaceView,
        userdata: UnsafeMutableRawPointer,
        _ body: (inout ghostty_surface_config_s) throws -> Result
    ) rethrows -> Result {
        var configuration = ghostty_surface_config_new()
        configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
        configuration.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
        )
        configuration.userdata = userdata
        configuration.scale_factor = Double(
            view.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
        configuration.wait_after_command = waitAfterCommand
        configuration.context =
            switch context {
            case .window:
                GHOSTTY_SURFACE_CONTEXT_WINDOW
            case .tab:
                GHOSTTY_SURFACE_CONTEXT_TAB
            case .split:
                GHOSTTY_SURFACE_CONTEXT_SPLIT
            }

        return try withOptionalCString(workingDirectory) { workingDirectory in
            configuration.working_directory = workingDirectory
            return try withOptionalCString(command) { command in
                configuration.command = command
                return try withOptionalCString(initialInput) { initialInput in
                    configuration.initial_input = initialInput
                    let pairs = environment.sorted { $0.key < $1.key }
                    var variables: [ghostty_env_var_s] = []
                    variables.reserveCapacity(pairs.count)
                    return try withEnvironment(
                        pairs,
                        at: pairs.startIndex,
                        variables: &variables
                    ) { buffer in
                        configuration.env_vars = buffer.baseAddress
                        configuration.env_var_count = buffer.count
                        return try body(&configuration)
                    }
                }
            }
        }
    }
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let value else {
        return try body(nil)
    }
    return try value.withCString(body)
}

private func withEnvironment<Result>(
    _ pairs: [(key: String, value: String)],
    at index: Int,
    variables: inout [ghostty_env_var_s],
    _ body: (UnsafeMutableBufferPointer<ghostty_env_var_s>) throws -> Result
) rethrows -> Result {
    guard index < pairs.endIndex else {
        return try variables.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }

    return try pairs[index].key.withCString { key in
        try pairs[index].value.withCString { value in
            variables.append(ghostty_env_var_s(key: key, value: value))
            defer { variables.removeLast() }
            return try withEnvironment(
                pairs,
                at: pairs.index(after: index),
                variables: &variables,
                body
            )
        }
    }
}
