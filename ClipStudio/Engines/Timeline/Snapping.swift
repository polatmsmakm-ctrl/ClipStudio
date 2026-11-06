//
//  Snapping.swift
//  ClipStudio — Engines/Timeline
//
//  Magnetic snapping for moves, trims, the playhead and markers. Candidates are
//  clip edges, the playhead, markers, in/out points and the timeline start.
//

import Foundation

struct SnapPoint: Hashable {
    enum Kind: Hashable {
        case clipEdge, playhead, marker, inOut, start
    }

    let time: Double
    let kind: Kind
}

struct SnapResult {
    /// Snapped value (for a move: the new clip start).
    let value: Double
    /// The time the guide line is drawn at, when snapping happened.
    let guide: SnapPoint?
}

enum SnapEngine {
    static func candidates(timeline: Timeline, markers: [TimelineMarker], playhead: Double?,
                           inPoint: Double?, outPoint: Double?, excluding: Set<UUID>) -> [SnapPoint] {
        var targets: [SnapPoint] = [SnapPoint(time: 0, kind: .start)]
        for time in TimelineEngine.editPoints(timeline, excluding: excluding) where time > 0 {
            targets.append(SnapPoint(time: time, kind: .clipEdge))
        }
        if let playhead { targets.append(SnapPoint(time: playhead, kind: .playhead)) }
        for marker in markers { targets.append(SnapPoint(time: marker.time.seconds, kind: .marker)) }
        if let inPoint { targets.append(SnapPoint(time: inPoint, kind: .inOut)) }
        if let outPoint { targets.append(SnapPoint(time: outPoint, kind: .inOut)) }
        return targets
    }

    /// Snaps a single time (trim edge, playhead, marker).
    static func snap(_ time: Double, to targets: [SnapPoint], tolerance: Double) -> SnapResult {
        guard let best = targets.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(best.time - time) <= tolerance else {
            return SnapResult(value: time, guide: nil)
        }
        return SnapResult(value: best.time, guide: best)
    }

    /// Snaps a moving range by either its start or its end — whichever is closer.
    static func snapRange(start: Double, duration: Double, to targets: [SnapPoint], tolerance: Double) -> SnapResult {
        let startSnap = snap(start, to: targets, tolerance: tolerance)
        let endSnap = snap(start + duration, to: targets, tolerance: tolerance)
        switch (startSnap.guide, endSnap.guide) {
        case (.some(let a), .some(let b)):
            return abs(a.time - start) <= abs(b.time - (start + duration))
                ? startSnap
                : SnapResult(value: endSnap.value - duration, guide: b)
        case (.some, .none):
            return startSnap
        case (.none, .some(let b)):
            return SnapResult(value: endSnap.value - duration, guide: b)
        case (.none, .none):
            return SnapResult(value: start, guide: nil)
        }
    }
}
