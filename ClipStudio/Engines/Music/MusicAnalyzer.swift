//
//  MusicAnalyzer.swift
//  ClipStudio — Engines/Music (Part 4)
//
//  Music intelligence on device (no network, no third-party code):
//  1. Audio is decoded to 22.05 kHz mono with AVAssetReader (streamed).
//  2. A 1024-point STFT (hop 512, vDSP) gives a log-compressed spectral-flux onset
//     envelope, a low-band (kick) flux and the frame loudness.
//  3. Tempo = autocorrelation peak of the onset envelope between 60 and 200 BPM,
//     weighted by a log-normal prior centred on 120 BPM.
//  4. Beats = dynamic-programming beat tracker (Ellis 2007); downbeats = the beat
//     phase (mod 4) with the strongest low-band onsets.
//  5. Energy envelope (10 / s), sections from energy novelty and the "drop"
//     (biggest energy rise).
//  Results are cached per media file in Caches/Analysis.
//

import Foundation
import AVFoundation
import Accelerate

enum MusicAnalysisError: LocalizedError {
    case noAudio
    case tooShort
    case readFailed

    var errorDescription: String? {
        switch self {
        case .noAudio: "الملف لا يحتوي صوتًا."
        case .tooShort: "المقطع الصوتي قصير جدًا لتحليل الإيقاع (أقل من 3 ثوانٍ)."
        case .readFailed: "تعذرت قراءة الصوت من الملف."
        }
    }
}

/// Frame features produced by the STFT pass.
struct MusicFeatures {
    var frameRate: Double
    var flux: [Double]
    var lowFlux: [Double]
    var rms: [Double]
}

/// Streaming STFT feature extractor (mono float input).
final class MusicFeatureExtractor {
    static let fftSize = 1024
    static let hop = 512
    private static let log2n = vDSP_Length(10)

    let sampleRate: Double
    private let n = MusicFeatureExtractor.fftSize
    private let half = MusicFeatureExtractor.fftSize / 2
    private let hop = MusicFeatureExtractor.hop
    private let setup: FFTSetup?
    private var window: [Float]
    private var pending: [Float] = []
    private var readIndex = 0
    private var previous: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var hasPrevious = false

    private(set) var flux: [Double] = []
    private(set) var lowFlux: [Double] = []
    private(set) var rms: [Double] = []

    init(sampleRate: Double) {
        let n = MusicFeatureExtractor.fftSize
        let half = n / 2
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(MusicFeatureExtractor.log2n, FFTRadix(kFFTRadix2))
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        previous = [Float](repeating: 0, count: half)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    var frameRate: Double { sampleRate / Double(hop) }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        while pending.count - readIndex >= n {
            processFrame(at: readIndex)
            readIndex += hop
        }
        // Compact the buffer now and then (keeps memory flat for long songs).
        if readIndex > 65_536 {
            pending.removeFirst(readIndex)
            readIndex = 0
        }
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    var features: MusicFeatures {
        MusicFeatures(frameRate: frameRate, flux: flux, lowFlux: lowFlux, rms: rms)
    }

    private func processFrame(at offset: Int) {
        guard let setup else { return }
        let count = n
        let halfCount = half
        // Loudness of the hop (frame centre).
        var meanSquare: Float = 0
        pending.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_measqv(base + offset + (count - hop) / 2, 1, &meanSquare, vDSP_Length(hop))
            window.withUnsafeBufferPointer { w in
                windowed.withUnsafeMutableBufferPointer { out in
                    vDSP_vmul(base + offset, 1, w.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        rms.append(Double(sqrt(meanSquare)))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfCount) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfCount))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, MusicFeatureExtractor.log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var total: Double = 0
        var low: Double = 0
        let scale = Float(100) / Float(count)
        for k in 0..<halfCount {
            let re = real[k]
            let im: Float = k == 0 ? 0 : imag[k]
            let magnitude = sqrt(re * re + im * im)
            let compressed = log1p(scale * magnitude)
            if hasPrevious {
                let rise = Double(max(0, compressed - previous[k]))
                total += rise
                if k >= 1 && k <= 8 { low += rise }
            }
            previous[k] = compressed
        }
        hasPrevious = true
        flux.append(total)
        lowFlux.append(low)
    }
}

enum MusicAnalyzer {
    static let sampleRate: Double = 22_050

    static func cacheURL(assetID: UUID) -> URL {
        StorageManager.shared.analysisDirectory.appendingPathComponent(assetID.uuidString + "-music-v1.json")
    }

    static func cached(assetID: UUID) -> MusicAnalysis? {
        JSONStore.load(MusicAnalysis.self, from: cacheURL(assetID: assetID))
    }

    // MARK: File analysis

    /// - Parameter cache: false for one-off files (reference videos) that aren't in the library.
    static func analyze(assetID: UUID, url: URL, cache: Bool = true, control: RenderControl?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> MusicAnalysis {
        if cache, let cached = cached(assetID: assetID) { return cached }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MusicAnalysisError.noAudio }
        guard duration.isFinite, duration >= 3 else { throw MusicAnalysisError.tooShort }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicAnalysisError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MusicAnalysisError.readFailed }

        let extractor = MusicFeatureExtractor(sampleRate: sampleRate)
        let totalSamples = max(1, duration * sampleRate)
        var processed = 0.0
        var scratch: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if control?.isCancelled == true || Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count != count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == noErr else { continue }
            extractor.append(scratch)
            processed += Double(count)
            progress(min(0.95, processed / totalSamples * 0.95))
        }
        if reader.status == .failed { throw reader.error ?? MusicAnalysisError.readFailed }

        let result = analyze(features: extractor.features, assetID: assetID, duration: duration)
        if cache {
            try? FileManager.default.createDirectory(at: StorageManager.shared.analysisDirectory, withIntermediateDirectories: true)
            try? JSONStore.save(result, to: cacheURL(assetID: assetID))
        }
        progress(1)
        return result
    }

    // MARK: Pure analysis (testable)

    static func analyze(samples: [Float], sampleRate: Double, assetID: UUID = UUID()) -> MusicAnalysis {
        let extractor = MusicFeatureExtractor(sampleRate: sampleRate)
        extractor.append(samples)
        return analyze(features: extractor.features, assetID: assetID, duration: Double(samples.count) / sampleRate)
    }

    static func analyze(features: MusicFeatures, assetID: UUID, duration: Double) -> MusicAnalysis {
        let fr = features.frameRate
        let onset = onsetEnvelope(features.flux, frameRate: fr)
        let energy = energyEnvelope(rms: features.rms, frameRate: fr, rate: 10)
        guard onset.count > Int(fr * 2), onset.contains(where: { $0 > 0 }) else {
            return MusicAnalysis(assetID: assetID, duration: duration, bpm: 0, beats: [], downbeats: [],
                                 energy: energy, energyRate: 10, sections: [MusicSection(start: 0, end: duration, energy: 1)],
                                 dropTime: nil)
        }
        let bpm = estimateTempo(onset: onset, frameRate: fr)
        var beatFrames = trackBeats(onset: onset, frameRate: fr, bpm: bpm)
        // Keep beats where there is sound.
        if let soundRange = audibleRange(rms: features.rms) {
            beatFrames = beatFrames.filter { $0 >= soundRange.lowerBound - 2 && $0 <= soundRange.upperBound + 2 }
        }
        // Frame f covers samples [f·hop, f·hop + n); its onset belongs to the frame centre.
        let offset = Double(MusicFeatureExtractor.fftSize) / 2 / Double(MusicFeatureExtractor.hop)
        let beats = beatFrames.map { min(duration, max(0, (Double($0) + offset) / fr)) }
        let downbeatPhase = bestDownbeatPhase(beatFrames: beatFrames, lowFlux: features.lowFlux)
        let downbeats = beats.enumerated().filter { $0.offset % 4 == downbeatPhase }.map(\.element)
        let (sections, drop) = findSections(energy: energy, rate: 10, duration: duration, downbeats: downbeats)
        return MusicAnalysis(assetID: assetID, duration: duration, bpm: (bpm * 10).rounded() / 10, beats: beats,
                             downbeats: downbeats, energy: energy, energyRate: 10, sections: sections, dropTime: drop)
    }

    /// Mean-removed, half-wave rectified, unit-variance onset strength.
    static func onsetEnvelope(_ flux: [Double], frameRate: Double) -> [Double] {
        guard !flux.isEmpty else { return [] }
        let radius = max(1, Int(frameRate * 0.25))
        var prefix = [0.0]
        prefix.reserveCapacity(flux.count + 1)
        for v in flux { prefix.append(prefix.last! + v) }
        var result = flux.indices.map { i -> Double in
            let a = max(0, i - radius), b = min(flux.count - 1, i + radius)
            let mean = (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
            return max(0, flux[i] - mean)
        }
        let mean = result.reduce(0, +) / Double(result.count)
        let variance = result.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(result.count)
        let std = sqrt(variance)
        if std > 1e-9 { result = result.map { $0 / std } }
        return result
    }

    /// Tempo in BPM (60…200) from the onset autocorrelation.
    static func estimateTempo(onset raw: [Double], frameRate: Double) -> Double {
        // Light smoothing: sharp one-frame onsets at a fractional period would
        // otherwise favour twice the period in the autocorrelation.
        let kernel: [Double] = [1, 2, 3, 2, 1].map { $0 / 9 }
        let onset = raw.indices.map { i -> Double in
            var sum = 0.0
            for (k, weight) in kernel.enumerated() {
                let j = i + k - 2
                if j >= 0 && j < raw.count { sum += raw[j] * weight }
            }
            return sum
        }
        let count = onset.count
        let minLag = max(1, Int((60 * frameRate / 200).rounded(.down)))
        let maxLag = min(count - 1, Int((60 * frameRate / 60).rounded(.up)))
        guard maxLag > minLag + 1 else { return 120 }
        // Analyze at most ~4 minutes.
        let length = min(count, Int(frameRate * 240))
        func autocorrelation(_ lag: Int) -> Double {
            guard lag < length else { return 0 }
            var sum = 0.0
            for i in lag..<length { sum += onset[i] * onset[i - lag] }
            return sum / Double(length - lag)
        }
        func ac(_ lag: Int) -> Double { autocorrelation(lag) }
        var scores: [Double] = []
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let octave = log2(bpm / 120)
            let prior = exp(-0.5 * octave * octave)
            scores.append(ac(lag) * prior)
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return 120 }
        var lag = Double(best + minLag)
        // Parabolic refinement.
        if best > 0, best < scores.count - 1 {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { lag += 0.5 * (a - c) / denominator }
        }
        return min(200, max(60, 60 * frameRate / lag))
    }

    /// Dynamic-programming beat tracker. Returns beat frame indices.
    static func trackBeats(onset: [Double], frameRate: Double, bpm: Double, tightness: Double = 100) -> [Int] {
        let count = onset.count
        guard count > 2, bpm > 0 else { return [] }
        let period = 60 * frameRate / bpm
        var score = onset
        var backlink = [Int](repeating: -1, count: count)
        let farthest = Int((2 * period).rounded())
        let nearest = max(1, Int((period / 2).rounded()))
        // Pre-computed penalties for every distance.
        let penalties: [Double] = (0...farthest).map { d in
            d < nearest ? -Double.infinity : -tightness * pow(log(Double(d) / period), 2)
        }
        for i in 0..<count {
            let low = i - farthest
            let high = i - nearest
            guard high >= 0 else { continue }
            var best = -Double.infinity
            var arg = -1
            for j in max(0, low)...high {
                let value = score[j] + penalties[i - j]
                if value > best { best = value; arg = j }
            }
            // Link only when it helps: silence before the music never pulls the first beats.
            if arg >= 0, best > 0 {
                score[i] = onset[i] + best
                backlink[i] = arg
            }
        }
        // Start from the best score inside the last period.
        let tailStart = max(0, count - Int(period.rounded(.up)))
        var current = (tailStart..<count).max(by: { score[$0] < score[$1] }) ?? count - 1
        var beats: [Int] = []
        while current >= 0 {
            beats.append(current)
            current = backlink[current]
        }
        return beats.reversed()
    }

    /// Frames between the first and last frame louder than −40 dB of the peak.
    static func audibleRange(rms: [Double]) -> ClosedRange<Int>? {
        guard let peak = rms.max(), peak > 0 else { return nil }
        let threshold = peak * 0.01
        guard let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else { return nil }
        return first...last
    }

    /// Beat phase (0…3) whose beats carry the strongest low-frequency onsets.
    static func bestDownbeatPhase(beatFrames: [Int], lowFlux: [Double]) -> Int {
        guard beatFrames.count >= 4, !lowFlux.isEmpty else { return 0 }
        var sums = [Double](repeating: 0, count: 4)
        for (index, frame) in beatFrames.enumerated() {
            let a = max(0, frame - 1), b = min(lowFlux.count - 1, frame + 1)
            guard a <= b else { continue }
            sums[index % 4] += lowFlux[a...b].max() ?? 0
        }
        return sums.indices.max(by: { sums[$0] < sums[$1] }) ?? 0
    }

    /// Loudness envelope (0…1) at `rate` values per second.
    static func energyEnvelope(rms: [Double], frameRate: Double, rate: Double) -> [Double] {
        guard !rms.isEmpty else { return [] }
        let framesPerValue = max(1, Int((frameRate / rate).rounded()))
        var values: [Double] = []
        var index = 0
        while index < rms.count {
            let slice = rms[index..<min(rms.count, index + framesPerValue)]
            values.append(slice.reduce(0, +) / Double(slice.count))
            index += framesPerValue
        }
        let sorted = values.sorted()
        let reference = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        guard reference > 1e-9 else { return values.map { _ in 0 } }
        return values.map { min(1, $0 / reference) }
    }

    /// Sections from energy novelty (boundaries snap to downbeats) and the biggest rise.
    static func findSections(energy: [Double], rate: Double, duration: Double,
                             downbeats: [Double]) -> (sections: [MusicSection], drop: Double?) {
        guard energy.count > Int(rate * 8) else {
            let mean = energy.isEmpty ? 1 : energy.reduce(0, +) / Double(energy.count)
            return ([MusicSection(start: 0, end: duration, energy: mean)], nil)
        }
        var prefix = [0.0]
        for v in energy { prefix.append(prefix.last! + v) }
        func mean(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(energy.count, b)
            guard hi > lo else { return 0 }
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
        let span = Int(rate * 4)
        var novelty = [Double](repeating: 0, count: energy.count)
        for i in span..<(energy.count - span) {
            novelty[i] = mean(i, i + span) - mean(i - span, i)
        }
        let neighborhood = Int(rate * 3)
        let minimumGap = Int(rate * 6)
        var boundaries: [Int] = []
        for i in novelty.indices where abs(novelty[i]) > 0.12 {
            let a = max(0, i - neighborhood), b = min(novelty.count - 1, i + neighborhood)
            let isPeak = (a...b).allSatisfy { abs(novelty[$0]) <= abs(novelty[i]) }
            guard isPeak else { continue }
            if let last = boundaries.last, i - last < minimumGap { continue }
            boundaries.append(i)
        }
        func snapped(_ index: Int) -> Double {
            let time = Double(index) / rate
            if let nearest = downbeats.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) <= 1 { return nearest }
            return time
        }
        var edges = [0.0] + boundaries.map(snapped) + [duration]
        edges = edges.sorted()
        var sections: [MusicSection] = []
        for index in 0..<(edges.count - 1) where edges[index + 1] - edges[index] > 0.5 {
            let a = Int(edges[index] * rate), b = Int(edges[index + 1] * rate)
            sections.append(MusicSection(start: edges[index], end: edges[index + 1], energy: mean(a, b)))
        }
        let peak = sections.map(\.energy).max() ?? 1
        if peak > 0 { for i in sections.indices { sections[i].energy = min(1, sections[i].energy / peak) } }
        var drop: Double?
        var biggest = 0.15
        for index in boundaries where novelty[index] > biggest {
            biggest = novelty[index]
            drop = snapped(index)
        }
        return (sections, drop)
    }
}
