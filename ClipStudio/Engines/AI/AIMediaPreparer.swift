//
//  AIMediaPreparer.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Prepares the smallest useful version of the user's media before anything is
//  sent to a cloud model:
//  • still frames (≤ 512 px JPEG) at chosen times — "contact sheets";
//  • a compressed proxy video (≈ 640 px, H.264) for whole-video analysis, never
//    the original file;
//  • the loudness envelope and speech spans used by the on-device provider.
//  The originals are never modified or uploaded.
//

import Foundation
import AVFoundation
import UIKit

struct PreparedFrame: Hashable {
    var time: Double
    var jpeg: Data
}

enum AIMediaPreparer {

    /// Evenly spaced times (or shot middles when cuts are known), at most `count`.
    static func sampleTimes(duration: Double, count: Int, cuts: [Double] = []) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        if cuts.count >= 2 {
            let edges = [0] + cuts.filter { $0 > 0 && $0 < duration } + [duration]
            var middles: [Double] = []
            for index in 0..<(edges.count - 1) where edges[index + 1] - edges[index] > 0.4 {
                middles.append((edges[index] + edges[index + 1]) / 2)
            }
            if middles.count <= count { return middles }
            let step = Double(middles.count) / Double(count)
            return (0..<count).map { middles[min(middles.count - 1, Int(Double($0) * step))] }
        }
        let step = duration / Double(count)
        return (0..<count).map { min(duration - 0.05, step * (Double($0) + 0.5)) }
    }

    /// JPEG frames of a video at `times` (source seconds).
    static func frames(url: URL, times: [Double], maxDimension: CGFloat = 512, quality: CGFloat = 0.7) async -> [PreparedFrame] {
        guard !times.isEmpty else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [PreparedFrame] = []
        for await item in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if case .success(requestedTime: let requested, image: let image, actualTime: _) = item,
               let data = UIImage(cgImage: image).jpegData(compressionQuality: quality) {
                result.append(PreparedFrame(time: requested.seconds, jpeg: data))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// A downscaled JPEG of a photo.
    static func image(url: URL, maxDimension: CGFloat = 768) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.75)
    }

    /// Compressed copy for upload (≈ 640×480 class, H.264 + AAC, .mp4) in the staging folder.
    static func proxyVideo(url: URL, control: RenderControl?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let preset = AVAssetExportSession.allExportPresets().contains(AVAssetExportPreset640x480)
            ? AVAssetExportPreset640x480 : AVAssetExportPresetMediumQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw GeminiError.uploadFailed("تعذر تجهيز نسخة مضغوطة")
        }
        let output = StorageManager.shared.stagingURL(extension: "mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let watcher = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                if control?.isCancelled == true { session.cancelExport() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await session.export()
        watcher.cancel()
        switch session.status {
        case .completed:
            progress(1)
            return output
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            throw GeminiError.cancelled
        default:
            try? FileManager.default.removeItem(at: output)
            throw GeminiError.uploadFailed(session.error?.localizedDescription ?? "")
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Loudness 0…1 at 4 values per second and speech spans (louder than −35 dBFS for ≥ 0.4 s).
    static func loudness(url: URL) async -> (levels: [Double], speech: [TimeSpan]) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return ([], []) }
        guard let windows = try? SilenceDetector.readLevels(asset: asset, track: track, duration: duration, progress: { _ in }) else {
            return ([], [])
        }
        // 20 ms windows → 250 ms values.
        var levels: [Double] = []
        var index = 0
        while index < windows.count {
            let slice = windows[index..<min(windows.count, index + 12)]
            let mean = slice.reduce(0, +) / Double(slice.count)
            levels.append(min(1, max(0, (mean + 60) / 60)))
            index += 12
        }
        var speech: [TimeSpan] = []
        var runStart: Int?
        for (i, value) in windows.enumerated() {
            if value > -35 {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if Double(i - start) * 0.02 >= 0.4 { speech.append(TimeSpan(start: Double(start) * 0.02, end: Double(i) * 0.02)) }
                runStart = nil
            }
        }
        if let start = runStart { speech.append(TimeSpan(start: Double(start) * 0.02, end: Double(windows.count) * 0.02)) }
        return (levels, speech)
    }
}
