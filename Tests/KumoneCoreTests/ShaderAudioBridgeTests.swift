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

        // The published band never reaches the raw swing, and it never moves
        // more than a slice of it in one frame — that is the difference between
        // a shader swaying and a shader twitching.
        XCTAssertLessThan(maxValue, ShaderAudioBridge.reactivity)
        XCTAssertLessThan(maxJump, 0.2)
    }

    func testLoudnessRisesAndDecaysSlowly() {
        var bridge = ShaderAudioBridge()

        // Drive it loud for a while.
        var frame = bridge.frame(sampler: { _ in 1 })
        for _ in 0..<100 {
            frame = bridge.frame(sampler: { _ in 1 })
        }
        let loud = frame.loudness
        // Loudness tracks the attenuated mean, not the raw level: a full-scale
        // input settles partway up rather than to 1.
        XCTAssertGreaterThan(loud, 0.3)
        XCTAssertLessThan(loud, 0.7)

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
}
