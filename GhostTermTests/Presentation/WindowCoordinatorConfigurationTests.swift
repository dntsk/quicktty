import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WindowCoordinatorConfigurationTests {
    @Test
    func configTransitionsPresentationAndRegistersOnlyQuakeHotKey() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: hotKeyController
        )
        var config = GhostTermConfig()
        config.presentationMode = .quake
        config.globalToggle = HotKeyDescriptor(option: true, key: .f10)

        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .quake)
        #expect(hotKeyController.registeredDescriptors == [config.globalToggle])

        config.presentationMode = .normal
        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .normal)
        #expect(hotKeyController.unregisterCount == 1)
    }
}

@MainActor
private final class RecordingHotKeyController: HotKeyControlling {
    private(set) var registeredDescriptors: [HotKeyDescriptor] = []
    private(set) var unregisterCount = 0

    func register(_ descriptor: HotKeyDescriptor) throws {
        registeredDescriptors.append(descriptor)
    }

    func unregister() throws {
        unregisterCount += 1
    }
}
