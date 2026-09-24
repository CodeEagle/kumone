import ComposableArchitecture
import Foundation

/// System clipboard, as a dependency. Thin wrapper so features that copy
/// (song links, lyrics) stay testable and platform-agnostic.
@DependencyClient
public struct PasteboardClient {
    /// Replaces the clipboard contents with the given string.
    public var setString: @Sendable (_ string: String) -> Void = { _ in }
}

extension PasteboardClient: DependencyKey {
    public static let liveValue = PasteboardClient()
    public static let testValue = PasteboardClient()
}

extension DependencyValues {
    public var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}
