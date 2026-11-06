//
//  ColorMatcher.swift
//  ClipStudio — Engines/Rendering (color grading)
//
//  Shot matching: adjusts a clip's grade so its frame matches a reference frame.
//  Measures luminance mean/contrast, saturation and per-channel balance on
//  64×64 samples and solves iteratively through the real color pipeline
//  (exposure, contrast, saturation and gain wheels), so the result is exactly
//  what the renderer will produce.
//

import Foundation
import CoreImage

enum ColorMatcher {
    struct Result {
        let adjustments: ColorAdjustments
        let reference: ImageStatistics
        let before: ImageStatistics
        let after: ImageStatistics
    }

    /// - Parameters:
    ///   - reference: the frame to match (already graded as it appears in the edit).
    ///   - target: the clip's ungraded source frame.
    ///   - starting: the clip's current grade (curves, LUT-independent sliders are kept).
    ///   - strength: 0…1 blend between the starting grade and the full match.
    static func match(reference: CIImage, target: CIImage, starting: ColorAdjustments,
                      strength: Double = 1, renderer: FramePreviewRenderer = .shared) -> Result? {
        guard let ref = renderer.statistics(reference),
              let before = renderer.statistics(ColorPipeline.apply(starting, lut: nil, to: target)) else { return nil }
        var result = starting
        for _ in 0..<4 {
            guard let current = renderer.statistics(ColorPipeline.apply(result, lut: nil, to: target)) else { break }
            if current.lumaMean > 0.01, ref.lumaMean > 0.01 {
                let ev = log2(ref.lumaMean / current.lumaMean)
                result.exposure = clamp(result.exposure + ev * 50 * 0.8, -100, 100)
            }
            if current.lumaStd > 0.01, ref.lumaStd > 0.005 {
                result.contrast = clamp(result.contrast + (ref.lumaStd / current.lumaStd - 1) * 200 * 0.6, -100, 100)
            }
            if current.saturation > 0.01 {
                result.saturation = clamp(result.saturation + (ref.saturation / current.saturation - 1) * 100 * 0.7, -100, 100)
            }
            let refL = max(0.01, ref.lumaMean)
            let curL = max(0.01, current.lumaMean)
            func gainStep(_ refChannel: Double, _ currentChannel: Double) -> Double {
                let refRatio = refChannel / refL
                let currentRatio = max(0.01, currentChannel / curL)
                return (refRatio / currentRatio - 1) * 0.8
            }
            result.wheels.gain.r = clamp(result.wheels.gain.r + gainStep(ref.meanR, current.meanR), -0.5, 0.5)
            result.wheels.gain.g = clamp(result.wheels.gain.g + gainStep(ref.meanG, current.meanG), -0.5, 0.5)
            result.wheels.gain.b = clamp(result.wheels.gain.b + gainStep(ref.meanB, current.meanB), -0.5, 0.5)
        }
        let blended = blend(starting, result, strength: min(max(strength, 0), 1))
        let after = renderer.statistics(ColorPipeline.apply(blended, lut: nil, to: target)) ?? before
        return Result(adjustments: blended, reference: ref, before: before, after: after)
    }

    static func blend(_ a: ColorAdjustments, _ b: ColorAdjustments, strength t: Double) -> ColorAdjustments {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var result = a
        result.exposure = mix(a.exposure, b.exposure)
        result.contrast = mix(a.contrast, b.contrast)
        result.saturation = mix(a.saturation, b.saturation)
        result.wheels.gain.r = mix(a.wheels.gain.r, b.wheels.gain.r)
        result.wheels.gain.g = mix(a.wheels.gain.g, b.wheels.gain.g)
        result.wheels.gain.b = mix(a.wheels.gain.b, b.wheels.gain.b)
        return result
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
