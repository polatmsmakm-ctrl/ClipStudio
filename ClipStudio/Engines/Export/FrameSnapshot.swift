//
//  FrameSnapshot.swift
//  ClipStudio — Engines/Export
//
//  Renders one frame of a timeline at the project's full canvas resolution with
//  the same compositor as export (colors, effects, text, watermark included) and
//  saves still images to the Photos library.
//

import Foundation
import AVFoundation
import UIKit
import Photos

enum FrameSnapshotError: LocalizedError {
    case renderFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "تعذّر التقاط الإطار من الخط الزمني."
        case .encodeFailed: "تعذّر حفظ الصورة."
        }
    }
}

enum FrameSnapshot {
    /// PNG data of the composite frame at `time` (seconds) at full canvas size.
    static func render(timeline: Timeline, settings: ProjectSettings, media: MediaURLMap, at time: Double) async throws -> Data {
        let size = CGSize(width: ExportGeometry.even(settings.canvasSize.width), height: ExportGeometry.even(settings.canvasSize.height))
        let built = try await CompositionBuilder(media: media).build(timeline: timeline, settings: settings,
                                                                     renderSize: size, frameRate: settings.frameRate)
        let asset = (built.composition.copy() as? AVComposition) ?? built.composition
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size
        let clamped = min(max(0, time), max(0, built.duration.seconds - 0.02))
        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 60_000)).image
        } catch {
            throw FrameSnapshotError.renderFailed
        }
        guard let data = UIImage(cgImage: cgImage).pngData() else { throw FrameSnapshotError.encodeFailed }
        return data
    }
}

extension PhotosSaver {
    /// Saves an encoded image (PNG/JPEG) to the Photos library (add-only permission).
    static func saveImage(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}
