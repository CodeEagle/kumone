import Foundation
import SwiftUI
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
            primary: Color(red: 0.8, green: 0.2, blue: 0.3),
            secondary: Color(red: 0.1, green: 0.1, blue: 0.15)
        )
        let palette = ShaderPaletteBuilder.make(from: colors)

        // Accent is the primary lifted toward white.
        XCTAssertGreaterThan(palette.accent.x, palette.primary.x)
        // Background is the secondary deepened toward black.
        XCTAssertLessThan(palette.background.x, palette.secondary.x)
        // Primary and secondary pass through unchanged.
        XCTAssertEqual(palette.primary.x, Float(0.8), accuracy: 1e-4)
        XCTAssertEqual(palette.secondary.x, Float(0.1), accuracy: 1e-4)
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
}
