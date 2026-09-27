import Foundation
import os

/// Loudness-normalization policy, identical to the Plasma widget's RadioBackend.
public enum Loudness {
    /// EBU R128 broadcast reference. Deliberately low so nearly every station sits
    /// above it and can be normalized *down* to match (we only attenuate).
    public static let targetLUFS = -23.0
    /// Assumed level for a not-yet-measured station, so it starts pre-attenuated
    /// instead of blasting at full volume until the meter converges.
    public static let defaultLUFS = -16.0
    public static let maxAttenuationDB = 24.0
    /// Limits how fast the applied gain moves, so it never pumps.
    public static let slewDBPerTick = 1.0
    public static let tickInterval: TimeInterval = 0.4
    /// Only persist a new measurement once it has moved this far.
    public static let persistThresholdLU = 0.5

    /// Gain (always <= 0) that brings `measured` down to `target`, clamped.
    public static func attenuationGainDB(measured: Double, target: Double = targetLUFS) -> Double {
        var g = target - measured
        if g > 0 { g = 0 }
        if g < -maxAttenuationDB { g = -maxAttenuationDB }
        return g
    }

    /// False for silence / non-finite readings, which must never move the gain.
    public static func isMeasurable(_ lufs: Double) -> Bool {
        lufs.isFinite && lufs > -60
    }

    /// One slew step from `current` toward `desired`.
    public static func slew(from current: Double, to desired: Double, step: Double = slewDBPerTick) -> Double {
        let delta = desired - current
        if delta > step { return current + step }
        if delta < -step { return current - step }
        return desired
    }

    public static func linearGain(db: Double) -> Double { pow(10, db / 20) }
}

/// EBU R128 / ITU-R BS.1770 integrated-loudness meter (the subset of
/// libebur128's EBUR128_MODE_I the widget uses).
///
/// K-weighting pre-filter, 400 ms blocks with 75 % overlap, absolute gate at
/// -70 LUFS and relative gate at -10 LU. Gated block energies are kept in a
/// fixed 0.1 dB histogram (as libebur128 does) so memory stays constant however
/// long a station plays.
public final class LoudnessMeter {
    public let channels: Int
    public let sampleRate: Double

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private let subBlockFrames: Int
    private var subBlockFill = 0
    private var subBlockSum: [Double]          // per-channel sum of squares, current 100 ms
    private var recentSubBlocks: [Double] = [] // weighted energy of the last 4 sub-blocks

    // Histogram of gated block energies: bins of 0.1 LU from -70 to +10 LUFS.
    private static let histMin = -70.0, histStep = 0.1, histBins = 800
    private var histCount = [Int](repeating: 0, count: histBins)
    private var histEnergy = [Double](repeating: 0, count: histBins)

    public init(channels: Int, sampleRate: Double) {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate

        // Filter design from libebur128 (valid at any sample rate).
        var f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(Double.pi * f0 / sampleRate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1.0 + K / Q + K * K
        let s = Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2.0 * (K * K - Vh) / a0,
                       b2: (Vh - Vb * K / Q + K * K) / a0, a1: 2.0 * (K * K - 1.0) / a0,
                       a2: (1.0 - K / Q + K * K) / a0)
        f0 = 38.13547087602444; Q = 0.5003270373238773; G = 0
        K = tan(Double.pi * f0 / sampleRate)
        a0 = 1.0 + K / Q + K * K
        let h = Biquad(b0: 1, b1: -2, b2: 1, a1: 2.0 * (K * K - 1.0) / a0, a2: (1.0 - K / Q + K * K) / a0)
        shelf = Array(repeating: s, count: self.channels)
        highpass = Array(repeating: h, count: self.channels)
        subBlockFrames = max(1, Int((sampleRate / 10).rounded()))
        subBlockSum = Array(repeating: 0, count: self.channels)
    }

    /// Feed non-interleaved float samples: `channelData[ch][frame]`.
    public func add(channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        var f = 0
        while f < frames {
            let n = min(frames - f, subBlockFrames - subBlockFill)
            for ch in 0..<channels {
                let p = channelData[ch]
                var sum = 0.0
                var sh = shelf[ch], hp = highpass[ch]
                for i in f..<(f + n) {
                    let y = hp.process(sh.process(Double(p[i])))
                    sum += y * y
                }
                shelf[ch] = sh; highpass[ch] = hp
                subBlockSum[ch] += sum
            }
            f += n
            subBlockFill += n
            if subBlockFill == subBlockFrames { finishSubBlock() }
        }
    }

    /// Convenience for tests: interleaved-per-channel arrays.
    public func add(_ channelsData: [[Float]]) {
        var copies = channelsData.map { UnsafeMutablePointer<Float>.allocate(capacity: $0.count) }
        defer { copies.forEach { $0.deallocate() } }
        for (i, d) in channelsData.enumerated() { copies[i].update(from: d, count: d.count) }
        copies.withUnsafeMutableBufferPointer { buf in
            add(channelData: UnsafePointer(buf.baseAddress!), frames: channelsData.first?.count ?? 0)
        }
    }

    private func finishSubBlock() {
        // Channel weights are 1.0 for mono/stereo (surround channels don't occur here).
        let energy = subBlockSum.reduce(0, +)
        recentSubBlocks.append(energy)
        if recentSubBlocks.count > 4 { recentSubBlocks.removeFirst() }
        for ch in 0..<channels { subBlockSum[ch] = 0 }
        subBlockFill = 0
        guard recentSubBlocks.count == 4 else { return }
        let blockEnergy = recentSubBlocks.reduce(0, +) / Double(4 * subBlockFrames)
        guard blockEnergy > 0 else { return }
        let lufs = LoudnessMeter.energyToLUFS(blockEnergy)
        guard lufs >= LoudnessMeter.histMin else { return } // absolute gate
        let bin = min(LoudnessMeter.histBins - 1, Int((lufs - LoudnessMeter.histMin) / LoudnessMeter.histStep))
        histCount[bin] += 1
        histEnergy[bin] += blockEnergy
    }

    static func energyToLUFS(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
    static func lufsToEnergy(_ l: Double) -> Double { pow(10, (l + 0.691) / 10) }

    /// Gated integrated loudness so far, or -infinity with no gated blocks yet.
    public var integratedLoudness: Double {
        var n = 0, e = 0.0
        for i in 0..<LoudnessMeter.histBins { n += histCount[i]; e += histEnergy[i] }
        guard n > 0 else { return -.infinity }
        let relativeGate = LoudnessMeter.energyToLUFS(e / Double(n)) - 10
        let startBin = max(0, Int(((relativeGate - LoudnessMeter.histMin) / LoudnessMeter.histStep).rounded(.up)))
        var n2 = 0, e2 = 0.0
        for i in startBin..<LoudnessMeter.histBins { n2 += histCount[i]; e2 += histEnergy[i] }
        guard n2 > 0 else { return -.infinity }
        return LoudnessMeter.energyToLUFS(e2 / Double(n2))
    }
}

/// Thread-safe holder: the audio queue feeds the meter, the main thread reads it.
public final class SharedLoudnessMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var meter: LoudnessMeter?
    private var enabled = false

    public init() {}

    public func reset(enabled: Bool) {
        lock.withLockUnchecked { meter = nil; self.enabled = enabled }
    }

    public func add(channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channels: Int, sampleRate: Double) {
        lock.withLockUnchecked {
            guard enabled else { return }
            // (Re)create on a format change; the applied gain is untouched.
            if meter == nil || meter!.channels != channels || meter!.sampleRate != sampleRate {
                meter = LoudnessMeter(channels: channels, sampleRate: sampleRate)
            }
            meter!.add(channelData: channelData, frames: frames)
        }
    }

    public var integratedLoudness: Double {
        lock.withLockUnchecked { meter?.integratedLoudness ?? -.infinity }
    }
}
