import Foundation

struct TerminalStatusPresentation: Equatable, Sendable {
    enum Phase: Int, Equatable, Sendable {
        case completed
        case working
        case waiting
        case failed
    }

    let phase: Phase
    let percent: Int?

    static func aggregate<S: Sequence>(_ states: S) -> TerminalStatusPresentation?
    where S.Element == TerminalActivityState {
        let contributions = states.map(Contribution.init)
        guard
            let winningPhase = contributions.map(\.phase).max(by: {
                $0.rawValue < $1.rawValue
            })
        else {
            return nil
        }

        let winners = contributions.filter { $0.phase == winningPhase }
        let percentages = winners.compactMap(\.percent)
        let percent =
            percentages.count == winners.count && !percentages.isEmpty
            ? percentages.reduce(0, +) / percentages.count
            : nil
        return TerminalStatusPresentation(phase: winningPhase, percent: percent)
    }

    var compactString: String {
        switch (phase, percent) {
        case (.working, let percent?), (.waiting, let percent?):
            "\(percent)%"
        case (.working, nil):
            "…"
        case (.waiting, nil):
            "⏸"
        case (.failed, _):
            "!"
        case (.completed, _):
            "✓"
        }
    }

    var accessibilityLabel: String {
        let state: String
        switch phase {
        case .working:
            state = "Terminal working"
        case .waiting:
            state = "Terminal waiting"
        case .failed:
            return "Terminal failed"
        case .completed:
            return "Terminal completed"
        }
        guard let percent else { return state }
        return "\(state), \(percent) percent"
    }

    private struct Contribution {
        let phase: Phase
        let percent: Int?

        init(_ state: TerminalActivityState) {
            switch state.phase {
            case .working(let progress):
                phase = .working
                percent = progress.map(Int.init)
            case .waiting(let progress):
                phase = .waiting
                percent = progress.map(Int.init)
            case .failed(let progress):
                phase = .failed
                percent = progress.map(Int.init)
            case .completed:
                phase = .completed
                percent = nil
            }
        }
    }
}
