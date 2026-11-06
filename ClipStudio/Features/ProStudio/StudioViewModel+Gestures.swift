//
//  StudioViewModel+Gestures.swift
//  ClipStudio — Features/ProStudio
//
//  Live state for timeline gestures: moving clips (with snapping and track
//  changes), trimming edges, the blade tool and clip taps. Gestures only update
//  preview state; the edit is committed once, as one undo step, when the finger lifts.
//

import Foundation
import SwiftUI

struct MoveDragState: Equatable {
    var anchorID: UUID
    var clipIDs: Set<UUID>
    /// Snapped, frame-aligned time offset.
    var timeDelta: Double
    /// Display rows moved (positive = down).
    var rowDelta: Int
    var guide: Double?
    let candidates: [SnapTarget]
}

struct TrimDragState: Equatable {
    var clipID: UUID
    var edge: TrimEdge
    var original: Clip
    var preview: Clip
    var targetTime: Double
    let candidates: [SnapTarget]
}

extension StudioViewModel {
    /// Snapping distance: 10 points on screen.
    var snapTolerance: Double { 10 / max(pixelsPerSecond, 0.001) }

    private func frameAligned(_ seconds: Double) -> Double {
        (seconds * frameRate).rounded() / frameRate
    }

    // MARK: Move

    func beginMove(anchor id: UUID) {
        guard let ref = TimelineEngine.locate(id, in: timeline) else { return }
        guard !timeline.tracks[ref.track].isLocked else {
            report(TimelineEditError.trackLocked)
            return
        }
        stopShuttle()
        if player.isPlaying { player.pause() }
        if !selection.contains(id) { selection = [id] }
        let movable = selection.filter { clipID in
            guard let index = TimelineEngine.trackIndex(of: clipID, in: timeline) else { return false }
            return !timeline.tracks[index].isLocked
        }
        let candidates = SnapEngine.candidates(timeline: timeline, markers: markers, playhead: currentTime,
                                               inPoint: inPoint, outPoint: outPoint, excluding: movable)
        moveDrag = MoveDragState(anchorID: id, clipIDs: movable, timeDelta: 0, rowDelta: 0, guide: nil, candidates: candidates)
        Haptics.tap()
    }

    func updateMove(rawDelta: Double, rowDelta: Int) {
        guard var drag = moveDrag, let anchor = TimelineEngine.clip(drag.anchorID, in: timeline) else { return }
        let earliest = drag.clipIDs.compactMap { TimelineEngine.clip($0, in: timeline)?.start.seconds }.min() ?? 0
        var delta = max(rawDelta, -earliest)
        var guide: Double?
        if prefs.snappingEnabled {
            let snapped = SnapEngine.snapRange(start: anchor.start.seconds + delta, duration: anchor.duration.seconds,
                                               to: drag.candidates, tolerance: snapTolerance)
            if let target = snapped.guide {
                delta = max(snapped.value - anchor.start.seconds, -earliest)
                guide = target.time
            }
        }
        if guide != drag.guide, guide != nil { Haptics.selection() }
        drag.timeDelta = frameAligned(delta)
        drag.rowDelta = rowDelta
        drag.guide = guide
        moveDrag = drag
        snapGuide = guide
    }

    func commitMove() {
        guard let drag = moveDrag else { return }
        moveDrag = nil
        snapGuide = nil
        guard abs(drag.timeDelta) > 1e-6 || drag.rowDelta != 0 else { return }
        let moves = makeMoves(for: drag)
        if edit("نقل", { timeline, context in try TimelineEngine.move(moves, in: &timeline, context: context) }) {
            Haptics.tap()
        }
    }

    func cancelMove() {
        moveDrag = nil
        snapGuide = nil
    }

    /// Display row a dragged clip is previewed on (nil when not dragged). -1 = new track above, count = new track below.
    func previewRow(for clipID: UUID) -> Int? {
        guard let drag = moveDrag, drag.clipIDs.contains(clipID) else { return nil }
        let order = TimelineEngine.displayOrder(timeline)
        guard let index = TimelineEngine.trackIndex(of: clipID, in: timeline),
              let row = order.firstIndex(of: index) else { return nil }
        switch destination(for: clipID, rowDelta: drag.rowDelta, order: order) {
        case .existing(let track): return order.firstIndex(of: track) ?? row
        case .newTrack(let kind): return kind == .audio ? order.count : -1
        }
    }

    private func makeMoves(for drag: MoveDragState) -> [ClipMove] {
        let order = TimelineEngine.displayOrder(timeline)
        return drag.clipIDs.compactMap { id in
            guard let clip = TimelineEngine.clip(id, in: timeline) else { return nil }
            return ClipMove(clipID: id, newStart: clip.start.seconds + drag.timeDelta,
                            destination: destination(for: id, rowDelta: drag.rowDelta, order: order))
        }
    }

    private func destination(for clipID: UUID, rowDelta: Int, order: [Int]) -> TrackDestination {
        guard let current = TimelineEngine.trackIndex(of: clipID, in: timeline),
              let clip = TimelineEngine.clip(clipID, in: timeline),
              let row = order.firstIndex(of: current) else { return .existing(0) }
        guard rowDelta != 0 else { return .existing(current) }
        let kind = timeline.tracks[current].kind
        let target = row + rowDelta
        if order.indices.contains(target) {
            let candidate = timeline.tracks[order[target]]
            if candidate.kind.isVisual == kind.isVisual, candidate.kind.accepts(clip.source), !candidate.isLocked {
                return .existing(order[target])
            }
            return .existing(current)
        }
        if target < 0 && kind.isVisual { return .newTrack(kind.newTrackKindForMovedClips) }
        if target >= order.count && !kind.isVisual { return .newTrack(.audio) }
        return .existing(current)
    }

    // MARK: Trim

    func beginTrim(_ id: UUID, edge: TrimEdge) {
        guard let clip = TimelineEngine.clip(id, in: timeline), let index = TimelineEngine.trackIndex(of: id, in: timeline) else { return }
        guard !timeline.tracks[index].isLocked else {
            report(TimelineEditError.trackLocked)
            return
        }
        stopShuttle()
        if player.isPlaying { player.pause() }
        let candidates = SnapEngine.candidates(timeline: timeline, markers: markers, playhead: currentTime,
                                               inPoint: inPoint, outPoint: outPoint, excluding: [id])
        trimDrag = TrimDragState(clipID: id, edge: edge, original: clip, preview: clip,
                                 targetTime: edge == .start ? clip.start.seconds : clip.end.seconds, candidates: candidates)
        Haptics.tap()
    }

    func updateTrim(rawDelta: Double) {
        guard var drag = trimDrag else { return }
        let base = drag.edge == .start ? drag.original.start.seconds : drag.original.end.seconds
        var target = max(0, base + rawDelta)
        var guide: Double?
        if prefs.snappingEnabled {
            let snapped = SnapEngine.snap(target, to: drag.candidates, tolerance: snapTolerance)
            if let hit = snapped.guide {
                target = snapped.value
                guide = hit.time
            }
        }
        if guide != snapGuide, guide != nil { Haptics.selection() }
        drag.targetTime = frameAligned(target)
        drag.preview = TimelineEngine.previewTrim(drag.original, edge: drag.edge, to: drag.targetTime, in: timeline,
                                                  ripple: false, context: editContext)
        trimDrag = drag
        snapGuide = guide
    }

    func commitTrim() {
        guard let drag = trimDrag else { return }
        trimDrag = nil
        snapGuide = nil
        let unchanged = drag.preview.start == drag.original.start && drag.preview.duration == drag.original.duration
        guard !unchanged else { return }
        edit("قص الحافة") { timeline, context in
            try TimelineEngine.trim(drag.clipID, edge: drag.edge, to: drag.targetTime, ripple: false,
                                    in: &timeline, context: context)
        }
    }

    func cancelTrim() {
        trimDrag = nil
        snapGuide = nil
    }

    // MARK: Taps

    /// Tap on a clip: select (select tool) or cut there (blade tool).
    func tapClip(_ id: UUID, atTime time: Double) {
        switch tool {
        case .select:
            select(id)
        case .blade:
            var cut = time
            if prefs.snappingEnabled {
                let candidates = SnapEngine.candidates(timeline: timeline, markers: markers, playhead: currentTime,
                                                       inPoint: inPoint, outPoint: outPoint, excluding: [id])
                cut = SnapEngine.snap(time, to: candidates, tolerance: snapTolerance).value
            }
            guard let clip = TimelineEngine.clip(id, in: timeline),
                  cut > clip.start.seconds + frameDuration * 0.99,
                  cut < clip.end.seconds - frameDuration * 0.99 else { return }
            if edit("قطع بالشفرة", { timeline, context in
                try TimelineEngine.split([id], at: cut, in: &timeline, context: context)
            }) {
                Haptics.tap()
            }
        }
    }

    func toggleTool() {
        tool = tool == .select ? .blade : .select
        Haptics.selection()
    }
}
