//
//  ReferenceAnalyzer.swift
//  ClipStudio — Engines/Intelligence (Part 4)
//
//  "Edit like this video": learns an Editing DNA from a reference video, entirely
//  on device. Nothing is copied from the reference — only measurements:
//  • shot lengths from scene-cut detection;
//  • fades through black / white flashes at cuts (sampled frame luminance);
//  • a representative frame (small JPEG) that clips are color-matched to;
//  • tempo + share of cuts on the beat (music analysis of its soundtrack);
//  • on-screen text (Vision text recognition) → caption / title style hint;
//  • aspect ratio.
//

import Foundation
import AVFoundation
import Vision
import CoreImage
import UIKit

enum ReferenceAnalyzer {
    struct FrameInfo {
        var time: Double
        var stats: ImageStatistics
        var jpeg: Data?
        var hasText: Bool
        var textInLowerHalf: Bool
    }

    static func analyze(url: URL, name: String, control: RenderControl?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> EditingDNA {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { throw MusicAnalysisError.tooShort }
        let size = try await FrameSampler.videoSize(url: url)

        // 1. Cuts.
        let cuts = try await SceneDetector.detect(url: url, progress: { progress($0 * 0.4) })
            .filter { $0 > 0.2 && $0 < duration - 0.2 }
        if control?.isCancelled == true { throw CancellationError() }
        let edges = [0] + cuts + [duration]
        let lengths = zip(edges.dropFirst(), edges).map { $0 - $1 }.filter { $0 > 0.05 }

        // 2. Frames: look, fades, text.
        let fps = min(2, max(0.2, 60 / duration))
        var frames: [FrameInfo] = []
        var textChecks = 0
        try await FrameSampler.sample(url: url, span: TimeSpan(start: 0, end: duration), fps: fps, maxDimension: 640,
                                      control: control, progress: { progress(0.4 + $0 * 0.35) }) { frame in
            let image = CIImage(cgImage: frame.image)
            guard let stats = FramePreviewRenderer.shared.statistics(image) else { return }
            var info = FrameInfo(time: frame.time, stats: stats, jpeg: nil, hasText: false, textInLowerHalf: false)
            if frames.count % 2 == 0, textChecks < 30 {
                textChecks += 1
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
                let boxes = (request.results ?? []).filter { $0.confidence > 0.4 }.map(\.boundingBox)
                if !boxes.isEmpty {
                    info.hasText = true
                    let lower = boxes.filter { $0.midY < 0.4 }.count
                    info.textInLowerHalf = lower * 2 >= boxes.count
                }
            }
            if stats.lumaMean > 0.08, stats.lumaMean < 0.92 {
                let small = FramePreviewRenderer.shared.downscaled(image, maxDimension: 256)
                if let cg = FramePreviewRenderer.shared.cgImage(small) {
                    info.jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82)
                }
            }
            frames.append(info)
        }
        if control?.isCancelled == true { throw CancellationError() }

        // 3. Music (optional — a silent reference is fine).
        var bpm = 0.0
        var beats: [Double] = []
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty, duration >= 3 {
            if let analysis = try? await MusicAnalyzer.analyze(assetID: UUID(), url: url, cache: false, control: control,
                                                               progress: { progress(0.75 + $0 * 0.2) }) {
                bpm = analysis.bpm
                beats = analysis.beats
            }
        }
        if control?.isCancelled == true { throw CancellationError() }

        var dna = EditingDNA(name: name, symbol: "eye", origin: "من فيديو مرجعي «" + url.deletingPathExtension().lastPathComponent + "»")
        dna.aspect = size.width > 0 && size.height > 0 ? AspectRatio.reduced(width: Int(size.width), height: Int(size.height)) : nil
        if !lengths.isEmpty {
            let mean = lengths.reduce(0, +) / Double(lengths.count)
            let variance = lengths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lengths.count)
            dna.averageShotLength = min(30, max(0.3, (mean * 100).rounded() / 100))
            dna.shotLengthSpread = mean > 0 ? min(1, sqrt(variance) / mean) : 0
        }

        // Fades through black / white flashes near cuts.
        let dark = frames.filter { $0.stats.lumaMean < 0.04 }.map(\.time)
        let bright = frames.filter { $0.stats.lumaMean > 0.96 }.map(\.time)
        let window = max(0.6, 1 / fps)
        let fades = cuts.filter { cut in dark.contains { abs($0 - cut) <= window } }.count
        let flashes = cuts.filter { cut in bright.contains { abs($0 - cut) <= window } }.count
        if !cuts.isEmpty, fades + flashes > 0 {
            dna.transitionRate = min(1, Double(fades + flashes) / Double(cuts.count))
            dna.transitionKind = fades >= flashes ? .fadeBlack : .flash
            dna.transitionDuration = fades >= flashes ? 0.6 : 0.2
        }

        // Representative look: the usable frame closest to the average statistics.
        let usable = frames.filter { $0.jpeg != nil }
        if !usable.isEmpty {
            let n = Double(usable.count)
            let meanL = usable.reduce(0) { $0 + $1.stats.lumaMean } / n
            let meanS = usable.reduce(0) { $0 + $1.stats.saturation } / n
            let meanR = usable.reduce(0) { $0 + $1.stats.meanR } / n
            let meanB = usable.reduce(0) { $0 + $1.stats.meanB } / n
            func distance(_ s: ImageStatistics) -> Double {
                let a = s.lumaMean - meanL, b = s.saturation - meanS, c = s.meanR - meanR, d = s.meanB - meanB
                return a * a + b * b + c * c + d * d
            }
            dna.referenceFrame = usable.min { distance($0.stats) < distance($1.stats) }?.jpeg
        }

        // Rhythm on the beat.
        if bpm > 0, cuts.count >= 3, !beats.isEmpty {
            let onBeat = cuts.filter { cut in beats.contains { abs($0 - cut) <= 0.08 } }.count
            dna.cutsOnBeat = Double(onBeat) / Double(cuts.count) >= 0.5
        }

        // On-screen text.
        let withText = frames.filter(\.hasText)
        if textChecks > 0, Double(withText.count) / Double(textChecks) >= 0.25 {
            let lower = withText.filter(\.textInLowerHalf).count
            if lower * 2 >= withText.count {
                let preset = CaptionStylePreset.bold
                dna.captionStyle = preset.style
                dna.captionHighlight = preset.highlight
                dna.captionHighlightColor = preset.highlightColor
            } else {
                var style = TextStyle()
                style.weight = .heavy
                style.sizeRatio = 0.075
                dna.titleStyle = style
            }
        }
        progress(1)
        return dna
    }
}
