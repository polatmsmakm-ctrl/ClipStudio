//
//  TimelineEngine.swift
//  ClipStudio — Engines/Timeline (TimelineEngine module)
//
//  Pure, testable editing operations on `Timeline`:
//  split, trim (normal / ripple), move between tracks with overwrite or insert,
//  delete / ripple delete, duplicate, replace, join, transitions (overlap-based),
//  speed changes, freeze frames, audio detach, generated layers, paste and the
//  helpers used by nested sequences.
//
//  Magnetic mode: the first video track is the primary storyline — it never has
//  gaps; clips are re-packed after every change (transitions overlap by their
//  duration). Every other track is free-form with overwrite semantics.
//
//  All times are snapped to the project frame grid.
//

import Foundation
import CoreMedia

// MARK: - Context & errors

struct EditContext {
    var assetDurations: [UUID: Double] = [:]
    var frameRate: Double = 30
    /// When true, the first video track behaves as a magnetic primary storyline.
    var magnetic: Bool = true

    var frame: Double { 1 / max(1, frameRate) }
    var tolerance: Double { frame * 0.5 }

    func snap(_ seconds: Double) -> Double {
        let f = max(1, frameRate)
        return max(0, (seconds * f).rounded() / f)
    }

    func floorToFrame(_ seconds: Double) -> Double {
        let f = max(1, frameRate)
        return max(0, (seconds * f + 1e-6).rounded(.down) / f)
    }

    func assetDuration(_ id: UUID) -> Double? { assetDurations[id] }
}

enum TimelineEditError: LocalizedError, Equatable {
    case clipNotFound
    case trackNotFound
    case trackLocked
    case incompatibleTrack
    case outsideClip
    case tooShort
    case noPreviousClip
    case cannotJoin
    case notMedia
    case nothingSelected
    case needsVisualClip

    var errorDescription: String? {
        switch self {
        case .clipNotFound: "المقطع غير موجود."
        case .trackNotFound: "المسار غير موجود."
        case .trackLocked: "المسار مقفول — افتح القفل أولاً."
        case .incompatibleTrack: "لا يمكن وضع هذا النوع في هذا المسار."
        case .outsideClip: "رأس التشغيل خارج المقطع."
        case .tooShort: "المقطع قصير جدًا لهذه العملية."
        case .noPreviousClip: "لا يوجد مقطع سابق في نفس المسار لإضافة انتقال."
        case .cannotJoin: "لا يمكن دمج هذين المقطعين — يجب أن يكونا متتاليين من نفس المصدر وبنفس السرعة."
        case .notMedia: "هذه العملية متاحة لمقاطع الفيديو والصوت فقط."
        case .nothingSelected: "حدّد مقطعًا أولاً."
        case .needsVisualClip: "التسلسل المتداخل يحتاج مقطعًا مرئيًا واحدًا على الأقل."
        }
    }
}

struct ClipRef: Hashable {
    var track: Int
    var index: Int
}

enum PlacementMode: String, CaseIterable, Identifiable {
    case insert, overwrite, append

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insert: "إدراج"
        case .overwrite: "استبدال"
        case .append: "إلحاق بالنهاية"
        }
    }

    var symbol: String {
        switch self {
        case .insert: "arrow.right.to.line.compact"
        case .overwrite: "square.on.square.dashed"
        case .append: "text.append"
        }
    }
}

enum TrimEdge { case start, end }

/// Where a moved clip should land.
enum TrackDestination: Hashable {
    case existing(Int)
    case newTrack(TrackKind)
}

struct ClipMove: Hashable {
    var clipID: UUID
    var newStart: Double
    var destination: TrackDestination
}

// MARK: - Track rules

extension TrackKind {
    /// Whether a clip with this source may live on this kind of track.
    func accepts(_ source: ClipSource) -> Bool {
        switch self {
        case .audio:
            if case .media = source { return true }
            return false
        case .adjustment:
            if case .adjustment = source { return true }
            return false
        case .video, .overlay:
            if case .adjustment = source { return false }
            return true
        case .text, .subtitle:
            switch source {
            case .text, .shape, .sticker: return true
            default: return false
            }
        }
    }

    /// Default kind for a brand-new track that will hold a clip from `kind`'s track.
    var newTrackKindForMovedClips: TrackKind {
        switch self {
        case .audio: .audio
        case .adjustment: .adjustment
        case .text, .subtitle: .text
        case .video, .overlay: .overlay
        }
    }
}

// MARK: - Speed mapping

enum SpeedMapping {
    /// Source offset (in playback order) reached after `local` seconds of timeline time.
    static func sourceOffset(speed: SpeedSettings, sourceDuration: Double, local: Double) -> Double {
        guard sourceDuration > 0 else { return 0 }
        if speed.ramp.isEmpty {
            return min(sourceDuration, max(0, local * max(SpeedSettings.minimumRate, speed.rate)))
        }
        let whole = CMTimeRange(start: .zero, duration: CMTime(seconds: sourceDuration, preferredTimescale: 60_000))
        var timelineCursor = 0.0
        var sourceCursor = 0.0
        for piece in speed.segments(for: whole) {
            let d = piece.range.duration.seconds
            let td = d / piece.rate
            if local <= timelineCursor + td {
                return min(sourceDuration, sourceCursor + max(0, local - timelineCursor) * piece.rate)
            }
            timelineCursor += td
            sourceCursor += d
        }
        return sourceDuration
    }

    /// Absolute source time (asset coordinates, forward) displayed at clip-local time.
    static func sourceTime(of clip: Clip, local: Double) -> Double? {
        guard let range = clip.sourceRange else { return nil }
        let sDur = range.duration.seconds
        let offset = sourceOffset(speed: clip.speed, sourceDuration: sDur, local: max(0, local))
        return clip.speed.isReversed ? range.start.seconds + sDur - offset : range.start.seconds + offset
    }

    /// Average playback rate over the whole clip (for waveform/filmstrip drawing).
    static func averageRate(of clip: Clip) -> Double {
        guard let range = clip.sourceRange, clip.duration.seconds > 0 else { return max(SpeedSettings.minimumRate, clip.speed.rate) }
        return range.duration.seconds / clip.duration.seconds
    }
}

// MARK: - Engine

enum TimelineEngine {

    // MARK: Lookup

    static func locate(_ id: UUID, in timeline: Timeline) -> ClipRef? {
        for (t, track) in timeline.tracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == id }) { return ClipRef(track: t, index: i) }
        }
        return nil
    }

    static func clip(_ id: UUID, in timeline: Timeline) -> Clip? {
        locate(id, in: timeline).map { timeline.tracks[$0.track].clips[$0.index] }
    }

    static func trackIndex(of id: UUID, in timeline: Timeline) -> Int? {
        locate(id, in: timeline)?.track
    }

    static func primaryTrackIndex(_ timeline: Timeline, context: EditContext) -> Int? {
        guard context.magnetic else { return nil }
        return timeline.tracks.firstIndex { $0.kind == .video }
    }

    static func isMagnetic(_ track: Int, _ timeline: Timeline, context: EditContext) -> Bool {
        primaryTrackIndex(timeline, context: context) == track
    }

    /// Track rows as displayed: visual tracks top→bottom (highest layer first), then audio tracks.
    static func displayOrder(_ timeline: Timeline) -> [Int] {
        let visual = timeline.tracks.indices.filter { timeline.tracks[$0].kind.isVisual }
        let audio = timeline.tracks.indices.filter { !timeline.tracks[$0].kind.isVisual }
        return Array(visual.reversed()) + audio
    }

    /// All clip boundaries (for snapping and previous/next edit navigation).
    static func editPoints(_ timeline: Timeline, excluding: Set<UUID> = []) -> [Double] {
        var points: Set<Double> = [0]
        for track in timeline.tracks where !track.isHidden {
            for clip in track.clips where !excluding.contains(clip.id) {
                points.insert((clip.start.seconds * 1000).rounded() / 1000)
                points.insert((clip.end.seconds * 1000).rounded() / 1000)
            }
        }
        return points.sorted()
    }

    static func clips(at time: Double, in timeline: Timeline) -> [Clip] {
        timeline.tracks.flatMap { $0.clips.filter { $0.start.seconds <= time && $0.end.seconds > time } }
    }

    /// Whether [start, end) on the track is free of clips (ignoring `excluding`).
    static func isFree(_ timeline: Timeline, track: Int, start: Double, end: Double,
                       excluding: Set<UUID> = [], context: EditContext) -> Bool {
        guard timeline.tracks.indices.contains(track) else { return false }
        return !timeline.tracks[track].clips.contains { clip in
            !excluding.contains(clip.id) && clip.start.seconds < end - context.tolerance && clip.end.seconds > start + context.tolerance
        }
    }

    // MARK: Tracks

    @discardableResult
    static func addTrack(_ kind: TrackKind, to timeline: inout Timeline) -> Int {
        let count = timeline.tracks.filter { $0.kind == kind }.count + 1
        timeline.tracks.append(Track(kind: kind, name: kind.title + " " + String(count)))
        return timeline.tracks.count - 1
    }

    static func removeTrack(_ index: Int, from timeline: inout Timeline) {
        guard timeline.tracks.indices.contains(index) else { return }
        timeline.tracks.remove(at: index)
        if !timeline.tracks.contains(where: { $0.kind == .video }) {
            timeline.tracks.insert(Track(kind: .video, name: TrackKind.video.title + " 1"), at: 0)
        }
    }

    /// Reorders a track within the layer stack (model indices).
    static func moveTrack(from source: Int, to destination: Int, in timeline: inout Timeline) {
        guard timeline.tracks.indices.contains(source) else { return }
        let target = min(max(destination, 0), timeline.tracks.count - 1)
        guard source != target else { return }
        let track = timeline.tracks.remove(at: source)
        timeline.tracks.insert(track, at: target)
    }

    /// First track of `kind` whose range is free, or a new track.
    static func freeTrack(_ kind: TrackKind, start: Double, end: Double, in timeline: inout Timeline,
                          context: EditContext, preferring preferred: Int? = nil) -> Int {
        if let preferred, timeline.tracks.indices.contains(preferred), timeline.tracks[preferred].kind == kind,
           !timeline.tracks[preferred].isLocked,
           isFree(timeline, track: preferred, start: start, end: end, context: context) {
            return preferred
        }
        for index in timeline.tracks.indices where timeline.tracks[index].kind == kind && !timeline.tracks[index].isLocked {
            if isMagnetic(index, timeline, context: context) { continue }
            if isFree(timeline, track: index, start: start, end: end, context: context) { return index }
        }
        return addTrack(kind, to: &timeline)
    }

    // MARK: Normalization

    /// Sorts clips, clamps starts and drops transitions that no longer have a matching overlap.
    static func normalize(_ timeline: inout Timeline, track t: Int, context: EditContext) {
        guard timeline.tracks.indices.contains(t) else { return }
        var clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        for i in clips.indices {
            if clips[i].start.seconds < 0 { clips[i].start = .zero }
            guard let transition = clips[i].transitionIn else { continue }
            guard i > 0, transition.kind != .none else {
                clips[i].transitionIn = nil
                continue
            }
            let previous = clips[i - 1]
            let overlap = previous.end.seconds - clips[i].start.seconds
            let d = transition.duration.seconds
            let limit = min(previous.duration.seconds, clips[i].duration.seconds) * 0.5
            if abs(overlap - d) > context.tolerance * 2 || d > limit + context.tolerance {
                clips[i].transitionIn = nil
            }
        }
        timeline.tracks[t].clips = clips
    }

    /// Packs the magnetic primary track: no gaps, transitions overlap by their duration.
    static func compact(_ timeline: inout Timeline, track t: Int, context: EditContext) {
        guard timeline.tracks.indices.contains(t) else { return }
        var clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        var cursor = TimeValue.zero
        for i in clips.indices {
            if i == 0 { clips[i].transitionIn = nil }
            if let transition = clips[i].transitionIn {
                let limit = min(clips[i - 1].duration.seconds, clips[i].duration.seconds) * 0.5
                if transition.kind == .none || transition.duration.seconds > limit + context.tolerance {
                    clips[i].transitionIn = nil
                }
            }
            let overlap = clips[i].transitionIn?.duration ?? .zero
            let start = cursor - overlap
            clips[i].start = start.seconds < 0 ? .zero : start
            cursor = clips[i].start + clips[i].duration
        }
        timeline.tracks[t].clips = clips
    }

    /// Inserts clips into the magnetic storyline at the clip boundary nearest `time`
    /// (by clip midpoints), then re-packs the track.
    static func insertIntoMagnetic(_ newClips: [Clip], at time: Double, track t: Int,
                                   in timeline: inout Timeline, context: EditContext) {
        guard timeline.tracks.indices.contains(t), !newClips.isEmpty else { return }
        var ordered = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        let index = ordered.filter { $0.start.seconds + $0.duration.seconds / 2 < time }.count
        var inserted = newClips
        inserted[0].transitionIn = nil
        ordered.insert(contentsOf: inserted, at: index)
        var cursor = TimeValue.zero
        for i in ordered.indices {
            ordered[i].start = cursor
            cursor = cursor + ordered[i].duration
        }
        timeline.tracks[t].clips = ordered
        compact(&timeline, track: t, context: context)
    }

    /// Normalizes every track and packs the primary storyline.
    static func finalize(_ timeline: inout Timeline, tracks: Set<Int>? = nil, context: EditContext) {
        let targets = tracks ?? Set(timeline.tracks.indices)
        for t in targets.sorted() where timeline.tracks.indices.contains(t) {
            if isMagnetic(t, timeline, context: context) {
                compact(&timeline, track: t, context: context)
            } else {
                normalize(&timeline, track: t, context: context)
            }
        }
    }

    // MARK: Split

    /// Splits a clip at timeline time `time`. The left part keeps the id.
    static func split(_ clip: Clip, at time: Double, context: EditContext) throws -> (Clip, Clip) {
        let local = context.snap(time) - clip.start.seconds
        guard local >= context.frame - 1e-6, local <= clip.duration.seconds - context.frame + 1e-6 else {
            throw TimelineEditError.outsideClip
        }
        let parts = clip.splitKeyframes(at: local)
        var left = parts.0
        var right = parts.1
        right.id = UUID()
        left.duration = TimeValue(seconds: local)
        right.start = TimeValue(seconds: clip.start.seconds + local)
        right.duration = TimeValue(seconds: clip.duration.seconds - local)
        right.transitionIn = nil
        left.audio.fadeOut = 0
        right.audio.fadeIn = 0
        left.audio.fadeIn = min(clip.audio.fadeIn, local / 2)
        right.audio.fadeOut = min(clip.audio.fadeOut, right.duration.seconds / 2)

        if let range = clip.sourceRange {
            let sDur = range.duration.seconds
            let sStart = range.start.seconds
            let offset = SpeedMapping.sourceOffset(speed: clip.speed, sourceDuration: sDur, local: local)
            if clip.speed.isReversed {
                left.sourceRange = TimeRangeValue(startSeconds: sStart + sDur - offset, endSeconds: sStart + sDur)
                right.sourceRange = TimeRangeValue(startSeconds: sStart, endSeconds: sStart + sDur - offset)
            } else {
                left.sourceRange = TimeRangeValue(startSeconds: sStart, endSeconds: sStart + offset)
                right.sourceRange = TimeRangeValue(startSeconds: sStart + offset, endSeconds: sStart + sDur)
            }
            if !clip.speed.ramp.isEmpty {
                let p = sDur > 0 ? offset / sDur : 0.5
                let ramps = splitRamp(clip.speed, at: p)
                left.speed.ramp = ramps.0
                right.speed.ramp = ramps.1
                left.recomputeDurationFromSpeed()
                right.recomputeDurationFromSpeed()
                left.duration = TimeValue(seconds: max(context.frame, context.snap(left.duration.seconds)))
                right.duration = TimeValue(seconds: max(context.frame, context.snap(right.duration.seconds)))
                right.start = left.end
            }
        }
        return (left, right)
    }

    static func splitRamp(_ speed: SpeedSettings, at p: Double) -> ([SpeedRampPoint], [SpeedRampPoint]) {
        let points = speed.ramp.sorted { $0.position < $1.position }
        let cut = min(max(p, 0.0001), 0.9999)
        let rateAtCut = speed.rate(atPosition: cut)
        var left = points.filter { $0.position < cut }.map { SpeedRampPoint(position: $0.position / cut, rate: $0.rate) }
        if left.first.map({ $0.position > 0.0001 }) ?? true {
            left.insert(SpeedRampPoint(position: 0, rate: speed.rate(atPosition: 0)), at: 0)
        }
        left.append(SpeedRampPoint(position: 1, rate: rateAtCut))
        var right = [SpeedRampPoint(position: 0, rate: rateAtCut)]
        right += points.filter { $0.position > cut }.map { SpeedRampPoint(position: ($0.position - cut) / (1 - cut), rate: $0.rate) }
        if right.last.map({ $0.position < 0.9999 }) ?? true {
            right.append(SpeedRampPoint(position: 1, rate: speed.rate(atPosition: 1)))
        }
        return (left, right)
    }

    /// Splits every given clip (or every unlocked clip under the playhead when `ids` is empty) at `time`.
    @discardableResult
    static func split(_ ids: Set<UUID>, at time: Double, in timeline: inout Timeline, context: EditContext) throws -> [UUID] {
        var created: [UUID] = []
        var touched: Set<Int> = []
        for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
            let candidates = timeline.tracks[t].clips.filter { clip in
                (ids.isEmpty || ids.contains(clip.id)) &&
                clip.start.seconds + context.frame <= time + 1e-6 && clip.end.seconds - context.frame >= time - 1e-6
            }
            for clip in candidates {
                guard let index = timeline.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) else { continue }
                let pair = try split(clip, at: time, context: context)
                let growth = pair.1.end.seconds - clip.end.seconds
                timeline.tracks[t].clips[index] = pair.0
                if abs(growth) > 1e-6 {
                    shiftClips(&timeline, track: t, startingAt: clip.end.seconds, by: growth, excluding: [clip.id], context: context)
                }
                timeline.tracks[t].clips.append(pair.1)
                created.append(pair.1.id)
                touched.insert(t)
            }
        }
        if created.isEmpty && !ids.isEmpty { throw TimelineEditError.outsideClip }
        finalize(&timeline, tracks: touched, context: context)
        return created
    }

    // MARK: Trim

    /// The clip with its start moved to `newStart` (end fixed). Extending is limited by available source.
    static func trimmedStart(_ clip: Clip, to newStart: Double, context: EditContext) -> Clip {
        let target = min(context.snap(newStart), clip.end.seconds - context.frame)
        let delta = target - clip.start.seconds
        if abs(delta) < 1e-6 { return clip }
        if delta > 0 {
            guard let pair = try? split(clip, at: target, context: context) else { return clip }
            var right = pair.1
            right.id = clip.id
            right.transitionIn = clip.transitionIn
            right.audio.fadeIn = min(clip.audio.fadeIn, right.duration.seconds / 2)
            return right
        }
        var result = clip
        var extend = -delta
        if let range = clip.sourceRange {
            guard clip.speed.ramp.isEmpty else { return clip }
            let rate = max(SpeedSettings.minimumRate, clip.speed.rate)
            let sStart = range.start.seconds
            let sEnd = range.end.seconds
            let available: Double
            if clip.speed.isReversed {
                let total = clip.mediaAssetID.flatMap { context.assetDuration($0) } ?? sEnd
                available = max(0, total - sEnd)
            } else {
                available = max(0, sStart)
            }
            extend = context.floorToFrame(min(extend, available / rate))
            let sourceDelta = extend * rate
            result.sourceRange = clip.speed.isReversed
                ? TimeRangeValue(startSeconds: sStart, endSeconds: sEnd + sourceDelta)
                : TimeRangeValue(startSeconds: sStart - sourceDelta, endSeconds: sEnd)
        }
        extend = min(extend, clip.start.seconds)
        guard extend > 1e-6 else { return clip }
        result.start = TimeValue(seconds: clip.start.seconds - extend)
        result.duration = TimeValue(seconds: clip.duration.seconds + extend)
        result.remapKeyframeTimes { $0 + extend }
        return result
    }

    /// The clip with its end moved to `newEnd` (start fixed).
    static func trimmedEnd(_ clip: Clip, to newEnd: Double, context: EditContext) -> Clip {
        let target = max(context.snap(newEnd), clip.start.seconds + context.frame)
        let delta = target - clip.end.seconds
        if abs(delta) < 1e-6 { return clip }
        if delta < 0 {
            guard let pair = try? split(clip, at: target, context: context) else { return clip }
            var left = pair.0
            left.audio.fadeOut = min(clip.audio.fadeOut, left.duration.seconds / 2)
            return left
        }
        var result = clip
        var extend = delta
        if let range = clip.sourceRange {
            guard clip.speed.ramp.isEmpty else { return clip }
            let rate = max(SpeedSettings.minimumRate, clip.speed.rate)
            let sStart = range.start.seconds
            let sEnd = range.end.seconds
            let available: Double
            if clip.speed.isReversed {
                available = max(0, sStart)
            } else {
                let total = clip.mediaAssetID.flatMap { context.assetDuration($0) } ?? sEnd
                available = max(0, total - sEnd)
            }
            extend = context.floorToFrame(min(extend, available / rate))
            let sourceDelta = extend * rate
            result.sourceRange = clip.speed.isReversed
                ? TimeRangeValue(startSeconds: sStart - sourceDelta, endSeconds: sEnd)
                : TimeRangeValue(startSeconds: sStart, endSeconds: sEnd + sourceDelta)
        }
        guard extend > 1e-6 else { return clip }
        result.duration = TimeValue(seconds: clip.duration.seconds + extend)
        return result
    }

    /// Computes the result of a trim without applying it (used for live previews).
    static func previewTrim(_ clip: Clip, edge: TrimEdge, to time: Double, in timeline: Timeline,
                            ripple: Bool, context: EditContext) -> Clip {
        guard let ref = locate(clip.id, in: timeline) else { return clip }
        let magnetic = isMagnetic(ref.track, timeline, context: context)
        var bounded = time
        if !magnetic && !ripple {
            let others = timeline.tracks[ref.track].clips.filter { $0.id != clip.id }
            if edge == .end, let next = others.filter({ $0.start.seconds >= clip.start.seconds + context.tolerance }).min(by: { $0.start < $1.start }) {
                let overlap = next.transitionIn?.duration.seconds ?? 0
                bounded = min(bounded, next.start.seconds + overlap)
            }
            if edge == .start, let previous = others.filter({ $0.end.seconds <= clip.end.seconds - context.tolerance }).max(by: { $0.end < $1.end }) {
                let overlap = clip.transitionIn?.duration.seconds ?? 0
                bounded = max(bounded, previous.end.seconds - overlap)
            }
        }
        var result = edge == .start ? trimmedStart(clip, to: bounded, context: context) : trimmedEnd(clip, to: bounded, context: context)
        if edge == .start && (ripple || magnetic) {
            result.start = clip.start
        }
        return result
    }

    static func trim(_ id: UUID, edge: TrimEdge, to time: Double, ripple: Bool,
                     in timeline: inout Timeline, context: EditContext) throws {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        let original = timeline.tracks[ref.track].clips[ref.index]
        let magnetic = isMagnetic(ref.track, timeline, context: context)
        let updated = previewTrim(original, edge: edge, to: time, in: timeline, ripple: ripple, context: context)
        timeline.tracks[ref.track].clips[ref.index] = updated
        if ripple && !magnetic {
            let growth = updated.end.seconds - original.end.seconds
            if abs(growth) > 1e-6 {
                shiftClips(&timeline, track: ref.track, startingAt: original.end.seconds, by: growth,
                           excluding: [id], context: context)
            }
        }
        finalize(&timeline, tracks: [ref.track], context: context)
    }

    // MARK: Shifting & carving

    static func shiftClips(_ timeline: inout Timeline, track t: Int, startingAt time: Double, by delta: Double,
                           excluding: Set<UUID> = [], context: EditContext) {
        guard timeline.tracks.indices.contains(t), abs(delta) > 1e-9 else { return }
        let shift = TimeValue(seconds: delta)
        for i in timeline.tracks[t].clips.indices {
            let clip = timeline.tracks[t].clips[i]
            guard !excluding.contains(clip.id), clip.start.seconds >= time - context.tolerance else { continue }
            let moved = clip.start + shift
            timeline.tracks[t].clips[i].start = moved.seconds < 0 ? .zero : moved
        }
    }

    /// Clears [a, b) on a track (overwrite): clips inside are removed, clips crossing the edges are trimmed or split.
    static func carve(_ timeline: inout Timeline, track t: Int, from a: Double, to b: Double,
                      excluding: Set<UUID> = [], context: EditContext) {
        guard timeline.tracks.indices.contains(t), b - a > context.tolerance else { return }
        let tol = context.tolerance
        var result: [Clip] = []
        for clip in timeline.tracks[t].clips {
            let s = clip.start.seconds
            let e = clip.end.seconds
            if excluding.contains(clip.id) || e <= a + tol || s >= b - tol {
                result.append(clip)
                continue
            }
            if s >= a - tol && e <= b + tol { continue }
            if s < a && e > b {
                if let first = try? split(clip, at: a, context: context),
                   let second = try? split(first.1, at: b, context: context) {
                    result.append(first.0)
                    var tail = second.1
                    tail.id = UUID()
                    result.append(tail)
                } else {
                    result.append(trimmedEnd(clip, to: a, context: context))
                }
                continue
            }
            if s < a {
                result.append(trimmedEnd(clip, to: a, context: context))
            } else {
                var trimmed = trimmedStart(clip, to: b, context: context)
                trimmed.transitionIn = nil
                result.append(trimmed)
            }
        }
        timeline.tracks[t].clips = result
    }

    // MARK: Placement

    /// Places new clips one after another starting at `time`. Returns their ids.
    @discardableResult
    static func place(_ newClips: [Clip], onTrack t: Int, at time: Double, mode: PlacementMode,
                      in timeline: inout Timeline, context: EditContext) throws -> [UUID] {
        guard timeline.tracks.indices.contains(t) else { throw TimelineEditError.trackNotFound }
        guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
        guard !newClips.isEmpty else { return [] }
        let kind = timeline.tracks[t].kind
        guard newClips.allSatisfy({ kind.accepts($0.source) }) else { throw TimelineEditError.incompatibleTrack }

        let total = newClips.reduce(0) { $0 + $1.duration.seconds }
        var start = context.snap(time)
        if mode == .append { start = timeline.tracks[t].endTime.seconds }

        if isMagnetic(t, timeline, context: context) {
            if mode == .overwrite {
                carve(&timeline, track: t, from: start, to: start + total, context: context)
            } else if mode == .insert, let inside = clipToSplitForInsert(in: timeline.tracks[t], at: start, context: context),
                      let index = timeline.tracks[t].clips.firstIndex(where: { $0.id == inside.id }) {
                let pair = try split(inside, at: start, context: context)
                timeline.tracks[t].clips[index] = pair.0
                timeline.tracks[t].clips.append(pair.1)
            }
            let anchorTime = mode == .append ? Double.greatestFiniteMagnitude : start
            insertIntoMagnetic(newClips, at: anchorTime, track: t, in: &timeline, context: context)
            return newClips.map(\.id)
        }

        switch mode {
        case .overwrite:
            carve(&timeline, track: t, from: start, to: start + total, context: context)
        case .insert:
            if let inside = clipToSplitForInsert(in: timeline.tracks[t], at: start, context: context),
               let index = timeline.tracks[t].clips.firstIndex(where: { $0.id == inside.id }) {
                let pair = try split(inside, at: start, context: context)
                timeline.tracks[t].clips[index] = pair.0
                timeline.tracks[t].clips.append(pair.1)
            }
            shiftClips(&timeline, track: t, startingAt: start, by: total, context: context)
        case .append:
            break
        }

        var cursor = TimeValue(seconds: start)
        var ids: [UUID] = []
        for var clip in newClips {
            clip.start = cursor
            clip.transitionIn = nil
            cursor = cursor + clip.duration
            timeline.tracks[t].clips.append(clip)
            ids.append(clip.id)
        }
        finalize(&timeline, tracks: [t], context: context)
        return ids
    }

    /// The clip an insert edit at `time` must split: strictly inside it, and not inside its
    /// incoming transition overlap (inserting at a cut never splits the next clip).
    static func clipToSplitForInsert(in track: Track, at time: Double, context: EditContext) -> Clip? {
        track.clips.first { clip in
            let overlap = clip.transitionIn?.duration.seconds ?? 0
            return clip.start.seconds + overlap + context.frame <= time + 1e-6 && clip.end.seconds - context.frame >= time - 1e-6
        }
    }

    /// Chooses a sensible track for a new clip: the preferred track when compatible,
    /// otherwise the primary video track (visual media) or a free audio track.
    static func defaultTrack(for source: ClipSource, kind mediaKind: MediaKind?, preferred: Int?,
                             in timeline: inout Timeline, start: Double, end: Double, context: EditContext) -> Int {
        if let preferred, timeline.tracks.indices.contains(preferred),
           timeline.tracks[preferred].kind.accepts(source), !timeline.tracks[preferred].isLocked {
            return preferred
        }
        if mediaKind == .audio {
            return freeTrack(.audio, start: start, end: end, in: &timeline, context: context)
        }
        switch source {
        case .adjustment:
            return freeTrack(.adjustment, start: start, end: end, in: &timeline, context: context)
        case .text, .shape, .sticker, .solidColor:
            return freeTrack(.overlay, start: start, end: end, in: &timeline, context: context)
        default:
            if let primary = timeline.tracks.firstIndex(where: { $0.kind == .video && !$0.isLocked }) { return primary }
            return addTrack(.video, to: &timeline)
        }
    }

    // MARK: Move

    /// Moves clips to new start times and tracks. Free tracks use overwrite; the
    /// magnetic primary track inserts at the nearest clip boundary.
    static func move(_ moves: [ClipMove], in timeline: inout Timeline, context: EditContext) throws {
        guard !moves.isEmpty else { return }
        var originals: [UUID: (clip: Clip, track: Int)] = [:]
        for move in moves {
            guard let ref = locate(move.clipID, in: timeline) else { throw TimelineEditError.clipNotFound }
            guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
            originals[move.clipID] = (timeline.tracks[ref.track].clips[ref.index], ref.track)
        }

        // Resolve destinations (create new tracks once per kind).
        var createdTracks: [TrackKind: Int] = [:]
        var destinations: [UUID: Int] = [:]
        for move in moves {
            guard let original = originals[move.clipID] else { continue }
            switch move.destination {
            case .existing(let index):
                guard timeline.tracks.indices.contains(index) else { throw TimelineEditError.trackNotFound }
                guard !timeline.tracks[index].isLocked else { throw TimelineEditError.trackLocked }
                guard timeline.tracks[index].kind.accepts(original.clip.source) else { throw TimelineEditError.incompatibleTrack }
                destinations[move.clipID] = index
            case .newTrack(let kind):
                guard kind.accepts(original.clip.source) else { throw TimelineEditError.incompatibleTrack }
                if let existing = createdTracks[kind] {
                    destinations[move.clipID] = existing
                } else {
                    let index = addTrack(kind, to: &timeline)
                    createdTracks[kind] = index
                    destinations[move.clipID] = index
                }
            }
        }

        let movingIDs = Set(moves.map(\.clipID))
        var touched = Set(originals.values.map { $0.track })
        for t in timeline.tracks.indices {
            timeline.tracks[t].clips.removeAll { movingIDs.contains($0.id) }
        }
        // Re-pack the primary first so insert positions are computed on a gap-free storyline.
        if let primary = primaryTrackIndex(timeline, context: context), touched.contains(primary) {
            compact(&timeline, track: primary, context: context)
        }

        let earliest = moves.map(\.newStart).min() ?? 0
        let clampShift = earliest < 0 ? -earliest : 0
        var byTrack: [Int: [(Clip, Double)]] = [:]
        for move in moves {
            guard let original = originals[move.clipID], let destination = destinations[move.clipID] else { continue }
            byTrack[destination, default: []].append((original.clip, context.snap(move.newStart + clampShift)))
        }

        for (t, entries) in byTrack {
            touched.insert(t)
            let sorted = entries.sorted { $0.1 < $1.1 }
            if isMagnetic(t, timeline, context: context) {
                let target = sorted.first?.1 ?? 0
                insertIntoMagnetic(sorted.map { $0.0 }, at: target, track: t, in: &timeline, context: context)
            } else {
                for entry in sorted {
                    var clip = entry.0
                    clip.start = TimeValue(seconds: entry.1)
                    carve(&timeline, track: t, from: entry.1, to: entry.1 + clip.duration.seconds,
                          excluding: movingIDs, context: context)
                    if originals[clip.id]?.track != t { clip.transitionIn = nil }
                    timeline.tracks[t].clips.append(clip)
                }
            }
        }
        finalize(&timeline, tracks: touched, context: context)
    }

    /// Nudges clips by whole frames on their own tracks (overwrite semantics).
    static func nudge(_ ids: Set<UUID>, frames: Int, in timeline: inout Timeline, context: EditContext) throws {
        let delta = Double(frames) * context.frame
        var moves: [ClipMove] = []
        for id in ids {
            guard let ref = locate(id, in: timeline) else { continue }
            let clip = timeline.tracks[ref.track].clips[ref.index]
            moves.append(ClipMove(clipID: id, newStart: clip.start.seconds + delta, destination: .existing(ref.track)))
        }
        try move(moves, in: &timeline, context: context)
    }

    // MARK: Delete

    static func delete(_ ids: Set<UUID>, ripple: Bool, in timeline: inout Timeline, context: EditContext) throws {
        guard !ids.isEmpty else { throw TimelineEditError.nothingSelected }
        var touched: Set<Int> = []
        for t in timeline.tracks.indices {
            let removed = timeline.tracks[t].clips.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
            timeline.tracks[t].clips.removeAll { ids.contains($0.id) }
            touched.insert(t)
            guard ripple, !isMagnetic(t, timeline, context: context) else { continue }
            // Merge removed ranges, then close only the gaps the deletion created (last first).
            var ranges: [(Double, Double)] = []
            for clip in removed.sorted(by: { $0.start < $1.start }) {
                let s = clip.start.seconds, e = clip.end.seconds
                if let last = ranges.last, s <= last.1 + context.tolerance {
                    ranges[ranges.count - 1].1 = max(last.1, e)
                } else {
                    ranges.append((s, e))
                }
            }
            for range in ranges.reversed() {
                let coveredBefore = timeline.tracks[t].clips
                    .filter { $0.start.seconds < range.0 + context.tolerance }
                    .map(\.end.seconds).max() ?? range.0
                let gapStart = max(range.0, min(coveredBefore, range.1))
                let gap = range.1 - gapStart
                if gap > context.tolerance {
                    shiftClips(&timeline, track: t, startingAt: range.1, by: -gap, context: context)
                }
            }
        }
        finalize(&timeline, tracks: touched, context: context)
    }

    // MARK: Duplicate / paste

    @discardableResult
    static func duplicate(_ ids: Set<UUID>, in timeline: inout Timeline, context: EditContext) throws -> [UUID] {
        guard !ids.isEmpty else { throw TimelineEditError.nothingSelected }
        var created: [UUID] = []
        var touched: Set<Int> = []
        for t in timeline.tracks.indices {
            let selected = timeline.tracks[t].clips.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
            guard let first = selected.first, let lastEnd = selected.map(\.end.seconds).max() else { continue }
            guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
            let span = lastEnd - first.start.seconds
            var copies: [Clip] = []
            for (index, clip) in selected.enumerated() {
                var copy = clip
                copy.id = UUID()
                copy.start = TimeValue(seconds: clip.start.seconds + span)
                if index == 0 { copy.transitionIn = nil }
                copies.append(copy)
                created.append(copy.id)
            }
            if isMagnetic(t, timeline, context: context) {
                insertIntoMagnetic(copies, at: lastEnd, track: t, in: &timeline, context: context)
            } else {
                shiftClips(&timeline, track: t, startingAt: lastEnd, by: span, context: context)
                timeline.tracks[t].clips += copies
            }
            touched.insert(t)
        }
        finalize(&timeline, tracks: touched, context: context)
        return created
    }

    /// Pastes clipboard items at `time`. Items keep their relative offsets and track-class order.
    @discardableResult
    static func paste(_ items: [ClipboardItem], at time: Double, anchorTrack: Int?,
                      in timeline: inout Timeline, context: EditContext) throws -> [UUID] {
        guard !items.isEmpty else { return [] }
        var created: [UUID] = []
        var touched: Set<Int> = []
        for item in items.sorted(by: { $0.timeOffset < $1.timeOffset }) {
            var clip = item.clip
            clip.id = UUID()
            clip.transitionIn = nil
            let start = context.snap(time + item.timeOffset)
            let end = start + clip.duration.seconds
            let track: Int
            if let anchorTrack, timeline.tracks.indices.contains(anchorTrack),
               timeline.tracks[anchorTrack].kind.accepts(clip.source), item.trackOffset == 0,
               !timeline.tracks[anchorTrack].isLocked {
                track = anchorTrack
            } else if let original = timeline.tracks.firstIndex(where: { $0.kind == item.trackKind && !$0.isLocked
                                                                         && $0.kind.accepts(clip.source) }),
                      item.trackOffset == 0 {
                track = original
            } else {
                let kind = item.trackKind.accepts(clip.source) ? item.trackKind : item.trackKind.newTrackKindForMovedClips
                track = freeTrack(kind, start: start, end: end, in: &timeline, context: context)
            }
            let mode: PlacementMode = isMagnetic(track, timeline, context: context) ? .insert : .overwrite
            created += try place([clip], onTrack: track, at: start, mode: mode, in: &timeline, context: context)
            touched.insert(track)
        }
        finalize(&timeline, tracks: touched, context: context)
        return created
    }

    // MARK: Replace / join

    static func replace(_ id: UUID, with source: ClipSource, name: String, assetDuration: Double?,
                        in timeline: inout Timeline, context: EditContext) throws {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        guard timeline.tracks[ref.track].kind.accepts(source) else { throw TimelineEditError.incompatibleTrack }
        var clip = timeline.tracks[ref.track].clips[ref.index]
        let rate = max(SpeedSettings.minimumRate, clip.speed.rate)
        clip.source = source
        clip.name = name
        clip.speed.ramp = []
        clip.speed.isReversed = false
        clip.speed.reversedAssetID = nil
        if case .media = source, let assetDuration, assetDuration > 0 {
            let needed = clip.duration.seconds * rate
            let used = min(needed, assetDuration)
            clip.sourceRange = TimeRangeValue(startSeconds: 0, endSeconds: used)
            let newDuration = context.floorToFrame(used / rate)
            let shrink = clip.duration.seconds - newDuration
            clip.duration = TimeValue(seconds: max(context.frame, newDuration))
            clip.remapKeyframeTimes { min($0, newDuration) }
            timeline.tracks[ref.track].clips[ref.index] = clip
            if shrink > context.tolerance && isMagnetic(ref.track, timeline, context: context) {
                compact(&timeline, track: ref.track, context: context)
            }
        } else {
            clip.sourceRange = nil
            timeline.tracks[ref.track].clips[ref.index] = clip
        }
        finalize(&timeline, tracks: [ref.track], context: context)
    }

    static func canJoin(_ a: Clip, _ b: Clip, context: EditContext) -> Bool {
        guard abs(b.start.seconds - a.end.seconds) <= context.tolerance, b.transitionIn == nil else { return false }
        switch (a.source, b.source) {
        case (.media(let x), .media(let y)):
            guard x == y, let ra = a.sourceRange, let rb = b.sourceRange,
                  a.speed.ramp.isEmpty, b.speed.ramp.isEmpty,
                  abs(a.speed.rate - b.speed.rate) < 0.0001,
                  a.speed.isReversed == b.speed.isReversed else { return false }
            let sourceTolerance = context.frame * max(1, a.speed.rate)
            if a.speed.isReversed {
                return abs(rb.end.seconds - ra.start.seconds) <= sourceTolerance
            }
            return abs(ra.end.seconds - rb.start.seconds) <= sourceTolerance
        default:
            return a.source == b.source
        }
    }

    /// Joins two adjacent clips of the same source (inverse of split).
    static func join(_ firstID: UUID, _ secondID: UUID, in timeline: inout Timeline, context: EditContext) throws {
        guard let refA = locate(firstID, in: timeline), let refB = locate(secondID, in: timeline),
              refA.track == refB.track else { throw TimelineEditError.cannotJoin }
        guard !timeline.tracks[refA.track].isLocked else { throw TimelineEditError.trackLocked }
        var a = timeline.tracks[refA.track].clips[refA.index]
        var b = timeline.tracks[refB.track].clips[refB.index]
        if b.start < a.start { swap(&a, &b) }
        guard canJoin(a, b, context: context) else { throw TimelineEditError.cannotJoin }
        var merged = a.joiningKeyframes(with: b, offset: a.duration.seconds)
        merged.duration = a.duration + b.duration
        if let ra = a.sourceRange, let rb = b.sourceRange {
            merged.sourceRange = a.speed.isReversed
                ? TimeRangeValue(start: rb.start, end: ra.end)
                : TimeRangeValue(start: ra.start, end: rb.end)
        }
        merged.audio.fadeOut = b.audio.fadeOut
        let track = refA.track
        timeline.tracks[track].clips.removeAll { $0.id == a.id || $0.id == b.id }
        timeline.tracks[track].clips.append(merged)
        finalize(&timeline, tracks: [track], context: context)
    }

    /// The joinable neighbor pair for a selection (one clip → with its next clip; two clips → that pair).
    static func joinCandidate(for ids: Set<UUID>, in timeline: Timeline, context: EditContext) -> (UUID, UUID)? {
        if ids.count == 2 {
            let list = Array(ids)
            guard let a = clip(list[0], in: timeline), let b = clip(list[1], in: timeline) else { return nil }
            let ordered = a.start < b.start ? (a, b) : (b, a)
            return canJoin(ordered.0, ordered.1, context: context) ? (ordered.0.id, ordered.1.id) : nil
        }
        guard ids.count == 1, let id = ids.first, let ref = locate(id, in: timeline) else { return nil }
        let clips = timeline.tracks[ref.track].clips.sorted { $0.start < $1.start }
        guard let position = clips.firstIndex(where: { $0.id == id }) else { return nil }
        if position + 1 < clips.count, canJoin(clips[position], clips[position + 1], context: context) {
            return (clips[position].id, clips[position + 1].id)
        }
        if position > 0, canJoin(clips[position - 1], clips[position], context: context) {
            return (clips[position - 1].id, clips[position].id)
        }
        return nil
    }

    // MARK: Transitions

    /// Sets (or removes with `.none`) the transition into a clip from the previous clip on its track.
    /// Following clips on the track ripple so the clips overlap by exactly the transition duration.
    static func setTransition(_ kind: TransitionKind, duration: Double, forClip id: UUID,
                              in timeline: inout Timeline, context: EditContext) throws {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        let t = ref.track
        let sorted = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        guard let position = sorted.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.clipNotFound }
        guard position > 0 else {
            if kind == .none {
                if let index = timeline.tracks[t].clips.firstIndex(where: { $0.id == id }) {
                    timeline.tracks[t].clips[index].transitionIn = nil
                }
                return
            }
            throw TimelineEditError.noPreviousClip
        }
        let previous = sorted[position - 1]
        let clip = sorted[position]
        let limit = min(previous.duration.seconds, clip.duration.seconds) * 0.5
        let overlap = kind == .none ? 0 : min(max(context.snap(duration), context.frame), context.floorToFrame(limit))
        guard kind == .none || overlap >= context.frame - 1e-6 else { throw TimelineEditError.tooShort }
        let newStart = previous.end.seconds - overlap
        let delta = newStart - clip.start.seconds
        if abs(delta) > 1e-6 {
            shiftClips(&timeline, track: t, startingAt: clip.start.seconds, by: delta, context: context)
        }
        if let index = timeline.tracks[t].clips.firstIndex(where: { $0.id == id }) {
            timeline.tracks[t].clips[index].transitionIn = kind == .none ? nil
                : TransitionInstance(kind: kind, duration: TimeValue(seconds: overlap))
            if abs(delta) > 1e-6 { timeline.tracks[t].clips[index].start = TimeValue(seconds: newStart) }
        }
        finalize(&timeline, tracks: [t], context: context)
    }

    /// Applies one transition to every cut on a track.
    static func setTransitionForAllCuts(_ kind: TransitionKind, duration: Double, track t: Int,
                                        in timeline: inout Timeline, context: EditContext) throws {
        guard timeline.tracks.indices.contains(t) else { throw TimelineEditError.trackNotFound }
        let ids = timeline.tracks[t].clips.sorted { $0.start < $1.start }.dropFirst().map(\.id)
        for id in ids {
            do {
                try setTransition(kind, duration: duration, forClip: id, in: &timeline, context: context)
            } catch TimelineEditError.tooShort {
                continue
            }
        }
    }

    // MARK: Speed

    static func setSpeed(_ speed: SpeedSettings, forClip id: UUID, in timeline: inout Timeline, context: EditContext) throws {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        var clip = timeline.tracks[ref.track].clips[ref.index]
        guard clip.sourceRange != nil, clip.mediaAssetID != nil else { throw TimelineEditError.notMedia }
        let oldDuration = clip.duration.seconds
        let oldEnd = clip.end.seconds
        clip.speed = speed
        clip.recomputeDurationFromSpeed()
        clip.duration = TimeValue(seconds: max(context.frame, context.snap(clip.duration.seconds)))
        let factor = oldDuration > 0 ? clip.duration.seconds / oldDuration : 1
        if abs(factor - 1) > 1e-6 { clip.remapKeyframeTimes { $0 * factor } }
        clip.audio.fadeIn = min(clip.audio.fadeIn, clip.duration.seconds / 2)
        clip.audio.fadeOut = min(clip.audio.fadeOut, clip.duration.seconds / 2)
        timeline.tracks[ref.track].clips[ref.index] = clip
        let growth = clip.end.seconds - oldEnd
        if abs(growth) > 1e-6 && !isMagnetic(ref.track, timeline, context: context) {
            shiftClips(&timeline, track: ref.track, startingAt: oldEnd, by: growth, excluding: [id], context: context)
        }
        finalize(&timeline, tracks: [ref.track], context: context)
    }

    // MARK: Freeze frame

    /// Inserts a freeze frame of the clip's picture at `time`, rippling the rest of the track.
    @discardableResult
    static func insertFreezeFrame(of id: UUID, at time: Double, duration: Double,
                                  in timeline: inout Timeline, context: EditContext) throws -> UUID {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        let clip = timeline.tracks[ref.track].clips[ref.index]
        guard case .media(let assetID) = clip.source, timeline.tracks[ref.track].kind.isVisual else {
            throw TimelineEditError.notMedia
        }
        let t = ref.track
        let local = min(max(context.snap(time) - clip.start.seconds, 0), clip.duration.seconds - context.frame)
        var sourceTime = SpeedMapping.sourceTime(of: clip, local: local) ?? 0
        if let range = clip.sourceRange { sourceTime = min(sourceTime, range.end.seconds - context.frame) }
        let freezeDuration = max(context.frame, context.snap(duration))

        var insertAt = clip.start.seconds + local
        if local < context.frame {
            insertAt = clip.start.seconds
        } else if clip.duration.seconds - local <= context.frame {
            insertAt = clip.end.seconds
        } else {
            let pair = try split(clip, at: clip.start.seconds + local, context: context)
            timeline.tracks[t].clips[ref.index] = pair.0
            timeline.tracks[t].clips.append(pair.1)
            insertAt = pair.1.start.seconds
        }
        var freeze = clip.flattenedAnimation(at: local)
        freeze.id = UUID()
        freeze.name = clip.name + " — إطار ثابت"
        freeze.source = .freezeFrame(assetID: assetID, time: TimeValue(seconds: max(0, sourceTime)))
        freeze.sourceRange = nil
        freeze.speed = .normal
        freeze.start = TimeValue(seconds: insertAt)
        freeze.duration = TimeValue(seconds: freezeDuration)
        freeze.transitionIn = nil
        freeze.audio = ClipAudio()
        freeze.audio.isMuted = true
        if isMagnetic(t, timeline, context: context) {
            insertIntoMagnetic([freeze], at: insertAt, track: t, in: &timeline, context: context)
        } else {
            shiftClips(&timeline, track: t, startingAt: insertAt, by: freezeDuration, context: context)
            timeline.tracks[t].clips.append(freeze)
            finalize(&timeline, tracks: [t], context: context)
        }
        return freeze.id
    }

    // MARK: Audio detach

    @discardableResult
    static func detachAudio(of id: UUID, in timeline: inout Timeline, context: EditContext) throws -> UUID {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        let clip = timeline.tracks[ref.track].clips[ref.index]
        guard case .media = clip.source, clip.sourceRange != nil, timeline.tracks[ref.track].kind.isVisual else {
            throw TimelineEditError.notMedia
        }
        var audio = Clip(name: clip.name + " (صوت)", source: clip.source, start: clip.start,
                         duration: clip.duration, sourceRange: clip.sourceRange)
        audio.speed = clip.speed
        audio.audio = clip.audio
        audio.audio.isMuted = false
        audio.label = clip.label
        let track = freeTrack(.audio, start: clip.start.seconds, end: clip.end.seconds, in: &timeline, context: context)
        timeline.tracks[track].clips.append(audio)
        if let index = timeline.tracks[ref.track].clips.firstIndex(where: { $0.id == id }) {
            timeline.tracks[ref.track].clips[index].audio.isMuted = true
        }
        finalize(&timeline, tracks: [track, ref.track], context: context)
        return audio.id
    }

    // MARK: Generated layers

    /// Adds a generated layer (adjustment, solid, text…) on a free track of the right kind.
    @discardableResult
    static func insertGenerated(_ source: ClipSource, name: String, at time: Double, duration: Double,
                                in timeline: inout Timeline, context: EditContext) throws -> UUID {
        let start = context.snap(time)
        let length = max(context.frame, context.snap(duration))
        let kind: TrackKind
        switch source {
        case .adjustment: kind = .adjustment
        default: kind = .overlay
        }
        let track = freeTrack(kind, start: start, end: start + length, in: &timeline, context: context)
        let clip = Clip(name: name, source: source, start: TimeValue(seconds: start), duration: TimeValue(seconds: length))
        return try place([clip], onTrack: track, at: start, mode: .overwrite, in: &timeline, context: context).first ?? clip.id
    }

    // MARK: Nested sequences

    /// Builds a sub-timeline from the selection (re-based to 0) and returns its span.
    static func extractSubTimeline(_ ids: Set<UUID>, from timeline: Timeline) -> (timeline: Timeline, start: Double, end: Double)? {
        let selected = timeline.tracks.flatMap { $0.clips.filter { ids.contains($0.id) } }
        guard let start = selected.map(\.start.seconds).min(), let end = selected.map(\.end.seconds).max(), end > start else {
            return nil
        }
        var tracks: [Track] = []
        for track in timeline.tracks {
            let clips = track.clips.filter { ids.contains($0.id) }
            guard !clips.isEmpty else { continue }
            var copy = Track(kind: track.kind, name: track.name)
            copy.volume = track.volume
            copy.isMuted = track.isMuted
            copy.clips = clips.map { clip in
                var shifted = clip
                shifted.start = TimeValue(seconds: clip.start.seconds - start)
                return shifted
            }
            if let first = copy.clips.min(by: { $0.start < $1.start }), let index = copy.clips.firstIndex(where: { $0.id == first.id }) {
                copy.clips[index].transitionIn = nil
            }
            tracks.append(copy)
        }
        guard tracks.contains(where: { $0.kind.isVisual }) else { return nil }
        return (Timeline(tracks: tracks), start, end)
    }

    /// Replaces the selection with one clip placed at `start` on `track` (overwrite).
    @discardableResult
    static func replaceSelection(_ ids: Set<UUID>, with clip: Clip, onTrack track: Int, at start: Double,
                                 in timeline: inout Timeline, context: EditContext) throws -> UUID {
        var touched: Set<Int> = []
        for t in timeline.tracks.indices where timeline.tracks[t].clips.contains(where: { ids.contains($0.id) }) {
            guard !timeline.tracks[t].isLocked else { throw TimelineEditError.trackLocked }
            touched.insert(t)
        }
        let magneticTrack = primaryTrackIndex(timeline, context: context)
        let insertionIndex: Int? = {
            guard track == magneticTrack else { return nil }
            let ordered = timeline.tracks[track].clips.sorted { $0.start < $1.start }
            return ordered.firstIndex { ids.contains($0.id) }
        }()
        for t in touched { timeline.tracks[t].clips.removeAll { ids.contains($0.id) } }
        var placed = clip
        placed.start = TimeValue(seconds: start)
        placed.transitionIn = nil
        if track == magneticTrack, let insertionIndex {
            var ordered = timeline.tracks[track].clips.sorted { $0.start < $1.start }
            ordered.insert(placed, at: min(insertionIndex, ordered.count))
            timeline.tracks[track].clips = ordered
            compact(&timeline, track: track, context: context)
        } else {
            carve(&timeline, track: track, from: start, to: start + clip.duration.seconds, context: context)
            timeline.tracks[track].clips.append(placed)
        }
        touched.insert(track)
        for t in touched where t != magneticTrack { normalize(&timeline, track: t, context: context) }
        if let magneticTrack, touched.contains(magneticTrack) { compact(&timeline, track: magneticTrack, context: context) }
        return placed.id
    }

    /// Re-points every clip that plays `oldAsset` to `newAsset`, adapting to a new duration.
    static func repointCompound(from oldAsset: UUID, to newAsset: UUID, newDuration: Double,
                                in timeline: inout Timeline, context: EditContext) {
        var touched: Set<Int> = []
        for t in timeline.tracks.indices {
            for i in timeline.tracks[t].clips.indices {
                guard case .media(let id) = timeline.tracks[t].clips[i].source, id == oldAsset else { continue }
                var clip = timeline.tracks[t].clips[i]
                clip.source = .media(newAsset)
                if clip.speed.isReversed { clip.speed.isReversed = false; clip.speed.reversedAssetID = nil }
                let range = clip.sourceRange ?? TimeRangeValue(startSeconds: 0, endSeconds: newDuration)
                let start = min(range.start.seconds, max(0, newDuration - context.frame))
                let end = min(range.end.seconds, newDuration)
                let wasFull = (clip.sourceRange?.start.seconds ?? 0) < context.tolerance
                let newEnd = wasFull ? newDuration : max(start + context.frame, end)
                clip.sourceRange = TimeRangeValue(startSeconds: start, endSeconds: newEnd)
                clip.recomputeDurationFromSpeed()
                clip.duration = TimeValue(seconds: max(context.frame, context.snap(clip.duration.seconds)))
                timeline.tracks[t].clips[i] = clip
                touched.insert(t)
            }
        }
        for t in touched {
            if isMagnetic(t, timeline, context: context) { continue }
            // Prevent overlaps created by a longer render.
            let clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
            var adjusted: [Clip] = []
            for clip in clips {
                if let last = adjusted.last, clip.start.seconds < last.end.seconds - context.tolerance, clip.transitionIn == nil {
                    adjusted[adjusted.count - 1] = trimmedEnd(last, to: clip.start.seconds, context: context)
                }
                adjusted.append(clip)
            }
            timeline.tracks[t].clips = adjusted
        }
        finalize(&timeline, tracks: touched, context: context)
    }

    /// Breaks a compound instance back into its inner clips at the instance position.
    @discardableResult
    static func expandCompound(_ id: UUID, inner: Timeline, in timeline: inout Timeline, context: EditContext) throws -> [UUID] {
        guard let ref = locate(id, in: timeline) else { throw TimelineEditError.clipNotFound }
        guard !timeline.tracks[ref.track].isLocked else { throw TimelineEditError.trackLocked }
        let instance = timeline.tracks[ref.track].clips[ref.index]
        let offset = instance.start.seconds - (instance.sourceRange?.start.seconds ?? 0)
        let windowStart = instance.sourceRange?.start.seconds ?? 0
        let windowEnd = instance.sourceRange?.end.seconds ?? instance.duration.seconds
        timeline.tracks[ref.track].clips.remove(at: ref.index)
        if isMagnetic(ref.track, timeline, context: context) {
            shiftClips(&timeline, track: ref.track, startingAt: instance.start.seconds,
                       by: windowEnd - windowStart, context: context)
        }
        var created: [UUID] = []
        var touched: Set<Int> = [ref.track]
        for innerTrack in inner.tracks {
            var clips: [Clip] = []
            for clip in innerTrack.clips {
                guard clip.end.seconds > windowStart + context.tolerance, clip.start.seconds < windowEnd - context.tolerance else { continue }
                var piece = clip
                if piece.start.seconds < windowStart { piece = trimmedStart(piece, to: windowStart, context: context) }
                if piece.end.seconds > windowEnd { piece = trimmedEnd(piece, to: windowEnd, context: context) }
                piece.id = UUID()
                piece.start = TimeValue(seconds: piece.start.seconds + offset)
                clips.append(piece)
                created.append(piece.id)
            }
            guard let first = clips.map(\.start.seconds).min(), let last = clips.map(\.end.seconds).max() else { continue }
            let target: Int
            if innerTrack.kind == .video, timeline.tracks.indices.contains(ref.track),
               timeline.tracks[ref.track].kind == .video, !touched.contains(-1) {
                target = ref.track
                touched.insert(-1)
            } else {
                target = freeTrack(innerTrack.kind == .video ? .overlay : innerTrack.kind,
                                   start: first, end: last, in: &timeline, context: context)
            }
            if !isMagnetic(target, timeline, context: context) {
                carve(&timeline, track: target, from: first, to: last, context: context)
            }
            timeline.tracks[target].clips += clips
            touched.insert(target)
        }
        touched.remove(-1)
        finalize(&timeline, tracks: touched, context: context)
        return created
    }

    // MARK: Attributes

    /// Applies a change to many clips at once (multi-clip edits); locked tracks are skipped.
    static func updateClips(_ ids: Set<UUID>, in timeline: inout Timeline, _ change: (inout Clip) -> Void) {
        for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
            for i in timeline.tracks[t].clips.indices where ids.contains(timeline.tracks[t].clips[i].id) {
                change(&timeline.tracks[t].clips[i])
            }
        }
    }
}
