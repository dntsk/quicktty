import Foundation

@MainActor
final class AgentIntegrationUpdateOfferStore {
    private static let lastOfferedBuildKey =
        "com.dntsk.QuickTTY.AgentIntegrations.lastUpdateOfferBuild"
    private static let maximumBuildLength = 128

    private let build: String
    private let defaults: UserDefaults

    convenience init?(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        self.init(build: build, defaults: defaults)
    }

    init?(build: String, defaults: UserDefaults) {
        guard !build.isEmpty,
            build.utf8.count <= Self.maximumBuildLength,
            !build.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        self.build = build
        self.defaults = defaults
    }

    var shouldOffer: Bool {
        defaults.string(forKey: Self.lastOfferedBuildKey) != build
    }

    func recordOffered() {
        guard shouldOffer else { return }
        defaults.set(build, forKey: Self.lastOfferedBuildKey)
    }
}
