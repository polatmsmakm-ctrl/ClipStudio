//
//  TimelineFactories.swift
//  ClipStudio — Engines/Stories
//
//  Builds render timelines for Smart Stories segments and Smart Merge, so both
//  workspaces export through the same GPU render pipeline as Pro Studio.
//

import Foundation
import CoreGraphics

enum StoryTimelineFactory {
    /// Canvas for a story export: target aspect (or source aspect) at the source's short side (≤ 2160).
    static func canvas(for source: MediaAsset, aspect: AspectRatio?, frameRate: Int) -> ProjectSettings {
        let sourceShort = min(source.pixelWidth ?? 1080, source.pixelHeight ?? 1920)
        let short = min(max(sourceShort, 360), 2160)
        if let aspect {
            return ProjectSettings(aspect: aspect, shortSide: short, frameRate: frameRate)
        }
        return ProjectSettings(canvasWidth: source.pixelWidth ?? 1080, canvasHeight: source.pixelHeight ?? 1920, frameRate: frameRate)
    }

    static func make(source: MediaAsset, segment: TimeRangeValue, aspect: AspectRatio?, fitMode: FitMode,
                     frameRate: Int) -> (Timeline, ProjectSettings) {
        let settings = canvas(for: source, aspect: aspect, frameRate: frameRate)
        var clip = Clip(name: source.displayName, source: .media(source.id), start: .zero,
                        duration: segment.duration, sourceRange: segment)
        clip.fitMode = aspect == nil ? .fit : fitMode
        var video = Track(kind: .video, name: "فيديو")
        video.clips = [clip]
        return (Timeline(tracks: [video]), settings)
    }
}

enum MergeTimelineFactory {
    enum FactoryError: LocalizedError {
        case noItems

        var errorDescription: String? { "أضف مقطعين على الأقل للدمج." }
    }

    /// Most common frame rate among the videos (rounded), default 30.
    static func automaticFrameRate(_ assets: [MediaAsset]) -> Int {
        let rates = assets.compactMap(\.frameRate).map { Int($0.rounded()) }.filter { $0 > 0 }
        guard !rates.isEmpty else { return 30 }
        let counts = Dictionary(grouping: rates, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key ?? 30
    }

    static func make(config: MergeConfig, assets: [UUID: MediaAsset]) throws -> (Timeline, ProjectSettings) {
        let resolved = config.items.compactMap { item -> (MergeItem, MediaAsset)? in
            guard let asset = assets[item.assetID], asset.kind != .audio else { return nil }
            return (item, asset)
        }
        guard !resolved.isEmpty else { throw FactoryError.noItems }

        let videoAssets = resolved.map(\.1).filter { $0.kind == .video }
        let fps = config.frameRate ?? automaticFrameRate(videoAssets)
        let firstAsset = resolved[0].1
        let aspect = config.aspect ?? firstAsset.aspect ?? .landscape16x9
        let largestShort = resolved.map { min($0.1.pixelWidth ?? 1080, $0.1.pixelHeight ?? 1080) }.max() ?? 1080
        var settings = ProjectSettings(aspect: aspect, shortSide: min(max(largestShort, 480), 2160), frameRate: fps)
        settings.backgroundColor = config.backgroundColor

        let transitionSeconds = config.transition == .none ? 0 : max(0.1, config.transitionDuration)
        var videoTrack = Track(kind: .video, name: "فيديو")
        var cursor = TimeValue.zero

        for (index, pair) in resolved.enumerated() {
            let (item, asset) = pair
            let range: TimeRangeValue?
            let length: TimeValue
            let source: ClipSource
            switch asset.kind {
            case .image:
                source = .image(asset.id)
                length = TimeValue(seconds: max(0.5, item.imageDuration))
                range = nil
            default:
                source = .media(asset.id)
                let full = TimeRangeValue(startSeconds: 0, endSeconds: asset.durationSeconds ?? 0)
                let trimmed = item.trim ?? full
                range = trimmed
                length = trimmed.duration
            }
            guard length.seconds > 0.05 else { continue }

            var clip = Clip(name: asset.displayName, source: source, start: cursor, duration: length, sourceRange: range)
            clip.fitMode = config.fitMode
            clip.audio.volume = KeyframedValue(config.originalAudioVolume)
            clip.audio.isMuted = config.muteOriginalAudio

            let overlap = index > 0 && transitionSeconds > 0
                ? min(transitionSeconds, length.seconds / 2, (videoTrack.clips.last?.duration.seconds ?? 0) / 2)
                : 0
            if overlap > 0 {
                clip.start = cursor - TimeValue(seconds: overlap)
                clip.transitionIn = TransitionInstance(kind: config.transition, duration: TimeValue(seconds: overlap))
                if config.crossfadeAudio {
                    clip.audio.fadeIn = overlap
                    if var previous = videoTrack.clips.popLast() {
                        previous.audio.fadeOut = overlap
                        videoTrack.clips.append(previous)
                    }
                }
            }
            videoTrack.clips.append(clip)
            cursor = clip.end
        }
        guard !videoTrack.clips.isEmpty else { throw FactoryError.noItems }

        var tracks = [videoTrack]
        if let music = config.music, let musicAsset = assets[music.assetID], let musicLength = musicAsset.durationSeconds, musicLength > 0.5 {
            tracks.append(musicTrack(music: music, musicLength: musicLength, total: cursor.seconds))
        }
        return (Timeline(tracks: tracks), settings)
    }

    /// Music laid under the whole merge, looping if requested, with global fades.
    static func musicTrack(music: MusicSettings, musicLength: Double, total: Double) -> Track {
        var track = Track(kind: .audio, name: "موسيقى")
        let offset = min(max(0, music.startOffset), max(0, musicLength - 0.5))
        var cursor = 0.0
        var first = true
        while cursor < total - 0.05 {
            let sourceStart = first ? offset : 0
            let available = musicLength - sourceStart
            let length = min(available, total - cursor)
            guard length > 0.05 else { break }
            var clip = Clip(name: "موسيقى", source: .media(music.assetID), start: TimeValue(seconds: cursor),
                            duration: TimeValue(seconds: length),
                            sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + length))
            clip.audio.volume = KeyframedValue(music.volume)
            if first { clip.audio.fadeIn = min(music.fadeIn, length / 2) }
            track.clips.append(clip)
            cursor += length
            first = false
            if !music.loop { break }
        }
        if var last = track.clips.popLast() {
            last.audio.fadeOut = min(music.fadeOut, last.duration.seconds / 2)
            track.clips.append(last)
        }
        return track
    }
}
