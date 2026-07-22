import AppKit
import SwiftUI

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
    private let palette: GhosttyChromePalette
    private let dividerColor: Color
    private let callbacks: GhosttySplitTreeCallbacks

    init(
        root: SplitNode,
        surfaces: [PaneID: GhosttySurfaceView],
        failures: [PaneID: SurfaceFailurePresentation],
        palette: GhosttyChromePalette,
        onResize: @escaping (UUID, Double) -> Void,
        onEqualize: @escaping (UUID) -> Void,
        onRetryUnavailablePane: @escaping (PaneID) -> Void,
        onCloseUnavailablePane: @escaping (PaneID) -> Void
    ) {
        self.root = GhosttySplitTreeDescriptor(root: root)
        self.surfaces = surfaces
        self.failures = failures
        self.palette = palette
        dividerColor = Self.dividerColor(for: palette)
        callbacks = GhosttySplitTreeCallbacks(
            onResize: onResize,
            onEqualize: onEqualize,
            onRetryUnavailablePane: onRetryUnavailablePane,
            onCloseUnavailablePane: onCloseUnavailablePane
        )
    }

    var body: some View {
        GhosttySplitNodeView(
            node: root,
            surfaces: surfaces,
            failures: failures,
            palette: palette,
            dividerColor: dividerColor,
            callbacks: callbacks
        )
    }

    private static func dividerColor(for palette: GhosttyChromePalette) -> Color {
        let foreground = NSColor(ghosttyRGB: palette.foreground)
        let background = NSColor(ghosttyRGB: palette.background)
        return Color(nsColor: foreground.blended(withFraction: 0.7, of: background) ?? foreground)
    }
}

@MainActor
private struct GhosttySplitNodeView: View {
    let node: GhosttySplitTreeDescriptor
    let surfaces: [PaneID: GhosttySurfaceView]
    let failures: [PaneID: SurfaceFailurePresentation]
    let palette: GhosttyChromePalette
    let dividerColor: Color
    let callbacks: GhosttySplitTreeCallbacks

    @ViewBuilder
    var body: some View {
        switch node {
        case .pane(let paneID):
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
private struct GhosttySurfaceRepresentable: NSViewRepresentable {
    let surface: GhosttySurfaceView

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        surface
    }

    func updateNSView(_: GhosttySurfaceView, context _: Context) {}
}
