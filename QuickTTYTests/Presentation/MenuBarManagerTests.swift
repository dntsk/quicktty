import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct MenuBarManagerTests {
    @Test
    func configuresBundledTemplateIconAndAccessibility() throws {
        _ = try #require(Bundle.main.image(forResource: "MenuBarIcon"))
        let button = NSStatusBarButton(frame: .zero)

        MenuBarManager().configure(button: button)

        let image = try #require(button.image)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(button.accessibilityLabel() == "QuickTTY")
    }
}
