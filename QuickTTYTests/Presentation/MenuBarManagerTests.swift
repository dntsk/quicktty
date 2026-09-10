import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct MenuBarManagerTests {
    @Test
    func configuresBundledTemplateIconAndAccessibility() throws {
        _ = try #require(Bundle.main.image(forResource: "MenuBarIcon"))
        let application = NSApplication.shared
        let initialPolicy = application.activationPolicy()

        for manager in [MenuBarManager(), MenuBarManager(systemPresentationEnabled: false)] {
            let button = NSStatusBarButton(frame: .zero)
            manager.configure(button: button)

            let image = try #require(button.image)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(button.imageScaling == .scaleProportionallyDown)
            #expect(button.accessibilityLabel() == "QuickTTY")
            #expect(button.target === manager)
            #expect(button.action != nil)
            #expect(!manager.isMenuBarActive)
            #expect(application.activationPolicy() == initialPolicy)
        }
        #expect(application.activationPolicy() == initialPolicy)
    }

    @Test
    func disabledManagerIgnoresActivationAndDeactivation() {
        let application = NSApplication.shared
        let initialPolicy = application.activationPolicy()
        let manager = MenuBarManager(systemPresentationEnabled: false)

        #expect(!manager.isMenuBarActive)
        for _ in 0..<3 {
            manager.activateMenuBar()
            #expect(!manager.isMenuBarActive)
            #expect(application.activationPolicy() == initialPolicy)
            manager.deactivateMenuBar()
            #expect(!manager.isMenuBarActive)
            #expect(application.activationPolicy() == initialPolicy)
        }
    }

    @Test
    func disabledManagerRepeatedModesAndCleanupLeaveSystemPolicyUnchanged() {
        let application = NSApplication.shared
        let initialPolicy = application.activationPolicy()

        for finalMode in [PresentationMode.normal, .quake] {
            var manager: MenuBarManager? = MenuBarManager(systemPresentationEnabled: false)
            weak var releasedManager: MenuBarManager?
            releasedManager = manager

            for mode in [PresentationMode.normal, .normal, .quake, .quake, .normal, finalMode] {
                manager?.applyMode(mode)
                #expect(manager?.isMenuBarActive == false)
                #expect(application.activationPolicy() == initialPolicy)
            }

            manager = nil
            #expect(releasedManager == nil)
            #expect(application.activationPolicy() == initialPolicy)
        }
    }
}
