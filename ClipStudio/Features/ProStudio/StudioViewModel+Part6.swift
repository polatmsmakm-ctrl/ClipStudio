//
//  StudioViewModel+Part6.swift
//  ClipStudio — Features/ProStudio (Part 6 suggestions)
//
//  Studio commands behind the Part 6 tools: generated voiceover, caption
//  translation, music suggestions, automatic thumbnail, the hook check, smart
//  shortening and assistant plan history. Every change to the timeline is one
//  normal, undoable edit.
//

import Foundation
import SwiftUI
import UIKit

extension StudioViewModel {

    // MARK: Spoken words

    /// The caption language chosen in the captions / transcript tools.
    var transcriptLocaleID: String { UserDefaults.standard.string(forKey: "captions.locale") ?? "ar-SA" }

    /// Words already transcribed on the default speech tracks (no recognition is started).
    func spokenWords() -> [TimelineWord] {
        cachedTimelineWords(localeID: transcriptLocaleID, sourceTrackIDs: defaultCaptionSources())
    }

    // MARK: Generated voiceover

    /// Synthesizes `text` and places it on a voiceover track at `time`.
    func addGeneratedVoiceover(_ text: String, options: VoiceoverOptions, at time: Double) async throws {
        let url = try await SpeechSynthesis.synthesize(text, options: options)
        placeVoiceover(fileURL: url, at: time, duration: 0)
    }

    // MARK: Caption translation

    /// Adds a new captions track with `texts` (one per caption entry, same timing and style).
    func addTranslatedCaptions(entries: [CaptionEntry], texts: [String], target: TranslationTarget, hideOriginal: Bool) {
        guard entries.count == texts.count, !entries.isEmpty else { return }
        let originalTracks = Set(entries.map(\.trackIndex))
        _ = edit("ترجمة إلى " + target.title) { timeline, context in
            let index = TimelineEngine.addTrack(.subtitle, to: &timeline)
            timeline.tracks[index].name = "ترجمة — " + target.title
            timeline.tracks[index].color = RGBAColor(hex: 0x4FA3E5)
            for (entry, text) in zip(entries, texts) {
                var clip = entry.clip
                clip.id = UUID()
                clip.name = CaptionBuilder.shortName(text)
                guard case .text(var content) = clip.source else { continue }
                if var info = content.caption {
                    let length = max(0.1, clip.duration.seconds)
                    info.words = [CaptionWord(text: "", start: 0, end: length)]
                    info.retext(text, duration: length)
                    content.caption = info
                    content.text = info.composedText
                } else {
                    content.text = text
                }
                clip.source = .text(content)
                timeline.tracks[index].clips.append(clip)
            }
            if hideOriginal {
                for track in originalTracks where track < timeline.tracks.count && track != index { timeline.tracks[track].isHidden = true }
            }
            TimelineEngine.finalize(&timeline, tracks: [index], context: context)
        }
        env.toasts.show("أُضيفت ترجمة " + target.title + " على مسار جديد", style: .success)
    }

    // MARK: Music suggestions

    /// Puts a suggested song on a music track at the start and fits its ending to the picture.
    func addSuggestedMusic(_ suggestion: MusicSuggestion, fit: Bool) {
        let asset = suggestion.asset
        let duration = asset.durationSeconds ?? suggestion.analysis.duration
        let length = max(frameDuration, (min(duration, max(pictureEnd, frameDuration)) * frameRate).rounded(.down) / frameRate)
        var clip = Clip(name: asset.displayName, source: .media(asset.id), start: .zero, duration: TimeValue(seconds: length),
                        sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
        clip.audio.volume = KeyframedValue(0.6)
        clip.audio.fadeOut = min(1.5, length / 4)
        let preferred = timeline.tracks.firstIndex { $0.kind == .audio && $0.name.contains("موسيقى") }
        var placedID: UUID?
        _ = edit("موسيقى مقترحة: " + asset.displayName) { timeline, context in
            placedID = try TimelineEngine.insertLayer(clip, kind: .audio, at: 0, preferring: preferred, in: &timeline, context: context)
        }
        guard let placedID else { return }
        selection = [placedID]
        if fit, pictureEnd > 1 {
            let mode: MusicFitMode = duration + 0.5 < pictureEnd ? .loop : .endOnBar
            fitMusic(clipID: placedID, analysis: suggestion.analysis, mode: mode, fadeOut: 1.5)
        }
        env.toasts.show("أُضيفت الموسيقى", style: .success)
    }

    /// Mood for this project: from its editing pace, or its name.
    func suggestedMood() -> MusicMood {
        if let mood = MusicMood.detect(in: project.name) { return mood }
        let visual = timeline.tracks.first { $0.kind == .video }?.clips ?? []
        guard visual.count >= 2 else { return MusicMood.mood("happy")! }
        let average = visual.reduce(0) { $0 + $1.duration.seconds } / Double(visual.count)
        return MusicMood.fromPace(averageShotLength: average)
    }

    // MARK: Thumbnail

    func thumbnailCandidates(progress: @escaping (Double) -> Void) async throws -> [ThumbnailCandidate] {
        try await ThumbnailMaker.candidates(timeline: timeline, settings: project.settings, media: env.library.urlMap(),
                                            progress: progress)
    }

    /// Saved thumbnail text from Content Studio, or the project name.
    var defaultThumbnailText: String {
        if let pack = ContentStore.load(project.id), let text = pack.posts.first(where: { !$0.thumbnailText.isEmpty })?.thumbnailText {
            return text
        }
        return project.name
    }

    // MARK: Hook check

    func hookInput() -> HookInput {
        var firstText: (time: Double, text: String)?
        var firstPicture: Double?
        var hasMusicAtStart = false
        for track in timeline.tracks where !track.isHidden {
            for clip in track.clips where clip.isEnabled {
                switch clip.source {
                case .text(let content):
                    let text = content.caption?.composedText ?? content.text
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       clip.start.seconds < (firstText?.time ?? .greatestFiniteMagnitude) {
                        firstText = (time: clip.start.seconds, text: text)
                    }
                case .media(let id):
                    if let asset = env.library.asset(id) {
                        if asset.kind == .audio, track.carriesAudio, !track.isMuted, clip.start.seconds < 0.5 { hasMusicAtStart = true }
                        if asset.kind != .audio, track.kind.isVisual { firstPicture = min(firstPicture ?? .greatestFiniteMagnitude, clip.start.seconds) }
                    }
                case .image, .freezeFrame:
                    if track.kind.isVisual { firstPicture = min(firstPicture ?? .greatestFiniteMagnitude, clip.start.seconds) }
                default:
                    break
                }
            }
        }
        let words = spokenWords()
        let opening = words.filter { $0.start < 5 }.map(\.text).joined(separator: " ")
        let mainTrack = timeline.tracks.first { $0.kind == .video }
        let cuts = (mainTrack?.clips ?? []).map(\.start.seconds).filter { $0 > 0.05 && $0 <= 5 }.sorted()
        return HookInput(duration: duration, firstTextTime: firstText?.time, firstText: firstText?.text ?? "",
                         firstSpeechTime: words.first?.start, openingWords: opening, cutTimes: cuts,
                         openingLoudness: nil, restLoudness: nil, hasMusicAtStart: hasMusicAtStart,
                         blackOpening: firstPicture ?? 0)
    }

    /// Small JPEG frames of the opening (titles and color included) for Gemini.
    func hookFrames() async -> [AIPart] {
        let times = HookAnalyzer.frameTimes.filter { $0 < max(0.1, duration) }
        guard let frames = try? await ThumbnailMaker.frames(timeline: timeline, settings: project.settings, media: env.library.urlMap(),
                                                             times: times, maxShortSide: 480, progress: { _ in }) else { return [] }
        return frames.compactMap { frame in
            UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.7).map { AIPart.inlineData(mimeType: "image/jpeg", data: $0) }
        }
    }

    func applyHookSuggestion(_ suggestion: HookSuggestion) async {
        switch suggestion.action {
        case .addTitle:
            let step = AIPlanStep(operation: .addTitle(text: suggestion.titleText, start: 0, duration: min(3, max(1.5, duration)), placement: .center),
                                  summary: "عنوان البداية")
            _ = await applyPlan(AIPlan(explanation: "", steps: [step], warnings: []))
        case .trimStart:
            removeTimelineRanges([TimeSpan(start: 0, end: min(suggestion.trimTo, max(0, duration - 0.5)))], name: "حذف بداية بطيئة")
            env.toasts.show("حُذفت أول " + Fmt.seconds(suggestion.trimTo, digits: 1), style: .success)
        case .none:
            break
        }
    }

    // MARK: Smart shortening

    func shortenInput(target: Double) -> ShortenInput {
        ShortenInput(sentences: SmartShortener.sentences(from: spokenWords()), target: target, totalDuration: duration)
    }

    func applyShortening(keep: Set<Int>, sentences: [ShortenSentence], target: Double) {
        let removals = SmartShortener.removalSpans(keep: keep, sentences: sentences, totalDuration: duration)
        guard !removals.isEmpty else {
            env.toasts.show("لا يوجد ما يُحذف.", style: .info)
            return
        }
        removeTimelineRanges(removals, name: "اختصار إلى " + Fmt.seconds(target, digits: 0))
        env.toasts.show("صارت المدة " + Fmt.duration(duration), style: .success)
    }
}
