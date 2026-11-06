//
//  AutoEditBuilder.swift
//  ClipStudio — Engines/Music (Part 4 suggestions)
//
//  "Auto edit to the beat": photos + videos + a song + an editing style → a full
//  timeline. Shots last a whole number of beats chosen from the style's shot
//  length; every cut is on a beat (downbeat-aligned grid); videos use their middle
//  part, short videos get fewer beats (or are slowed to fill one beat); the song
//  ends on the last cut with a fade. Transitions are centred on the beat
//  (BeatSync) and the style's look / text / motion / music level are applied.
//  Pure: returns a Timeline.
//

import Foundation

struct AutoEditReport: Hashable {
    var shots = 0
    var beatsPerShot = 0
    var slowed = 0
    var unused = 0
    var duration: Double = 0
}

enum AutoEditBuilder {
    /// Beats per shot nearest (in log scale) to the style's shot length: 1, 2, 4, 8 or 16.
    static func beatsPerShot(averageShotLength: Double, bpm: Double) -> Int {
        guard bpm > 0 else { return 4 }
        let period = 60 / bpm
        let wanted = max(period, averageShotLength) / period
        return [1, 2, 4, 8, 16].min { abs(log(Double($0) / wanted)) < abs(log(Double($1) / wanted)) } ?? 4
    }

    /// Beat grid starting at the first downbeat (or the first beat).
    static func grid(_ analysis: MusicAnalysis) -> [Double] {
        let first = analysis.downbeats.first ?? analysis.beats.first ?? 0
        return analysis.beats.filter { $0 >= first - 1e-6 }
    }

    static func build(visuals: [MediaAsset], music: MediaAsset, analysis: MusicAnalysis, dna: EditingDNA,
                      settings: ProjectSettings, keepClipAudio: Bool, maximumDuration: Double?,
                      report: inout AutoEditReport) throws -> Timeline {
        let fps = Double(max(1, settings.frameRate))
        var durations: [UUID: Double] = [music.id: analysis.duration]
        for asset in visuals { if let d = asset.durationSeconds { durations[asset.id] = d } }
        let context = EditContext(assetDurations: durations, frameRate: fps, magnetic: true)
        let beats = grid(analysis)
        guard beats.count >= 2, !visuals.isEmpty else { throw MusicFitError.noBars }
        let period = 60 / max(1, analysis.bpm)
        let n = beatsPerShot(averageShotLength: dna.averageShotLength, bpm: analysis.bpm)
        report.beatsPerShot = n
        let limit = min(maximumDuration ?? .greatestFiniteMagnitude, analysis.duration)

        // Cut points on the timeline = beat times (music starts at source 0 at timeline 0).
        var shots: [Clip] = []
        var cursor = 0.0
        var beatIndex = 0
        // The first shot runs from 0 to the n-th beat of the grid.
        for asset in visuals {
            guard beatIndex < beats.count - 1 else { break }
            var steps = n
            var cut: Double { beats[min(beats.count - 1, beatIndex + steps)] }
            let available = asset.kind == .image ? Double.greatestFiniteMagnitude : (asset.durationSeconds ?? 0)
            // Fewer beats when the video is short.
            while steps > 1 && cut - cursor > available + context.tolerance { steps = max(1, steps / 2) }
            let end = cut
            guard end <= limit + context.tolerance, end - cursor >= context.frame * 2 else { break }
            let length = context.snap(end) - context.snap(cursor)
            var clip: Clip
            if asset.kind == .image {
                clip = Clip(name: asset.displayName, source: .image(asset.id), start: TimeValue(seconds: context.snap(cursor)),
                            duration: TimeValue(seconds: length))
                clip.fitMode = .fill
            } else if available + context.tolerance >= length {
                let sourceStart = max(0, (available - length) / 2)
                clip = Clip(name: asset.displayName, source: .media(asset.id), start: TimeValue(seconds: context.snap(cursor)),
                            duration: TimeValue(seconds: length),
                            sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + length))
                clip.fitMode = .fill
            } else {
                // Shorter than one beat step: slow it down to fill the shot.
                clip = Clip(name: asset.displayName, source: .media(asset.id), start: TimeValue(seconds: context.snap(cursor)),
                            duration: TimeValue(seconds: length),
                            sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: max(context.frame, available)))
                clip.speed.rate = max(0.25, max(context.frame, available) / length)
                clip.recomputeDurationFromSpeed()
                clip.duration = TimeValue(seconds: length)
                clip.fitMode = .fill
                report.slowed += 1
            }
            clip.audio.isMuted = !keepClipAudio
            shots.append(clip)
            cursor = end
            beatIndex = min(beats.count - 1, beatIndex + steps)
        }
        report.shots = shots.count
        report.unused = visuals.count - shots.count
        guard !shots.isEmpty else { throw MusicFitError.noBars }

        let total = cursor
        var musicClip = Clip(name: music.displayName, source: .media(music.id), start: .zero,
                             duration: TimeValue(seconds: context.snap(total)),
                             sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: context.snap(total)))
        musicClip.audio.fadeOut = min(1.5, max(period, total / 10))
        if let level = dna.musicVolume { musicClip.audio.volume = KeyframedValue(level) }

        var timeline = Timeline(tracks: [Track(kind: .video, name: "فيديو 1", clips: shots),
                                         Track(kind: .audio, name: "موسيقى", clips: [musicClip])])
        TimelineEngine.finalize(&timeline, context: context)

        // Beat-centred transitions from the style.
        let every: Int = dna.transitionRate >= 0.9 ? 1 : dna.transitionRate >= 0.45 ? 2 : dna.transitionRate >= 0.2 ? 4
            : dna.transitionRate > 0.01 ? 6 : 0
        if every > 0 {
            let mapped = BeatSync.timelineBeats(analysis, clip: musicClip)
            var options = BeatSyncOptions()
            options.grid = .nearest
            options.transitionEvery = every
            options.transitionKind = dna.transitionKind ?? .crossDissolve
            options.transitionDuration = min(dna.transitionDuration, period)
            try BeatSync.cutToBeats(track: 0, beats: mapped.beats, downbeats: mapped.downbeats, options: options,
                                    in: &timeline, context: context)
        }
        var options = DNAApplyOptions()
        options.pacing = false
        options.transitions = false
        options.colorStrength = 0.85
        try EditingDNAApplier.apply(dna, options: options, colorMatches: [:], beats: nil, to: &timeline, context: context)
        report.duration = timeline.duration.seconds
        return timeline
    }
}
