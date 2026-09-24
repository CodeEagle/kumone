import CoreGraphics
import Foundation

/// Dominant-color extraction for artwork-driven backgrounds
/// (kaset's ColorExtractor approach: tiny bitmap, saturation-weighted averages).
///
/// Colors are carried as `SIMD4<Float>` (RGBA, 0...1) rather than `Color`: the
/// palette feeds a Metal `float4` uniform, and staying numeric end-to-end
/// avoids resolving a `Color` on platforms where that is lossy.
public struct ArtworkColors: Equatable {
    public var primary: SIMD4<Float>
    public var secondary: SIMD4<Float>

    // Keep the ambient UI's subdued colors, but give shaders actual cover colors.
    public var shaderPrimary: SIMD4<Float>? = nil
    public var shaderSecondary: SIMD4<Float>? = nil

    public static let fallback = ArtworkColors(
        primary: SIMD4(0.16, 0.16, 0.20, 1),
        secondary: SIMD4(0.09, 0.09, 0.12, 1)
    )
}

public enum ArtworkPalette {
    private static var cache: [String: ArtworkColors] = [:]

    /// Extracts the dominant palette from a `CGImage`. Callers that hold a
    /// `PlatformImage` should use the UI-layer convenience in
    /// `ArtworkPaletteUI`, which performs the platform bitmap bridge.
    @MainActor
    public static func extract(from cgImage: CGImage, cacheKey: String) -> ArtworkColors {
        if let cached = cache[cacheKey] {
            return cached
        }
        let colors = compute(from: cgImage)
        if cache.count > 200 { cache.removeAll() }
        cache[cacheKey] = colors
        return colors
    }

    private static func compute(from cgImage: CGImage) -> ArtworkColors {
        let size = 10
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * size
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: size,
            height: size,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return .fallback }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var samples: [(h: CGFloat, s: CGFloat, b: CGFloat, weight: CGFloat)] = []
        var buckets: [Int: (sum: SIMD3<Double>, weight: Double)] = [:]
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * bytesPerPixel
                let r = CGFloat(rawData[offset]) / 255.0
                let g = CGFloat(rawData[offset + 1]) / 255.0
                let b_val = CGFloat(rawData[offset + 2]) / 255.0
                let a = CGFloat(rawData[offset + 3]) / 255.0
                guard a > 0.1 else { continue }

                // Quantize unpremultiplied sRGB: averaging unrelated hues can
                // invent a color absent from the cover. Area dominates, with
                // a small saturation preference; neutral covers stay neutral.
                let rgb = SIMD3<Double>(Double(r / a), Double(g / a), Double(b_val / a))
                let high = max(rgb.x, max(rgb.y, rgb.z))
                let low = min(rgb.x, min(rgb.y, rgb.z))
                let saturation = high > 0 ? (high - low) / high : 0
                // Vivid, bright colours read as the cover's identity even
                // when they cover little area; pure area weighting picks the
                // flat dark background and buries the accent. The 0.08 floor
                // keeps muted covers falling back to area dominance.
                let vivid = saturation * (0.2 + 0.8 * high)
                let coverWeight = Double(a) * (0.08 + 0.92 * vivid)
                let key = min(Int(rgb.x * 4), 3) * 16
                    + min(Int(rgb.y * 4), 3) * 4 + min(Int(rgb.z * 4), 3)
                let bucket = buckets[key] ?? (.zero, 0)
                buckets[key] = (bucket.sum + rgb * coverWeight, bucket.weight + coverWeight)

                // Convert RGB to HSB
                let maxC = max(r, max(g, b_val))
                let minC = min(r, min(g, b_val))
                let delta = maxC - minC

                var h: CGFloat = 0
                let s: CGFloat = maxC == 0 ? 0 : delta / maxC
                let b: CGFloat = maxC

                if delta > 0.00001 {
                    if r == maxC {
                        h = (g - b_val) / delta
                    } else if g == maxC {
                        h = 2 + (b_val - r) / delta
                    } else {
                        h = 4 + (r - g) / delta
                    }
                    h /= 6.0
                    if h < 0 { h += 1.0 }
                }

                // Weight vivid mid-brightness pixels highest.
                let weight = s * (1 - abs(b - 0.55))
                samples.append((h, s, b, max(weight, 0.01)))
            }
        }
        guard !samples.isEmpty else { return .fallback }

        // Dominant hue = weighted circular mean.
        var sinSum: CGFloat = 0, cosSum: CGFloat = 0, weightSum: CGFloat = 0
        var satSum: CGFloat = 0, brightSum: CGFloat = 0
        for sample in samples {
            let angle = sample.h * 2 * .pi
            sinSum += sin(angle) * sample.weight
            cosSum += cos(angle) * sample.weight
            satSum += sample.s * sample.weight
            brightSum += sample.b * sample.weight
            weightSum += sample.weight
        }
        var hue = atan2(sinSum, cosSum) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let saturation = min(satSum / weightSum * 1.15, 0.72)
        let brightness = brightSum / weightSum

        let primary = simd4(hue: hue, saturation: saturation,
                             brightness: min(max(brightness, 0.32), 0.5))
        let secondary = simd4(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1),
                               saturation: min(saturation * 1.1, 0.8),
                               brightness: min(max(brightness * 0.5, 0.12), 0.26))
        let ranked = buckets.sorted {
            $0.value.weight == $1.value.weight
                ? $0.key < $1.key : $0.value.weight > $1.value.weight
        }.map { $0.value.sum / $0.value.weight }
        guard let dominant = ranked.first else { return .fallback }
        let supporting = ranked.dropFirst().first {
            let delta = $0 - dominant
            return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z > 0.0225
        } ?? dominant
        return ArtworkColors(
            primary: primary, secondary: secondary,
            shaderPrimary: SIMD4(Float(dominant.x), Float(dominant.y), Float(dominant.z), 1),
            shaderSecondary: SIMD4(Float(supporting.x), Float(supporting.y), Float(supporting.z), 1)
        )
    }

    /// HSB (each 0...1) → RGBA float4. Same conversion SwiftUI's
    /// `Color(hue:saturation:brightness:)` applies, but stays numeric so the
    /// result drops straight into a Metal `float4` uniform.
    private static func simd4(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> SIMD4<Float> {
        let h = hue.truncatingRemainder(dividingBy: 1)
        let sector = Int(h * 6)
        let f = h * 6 - CGFloat(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch sector % 6 {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return SIMD4(Float(rgb.0), Float(rgb.1), Float(rgb.2), 1)
    }
}
