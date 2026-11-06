//
//  HorizonLeveler.swift
//  ClipStudio — Engines/Vision (Part 4 suggestions)
//
//  Horizon leveling: Vision measures the horizon tilt (VNDetectHorizonRequest) at
//  4 fps once per file (cached). LayerRenderer rotates each frame by the smoothed
//  opposite angle and zooms just enough to hide the rotated corners
//  (coverScale), so the picture stays full-frame.
//

import Foundation
import Vision
import CoreGraphics
import os

enum HorizonAnalyzer {
    static let fps: Double = 4
    /// Tilts above this are treated as "not a horizon" (≈ 15°).
    static let maximumAngle = 0.26

    static func cacheURL(assetID: UUID) -> URL {
        StorageManager.shared.analysisDirectory.appendingPathComponent(assetID.uuidString + "-horizon-v1.json")
    }

    static func cached(assetID: UUID) -> HorizonData? {
        JSONStore.load(HorizonData.self, from: cacheURL(assetID: assetID))
    }

    static func analyze(assetID: UUID, url: URL, duration: Double, control: RenderControl?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> HorizonData {
        if let cached = cached(assetID: assetID) { return cached }
        var times: [Double] = []
        var angles: [Double] = []
        var confidence: [Double] = []
        try await FrameSampler.sample(url: url, span: TimeSpan(start: 0, end: duration), fps: fps, maxDimension: 480,
                                      control: control, progress: progress) { frame in
            let request = VNDetectHorizonRequest()
            try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
            times.append(frame.time)
            if let horizon = request.results?.first, abs(Double(horizon.angle)) <= maximumAngle {
                angles.append(Double(horizon.angle))
                confidence.append(Double(horizon.confidence))
            } else {
                angles.append(0)
                confidence.append(0)
            }
        }
        let data = HorizonData(assetID: assetID, times: times, angles: angles, confidence: confidence)
        try? FileManager.default.createDirectory(at: StorageManager.shared.analysisDirectory, withIntermediateDirectories: true)
        try? JSONStore.save(data, to: cacheURL(assetID: assetID))
        return data
    }

    /// Angles with missing samples held from the nearest measurement, then box-smoothed.
    static func smoothedAngles(_ data: HorizonData, smoothing: Double) -> [Double] {
        guard !data.angles.isEmpty else { return [] }
        var filled = data.angles
        var last: Double?
        for i in filled.indices {
            if data.confidence[i] > 0.05 { last = filled[i] } else if let last { filled[i] = last }
        }
        if let first = data.confidence.firstIndex(where: { $0 > 0.05 }) {
            for i in 0..<first { filled[i] = data.angles[first] }
        } else {
            return filled.map { _ in 0 }
        }
        let radius = max(0, Int((smoothing * fps).rounded()))
        guard radius > 0, filled.count > 2 else { return filled }
        var prefix = [0.0]
        for v in filled { prefix.append(prefix.last! + v) }
        return filled.indices.map { i in
            let a = max(0, i - radius), b = min(filled.count - 1, i + radius)
            return (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
        }
    }

    /// Zoom that keeps a `width`×`height` frame fully covered after rotating by `angle`.
    static func coverScale(angle: Double, width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let c = cos(abs(angle)), s = sin(abs(angle))
        return max((width * c + height * s) / width, (width * s + height * c) / height)
    }
}

/// In-memory horizon angles for the render threads (thread-safe).
final class HorizonStore: @unchecked Sendable {
    static let shared = HorizonStore()

    private struct Entry {
        let data: HorizonData
        var smoothed: [Double: [Double]]
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: [UUID: Entry]())

    func preload(_ assetIDs: Set<UUID>) {
        for id in assetIDs {
            let loaded = lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Bool in entries[id] != nil }
            guard !loaded, let data = HorizonAnalyzer.cached(assetID: id) else { continue }
            lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Void in entries[id] = Entry(data: data, smoothed: [:]) }
        }
    }

    func insert(_ data: HorizonData) {
        lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Void in entries[data.assetID] = Entry(data: data, smoothed: [:]) }
    }

    /// Smoothed horizon angle (radians) at source time `t`.
    func angle(assetID: UUID, smoothing: Double, at t: Double) -> Double? {
        let key = (smoothing * 20).rounded() / 20
        return lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Double? in
            guard var entry = entries[assetID], !entry.data.times.isEmpty else { return nil }
            let table: [Double]
            if let existing = entry.smoothed[key] {
                table = existing
            } else {
                table = HorizonAnalyzer.smoothedAngles(entry.data, smoothing: key)
                entry.smoothed[key] = table
                entries[assetID] = entry
            }
            let times = entry.data.times
            guard table.count == times.count else { return nil }
            if t <= times[0] { return table[0] }
            if t >= times[times.count - 1] { return table[times.count - 1] }
            var low = 0, high = times.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if times[mid] <= t { low = mid } else { high = mid }
            }
            let f = (t - times[low]) / max(0.0001, times[high] - times[low])
            return table[low] + (table[high] - table[low]) * f
        }
    }
}
