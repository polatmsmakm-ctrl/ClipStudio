//
//  TimelineEngine+Organize.swift
//  ClipStudio — Engines/Timeline (Part 3)
//
//  Pure timeline operations added in Part 3:
//  • closeGaps — removes empty space between clips on a track (transitions kept);
//  • removeRanges — ripple-deletes time ranges across all unlocked tracks (the
//    foundation of text-based editing: delete words, fillers and long pauses);
//  • clips that use the same source file (for "select all from this file");
//  • insertLayer — places a generated layer (text, caption, graphic) on a free
//    track of a given kind;
//  • SpeedMapping.localTime — source time → clip-local time (inverse mapping).
//

import Foundation

extension TimelineEngine {

    // MARK: Gaps

    /// Empty ranges between consecutive clips of a track (start of the timeline excluded).
    static func gaps(in track: Track, context: EditContext) -> [TimeSpan] {
        let clips = track.clips.sorted { $0.start < $1.start }
        var result: [TimeSpan] = []
        var reach = clips.first?.end.seconds ?? 0
        for clip in clips.dropFirst() {
            let start = clip.start.seconds
            if start > reach + context.tolerance {
                result.append(TimeSpan(start: reach, end: start))
            }
            reach = max(reach, clip.end.seconds)
        }
        return result
    }

    /// Moves clips left so no gaps remain between them on track `t`. Returns the removed time.
    @discardableResult
    static func closeGaps(onTrack t: Int, in timeline: inout Timeline, context: EditContext) throws -> Double {
        guard timeline.tracks.indices.contains(t) else { throw TimelineEditError.trackNotFound }
        guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
        var clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        guard clips.count > 1 else { return 0 }
        var removed = 0.0
        var reach = clips[0].end.seconds
        for index in 1..<clips.count {
            let start = clips[index].start.seconds - removed
            if start > reach + context.tolerance {
                removed += start - reach
            }
            let shifted = context.snap(clips[index].start.seconds - removed)
            clips[index].start = TimeValue(seconds: max(0, shifted))
            reach = max(reach, clips[index].end.seconds)
        }
        timeline.tracks[t].clips = clips
        finalize(&timeline, tracks: [t], context: context)
        return removed
    }

    // MARK: Ripple-remove ranges

    /// Removes the given timeline ranges from every unlocked track and closes the holes
    /// (later material moves left), keeping all unlocked tracks in sync. Ranges may be
    /// unsorted or overlap. Returns the total removed duration.
    @discardableResult
    static func removeRanges(_ ranges: [TimeSpan], in timeline: inout Timeline, context: EditContext) -> Double {
        let merged = mergedSpans(ranges.filter { $0.duration > context.tolerance })
        guard !merged.isEmpty else { return 0 }
        var total = 0.0
        // Back to front so earlier ranges keep their positions.
        for span in merged.reversed() {
            let a = max(0, span.start)
            let b = span.end
            guard b - a > context.tolerance else { continue }
            for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
                carve(&timeline, track: t, from: a, to: b, context: context)
                if !isMagnetic(t, timeline, context: context) {
                    shiftClips(&timeline, track: t, startingAt: b, by: -(b - a), context: context)
                }
            }
            total += b - a
        }
        finalize(&timeline, context: context)
        return total
    }

    static func mergedSpans(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end + 0.0005 {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    // MARK: Same source

    /// Ids of every clip that plays the same media file as `clipID` (including itself).
    static func clipsSharingSource(with clipID: UUID, in timeline: Timeline) -> Set<UUID> {
        guard let clip = clip(clipID, in: timeline) else { return [] }
        let assets = Set(clip.source.assetIDs)
        guard !assets.isEmpty else { return [clipID] }
        var ids: Set<UUID> = []
        for track in timeline.tracks {
            for other in track.clips where !Set(other.source.assetIDs).isDisjoint(with: assets) {
                ids.insert(other.id)
            }
        }
        return ids
    }

    // MARK: Generated layers on typed tracks

    /// Places `clip` on a free unlocked track of `kind` (creating one when needed) at `start`.
    @discardableResult
    static func insertLayer(_ clip: Clip, kind: TrackKind, at start: Double, preferring preferred: Int? = nil,
                            in timeline: inout Timeline, context: EditContext) throws -> UUID {
        let begin = max(0, context.snap(start))
        let length = max(context.frame, clip.duration.seconds)
        let track = freeTrack(kind, start: begin, end: begin + length, in: &timeline, context: context, preferring: preferred)
        var placed = clip
        placed.start = TimeValue(seconds: begin)
        return try place([placed], onTrack: track, at: begin, mode: .overwrite, in: &timeline, context: context).first ?? placed.id
    }
}

// MARK: - Inverse speed mapping

extension SpeedMapping {
    /// Clip-local time at which source time `sourceTime` plays, or nil when the source
    /// time is outside the clip's range.
    static func localTime(of clip: Clip, sourceTime: Double) -> Double? {
        guard let range = clip.sourceRange else { return nil }
        let s0 = range.start.seconds, s1 = range.end.seconds
        guard sourceTime >= s0 - 0.0005, sourceTime <= s1 + 0.0005 else { return nil }
        let duration = clip.duration.seconds
        if clip.speed.ramp.isEmpty {
            let rate = max(SpeedSettings.minimumRate, clip.speed.rate)
            let offset = clip.speed.isReversed ? s1 - sourceTime : sourceTime - s0
            return min(duration, max(0, offset / rate))
        }
        // Ramps: monotonic in local time — binary search.
        var low = 0.0, high = duration
        for _ in 0..<40 {
            let mid = (low + high) / 2
            guard let source = SpeedMapping.sourceTime(of: clip, local: mid) else { return nil }
            let before = clip.speed.isReversed ? source > sourceTime : source < sourceTime
            if before { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
