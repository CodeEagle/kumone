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

    func testPaletteBuilderDerivesAccentAndBackground() {
        let colors = ArtworkColors(
            primary: SIMD4<Float>(0.8, 0.2, 0.3, 1),
            secondary: SIMD4<Float>(0.1, 0.1, 0.15, 1)
        )
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Accent lifts brightness while preserving channel ratios.
        XCTAssertGreaterThan(palette.accent.x, palette.primary.x)
        // Background is the secondary deepened toward black.
        XCTAssertLessThan(palette.background.x, palette.secondary.x)
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
        XCTAssertEqual(palette.primary.x, 1, accuracy: 0.01)
        XCTAssertEqual(palette.primary.z, 0, accuracy: 0.01)
        XCTAssertEqual(palette.secondary.x, 0, accuracy: 0.01)
        XCTAssertEqual(palette.secondary.z, 1, accuracy: 0.01)
        // The pre-existing ambient UI still gets its intentionally dimmed color.
        XCTAssertNotEqual(colors.primary, colors.shaderPrimary)
    }

    @MainActor
    func testGrayCoverStaysNeutralAndRetainsBrightness() throws {
        let colors = try extractCover(primary: (204, 204, 204, 255), secondary: (204, 204, 204, 255))
        let palette = ShaderPaletteBuilder.make(from: colors)
        XCTAssertEqual(palette.primary.x, 0.603827, accuracy: 0.01)
        XCTAssertEqual(palette.primary.x, palette.primary.y, accuracy: 1e-5)
        XCTAssertEqual(palette.primary.y, palette.primary.z, accuracy: 1e-5)
        XCTAssertEqual(palette.accent.x, palette.accent.y, accuracy: 1e-5)
        XCTAssertEqual(palette.primary, palette.secondary)
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
