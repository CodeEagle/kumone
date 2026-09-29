import Foundation
import XCTest

@testable import KumoneCore

final class ShaderAudioBridgeTests: XCTestCase {

    // MARK: - Level / loudness

    func testSilentFrameStaysSilent() {
        var bridge = ShaderAudioBridge()
        let frame = bridge.frame(sampler: { _ in 0 })

        XCTAssertEqual(frame.level, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.loudness, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.beat, 0, accuracy: 1e-6)
    }

    func testLevelIsMeanOfFourBands() {
        var bridge = ShaderAudioBridge()

        // The published bands are attenuated by `reactivity` and eased toward
        // their target, so steady state is what a shader actually sits at.
        for _ in 0..<200 {
            _ = bridge.frame(sampler: { i in Float(i) / 3.0 })
        }
        let frame = bridge.frame(sampler: { i in Float(i) / 3.0 })

        // Bands 0, 0.333, 0.666, 1, each scaled by reactivity, mean 0.5*0.4.
        let expected = ShaderAudioBridge.reactivity
        XCTAssertEqual(frame.level, 0.5 * expected, accuracy: 1e-3)
        XCTAssertEqual(frame.low, 0, accuracy: 1e-3)
        XCTAssertEqual(frame.mid, 0.5 * expected, accuracy: 1e-3)
        XCTAssertEqual(frame.high, expected, accuracy: 1e-3)
    }

    func testBandsAreEasedRatherThanTracked() {
        var bridge = ShaderAudioBridge()

        // A level that flips every frame is exactly the raw bounce the shaders
        // must not see: the published band should stay bounded and move a
        // fraction of the full swing per frame.
        var previous: Float = 0
        var maxJump: Float = 0
        var maxValue: Float = 0
        for frame in 0..<100 {
            let raw: Float = frame.isMultiple(of: 2) ? 1.0 : 0.0
            let f = bridge.frame(sampler: { _ in raw })
            maxJump = max(maxJump, abs(f.low - previous))
            maxValue = max(maxValue, f.low)
            previous = f.low
        }

        // The band tracks the music closely — `reactivity` is 1.0, so a shader
        // that wants the real level gets it — while still never jumping the
        // full raw swing in one frame. That difference is what separates a
        // shader swaying from a shader twitching. (An alternating input settles
        // well below the raw peak: a one-pole filter with asymmetric
        // coefficients cannot follow a square wave to its peaks.)
        XCTAssertLessThanOrEqual(maxValue, 1.0)
        XCTAssertLessThan(maxJump, 0.2)

        // A level that *holds* must be published at full strength, though: that
        // is what the host used to take away with its 0.3 reactivity.
        var held = ShaderAudioBridge()
        var steady = held.frame(sampler: { _ in 1 })
        for _ in 0..<200 { steady = held.frame(sampler: { _ in 1 }) }
        XCTAssertGreaterThan(steady.low, 0.98)
        XCTAssertGreaterThan(steady.level, 0.98)
    }

    func testLoudnessRisesAndDecaysSlowly() {
        var bridge = ShaderAudioBridge()

        // Drive it at a level that leaves loudness clear of its 1.0 clamp, so
        // the release is observable instead of sitting pinned at the ceiling.
        var frame = bridge.frame(sampler: { _ in 0.5 })
        for _ in 0..<200 {
            frame = bridge.frame(sampler: { _ in 0.5 })
        }
        let loud = frame.loudness
        // Loudness follows the unattenuated mean: a half-scale input settles
        // around 0.5 * 1.35 rather than being scaled down again on the way out.
        XCTAssertGreaterThan(loud, 0.5)
        XCTAssertLessThan(loud, 0.8)

        // Then silent: loudness should fall, but not to zero in one frame —
        // the release is deliberately slower than the attack.
        let afterSilence = bridge.frame(sampler: { _ in 0 })
        XCTAssertLessThan(afterSilence.loudness, loud)
        XCTAssertGreaterThan(afterSilence.loudness, 0)
    }

    // MARK: - Beat

    func testSustainedBassDoesNotSpamBeats() {
        var bridge = ShaderAudioBridge()
        // A constant low band becomes the running mean, so nothing rises above
        // it and no beat fires.
        for _ in 0..<80 {
            let frame = bridge.frame(sampler: { i in i == 0 ? 0.8 : 0 })
            XCTAssertLessThan(frame.beat, 0.9)
        }
    }

    func testTransientRiseFiresABeat() {
        var bridge = ShaderAudioBridge()
        // Establish a quiet baseline so a kick actually stands out.
        for _ in 0..<40 {
            _ = bridge.frame(sampler: { _ in 0.1 })
        }
        let beforeBeat = bridge.frame(sampler: { i in i == 0 ? 1.0 : 0.1 })
        XCTAssertGreaterThan(beforeBeat.beat, 0.1)
    }

    func testBeatDecaysBetweenHits() {
        var bridge = ShaderAudioBridge()
        for _ in 0..<40 {
            _ = bridge.frame(sampler: { _ in 0.1 })
        }
        let peak = bridge.frame(sampler: { i in i == 0 ? 1.0 : 0.1 })
        let after = bridge.frame(sampler: { _ in 0.1 })
        // The envelope eases off rather than snapping to zero.
        XCTAssertLessThan(after.beat, peak.beat)
        XCTAssertGreaterThan(after.beat, 0)
    }

    // MARK: - Reset

    func testResetClearsHistory() {
        var bridge = ShaderAudioBridge()
        for _ in 0..<50 {
            _ = bridge.frame(sampler: { _ in 1 })
        }
        let before = bridge.frame(sampler: { i in i == 0 ? 1.0 : 0 })
        // The low band now sits far above its own running mean, so a beat fires.
        XCTAssertGreaterThan(before.beat, 0.2)

        bridge.reset()
        // After reset the history starts over: the mean is built from the
        // single new sample, so the same input no longer reads as a transient.
        let after = bridge.frame(sampler: { i in i == 0 ? 1.0 : 0 })
        XCTAssertLessThan(after.beat, before.beat)
    }

    /// The beat history is a fixed ring precisely so this path cannot allocate;
    /// after a reset it has to behave exactly like a bridge that never ran.
    func testResetLeavesTheRingBehavingLikeAFreshBridge() {
        var used = ShaderAudioBridge()
        for _ in 0..<50 {
            _ = used.frame(sampler: { _ in 1 })
        }
        used.reset()

        var fresh = ShaderAudioBridge()
        for step in 0..<40 {
            let input: (Int) -> Float = { i in i == 0 ? Float(step % 7) / 7 : 0.1 }
            let a = used.frame(sampler: input)
            let b = fresh.frame(sampler: input)
            XCTAssertEqual(a.bands.0, b.bands.0, accuracy: 1e-6)
            XCTAssertEqual(a.beat, b.beat, accuracy: 1e-6)
            XCTAssertEqual(a.loudness, b.loudness, accuracy: 1e-6)
        }
    }
}
