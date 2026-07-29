import Combine
import SwiftUI

// Adapted from Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift:400-600
// at commit 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
@MainActor
final class SearchState: ObservableObject {
    @Published var needle: String
    @Published var selected: UInt?
    @Published var total: UInt?

    init(needle: String = "") {
        self.needle = needle
    }
}

enum GhosttySearchInteractionDecision: Equatable {
    case close
}

struct GhosttySearchInteractionRegion: Equatable {
    let swiftUIFrame: CGRect

    func contains(
        hostPoint: CGPoint,
        hostBounds: CGRect,
        hostIsFlipped: Bool
    ) -> Bool {
        let swiftUIPoint = CGPoint(
            x: hostPoint.x - hostBounds.minX,
            y: hostIsFlipped
                ? hostBounds.maxY - hostPoint.y
                : hostPoint.y - hostBounds.minY
        )
        return swiftUIFrame.contains(swiftUIPoint)
    }
}

@MainActor
final class GhosttySearchInteractionState {
    var interactionRegion: GhosttySearchInteractionRegion?
}

private struct GhosttySearchBarFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

enum GhosttySearchPresentation {
    static let nextAction = "navigate_search:next"
    static let previousAction = "navigate_search:previous"

    static func countText(selected: UInt?, total: UInt?) -> String? {
        if let selected {
            return "\(selected + 1)/\(total.map(String.init) ?? "?")"
        }
        if let total {
            return "-/\(total)"
        }
        return nil
    }

    static func returnAction(shiftPressed: Bool) -> String {
        shiftPressed ? previousAction : nextAction
    }

    static func escapeDecision(needle: String) -> GhosttySearchInteractionDecision {
        .close
    }
}

extension Notification.Name {
    fileprivate static let quickTTYGhosttySearchFocus = Notification.Name(
        "QuickTTY.GhosttySearchFocus"
    )
}

struct GhosttySurfaceSearchOverlay: View {
    @ObservedObject var searchState: SearchState
    let interactionState: GhosttySearchInteractionState
    let onBindingAction: (String) -> Void
    let onSearchFieldFocusChanged: (Bool) -> Void
    let onClose: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @FocusState private var isSearchFieldFocused: Bool

    private let padding: CGFloat = 8
    private let coordinateSpaceName = "QuickTTY.GhosttySearchOverlay"

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(6)
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                        if let count = GhosttySearchPresentation.countText(
                            selected: searchState.selected,
                            total: searchState.total
                        ) {
                            Text(count)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .padding(.trailing, 8)
                        }
                    }
                    .onChange(of: isSearchFieldFocused) { _, focused in
                        onSearchFieldFocusChanged(focused)
                    }
                    .onExitCommand {
                        _ = GhosttySearchPresentation.escapeDecision(
                            needle: searchState.needle
                        )
                        onClose()
                    }
                    .backport.onKeyPress(.return) { modifiers in
                        let shiftPressed = modifiers.contains(.shift)
                        let action = GhosttySearchPresentation.returnAction(
                            shiftPressed: shiftPressed
                        )
                        onBindingAction(action)
                        return .handled
                    }

                Button(
                    action: {
                        onBindingAction(GhosttySearchPresentation.nextAction)
                    },
                    label: {
                        Image(systemName: "chevron.up")
                    }
                )
                .buttonStyle(SearchButtonStyle())

                Button(
                    action: {
                        onBindingAction(GhosttySearchPresentation.previousAction)
                    },
                    label: {
                        Image(systemName: "chevron.down")
                    }
                )
                .buttonStyle(SearchButtonStyle())

                Button(action: {
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
            }
            .padding(8)
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
                requestSearchFieldFocusTransition()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .quickTTYGhosttySearchFocus
                )
            ) { notification in
                let matched = notification.object as? SearchState === searchState
                guard matched else { return }
                requestSearchFieldFocusTransition()
            }
            .background(
                GeometryReader { barGeo in
                    Color.clear.preference(
                        key: GhosttySearchBarFramePreferenceKey.self,
                        value: barGeo.frame(in: .named(coordinateSpaceName))
                    )
                }
            )
            .padding(padding)
            .offset(dragOffset)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: corner.alignment
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let centerPos = centerPosition(
                            for: corner,
                            in: geo.size,
                            barSize: barSize
                        )
                        let newCenter = CGPoint(
                            x: centerPos.x + value.translation.width,
                            y: centerPos.y + value.translation.height
                        )
                        let newCorner = closestCorner(to: newCenter, in: geo.size)
                        withAnimation(.easeOut(duration: 0.2)) {
                            corner = newCorner
                            dragOffset = .zero
                        }
                    }
            )
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(GhosttySearchBarFramePreferenceKey.self) { frame in
            let newBarSize = frame?.size ?? .zero
            barSize = newBarSize
            interactionState.interactionRegion = frame.map {
                GhosttySearchInteractionRegion(swiftUIFrame: $0)
            }
        }
    }

    private func requestSearchFieldFocusTransition() {
        isSearchFieldFocused = false
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private var clipShape: some Shape {
        if #available(macOS 26.0, *) {
            return ConcentricRectangle(
                corners: .concentric(minimum: 8),
                isUniform: true
            )
        } else {
            return RoundedRectangle(cornerRadius: 8)
        }
    }

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    private func centerPosition(
        for corner: Corner,
        in containerSize: CGSize,
        barSize: CGSize
    ) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding
        let halfHeight = barSize.height / 2 + padding

        switch corner {
        case .topLeft:
            return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight:
            return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft:
            return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight:
            return CGPoint(
                x: containerSize.width - halfWidth,
                y: containerSize.height - halfHeight
            )
        }
    }

    private func closestCorner(
        to point: CGPoint,
        in containerSize: CGSize
    ) -> Corner {
        let midX = containerSize.width / 2
        let midY = containerSize.height / 2

        if point.x < midX {
            return point.y < midY ? .topLeft : .bottomLeft
        } else {
            return point.y < midY ? .topRight : .bottomRight
        }
    }

    struct SearchButtonStyle: ButtonStyle {
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(
                    isHovered || configuration.isPressed ? .primary : .secondary
                )
                .padding(.horizontal, 2)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor(isPressed: configuration.isPressed))
                )
                .onHover { hovering in
                    isHovered = hovering
                }
                .backport.pointerStyle(.link)
        }

        private func backgroundColor(isPressed: Bool) -> Color {
            if isPressed {
                return Color.primary.opacity(0.2)
            } else if isHovered {
                return Color.primary.opacity(0.1)
            } else {
                return Color.clear
            }
        }
    }
}

extension SearchState {
    func requestFocus() {
        NotificationCenter.default.post(
            name: .quickTTYGhosttySearchFocus,
            object: self
        )
    }
}
