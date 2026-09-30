import Foundation
import XCTest

@testable import KumoneCore

final class ShaderUniformsTests: XCTestCase {

    /// The Swift mirror must match the MSL `Uniforms` byte-for-byte, since the
    /// host copies it straight into a Metal buffer. MSL lays the struct out at
    /// 128 bytes: `time` at 0, `resolution` 8-aligned at 8, `bands` at 16, the
    /// scalar envelope at 32, and the four 16-byte-aligned palette float4s
    /// starting at 64 — the `_pad` field plus alignment padding covers 56..64.
    func testUniformsMatchMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.size, 128)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.alignment, 16)
    }

    func testUniformsAreContiguousInBuffer() {
        // The stride matching the size means no per-element padding when packed
        // into an array; the single-buffer layout relies on that.
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 128)
    }

    func testPaletteFallbackIsOpaque() {
        let palette = ShaderPalette.fallback
        XCTAssertEqual(palette.primary.w, 1, accuracy: 1e-6)
        XCTAssertEqual(palette.background.w, 1, accuracy: 1e-6)
    }

    func testPaletteBuilderDerivesAccentAndBackgroundForAnUnanalyzedTrack() {
        // No analysed cover: `ArtworkPalette` only fills the `shader*` slots once
        // it has looked at real pixels, so this is the idle/broken-artwork path
        // and keeps the subdued ambient colours rather than inventing a scheme.
        let colors = ArtworkColors(
            primary: SIMD4<Float>(0.8, 0.2, 0.3, 1),
            secondary: SIMD4<Float>(0.1, 0.1, 0.15, 1)
        )
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Accent lifts brightness while preserving channel ratios.
        XCTAssertGreaterThan(palette.accent.x, palette.primary.x)
        // With no cover there is no hue to tint, so the base stays neutral black.
        XCTAssertEqual(palette.background.x, 0, accuracy: 1e-6)
        // sRGB inputs are decoded for the sRGB render target.
        XCTAssertEqual(palette.primary.x, Float(0.603827), accuracy: 1e-4)
        XCTAssertEqual(palette.secondary.x, Float(0.010023), accuracy: 1e-4)
    }

    func testPaletteBuilderHandlesFallbackColors() {
        let palette = ShaderPaletteBuilder.make(from: .fallback)
        // Must not produce NaN for any input the app can hand it.
        for component in [palette.primary, palette.secondary, palette.accent, palette.background] {
            XCTAssertFalse(component.x.isNaN)
            XCTAssertFalse(component.y.isNaN)
            XCTAssertFalse(component.z.isNaN)
        }
    }

    func testRedAccentDoesNotTurnWhite() {
        let palette = ShaderPaletteBuilder.make(from: ArtworkColors(
            primary: SIMD4<Float>(0.8, 0.1, 0.05, 1),
            secondary: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        ))
        XCTAssertLessThan(palette.accent.y, 0.02)
        XCTAssertLessThan(palette.accent.z, 0.01)
        XCTAssertEqual(palette.accent.y / palette.accent.x,
                       palette.primary.y / palette.primary.x, accuracy: 1e-5)
    }

    @MainActor
    func testCoverColorsPreserveRedAndBlueInsteadOfInventingPurple() throws {
        let colors = try extractCover(primary: (255, 0, 0, 255), secondary: (0, 0, 255, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)
        // The two halves stay red and blue, at the levels the scheme uses:
        // primary is the subject colour, secondary the dimmer supporting one.
        // Peaks are lifted (0.68 / 0.50 linear) because the palette composites
        // over a frosted window that attenuates it; the old 0.5 / 0.28 read as
        // grey once they survived that dimming.
        XCTAssertEqual(palette.primary.x, 0.68, accuracy: 0.01)
        XCTAssertEqual(palette.primary.z, 0, accuracy: 0.01)
        XCTAssertEqual(palette.secondary.x, 0, accuracy: 0.01)
        XCTAssertEqual(palette.secondary.z, 0.50, accuracy: 0.01)
        // The pre-existing ambient UI still gets its intentionally dimmed color.
        XCTAssertNotEqual(colors.primary, colors.shaderPrimary)
    }

    @MainActor
    func testCoverBackgroundCarriesTheCoversHueInsteadOfBlack() throws {
        let colors = try extractCover(primary: (255, 0, 0, 255), secondary: (0, 0, 255, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Most shaders fill everything that is not their subject with this slot,
        // so a black background is what made the backdrop stop looking like the
        // song. It has to be the cover's own hue ...
        XCTAssertGreaterThan(palette.background.x, 0.02)
        XCTAssertEqual(palette.background.z, 0, accuracy: 0.01)
        XCTAssertEqual(palette.background.y, 0, accuracy: 0.01)
        // ... and still dark enough to sit behind controls.
        XCTAssertLessThan(palette.background.x, 0.06)
        XCTAssertLessThan(palette.background.x, palette.primary.x)
    }

    @MainActor
    func testAccentIsTheBrightestSlotAndHueSeparatedFromTheSubject() throws {
        let colors = try extractCover(primary: (255, 0, 0, 255), secondary: (0, 0, 255, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Shaders draw their glow with the accent, so it has to be the brightest
        // slot — otherwise the glow reads as noise.
        let peak = { (c: SIMD4<Float>) in max(c.x, max(c.y, c.z)) }
        XCTAssertGreaterThan(peak(palette.accent), peak(palette.primary))
        XCTAssertGreaterThan(peak(palette.primary), peak(palette.secondary))
        XCTAssertGreaterThan(peak(palette.accent), peak(palette.background))
        // And it must be a different colour, not just a brighter red: a violet
        // accent off this red/blue cover keeps the two hues apart.
        XCTAssertGreaterThan(palette.accent.z, palette.accent.x)
    }

    @MainActor
    func testMonochromeCoverStillGetsASeparatedSecondary() throws {
        // Two shades of one hue: nothing in the artwork separates them, so the
        // scheme has to separate them itself rather than emitting two reds.
        let colors = try extractCover(primary: (200, 20, 20, 255), secondary: (120, 10, 10, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Primary stays the cover's red; secondary moves off it (here toward the
        // cover's other side rather than into a second red) so shaders still get
        // two colours to work with.
        XCTAssertLessThan(palette.primary.y, 0.02)
        XCTAssertLessThan(palette.primary.z, 0.02)
        XCTAssertGreaterThan(palette.secondary.z, 0.15)
        XCTAssertGreaterThan(palette.accent.x, palette.accent.z)
    }

    @MainActor
    func testPaletteIsDeterministic() throws {
        let first = try extractCover(primary: (34, 120, 210, 255), secondary: (240, 190, 20, 255))
        let second = try extractCover(primary: (34, 120, 210, 255), secondary: (240, 190, 20, 255))
        let a = ShaderPaletteBuilder.make(from: first)
        let b = ShaderPaletteBuilder.make(from: second)

        XCTAssertEqual(a.primary, b.primary)
        XCTAssertEqual(a.secondary, b.secondary)
        XCTAssertEqual(a.accent, b.accent)
        XCTAssertEqual(a.background, b.background)
    }

    @MainActor
    func testEverySlotStaysInRangeForEveryCover() throws {
        let covers = try [
            extractCover(primary: (204, 204, 204, 255), secondary: (204, 204, 204, 255)),
            extractCover(primary: (0, 200, 40, 255), secondary: (250, 0, 120, 255)),
            extractCover(primary: (3, 3, 3, 255), secondary: (1, 1, 1, 255)),
            .fallback,
        ]
        for colors in covers {
            let palette = ShaderPaletteBuilder.make(from: colors)
            for component in [palette.primary, palette.secondary, palette.accent, palette.background] {
                XCTAssertTrue(component.x.isFinite)
                XCTAssertTrue(component.y.isFinite)
                XCTAssertTrue(component.z.isFinite)
                for channel in [component.x, component.y, component.z] {
                    XCTAssertGreaterThanOrEqual(channel, 0)
                    XCTAssertLessThanOrEqual(channel, 1)
                }
            }
        }
    }

    @MainActor
    func testNearBlackCoverFallsBackRatherThanInventingAColour() throws {
        let colors = try extractCover(primary: (3, 3, 3, 255), secondary: (1, 1, 1, 255))
        // Linear-light brightness of almost-black is below the usable floor, so
        // the scheme falls back instead of stretching noise into a palette.
        let palette = ShaderPaletteBuilder.make(from: colors)
        XCTAssertEqual(palette.primary.x, ShaderPalette.fallback.primary.x, accuracy: 1e-6)
        XCTAssertEqual(palette.background.z, ShaderPalette.fallback.background.z, accuracy: 1e-6)
    }

    @MainActor
    func testGrayCoverStaysNeutralAndRetainsBrightness() throws {
        let colors = try extractCover(primary: (204, 204, 204, 255), secondary: (204, 204, 204, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)
        // A grey cover has no hue to separate, so nothing is rotated for it: the
        // slots stay neutral instead of inventing a colour the artwork never had.
        XCTAssertEqual(palette.primary.x, palette.primary.y, accuracy: 1e-5)
        XCTAssertEqual(palette.primary.y, palette.primary.z, accuracy: 1e-5)
        XCTAssertEqual(palette.secondary.x, palette.secondary.y, accuracy: 1e-5)
        XCTAssertEqual(palette.accent.x, palette.accent.y, accuracy: 1e-5)
        XCTAssertEqual(palette.background.x, palette.background.z, accuracy: 1e-5)
        // Still a usable scheme: the subject is well clear of the dark base.
        XCTAssertGreaterThan(palette.primary.x, palette.background.x * 4)
    }

    @MainActor
    func testTransparentCoverUsesFallback() throws {
        let colors = try extractCover(primary: (0, 0, 0, 0), secondary: (0, 0, 0, 0))
        XCTAssertEqual(colors, .fallback)
    }

    @MainActor
    private func extractCover(
        primary: (UInt8, UInt8, UInt8, UInt8), secondary: (UInt8, UInt8, UInt8, UInt8)
    ) throws -> ArtworkColors {
        var bytes: [UInt8] = []
        for _ in 0..<10 {
            for x in 0..<10 {
                let pixel = x < 7 ? primary : secondary
                bytes.append(contentsOf: [pixel.0, pixel.1, pixel.2, pixel.3])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 10, height: 10, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 40, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return ArtworkPalette.extract(from: image, cacheKey: UUID().uuidString)
    }

}
