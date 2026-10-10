import Foundation

/// Pixel dimensions, not SwiftUI points. Playback variants are shared only
/// while a consumer owns them; the cache must not pin previous-track bitmaps.
public struct ImageRendition: Hashable, Sendable {
    public let maxPixelSize: Int
    public let square: Bool
    public let transient: Bool

    public init(maxPixelSize: Int, square: Bool = true, transient: Bool = false) {
        self.maxPixelSize = min(1536, max(1, maxPixelSize))
        self.square = square
        self.transient = transient
    }

    public static let playback = Self(maxPixelSize: 768, transient: true)
    public static let thumbnail = Self(maxPixelSize: 96, transient: true)
    public static let systemArtwork = Self(maxPixelSize: 256, transient: true)

    static func automatic(for url: URL) -> Self {
        // Enforce the requested size locally even if the CDN ignores `param`.
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.last(where: { $0.name == "param" })?.value
        if let parts = value?.split(separator: "y"), parts.count == 2,
           let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 {
            return Self(maxPixelSize: max(width, height), square: width == height)
        }
        return Self(maxPixelSize: 1536, square: false)
    }

    var cacheSuffix: String { "\(maxPixelSize)-\(square)-\(transient)" }
}
