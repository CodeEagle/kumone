import Foundation
import XCTest
@testable import KumoneCore

/// The palette ease is the difference between a backdrop that dissolves into
/// the next song's colours and one that blinks at it, so the properties that
/// make it look like a dissolve — monotone approach, asymptotic arrival and
/// frame-rate independence — are asserted directly.
final class ShaderPaletteMixerTests: XCTestCase {

    private let blue = ShaderPalette(
        primary: SIMD4(0.1, 0.2, 0.8, 1),
        secondary: SIMD4(0.05, 0.1, 0.4, 1),
        accent: SIMD4(0.3, 0.6, 1.0, 1),
        background: SIMD4(0.01, 0.02, 0.06, 1)
    )
    private let red = ShaderPalette(
        primary: SIMD4(0.9, 0.2, 0.1, 1),
        secondary: SIMD4(0.5, 0.05, 0.05, 1),
        accent: SIMD4(1.0, 0.6, 0.3, 1),
        background: SIMD4(0.06, 0.01, 0.01, 1)
    )

    /// 60fps frame time.
    private let frame: Float = 1.0 / 60.0

    func testFirstFrameSnapsInsteadOfFadingFromNothing() {
        var mixer = ShaderPaletteMixer()
        mixer.step(toward: blue, dt: frame)
        XCTAssertEqual(mixer.current.primary.x, blue.primary.x, accuracy: 1e-6)
        XCTAssertEqual(mixer.current.background.z, blue.background.z, accuracy: 1e-6)
    }

    func testStepMovesMonotonicallyTowardTheTarget() {
        var mixer = ShaderPaletteMixer(startingAt: blue)
        var previous = mixer.current.primary.x

        for _ in 0..<60 {
            mixer.step(toward: red, dt: frame)
            XCTAssertGreaterThan(mixer.current.primary.x, previous)
            XCTAssertLessThanOrEqual(mixer.current.primary.x, red.primary.x)
            previous = mixer.current.primary.x
        }
    }

    func testArrivalIsAsymptoticRatherThanExact() {
        var mixer = ShaderPaletteMixer(startingAt: blue)
        for _ in 0..<600 { mixer.step(toward: red, dt: frame) }

        // Ten seconds in, the palette must read as the new track's colour ...
        XCTAssertEqual(mixer.current.primary.x, red.primary.x, accuracy: 0.01)
        // ... without ever having snapped exactly onto it.
        XCTAssertNotEqual(mixer.current.primary.x, red.primary.x)
    }

    /// A 120Hz display and a 30fps window must land on the same colour after
    /// the same amount of wall-clock time, which is what deriving the step from
    /// elapsed time buys.
    func testStepIsFrameRateIndependent() {
        var fast = ShaderPaletteMixer(startingAt: blue)
        var slow = ShaderPaletteMixer(startingAt: blue)

        for _ in 0..<120 { fast.step(toward: red, dt: 1.0 / 120.0) }
        for _ in 0..<30 { slow.step(toward: red, dt: 1.0 / 30.0) }

        XCTAssertEqual(fast.current.primary.x, slow.current.primary.x, accuracy: 0.01)
        XCTAssertEqual(fast.current.accent.z, slow.current.accent.z, accuracy: 0.01)
    }

    /// One big step and many small ones must agree: the coefficient has to come
    /// from dt, never from a hardcoded per-frame fraction.
    func testOneLongStepMatchesManyShortOnes() {
        var single = ShaderPaletteMixer(startingAt: blue)
        var stepped = ShaderPaletteMixer(startingAt: blue)
        single.step(toward: red, dt: 1.0)
        for _ in 0..<60 { stepped.step(toward: red, dt: frame) }

        XCTAssertEqual(single.current.primary.x, stepped.current.primary.x, accuracy: 0.02)
    }

    /// All four slots share one rate, so the palette is always a colour the
    /// cover actually contained instead of a cross-fade between two of them.
    func testAllFourSlotsEaseTogether() {
        var mixer = ShaderPaletteMixer(startingAt: blue)
        mixer.step(toward: red, dt: frame * 6)

        let fraction = mixer.current.primary.x - blue.primary.x
        let secondaryFraction = mixer.current.secondary.x - blue.secondary.x
        let accentFraction = mixer.current.accent.x - blue.accent.x
        let backgroundFraction = mixer.current.background.x - blue.background.x

        XCTAssertGreaterThan(fraction, 0)
        // Each slot covers the same share of its own distance to the target.
        for progress in [secondaryFraction / (red.secondary.x - blue.secondary.x),
                         accentFraction / (red.accent.x - blue.accent.x),
                         backgroundFraction / (red.background.x - blue.background.x)] {
            XCTAssertEqual(progress, fraction / (red.primary.x - blue.primary.x), accuracy: 1e-5)
        }
    }

    func testSnapIsInstant() {
        var mixer = ShaderPaletteMixer(startingAt: blue)
        mixer.step(toward: red, dt: frame)
        mixer.snap(to: red)

        XCTAssertEqual(mixer.current.accent.z, red.accent.z)
        // And a later frame keeps the snapped value when nothing else changes.
        mixer.step(toward: red, dt: frame)
        XCTAssertEqual(mixer.current.accent.z, red.accent.z, accuracy: 1e-6)
    }

    func testStepsStayFinite() {
        var mixer = ShaderPaletteMixer(startingAt: .fallback)
        // A stalled or resumed window can hand over an absurd dt; the ease must
        // stay a number.
        mixer.step(toward: blue, dt: 1e6)
        XCTAssertTrue(mixer.current.primary.x.isFinite)
        mixer.step(toward: blue, dt: -1)
        XCTAssertTrue(mixer.current.primary.y.isFinite)
        XCTAssertTrue(mixer.current.background.z.isFinite)
    }
}
