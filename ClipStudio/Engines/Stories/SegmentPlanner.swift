//
//  SegmentPlanner.swift
//  ClipStudio — Engines/Stories
//
//  Pure, deterministic split planning (fully unit-tested):
//  rule + duration + optional snap points → contiguous [start, end) segments.
//

import Foundation

struct PlannedRange: Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

enum SegmentPlanner {
    static let minimumSegment = 0.5

    static func plan(duration: Double, rule: SplitRule, snapPoints: [Double] = []) -> [PlannedRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        let limit = effectiveMaximum(rule)
        var boundaries = baseBoundaries(duration: duration, rule: rule)

        if rule.snap != .none, !snapPoints.isEmpty, boundaries.count > 2 {
            boundaries = snap(boundaries, to: snapPoints.sorted(), tolerance: max(0, rule.snapTolerance),
                              duration: duration, limit: limit)
        }

        var ranges: [PlannedRange] = []
        for i in 0..<(boundaries.count - 1) where boundaries[i + 1] - boundaries[i] > 0.001 {
            ranges.append(PlannedRange(start: boundaries[i], end: boundaries[i + 1]))
        }
        return mergeShortTail(ranges, minimumTail: rule.minimumTail, limit: limit)
    }

    /// The hard maximum length any segment may have (nil = unlimited).
    static func effectiveMaximum(_ rule: SplitRule) -> Double? {
        var limits: [Double] = []
        if let hard = rule.hardMaximum, hard > 0 { limits.append(hard) }
        if rule.mode == .maxDuration || rule.mode == .fixedDuration, rule.seconds > 0 { limits.append(rule.seconds) }
        return limits.min()
    }

    static func baseBoundaries(duration: Double, rule: SplitRule) -> [Double] {
        var cuts: [Double] = []
        switch rule.mode {
        case .maxDuration:
            let maxLen = max(minimumSegment, rule.seconds)
            let count = max(1, Int((duration / maxLen - 1e-9).rounded(.up)))
            let length = duration / Double(count)
            cuts = (1..<max(count, 1)).map { Double($0) * length }
        case .fixedDuration:
            let length = max(minimumSegment, rule.seconds)
            var t = length
            while t < duration - 0.001 {
                cuts.append(t)
                t += length
            }
        case .equalParts:
            let count = max(1, rule.parts)
            let length = duration / Double(count)
            cuts = (1..<max(count, 1)).map { Double($0) * length }
        case .customDurations:
            let list = rule.customDurations.filter { $0 > 0 }
            guard let lastLength = list.last else { break }
            var t = 0.0
            var index = 0
            while true {
                let length = max(minimumSegment, index < list.count ? list[index] : lastLength)
                t += length
                if t >= duration - 0.001 { break }
                cuts.append(t)
                index += 1
            }
        }
        if let hard = rule.hardMaximum, hard > 0, rule.mode != .maxDuration {
            cuts = enforceMaximum(cuts: cuts, duration: duration, maximum: hard)
        }
        return [0] + cuts + [duration]
    }

    /// Splits any segment longer than `maximum` into equal pieces.
    static func enforceMaximum(cuts: [Double], duration: Double, maximum: Double) -> [Double] {
        let bounds = [0] + cuts + [duration]
        var result: [Double] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            let length = b - a
            if length > maximum + 0.001 {
                let pieces = Int((length / maximum).rounded(.up))
                let step = length / Double(pieces)
                for p in 1..<pieces { result.append(a + Double(p) * step) }
            }
            if i < bounds.count - 2 { result.append(b) }
        }
        return result.sorted()
    }

    /// Moves each interior boundary to the nearest snap point within tolerance,
    /// keeping segments ≥ minimumSegment and (when limited) ≤ limit, and keeping
    /// the remaining duration coverable by the remaining segments.
    static func snap(_ boundaries: [Double], to points: [Double], tolerance: Double,
                     duration: Double, limit: Double?) -> [Double] {
        var result = boundaries
        let lastIndex = result.count - 1
        for i in 1..<lastIndex {
            let target = boundaries[i]
            let previous = result[i - 1]
            let remainingSegments = Double(lastIndex - i)
            let candidates = points.filter { point in
                guard abs(point - target) <= tolerance else { return false }
                guard point - previous >= minimumSegment, duration - point >= minimumSegment * remainingSegments else { return false }
                if let limit {
                    guard point - previous <= limit + 0.001 else { return false }
                    guard duration - point <= limit * remainingSegments + 0.001 else { return false }
                }
                return true
            }
            if let best = candidates.min(by: { abs($0 - target) < abs($1 - target) }) {
                result[i] = best
            } else {
                result[i] = max(target, previous + minimumSegment)
            }
        }
        return result
    }

    static func mergeShortTail(_ ranges: [PlannedRange], minimumTail: Double, limit: Double?) -> [PlannedRange] {
        guard ranges.count > 1, let last = ranges.last, last.duration < minimumTail else { return ranges }
        let previous = ranges[ranges.count - 2]
        let combined = last.end - previous.start
        if let limit, combined > limit + 0.001 { return ranges }
        var result = Array(ranges.dropLast(2))
        result.append(PlannedRange(start: previous.start, end: last.end))
        return result
    }

    /// Nearest snap point to `time` within `tolerance`, if any.
    static func nearest(_ time: Double, in points: [Double], tolerance: Double) -> Double? {
        points.filter { abs($0 - time) <= tolerance }.min { abs($0 - time) < abs($1 - time) }
    }
}
