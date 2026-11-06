//
//  Stabilizer.swift
//  ClipStudio — Engines/Vision (Part 4)
//
//  Video stabilization on device:
//  1. Analysis — Vision translational registration between consecutive frames
//     (15 fps, 480 px) gives the camera path; cached per media file.
//  2. Rendering — LayerRenderer shifts each frame by (raw path − smoothed path)
//     and zooms slightly to hide the moving edges. Smoothing strength and zoom are
//     per clip and change instantly (no new analysis).
//  StabilizationStore keeps loaded paths in memory for the render threads.
//

import Foundation
import Vision
import CoreGraphics
import os

enum StabilizationAnalyzer {
    static let fps: Double = 15

    static func cacheURL(assetID: UUID) -> URL {
        StorageManager.shared.analysisDirectory.appendingPathComponent(assetID.uuidString + "-stabilize-v1.json")
    }

    /// Analyzes the whole file (cached), so trims and splits never need a new analysis.
    static func analyze(assetID: UUID, url: URL, duration: Double, control: RenderControl?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> StabilizationData {
        if let cached = JSONStore.load(StabilizationData.self, from: cacheURL(assetID: assetID)) { return cached }
        var times: [Double] = []
        var xs: [Double] = []
        var ys: [Double] = []
        var previous: CGImage?
        var cx = 0.0, cy = 0.0
        try await FrameSampler.sample(url: url, span: TimeSpan(start: 0, end: duration), fps: fps, maxDimension: 480,
                                      control: control, progress: progress) { frame in
            if let previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: frame.image, options: [:])
                let handler = VNImageRequestHandler(cgImage: previous, options: [:])
                try handler.perform([request])
                if let alignment = request.results?.first as? VNImageTranslationAlignmentObservation {
                    let t = alignment.alignmentTransform
                    // Vision's translation is in pixels with a bottom-left origin.
                    cx += Double(t.tx) / Double(max(1, frame.image.width))
                    cy -= Double(t.ty) / Double(max(1, frame.image.height))
                }
            }
            previous = frame.image
            times.append(frame.time)
            xs.append(cx)
            ys.append(cy)
        }
        let data = StabilizationData(assetID: assetID, span: TimeSpan(start: 0, end: duration), times: times,
                                     pathX: xs, pathY: ys, sampleRate: fps)
        try? FileManager.default.createDirectory(at: StorageManager.shared.analysisDirectory, withIntermediateDirectories: true)
        try? JSONStore.save(data, to: cacheURL(assetID: assetID))
        return data
    }

    /// Correction (normalized offset to apply to the frame) at every sample for a smoothing strength.
    static func corrections(_ data: StabilizationData, strength: Double) -> (x: [Double], y: [Double]) {
        let radius = max(1, Int((0.25 + 2.75 * min(max(strength, 0), 1)) * data.sampleRate))
        func smooth(_ values: [Double]) -> [Double] {
            guard values.count > 2 else { return values }
            var prefix = [0.0]
            prefix.reserveCapacity(values.count + 1)
            for v in values { prefix.append(prefix.last! + v) }
            return values.indices.map { i in
                let a = max(0, i - radius), b = min(values.count - 1, i + radius)
                return (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
            }
        }
        // raw path = shift that locks each frame onto the first frame; applying
        // (raw − smoothed) leaves only the smoothed camera motion.
        let sx = smooth(data.pathX), sy = smooth(data.pathY)
        return (zip(data.pathX, sx).map { $0 - $1 }, zip(data.pathY, sy).map { $0 - $1 })
    }

    /// Zoom that hides the largest correction (clamped to a sensible range).
    static func suggestedZoom(_ data: StabilizationData, strength: Double) -> Double {
        let c = corrections(data, strength: strength)
        let maxShift = max(c.x.map(abs).max() ?? 0, c.y.map(abs).max() ?? 0)
        return min(1.35, max(1.02, 1 + 2 * maxShift))
    }
}

/// In-memory corrections for the render threads (thread-safe).
final class StabilizationStore: @unchecked Sendable {
    static let shared = StabilizationStore()

    private struct Entry {
        let data: StabilizationData
        var corrections: [Double: (x: [Double], y: [Double])]
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: [UUID: Entry]())

    /// Loads cached analyses for these assets (called before building a composition).
    func preload(_ assetIDs: Set<UUID>) {
        for id in assetIDs {
            let loaded = lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Bool in entries[id] != nil }
            guard !loaded, let data = JSONStore.load(StabilizationData.self, from: StabilizationAnalyzer.cacheURL(assetID: id)) else { continue }
            lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Void in entries[id] = Entry(data: data, corrections: [:]) }
        }
    }

    func insert(_ data: StabilizationData) {
        lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Void in entries[data.assetID] = Entry(data: data, corrections: [:]) }
    }

    /// Normalized correction (+x right, +y down) at source time `t`.
    func correction(assetID: UUID, strength: Double, at t: Double) -> (x: Double, y: Double)? {
        let key = (strength * 100).rounded() / 100
        return lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> (x: Double, y: Double)? in
            guard var entry = entries[assetID], !entry.data.times.isEmpty else { return nil }
            let table: (x: [Double], y: [Double])
            if let existing = entry.corrections[key] {
                table = existing
            } else {
                table = StabilizationAnalyzer.corrections(entry.data, strength: key)
                entry.corrections[key] = table
                entries[assetID] = entry
            }
            let times = entry.data.times
            // Binary search for the surrounding samples, then interpolate.
            var low = 0, high = times.count - 1
            if t <= times[0] { return (table.x[0], table.y[0]) }
            if t >= times[high] { return (table.x[high], table.y[high]) }
            while high - low > 1 {
                let mid = (low + high) / 2
                if times[mid] <= t { low = mid } else { high = mid }
            }
            let f = (t - times[low]) / max(0.0001, times[high] - times[low])
            return (table.x[low] + (table.x[high] - table.x[low]) * f, table.y[low] + (table.y[high] - table.y[low]) * f)
        }
    }
}
