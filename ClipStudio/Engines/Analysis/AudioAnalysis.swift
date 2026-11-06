//
//  AudioAnalysis.swift
//  ClipStudio — Engines/Analysis (AudioEngine, local)
//
//  • SilenceDetector: finds pauses in speech/audio (natural cut points) from
//    20 ms RMS windows on 16 kHz mono audio decoded by AVAssetReader (streamed).
//  • KeyframeIndexer: lists sync-sample (keyframe) times by demuxing compressed
//    samples without decoding — used for lossless "fast copy" cuts.
//

import Foundation
import AVFoundation

struct SilenceRange: Codable, Hashable {
    var start: Double
    var end: Double
    var midpoint: Double { (start + end) / 2 }
    var duration: Double { end - start }
}

enum SilenceDetector {
    struct Options {
        /// nil = adaptive (noise floor + 10 dB, clamped to −55…−25 dBFS).
        var thresholdDB: Double? = nil
        var minimumSilence: Double = 0.35
    }

    static let sampleRate: Double = 16_000
    static let windowSamples = 320 // 20 ms

    static func detect(url: URL, options: Options = Options(),
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [SilenceRange] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let levels = try readLevels(asset: asset, track: track, duration: duration, progress: progress)
        guard !levels.isEmpty else { return [] }

        let threshold: Double
        if let fixed = options.thresholdDB {
            threshold = fixed
        } else {
            let sorted = levels.sorted()
            let floor = sorted[Int(Double(sorted.count) * 0.1)]
            threshold = min(-25, max(-55, floor + 10))
        }

        let windowSeconds = Double(windowSamples) / sampleRate
        var ranges: [SilenceRange] = []
        var runStart: Int?
        for (i, level) in levels.enumerated() {
            if level < threshold {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                let range = SilenceRange(start: Double(start) * windowSeconds, end: Double(i) * windowSeconds)
                if range.duration >= options.minimumSilence { ranges.append(range) }
                runStart = nil
            }
        }
        if let start = runStart {
            let range = SilenceRange(start: Double(start) * windowSeconds, end: Double(levels.count) * windowSeconds)
            if range.duration >= options.minimumSilence { ranges.append(range) }
        }
        progress(1)
        return ranges
    }

    /// Per-window loudness in dBFS.
    static func readLevels(asset: AVAsset, track: AVAssetTrack, duration: Double,
                           progress: @escaping @Sendable (Double) -> Void) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var levels: [Double] = []
        var accumulator: Double = 0
        var count = 0
        var processedSamples = 0
        let totalSamples = max(1, Int(duration * sampleRate))

        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let sampleCount = length / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: sampleCount)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == noErr else { continue }
            for sample in samples {
                accumulator += Double(sample * sample)
                count += 1
                if count == windowSamples {
                    let rms = sqrt(accumulator / Double(count))
                    levels.append(rms > 0 ? 20 * log10(rms) : -120)
                    accumulator = 0
                    count = 0
                }
            }
            processedSamples += sampleCount
            if levels.count % 200 == 0 { progress(min(0.99, Double(processedSamples) / Double(totalSamples))) }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return levels
    }
}

enum KeyframeIndexer {
    static func syncTimes(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var times: [Double] = []
        var counter = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            var isSync = true
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]],
               let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool {
                isSync = !notSync
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if isSync && pts.isFinite { times.append(pts) }
            counter += 1
            if counter % 300 == 0, duration > 0 { progress(min(0.99, pts / duration)) }
        }
        progress(1)
        return times.sorted()
    }
}

/// Caches analysis results per asset so repeated requests never recompute.
enum AnalysisCache {
    private static func url(_ assetID: UUID, _ kind: String) -> URL {
        StorageManager.shared.analysisDirectory.appendingPathComponent("\(assetID.uuidString)-\(kind).json")
    }

    static func loadTimes(_ assetID: UUID, kind: String) -> [Double]? {
        JSONStore.load([Double].self, from: url(assetID, kind))
    }

    static func saveTimes(_ times: [Double], assetID: UUID, kind: String) {
        try? JSONStore.save(times, to: url(assetID, kind))
    }

    static func loadSilences(_ assetID: UUID) -> [SilenceRange]? {
        JSONStore.load([SilenceRange].self, from: url(assetID, "silences"))
    }

    static func saveSilences(_ ranges: [SilenceRange], assetID: UUID) {
        try? JSONStore.save(ranges, to: url(assetID, "silences"))
    }
}
