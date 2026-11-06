//
//  EditingDNAEngine.swift
//  ClipStudio — Engines/Intelligence (Part 4)
//
//  Editing DNA = a reusable editing style:
//  • EditingDNAAnalyzer learns it from a finished project (shot rhythm, transitions,
//    beat alignment, look, caption / title styles, motion on stills, music level);
//  • EditingDNAApplier applies it to another timeline — pacing (deterministic shot
//    lengths, optional beat sync), transitions, color (direct look or a match to the
//    DNA's reference frame through ColorMatcher), text styles, motion on stills and
//    the music level. Every step is optional and the whole apply is one undo step.
//

import Foundation
import CoreImage

// MARK: - Learn from a project

enum EditingDNAAnalyzer {
    static let voiceWords = ["تعليق", "حوار", "متحدث", "voice", "dialog"]
    static let musicWords = ["موسيقى", "music", "أغنية", "song"]

    /// Visual track that carries the edit rhythm: the first video track with clips.
    static func rhythmTrack(_ timeline: Timeline) -> Int? {
        if let first = timeline.tracks.firstIndex(where: { $0.kind == .video && !$0.clips.isEmpty }) { return first }
        return timeline.tracks.indices.filter { timeline.tracks[$0].kind.isVisual }
            .max { timeline.tracks[$0].clips.count < timeline.tracks[$1].clips.count }
    }

    static func extract(from project: EditProject, name: String) -> EditingDNA {
        let timeline = project.timeline
        var dna = EditingDNA(name: name, symbol: "dna", origin: "من مشروع «" + project.name + "»")
        dna.aspect = project.settings.aspect

        if let t = rhythmTrack(timeline) {
            let clips = timeline.tracks[t].clips.filter(\.isEnabled).sorted { $0.start < $1.start }
            let lengths = clips.map(\.duration.seconds).filter { $0 > 0 }
            if !lengths.isEmpty {
                let mean = lengths.reduce(0, +) / Double(lengths.count)
                let variance = lengths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lengths.count)
                dna.averageShotLength = (mean * 100).rounded() / 100
                dna.shotLengthSpread = mean > 0 ? min(1, sqrt(variance) / mean) : 0
            }
            let transitions = clips.compactMap(\.transitionIn).filter { $0.kind != .none }
            let cuts = max(0, clips.count - 1)
            if cuts > 0 {
                dna.transitionRate = min(1, Double(transitions.count) / Double(cuts))
            }
            if !transitions.isEmpty {
                var counts: [TransitionKind: Int] = [:]
                for transition in transitions { counts[transition.kind, default: 0] += 1 }
                dna.transitionKind = counts.max { $0.value < $1.value }?.key
                dna.transitionDuration = transitions.map(\.duration.seconds).reduce(0, +) / Double(transitions.count)
            }
            // Cuts on the beat of an analyzed music clip.
            let cutTimes = clips.dropFirst().map { clip -> Double in
                clip.start.seconds + (clip.transitionIn?.duration.seconds ?? 0) / 2
            }
            if cutTimes.count >= 3 {
                var beats: [Double] = []
                for track in timeline.tracks where track.kind == .audio {
                    for clip in track.clips {
                        guard let id = clip.mediaAssetID, let analysis = MusicAnalyzer.cached(assetID: id) else { continue }
                        beats += BeatSync.timelineBeats(analysis, clip: clip).beats
                    }
                }
                if !beats.isEmpty {
                    let onBeat = cutTimes.filter { cut in beats.contains { abs($0 - cut) <= 0.07 } }.count
                    dna.cutsOnBeat = Double(onBeat) / Double(cutTimes.count) >= 0.6
                }
            }
        }

        // Look: the most used non-neutral grade / LUT on visual clips.
        var gradeCounts: [ColorAdjustments: Int] = [:]
        var lutCounts: [UUID: (LUTReference, Int)] = [:]
        var stills = 0
        var animatedStills = 0
        for track in timeline.tracks where track.kind.isVisual {
            for clip in track.clips {
                switch clip.source {
                case .media, .image, .freezeFrame:
                    if !clip.color.isNeutral { gradeCounts[clip.color, default: 0] += 1 }
                    if let lut = clip.lut {
                        let entry = lutCounts[lut.lutID] ?? (lut, 0)
                        lutCounts[lut.lutID] = (entry.0, entry.1 + 1)
                    }
                    if case .image = clip.source {
                        stills += 1
                        if !clip.transform.scale.keyframes.isEmpty || !clip.transform.position.keyframes.isEmpty { animatedStills += 1 }
                    }
                case .text(let content):
                    if let caption = content.caption {
                        if dna.captionStyle == nil {
                            dna.captionStyle = content.style
                            dna.captionHighlight = caption.highlight
                            dna.captionHighlightColor = caption.highlightColor
                        }
                    } else if dna.titleStyle == nil {
                        dna.titleStyle = content.style
                    }
                default:
                    break
                }
            }
        }
        dna.color = gradeCounts.max { $0.value < $1.value }?.key
        dna.lut = lutCounts.values.max { $0.1 < $1.1 }?.0
        dna.stillMotion = stills > 0 && Double(animatedStills) / Double(stills) >= 0.5

        // Music level.
        var volumes: [Double] = []
        for track in timeline.tracks where track.kind == .audio {
            let lower = track.name.lowercased()
            guard !voiceWords.contains(where: { lower.contains($0) }) else { continue }
            let isMusic = musicWords.contains { lower.contains($0) }
                || track.clips.contains { $0.mediaAssetID.flatMap(MusicAnalyzer.cached(assetID:)) != nil }
            guard isMusic else { continue }
            volumes += track.clips.map { $0.audio.volume.base * track.volume }
        }
        if !volumes.isEmpty { dna.musicVolume = volumes.reduce(0, +) / Double(volumes.count) }
        return dna
    }
}

// MARK: - Apply

struct DNAApplyOptions: Hashable {
    var pacing = true
    var transitions = true
    var color = true
    /// 0…1 strength of the match to the reference frame.
    var colorStrength = 0.85
    var text = true
    var stillMotion = true
    var music = true
}

struct DNAApplyReport: Hashable {
    var retimed = 0
    var transitions = 0
    var graded = 0
    var restyled = 0
    var animated = 0
    var musicClips = 0
    var beatSynced = false

    var summary: String {
        var parts: [String] = []
        if retimed > 0 { parts.append("إيقاع " + Fmt.int(retimed) + " لقطة" + (beatSynced ? " على الإيقاع" : "")) }
        if transitions > 0 { parts.append(Fmt.int(transitions) + " انتقال") }
        if graded > 0 { parts.append("ألوان " + Fmt.int(graded)) }
        if restyled > 0 { parts.append("نصوص " + Fmt.int(restyled)) }
        if animated > 0 { parts.append("حركة " + Fmt.int(animated) + " صورة") }
        if musicClips > 0 { parts.append("مستوى الموسيقى") }
        return parts.isEmpty ? "لا يوجد ما يتغير" : parts.joined(separator: " • ")
    }
}

enum EditingDNAApplier {

    /// Deterministic value in −1…1 for shot `index` (same input = same edit).
    static func jitter(_ index: Int) -> Double {
        let x = sin(Double(index + 1) * 12.9898) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    /// Target length of each shot.
    static func shotLengths(_ dna: EditingDNA, count: Int, minimum: Double) -> [Double] {
        (0..<count).map { index in
            max(minimum, dna.averageShotLength * (1 + dna.shotLengthSpread * 0.8 * jitter(index)))
        }
    }

    /// Whether cut `index` (1-based among cuts) gets a transition for `rate`.
    static func cutGetsTransition(_ index: Int, rate: Double) -> Bool {
        guard rate > 0.01 else { return false }
        return Int((Double(index) * rate).rounded(.down)) > Int((Double(index - 1) * rate).rounded(.down))
    }

    /// Visual clips that carry a picture (color targets).
    static func pictureClips(_ timeline: Timeline) -> [Clip] {
        timeline.tracks.filter { $0.kind.isVisual && !$0.isLocked }.flatMap { track in
            track.clips.filter { clip in
                switch clip.source {
                case .media, .image, .freezeFrame: true
                default: false
                }
            }
        }
    }

    /// Grades that match every picture clip to the DNA reference frame (empty without one).
    static func matchColors(_ dna: EditingDNA, timeline: Timeline, media: MediaURLMap, canvas: CGSize, strength: Double,
                            control: RenderControl?, progress: @Sendable (Double) -> Void) async -> [UUID: ColorAdjustments] {
        guard let data = dna.referenceFrame, let reference = CIImage(data: data) else { return [:] }
        return await ColorMatchBatch.match(reference: reference, clips: pictureClips(timeline), media: media, canvas: canvas,
                                           strength: strength, control: control, progress: progress)
    }

    /// Applies the DNA to the timeline (pure apart from the precomputed color matches).
    @discardableResult
    static func apply(_ dna: EditingDNA, options: DNAApplyOptions, colorMatches: [UUID: ColorAdjustments],
                      beats: (beats: [Double], downbeats: [Double])?, to timeline: inout Timeline,
                      context: EditContext) throws -> DNAApplyReport {
        var report = DNAApplyReport()

        if let t = EditingDNAAnalyzer.rhythmTrack(timeline), !timeline.tracks[t].isLocked {
            // Pacing.
            if options.pacing {
                var clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
                let lengths = shotLengths(dna, count: clips.count, minimum: max(0.4, context.frame * 4))
                var cursor = clips.first?.start.seconds ?? 0
                for index in clips.indices {
                    var clip = clips[index]
                    clip.transitionIn = nil
                    let before = (clip.start, clip.duration)
                    clip.start = TimeValue(seconds: context.snap(cursor))
                    clip = TimelineEngine.trimmedEnd(clip, to: cursor + lengths[index], context: context)
                    if before.0 != clip.start || before.1 != clip.duration { report.retimed += 1 }
                    clips[index] = clip
                    cursor = clip.end.seconds
                }
                timeline.tracks[t].clips = clips
                TimelineEngine.finalize(&timeline, tracks: [t], context: context)
            }

            let kind = dna.transitionKind ?? .crossDissolve
            let every: Int = dna.transitionRate >= 0.9 ? 1 : dna.transitionRate >= 0.45 ? 2 : dna.transitionRate >= 0.2 ? 4
                : dna.transitionRate > 0.01 ? 6 : 0
            if dna.cutsOnBeat, let beats, beats.beats.count >= 2, options.pacing {
                var syncOptions = BeatSyncOptions()
                syncOptions.grid = .nearest
                syncOptions.transitionEvery = options.transitions ? every : 0
                syncOptions.transitionKind = kind
                syncOptions.transitionDuration = dna.transitionDuration
                let result = try BeatSync.cutToBeats(track: t, beats: beats.beats, downbeats: beats.downbeats,
                                                     options: syncOptions, in: &timeline, context: context)
                report.beatSynced = result.onBeat > 0
                report.transitions = result.transitions
                report.retimed = max(report.retimed, result.retimed)
            } else if options.transitions {
                let ids = timeline.tracks[t].clips.sorted { $0.start < $1.start }.map(\.id)
                // Start from hard cuts, then add the DNA's share of transitions.
                for id in ids.dropFirst() {
                    try? TimelineEngine.setTransition(.none, duration: 0, forClip: id, in: &timeline, context: context)
                }
                for (offset, id) in ids.dropFirst().enumerated() where cutGetsTransition(offset + 1, rate: dna.transitionRate) {
                    do {
                        try TimelineEngine.setTransition(kind, duration: dna.transitionDuration, forClip: id,
                                                         in: &timeline, context: context)
                        report.transitions += 1
                    } catch {
                        continue
                    }
                }
            }
        }

        // Look.
        if options.color {
            for t in timeline.tracks.indices where timeline.tracks[t].kind.isVisual && !timeline.tracks[t].isLocked {
                for c in timeline.tracks[t].clips.indices {
                    let clip = timeline.tracks[t].clips[c]
                    switch clip.source {
                    case .media, .image, .freezeFrame: break
                    default: continue
                    }
                    var changed = false
                    if let matched = colorMatches[clip.id] {
                        timeline.tracks[t].clips[c].color = matched
                        changed = true
                    } else if dna.referenceFrame == nil, let grade = dna.color {
                        timeline.tracks[t].clips[c].color = grade
                        changed = true
                    }
                    if let lut = dna.lut {
                        timeline.tracks[t].clips[c].lut = lut
                        changed = true
                    }
                    if changed { report.graded += 1 }
                }
            }
        }

        // Text styles.
        if options.text {
            for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
                for c in timeline.tracks[t].clips.indices {
                    guard case .text(var content) = timeline.tracks[t].clips[c].source else { continue }
                    if var caption = content.caption {
                        guard let style = dna.captionStyle else { continue }
                        content.style = style
                        if let highlight = dna.captionHighlight { caption.highlight = highlight }
                        if let color = dna.captionHighlightColor {
                            caption.highlightColor = color
                            caption.boxColor = color
                        }
                        content.caption = caption
                    } else {
                        guard let style = dna.titleStyle else { continue }
                        content.style = style
                    }
                    timeline.tracks[t].clips[c].source = .text(content)
                    report.restyled += 1
                }
            }
        }

        // Gentle motion on stills.
        if options.stillMotion, dna.stillMotion {
            let presets = Array(MotionPreset.builtIns.prefix(4))
            var index = 0
            for t in timeline.tracks.indices where timeline.tracks[t].kind.isVisual && !timeline.tracks[t].isLocked {
                for c in timeline.tracks[t].clips.indices {
                    let clip = timeline.tracks[t].clips[c]
                    guard case .image = clip.source, clip.transform.scale.keyframes.isEmpty,
                          clip.transform.position.keyframes.isEmpty, !presets.isEmpty else { continue }
                    presets[index % presets.count].apply(to: &timeline.tracks[t].clips[c], frame: context.frame)
                    index += 1
                    report.animated += 1
                }
            }
        }

        // Music level (clips with volume automation — e.g. ducking — are left alone).
        if options.music, let level = dna.musicVolume {
            for t in timeline.tracks.indices where timeline.tracks[t].kind == .audio && !timeline.tracks[t].isLocked {
                let lower = timeline.tracks[t].name.lowercased()
                guard !EditingDNAAnalyzer.voiceWords.contains(where: { lower.contains($0) }) else { continue }
                for c in timeline.tracks[t].clips.indices where timeline.tracks[t].clips[c].audio.volume.keyframes.isEmpty {
                    timeline.tracks[t].clips[c].audio.volume.base = min(1, max(0, level))
                    report.musicClips += 1
                }
            }
        }

        TimelineEngine.finalize(&timeline, context: context)
        return report
    }
}
