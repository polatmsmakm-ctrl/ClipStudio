//
//  SceneDetector.swift
//  ClipStudio — Engines/Analysis (VideoProcessingEngine, local)
//
//  Local scene-change detection without AI:
//  1. Coarse pass: tiny frames sampled at an adaptive interval; RGB histograms compared.
//  2. Cuts = differences that are both above an absolute threshold and well above
//     the local average (adaptive), so slow pans don't trigger false cuts.
//  3. Refinement: frame-accurate search inside each candidate window.
//

import Foundation
import AVFoundation
import CoreGraphics

enum SceneDetector {
    struct Options {
        /// 0…1, higher finds more cuts.
        var sensitivity: Double = 0.5
        /// Upper bound on coarse samples (keeps 1-hour videos fast).
        var maxSamples: Int = 2400
        var refine = true
    }

    static func detect(url: URL, options: Options = Options(),
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { return [] }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let fps = Double(try await track.load(.nominalFrameRate))
        let frameRate = fps > 0 ? fps : 30

        let interval = max(0.4, duration / Double(options.maxSamples))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 48, height: 48)
        let tolerance = CMTime(seconds: interval / 3, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var times: [Double] = []
        var histograms: [[Double]] = []
        var t = 0.0
        let total = Int(duration / interval)
        var index = 0
        while t < duration - 0.05 {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let histogram = Histogram.make(image) {
                times.append(t)
                histograms.append(histogram)
            }
            index += 1
            if index % 10 == 0 { progress(min(0.85, Double(index) / Double(max(total, 1)) * 0.85)) }
            t += interval
        }
        guard histograms.count > 2 else { return [] }

        var diffs: [Double] = [0]
        for i in 1..<histograms.count { diffs.append(Histogram.distance(histograms[i - 1], histograms[i])) }

        let absolute = 0.62 - 0.4 * min(max(options.sensitivity, 0), 1)
        var candidates: [(time: Double, previous: Double)] = []
        let window = 8
        for i in 1..<diffs.count {
            let lo = max(1, i - window), hi = min(diffs.count - 1, i + window)
            let neighbours = (lo...hi).filter { $0 != i }.map { diffs[$0] }
            let mean = neighbours.isEmpty ? 0 : neighbours.reduce(0, +) / Double(neighbours.count)
            if diffs[i] > absolute && diffs[i] > mean * 2.2 + 0.05 {
                if let last = candidates.last, times[i] - last.time < 1.0 { continue }
                candidates.append((times[i], times[i - 1]))
            }
        }

        guard options.refine else {
            progress(1)
            return candidates.map(\.time)
        }

        var refined: [Double] = []
        let precise = AVAssetImageGenerator(asset: asset)
        precise.appliesPreferredTrackTransform = true
        precise.maximumSize = CGSize(width: 48, height: 48)
        precise.requestedTimeToleranceBefore = .zero
        precise.requestedTimeToleranceAfter = .zero
        for (n, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            refined.append(await refine(candidate: candidate, generator: precise, frameRate: frameRate))
            progress(0.85 + 0.15 * Double(n + 1) / Double(candidates.count))
        }
        progress(1)
        return refined
    }

    /// Finds the frame with the largest jump between `previous` and `time`.
    private static func refine(candidate: (time: Double, previous: Double), generator: AVAssetImageGenerator,
                               frameRate: Double) async -> Double {
        let step = 1 / frameRate
        let frames = Int(((candidate.time - candidate.previous) / step).rounded())
        guard frames > 1, frames < 240 else { return candidate.time }
        var previousHistogram: [Double]?
        var best = (time: candidate.time, score: -1.0)
        for f in 0...frames {
            let time = candidate.previous + Double(f) * step
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image,
                  let histogram = Histogram.make(image) else { continue }
            if let previousHistogram {
                let score = Histogram.distance(previousHistogram, histogram)
                if score > best.score { best = (time, score) }
            }
            previousHistogram = histogram
        }
        return best.time
    }
}

/// 3 × 16-bin normalized RGB histogram of a tiny image.
enum Histogram {
    static let bins = 16

    static func make(_ image: CGImage) -> [Double]? {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var histogram = [Double](repeating: 0, count: bins * 3)
        let scale = 256 / bins
        for p in stride(from: 0, to: pixels.count, by: 4) {
            histogram[Int(pixels[p]) / scale] += 1
            histogram[bins + Int(pixels[p + 1]) / scale] += 1
            histogram[bins * 2 + Int(pixels[p + 2]) / scale] += 1
        }
        let total = Double(width * height)
        return histogram.map { $0 / total }
    }

    /// 0 (identical) … 1 (completely different).
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum = 0.0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return sum / 6
    }
}
