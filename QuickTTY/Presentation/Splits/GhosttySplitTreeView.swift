import AppKit
import Combine
import SwiftUI

struct PaneFocusDecoration: Equatable, Sendable {
    let overlayFill: GhosttyRGB
    let overlayOpacity: Double

    static func resolve(
        paneID: PaneID,
        activePaneID: PaneID?,
        appearance: GhosttySplitAppearance
    ) -> PaneFocusDecoration {
        PaneFocusDecoration(
            overlayFill: appearance.unfocusedFill,
            overlayOpacity: paneID == activePaneID ? 0 : appearance.unfocusedOverlayOpacity
        )
    }
}

@MainActor
final class WorkspacePresentationState: ObservableObject {
    @Published private(set) var isKeyWindow: Bool
    @Published private(set) var splitAppearance: GhosttySplitAppearance
    @Published private(set) var chromePalette: GhosttyChromePalette

    init(
        isKeyWindow: Bool = false,
        splitAppearance: GhosttySplitAppearance = .fallback,
        chromePalette: GhosttyChromePalette = .fallback
    ) {
        self.isKeyWindow = isKeyWindow
        self.splitAppearance = splitAppearance
        self.chromePalette = chromePalette
    }

    func setKeyWindow(_ isKeyWindow: Bool) {
        self.isKeyWindow = isKeyWindow
    }

    func setSplitAppearance(_ splitAppearance: GhosttySplitAppearance) {
        self.splitAppearance = splitAppearance
    }

    func setChromePalette(_ chromePalette: GhosttyChromePalette) {
        self.chromePalette = chromePalette
    }
}

indirect enum GhosttySplitTreeDescriptor: Equatable {
    enum Direction: Equatable {
        case horizontal
        case vertical

        var upstreamDirection: SplitViewDirection {
            switch self {
            case .horizontal:
                .horizontal
            case .vertical:
                .vertical
            }
        }
    }

    case pane(PaneID)
    case split(
        id: UUID,
        direction: Direction,
        ratio: Double,
        first: GhosttySplitTreeDescriptor,
        second: GhosttySplitTreeDescriptor
    )

    init(root: SplitNode) {
        switch root {
        case .pane(let paneID):
            self = .pane(paneID)
        case .split(let id, let axis, let ratio, let first, let second):
            self = .split(
                id: id,
                direction: axis == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                first: GhosttySplitTreeDescriptor(root: first),
                second: GhosttySplitTreeDescriptor(root: second)
            )
        }
    }
}

struct GhosttySplitTreeCallbacks {
    let onResize: (UUID, Double) -> Void
    let onEqualize: (UUID) -> Void
    let onRetryUnavailablePane: (PaneID) -> Void
    let onCloseUnavailablePane: (PaneID) -> Void

    func resize(_ splitID: UUID, ratio: Double) {
        onResize(splitID, ratio)
    }

    func equalize(_ splitID: UUID) {
        onEqualize(splitID)
    }

    func retryUnavailablePane(_ paneID: PaneID) {
        onRetryUnavailablePane(paneID)
    }

    func closeUnavailablePane(_ paneID: PaneID) {
        onCloseUnavailablePane(paneID)
    }
}

@MainActor
struct GhosttySplitTreeView: View {
    private let root: GhosttySplitTreeDescriptor
    private let surfaces: [PaneID: GhosttySurfaceView]
    private let failures: [PaneID: SurfaceFailurePresentation]
    private let activePaneID: PaneID?
    @ObservedObject private var presentationState: WorkspacePresentationState
    private let callbacks: GhosttySplitTreeCallbacks

    init(
        root: SplitNode,
        surfaces: [PaneID: GhosttySurfaceView],
        failures: [PaneID: SurfaceFailurePresentation],
        activePaneID: PaneID? = nil,
        presentationState: WorkspacePresentationState = WorkspacePresentationState(),
        onResize: @escaping (UUID, Double) -> Void,
        onEqualize: @escaping (UUID) -> Void,
        onRetryUnavailablePane: @escaping (PaneID) -> Void,
        onCloseUnavailablePane: @escaping (PaneID) -> Void
    ) {
        self.root = GhosttySplitTreeDescriptor(root: root)
        self.surfaces = surfaces
        self.failures = failures
        self.activePaneID = activePaneID
        self.presentationState = presentationState
        callbacks = GhosttySplitTreeCallbacks(
            onResize: onResize,
            onEqualize: onEqualize,
            onRetryUnavailablePane: onRetryUnavailablePane,
            onCloseUnavailablePane: onCloseUnavailablePane
        )
    }

    var body: some View {
        let palette = presentationState.chromePalette
        let dividerColor = Color(nsColor: NSColor(ghosttyRGB: Self.dividerRGB(for: palette)))

        GhosttySplitNodeView(
            node: root,
            surfaces: surfaces,
            failures: failures,
            palette: palette,
            activePaneID: activePaneID,
            splitAppearance: presentationState.splitAppearance,
            dividerColor: dividerColor,
            callbacks: callbacks
        )
    }

    static func dividerRGB(for palette: GhosttyChromePalette) -> GhosttyRGB {
        palette.foreground.blended(with: palette.background, fraction: 0.7)
    }
}

@MainActor
private struct GhosttySplitNodeView: View {
    let node: GhosttySplitTreeDescriptor
    let surfaces: [PaneID: GhosttySurfaceView]
    let failures: [PaneID: SurfaceFailurePresentation]
    let palette: GhosttyChromePalette
    let activePaneID: PaneID?
    let splitAppearance: GhosttySplitAppearance
    let dividerColor: Color
    let callbacks: GhosttySplitTreeCallbacks

    @ViewBuilder
    var body: some View {
        switch node {
        case .pane(let paneID):
            GhosttySplitLeafView(
                paneID: paneID,
                activePaneID: activePaneID,
                appearance: splitAppearance
            ) {
                if let surface = surfaces[paneID] {
                    GhosttySurfaceRepresentable(surface: surface)
                        .id(paneID)
                } else {
                    SurfaceErrorPlaceholder(
                        presentation: failures[paneID]
                            ?? SurfaceFailurePresentation(
                                message: "The terminal surface is unavailable."
                            ),
                        palette: palette,
                        onRetry: { callbacks.retryUnavailablePane(paneID) },
                        onClosePane: { callbacks.closeUnavailablePane(paneID) }
                    )
                    .id(paneID)
                }
            }
        case .split(let id, let direction, let ratio, let first, let second):
            SplitView(
                direction.upstreamDirection,
                Binding(
                    get: { CGFloat(ratio) },
                    set: { callbacks.resize(id, ratio: Double($0)) }
                ),
                dividerColor: dividerColor,
                left: {
                    GhosttySplitNodeView(
                        node: first,
                        surfaces: surfaces,
                        failures: failures,
                        palette: palette,
                        activePaneID: activePaneID,
                        splitAppearance: splitAppearance,
                        dividerColor: dividerColor,
                        callbacks: callbacks
                    )
                },
                right: {
                    GhosttySplitNodeView(
                        node: second,
                        surfaces: surfaces,
                        failures: failures,
                        palette: palette,
                        activePaneID: activePaneID,
                        splitAppearance: splitAppearance,
                        dividerColor: dividerColor,
                        callbacks: callbacks
                    )
                },
                onEqualize: {
                    callbacks.equalize(id)
                }
            )
        }
    }
}

@MainActor
private struct GhosttySplitLeafView<Content: View>: View {
    let paneID: PaneID
    let activePaneID: PaneID?
    let appearance: GhosttySplitAppearance
    let content: Content

    init(
        paneID: PaneID,
        activePaneID: PaneID?,
        appearance: GhosttySplitAppearance,
        @ViewBuilder content: () -> Content
    ) {
        self.paneID = paneID
        self.activePaneID = activePaneID
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        let decoration = PaneFocusDecoration.resolve(
            paneID: paneID,
            activePaneID: activePaneID,
            appearance: appearance
        )

        content
            .overlay {
                Color(nsColor: NSColor(ghosttyRGB: decoration.overlayFill))
                    .opacity(decoration.overlayOpacity)
                    .allowsHitTesting(false)
            }
    }
}

@MainActor
private struct GhosttySurfaceRepresentable: NSViewRepresentable {
    let surface: GhosttySurfaceView

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        surface
    }

    func updateNSView(_: GhosttySurfaceView, context _: Context) {}
}
