//
//  BeatSync.swift
//  ClipStudio — Engines/Music (Part 4)
//
//  Pure timeline operations driven by a MusicAnalysis:
//  • beat / downbeat times of a music clip in timeline seconds (speed-aware);
//  • cut-to-beat: re-times the clips of one track so every cut lands on a beat
//    (every N beats, or the beat nearest the clip's current length), limited by
//    the source media actually available;
//  • optional transitions centred on the beat (both sides extended by half);
//  • beat markers.
//

import Foundation

enum BeatGrid: String, CaseIterable, Identifiable, Hashable {
    /// Each clip keeps roughly its length; its end moves to the nearest beat.
    case nearest
    case every1, every2, every4, every8

    var id: String { rawValue }

    var beats: Int? {
        switch self {
        case .nearest: nil
        case .every1: 1
        case .every2: 2
        case .every4: 4
        case .every8: 8
        }
    }

    var title: String {
        switch self {
        case .nearest: "أقرب إيقاع لطول كل مقطع"
        case .every1: "قطع كل إيقاع"
        case .every2: "قطع كل إيقاعين"
        case .every4: "قطع كل مازورة (4)"
        case .every8: "قطع كل مازورتين (8)"
        }
    }
}

struct BeatSyncOptions: Hashable {
    var grid: BeatGrid = .every2
    /// Cut only on downbeats (strong beats).
    var downbeatsOnly = false
    /// 0 = none; otherwise a transition on every Nth cut.
    var transitionEvery = 0
    var transitionKind: TransitionKind = .crossDissolve
    var transitionDuration: Double = 0.3
    /// Shortest allowed clip (seconds).
    var minimumLength: Double = 0.3
}

struct BeatSyncResult: Hashable {
    var retimed = 0
    var onBeat = 0
    var transitions = 0
    var skipped = 0
}

enum BeatSync {

    /// Beats of `analysis` that the music clip plays, in timeline seconds.
    static func timelineBeats(_ analysis: MusicAnalysis, clip: Clip) -> (beats: [Double], downbeats: [Double]) {
        func map(_ times: [Double]) -> [Double] {
            times.compactMap { source -> Double? in
                guard let local = SpeedMapping.localTime(of: clip, sourceTime: source) else { return nil }
                guard local >= 0, local <= clip.duration.seconds else { return nil }
                return clip.start.seconds + local
            }.sorted()
        }
        return (map(analysis.beats), map(analysis.downbeats))
    }

    /// Longest timeline length the clip can have from its current start (source limit).
    static func maximumLength(of clip: Clip, context: EditContext) -> Double {
        guard let range = clip.sourceRange else { return .greatestFiniteMagnitude }
        guard clip.speed.ramp.isEmpty else { return clip.duration.seconds }
        let rate = max(SpeedSettings.minimumRate, clip.speed.rate)
        let available: Double
        if clip.speed.isReversed {
            available = max(0, range.start.seconds)
        } else {
            let total = clip.mediaAssetID.flatMap { context.assetDuration($0) } ?? range.end.seconds
            available = max(0, total - range.end.seconds)
        }
        return clip.duration.seconds + available / rate
    }

    /// Re-times the clips of track `t` so their cuts land on `grid` times (timeline seconds).
    @discardableResult
    static func cutToBeats(track t: Int, beats: [Double], downbeats: [Double], options: BeatSyncOptions,
                           in timeline: inout Timeline, context: EditContext) throws -> BeatSyncResult {
        guard timeline.tracks.indices.contains(t) else { throw TimelineEditError.trackNotFound }
        guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
        let points = (options.downbeatsOnly && downbeats.count >= 2 ? downbeats : beats).sorted()
        var clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        guard !clips.isEmpty, points.count >= 2 else { return BeatSyncResult() }

        var result = BeatSyncResult()
        var cursor = clips[0].start.seconds
        var cutsOnBeat: [Bool] = []
        let minimum = max(context.frame * 2, options.minimumLength)

        for index in clips.indices {
            var clip = clips[index]
            clip.transitionIn = nil
            let shift = cursor - clip.start.seconds
            clip.start = TimeValue(seconds: context.snap(cursor))
            let original = clip.duration.seconds
            let limit = maximumLength(of: clip, context: context)
            let candidates = points.filter { $0 > cursor + minimum - 1e-6 }
            var target: Double?
            if let n = options.grid.beats {
                let step = max(1, n / (options.downbeatsOnly ? 4 : 1))
                if candidates.count >= step { target = candidates[step - 1] }
            } else {
                target = candidates.min { abs($0 - (cursor + original)) < abs($1 - (cursor + original)) }
            }
            if let wanted = target, wanted - cursor > limit + context.tolerance {
                // Not enough source: the latest beat that still fits.
                target = candidates.last { $0 - cursor <= limit + context.tolerance }
            }
            if let end = target {
                let resized = TimelineEngine.trimmedEnd(clip, to: end, context: context)
                clip = resized
                let landed = abs(clip.end.seconds - end) <= context.tolerance * 2
                if landed { result.onBeat += 1 } else { result.skipped += 1 }
                cutsOnBeat.append(landed)
                if abs(clip.duration.seconds - original) > context.tolerance || abs(shift) > context.tolerance { result.retimed += 1 }
            } else {
                cutsOnBeat.append(false)
                result.skipped += 1
                if abs(shift) > context.tolerance { result.retimed += 1 }
            }
            clips[index] = clip
            cursor = clip.end.seconds
        }

        // Transitions centred on the beat: the outgoing clip runs half the transition past
        // the cut and the incoming clip starts half before it.
        if options.transitionEvery > 0, options.transitionKind != .none, clips.count > 1 {
            var cutNumber = 0
            for index in 1..<clips.count {
                guard cutsOnBeat[index - 1] else { continue }
                cutNumber += 1
                guard cutNumber % options.transitionEvery == 0 else { continue }
                let a = clips[index - 1], b = clips[index]
                let cut = a.end.seconds
                guard abs(b.start.seconds - cut) <= context.tolerance else { continue }
                var half = context.floorToFrame(options.transitionDuration / 2)
                half = min(half, context.floorToFrame(min(a.duration.seconds, b.duration.seconds) * 0.25))
                guard half >= context.frame - 1e-9 else { continue }
                let extendedA = TimelineEngine.trimmedEnd(a, to: cut + half, context: context)
                let extendedB = TimelineEngine.trimmedStart(b, to: cut - half, context: context)
                guard abs(extendedA.end.seconds - (cut + half)) <= context.tolerance,
                      abs(extendedB.start.seconds - (cut - half)) <= context.tolerance else { continue }
                clips[index - 1] = extendedA
                clips[index] = extendedB
                clips[index].transitionIn = TransitionInstance(kind: options.transitionKind, duration: TimeValue(seconds: 2 * half))
                result.transitions += 1
            }
        }

        timeline.tracks[t].clips = clips
        TimelineEngine.finalize(&timeline, tracks: [t], context: context)
        return result
    }

    /// Markers at downbeats (or every beat) inside a timeline range.
    static func markers(beats: [Double], downbeats: [Double], everyBeat: Bool, drop: Double?) -> [TimelineMarker] {
        var markers: [TimelineMarker] = []
        let times = everyBeat ? beats : (downbeats.isEmpty ? beats : downbeats)
        for (index, time) in times.enumerated() {
            markers.append(TimelineMarker(time: TimeValue(seconds: time), name: "إيقاع " + String(index + 1),
                                          color: RGBAColor(hex: 0x6FB7E8)))
        }
        if let drop {
            markers.append(TimelineMarker(time: TimeValue(seconds: drop), name: "ذروة الموسيقى", color: RGBAColor(hex: 0xE3B04B)))
        }
        return markers
    }

    /// Drop time of the analysis in timeline seconds (nil when the clip doesn't play it).
    static func timelineDrop(_ analysis: MusicAnalysis, clip: Clip) -> Double? {
        guard let drop = analysis.dropTime, let local = SpeedMapping.localTime(of: clip, sourceTime: drop) else { return nil }
        return clip.start.seconds + local
    }
}
