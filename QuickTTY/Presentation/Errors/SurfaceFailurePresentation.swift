struct SurfaceFailurePresentation: Equatable, Sendable {
    static let unavailable = SurfaceFailurePresentation(
        message: "The terminal surface is unavailable."
    )

    let message: String
}
