import Foundation
import Testing
@testable import PatronRadioCore

struct LoudnessPolicyTests {
    // Cases shared with the widget's test_radiobackend (tests/data/loudness_gain.json).
    @Test func sharedVectorsLoaded() {
        #expect(SharedVectors.loudnessGain.count >= 7)
    }

    @Test(arguments: SharedVectors.loudnessGain)
    func attenuatesOnlyAndClamps(_ c: SharedVectors.GainCase) {
        #expect(abs(Loudness.attenuationGainDB(measured: c.measured, target: c.target) - c.gain) < 1e-9)
    }

    @Test func manualGainRoundTrips() {
        for adj in [-0.5, -6.0, -12.0, -23.0] {
            #expect(Loudness.attenuationGainDB(measured: Loudness.targetLUFS - adj) == adj)
        }
        #expect(Loudness.attenuationGainDB(measured: Loudness.targetLUFS + 30) == -24)
    }

    @Test func measurability() {
        #expect(Loudness.isMeasurable(-18))
        #expect(Loudness.isMeasurable(-59))
        #expect(!Loudness.isMeasurable(-61))
        #expect(!Loudness.isMeasurable(-.infinity))
        #expect(!Loudness.isMeasurable(.nan))
    }

    @Test func slewIsRateLimited() {
        #expect(Loudness.slew(from: 0, to: -5) == -1)
        #expect(Loudness.slew(from: -1, to: -5) == -2)
        #expect(Loudness.slew(from: -4.5, to: -5) == -5)
        #expect(Loudness.slew(from: -10, to: 0) == -9)
    }
}

/// Calibration against EBU Tech 3341 conditions.
struct LoudnessMeterTests {
    private func sine(freq: Double, dbfs: Double, seconds: Double, rate: Double) -> [Float] {
        let amp = pow(10, dbfs / 20)
        return (0..<Int(seconds * rate)).map { Float(amp * sin(2 * .pi * freq * Double($0) / rate)) }
    }

    @Test(arguments: [44100.0, 48000.0])
    func stereoSineAtMinus23ReadsMinus23LUFS(rate: Double) {
        // Tech 3341 case 1: 1 kHz stereo sine at -23 dBFS → -23.0 LUFS (±0.1).
        let m = LoudnessMeter(channels: 2, sampleRate: rate)
        let s = sine(freq: 1000, dbfs: -23, seconds: 20, rate: rate)
        m.add([s, s])
        #expect(abs(m.integratedLoudness - -23.0) < 0.1)
    }

    @Test func relativeGateIgnoresQuietPassages() {
        // Tech 3341 case 3-style: -36 / -23 / -36 dBFS segments. The quiet parts are
        // more than 10 LU below the loud part, so the relative gate drops them.
        let rate = 48000.0
        let m = LoudnessMeter(channels: 2, sampleRate: rate)
        let s = sine(freq: 1000, dbfs: -36, seconds: 10, rate: rate)
            + sine(freq: 1000, dbfs: -23, seconds: 60, rate: rate)
            + sine(freq: 1000, dbfs: -36, seconds: 10, rate: rate)
        m.add([s, s])
        #expect(abs(m.integratedLoudness - -23.0) < 0.1)
    }

    @Test func silenceIsNotMeasurable() {
        let m = LoudnessMeter(channels: 2, sampleRate: 48000)
        let z = [Float](repeating: 0, count: 48000 * 3)
        m.add([z, z])
        #expect(!Loudness.isMeasurable(m.integratedLoudness))
    }

    @Test func monoIsThreeDBQuieterThanDualMono() {
        let rate = 48000.0
        let s = sine(freq: 1000, dbfs: -20, seconds: 10, rate: rate)
        let mono = LoudnessMeter(channels: 1, sampleRate: rate)
        mono.add([s])
        let stereo = LoudnessMeter(channels: 2, sampleRate: rate)
        stereo.add([s, s])
        #expect(abs((stereo.integratedLoudness - mono.integratedLoudness) - 3.01) < 0.05)
    }

    @Test func chunkingDoesNotChangeTheResult() {
        let rate = 44100.0
        let s = sine(freq: 440, dbfs: -14, seconds: 6, rate: rate)
        let whole = LoudnessMeter(channels: 1, sampleRate: rate)
        whole.add([s])
        let chunked = LoudnessMeter(channels: 1, sampleRate: rate)
        var i = 0
        while i < s.count {
            let n = min(1153, s.count - i) // decoder-sized, not aligned to 100 ms
            chunked.add([Array(s[i..<(i + n)])])
            i += n
        }
        #expect(abs(whole.integratedLoudness - chunked.integratedLoudness) < 1e-9)
    }
}
