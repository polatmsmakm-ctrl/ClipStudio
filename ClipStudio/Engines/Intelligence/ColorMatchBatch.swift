//
//  ColorMatchBatch.swift
//  ClipStudio — Engines/Intelligence (Part 4 suggestions)
//
//  Matches many clips to one reference picture with ColorMatcher (exposure,
//  contrast, saturation and balance solved through the real color pipeline).
//  Used by "match every shot to this one" and by Editing DNA reference frames.
//

import Foundation
import CoreImage

enum ColorMatchBatch {
    /// New grades for `clips` (clips whose frame can't be read are skipped).
    static func match(reference: CIImage, clips: [Clip], media: MediaURLMap, canvas: CGSize, strength: Double,
                      control: RenderControl?, progress: @Sendable (Double) -> Void) async -> [UUID: ColorAdjustments] {
        var result: [UUID: ColorAdjustments] = [:]
        for (index, clip) in clips.enumerated() {
            if control?.isCancelled == true || Task.isCancelled { break }
            let middle = clip.duration.seconds / 2
            if let frame = await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: middle, media: media,
                                                                       canvas: canvas, maxDimension: 320),
               let match = ColorMatcher.match(reference: reference, target: frame, starting: clip.color, strength: strength) {
                result[clip.id] = match.adjustments
            }
            progress(Double(index + 1) / Double(max(1, clips.count)))
        }
        return result
    }

    /// The reference clip's picture as it appears in the edit (its own grade applied).
    static func referenceFrame(of clip: Clip, media: MediaURLMap, canvas: CGSize, at localTime: Double) async -> CIImage? {
        guard let frame = await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: localTime, media: media,
                                                                       canvas: canvas, maxDimension: 320) else { return nil }
        return FramePreviewRenderer.shared.graded(frame, color: clip.color, lut: clip.lut)
    }
}
