//
//  AIFeatureService.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  The AI tools that work from the library (no open editor):
//  • Storyboard — idea + media → editable scene list → a new project;
//  • Smart Highlights — best moments of a long video → reel or separate projects;
//  • Content Studio — titles / captions / hashtags per platform for a project;
//  • Style enrichment — a richer Editing DNA from a reference video.
//  Each builds the request (prompt, schema, media parts, on-device input), sends it
//  through AIRequestRouter and validates the answer. Media sent to the cloud is
//  only small frames or a compressed proxy, and only after the user agreed.
//

import Foundation
import CoreGraphics
import AVFoundation

@MainActor
enum AIFeatureService {
    private static var language: AIResponseLanguage { AISettings.shared.language }

    // MARK: Media context

    static func mediaReferences(_ assets: [MediaAsset]) -> [AIMediaReference] {
        assets.enumerated().map { index, asset in
            let transcript = TranscriptStore.transcripts(for: asset.id).first?.words.map(\.text).joined(separator: " ") ?? ""
            return AIMediaReference(ref: "m" + String(index + 1), assetID: asset.id, kind: asset.kind, name: asset.displayName,
                                    duration: asset.durationSeconds ?? 0,
                                    sceneCuts: AnalysisCache.loadTimes(asset.id, kind: "scenes") ?? [],
                                    transcript: transcript)
        }
    }

    /// Small labeled frames ("m2 @ 3.5s" + JPEG) for the model.
    static func frameParts(_ refs: [AIMediaReference], library: MediaLibrary, perVideo: Int, maxTotal: Int) async -> [AIPart] {
        var parts: [AIPart] = []
        var count = 0
        for ref in refs where count < maxTotal {
            guard let url = library.url(forID: ref.assetID) else { continue }
            switch ref.kind {
            case .image:
                if let data = AIMediaPreparer.image(url: url, maxDimension: 512) {
                    parts.append(.text(ref.ref + " (صورة)"))
                    parts.append(.inlineData(mimeType: "image/jpeg", data: data))
                    count += 1
                }
            case .video:
                let times = AIMediaPreparer.sampleTimes(duration: ref.duration, count: min(perVideo, maxTotal - count), cuts: ref.sceneCuts)
                for frame in await AIMediaPreparer.frames(url: url, times: times, maxDimension: 384) {
                    parts.append(.text(ref.ref + " @ " + String(format: "%.1f", frame.time) + "s"))
                    parts.append(.inlineData(mimeType: "image/jpeg", data: frame.jpeg))
                    count += 1
                }
            case .audio:
                continue
            }
        }
        return parts
    }

    static func frameCount(_ parts: [AIPart]) -> Int {
        parts.filter { if case .inlineData = $0 { return true }; return false }.count
    }

    /// What leaves the device, in words (shown before sending).
    static func uploadSummary(frames: Int, hasText: Bool, videoSeconds: Double?) -> String {
        var items: [String] = []
        if let videoSeconds {
            items.append("نسخة مضغوطة من الفيديو (حوالي 640 بكسل) مدتها " + Fmt.duration(videoSeconds) + " — تحذفها Google تلقائيًا خلال 48 ساعة")
        }
        if frames > 0 { items.append(Fmt.int(frames) + " صورة مصغرة من الوسائط") }
        if hasText { items.append("نصوص المشروع والكلام المفرغ") }
        return "سيتم إرسال ما يلي إلى Google Gemini باستخدام مفتاحك:\n• " + items.joined(separator: "\n• ")
            + "\nالملفات الأصلية لا تُرفع ولا تتغير."
    }

    // MARK: Storyboard

    static func storyboardRequest(idea: String, duration: Double, tone: String, refs: [AIMediaReference],
                                  frames: [AIPart]) -> AIRequest {
        let input = StoryboardInput(idea: idea, targetDuration: duration, media: refs, tone: tone)
        return AIRequest(task: .storyboard, systemInstruction: AIPromptManager.system(for: .storyboard, language: language),
                         messages: [AIMessage(role: .user, parts: [.text(AIPromptManager.storyboardPrompt(input))] + frames)],
                         responseSchema: AIPromptManager.storyboardSchema, temperature: 0.7,
                         localInput: .storyboard(input))
    }

    static func storyboard(_ request: AIRequest, refs: [AIMediaReference], duration: Double,
                           forceLocal: Bool) async throws -> (board: Storyboard, response: AIResponse) {
        let response = try await AIRequestRouter.shared.perform(request, forceLocal: forceLocal)
        let raw = try AIResponseValidator.decode(Storyboard.self, from: response.text)
        let board = AIResponseValidator.storyboard(raw, media: refs, targetDuration: duration)
        guard !board.scenes.isEmpty else { throw AIValidationError.empty }
        return (board: board, response: response)
    }

    /// Timeline (and markers) for an edited storyboard.
    nonisolated static func timeline(for board: Storyboard, refs: [AIMediaReference], settings: ProjectSettings)
        -> (timeline: Timeline, markers: [TimelineMarker]) {
        var durations: [UUID: Double] = [:]
        for ref in refs where ref.kind == .video { durations[ref.assetID] = ref.duration }
        let context = EditContext(assetDurations: durations, frameRate: Double(max(1, settings.frameRate)), magnetic: true)
        var video: [Clip] = []
        var texts: [Clip] = []
        var markers: [TimelineMarker] = []
        var cursor = 0.0
        for scene in board.scenes {
            let start = context.snap(cursor)
            var length = context.snap(max(0.5, scene.duration))
            var clip: Clip
            if let shot = scene.shot, let ref = refs.first(where: { $0.ref.lowercased() == shot.mediaRef.lowercased() }) {
                if ref.kind == .image {
                    clip = Clip(name: ref.name, source: .image(ref.assetID), start: TimeValue(seconds: start), duration: TimeValue(seconds: length))
                } else {
                    let end = min(ref.duration, max(shot.start + 0.3, shot.end))
                    length = context.snap(min(length, end - shot.start))
                    clip = Clip(name: ref.name, source: .media(ref.assetID), start: TimeValue(seconds: start),
                                duration: TimeValue(seconds: length),
                                sourceRange: TimeRangeValue(startSeconds: shot.start, endSeconds: shot.start + length))
                }
                clip.fitMode = .fill
            } else {
                clip = Clip(name: scene.purpose.title, source: .solidColor(RGBAColor(hex: 0x15171C)), start: TimeValue(seconds: start),
                            duration: TimeValue(seconds: length))
            }
            video.append(clip)
            if !scene.onScreenText.isEmpty {
                var content = TextContent(text: scene.onScreenText)
                content.style.weight = .heavy
                content.style.sizeRatio = scene.purpose == .hook ? 0.08 : 0.06
                var title = Clip(name: CaptionBuilder.shortName(scene.onScreenText), source: .text(content),
                                 start: TimeValue(seconds: start), duration: TimeValue(seconds: length))
                title.transform.position = KeyframedValue(Vec2(x: 0.5, y: scene.purpose == .hook ? 0.5 : 0.8))
                texts.append(title)
            }
            var label = scene.purpose.title + ": " + String(scene.description.prefix(40))
            if !scene.voiceover.isEmpty { label += " — تعليق: " + String(scene.voiceover.prefix(80)) }
            markers.append(TimelineMarker(time: TimeValue(seconds: start), name: label))
            cursor = start + length
        }
        var timeline = Timeline(tracks: [Track(kind: .video, name: "فيديو 1", clips: video),
                                         Track(kind: .text, name: "نصوص", clips: texts),
                                         Track(kind: .audio, name: "موسيقى", clips: [])])
        TimelineEngine.finalize(&timeline, context: context)
        return (timeline: timeline, markers: markers)
    }

    // MARK: Highlights

    static func highlightsRequest(asset: MediaAsset, url: URL, count: Int, length: Double, uploaded: UploadedAIFile?,
                                  library: MediaLibrary, progress: @escaping @Sendable (Double) -> Void) async -> AIRequest {
        var ref = mediaReferences([asset])[0]
        if ref.sceneCuts.isEmpty, let cuts = try? await SceneDetector.detect(url: url, progress: { progress($0 * 0.6) }) {
            ref.sceneCuts = cuts
            AnalysisCache.saveTimes(cuts, assetID: asset.id, kind: "scenes")
        }
        let audio = await AIMediaPreparer.loudness(url: url)
        progress(0.75)
        let input = HighlightsInput(media: ref, count: count, targetLength: length, sceneCuts: ref.sceneCuts,
                                    loudness: audio.levels, speech: audio.speech)
        var parts: [AIPart] = [.text(AIPromptManager.highlightsPrompt(input, framesOnly: uploaded == nil))]
        if let uploaded {
            parts.append(.fileData(mimeType: uploaded.mimeType, uri: uploaded.uri))
        } else if AISettings.shared.cloudAvailable {
            parts += await frameParts([ref], library: library, perVideo: min(40, max(8, Int(ref.duration / 4))), maxTotal: 40)
        }
        progress(0.9)
        return AIRequest(task: .highlights, systemInstruction: AIPromptManager.system(for: .highlights, language: language),
                         messages: [AIMessage(role: .user, parts: parts)], responseSchema: AIPromptManager.highlightsSchema,
                         temperature: 0.3, localInput: .highlights(input))
    }

    static func highlights(_ request: AIRequest, duration: Double, count: Int,
                           forceLocal: Bool) async throws -> (moments: [HighlightMoment], response: AIResponse) {
        let response = try await AIRequestRouter.shared.perform(request, forceLocal: forceLocal)
        let raw = try AIResponseValidator.decode(HighlightResult.self, from: response.text)
        let moments = AIResponseValidator.highlights(raw.highlights, duration: duration, count: count)
        guard !moments.isEmpty else { throw AIValidationError.empty }
        return (moments: moments, response: response)
    }

    /// One timeline with the chosen moments in order, joined by short dissolves.
    nonisolated static func reel(_ moments: [HighlightMoment], asset: MediaAsset, settings: ProjectSettings,
                                 withTitles: Bool) -> Timeline {
        let duration = asset.durationSeconds ?? 0
        let context = EditContext(assetDurations: [asset.id: duration], frameRate: Double(max(1, settings.frameRate)), magnetic: true)
        var clips: [Clip] = []
        var titles: [Clip] = []
        var cursor = 0.0
        for moment in moments.sorted(by: { $0.start < $1.start }) {
            let length = context.snap(moment.duration)
            guard length > context.frame * 2 else { continue }
            var clip = Clip(name: moment.title, source: .media(asset.id), start: TimeValue(seconds: cursor), duration: TimeValue(seconds: length),
                            sourceRange: TimeRangeValue(startSeconds: moment.start, endSeconds: moment.start + length))
            clip.fitMode = .fill
            clips.append(clip)
            if withTitles, !moment.title.isEmpty {
                var content = TextContent(text: moment.title)
                content.style.weight = .bold
                content.style.sizeRatio = 0.05
                var title = Clip(name: CaptionBuilder.shortName(moment.title), source: .text(content), start: TimeValue(seconds: cursor),
                                 duration: TimeValue(seconds: min(2.5, length)))
                title.transform.position = KeyframedValue(Vec2(x: 0.5, y: 0.85))
                titles.append(title)
            }
            cursor += length
        }
        var timeline = Timeline(tracks: [Track(kind: .video, name: "فيديو 1", clips: clips),
                                         Track(kind: .text, name: "نصوص", clips: titles)])
        TimelineEngine.finalize(&timeline, context: context)
        let ids = timeline.tracks[0].clips.sorted { $0.start < $1.start }.map(\.id)
        for id in ids.dropFirst() {
            try? TimelineEngine.setTransition(.crossDissolve, duration: 0.3, forClip: id, in: &timeline, context: context)
        }
        return timeline
    }

    // MARK: Content Studio

    /// Spoken words and on-screen texts of a project.
    nonisolated static func contentInput(project: EditProject, platforms: [SocialPlatform], tone: String, language: String) -> ContentInput {
        var spoken: [String] = []
        var onScreen: [String] = []
        var assets: [UUID] = []
        for track in project.timeline.tracks {
            for clip in track.clips {
                switch clip.source {
                case .text(let content):
                    if content.isCaption { spoken.append(content.caption?.composedText ?? content.text) } else { onScreen.append(content.text) }
                case .media(let id):
                    if !assets.contains(id) { assets.append(id) }
                default:
                    break
                }
            }
        }
        if spoken.isEmpty {
            for id in assets {
                if let transcript = TranscriptStore.transcripts(for: id).first {
                    spoken.append(transcript.words.map(\.text).joined(separator: " "))
                }
            }
        }
        return ContentInput(projectName: project.name, duration: project.timeline.duration.seconds,
                            spokenText: spoken.joined(separator: " "),
                            onScreenText: onScreen.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                            platforms: platforms, tone: tone, language: language)
    }

    static func contentRequest(_ input: ContentInput, frames: [AIPart]) -> AIRequest {
        AIRequest(task: .content, systemInstruction: AIPromptManager.system(for: .content, language: language),
                  messages: [AIMessage(role: .user, parts: [.text(AIPromptManager.contentPrompt(input))] + frames)],
                  responseSchema: AIPromptManager.contentSchema(platforms: input.platforms), temperature: 0.8,
                  localInput: .content(input))
    }

    static func content(_ request: AIRequest, platforms: [SocialPlatform], projectID: UUID,
                        forceLocal: Bool) async throws -> ContentPack {
        let response = try await AIRequestRouter.shared.perform(request, forceLocal: forceLocal)
        struct Raw: Decodable {
            var keywords: [String]?
            var posts: [PlatformPost]
        }
        let raw = try AIResponseValidator.decode(Raw.self, from: response.text)
        let posts = AIResponseValidator.posts(raw.posts, platforms: platforms)
        guard !posts.isEmpty else { throw AIValidationError.empty }
        let pack = ContentPack(projectID: projectID, createdAt: Date(), provider: response.provider,
                               keywords: Array((raw.keywords ?? []).prefix(15)), posts: posts)
        ContentStore.save(pack)
        return pack
    }

    /// A few frames of the project's picture clips (for Content Studio).
    static func projectFrames(_ project: EditProject, library: MediaLibrary, count: Int) async -> [AIPart] {
        var picture: [Clip] = []
        for track in project.timeline.tracks where track.kind.isVisual {
            picture += track.clips.filter { if case .media = $0.source { return true }; if case .image = $0.source { return true }; return false }
        }
        picture.sort { $0.start < $1.start }
        guard !picture.isEmpty else { return [] }
        let step = max(1, picture.count / max(1, count))
        var parts: [AIPart] = []
        for clip in stride(from: 0, to: picture.count, by: step).prefix(count).map({ picture[$0] }) {
            guard let id = clip.mediaAssetID, let url = library.url(forID: id) else { continue }
            if case .image = clip.source {
                if let data = AIMediaPreparer.image(url: url, maxDimension: 384) { parts.append(.inlineData(mimeType: "image/jpeg", data: data)) }
            } else if let range = clip.sourceRange,
                      let frame = await AIMediaPreparer.frames(url: url, times: [range.start.seconds + range.duration.seconds / 2],
                                                               maxDimension: 384).first {
                parts.append(.inlineData(mimeType: "image/jpeg", data: frame.jpeg))
            }
        }
        return parts
    }

    // MARK: Style enrichment

    static func enrich(_ dna: EditingDNA, referenceURL: URL) async throws -> EditingDNA {
        let duration = await AVURLAssetDuration.seconds(referenceURL)
        let times = AIMediaPreparer.sampleTimes(duration: duration, count: 8)
        let frames = await AIMediaPreparer.frames(url: referenceURL, times: times, maxDimension: 384)
        var parts: [AIPart] = [.text(AIPromptManager.enrichmentPrompt(dna))]
        for frame in frames { parts.append(.inlineData(mimeType: "image/jpeg", data: frame.jpeg)) }
        let request = AIRequest(task: .styleEnrichment, systemInstruction: AIPromptManager.system(for: .styleEnrichment, language: language),
                                messages: [AIMessage(role: .user, parts: parts)], responseSchema: AIPromptManager.enrichmentSchema,
                                temperature: 0.3)
        let response = try await AIRequestRouter.shared.perform(request)
        let enrichment = try AIResponseValidator.decode(StyleEnrichment.self, from: response.text)
        var result = dna
        AIResponseValidator.apply(enrichment, to: &result)
        return result
    }
}

/// Duration helper for a file URL.
enum AVURLAssetDuration {
    static func seconds(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let value = (try? await asset.load(.duration).seconds) ?? 0
        return value.isFinite ? value : 0
    }
}
