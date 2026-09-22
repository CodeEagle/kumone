//
//  AudioSpectrumIngestTests.swift
//
//  Regression for the PCM ingest path that replaced the AVPlayer
//  MTAudioProcessingTap: the engine's `APlay.pcmTap` hands interleaved PCM to
//  `AudioSpectrum.ingest`, and band levels have to actually move with it.
//

import AVFoundation
import XCTest

@testable import KumoneCore

final class AudioSpectrumIngestTests: XCTestCase {

    /// Builds an interleaved stereo buffer list of `frameCount` frames and hands
    /// it to the spectrum the way the engine's tap does.
    private func feed(sine samples: inout [Int16], frameCount: Int, format: AVAudioFormat) {
        samples.withUnsafeBufferPointer { buffer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Int16>.size),
                    mData: UnsafeMutableRawPointer(mutating: buffer.baseAddress)))
            AudioSpectrum.shared.ingest(
                withUnsafePointer(to: &bufferList) { $0 },
                frameCount: UInt32(frameCount),
                format: format)
        }
    }

    /// A loud low-frequency sine has to land in the low band, and silence has to
    /// leave the levels flat.
    func testIngestProducesBandLevels() {
        AudioSpectrum.shared.beginPreparing()

        // 60Hz sine at a healthy level, interleaved stereo Int16 — the format
        // APlay hands the tap for a 44.1kHz source.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        let format = withUnsafePointer(to: &asbd) { AVAudioFormat(streamDescription: $0)! }
        let frameCount = 44_100   // one second
        var samples = [Int16](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let v = sinf(2 * .pi * 60 * Float(i) / 44_100) * 0.8
            samples[i * 2] = Int16(v * Float(Int16.max))
            samples[i * 2 + 1] = samples[i * 2]
        }

        // The analysis runs in 512-sample windows; feed enough of them that the
        // envelopes settle.
        for _ in 0..<8 {
            feed(sine: &samples, frameCount: frameCount, format: format)
        }

        XCTAssertTrue(AudioSpectrum.shared.isLive, "ingest never reported live audio")
        XCTAssertGreaterThan(AudioSpectrum.shared.level(at: 0), 0.05, "low band stayed flat for a loud bass sine")
        // A pure 60Hz tone has no business lighting up the 2.5–8kHz band: this is
        // the check that catches a misaligned read (samples read off-by-element
        // still produce non-zero levels, just in the wrong bands).
        XCTAssertLessThan(AudioSpectrum.shared.level(at: 3), 0.1, "high band moved for a pure bass sine")

        // Silence must not keep the levels pinned at the last value.
        var quiet = [Int16](repeating: 0, count: frameCount * 2)
        for _ in 0..<40 {
            feed(sine: &quiet, frameCount: frameCount, format: format)
        }
        XCTAssertEqual(AudioSpectrum.shared.level(at: 0), 0, accuracy: 0.05)

        AudioSpectrum.shared.markIdle()
    }

    /// The render quantum the engine delivers can be smaller than the FFT
    /// window — the live engine hands over 470 frames against a 512-sample
    /// window. Such quanta have to accumulate across calls; a per-call analysis
    /// would drop every one of them and the spectrum would report silence for a
    /// track that is plainly playing.
    func testIngestAccumulatesSubWindowQuanta() {
        AudioSpectrum.shared.beginPreparing()

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        let format = withUnsafePointer(to: &asbd) { AVAudioFormat(streamDescription: $0)! }
        let quantum = 470   // smaller than the 512-sample window
        var samples = [Int16](repeating: 0, count: quantum * 2)
        for i in 0..<quantum {
            let v = sinf(2 * .pi * 60 * Float(i) / 44_100) * 0.8
            samples[i * 2] = Int16(v * Float(Int16.max))
            samples[i * 2 + 1] = samples[i * 2]
        }

        // Roughly a second of audio in sub-window quanta.
        for _ in 0..<(44_100 / quantum) {
            feed(sine: &samples, frameCount: quantum, format: format)
        }

        XCTAssertTrue(AudioSpectrum.shared.isLive,
                      "sub-window quanta never accumulated into a full FFT window")
        XCTAssertGreaterThan(AudioSpectrum.shared.level(at: 0), 0.05,
                             "low band stayed flat for a loud bass sine fed in sub-window quanta")

        AudioSpectrum.shared.markIdle()
    }

    /// A track change has to reset the levels rather than leaving the previous
    /// track's frame frozen under the new one.
    func testBeginPreparingResetsLevels() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        let format = withUnsafePointer(to: &asbd) { AVAudioFormat(streamDescription: $0)! }
        let frameCount = 44_100
        var samples = [Int16](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let v = sinf(2 * .pi * 60 * Float(i) / 44_100) * 0.8
            samples[i * 2] = Int16(v * Float(Int16.max))
            samples[i * 2 + 1] = samples[i * 2]
        }
        for _ in 0..<8 { feed(sine: &samples, frameCount: frameCount, format: format) }
        XCTAssertGreaterThan(AudioSpectrum.shared.level(at: 0), 0.05)

        AudioSpectrum.shared.beginPreparing()
        for i in 0..<AudioSpectrum.bandCount {
            XCTAssertEqual(AudioSpectrum.shared.level(at: i), 0, accuracy: 1e-6)
        }
        XCTAssertFalse(AudioSpectrum.shared.isLive)
        XCTAssertEqual(AudioSpectrum.shared.tapState, .preparing)

        AudioSpectrum.shared.markIdle()
    }

    /// Float32 interleaved PCM (the other format a decoder can hand the tap)
    /// feeds the same path.
    func testIngestAcceptsFloat32() {
        AudioSpectrum.shared.beginPreparing()

        var floatAsbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let format = withUnsafePointer(to: &floatAsbd) { AVAudioFormat(streamDescription: $0)! }
        let frameCount = 44_100
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let v = sinf(2 * .pi * 60 * Float(i) / 44_100) * 0.8
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        samples.withUnsafeBufferPointer { buffer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: buffer.baseAddress)))
            for _ in 0..<8 {
                AudioSpectrum.shared.ingest(
                    withUnsafePointer(to: &bufferList) { $0 },
                    frameCount: UInt32(frameCount),
                    format: format)
            }
        }

        XCTAssertTrue(AudioSpectrum.shared.isLive)
        XCTAssertGreaterThan(AudioSpectrum.shared.level(at: 0), 0.05)

        AudioSpectrum.shared.markIdle()
    }
}
