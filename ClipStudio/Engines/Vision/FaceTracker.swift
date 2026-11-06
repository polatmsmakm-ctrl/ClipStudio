//
//  FaceTracker.swift
//  ClipStudio — Engines/Vision (Part 4 suggestions)
//
//  Every face in a clip, each followed as its own track — for privacy blur and
//  subject masks. Faces are detected on device (8 fps) and linked frame to frame
//  by overlap / distance; short flickers are dropped. Cached per file + range.
//  ReframeEngine.maskPath turns a track into mask center / size keyframes in the
//  clip's own (post-crop) coordinates.
//

import Foundation
import Vision
import CoreGraphics

enum FaceTracker {
    static let fps: Double = 8

    private static func cacheURL(assetID: UUID, span: TimeSpan) -> URL {
        let key = assetID.uuidString + "-faces-" + String(Int(span.start * 10)) + "-" + String(Int(span.end * 10))
        return StorageManager.shared.analysisDirectory.appendingPathComponent(key + "-v1.json")
    }

    static func cached(assetID: UUID, span: TimeSpan) -> [SubjectTrack]? {
        JSONStore.load([SubjectTrack].self, from: cacheURL(assetID: assetID, span: span))
    }

    /// One track per face found in `span` (source seconds).
    static func detect(assetID: UUID, url: URL, span: TimeSpan, control: RenderControl?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [SubjectTrack] {
        if let cached = cached(assetID: assetID, span: span) { return cached }
        let size = try await FrameSampler.videoSize(url: url)
        var frames: [(time: Double, boxes: [RectValue])] = []
        try await FrameSampler.sample(url: url, span: span, fps: fps, maxDimension: 640, control: control,
                                      progress: progress) { frame in
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
            let boxes = (request.results ?? []).map { face -> RectValue in
                let b = face.boundingBox
                return RectValue(x: Double(b.minX), y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height))
            }
            frames.append((time: frame.time, boxes: boxes))
        }
        let tracks = group(frames).map { samples in
            SubjectTrack(assetID: assetID, mode: .faces, span: span, samples: samples,
                         sourceWidth: Double(size.width), sourceHeight: Double(size.height))
        }
        try? FileManager.default.createDirectory(at: StorageManager.shared.analysisDirectory, withIntermediateDirectories: true)
        try? JSONStore.save(tracks, to: cacheURL(assetID: assetID, span: span))
        return tracks
    }

    static func iou(_ a: RectValue, _ b: RectValue) -> Double {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        let inter = max(0, x1 - x0) * max(0, y1 - y0)
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Links per-frame boxes into tracks (greedy, biggest faces first).
    /// - Parameters:
    ///   - maxGap: seconds a face may disappear and still continue its track.
    ///   - minSamples: tracks with fewer detections are dropped (false positives).
    static func group(_ frames: [(time: Double, boxes: [RectValue])], maxGap: Double = 1.0,
                      minSamples: Int = 3) -> [[SubjectSample]] {
        struct Active {
            var samples: [SubjectSample]
            var last: RectValue
            var lastTime: Double
        }
        var active: [Active] = []
        var finished: [[SubjectSample]] = []
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            // Retire tracks that have been gone too long.
            var kept: [Active] = []
            for track in active {
                if frame.time - track.lastTime > maxGap { finished.append(track.samples) } else { kept.append(track) }
            }
            active = kept
            var used = Set<Int>()
            for box in frame.boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
                var bestIndex: Int?
                var bestScore = 0.0
                for (index, track) in active.enumerated() where !used.contains(index) {
                    let overlap = iou(box, track.last)
                    var score = overlap
                    if overlap == 0 {
                        let dx = (box.x + box.width / 2) - (track.last.x + track.last.width / 2)
                        let dy = (box.y + box.height / 2) - (track.last.y + track.last.height / 2)
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let reach = max(box.width, box.height, track.last.width, track.last.height) * 1.2
                        score = distance < reach ? 0.01 * (1 - distance / reach) : 0
                    }
                    if score > bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }
                let sample = SubjectSample(time: frame.time, rect: box, confidence: 1)
                if let bestIndex {
                    used.insert(bestIndex)
                    active[bestIndex].samples.append(sample)
                    active[bestIndex].last = box
                    active[bestIndex].lastTime = frame.time
                } else {
                    active.append(Active(samples: [sample], last: box, lastTime: frame.time))
                    used.insert(active.count - 1)
                }
            }
        }
        finished += active.map(\.samples)
        return finished.filter { $0.count >= minSamples }.sorted { ($0.first?.time ?? 0) < ($1.first?.time ?? 0) }
    }
}

// MARK: - Masks that follow a subject

struct SubjectMaskPath {
    var center: KeyframedValue<Vec2>
    var size: KeyframedValue<Vec2>
    /// Clip-local span where the subject was seen.
    var firstLocal: Double
    var lastLocal: Double
}

extension ReframeEngine {
    /// Mask center / size keyframes (clip coordinates after the crop) for a track.
    /// - Parameter padding: size multiplier around the detected box (1.6 covers a whole head).
    static func maskPath(track: SubjectTrack, clip: Clip, smoothing: Double, padding: Double) -> SubjectMaskPath? {
        let detected = track.samples.filter { $0.confidence > 0.05 }
        guard !detected.isEmpty else { return nil }
        let centers = smoothedCenters(track, smoothing: smoothing)
        // Size: moving average over detections, held between them.
        var sizes: [(time: Double, w: Double, h: Double)] = []
        for (index, sample) in detected.enumerated() {
            let window = detected[max(0, index - 3)...min(detected.count - 1, index + 3)]
            let w = window.reduce(0) { $0 + $1.rect.width } / Double(window.count)
            let h = window.reduce(0) { $0 + $1.rect.height } / Double(window.count)
            sizes.append((time: sample.time, w: w, h: h))
        }
        func size(at time: Double) -> (w: Double, h: Double) {
            let nearest = sizes.min { abs($0.time - time) < abs($1.time - time) } ?? (time: time, w: 0.2, h: 0.2)
            return (w: nearest.w, h: nearest.h)
        }
        var centerKeys: [Keyframe<Vec2>] = []
        var sizeKeys: [Keyframe<Vec2>] = []
        var lastKey = -Double.greatestFiniteMagnitude
        var firstLocal = Double.greatestFiniteMagnitude
        var lastLocal = -Double.greatestFiniteMagnitude
        let detectedStart = detected.first?.time ?? 0, detectedEnd = detected.last?.time ?? 0
        for point in centers {
            guard let local = SpeedMapping.localTime(of: clip, sourceTime: point.time) else { continue }
            if point.time >= detectedStart - 1e-6 && point.time <= detectedEnd + 1e-6 {
                firstLocal = min(firstLocal, local)
                lastLocal = max(lastLocal, local)
            }
            guard abs(local - lastKey) >= 0.1 else { continue }
            let crop = clip.crop.value(at: local).clamped()
            let s = size(at: point.time)
            centerKeys.append(Keyframe(time: local, value: Vec2(x: (point.x - crop.x) / max(0.0001, crop.width),
                                                                 y: (point.y - crop.y) / max(0.0001, crop.height)), easing: .linear))
            sizeKeys.append(Keyframe(time: local, value: Vec2(x: min(2, s.w * padding / max(0.0001, crop.width)),
                                                               y: min(2, s.h * padding / max(0.0001, crop.height))), easing: .linear))
            lastKey = local
        }
        guard let firstCenter = centerKeys.first, let firstSize = sizeKeys.first, firstLocal <= lastLocal else { return nil }
        centerKeys.sort { $0.time < $1.time }
        sizeKeys.sort { $0.time < $1.time }
        return SubjectMaskPath(center: KeyframedValue(firstCenter.value, keyframes: centerKeys.count > 1 ? centerKeys : []),
                               size: KeyframedValue(firstSize.value, keyframes: sizeKeys.count > 1 ? sizeKeys : []),
                               firstLocal: firstLocal, lastLocal: lastLocal)
    }
}
