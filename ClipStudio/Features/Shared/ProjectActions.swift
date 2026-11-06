//
//  ProjectActions.swift
//  ClipStudio — Features/Shared
//
//  Creating, converting and opening projects from any screen.
//

import Foundation

@MainActor
enum ProjectActions {
    /// New Smart Stories project for one video. Returns the project id.
    static func newStory(asset: MediaAsset, env: AppEnvironment) -> UUID {
        let fps = Int((asset.frameRate ?? 30).rounded())
        let settings = ProjectSettings(canvasWidth: asset.pixelWidth ?? 1080, canvasHeight: asset.pixelHeight ?? 1920,
                                       frameRate: fps)
        let project = env.projects.create(kind: .story, name: asset.displayName, settings: settings) { project in
            var story = StoryConfig(sourceAssetID: asset.id)
            story.exportSettings = env.settings.defaultExport
            story.exportSettings.frameRate = .matchSource
            project.story = story
            project.coverAssetID = asset.id
        }
        return project.id
    }

    /// New Smart Merge project with the given clips in order.
    static func newMerge(assets: [MediaAsset], env: AppEnvironment) -> UUID {
        let project = env.projects.create(kind: .merge, name: "دمج " + Fmt.shortDate(Date())) { project in
            var merge = MergeConfig()
            merge.items = assets.filter { $0.kind != .audio }.map { MergeItem(assetID: $0.id) }
            if let music = assets.first(where: { $0.kind == .audio }) { merge.music = MusicSettings(assetID: music.id) }
            merge.exportSettings = env.settings.defaultExport
            project.merge = merge
            project.coverAssetID = merge.items.first?.assetID
        }
        return project.id
    }

    /// New Pro Studio project. Optional media is placed on the timeline in order
    /// (video/images on the primary track, audio on the template's music track).
    /// Part 3: project templates (organized, color-coded tracks), an optional opening
    /// title, and slideshow crossfades + motion.
    static func newPro(name: String, settings: ProjectSettings, assets: [MediaAsset], imageDuration: Double,
                       template: ProjectTemplate = .blank, openingTitle: String = "", env: AppEnvironment) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = env.projects.create(kind: .pro, name: trimmed.isEmpty ? "مشروع " + Fmt.shortDate(Date()) : trimmed,
                                          settings: settings) { project in
            project.timeline = template.makeTimeline()
            let fps = Double(settings.frameRate)
            func frames(_ seconds: Double) -> Double { max(1 / fps, (seconds * fps).rounded(.down) / fps) }
            let videoTrack = project.timeline.tracks.firstIndex { $0.kind == .video } ?? 0
            let audioTrack = template.audioTrackIndex(in: project.timeline)
            let slideDuration = template.addsSlideshowMotion ? max(imageDuration, 4) : imageDuration
            let fade = template.addsSlideshowMotion ? frames(0.8) : 0
            var videoCursor = TimeValue.zero
            var audioCursor = TimeValue.zero
            var visualIndex = 0
            for asset in assets {
                switch asset.kind {
                case .video:
                    guard let seconds = asset.durationSeconds, seconds > 0 else { continue }
                    let length = frames(seconds)
                    var clip = Clip(name: asset.displayName, source: .media(asset.id), start: videoCursor,
                                    duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
                    if fade > 0, visualIndex > 0, length > fade * 2 {
                        clip.transitionIn = TransitionInstance(kind: .crossDissolve, duration: TimeValue(seconds: fade))
                        clip.start = videoCursor - TimeValue(seconds: fade)
                    }
                    project.timeline.tracks[videoTrack].clips.append(clip)
                    videoCursor = clip.start + clip.duration
                    visualIndex += 1
                case .image:
                    var clip = Clip(name: asset.displayName, source: .image(asset.id), start: videoCursor,
                                    duration: TimeValue(seconds: frames(slideDuration)))
                    if template.addsSlideshowMotion {
                        clip.fitMode = .fill
                        let motion = MotionPreset.builtIns[visualIndex.isMultiple(of: 2) ? 0 : 1]
                        motion.apply(to: &clip, frame: 1 / fps)
                        if visualIndex > 0 {
                            clip.transitionIn = TransitionInstance(kind: .crossDissolve, duration: TimeValue(seconds: fade))
                            clip.start = videoCursor - TimeValue(seconds: fade)
                        }
                    }
                    project.timeline.tracks[videoTrack].clips.append(clip)
                    videoCursor = clip.start + clip.duration
                    visualIndex += 1
                case .audio:
                    guard let seconds = asset.durationSeconds, seconds > 0, let audioTrack else { continue }
                    let length = frames(seconds)
                    let clip = Clip(name: asset.displayName, source: .media(asset.id), start: audioCursor,
                                    duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
                    project.timeline.tracks[audioTrack].clips.append(clip)
                    audioCursor = audioCursor + clip.duration
                }
            }
            let title = openingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, let design = TitleTemplate.all.first {
                var textTrack = project.timeline.tracks.firstIndex { $0.kind == .text } ?? -1
                if textTrack < 0 {
                    var track = Track(kind: .text, name: "العناوين")
                    track.color = TitleTemplate.gold
                    project.timeline.tracks.append(track)
                    textTrack = project.timeline.tracks.count - 1
                }
                var clip = Clip(name: title, source: .text(design.content(text: title, subtitle: "")), start: .zero,
                                duration: TimeValue(seconds: frames(design.duration)))
                clip.transform.position = KeyframedValue(design.position(rightToLeft: ScriptDirection.isRightToLeft(title)))
                project.timeline.tracks[textTrack].clips.append(clip)
            }
            project.coverAssetID = assets.first { $0.kind != .audio }?.id
        }
        return project.id
    }

    /// Converts a Smart Stories or Smart Merge project into a new Pro Studio project
    /// (the original project is kept unchanged).
    static func convertToPro(_ summary: ProjectSummary, env: AppEnvironment) -> UUID? {
        guard let source = env.projects.load(summary.id) else { return nil }
        var assets: [UUID: MediaAsset] = [:]
        for id in source.referencedAssetIDs {
            if let asset = env.library.asset(id) { assets[id] = asset }
        }
        var timeline: Timeline
        var settings: ProjectSettings
        switch source.kind {
        case .pro:
            return nil
        case .merge:
            guard let config = source.merge, let built = try? MergeTimelineFactory.make(config: config, assets: assets) else { return nil }
            timeline = built.0
            settings = built.1
        case .story:
            guard let story = source.story, let asset = assets[story.sourceAssetID] else { return nil }
            settings = StoryTimelineFactory.canvas(for: asset, aspect: story.aspect, frameRate: Int((asset.frameRate ?? 30).rounded()))
            var video = Track(kind: .video, name: "فيديو 1")
            var cursor = TimeValue.zero
            for segment in story.segments where segment.isIncluded {
                var clip = Clip(name: segment.name.isEmpty ? asset.displayName : segment.name, source: .media(asset.id),
                                start: cursor, duration: segment.range.duration, sourceRange: segment.range)
                clip.fitMode = story.aspect == nil ? .fit : story.fitMode
                video.clips.append(clip)
                cursor = cursor + segment.range.duration
            }
            timeline = Timeline(tracks: [video, Track(kind: .audio, name: "صوت 1")])
        }
        if !timeline.tracks.contains(where: { $0.kind == .audio }) {
            timeline.tracks.append(Track(kind: .audio, name: "صوت 1"))
        }
        let project = env.projects.create(kind: .pro, name: source.name + " — مونتاج", settings: settings) { project in
            project.timeline = timeline
            project.coverAssetID = source.coverAssetID ?? summary.coverAssetID
        }
        return project.id
    }

    static func route(for summary: ProjectSummary) -> Route {
        switch summary.kind {
        case .story: .story(summary.id)
        case .merge: .merge(summary.id)
        case .pro: .studio(summary.id)
        }
    }
}
