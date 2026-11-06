//
//  SubjectTracker.swift
//  ClipStudio — Engines/Vision (Part 4)
//
//  Finds where the subject is in a video range, entirely on device:
//  • detection modes: faces → people → most salient object (auto), or one of them;
//  • object mode: follows a rectangle chosen by the user (VNTrackObjectRequest).
//  Results are cached per media file + mode in Caches/Analysis. ReframeEngine turns
//  a track into smooth crop keyframes for another aspect ratio, or into position
//  keyframes so a title / sticker follows the subject.
//

import Foundation
import Vision
import CoreGraphics

enum SubjectTracker {
    static let analysisFPS: Double = 8

    private static func cacheURL(assetID: UUID, mode: SubjectMode, span: TimeSpan) -> URL {
        let key = assetID.uuidString + "-subject-" + mode.rawValue + "-" + String(Int(span.start * 10)) + "-" + String(Int(span.end * 10))
        return StorageManager.shared.analysisDirectory.appendingPathComponent(key + "-v1.json")
    }

    static func cached(assetID: UUID, mode: SubjectMode, span: TimeSpan) -> SubjectTrack? {
        JSONStore.load(SubjectTrack.self, from: cacheURL(assetID: assetID, mode: mode, span: span))
    }

    /// Cached track of any detection mode covering `span` (used for multi-format variants).
    static func anyCached(assetID: UUID, span: TimeSpan) -> SubjectTrack? {
        for mode in [SubjectMode.auto, .faces, .people, .salient] {
            if let track = cached(assetID: assetID, mode: mode, span: span) { return track }
        }
        return nil
    }

    // MARK: Detection

    static func detect(assetID: UUID, url: URL, span: TimeSpan, mode: SubjectMode, control: RenderControl?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> SubjectTrack {
        if let cached = cached(assetID: assetID, mode: mode, span: span) { return cached }
        let size = try await FrameSampler.videoSize(url: url)
        var samples: [SubjectSample] = []
        try await FrameSampler.sample(url: url, span: span, fps: analysisFPS, maxDimension: 480, control: control,
                                      progress: progress) { frame in
            let rect = try locate(in: frame.image, mode: mode)
            samples.append(SubjectSample(time: frame.time, rect: rect?.rect ?? RectValue(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                         confidence: rect?.confidence ?? 0))
        }
        let track = SubjectTrack(assetID: assetID, mode: mode, span: span, samples: samples,
                                 sourceWidth: Double(size.width), sourceHeight: Double(size.height))
        try? FileManager.default.createDirectory(at: StorageManager.shared.analysisDirectory, withIntermediateDirectories: true)
        try? JSONStore.save(track, to: cacheURL(assetID: assetID, mode: mode, span: span))
        return track
    }

    /// Top-left normalized rect of the subject in one frame.
    static func locate(in image: CGImage, mode: SubjectMode) throws -> (rect: RectValue, confidence: Double)? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        func convert(_ box: CGRect) -> RectValue {
            RectValue(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height))
        }
        if mode == .auto || mode == .faces {
            let faces = VNDetectFaceRectanglesRequest()
            try handler.perform([faces])
            if let best = (faces.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                // Frame the head and shoulders, not just the face.
                var rect = convert(best.boundingBox)
                rect.y = max(0, rect.y - rect.height * 0.3)
                rect.height = min(1 - rect.y, rect.height * 2.2)
                return (rect, Double(best.confidence))
            }
            if mode == .faces { return nil }
        }
        if mode == .auto || mode == .people {
            let humans = VNDetectHumanRectanglesRequest()
            try handler.perform([humans])
            if let best = (humans.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                return (convert(best.boundingBox), Double(best.confidence))
            }
            if mode == .people { return nil }
        }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try handler.perform([saliency])
        if let observation = saliency.results?.first,
           let object = (observation.salientObjects ?? []).max(by: { $0.confidence < $1.confidence }) {
            return (convert(object.boundingBox), Double(object.confidence))
        }
        return nil
    }

    // MARK: Object tracking

    /// Follows `initial` (top-left normalized rect at `span.start`) through the range.
    static func trackObject(assetID: UUID, url: URL, span: TimeSpan, initial: RectValue, control: RenderControl?,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> SubjectTrack {
        let size = try await FrameSampler.videoSize(url: url)
        let sequence = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: CGRect(x: initial.x, y: 1 - initial.y - initial.height,
                                                                          width: initial.width, height: initial.height))
        var samples: [SubjectSample] = []
        var lost = false
        try await FrameSampler.sample(url: url, span: span, fps: 15, maxDimension: 640, control: control,
                                      progress: progress) { frame in
            if lost {
                samples.append(SubjectSample(time: frame.time, rect: samples.last?.rect ?? initial, confidence: 0))
                return
            }
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: frame.image)
            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                lost = true
                samples.append(SubjectSample(time: frame.time, rect: samples.last?.rect ?? initial, confidence: 0))
                return
            }
            if result.confidence < 0.25 { lost = true }
            observation = result
            let box = result.boundingBox
            samples.append(SubjectSample(time: frame.time,
                                         rect: RectValue(x: Double(box.minX), y: Double(1 - box.maxY),
                                                         width: Double(box.width), height: Double(box.height)),
                                         confidence: Double(result.confidence)))
        }
        return SubjectTrack(assetID: assetID, mode: .object, span: span, samples: samples,
                            sourceWidth: Double(size.width), sourceHeight: Double(size.height))
    }
}

// MARK: - Reframe

enum ReframeEngine {
    struct Point { var time: Double; var x: Double; var y: Double }

    /// Subject centers with gaps filled (hold) and smoothed forward + backward.
    /// - Parameter smoothing: seconds (larger = calmer camera).
    static func smoothedCenters(_ track: SubjectTrack, smoothing: Double) -> [Point] {
        var points: [Point] = []
        var last: (Double, Double)? = nil
        for sample in track.samples {
            if sample.confidence > 0.05 {
                last = (sample.rect.x + sample.rect.width / 2, sample.rect.y + sample.rect.height / 2)
            }
            let center = last ?? (0.5, 0.5)
            points.append(Point(time: sample.time, x: center.0, y: center.1))
        }
        guard points.count > 1 else { return points }
        // Fill the leading gap with the first real position.
        if let firstReal = track.samples.firstIndex(where: { $0.confidence > 0.05 }) {
            for index in 0..<firstReal { points[index].x = points[firstReal].x; points[index].y = points[firstReal].y }
        }
        let tau = max(0.05, smoothing)
        for pass in 0..<2 {
            let indices: [Int] = pass == 0 ? Array(1..<points.count) : Array((0..<(points.count - 1)).reversed())
            for i in indices {
                let j = pass == 0 ? i - 1 : i + 1
                let dt = abs(points[i].time - points[j].time)
                let a = 1 - exp(-dt / tau)
                points[i].x = points[j].x + a * (points[i].x - points[j].x)
                points[i].y = points[j].y + a * (points[i].y - points[j].y)
            }
        }
        return points
    }

    /// Normalized crop size (source space) that fills a canvas of `targetAspect` (w/h).
    static func cropSize(sourceAspect: Double, targetAspect: Double) -> (width: Double, height: Double) {
        if sourceAspect > targetAspect {
            return (min(1, targetAspect / sourceAspect), 1)
        }
        return (1, min(1, sourceAspect / targetAspect))
    }

    /// Crop keyframes (clip-local times) that keep the subject in frame for `targetAspect`.
    /// - Parameter zoom: ≥ 1 tightens the framing around the subject.
    static func cropKeyframes(for clip: Clip, track: SubjectTrack, targetAspect: Double, smoothing: Double,
                              zoom: Double = 1, keyInterval: Double = 0.5) -> KeyframedValue<RectValue> {
        let sourceAspect = track.sourceWidth / max(1, track.sourceHeight)
        let base = cropSize(sourceAspect: sourceAspect, targetAspect: targetAspect)
        let z = min(4, max(1, zoom))
        let size = (width: base.width / z, height: base.height / z)
        func rect(_ point: Point) -> RectValue {
            RectValue(x: min(max(point.x - size.width / 2, 0), 1 - size.width),
                      y: min(max(point.y - size.height / 2, 0), 1 - size.height),
                      width: size.width, height: size.height)
        }
        let centers = smoothedCenters(track, smoothing: smoothing)
        guard let first = centers.first else { return KeyframedValue(RectValue(x: (1 - size.width) / 2, y: (1 - size.height) / 2,
                                                                              width: size.width, height: size.height)) }
        var keys: [Keyframe<RectValue>] = []
        var lastKeyTime = -Double.greatestFiniteMagnitude
        for point in centers {
            guard let local = SpeedMapping.localTime(of: clip, sourceTime: point.time) else { continue }
            if local - lastKeyTime >= keyInterval || keys.isEmpty {
                keys.append(Keyframe(time: local, value: rect(point), easing: .linear))
                lastKeyTime = local
            }
        }
        keys.sort { $0.time < $1.time }
        return KeyframedValue(rect(first), keyframes: keys.count > 1 ? keys : [])
    }

    /// Canvas positions (clip-local times of `overlay`) that follow the subject of `base`.
    static func followPositions(track: SubjectTrack, base: Clip, overlay: Clip, asset: MediaAsset?, canvas: CGSize,
                                smoothing: Double, offset: Vec2) -> KeyframedValue<Vec2>? {
        let centers = smoothedCenters(track, smoothing: smoothing)
        var keys: [Keyframe<Vec2>] = []
        var lastKeyTime = -Double.greatestFiniteMagnitude
        for point in centers {
            guard let baseLocal = SpeedMapping.localTime(of: base, sourceTime: point.time) else { continue }
            let timelineTime = base.start.seconds + baseLocal
            let overlayLocal = timelineTime - overlay.start.seconds
            guard overlayLocal >= 0, overlayLocal <= overlay.duration.seconds, overlayLocal - lastKeyTime >= 0.1 else { continue }
            guard let corners = ClipGeometry.corners(for: base, asset: asset, canvas: canvas, localTime: baseLocal),
                  corners.count == 4 else { continue }
            let crop = base.crop.value(at: baseLocal).clamped()
            let u = (point.x - crop.x) / max(0.0001, crop.width)
            let v = (point.y - crop.y) / max(0.0001, crop.height)
            let tl = corners[0], tr = corners[1], bl = corners[3]
            let px = Double(tl.x) + u * Double(tr.x - tl.x) + v * Double(bl.x - tl.x)
            let py = Double(tl.y) + u * Double(tr.y - tl.y) + v * Double(bl.y - tl.y)
            let position = Vec2(x: px / Double(canvas.width) + offset.x, y: py / Double(canvas.height) + offset.y)
            keys.append(Keyframe(time: overlayLocal, value: position, easing: .linear))
            lastKeyTime = overlayLocal
        }
        guard let first = keys.first else { return nil }
        return KeyframedValue(first.value, keyframes: keys)
    }
}
