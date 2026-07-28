import AppKit
import Testing

@testable import QuickTTY

@MainActor
struct SearchOverlayViewTests {

    @Test
    func createsOverlay() {
        let overlay = SearchOverlayView(frame: .zero)
        #expect(overlay.subviews.count == 1)
    }

    @Test
    func updateCountFormats() {
        let overlay = SearchOverlayView(frame: .zero)

        overlay.updateCount(selected: 3, total: 17)
        #expect(countLabelText(overlay) == "3/17")

        overlay.updateCount(selected: nil, total: nil)
        #expect(countLabelText(overlay) == "-/-")

        overlay.updateCount(selected: 1, total: nil)
        #expect(countLabelText(overlay) == "1/-")

        overlay.updateCount(selected: nil, total: 5)
        #expect(countLabelText(overlay) == "-/5")
    }

    @Test
    func debounceDeliversLastNeedle() async throws {
        let overlay = SearchOverlayView(frame: .zero)
        var receivedNeedles: [String] = []
        overlay.onNeedleChange = { receivedNeedles.append($0) }

        // Drive the search field's action path directly.
        guard let searchField = firstSearchField(in: overlay) else {
            Issue.record("Search field not found in overlay")
            return
        }

        searchField.stringValue = "a"
        _ = overlay.performSearchFieldActionForTesting()
        searchField.stringValue = "ab"
        _ = overlay.performSearchFieldActionForTesting()
        searchField.stringValue = "abc"
        _ = overlay.performSearchFieldActionForTesting()

        // Wait for debounce (200ms + buffer).
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(receivedNeedles == ["abc"])
    }

    @Test
    func emptyNeedleDoesNotTriggerCallback() async throws {
        let overlay = SearchOverlayView(frame: .zero)
        var received = false
        overlay.onNeedleChange = { _ in received = true }

        guard let searchField = firstSearchField(in: overlay) else {
            Issue.record("Search field not found in overlay")
            return
        }
        searchField.stringValue = ""
        _ = overlay.performSearchFieldActionForTesting()

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(!received)
    }

    @Test
    func debounceCancelsPreviousWork() async throws {
        let overlay = SearchOverlayView(frame: .zero)
        var receivedNeedles: [String] = []
        overlay.onNeedleChange = { receivedNeedles.append($0) }

        guard let searchField = firstSearchField(in: overlay) else {
            Issue.record("Search field not found in overlay")
            return
        }

        // First needle - will be cancelled by second.
        searchField.stringValue = "first"
        _ = overlay.performSearchFieldActionForTesting()

        // Brief wait to ensure first work item is queued.
        try await Task.sleep(nanoseconds: 10_000_000)

        // Second needle cancels first.
        searchField.stringValue = "second"
        _ = overlay.performSearchFieldActionForTesting()

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(receivedNeedles == ["second"])
    }

    @Test
    func upArrowNavigatesPrevious() {
        let overlay = SearchOverlayView(frame: .zero)
        var navigation: SearchNavigation?
        overlay.onNavigate = { navigation = $0 }

        _ = overlay.simulateDoCommandForTesting(#selector(NSResponder.moveUp(_:)))

        #expect(navigation == .previous)
    }

    @Test
    func downArrowNavigatesNext() {
        let overlay = SearchOverlayView(frame: .zero)
        var navigation: SearchNavigation?
        overlay.onNavigate = { navigation = $0 }

        _ = overlay.simulateDoCommandForTesting(#selector(NSResponder.moveDown(_:)))

        #expect(navigation == .next)
    }

    @Test
    func escapeClosesAndClears() {
        let overlay = SearchOverlayView(frame: .zero)
        var clearFlag: Bool?
        overlay.onClose = { clearFlag = $0 }

        _ = overlay.simulateDoCommandForTesting(#selector(NSResponder.cancelOperation(_:)))

        #expect(clearFlag == true)
    }

    @Test
    func enterClosesWithoutClear() {
        let overlay = SearchOverlayView(frame: .zero)
        var clearFlag: Bool?
        overlay.onClose = { clearFlag = $0 }

        _ = overlay.simulateDoCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        #expect(clearFlag == false)
    }

    // MARK: - Helpers

    private func countLabelText(_ overlay: SearchOverlayView) -> String {
        for subview in overlay.subviews {
            if let stackView = subview as? NSStackView {
                for item in stackView.arrangedSubviews {
                    if let textField = item as? NSTextField,
                        textField !== stackView.arrangedSubviews.first
                    {
                        return textField.stringValue
                    }
                }
            }
        }
        return ""
    }

    private func firstSearchField(in overlay: SearchOverlayView) -> NSSearchField? {
        for subview in overlay.subviews {
            if let stackView = subview as? NSStackView {
                for item in stackView.arrangedSubviews {
                    if let searchField = item as? NSSearchField {
                        return searchField
                    }
                }
            }
        }
        return nil
    }
}

extension SearchOverlayView {
    /// Calls searchFieldDidChange via the target/action mechanism.
    fileprivate func performSearchFieldActionForTesting() -> Bool {
        guard let searchField = firstSearchFieldForTesting(),
            let target = searchField.target,
            let action = searchField.action
        else { return false }
        _ = target.perform(action, with: searchField)
        return true
    }

    /// Directly invokes the control(_:textView:doCommandBy:) delegate method.
    fileprivate func simulateDoCommandForTesting(_ selector: Selector) -> Bool {
        guard let searchField = firstSearchFieldForTesting(),
            let delegate = searchField.delegate as? SearchOverlayView
        else { return false }

        // Create a temporary text view to pass as the textView parameter.
        let textView = NSTextView(frame: .zero)
        return delegate.control(searchField, textView: textView, doCommandBy: selector)
    }

    private func firstSearchFieldForTesting() -> NSSearchField? {
        for subview in subviews {
            if let stackView = subview as? NSStackView {
                for item in stackView.arrangedSubviews {
                    if let searchField = item as? NSSearchField {
                        return searchField
                    }
                }
            }
        }
        return nil
    }
}
