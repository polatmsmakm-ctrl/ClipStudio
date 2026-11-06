//
//  LoudnessAnalyzer.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  Integrated loudness (ITU-R BS.1770-4: K-weighting, 400 ms blocks with 75 %
//  overlap, absolute −70 LUFS and relative −10 LU gates) and sample peak of a media
//  range. Used by "normalize loudness" to set each clip's gain to a target such as
//  −14 LUFS (social platforms) or −23 LUFS (broadcast).
//

import Foundation
import AVFoundation

struct LoudnessResult: Hashable {
    /// LUFS (−inf when silent).
    let integrated: Double
    /// dBFS sample peak.
    let peak: Double

    var isSilent: Bool { !integrated.isFinite || integrated < -69 }
}

enum LoudnessTarget: Double, CaseIterable, Identifiable {
    case social = -14
    case podcast = -16
    case broadcast = -23

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .social: "منصات التواصل (−14 LUFS)"
        case .podcast: "بودكاست (−16 LUFS)"
        case .broadcast: "بث تلفزيوني (−23 LUFS)"
        }
    }
}

enum LoudnessError: LocalizedError {
    case noAudio
    case readFailed

    var errorDescription: String? {
        switch self {
        case .noAudio: "لا يوجد صوت في هذا المقطع."
        case .readFailed: "تعذّرت قراءة الصوت لقياس مستواه."
        }
    }
}

enum LoudnessAnalyzer {
    private static let sampleRate: Double = 48_000

    // K-weighting at 48 kHz (BS.1770-4 pre-filter + RLB high-pass).
    private static let shelf = BiquadCoefficients(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                                  a1: -1.69065929318241, a2: 0.73248077421585)
    private static let rlb = BiquadCoefficients(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)

    /// Measures a source range of a media file (nil = whole file).
    static func measure(url: URL, range: CMTimeRange?, control: RenderControl? = nil) async throws -> LoudnessResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw LoudnessError.noAudio }
        var sourceChannels = 2
        if let description = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sourceChannels = Int(basic.mChannelsPerFrame)
        }
        let channels = min(max(1, sourceChannels), 2)
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LoudnessError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LoudnessError.readFailed }

        var meter = KWeightedMeter(channels: channels, sampleRate: sampleRate, shelf: shelf, rlb: rlb)
        while let buffer = output.copyNextSampleBuffer() {
            if control?.isCancelled == true || Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                meter.consume(samples, count: count)
            }
        }
        if reader.status == .failed { throw reader.error ?? LoudnessError.readFailed }
        return meter.result()
    }
}

/// Streaming BS.1770 meter over interleaved float samples.
struct KWeightedMeter {
    let channels: Int
    private let subBlock: Int
    private let shelf: BiquadCoefficients
    private let rlb: BiquadCoefficients
    private var state: [Double]
    private var subSums: [Double]
    private var subCount = 0
    private var recentSubBlocks: [[Double]] = []
    private var blockLoudness: [Double] = []
    private var blockPowers: [Double] = []
    private var peak: Float = 0

    init(channels: Int, sampleRate: Double, shelf: BiquadCoefficients, rlb: BiquadCoefficients) {
        self.channels = max(1, channels)
        self.subBlock = Int(sampleRate * 0.1)
        self.shelf = shelf
        self.rlb = rlb
        state = Array(repeating: 0, count: self.channels * 4)
        subSums = Array(repeating: 0, count: self.channels)
    }

    mutating func consume(_ samples: UnsafePointer<Float>, count: Int) {
        let frames = count / channels
        for frame in 0..<frames {
            for ch in 0..<channels {
                let x = samples[frame * channels + ch]
                let magnitude = abs(x)
                if magnitude > peak { peak = magnitude }
                // Stage 1 (shelf)
                let base = ch * 4
                let input = Double(x)
                let y1 = shelf.b0 * input + state[base]
                state[base] = shelf.b1 * input - shelf.a1 * y1 + state[base + 1]
                state[base + 1] = shelf.b2 * input - shelf.a2 * y1
                // Stage 2 (RLB high-pass)
                let y2 = rlb.b0 * y1 + state[base + 2]
                state[base + 2] = rlb.b1 * y1 - rlb.a1 * y2 + state[base + 3]
                state[base + 3] = rlb.b2 * y1 - rlb.a2 * y2
                subSums[ch] += y2 * y2
            }
            subCount += 1
            if subCount == subBlock {
                recentSubBlocks.append(subSums.map { $0 / Double(subBlock) })
                if recentSubBlocks.count > 4 { recentSubBlocks.removeFirst() }
                if recentSubBlocks.count == 4 {
                    var power = 0.0
                    for ch in 0..<channels {
                        power += recentSubBlocks.reduce(0) { $0 + $1[ch] } / 4
                    }
                    blockPowers.append(power)
                    blockLoudness.append(-0.691 + 10 * log10(max(power, 1e-20)))
                }
                subSums = Array(repeating: 0, count: channels)
                subCount = 0
            }
        }
    }

    func result() -> LoudnessResult {
        let peakDB = 20 * log10(Double(max(peak, 1e-9)))
        let absolute = blockLoudness.indices.filter { blockLoudness[$0] > -70 }
        guard !absolute.isEmpty else { return LoudnessResult(integrated: -.infinity, peak: peakDB) }
        let meanAbsolute = absolute.reduce(0.0) { $0 + blockPowers[$1] } / Double(absolute.count)
        let relativeGate = -0.691 + 10 * log10(max(meanAbsolute, 1e-20)) - 10
        let gated = absolute.filter { blockLoudness[$0] > relativeGate }
        guard !gated.isEmpty else { return LoudnessResult(integrated: -.infinity, peak: peakDB) }
        let mean = gated.reduce(0.0) { $0 + blockPowers[$1] } / Double(gated.count)
        return LoudnessResult(integrated: -0.691 + 10 * log10(max(mean, 1e-20)), peak: peakDB)
    }
}
