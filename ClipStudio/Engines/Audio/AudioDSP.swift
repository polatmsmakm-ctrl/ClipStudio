//
//  AudioDSP.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  Real-time DSP building blocks used by the audio processing tap:
//  • Biquad filters (RBJ cookbook): high-pass, shelves, peaking EQ (+ magnitude
//    response for the EQ graph).
//  • Feed-forward compressor with soft knee, and a peak limiter.
//  • Adaptive spectral noise gate (STFT, sqrt-Hann windows, minimum-statistics
//    noise floor, smoothed spectral gains) built on vDSP.
//  • AudioEffectChain: one clip's full chain, reconfigured live from AudioEffects.
//  All buffers are allocated up front; processing never allocates (except the
//  noise reducer, created once the first time it is switched on).
//

import Foundation
import Accelerate

// MARK: - Biquad

struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        guard abs(a0) > 1e-12 else { return .identity }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func omega(_ frequency: Double, _ sampleRate: Double) -> Double {
        let nyquistSafe = min(max(10, frequency), sampleRate * 0.45)
        return 2 * Double.pi * nyquistSafe / sampleRate
    }

    static func highPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> BiquadCoefficients {
        let w = omega(frequency, sampleRate)
        let cosw = cos(w), alpha = sin(w) / (2 * max(0.1, q))
        return normalized((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
    }

    static func lowPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> BiquadCoefficients {
        let w = omega(frequency, sampleRate)
        let cosw = cos(w), alpha = sin(w) / (2 * max(0.1, q))
        return normalized((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
    }

    static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w = omega(frequency, sampleRate)
        let cosw = cos(w), alpha = sin(w) / (2 * max(0.1, q))
        return normalized(1 + alpha * a, -2 * cosw, 1 - alpha * a, 1 + alpha / a, -2 * cosw, 1 - alpha / a)
    }

    static func lowShelf(frequency: Double, gainDB: Double, q: Double = 0.7071, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w = omega(frequency, sampleRate)
        let cosw = cos(w), alpha = sin(w) / (2 * max(0.1, q))
        let s = 2 * sqrt(a) * alpha
        return normalized(a * ((a + 1) - (a - 1) * cosw + s),
                          2 * a * ((a - 1) - (a + 1) * cosw),
                          a * ((a + 1) - (a - 1) * cosw - s),
                          (a + 1) + (a - 1) * cosw + s,
                          -2 * ((a - 1) + (a + 1) * cosw),
                          (a + 1) + (a - 1) * cosw - s)
    }

    static func highShelf(frequency: Double, gainDB: Double, q: Double = 0.7071, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w = omega(frequency, sampleRate)
        let cosw = cos(w), alpha = sin(w) / (2 * max(0.1, q))
        let s = 2 * sqrt(a) * alpha
        return normalized(a * ((a + 1) + (a - 1) * cosw + s),
                          -2 * a * ((a - 1) + (a + 1) * cosw),
                          a * ((a + 1) + (a - 1) * cosw - s),
                          (a + 1) - (a - 1) * cosw + s,
                          2 * ((a - 1) - (a + 1) * cosw),
                          (a + 1) - (a - 1) * cosw - s)
    }

    static func band(_ band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        switch band.kind {
        case .lowShelf: lowShelf(frequency: band.frequency, gainDB: band.gainDB, q: band.q, sampleRate: sampleRate)
        case .peak: peaking(frequency: band.frequency, gainDB: band.gainDB, q: band.q, sampleRate: sampleRate)
        case .highShelf: highShelf(frequency: band.frequency, gainDB: band.gainDB, q: band.q, sampleRate: sampleRate)
        }
    }

    /// Magnitude response in dB at `frequency`.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2
        let ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2
        let di = -(a1 * s1 + a2 * s2)
        let num = nr * nr + ni * ni
        let den = max(1e-18, dr * dr + di * di)
        return 10 * log10(max(1e-18, num / den))
    }
}

/// A biquad with independent state per channel (transposed direct form II).
final class BiquadFilter {
    private(set) var coefficients = BiquadCoefficients.identity
    private let channels: Int
    private let z1: UnsafeMutablePointer<Double>
    private let z2: UnsafeMutablePointer<Double>

    init(channels: Int) {
        let count = max(1, channels)
        self.channels = count
        z1 = .allocate(capacity: count)
        z2 = .allocate(capacity: count)
        z1.initialize(repeating: 0, count: count)
        z2.initialize(repeating: 0, count: count)
    }

    deinit {
        z1.deallocate()
        z2.deallocate()
    }

    var isIdentity: Bool { coefficients == .identity }

    func setCoefficients(_ value: BiquadCoefficients) {
        coefficients = value
    }

    func reset() {
        z1.update(repeating: 0, count: channels)
        z2.update(repeating: 0, count: channels)
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard channel < channels else { return }
        let c = coefficients
        var s1 = z1[channel], s2 = z2[channel]
        for i in 0..<count {
            let x = Double(samples[i])
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            samples[i] = Float(y)
        }
        // Flush denormals / runaway states.
        if !s1.isFinite || !s2.isFinite { s1 = 0; s2 = 0 }
        if abs(s1) < 1e-20 { s1 = 0 }
        if abs(s2) < 1e-20 { s2 = 0 }
        z1[channel] = s1
        z2[channel] = s2
    }
}

// MARK: - Channel buffers

/// Pointers to one block of non-interleaved float samples (one pointer per channel).
struct ChannelBlock {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let channels: Int
    let frames: Int

    subscript(channel: Int) -> UnsafeMutablePointer<Float> { pointers[channel] }
}

// MARK: - Dynamics

/// Feed-forward compressor (linked channels, soft knee, gain smoothing in dB).
final class Compressor {
    private var threshold: Double = -20
    private var ratio: Double = 3
    private var knee: Double = 6
    private var attack: Double = 0
    private var release: Double = 0
    private var makeup: Double = 1
    private var reductionDB: Double = 0
    private(set) var lastReductionDB: Double = 0

    func configure(_ settings: CompressorSettings, sampleRate: Double, knee kneeDB: Double = 6) {
        threshold = settings.thresholdDB
        ratio = max(1, settings.ratio)
        knee = max(0, kneeDB)
        attack = exp(-1 / (max(0.1, settings.attackMS) * 0.001 * sampleRate))
        release = exp(-1 / (max(1, settings.releaseMS) * 0.001 * sampleRate))
        makeup = pow(10, settings.makeupDB / 20)
    }

    func reset() {
        reductionDB = 0
        lastReductionDB = 0
    }

    private func gainComputer(_ levelDB: Double) -> Double {
        let over = levelDB - threshold
        let slope = 1 / ratio - 1
        if knee > 0 && 2 * abs(over) <= knee {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        }
        return over > 0 ? slope * over : 0
    }

    func process(_ block: ChannelBlock, offset: Int, count: Int) {
        var deepest = 0.0
        for i in offset..<(offset + count) {
            var peak: Float = 0
            for ch in 0..<block.channels {
                let v = abs(block[ch][i])
                if v > peak { peak = v }
            }
            let level = 20 * log10(Double(max(peak, 1e-9)))
            let target = gainComputer(level)
            if target < reductionDB {
                reductionDB = attack * reductionDB + (1 - attack) * target
            } else {
                reductionDB = release * reductionDB + (1 - release) * target
            }
            if reductionDB < deepest { deepest = reductionDB }
            let gain = Float(pow(10, reductionDB / 20) * makeup)
            for ch in 0..<block.channels { block[ch][i] *= gain }
        }
        lastReductionDB = deepest
    }
}

/// Instant-attack peak limiter with smooth release, followed by a hard safety clip.
final class PeakLimiter {
    private var gain: Float = 1
    private var releaseCoefficient: Float = 0.9995
    private let ceiling: Float = 0.891 // −1 dBFS

    func configure(sampleRate: Double) {
        releaseCoefficient = Float(exp(-1 / (0.08 * sampleRate)))
    }

    func reset() { gain = 1 }

    func process(_ block: ChannelBlock, offset: Int, count: Int) {
        for i in offset..<(offset + count) {
            var peak: Float = 0
            for ch in 0..<block.channels {
                let v = abs(block[ch][i])
                if v > peak { peak = v }
            }
            let needed: Float = peak * gain > ceiling ? ceiling / max(peak, 1e-9) : 1
            if needed < gain {
                gain = needed
            } else {
                gain = releaseCoefficient * gain + (1 - releaseCoefficient) * min(1, needed)
            }
            for ch in 0..<block.channels {
                let v = block[ch][i] * gain
                block[ch][i] = min(1, max(-1, v))
            }
        }
    }
}

// MARK: - Spectral noise reduction

/// Adaptive spectral gate for one channel. Latency: `size - hop` samples (~16 ms at 48 kHz).
final class SpectralNoiseReducer {
    static let size = 1024
    static let hop = 256
    private static let log2n = vDSP_Length(10)

    private let n = SpectralNoiseReducer.size
    private let half = SpectralNoiseReducer.size / 2
    private let hop = SpectralNoiseReducer.hop
    private let latency: Int
    private let setup: FFTSetup?

    private let window: UnsafeMutablePointer<Float>
    private let inFIFO: UnsafeMutablePointer<Float>
    private let outFIFO: UnsafeMutablePointer<Float>
    private let accumulator: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let smoothedPower: UnsafeMutablePointer<Float>
    private let noise: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private let rawGains: UnsafeMutablePointer<Float>

    private var rover: Int
    private var framesSeen = 0
    private var riseFactor: Float = 1.0002
    var amount: Double = 0.5

    init(sampleRate: Double) {
        let n = SpectralNoiseReducer.size
        let half = n / 2
        let bins = half + 1
        latency = n - SpectralNoiseReducer.hop
        rover = n - SpectralNoiseReducer.hop
        setup = vDSP_create_fftsetup(SpectralNoiseReducer.log2n, FFTRadix(kFFTRadix2))
        window = .allocate(capacity: n)
        inFIFO = .allocate(capacity: n)
        outFIFO = .allocate(capacity: n)
        accumulator = .allocate(capacity: 2 * n)
        frame = .allocate(capacity: n)
        real = .allocate(capacity: half)
        imag = .allocate(capacity: half)
        power = .allocate(capacity: bins)
        smoothedPower = .allocate(capacity: bins)
        noise = .allocate(capacity: bins)
        gains = .allocate(capacity: bins)
        rawGains = .allocate(capacity: bins)
        // Noise floor may rise ~3 dB per second (minimum statistics tracking).
        let hopSeconds = Double(SpectralNoiseReducer.hop) / max(8_000, sampleRate)
        riseFactor = Float(pow(10, 3.0 * hopSeconds / 10))

        for k in 0..<n {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))
            window.advanced(by: k).initialize(to: Float(sqrt(hann)))
        }
        inFIFO.initialize(repeating: 0, count: n)
        outFIFO.initialize(repeating: 0, count: n)
        accumulator.initialize(repeating: 0, count: 2 * n)
        frame.initialize(repeating: 0, count: n)
        real.initialize(repeating: 0, count: half)
        imag.initialize(repeating: 0, count: half)
        power.initialize(repeating: 0, count: bins)
        smoothedPower.initialize(repeating: 0, count: bins)
        noise.initialize(repeating: 0, count: bins)
        gains.initialize(repeating: 1, count: bins)
        rawGains.initialize(repeating: 1, count: bins)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        window.deallocate()
        inFIFO.deallocate()
        outFIFO.deallocate()
        accumulator.deallocate()
        frame.deallocate()
        real.deallocate()
        imag.deallocate()
        power.deallocate()
        smoothedPower.deallocate()
        noise.deallocate()
        gains.deallocate()
        rawGains.deallocate()
    }

    func reset() {
        inFIFO.update(repeating: 0, count: n)
        outFIFO.update(repeating: 0, count: n)
        accumulator.update(repeating: 0, count: 2 * n)
        gains.update(repeating: 1, count: half + 1)
        rover = latency
        framesSeen = 0
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard setup != nil else { return }
        for i in 0..<count {
            inFIFO[rover] = samples[i]
            samples[i] = outFIFO[rover - latency]
            rover += 1
            if rover >= n {
                rover = latency
                processFrame()
            }
        }
    }

    private func processFrame() {
        guard let setup else { return }
        let bins = half + 1
        vDSP_vmul(inFIFO, 1, window, 1, frame, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: real, imagp: imag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, SpectralNoiseReducer.log2n, FFTDirection(FFT_FORWARD))

        // Power spectrum (bin 0 = DC in real[0], bin n/2 = Nyquist in imag[0]).
        power[0] = real[0] * real[0]
        power[half] = imag[0] * imag[0]
        for k in 1..<half { power[k] = real[k] * real[k] + imag[k] * imag[k] }

        let strength = Float(min(max(amount, 0), 1))
        let oversubtraction: Float = 1.6 + 2.6 * strength
        let floorGain = Float(pow(10, -(8 + 22 * Double(strength)) / 20))
        for k in 0..<bins {
            if framesSeen == 0 {
                smoothedPower[k] = power[k]
                noise[k] = power[k]
            } else {
                smoothedPower[k] = 0.75 * smoothedPower[k] + 0.25 * power[k]
                noise[k] = min(noise[k] * riseFactor, smoothedPower[k])
            }
            let ratio = noise[k] / max(power[k], 1e-12)
            rawGains[k] = max(floorGain, 1 - oversubtraction * ratio)
        }
        // Frequency smoothing (3 bins), then fast-open / slow-close time smoothing.
        for k in 0..<bins {
            let a = rawGains[max(0, k - 1)], b = rawGains[k], c = rawGains[min(bins - 1, k + 1)]
            let g = 0.25 * a + 0.5 * b + 0.25 * c
            gains[k] = g > gains[k] ? 0.35 * gains[k] + 0.65 * g : 0.82 * gains[k] + 0.18 * g
        }
        framesSeen += 1

        real[0] *= gains[0]
        imag[0] *= gains[half]
        for k in 1..<half {
            real[k] *= gains[k]
            imag[k] *= gains[k]
        }

        vDSP_fft_zrip(setup, &split, 1, SpectralNoiseReducer.log2n, FFTDirection(FFT_INVERSE))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
            vDSP_ztoc(&split, 1, packed, 2, vDSP_Length(half))
        }
        // zrip round trip scales by 2n; sqrt-Hann² windows at 75 % overlap sum to 2.
        let scale = Float(1.0 / (2.0 * Double(n))) * 0.5
        for k in 0..<n { accumulator[k] += frame[k] * window[k] * scale }
        for k in 0..<hop { outFIFO[k] = accumulator[k] }
        // Shift the accumulator and the input FIFO by one hop (overlapping moves).
        let floatSize = MemoryLayout<Float>.stride
        memmove(accumulator, accumulator + hop, (2 * n - hop) * floatSize)
        (accumulator + (2 * n - hop)).update(repeating: 0, count: hop)
        memmove(inFIFO, inFIFO + hop, latency * floatSize)
    }
}

// MARK: - Effect chain

/// One clip's processing chain. Rebuilt coefficients only when its settings change.
final class AudioEffectChain {
    let sampleRate: Double
    let channels: Int

    private var effects = AudioEffects()
    private var trackPan = 0.0
    private var appliedVersion = -1

    private let highPass: BiquadFilter
    private let eqFilters: [BiquadFilter]
    private let voiceFilters: [BiquadFilter]
    private let compressor = Compressor()
    private let voiceCompressor = Compressor()
    private let limiter = PeakLimiter()
    private var noiseReducers: [SpectralNoiseReducer] = []

    private var gain: Float = 1
    private var leftGain: Float = 1
    private var rightGain: Float = 1
    private(set) var isBypassed = true

    init(sampleRate: Double, channels: Int) {
        let count = max(1, channels)
        self.sampleRate = sampleRate
        self.channels = count
        highPass = BiquadFilter(channels: count)
        eqFilters = (0..<EQBand.defaults.count).map { _ in BiquadFilter(channels: count) }
        voiceFilters = (0..<4).map { _ in BiquadFilter(channels: count) }
        // All stored properties are set: configure the fixed parts of the chain.
        limiter.configure(sampleRate: sampleRate)
        voiceCompressor.configure(CompressorSettings(thresholdDB: -24, ratio: 3, attackMS: 5, releaseMS: 120, makeupDB: 5),
                                  sampleRate: sampleRate)
        voiceFilters[0].setCoefficients(.highPass(frequency: 90, sampleRate: sampleRate))
        voiceFilters[1].setCoefficients(.peaking(frequency: 300, gainDB: -3, q: 1.0, sampleRate: sampleRate))
        voiceFilters[2].setCoefficients(.peaking(frequency: 3_200, gainDB: 4, q: 0.9, sampleRate: sampleRate))
        voiceFilters[3].setCoefficients(.highShelf(frequency: 9_000, gainDB: 2.5, sampleRate: sampleRate))
    }

    /// Applies new settings (cheap no-op when the version did not change).
    func update(effects newEffects: AudioEffects, trackPan newPan: Double, version: Int) {
        guard version != appliedVersion else { return }
        appliedVersion = version
        let previous = effects
        effects = newEffects
        trackPan = newPan

        if newEffects.highPassHz >= 1 {
            highPass.setCoefficients(.highPass(frequency: newEffects.highPassHz, sampleRate: sampleRate))
        } else {
            highPass.setCoefficients(.identity)
        }
        for (index, band) in newEffects.eq.enumerated() where index < eqFilters.count {
            eqFilters[index].setCoefficients(newEffects.eqEnabled && abs(band.gainDB) > 0.05
                                             ? .band(band, sampleRate: sampleRate) : .identity)
        }
        if newEffects.compressorEnabled { compressor.configure(newEffects.compressor, sampleRate: sampleRate) }
        if newEffects.noiseReduction > 0.001 && noiseReducers.isEmpty {
            noiseReducers = (0..<channels).map { _ in SpectralNoiseReducer(sampleRate: sampleRate) }
        }
        for reducer in noiseReducers { reducer.amount = newEffects.noiseReduction }
        if previous.noiseReduction < 0.001 && newEffects.noiseReduction >= 0.001 {
            for reducer in noiseReducers { reducer.reset() }
        }

        gain = Float(newEffects.gainLinear)
        let pan = min(1, max(-1, newEffects.pan + trackPan))
        leftGain = pan > 0 ? Float(1 - pan) : 1
        rightGain = pan < 0 ? Float(1 + pan) : 1
        isBypassed = newEffects.isNeutral && abs(trackPan) < 0.001
    }

    func reset() {
        highPass.reset()
        eqFilters.forEach { $0.reset() }
        voiceFilters.forEach { $0.reset() }
        compressor.reset()
        voiceCompressor.reset()
        limiter.reset()
        noiseReducers.forEach { $0.reset() }
    }

    /// Processes `count` frames starting at `offset` in place.
    func process(_ block: ChannelBlock, offset: Int, count: Int) {
        guard !isBypassed, count > 0 else { return }
        let usable = min(block.channels, channels)
        if !highPass.isIdentity {
            for ch in 0..<usable { highPass.process(block[ch] + offset, count: count, channel: ch) }
        }
        if effects.noiseReduction >= 0.001 {
            for ch in 0..<min(usable, noiseReducers.count) { noiseReducers[ch].process(block[ch] + offset, count: count) }
        }
        for filter in eqFilters where !filter.isIdentity {
            for ch in 0..<usable { filter.process(block[ch] + offset, count: count, channel: ch) }
        }
        if effects.voiceEnhance {
            for filter in voiceFilters {
                for ch in 0..<usable { filter.process(block[ch] + offset, count: count, channel: ch) }
            }
            voiceCompressor.process(block, offset: offset, count: count)
        }
        if effects.compressorEnabled { compressor.process(block, offset: offset, count: count) }
        if abs(gain - 1) > 0.0001 {
            var g = gain
            for ch in 0..<usable { vDSP_vsmul(block[ch] + offset, 1, &g, block[ch] + offset, 1, vDSP_Length(count)) }
        }
        if usable >= 2 {
            if leftGain < 0.9999 {
                var g = leftGain
                vDSP_vsmul(block[0] + offset, 1, &g, block[0] + offset, 1, vDSP_Length(count))
            }
            if rightGain < 0.9999 {
                var g = rightGain
                vDSP_vsmul(block[1] + offset, 1, &g, block[1] + offset, 1, vDSP_Length(count))
            }
        }
        if effects.limiter { limiter.process(block, offset: offset, count: count) }
    }

    var compressorReductionDB: Double { compressor.lastReductionDB }
}
