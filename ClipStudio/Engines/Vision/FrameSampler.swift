//
//  FrameSampler.swift
//  ClipStudio — Engines/Vision (Part 4)
//
//  Delivers downscaled, orientation-corrected frames of a media range at a fixed
//  rate (AVAssetImageGenerator batch API), for Vision analysis: subject detection,
//  object tracking, stabilization and reference analysis.
//

import Foundation
import AVFoundation
import CoreGraphics

struct SampledFrame {
    /// Source seconds actually decoded.
    let time: Double
    let image: CGImage
}

enum FrameSamplerError: LocalizedError {
    case noVideo
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideo: "الملف لا يحتوي فيديو."
        case .cancelled: "تم الإلغاء."
        }
    }
}

enum FrameSampler {
    /// Oriented pixel size of the video track.
    static func videoSize(url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FrameSamplerError.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Calls `handle` for every sampled frame in `span` (source seconds), in order.
    static func sample(url: URL, span: TimeSpan, fps: Double, maxDimension: CGFloat,
                       control: RenderControl?, progress: ((Double) -> Void)? = nil,
                       handle: (SampledFrame) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw FrameSamplerError.noVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: 0.5 / max(1, fps), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = 1 / max(1, fps)
        var times: [CMTime] = []
        var t = span.start
        while t < span.end - 0.001 {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }
        guard !times.isEmpty else { return }
        var index = 0
        for await result in generator.images(for: times) {
            if control?.isCancelled == true || Task.isCancelled { throw FrameSamplerError.cancelled }
            index += 1
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                try handle(SampledFrame(time: actual.seconds, image: image))
            case .failure:
                break
            }
            progress?(Double(index) / Double(times.count))
        }
    }
}
