//
//  FramePreviewRenderer.swift
//  ClipStudio — Engines/Rendering
//
//  Still-frame rendering for the color workspace, crop/mask editors and effect
//  thumbnails: exact source frames, composited timeline frames (optionally hiding
//  clips — the "before" image of an adjustment layer), fast GPU grading of a
//  frame, RGB histograms and image statistics for color matching.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit
import Metal

struct RGBHistogram: Equatable {
    /// 256 bins per channel, normalized to the tallest bin (0…1).
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]

    static let empty = RGBHistogram(red: [], green: [], blue: [], luma: [])
}

struct ImageStatistics {
    var meanR: Double
    var meanG: Double
    var meanB: Double
    var lumaMean: Double
    var lumaStd: Double
    var saturation: Double
}

final class FramePreviewRenderer: @unchecked Sendable {
    static let shared = FramePreviewRenderer()

    let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "FramePreview"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: Frames

    /// The clip's own picture at clip-local time, before any grading or transform.
    func sourceFrame(for clip: Clip, localTime: Double, media: MediaURLMap, canvas: CGSize,
                     maxDimension: CGFloat = 960) async -> CIImage? {
        switch clip.source {
        case .media(let id):
            guard let url = media[id], let sourceTime = SpeedMapping.sourceTime(of: clip, local: localTime) else { return nil }
            return await StillImageLoader.frame(url: url, at: CMTime(seconds: max(0, sourceTime), preferredTimescale: 60_000),
                                                maxDimension: maxDimension)
        case .image(let id):
            guard let url = media[id] else { return nil }
            return StillImageLoader.load(url: url, maxDimension: maxDimension)
        case .freezeFrame(let id, let time):
            guard let url = media[id] else { return nil }
            return await StillImageLoader.frame(url: url, at: time.cm, maxDimension: maxDimension)
        case .solidColor(let color):
            let size = scaled(canvas, maxDimension: maxDimension)
            return CIImage(color: color.ciColor).cropped(to: CGRect(origin: .zero, size: size))
        case .text(let content):
            return GeneratedContentRenderer.shared.image(for: .text(content), canvas: canvas, localTime: localTime,
                                                         clipDuration: clip.duration.seconds)
        case .shape(let content):
            return GeneratedContentRenderer.shared.image(for: .shape(content), canvas: canvas, localTime: localTime,
                                                         clipDuration: clip.duration.seconds)
        case .sticker(let content):
            return GeneratedContentRenderer.shared.image(for: .sticker(content), canvas: canvas, localTime: localTime,
                                                         clipDuration: clip.duration.seconds)
        case .adjustment:
            return nil
        }
    }

    /// A composited timeline frame from an existing preview build (custom compositor),
    /// optionally hiding some clips.
    func compositeFrame(built: BuiltComposition, timeline: Timeline, background: RGBAColor, at time: Double,
                        excluding: Set<UUID>, maxDimension: CGFloat = 960) async -> CIImage? {
        guard let videoComposition = built.refreshedVideoComposition(with: timeline, background: background, excluding: excluding) else {
            return nil
        }
        let asset = (built.composition.copy() as? AVComposition) ?? built.composition
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let clamped = min(max(0, time), max(0, built.duration.seconds - 0.02))
        guard let image = try? await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 60_000)).image else {
            return nil
        }
        return CIImage(cgImage: image)
    }

    // MARK: Grading

    func graded(_ base: CIImage, color: ColorAdjustments, lut: LUTReference?, effects: [EffectInstance] = [],
                localTime: Double = 0) -> CIImage {
        var image = ColorPipeline.apply(color, lut: lut, to: base)
        let active = effects.filter { $0.isEnabled && $0.kind != .letterbox }
        if !active.isEmpty {
            image = EffectRenderer.apply(active, to: image, localTime: localTime, canvas: base.extent.size)
        }
        if let letterbox = effects.first(where: { $0.isEnabled && $0.kind == .letterbox }) {
            image = EffectRenderer.letterbox(image, amount: letterbox.intensity.value(at: localTime), canvas: base.extent)
        }
        return image.cropped(to: base.extent)
    }

    func cgImage(_ image: CIImage) -> CGImage? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    func uiImage(_ image: CIImage) -> UIImage? {
        cgImage(image).map { UIImage(cgImage: $0) }
    }

    /// Before/after composite: left part of `before`, right part of `after` split at `fraction` (0…1).
    func splitComparison(before: CIImage, after: CIImage, fraction: Double) -> CIImage {
        let extent = before.extent
        let x = extent.minX + extent.width * CGFloat(min(max(fraction, 0), 1))
        let left = before.cropped(to: CGRect(x: extent.minX, y: extent.minY, width: x - extent.minX, height: extent.height))
        let right = after.cropped(to: CGRect(x: x, y: extent.minY, width: extent.maxX - x, height: extent.height))
        return left.composited(over: right).cropped(to: extent)
    }

    // MARK: Analysis

    func histogram(_ image: CIImage) -> RGBHistogram {
        let small = downscaled(image, maxDimension: 320)
        guard small.extent.width > 0,
              let filter = CIFilter(name: "CIAreaHistogram", parameters: [
                kCIInputImageKey: small,
                kCIInputExtentKey: CIVector(cgRect: small.extent),
                "inputCount": 256,
                "inputScale": 1
              ]),
              let output = filter.outputImage else { return .empty }
        var bins = [Float](repeating: 0, count: 256 * 4)
        bins.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 256 * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 256, height: 1), format: .RGBAf, colorSpace: nil)
        }
        var red = [Float](repeating: 0, count: 256)
        var green = red, blue = red, luma = red
        for i in 0..<256 {
            red[i] = bins[i * 4]
            green[i] = bins[i * 4 + 1]
            blue[i] = bins[i * 4 + 2]
            luma[i] = 0.2126 * red[i] + 0.7152 * green[i] + 0.0722 * blue[i]
        }
        func normalized(_ values: [Float]) -> [Float] {
            let peak = values.max() ?? 0
            return peak > 0 ? values.map { min(1, $0 / peak) } : values
        }
        return RGBHistogram(red: normalized(red), green: normalized(green), blue: normalized(blue), luma: normalized(luma))
    }

    func statistics(_ image: CIImage) -> ImageStatistics? {
        let side = 64
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scaledImage = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / extent.width, y: CGFloat(side) / extent.height))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaledImage, toBitmap: base, rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: colorSpace)
        }
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumL = 0.0, sumL2 = 0.0, sumS = 0.0
        let count = Double(side * side)
        for i in 0..<(side * side) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b), minC = min(r, g, b)
            sumR += r
            sumG += g
            sumB += b
            sumL += l
            sumL2 += l * l
            sumS += maxC > 0 ? (maxC - minC) / maxC : 0
        }
        let mean = sumL / count
        return ImageStatistics(meanR: sumR / count, meanG: sumG / count, meanB: sumB / count,
                               lumaMean: mean, lumaStd: sqrt(max(0, sumL2 / count - mean * mean)),
                               saturation: sumS / count)
    }

    // MARK: Helpers

    func downscaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return scale < 1 ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : normalized
    }

    private func scaled(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return size }
        let scale = maxDimension / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
