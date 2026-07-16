import Testing

@testable import GhostTerm

struct PresentationModeTests {
    @Test
    func togglingTwiceReturnsToOriginalMode() {
        for mode in PresentationMode.allCases {
            #expect(mode.toggled.toggled == mode)
        }
    }

    @Test
    func rawValuesMatchConfigurationValues() {
        #expect(PresentationMode(rawValue: "normal") == .normal)
        #expect(PresentationMode(rawValue: "quake") == .quake)
        #expect(PresentationMode(rawValue: "fullscreen") == nil)
    }
}
