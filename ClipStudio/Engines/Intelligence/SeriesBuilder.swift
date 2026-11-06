//
//  SeriesBuilder.swift
//  ClipStudio — Engines/Intelligence (Part 6 suggestions)
//
//  Episode series: several videos → one project per video with the same look —
//  an intro card (series name + "الحلقة N"), the video, an optional outro card,
//  the same song under it (fitted to end on a bar), and the same editing style
//  (color, text style, still motion, music level). Pure: returns timelines; the
//  view creates the projects and can queue them all for export.
//

import Foundation

struct SeriesOptions: Hashable {
    var seriesName = ""
    /// "{n}" is replaced by the episode number.
    var episodeFormat = "الحلقة {n}"
    var startNumber = 1
    /// 0 = no intro card (the title is shown over the first seconds of the video instead).
    var introDuration: Double = 2.5
    var outroText = ""
    var outroDuration: Double = 2.5
    var musicVolume: Double = 0.25
    /// nil = whole video.
    var maximumDuration: Double?
    var transition: TransitionKind = .crossDissolve
}

enum SeriesBuilder {
    static func episodeLabel(_ options: SeriesOptions, index: Int) -> String {
        options.episodeFormat.replacingOccurrences(of: "{n}", with: String(options.startNumber + index))
    }

    /// Timeline of episode `index` for `video`.
    static func episode(video: MediaAsset, index: Int, options: SeriesOptions, style: EditingDNA?, music: MediaAsset?,
                        musicAnalysis: MusicAnalysis?, settings: ProjectSettings) throws -> Timeline {
        var durations: [UUID: Double] = [:]
        if let d = video.durationSeconds { durations[video.id] = d }
        if let music, let d = music.durationSeconds ?? musicAnalysis?.duration { durations[music.id] = d }
        let context = EditContext(assetDurations: durations, frameRate: Double(max(1, settings.frameRate)), magnetic: true)
        let label = episodeLabel(options, index: index)
        let name = options.seriesName.trimmingCharacters(in: .whitespacesAndNewlines)

        var video1: [Clip] = []
        var texts: [Clip] = []
        var cursor = 0.0
        let intro = context.snap(max(0, options.introDuration))
        if intro >= context.frame * 2 {
            video1.append(Clip(name: "مقدمة", source: .solidColor(RGBAColor(hex: 0x111216)), start: .zero,
                               duration: TimeValue(seconds: intro)))
            var content = TextContent(text: name.isEmpty ? label : name)
            content.subtitle = name.isEmpty ? "" : label
            content.design = name.isEmpty ? .plain : .banner
            content.style.weight = .heavy
            content.style.sizeRatio = 0.07
            var title = Clip(name: CaptionBuilder.shortName(content.text), source: .text(content), start: .zero,
                             duration: TimeValue(seconds: intro))
            title.transform.position = KeyframedValue(Vec2(x: 0.5, y: 0.5))
            texts.append(title)
            cursor = intro
        }
        let available = video.kind == .image ? 4 : (video.durationSeconds ?? 0)
        let length = context.floorToFrame(min(available, options.maximumDuration ?? available))
        guard length >= context.frame * 2 else { throw TimelineEditError.tooShort }
        var main: Clip
        if video.kind == .image {
            main = Clip(name: video.displayName, source: .image(video.id), start: TimeValue(seconds: cursor), duration: TimeValue(seconds: length))
        } else {
            main = Clip(name: video.displayName, source: .media(video.id), start: TimeValue(seconds: cursor), duration: TimeValue(seconds: length),
                        sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
        }
        main.fitMode = .fill
        video1.append(main)
        if intro < context.frame * 2 {
            // No intro card: lower title over the first seconds.
            var content = TextContent(text: name.isEmpty ? label : name)
            content.subtitle = name.isEmpty ? "" : label
            content.design = .lowerThird
            content.style.weight = .bold
            content.style.sizeRatio = 0.045
            var title = Clip(name: CaptionBuilder.shortName(content.text), source: .text(content), start: .zero,
                             duration: TimeValue(seconds: min(3.5, length)))
            title.transform.position = KeyframedValue(Vec2(x: 0.5, y: 0.8))
            texts.append(title)
        }
        cursor += length
        let outroText = options.outroText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outro = context.snap(max(0, options.outroDuration))
        if !outroText.isEmpty, outro >= context.frame * 2 {
            video1.append(Clip(name: "خاتمة", source: .solidColor(RGBAColor(hex: 0x111216)), start: TimeValue(seconds: cursor),
                               duration: TimeValue(seconds: outro)))
            var content = TextContent(text: outroText)
            content.style.weight = .bold
            content.style.sizeRatio = 0.06
            var title = Clip(name: CaptionBuilder.shortName(outroText), source: .text(content), start: TimeValue(seconds: cursor),
                             duration: TimeValue(seconds: outro))
            title.transform.position = KeyframedValue(Vec2(x: 0.5, y: 0.5))
            texts.append(title)
            cursor += outro
        }

        var tracks = [Track(kind: .video, name: "فيديو 1", clips: video1), Track(kind: .text, name: "نصوص", clips: texts)]
        if let music {
            let total = cursor
            let songLength = music.durationSeconds ?? musicAnalysis?.duration ?? total
            let musicLength = context.floorToFrame(min(total, songLength))
            if musicLength >= context.frame * 2 {
                var clip = Clip(name: music.displayName, source: .media(music.id), start: .zero, duration: TimeValue(seconds: musicLength),
                                sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: musicLength))
                clip.audio.volume = KeyframedValue(min(1, max(0, style?.musicVolume ?? options.musicVolume)))
                clip.audio.fadeOut = min(1.5, musicLength / 3)
                var pieces = [clip]
                if let musicAnalysis, songLength > total + 0.5,
                   let fitted = try? MusicFit.fit(clip, analysis: musicAnalysis, to: total, mode: .endOnBar, fadeOut: 1.5, context: context) {
                    pieces = fitted
                } else if let musicAnalysis, songLength < total - 0.5,
                          let looped = try? MusicFit.fit(clip, analysis: musicAnalysis, to: total, mode: .loop, fadeOut: 1.5, context: context) {
                    pieces = looped
                }
                tracks.append(Track(kind: .audio, name: "موسيقى", clips: pieces))
            }
        }
        var timeline = Timeline(tracks: tracks)
        TimelineEngine.finalize(&timeline, context: context)
        if options.transition != .none {
            let ids = timeline.tracks[0].clips.sorted { $0.start < $1.start }.map(\.id)
            for id in ids.dropFirst() {
                try? TimelineEngine.setTransition(options.transition, duration: 0.5, forClip: id, in: &timeline, context: context)
            }
        }
        if let style {
            var apply = DNAApplyOptions()
            apply.pacing = false
            apply.transitions = false
            apply.music = false
            try EditingDNAApplier.apply(style, options: apply, colorMatches: [:], beats: nil, to: &timeline, context: context)
        }
        return timeline
    }
}
