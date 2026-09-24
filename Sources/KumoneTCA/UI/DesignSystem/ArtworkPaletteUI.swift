import CoreGraphics
import KumoneCore
import SwiftUI

/// UI-layer face of `ArtworkPalette` (Core): the SwiftUI `Color` bridge and the
/// platform bitmap bridge that feeds the numeric extractor.

extension SIMD4<Float> {
    /// RGBA float4 → SwiftUI `Color` for the non-shader callers.
    var color: Color {
        Color(.sRGB, red: Double(x), green: Double(y), blue: Double(z), opacity: Double(w))
    }
}

extension ArtworkPalette {
    /// Extracts the dominant palette from a platform image, bridging to the
    /// `CGImage` the Core extractor speaks. Lives in the UI layer because
    /// `PlatformImage → CGImage` is an AppKit/UIKit concern.
    @MainActor
    static func extract(from image: PlatformImage, cacheKey: String) -> ArtworkColors {
        guard let cgImage = image.cgImageRef else { return .fallback }
        return extract(from: cgImage, cacheKey: cacheKey)
    }
}
