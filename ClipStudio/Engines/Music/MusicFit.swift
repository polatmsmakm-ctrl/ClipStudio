//
//  MusicFit.swift
//  ClipStudio — Engines/Music (Part 4 suggestions)
//
//  Makes a song end with the video, musically:
//  • endOnBar — the song stops on the last bar line before the video ends, with a fade;
//  • keepEnding — the beginning is cut on a bar line so the song's real ending lands
//    at the end of the video;
//  • loop — a song shorter than the video repeats whole bars (downbeat to downbeat)
//    until the video ends, then ends on a bar with a fade.
//  Pure functions: the result is a list of clips replacing the music clip.
//

import Foundation

enum MusicFitMode: String, CaseIterable, Identifiable, Hashable {
    case endOnBar, keepEnding, loop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endOnBar: "تنتهي على مازورة مع تلاشي"
        case .keepEnding: "الحفاظ على نهاية الأغنية"
        case .loop: "تكرار المازورات حتى النهاية"
        }
    }
}

enum MusicFitError: LocalizedError {
    case unsupportedSpeed
    case noBars

    var errorDescription: String? {
        switch self {
        case .unsupportedSpeed: "ملاءمة الموسيقى تحتاج مقطعًا بسرعته الطبيعية."
        case .noBars: "لم يُعثر على مازورات واضحة في هذه الموسيقى."
        }
    }
}

enum MusicFit {
    /// Bar lines (downbeats, or every 4th beat when there are none), source seconds.
    static func barLines(_ analysis: MusicAnalysis) -> [Double] {
        if analysis.downbeats.count >= 2 { return analysis.downbeats }
        return analysis.beats.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
    }

    /// Clips that replace `clip` so the music ends at timeline time `end`.
    static func fit(_ clip: Clip, analysis: MusicAnalysis, to end: Double, mode: MusicFitMode, fadeOut: Double,
                    context: EditContext) throws -> [Clip] {
        guard let range = clip.sourceRange, clip.speed.isNormal else { throw MusicFitError.unsupportedSpeed }
        let bars = barLines(analysis)
        guard bars.count >= 2 else { throw MusicFitError.noBars }
        let start = clip.start.seconds
        let target = max(context.frame, end - start)
        let sourceStart = range.start.seconds
        let songEnd = analysis.duration

        func make(_ base: Clip, from a: Double, to b: Double, at timelineStart: Double) -> Clip {
            var piece = base
            piece.sourceRange = TimeRangeValue(startSeconds: a, endSeconds: b)
            piece.start = TimeValue(seconds: context.snap(timelineStart))
            piece.duration = TimeValue(seconds: max(context.frame, context.floorToFrame(b - a)))
            piece.transitionIn = nil
            return piece
        }

        switch mode {
        case .endOnBar:
            let available = songEnd - sourceStart
            if available <= target {
                var whole = make(clip, from: sourceStart, to: songEnd, at: start)
                whole.audio.fadeOut = min(fadeOut, whole.duration.seconds / 2)
                return [whole]
            }
            let barEnd = bars.last { $0 > sourceStart + 1 && $0 - sourceStart <= target + context.tolerance } ?? (sourceStart + target)
            var piece = make(clip, from: sourceStart, to: barEnd, at: start)
            piece.audio.fadeOut = min(fadeOut, piece.duration.seconds / 2)
            return [piece]

        case .keepEnding:
            guard songEnd > target else {
                var whole = make(clip, from: 0, to: songEnd, at: start)
                whole.audio.fadeIn = min(clip.audio.fadeIn, whole.duration.seconds / 2)
                return [whole]
            }
            let idealStart = songEnd - target
            let barStart = bars.first { $0 >= idealStart - context.tolerance } ?? idealStart
            var piece = make(clip, from: barStart, to: songEnd, at: start)
            piece.audio.fadeIn = min(0.3, piece.duration.seconds / 4)
            piece.audio.fadeOut = 0
            return [piece]

        case .loop:
            let available = songEnd - sourceStart
            if available >= target {
                return try fit(clip, analysis: analysis, to: end, mode: .endOnBar, fadeOut: fadeOut, context: context)
            }
            // Loop body: from the first bar line after the start to the last bar line.
            guard let loopStart = bars.first(where: { $0 >= sourceStart }), let loopEnd = bars.last,
                  loopEnd - loopStart >= 1 else { throw MusicFitError.noBars }
            var pieces: [Clip] = []
            var first = make(clip, from: sourceStart, to: loopEnd, at: start)
            first.audio.fadeOut = 0
            pieces.append(first)
            var cursor = start + first.duration.seconds
            let finish = start + target
            while finish - cursor > context.frame * 2, pieces.count < 200 {
                let remaining = finish - cursor
                var copy = clip
                copy.id = UUID()
                copy.audio.fadeIn = 0
                copy.audio.fadeOut = 0
                if loopEnd - loopStart <= remaining + context.tolerance {
                    let piece = make(copy, from: loopStart, to: loopEnd, at: cursor)
                    pieces.append(piece)
                    cursor += piece.duration.seconds
                } else {
                    // Last repeat: end on a bar line inside the loop, with the fade.
                    let barEnd = bars.last { $0 > loopStart + 0.5 && $0 - loopStart <= remaining + context.tolerance }
                        ?? (loopStart + remaining)
                    var piece = make(copy, from: loopStart, to: barEnd, at: cursor)
                    piece.audio.fadeOut = min(fadeOut, piece.duration.seconds / 2)
                    pieces.append(piece)
                    cursor += piece.duration.seconds
                    break
                }
            }
            if pieces.count > 1, pieces[pieces.count - 1].audio.fadeOut == 0 {
                pieces[pieces.count - 1].audio.fadeOut = min(fadeOut, pieces[pieces.count - 1].duration.seconds / 2)
            }
            return pieces
        }
    }
}
