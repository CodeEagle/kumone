import Combine

/// Session-only diagnostic: all cached artwork consumers observe the same gate.
@MainActor
public final class ImageLoadingControl: ObservableObject {
    public static let shared = ImageLoadingControl()
    @Published public private(set) var isDisabled = false

    public func setDisabled(_ disabled: Bool) async {
        if disabled { isDisabled = true }
        await ImageCache.shared.setLoadingDisabled(disabled)
        if !disabled { isDisabled = false }
        KumoneLogger.player.notice("IMAGE DIAGNOSTIC disabled=\(disabled)")
    }
}
