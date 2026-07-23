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
    private let ghosttySurfaceSizeObservationLimit = 256

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

    struct GhosttySurfaceSizeRequestObservation: Equatable {
        let requestedWidthPixels: UInt32
        let requestedHeightPixels: UInt32
        let resultingSize: GhosttySurfaceSizeSnapshot
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

    struct GhosttySurfaceTerminalActionObservation: Equatable, Sendable {
        let action: TerminalShortcutAction
        let result: Bool
    }

    enum GhosttySurfaceClipboardObservation: Equatable, Sendable {
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

    private func appendBoundedSizeObservation(
        _ observation: GhosttySurfaceSizeRequestObservation,
        to observations: inout [GhosttySurfaceSizeRequestObservation]
    ) {
        if observations.count == ghosttySurfaceSizeObservationLimit {
            observations.removeFirst()
        }
        observations.append(observation)
    }
#endif

func conservativeMinimumSurfaceSize(
    for size: ghostty_surface_size_s
) -> (widthPixels: UInt32, heightPixels: UInt32) {
    let fallback = (widthPixels: UInt32(40), heightPixels: UInt32(32))
    let cellWidth = size.cell_width_px
    let cellHeight = size.cell_height_px
    guard cellWidth > 0, cellHeight > 0 else { return fallback }

    let gridWidth = UInt32(size.columns).multipliedReportingOverflow(by: cellWidth)
    let gridHeight = UInt32(size.rows).multipliedReportingOverflow(by: cellHeight)
    guard !gridWidth.overflow, !gridHeight.overflow else { return fallback }

    let widthOverhead = size.width_px.subtractingReportingOverflow(gridWidth.partialValue)
    let heightOverhead = size.height_px.subtractingReportingOverflow(gridHeight.partialValue)
    guard !widthOverhead.overflow, !heightOverhead.overflow else { return fallback }

    let minimumGridWidth = cellWidth.multipliedReportingOverflow(by: 5)
    let minimumGridHeight = cellHeight.multipliedReportingOverflow(by: 2)
    guard !minimumGridWidth.overflow, !minimumGridHeight.overflow else { return fallback }

    let minimumWidth = widthOverhead.partialValue
        .addingReportingOverflow(minimumGridWidth.partialValue)
    let minimumHeight = heightOverhead.partialValue
        .addingReportingOverflow(minimumGridHeight.partialValue)
    guard !minimumWidth.overflow, !minimumHeight.overflow else { return fallback }

    // Remainder is treated as overhead to avoid under-estimating padding, even if that rejects a fitting boundary.
    return (
        widthPixels: minimumWidth.partialValue,
        heightPixels: minimumHeight.partialValue
    )
}

struct GhosttyMouseShape: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: Int32

    static let `default` = GhosttyMouseShape(rawValue: 0)
    static let contextMenu = GhosttyMouseShape(rawValue: 1)
    static let help = GhosttyMouseShape(rawValue: 2)
    static let pointer = GhosttyMouseShape(rawValue: 3)
    static let progress = GhosttyMouseShape(rawValue: 4)
    static let wait = GhosttyMouseShape(rawValue: 5)
    static let cell = GhosttyMouseShape(rawValue: 6)
    static let crosshair = GhosttyMouseShape(rawValue: 7)
    static let text = GhosttyMouseShape(rawValue: 8)
    static let verticalText = GhosttyMouseShape(rawValue: 9)
    static let alias = GhosttyMouseShape(rawValue: 10)
    static let copy = GhosttyMouseShape(rawValue: 11)
    static let move = GhosttyMouseShape(rawValue: 12)
    static let noDrop = GhosttyMouseShape(rawValue: 13)
    static let notAllowed = GhosttyMouseShape(rawValue: 14)
    static let grab = GhosttyMouseShape(rawValue: 15)
    static let grabbing = GhosttyMouseShape(rawValue: 16)
    static let allScroll = GhosttyMouseShape(rawValue: 17)
    static let columnResize = GhosttyMouseShape(rawValue: 18)
    static let rowResize = GhosttyMouseShape(rawValue: 19)
    static let northResize = GhosttyMouseShape(rawValue: 20)
    static let eastResize = GhosttyMouseShape(rawValue: 21)
    static let southResize = GhosttyMouseShape(rawValue: 22)
    static let westResize = GhosttyMouseShape(rawValue: 23)
    static let northEastResize = GhosttyMouseShape(rawValue: 24)
    static let northWestResize = GhosttyMouseShape(rawValue: 25)
    static let southEastResize = GhosttyMouseShape(rawValue: 26)
    static let southWestResize = GhosttyMouseShape(rawValue: 27)
    static let eastWestResize = GhosttyMouseShape(rawValue: 28)
    static let northSouthResize = GhosttyMouseShape(rawValue: 29)
    static let northEastSouthWestResize = GhosttyMouseShape(rawValue: 30)
    static let northWestSouthEastResize = GhosttyMouseShape(rawValue: 31)
    static let zoomIn = GhosttyMouseShape(rawValue: 32)
    static let zoomOut = GhosttyMouseShape(rawValue: 33)

    static let allPinned: [GhosttyMouseShape] = (0...33).map(GhosttyMouseShape.init)

    nonisolated init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    nonisolated init(cValue: ghostty_action_mouse_shape_e) {
        self.init(rawValue: Int32(cValue.rawValue))
    }

    static var pinnedABIMatchesHeader: Bool {
        let actual = [
            GHOSTTY_MOUSE_SHAPE_DEFAULT,
            GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
            GHOSTTY_MOUSE_SHAPE_HELP,
            GHOSTTY_MOUSE_SHAPE_POINTER,
            GHOSTTY_MOUSE_SHAPE_PROGRESS,
            GHOSTTY_MOUSE_SHAPE_WAIT,
            GHOSTTY_MOUSE_SHAPE_CELL,
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            GHOSTTY_MOUSE_SHAPE_TEXT,
            GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
            GHOSTTY_MOUSE_SHAPE_ALIAS,
            GHOSTTY_MOUSE_SHAPE_COPY,
            GHOSTTY_MOUSE_SHAPE_MOVE,
            GHOSTTY_MOUSE_SHAPE_NO_DROP,
            GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
            GHOSTTY_MOUSE_SHAPE_GRAB,
            GHOSTTY_MOUSE_SHAPE_GRABBING,
            GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
            GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
            GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_N_RESIZE,
            GHOSTTY_MOUSE_SHAPE_E_RESIZE,
            GHOSTTY_MOUSE_SHAPE_S_RESIZE,
            GHOSTTY_MOUSE_SHAPE_W_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
            GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
            GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
            GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
        ].map { Int32($0.rawValue) }
        return actual == Array(0...33)
    }

    @MainActor
    var cursor: NSCursor? {
        switch self {
        case .default, .help, .progress, .wait:
            NSCursor.arrow
        case .contextMenu:
            NSCursor.contextualMenu
        case .pointer:
            NSCursor.pointingHand
        case .cell, .crosshair:
            NSCursor.crosshair
        case .text:
            NSCursor.iBeam
        case .verticalText:
            NSCursor.iBeamCursorForVerticalLayout
        case .alias:
            NSCursor.dragLink
        case .copy:
            NSCursor.dragCopy
        case .move, .allScroll, .grab:
            NSCursor.openHand
        case .noDrop, .notAllowed:
            NSCursor.operationNotAllowed
        case .grabbing:
            NSCursor.closedHand
        case .columnResize, .eastWestResize:
            NSCursor.columnResize
        case .rowResize, .northSouthResize:
            NSCursor.rowResize
        case .northResize:
            NSCursor.rowResize(directions: .up)
        case .eastResize:
            NSCursor.columnResize(directions: .right)
        case .southResize:
            NSCursor.rowResize(directions: .down)
        case .westResize:
            NSCursor.columnResize(directions: .left)
        case .northEastResize, .northEastSouthWestResize:
            NSCursor.frameResize(position: .topRight, directions: .all)
        case .northWestResize, .northWestSouthEastResize:
            NSCursor.frameResize(position: .topLeft, directions: .all)
        case .southEastResize:
            NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .southWestResize:
            NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .zoomIn:
            NSCursor.zoomIn
        case .zoomOut:
            NSCursor.zoomOut
        default:
            nil
        }
    }
}

typealias GhosttySurfaceCloseHandler = @MainActor @Sendable (PaneID, Bool) -> Void
typealias GhosttySurfaceInputRoute = @MainActor (PaneID, NSEvent) -> Void
typealias GhosttySurfaceFocusRoute = @MainActor (PaneID) -> Void
typealias GhosttySurfaceShortcutRoute =
    @MainActor (PaneID, NSEvent) -> GhosttyShortcutDispatchResult
typealias GhosttySurfaceTerminalActionRoute =
    @MainActor (PaneID, TerminalShortcutAction) -> Bool
typealias GhosttySurfaceCallbackRoute =
    @MainActor @Sendable (PaneID, GhosttySurfaceCallbackEvent) -> Void
typealias GhosttyClipboardInvalidationRoute = @MainActor (PaneID) -> Void

enum GhosttyShortcutDispatchResult: Equatable, Sendable {
    case appKit
    case handled
    case passThrough
    case unmatched
}

@MainActor
struct GhosttySurfaceInputCapture {
    let wasProcessed: Bool
    let replay: GhosttySurfaceInputReplay?
}

@MainActor
enum GhosttySurfaceInputReplay {
    enum KeyText {
        case sourceInterpreted([String])
        case targetFallback
    }

    case keyDown(
        action: GhosttyInputAction,
        text: KeyText,
        composing: Bool
    )
    case keyUp
    case flagsChanged
}

enum GhosttySurfaceCallbackEvent: Sendable {
    case clipboardRead(token: UInt, location: GhosttyClipboardLocation)
    case clipboardConfirmation(GhosttyClipboardConfirmationRequest)
    case clipboardWrite(
        location: GhosttyClipboardLocation,
        contents: [GhosttyClipboardContent]
    )
    case close(processAlive: Bool)
    case mouseShapeChanged(GhosttyMouseShape)
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
    private let shortcutRoute: GhosttySurfaceShortcutRoute
    private let terminalActionRoute: GhosttySurfaceTerminalActionRoute
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
    private var currentMouseShape: GhosttyMouseShape = .text
    private var lastPerformKeyEvent: TimeInterval?
    private(set) var isActive = false
    private(set) var currentWorkingDirectory: String?

    var latestWorkingDirectoryForPersistence: String? {
        callbackContextOwnership?.takeUnretainedValue().latestWorkingDirectory
            ?? currentWorkingDirectory
    }

    #if DEBUG
        private var inputObservations: [GhosttySurfaceInputObservation] = []
        private var sizeRequestObservations: [GhosttySurfaceSizeRequestObservation] = []
        private var interpretedTextObservations: [String] = []
        private var preeditObservations: [GhosttySurfacePreeditObservation] = []
        private var imeGeometryObservations: [GhosttySurfaceIMEGeometryObservation] = []
        private var mouseButtonObservations: [GhosttySurfaceMouseButtonObservation] = []
        private var mousePositionObservations: [GhosttySurfaceMousePositionObservation] = []
        private var mouseScrollObservations: [GhosttySurfaceMouseScrollObservation] = []
        private var mouseShapeUpdateCount = 0
        private var terminalActionObservations: [GhosttySurfaceTerminalActionObservation] = []
        private var clipboardObservations: [GhosttySurfaceClipboardObservation] = []
        var clipboardObservationHandlerForTesting:
            (@MainActor @Sendable (GhosttySurfaceClipboardObservation) -> Void)?
    #endif

    var isReady: Bool {
        surface != nil
    }

    var isShortcutDispatchSource: Bool {
        surface != nil
            && window?.firstResponder === self
            && !isHiddenOrHasHiddenAncestor
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
        shortcutRoute: @escaping GhosttySurfaceShortcutRoute,
        terminalActionRoute: @escaping GhosttySurfaceTerminalActionRoute,
        clipboardClient: GhosttyClipboardClient,
        callbackRoute: @escaping GhosttySurfaceCallbackRoute,
        clipboardInvalidationRoute: @escaping GhosttyClipboardInvalidationRoute
    ) {
        self.paneID = paneID
        self.inputRoute = inputRoute
        self.focusRoute = focusRoute
        self.shortcutRoute = shortcutRoute
        self.terminalActionRoute = terminalActionRoute
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
            clearLocalCursorState()
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
        clearLocalCursorState()

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

    override func resetCursorRects() {
        super.resetCursorRects()
        guard surface != nil, let cursor = currentMouseShape.cursor else { return }
        addCursorRect(bounds, cursor: cursor)
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
            return sizeSnapshot(for: surface)
        }

        var sizeRequestObservationsForTesting: [GhosttySurfaceSizeRequestObservation] {
            sizeRequestObservations
        }

        var processExitedForTesting: Bool {
            guard let surface else { return true }
            return ghostty_surface_process_exited(surface)
        }

        var inputObservationsForTesting: [GhosttySurfaceInputObservation] {
            inputObservations
        }

        var interpretedTextObservationsForTesting: [String] {
            interpretedTextObservations
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

        var currentMouseShapeForTesting: GhosttyMouseShape {
            currentMouseShape
        }

        var currentMouseCursorForTesting: NSCursor? {
            currentMouseShape.cursor
        }

        var mouseShapeUpdateCountForTesting: Int {
            mouseShapeUpdateCount
        }

        var terminalActionObservationsForTesting: [GhosttySurfaceTerminalActionObservation] {
            terminalActionObservations
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
        func scheduleMouseShapeForTesting(rawValue: Int32) -> Bool {
            guard let surface else { return false }
            return ghosttyRuntimeMouseShapeCallbackForTesting(
                surface: surface,
                rawValue: rawValue
            )
        }

        @discardableResult
        func scheduleWorkingDirectoryChangeForTesting(
            _ workingDirectory: String
        ) -> Bool {
            callbackContextOwnership?.takeUnretainedValue()
                .scheduleWorkingDirectoryChange(workingDirectory) ?? false
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
        let viewSize = bounds.size
        guard
            viewSize.width.isFinite,
            viewSize.height.isFinite,
            viewSize.width > 0,
            viewSize.height > 0
        else { return }

        let backingSize = convertToBacking(viewSize)
        let roundedWidth = backingSize.width.rounded(.down)
        let roundedHeight = backingSize.height.rounded(.down)
        guard
            roundedWidth.isFinite,
            roundedHeight.isFinite,
            roundedWidth > 0,
            roundedHeight > 0,
            roundedWidth <= CGFloat(UInt32.max),
            roundedHeight <= CGFloat(UInt32.max)
        else { return }

        let width = UInt32(roundedWidth)
        let height = UInt32(roundedHeight)
        let minimumSize = conservativeMinimumSurfaceSize(for: ghostty_surface_size(surface))
        guard width >= minimumSize.widthPixels, height >= minimumSize.heightPixels else { return }

        ghostty_surface_set_size(surface, width, height)

        #if DEBUG
            appendBoundedSizeObservation(
                GhosttySurfaceSizeRequestObservation(
                    requestedWidthPixels: width,
                    requestedHeightPixels: height,
                    resultingSize: sizeSnapshot(for: surface)
                ),
                to: &sizeRequestObservations
            )
        #endif
    }

    #if DEBUG
        private func sizeSnapshot(for surface: ghostty_surface_t) -> GhosttySurfaceSizeSnapshot {
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
    #endif

    private func clearLocalInputState() {
        markedText.mutableString.setString("")
        keyTextAccumulator = nil
        lastPerformKeyEvent = nil
    }

    private func clearLocalCursorState() {
        currentMouseShape = .text
        window?.invalidateCursorRects(for: self)
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
        captureInputEvent(event).wasProcessed
    }

    func captureInputEvent(_ event: NSEvent) -> GhosttySurfaceInputCapture {
        switch event.type {
        case .keyDown:
            captureKeyDown(event)
        case .keyUp:
            GhosttySurfaceInputCapture(
                wasProcessed: keyAction(.release, event: event),
                replay: .keyUp
            )
        case .flagsChanged:
            GhosttySurfaceInputCapture(
                wasProcessed: processFlagsChanged(event),
                replay: .flagsChanged
            )
        default:
            GhosttySurfaceInputCapture(wasProcessed: false, replay: nil)
        }
    }

    func replayInputEvent(
        _ event: NSEvent,
        replay: GhosttySurfaceInputReplay
    ) -> Bool {
        switch replay {
        case .keyDown(let action, let text, let composing):
            return replayKeyDown(
                event,
                action: action,
                text: text,
                composing: composing
            )
        case .keyUp:
            return keyAction(.release, event: event)
        case .flagsChanged:
            return processFlagsChanged(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            window?.isKeyWindow == true,
            window?.firstResponder === self,
            surface != nil
        else { return false }

        switch shortcutRoute(paneID, event) {
        case .appKit, .passThrough:
            lastPerformKeyEvent = nil
            return false
        case .handled:
            lastPerformKeyEvent = nil
            return true
        case .unmatched:
            break
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

    override func doCommand(by _: Selector) {
        guard let lastPerformKeyEvent,
            let currentEvent = NSApp.currentEvent,
            lastPerformKeyEvent == currentEvent.timestamp
        else { return }

        NSApp.sendEvent(currentEvent)
    }

    private func captureKeyDown(_ event: NSEvent) -> GhosttySurfaceInputCapture {
        guard let translationEvent = translationEvent(for: event) else {
            return GhosttySurfaceInputCapture(wasProcessed: false, replay: nil)
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
            return GhosttySurfaceInputCapture(wasProcessed: true, replay: nil)
        }

        syncPreedit(clearIfNeeded: hadMarkedText)

        if let accumulatedText = keyTextAccumulator,
            !accumulatedText.isEmpty
        {
            let result = sendKeyTexts(
                accumulatedText,
                action: action,
                event: event,
                translationEvent: translationEvent
            )
            return GhosttySurfaceInputCapture(
                wasProcessed: result,
                replay: .keyDown(
                    action: action,
                    text: .sourceInterpreted(accumulatedText),
                    composing: false
                )
            )
        }

        let composing = markedText.length > 0 || hadMarkedText
        let result = keyAction(
            action,
            event: event,
            translationEvent: translationEvent,
            text: controlSlashText(for: event) ?? translationEvent.ghosttyCharacters,
            composing: composing
        )
        return GhosttySurfaceInputCapture(
            wasProcessed: result,
            replay: .keyDown(
                action: action,
                text: .targetFallback,
                composing: composing
            )
        )
    }

    private func replayKeyDown(
        _ event: NSEvent,
        action: GhosttyInputAction,
        text: GhosttySurfaceInputReplay.KeyText,
        composing: Bool
    ) -> Bool {
        guard let translationEvent = translationEvent(for: event) else { return false }

        switch text {
        case .sourceInterpreted(let texts):
            // Marked text belongs to AppKit's current responder, so only committed text is replayed.
            return sendKeyTexts(
                texts,
                action: action,
                event: event,
                translationEvent: translationEvent,
                composing: composing
            )
        case .targetFallback:
            return keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: controlSlashText(for: event) ?? translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    private func translationEvent(for event: NSEvent) -> NSEvent? {
        guard let surface else { return nil }

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
        guard translationModifiers != event.modifierFlags else { return event }

        return NSEvent.keyEvent(
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

    private func sendKeyTexts(
        _ texts: [String],
        action: GhosttyInputAction,
        event: NSEvent,
        translationEvent: NSEvent,
        composing: Bool = false
    ) -> Bool {
        var result = false
        for text in texts {
            result = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: text,
                composing: composing
            )
            if callbackContextOwnership?.takeUnretainedValue().hasTerminalClosePending == true {
                break
            }
        }
        return result
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

        #if DEBUG
            interpretedTextObservations.append(text)
        #endif

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
        _ = terminalActionRoute(paneID, .copy)
    }

    @IBAction func paste(_ sender: Any?) {
        _ = terminalActionRoute(paneID, .paste)
    }

    @IBAction func pasteSelection(_ sender: Any?) {
        _ = terminalActionRoute(paneID, .pasteSelection)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = terminalActionRoute(paneID, .selectAll)
    }

    @discardableResult
    func performTerminalShortcutAction(_ action: TerminalShortcutAction) -> Bool {
        guard let surface else { return false }
        let coreAction = action.coreAction
        let result = coreAction.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(coreAction.utf8.count))
        }

        #if DEBUG
            if terminalActionObservations.count == ghosttyClipboardObservationLimit {
                terminalActionObservations.removeFirst()
            }
            terminalActionObservations.append(
                GhosttySurfaceTerminalActionObservation(action: action, result: result)
            )
        #endif

        return result
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
        case .mouseShapeChanged(let shape):
            updateMouseShape(shape)
        case .pwdChanged(let workingDirectory):
            currentWorkingDirectory = workingDirectory
        }
    }

    private func updateMouseShape(_ shape: GhosttyMouseShape) {
        guard shape.cursor != nil, currentMouseShape != shape else { return }
        currentMouseShape = shape
        window?.invalidateCursorRects(for: self)

        #if DEBUG
            mouseShapeUpdateCount += 1
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
        var pendingMouseShape: GhosttyMouseShape?
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
            state.pendingMouseShape = nil
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

    var latestWorkingDirectory: String? {
        state.withLock { $0.pendingWorkingDirectory }
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
    func scheduleMouseShape(_ shape: GhosttyMouseShape) -> Bool {
        let result = state.withLock { state in
            guard state.isActive else { return (accepted: false, shouldSchedule: false) }
            let shouldSchedule = state.pendingMouseShape == nil
            state.pendingMouseShape = shape
            return (accepted: true, shouldSchedule: shouldSchedule)
        }
        guard result.accepted else { return false }

        if result.shouldSchedule {
            Task { @MainActor [self] in
                deliverMouseShapeIfActive()
            }
        }
        return true
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
    private func deliverMouseShapeIfActive() {
        let shape = state.withLock { state -> GhosttyMouseShape? in
            guard state.isActive else { return nil }
            let shape = state.pendingMouseShape
            state.pendingMouseShape = nil
            return shape
        }
        guard let shape else { return }
        eventHandler(paneID, .mouseShapeChanged(shape))
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
            case .newTab:
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
