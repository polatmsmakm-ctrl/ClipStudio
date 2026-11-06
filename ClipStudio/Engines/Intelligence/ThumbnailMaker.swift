//
//  ThumbnailMaker.swift
//  ClipStudio — Engines/Intelligence (Part 6 suggestions)
//
//  Automatic thumbnail: the finished composite (titles, color, effects included)
//  is sampled across the project; each frame is scored on device for sharpness,
//  exposure, colorfulness, contrast and face quality (Vision); the best frames are
//  offered, and the chosen one is composed with large readable thumbnail text
//  (Arabic-ready) into a JPEG saved to Files and Photos.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit
import Vision

struct FrameMetrics: Hashable {
    /// Variance of the Laplacian on a 128 px grayscale copy (higher = sharper).
    var sharpness: Double
    /// 0…1 mean luma.
    var brightness: Double
    /// Hasler–Süsstrunk colorfulness (0…~1.5).
    var colorfulness: Double
    /// 0…1 standard deviation of luma ×2.
    var contrast: Double
    /// 0…1 best face capture quality (0 = no face).
    var faceQuality: Double
    var faceCount: Int
}

struct ThumbnailCandidate: Identifiable {
    let id = UUID()
    let time: Double
    let image: CGImage
    let metrics: FrameMetrics
    let score: Double
}

enum ThumbnailTextPosition: String, CaseIterable, Identifiable, Hashable {
    case top, center, bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "أعلى"
        case .center: "وسط"
        case .bottom: "أسفل"
        }
    }
}

struct ThumbnailStyle: Hashable {
    var position: ThumbnailTextPosition = .bottom
    var useAccent = true
    /// Text height relative to the image height.
    var size: Double = 0.1
    var darken: Double = 0.45
}

enum ThumbnailMaker {

    // MARK: Pure scoring

    /// Grayscale Laplacian variance (4-neighbour kernel).
    static func laplacianVariance(_ gray: [Float], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var values: [Double] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let lap = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - width] - gray[i + width]
                values.append(Double(lap))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// Brightness, colorfulness and contrast from RGBA bytes (0…255).
    static func colorStats(_ rgba: [UInt8], width: Int, height: Int) -> (brightness: Double, colorfulness: Double, contrast: Double) {
        let count = width * height
        guard count > 0, rgba.count >= count * 4 else { return (0, 0, 0) }
        var lumas: [Double] = []
        lumas.reserveCapacity(count)
        var rgSum = 0.0, ybSum = 0.0, rgSq = 0.0, ybSq = 0.0
        for p in 0..<count {
            let r = Double(rgba[p * 4]) / 255, g = Double(rgba[p * 4 + 1]) / 255, b = Double(rgba[p * 4 + 2]) / 255
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            let rg = r - g, yb = 0.5 * (r + g) - b
            rgSum += rg; ybSum += yb; rgSq += rg * rg; ybSq += yb * yb
        }
        let n = Double(count)
        let brightness = lumas.reduce(0, +) / n
        let variance = lumas.reduce(0) { $0 + ($1 - brightness) * ($1 - brightness) } / n
        let rgMean = rgSum / n, ybMean = ybSum / n
        let rgStd = max(0, rgSq / n - rgMean * rgMean).squareRoot()
        let ybStd = max(0, ybSq / n - ybMean * ybMean).squareRoot()
        let colorfulness = (rgStd * rgStd + ybStd * ybStd).squareRoot() + 0.3 * (rgMean * rgMean + ybMean * ybMean).squareRoot()
        return (brightness, colorfulness, min(1, variance.squareRoot() * 2))
    }

    /// 0…100 — how good a frame is as a thumbnail.
    static func score(_ m: FrameMetrics) -> Double {
        let sharp = min(1, log10(1 + m.sharpness * 1000) / 2.5)
        let exposure = max(0, 1 - abs(m.brightness - 0.5) * 2.2)
        let color = min(1, m.colorfulness / 0.45)
        let faces = m.faceCount > 0 ? 0.4 + 0.6 * m.faceQuality : 0
        var value = 0.32 * sharp + 0.2 * exposure + 0.14 * color + 0.12 * m.contrast + 0.22 * faces
        if m.brightness < 0.12 || m.brightness > 0.94 { value -= 0.3 }
        return min(100, max(0, value * 100))
    }

    /// Evenly spaced sample times (avoiding the very first and last frames).
    static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0.2, count > 0 else { return duration > 0 ? [0] : [] }
        let step = duration / Double(count + 1)
        return (1...count).map { Double($0) * step }
    }

    // MARK: Measuring

    static func metrics(_ image: CGImage) -> FrameMetrics {
        let width = 128
        let height = max(8, Int(Double(width) * Double(image.height) / Double(max(1, image.width))))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return FrameMetrics(sharpness: 0, brightness: 0, colorfulness: 0, contrast: 0, faceQuality: 0, faceCount: 0) }
        var gray = [Float](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            gray[p] = (0.2126 * Float(rgba[p * 4]) + 0.7152 * Float(rgba[p * 4 + 1]) + 0.0722 * Float(rgba[p * 4 + 2])) / 255
        }
        let stats = colorStats(rgba, width: width, height: height)
        var faceQuality = 0.0
        var faceCount = 0
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform([request])) != nil, let faces = request.results {
            faceCount = faces.count
            faceQuality = faces.compactMap { $0.faceCaptureQuality.map(Double.init) }.max() ?? (faces.isEmpty ? 0 : 0.4)
        }
        return FrameMetrics(sharpness: laplacianVariance(gray, width: width, height: height), brightness: stats.brightness,
                            colorfulness: stats.colorfulness, contrast: stats.contrast, faceQuality: faceQuality, faceCount: faceCount)
    }

    /// Composite frames of the timeline at `times` (titles, color and effects included).
    static func frames(timeline: Timeline, settings: ProjectSettings, media: MediaURLMap, times: [Double],
                       maxShortSide: CGFloat, progress: (Double) -> Void) async throws -> [(time: Double, image: CGImage)] {
        let size = CompositionBuilder.previewSize(canvas: settings.canvasSize, maxShortSide: maxShortSide)
        let built = try await CompositionBuilder(media: media).build(timeline: timeline, settings: settings,
                                                                     renderSize: size, frameRate: settings.frameRate)
        let asset = (built.composition.copy() as? AVComposition) ?? built.composition
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = size
        var result: [(time: Double, image: CGImage)] = []
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            let clamped = min(max(0, time), max(0, built.duration.seconds - 0.05))
            if let frame = try? await generator.image(at: CMTime(seconds: clamped, preferredTimescale: 600)) {
                result.append((time: clamped, image: frame.image))
            }
            progress(Double(index + 1) / Double(max(1, times.count)))
        }
        return result
    }

    /// Samples, measures and ranks frames (best first).
    static func candidates(timeline: Timeline, settings: ProjectSettings, media: MediaURLMap, count: Int = 18,
                           progress: @escaping (Double) -> Void) async throws -> [ThumbnailCandidate] {
        let times = sampleTimes(duration: timeline.duration.seconds, count: count)
        let grabbed = try await frames(timeline: timeline, settings: settings, media: media, times: times, maxShortSide: 720,
                                       progress: { progress($0 * 0.7) })
        var candidates: [ThumbnailCandidate] = []
        for (index, frame) in grabbed.enumerated() {
            try Task.checkCancellation()
            let image = frame.image
            let measured = await Task.detached(priority: .userInitiated) { ThumbnailMaker.metrics(image) }.value
            candidates.append(ThumbnailCandidate(time: frame.time, image: image, metrics: measured, score: score(measured)))
            progress(0.7 + 0.3 * Double(index + 1) / Double(max(1, grabbed.count)))
        }
        return candidates.sorted { $0.score > $1.score }
    }

    // MARK: Composition

    /// Output size: the canvas aspect with the long side at most 1920 px.
    static func outputSize(canvas: CGSize) -> CGSize {
        let long = max(canvas.width, canvas.height)
        guard long > 0 else { return CGSize(width: 1280, height: 720) }
        let scale = min(1, 1920 / long)
        return CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }

    static func compose(frame: CGImage, size: CGSize, text: String, style: ThumbnailStyle) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // Aspect fill.
            let imageSize = CGSize(width: frame.width, height: frame.height)
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            UIImage(cgImage: frame).draw(in: CGRect(origin: origin, size: drawSize))

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Readability gradient on the text side.
            let colors = [UIColor.black.withAlphaComponent(CGFloat(style.darken)).cgColor, UIColor.clear.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let band = size.height * 0.55
                switch style.position {
                case .bottom:
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height - band), options: [])
                case .top:
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: band), options: [])
                case .center:
                    UIColor.black.withAlphaComponent(CGFloat(style.darken * 0.6)).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            }
            let fontSize = max(24, size.height * CGFloat(style.size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.baseWritingDirection = .natural
            paragraph.lineHeightMultiple = 0.95
            let color = style.useAccent ? UIColor(red: 0xE3 / 255, green: 0xB0 / 255, blue: 0x4B / 255, alpha: 1) : .white
            let font = UIFont.systemFont(ofSize: fontSize, weight: .black)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                .strokeColor: UIColor.black, .strokeWidth: -3.5
            ]
            let maxWidth = size.width * 0.9
            let string = NSAttributedString(string: trimmed, attributes: attributes)
            let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: size.height * 0.6),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let height = min(size.height * 0.6, ceil(bounds.height))
            let margin = size.height * 0.07
            let y: CGFloat
            switch style.position {
            case .top: y = margin
            case .center: y = (size.height - height) / 2
            case .bottom: y = size.height - margin - height
            }
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = fontSize * 0.15
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.04)
            context.saveGState()
            context.setShadow(offset: shadow.shadowOffset, blur: shadow.shadowBlurRadius, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            string.draw(with: CGRect(x: (size.width - maxWidth) / 2, y: y, width: maxWidth, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.restoreGState()
            // Accent bar.
            let barWidth = min(maxWidth, size.width * 0.18)
            let barY = style.position == .top ? y + height + fontSize * 0.2 : y - fontSize * 0.35
            UIColor(red: 0xE3 / 255, green: 0xB0 / 255, blue: 0x4B / 255, alpha: 1).setFill()
            context.fill(CGRect(x: (size.width - barWidth) / 2, y: barY, width: barWidth, height: max(4, fontSize * 0.08)))
        }
    }

    /// Writes the JPEG to the Exports folder (unique name) and returns its URL.
    static func save(_ image: UIImage, projectName: String) throws -> (url: URL, data: Data) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        let storage = StorageManager.shared
        storage.ensureDirectories()
        let url = storage.uniqueURL(in: storage.exportsDirectory, baseName: storage.sanitizedFileName(projectName + " صورة مصغرة"), ext: "jpg")
        try data.write(to: url, options: .atomic)
        return (url: url, data: data)
    }
}
