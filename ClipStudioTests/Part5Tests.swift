//
//  Part5Tests.swift
//  ClipStudioTests
//
//  Part 5 (AI layer) and the Part 4 suggestion pack:
//  • Gemini request building, response parsing, error mapping, model ranking;
//  • response validation (storyboards, highlights, posts, transcript, plans);
//  • the on-device provider (command parser, clean-up, highlights, content,
//    storyboard) and the plan executor;
//  • storyboard / highlight timelines, stable cache keys, span maths;
//  • face grouping, subject mask paths, horizon maths, music fit, beat auto-edit,
//    style sharing files and tracked-mask keyframes through splits.
//

import XCTest
import CoreGraphics
@testable import ClipStudio

final class Part5Tests: XCTestCase {
    private let asset = UUID()

    private func context(magnetic: Bool = true, durations: [UUID: Double]? = nil) -> EditContext {
        EditContext(assetDurations: durations ?? [asset: 100], frameRate: 30, magnetic: magnetic)
    }

    private func image(start: Double, duration: Double) -> Clip {
        Clip(name: "image", source: .image(UUID()), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration))
    }

    private func media(start: Double, duration: Double, sourceStart: Double = 0, assetID: UUID? = nil) -> Clip {
        Clip(name: "clip", source: .media(assetID ?? asset), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration),
             sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + duration))
    }

    private func call(_ name: String, _ args: [String: Any]) -> AIFunctionCall {
        AIFunctionCall(name: name, arguments: try! JSONSerialization.data(withJSONObject: args))
    }

    private func assistantContext(_ timeline: Timeline) -> AssistantContext {
        var clips: [AssistantContext.ClipRef] = []
        var number = 0
        for (t, track) in timeline.tracks.enumerated() {
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                number += 1
                clips.append(AssistantContext.ClipRef(ref: "c" + String(number), clipID: clip.id, trackRef: "t" + String(t + 1),
                                                      kind: "فيديو", name: clip.name, start: clip.start.seconds, end: clip.end.seconds,
                                                      text: nil, speed: 1, isPicture: track.kind.isVisual, onMainTrack: t == 0))
            }
        }
        return AssistantContext(clips: clips, tracks: [], duration: timeline.duration.seconds, playhead: 1,
                                selectedRefs: [], styleNames: ["سينمائي هادئ"], frameRate: 30)
    }

    // MARK: Gemini wire format

    func testRequestBodyHasSchemaToolsAndInlineData() throws {
        let request = AIRequest(task: .storyboard, systemInstruction: "sys",
                                messages: [AIMessage(role: .user, parts: [.text("hi"), .inlineData(mimeType: "image/jpeg", data: Data([1, 2, 3]))])],
                                responseSchema: ["type": "OBJECT"],
                                functions: [AIFunctionDeclaration(name: "split_at", description: "d", parameters: nil)],
                                temperature: 0.5)
        let body = GeminiClient.body(for: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "hi")
        let inline = try XCTUnwrap(parts.last?["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(generation["responseSchema"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertNil(declarations.first?["parameters"])
        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertTrue(request.containsMedia)
    }

    func testParseTextFunctionCallsAndUsage() throws {
        let functionCall: [String: Any] = ["name": "split_at", "args": ["time": 3.5]]
        let parts: [[String: Any]] = [["text": "مرحبا"], ["functionCall": functionCall]]
        let json: [String: Any] = [
            "candidates": [["content": ["parts": parts]]],
            "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5]
        ]
        let response = try GeminiClient.parse(JSONSerialization.data(withJSONObject: json), model: "m")
        XCTAssertEqual(response.text, "مرحبا")
        XCTAssertEqual(response.functionCalls.first?.name, "split_at")
        XCTAssertEqual(response.usage.totalTokens, 15)
        let blocked: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        XCTAssertThrowsError(try GeminiClient.parse(JSONSerialization.data(withJSONObject: blocked), model: "m"))
    }

    func testErrorMapping() throws {
        let rateError: [String: Any] = ["message": "Resource exhausted", "status": "RESOURCE_EXHAUSTED",
                                         "details": [["retryDelay": "30s"]]]
        let rate: [String: Any] = ["error": rateError]
        XCTAssertEqual(GeminiClient.error(status: 429, data: try JSONSerialization.data(withJSONObject: rate), headers: nil, model: "m"),
                       .rateLimited(retryAfter: 30))
        let key: [String: Any] = ["error": ["message": "API key not valid. Please pass a valid API key."]]
        XCTAssertEqual(GeminiClient.error(status: 400, data: try JSONSerialization.data(withJSONObject: key), headers: nil, model: "m"),
                       .invalidKey)
        XCTAssertEqual(GeminiClient.error(status: 404, data: Data(), headers: nil, model: "gemini-x"), .modelUnavailable("gemini-x"))
        XCTAssertTrue(GeminiError.offline.allowsLocalFallback)
        XCTAssertFalse(GeminiError.invalidKey.allowsLocalFallback)
    }

    func testModelRankingPrefersNewestStableFlash() {
        func model(_ id: String) -> GeminiModelInfo {
            GeminiModelInfo(id: id, displayName: id, inputTokenLimit: 0, outputTokenLimit: 0, methods: ["generateContent"])
        }
        let list = ["gemini-1.5-flash", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro",
                    "gemini-2.0-flash-exp", "gemini-2.5-flash-image-preview", "gemini-2.5-flash-preview-tts"].map(model)
        XCTAssertEqual(AIModelManager.bestFlash(list), "gemini-2.5-flash")
        XCTAssertFalse(AIModelManager.isTextModel("gemini-2.5-flash-image-preview"))
        XCTAssertFalse(AIModelManager.isTextModel("text-embedding-004"))
        XCTAssertEqual(AIModelManager.version("gemini-2.5-flash"), 2.5, accuracy: 1e-9)
        XCTAssertNil(AIModelManager.bestFlash([]))
    }

    func testStableCacheKeys() {
        var a = StableHasher(); a.add("abc")
        var b = StableHasher(); b.add("abc")
        XCTAssertEqual(a.hex, b.hex)
        let r1 = AIRequest(task: .content, systemInstruction: "s", messages: [AIMessage(role: .user, parts: [.text("one")])], responseSchema: nil)
        let r2 = AIRequest(task: .content, systemInstruction: "s", messages: [AIMessage(role: .user, parts: [.text("two")])], responseSchema: nil)
        XCTAssertNotEqual(r1.cacheKey(model: "m"), r2.cacheKey(model: "m"))
        XCTAssertEqual(r1.cacheKey(model: "m"), r1.cacheKey(model: "m"))
        XCTAssertNotEqual(r1.cacheKey(model: "m"), r1.cacheKey(model: "n"))
        XCTAssertFalse(r1.containsMedia)
    }

    // MARK: Validation

    func testExtractJSONFromFencedText() throws {
        let text = "إليك النتيجة:\n```json\n{\"highlights\": []}\n```"
        let data = try XCTUnwrap(AIResponseValidator.extractJSON(text))
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"highlights\": []}")
        XCTAssertNil(AIResponseValidator.extractJSON("no json"))
    }

    func testStoryboardValidationClampsShots() {
        let refs = [AIMediaReference(ref: "m1", assetID: asset, kind: .video, name: "v", duration: 10),
                    AIMediaReference(ref: "m2", assetID: UUID(), kind: .image, name: "p", duration: 0)]
        let raw = Storyboard(title: "", summary: "", musicMood: "", scenes: [
            StoryboardScene(purpose: .hook, description: "a", duration: 4, onScreenText: "", voiceover: "",
                            shot: StoryboardShot(mediaRef: "m1", start: 8, end: 20)),
            StoryboardScene(purpose: .main, description: "b", duration: 3, onScreenText: "", voiceover: "",
                            shot: StoryboardShot(mediaRef: "m9", start: 0, end: 3)),
            StoryboardScene(purpose: .main, description: "", duration: 3, onScreenText: "", voiceover: "", shot: nil),
            StoryboardScene(purpose: .outro, description: "c", duration: 200, onScreenText: "", voiceover: "",
                            shot: StoryboardShot(mediaRef: "M2", start: 0, end: 1))
        ])
        let board = AIResponseValidator.storyboard(raw, media: refs, targetDuration: 20)
        XCTAssertEqual(board.title, "قصة مصورة")
        XCTAssertEqual(board.scenes.count, 3)
        XCTAssertEqual(board.scenes[0].shot?.end ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(board.scenes[0].duration, 2, accuracy: 1e-9)
        XCTAssertNil(board.scenes[1].shot)
        XCTAssertEqual(board.scenes[2].duration, 60, accuracy: 1e-9)
        XCTAssertEqual(board.scenes[2].shot?.mediaRef, "m2")
    }

    func testHighlightValidationRemovesOverlaps() {
        let raw = [HighlightMoment(start: 0, end: 5, score: 60, title: "a", reason: ""),
                   HighlightMoment(start: 3, end: 8, score: 90, title: "b", reason: ""),
                   HighlightMoment(start: 20, end: 20.5, score: 99, title: "short", reason: ""),
                   HighlightMoment(start: 40, end: 70, score: 150, title: "", reason: "")]
        let kept = AIResponseValidator.highlights(raw, duration: 50, count: 5)
        XCTAssertEqual(kept.map(\.title), ["b", "لحظة مميزة"])
        XCTAssertEqual(kept.last?.end ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(kept.last?.score ?? 0, 100, accuracy: 1e-9)
    }

    func testPostsRespectPlatformLimits() {
        let raw = [PlatformPost(platform: .x, title: "عنوان", caption: String(repeating: "ك", count: 500),
                                hashtags: ["#سفر", "سفر", "رحلة جميلة", "a", "b", "c"], hook: "", thumbnailText: ""),
                   PlatformPost(platform: .youtube, title: "t", caption: "c", hashtags: [], hook: "", thumbnailText: "")]
        let posts = AIResponseValidator.posts(raw, platforms: [.x])
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.hashtags, ["سفر", "رحلة_جميلة", "a"])
        XCTAssertLessThanOrEqual(post.shareText.count, 300)
    }

    func testTranscriptValidationMergesAndBounds() {
        let raw = [TranscriptSuggestion(startWord: 2, endWord: 4, kind: .filler, reason: ""),
                   TranscriptSuggestion(startWord: 4, endWord: 6, kind: .repetition, reason: ""),
                   TranscriptSuggestion(startWord: 9, endWord: 30, kind: .offTopic, reason: "")]
        let valid = AIResponseValidator.transcript(raw, wordCount: 10)
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(valid[0].startWord, 2)
        XCTAssertEqual(valid[0].endWord, 6)
    }

    func testPlanValidation() {
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 2), image(start: 2, duration: 2),
                                                                      image(start: 4, duration: 2)])])
        let ctx = assistantContext(timeline)
        let plan = AIResponseValidator.plan(calls: [
            call("split_at", ["time": 99]),
            call("delete_clips", ["clips": ["c2", "c9"]]),
            call("add_transition", ["kind": "fadeBlack"]),
            call("set_speed", ["clip": "c1", "rate": 50]),
            call("teleport", [:]),
            call("apply_style", ["name": "سينمائي هادئ"])
        ], text: "تم", context: ctx, styles: EditingDNA.builtIns)
        XCTAssertEqual(plan.steps.count, 5)
        if case .split(let time) = plan.steps[0].operation { XCTAssertEqual(time, 6, accuracy: 1e-9) } else { XCTFail("split") }
        if case .delete(let ids, _) = plan.steps[1].operation { XCTAssertEqual(ids.count, 1) } else { XCTFail("delete") }
        if case .transition(let ids, let kind, _) = plan.steps[2].operation {
            XCTAssertEqual(ids.count, 2)
            XCTAssertEqual(kind, .fadeBlack)
        } else { XCTFail("transition") }
        if case .speed(_, let rate) = plan.steps[3].operation { XCTAssertEqual(rate, 8, accuracy: 1e-9) } else { XCTFail("speed") }
        XCTAssertTrue(plan.steps[1].isDestructive)
        XCTAssertEqual(plan.warnings.count, 2)
        XCTAssertEqual(plan.explanation, "تم")
    }

    // MARK: On-device provider

    func testLocalCommandParser() {
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 2), image(start: 2, duration: 2)])])
        let ctx = assistantContext(timeline)
        XCTAssertEqual(LocalCommandParser.latinDigits("المقطع ٢ عند ١٢٫٥"), "المقطع 2 عند 12.5")
        let delete = LocalCommandParser.parse("احذف المقطع ٢", context: ctx)
        XCTAssertEqual(delete.calls.first?.name, "delete_clips")
        let speed = LocalCommandParser.parse("سرّع المقطع 1 ×3", context: ctx)
        let plan = AIResponseValidator.plan(calls: speed.calls, text: "", context: ctx, styles: [])
        if case .speed(_, let rate) = plan.steps.first?.operation { XCTAssertEqual(rate, 3, accuracy: 1e-9) } else { XCTFail("speed") }
        let title = LocalCommandParser.parse("أضف عنوان «مرحبًا» فوق", context: ctx)
        let titlePlan = AIResponseValidator.plan(calls: title.calls, text: "", context: ctx, styles: [])
        if case .addTitle(let text, _, _, let placement) = titlePlan.steps.first?.operation {
            XCTAssertEqual(text, "مرحبًا")
            XCTAssertEqual(placement, .top)
        } else { XCTFail("title") }
        XCTAssertTrue(LocalCommandParser.parse("ما رأيك بالطقس؟", context: ctx).calls.isEmpty)
        XCTAssertEqual(LocalCommandParser.parse("احذف الصمت", context: ctx).calls.first?.name, "remove_silences")
    }

    func testLocalTranscriptCleanup() {
        let words = ["يعني", "أنا", "أنا", "رحت", "إلى", "البيت", "إلى", "البيت", "اليوم"]
        let gaps = [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 1.5, 0]
        let suggestions = LocalAIProvider.transcript(words: words, gaps: gaps)
        XCTAssertTrue(suggestions.contains { $0.kind == .filler && $0.startWord == 0 })
        XCTAssertTrue(suggestions.contains { $0.kind == .repetition && $0.startWord == 1 && $0.endWord == 1 })
        XCTAssertTrue(suggestions.contains { $0.kind == .repetition && $0.startWord == 4 && $0.endWord == 5 })
        XCTAssertTrue(suggestions.contains { $0.kind == .pause && $0.startWord == 7 })
    }

    func testLocalHighlightsPreferLoudPart() {
        var loudness = [Double](repeating: 0.1, count: 240)
        for i in 120..<160 { loudness[i] = 1 }
        let ref = AIMediaReference(ref: "m1", assetID: asset, kind: .video, name: "v", duration: 60)
        let input = HighlightsInput(media: ref, count: 1, targetLength: 8, sceneCuts: [], loudness: loudness, speech: [])
        let moments = LocalAIProvider.highlights(input)
        XCTAssertEqual(moments.count, 1)
        XCTAssertGreaterThanOrEqual(moments[0].start, 29)
        XCTAssertLessThanOrEqual(moments[0].end, 41)
    }

    func testLocalContentAndStoryboard() {
        let input = ContentInput(projectName: "رحلة جدة", duration: 30, spokenText: "زرنا الكورنيش في جدة. البحر جميل جدًا والكورنيش مزدحم.",
                                 onScreenText: ["جدة"], platforms: [.x, .instagram], tone: "حماسي", language: "العربية")
        let pack = LocalAIProvider.content(input)
        XCTAssertEqual(pack.posts.map(\.platform), [.x, .instagram])
        XCTAssertLessThanOrEqual(pack.posts[0].hashtags.count, SocialPlatform.x.hashtagLimit)
        XCTAssertFalse(pack.keywords.isEmpty)

        let refs = [AIMediaReference(ref: "m1", assetID: asset, kind: .video, name: "v", duration: 20),
                    AIMediaReference(ref: "m2", assetID: UUID(), kind: .image, name: "p", duration: 0)]
        let board = LocalAIProvider.storyboard(StoryboardInput(idea: "إعلان مقهى. قهوة مختصة", targetDuration: 10, media: refs, tone: "هادئ"))
        XCTAssertFalse(board.scenes.isEmpty)
        XCTAssertLessThanOrEqual(board.duration, 10.01)
        XCTAssertEqual(board.scenes.first?.purpose, .hook)
        XCTAssertEqual(board.title, "إعلان مقهى")
    }

    // MARK: Plan executor & timelines

    func testPlanExecutor() {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 4), image(start: 4, duration: 4)])])
        let ids = timeline.tracks[0].clips.sorted { $0.start < $1.start }.map(\.id)
        let steps = [
            AIPlanStep(operation: .split(time: 2), summary: "split"),
            AIPlanStep(operation: .color(clips: [ids[1]], exposure: 20, contrast: 0, saturation: 0, temperature: 0), summary: "color"),
            AIPlanStep(operation: .addTitle(text: "مرحبا", start: 1, duration: 2, placement: .top), summary: "title"),
            AIPlanStep(operation: .marker(time: 3, name: "هنا"), summary: "marker"),
            AIPlanStep(operation: .speed(clip: UUID(), rate: 2), summary: "missing"),
            AIPlanStep(operation: .normalizeAudio, summary: "deferred")
        ]
        let outcome = AIPlanExecutor.apply(steps, to: &timeline, styles: [:], context: context())
        XCTAssertEqual(outcome.applied, 4)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertEqual(outcome.markers.count, 1)
        XCTAssertEqual(timeline.tracks[0].clips.count, 3)
        XCTAssertEqual(TimelineEngine.clip(ids[1], in: timeline)?.color.exposure ?? 0, 20, accuracy: 1e-9)
        let text = timeline.tracks.first { $0.kind == .text }?.clips.first
        XCTAssertEqual(text?.transform.position.base.y ?? 0, 0.16, accuracy: 1e-9)
    }

    func testStoryboardTimeline() {
        let refs = [AIMediaReference(ref: "m1", assetID: asset, kind: .video, name: "v", duration: 20)]
        let board = Storyboard(title: "t", summary: "", musicMood: "", scenes: [
            StoryboardScene(purpose: .hook, description: "hook", duration: 3, onScreenText: "ابدأ", voiceover: "",
                            shot: StoryboardShot(mediaRef: "m1", start: 5, end: 8)),
            StoryboardScene(purpose: .main, description: "card", duration: 2, onScreenText: "", voiceover: "مرحبًا", shot: nil)
        ])
        let built = AIFeatureService.timeline(for: board, refs: refs, settings: ProjectSettings(aspect: .portrait9x16))
        let video = built.timeline.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(video.count, 2)
        XCTAssertEqual(video[0].sourceRange?.start.seconds ?? 0, 5, accuracy: 1e-6)
        XCTAssertEqual(video[1].start.seconds, 3, accuracy: 1e-6)
        if case .solidColor = video[1].source {} else { XCTFail("placeholder") }
        XCTAssertEqual(built.timeline.tracks[1].clips.count, 1)
        XCTAssertEqual(built.markers.count, 2)
        XCTAssertTrue(built.markers[1].name.contains("مرحبًا"))
    }

    func testHighlightReel() {
        let assetValue = MediaAsset(id: asset, kind: .video, displayName: "long", originalFilename: "a.mov", storedFileName: "a.mov",
                                    importedAt: Date(), fileSize: 1, durationSeconds: 100, pixelWidth: 1920, pixelHeight: 1080,
                                    frameRate: 30, videoCodec: nil, audioCodec: nil, hasAudio: true, estimatedBitrate: nil, fingerprint: "f")
        let moments = [HighlightMoment(start: 50, end: 55, score: 80, title: "b", reason: ""),
                       HighlightMoment(start: 10, end: 14, score: 90, title: "a", reason: "")]
        let timeline = AIFeatureService.reel(moments, asset: assetValue, settings: ProjectSettings(), withTitles: true)
        let clips = timeline.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].sourceRange?.start.seconds ?? 0, 10, accuracy: 1e-6)
        XCTAssertNotNil(clips[1].transitionIn)
        XCTAssertEqual(timeline.tracks[1].clips.count, 2)
    }

    func testSpanSubtraction() {
        let result = StudioViewModel.subtract([TimeSpan(start: 0, end: 10)], [TimeSpan(start: 2, end: 3), TimeSpan(start: 5, end: 12)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].end, 2, accuracy: 1e-9)
        XCTAssertEqual(result[1].start, 3, accuracy: 1e-9)
        XCTAssertEqual(result[1].end, 5, accuracy: 1e-9)
    }

    // MARK: Part 4 suggestions

    func testFaceGrouping() {
        func box(_ x: Double) -> RectValue { RectValue(x: x, y: 0.3, width: 0.1, height: 0.15) }
        var frames: [(time: Double, boxes: [RectValue])] = []
        for i in 0..<10 {
            let t = Double(i) * 0.125
            frames.append((time: t, boxes: [box(0.1 + Double(i) * 0.005), box(0.7 - Double(i) * 0.005)]))
        }
        frames.append((time: 1.3, boxes: [box(0.45)]))
        let tracks = FaceTracker.group(frames)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertTrue(tracks.allSatisfy { $0.count >= 10 })
        XCTAssertEqual(FaceTracker.iou(box(0.1), box(0.1)), 1, accuracy: 1e-9)
    }

    func testMaskPathFollowsSubjectThroughCrop() throws {
        var clip = media(start: 0, duration: 2)
        clip.crop = KeyframedValue(RectValue(x: 0.5, y: 0, width: 0.5, height: 1))
        let samples = stride(from: 0.0, to: 2, by: 0.125).map {
            SubjectSample(time: $0, rect: RectValue(x: 0.7, y: 0.4, width: 0.1, height: 0.2), confidence: 0.9)
        }
        let track = SubjectTrack(assetID: asset, mode: .faces, span: TimeSpan(start: 0, end: 2), samples: samples,
                                 sourceWidth: 1920, sourceHeight: 1080)
        let path = try XCTUnwrap(ReframeEngine.maskPath(track: track, clip: clip, smoothing: 0.2, padding: 2))
        XCTAssertEqual(path.center.value(at: 1).x, (0.75 - 0.5) / 0.5, accuracy: 1e-6)
        XCTAssertEqual(path.size.value(at: 1).x, 0.1 * 2 / 0.5, accuracy: 1e-6)

        var mask = MaskSettings()
        mask.centerTrack = path.center
        mask.sizeTrack = path.size
        clip.mask = mask
        XCTAssertEqual(mask.resolved(at: 1).center.x, 0.5, accuracy: 1e-6)
        let (left, right) = clip.splitKeyframes(at: 1)
        XCTAssertEqual(left.mask?.centerTrack?.value(at: 0.5).x ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(right.mask?.centerTrack?.value(at: 0.5).x ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertNil(clip.flattenedAnimation(at: 1).mask?.centerTrack)
    }

    func testHorizonMaths() {
        XCTAssertEqual(HorizonAnalyzer.coverScale(angle: 0, width: 1920, height: 1080), 1, accuracy: 1e-9)
        let scale = HorizonAnalyzer.coverScale(angle: 0.1, width: 1920, height: 1080)
        XCTAssertEqual(scale, (1920 * sin(0.1) + 1080 * cos(0.1)) / 1080, accuracy: 1e-9)
        let data = HorizonData(assetID: asset, times: [0, 0.25, 0.5, 0.75], angles: [0, 0.05, 0, 0.05], confidence: [0, 1, 0, 1])
        let smoothed = HorizonAnalyzer.smoothedAngles(data, smoothing: 0)
        XCTAssertEqual(smoothed, [0.05, 0.05, 0.05, 0.05])
    }

    func testClipDecodesWithoutHorizon() throws {
        var clip = media(start: 0, duration: 1)
        clip.horizon = HorizonSettings(assetID: asset)
        let data = try JSONStore.makeEncoder().encode(clip)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(try JSONStore.makeDecoder().decode(Clip.self, from: data).horizon)
        object.removeValue(forKey: "horizon")
        let decoded = try JSONStore.makeDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.horizon)
    }

    private var analysis: MusicAnalysis {
        let beats = stride(from: 0.0, to: 60, by: 0.5).map { $0 }
        let downbeats = stride(from: 0.0, to: 60, by: 2.0).map { $0 }
        return MusicAnalysis(assetID: asset, duration: 60, bpm: 120, beats: beats, downbeats: downbeats,
                             energy: [], energyRate: 10, sections: [], dropTime: nil)
    }

    func testMusicFitModes() throws {
        let music = media(start: 0, duration: 60)
        let endOnBar = try MusicFit.fit(music, analysis: analysis, to: 13, mode: .endOnBar, fadeOut: 1.5, context: context(magnetic: false))
        XCTAssertEqual(endOnBar.count, 1)
        XCTAssertEqual(endOnBar[0].duration.seconds, 12, accuracy: 1e-6)
        XCTAssertGreaterThan(endOnBar[0].audio.fadeOut, 0)

        let ending = try MusicFit.fit(music, analysis: analysis, to: 13, mode: .keepEnding, fadeOut: 1.5, context: context(magnetic: false))
        XCTAssertEqual(ending[0].sourceRange?.end.seconds ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(ending[0].sourceRange?.start.seconds ?? 0, 48, accuracy: 1e-6)

        var short = media(start: 0, duration: 10)
        short.sourceRange = TimeRangeValue(startSeconds: 0, endSeconds: 10)
        var shortAnalysis = analysis
        shortAnalysis.duration = 10
        shortAnalysis.beats = shortAnalysis.beats.filter { $0 <= 10 }
        shortAnalysis.downbeats = shortAnalysis.downbeats.filter { $0 <= 10 }
        let looped = try MusicFit.fit(short, analysis: shortAnalysis, to: 25, mode: .loop, fadeOut: 1, context: context(magnetic: false))
        XCTAssertGreaterThan(looped.count, 2)
        let total = looped.reduce(0) { $0 + $1.duration.seconds }
        XCTAssertLessThanOrEqual(total, 25 + 1e-6)
        XCTAssertGreaterThan(total, 20)
    }

    func testBeatAutoEdit() throws {
        XCTAssertEqual(AutoEditBuilder.beatsPerShot(averageShotLength: 1.2, bpm: 120), 2)
        XCTAssertEqual(AutoEditBuilder.beatsPerShot(averageShotLength: 4.5, bpm: 120), 8)
        func make(_ kind: MediaKind, _ duration: Double?) -> MediaAsset {
            MediaAsset(id: UUID(), kind: kind, displayName: "x", originalFilename: "x", storedFileName: "x", importedAt: Date(),
                       fileSize: 1, durationSeconds: duration, pixelWidth: 1080, pixelHeight: 1920, frameRate: 30, videoCodec: nil,
                       audioCodec: nil, hasAudio: kind != .image, estimatedBitrate: nil, fingerprint: UUID().uuidString)
        }
        let visuals = [make(.image, nil), make(.video, 10), make(.video, 0.4), make(.image, nil)]
        let music = make(.audio, 60)
        var musicAnalysis = analysis
        musicAnalysis.assetID = music.id
        var report = AutoEditReport()
        let timeline = try AutoEditBuilder.build(visuals: visuals, music: music, analysis: musicAnalysis, dna: EditingDNA.fastReels,
                                                 settings: ProjectSettings(aspect: .portrait9x16), keepClipAudio: false,
                                                 maximumDuration: nil, report: &report)
        XCTAssertEqual(report.shots, 4)
        XCTAssertEqual(report.slowed, 1)
        let video = timeline.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(video.count, 4)
        // Every cut (centre of any transition) lands on a beat.
        for clip in video.dropFirst() {
            let cut = clip.start.seconds + (clip.transitionIn?.duration.seconds ?? 0) / 2
            let nearest = musicAnalysis.beats.min { abs($0 - cut) < abs($1 - cut) } ?? 0
            XCTAssertEqual(cut, nearest, accuracy: 2.0 / 30 + 1e-6)
        }
        XCTAssertTrue(video.filter { if case .media = $0.source { return true }; return false }.allSatisfy(\.audio.isMuted))
        XCTAssertEqual(timeline.tracks.first { $0.kind == .audio }?.clips.count, 1)
    }

    func testStyleSharingRoundTrip() throws {
        let style = EditingDNA.calmCinematic
        let data = try JSONStore.makeEncoder().encode(SharedStyleFile(style: style))
        guard case .style(let imported) = try StyleSharing.decode(data) else { return XCTFail("style") }
        XCTAssertNotEqual(imported.id, style.id)
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertEqual(imported.name, style.name)

        let template = StudioTemplate(id: UUID(), name: "T", createdAt: Date(), settings: ProjectSettings(), timeline: Timeline(),
                                      markers: [], slots: [], note: "")
        let templateData = try JSONStore.makeEncoder().encode(SharedTemplateFile(template: template))
        guard case .template(let importedTemplate) = try StyleSharing.decode(templateData) else { return XCTFail("template") }
        XCTAssertNotEqual(importedTemplate.id, template.id)
        XCTAssertThrowsError(try StyleSharing.decode(Data("{\"kind\":\"other\"}".utf8)))
    }
}
