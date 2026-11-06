//
//  Part6Tests.swift
//  ClipStudioTests
//
//  Part 6 and the Part 5 suggestion pack (pure logic only — no network, no
//  rendering): smart shortening, hook check, caption translation batches,
//  assistant memory and plan history encoding, speech (chunks, WAV, Gemini TTS
//  wire format), music suggestions, thumbnail scoring, episode series, proxy
//  policy, the adaptive preview cap and VoiceOver clip descriptions.
//

import XCTest
@testable import ClipStudio

final class Part6Tests: XCTestCase {
    private let asset = UUID()

    private func context() -> EditContext {
        EditContext(assetDurations: [asset: 100], frameRate: 30, magnetic: true)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimelineWord {
        TimelineWord(text: text, start: start, end: end, confidence: 1, clipID: UUID())
    }

    private func sentence(_ index: Int, _ text: String, _ start: Double, _ end: Double) -> ShortenSentence {
        ShortenSentence(index: index, text: text, start: start, end: end)
    }

    private func makeAsset(kind: MediaKind, duration: Double?, width: Int = 1920, height: Int = 1080, fps: Double = 30,
                           bitrate: Double? = 10_000_000, codec: String? = "avc1") -> MediaAsset {
        MediaAsset(id: UUID(), kind: kind, displayName: "asset", originalFilename: "a.mov", storedFileName: "a.mov", importedAt: Date(),
                   fileSize: 1, durationSeconds: duration, pixelWidth: width, pixelHeight: height, frameRate: fps, videoCodec: codec,
                   audioCodec: nil, hasAudio: kind != .image, estimatedBitrate: bitrate, fingerprint: UUID().uuidString)
    }

    private func analysis(_ id: UUID, duration: Double, bpm: Double = 120, energy: [Double] = [0.5]) -> MusicAnalysis {
        let period = 60 / bpm
        let beats = stride(from: 0.0, to: duration, by: period).map { $0 }
        let downbeats = stride(from: 0.0, to: duration, by: period * 4).map { $0 }
        return MusicAnalysis(assetID: id, duration: duration, bpm: bpm, beats: beats, downbeats: downbeats,
                             energy: energy, energyRate: 10, sections: [], dropTime: nil)
    }

    private func assistantContext(_ timeline: Timeline, preferred: TransitionKind?) -> AssistantContext {
        var clips: [AssistantContext.ClipRef] = []
        var number = 0
        for (t, track) in timeline.tracks.enumerated() {
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                number += 1
                clips.append(AssistantContext.ClipRef(ref: "c" + String(number), clipID: clip.id, trackRef: "t" + String(t + 1),
                                                      kind: "فيديو", name: clip.name, start: clip.start.seconds, end: clip.end.seconds,
                                                      text: nil, speed: 1, isPicture: true, onMainTrack: t == 0))
            }
        }
        return AssistantContext(clips: clips, tracks: [], duration: timeline.duration.seconds, playhead: 0, selectedRefs: [],
                                styleNames: [], frameRate: 30, preferredTransition: preferred)
    }

    // MARK: Smart shortening

    func testSentencesSplitOnPunctuationAndPauses() {
        let words = [word("مرحبا", 0, 0.4), word("بكم.", 0.5, 0.9), word("اليوم", 1.0, 1.4), word("نتكلم", 1.5, 2.0),
                     word("عن", 3.0, 3.2), word("القهوة", 3.3, 3.8)]
        let result = SmartShortener.sentences(from: words)
        XCTAssertEqual(result.map(\.text), ["مرحبا بكم.", "اليوم نتكلم", "عن القهوة"])
        XCTAssertEqual(result.map(\.index), [0, 1, 2])
        XCTAssertEqual(result[2].start, 3.0, accuracy: 1e-9)
    }

    func testSelectFitsTargetAndKeepsOpening() {
        let texts = ["أهلا بكم في حلقة القهوة", "القهوة المختصة لها طرق تحضير", "الطقس اليوم جميل",
                     "تحضير القهوة بالترشيح سهل", "يعني يعني", "شكرا للمتابعة والقهوة"]
        let sentences = texts.enumerated().map { sentence($0.offset, $0.element, Double($0.offset) * 5, Double($0.offset) * 5 + 4) }
        let kept = SmartShortener.select(sentences, target: 13)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept.contains(0))
        XCTAssertFalse(kept.contains(4))
        let fitted = SmartShortener.fit(Set(0..<6), sentences: sentences, target: 8)
        XCTAssertEqual(fitted.count, 2)
        XCTAssertEqual(SmartShortener.select([], target: 10), [])
    }

    func testRemovalSpans() {
        let sentences = [sentence(0, "a", 1, 3), sentence(1, "b", 5, 6), sentence(2, "c", 8, 9.5)]
        let removals = SmartShortener.removalSpans(keep: [0, 2], sentences: sentences, totalDuration: 10, padding: 0.12)
        XCTAssertEqual(removals.count, 3)
        XCTAssertEqual(removals[0].end, 0.88, accuracy: 1e-9)
        XCTAssertEqual(removals[1].start, 3.12, accuracy: 1e-9)
        XCTAssertEqual(removals[1].end, 7.88, accuracy: 1e-9)
        XCTAssertEqual(removals[2].start, 9.62, accuracy: 1e-9)
        XCTAssertEqual(SmartShortener.resultingDuration(totalDuration: 10, removals: removals), 3.98, accuracy: 1e-9)
        XCTAssertTrue(SmartShortener.removalSpans(keep: [], sentences: sentences, totalDuration: 10).isEmpty)
    }

    // MARK: Hook check

    func testHookLocalScoring() {
        let weak = HookInput(duration: 20, firstTextTime: nil, firstText: "", firstSpeechTime: 3.2, openingWords: "مرحبا بكم في القناة",
                             cutTimes: [], openingLoudness: nil, restLoudness: nil, hasMusicAtStart: false, blackOpening: 0.5)
        let weakReport = HookAnalyzer.local(weak)
        XCTAssertEqual(weakReport.score, 15, accuracy: 1e-9)
        XCTAssertEqual(weakReport.problems.count, 4)
        XCTAssertTrue(weakReport.suggestions.contains { $0.action == .trimStart && abs($0.trimTo - 0.5) < 1e-9 })
        XCTAssertTrue(weakReport.suggestions.contains { $0.action == .addTitle && $0.titleText == "مرحبا بكم في القناة" })
        XCTAssertTrue(weakReport.suggestions.contains { $0.action == .trimStart && abs($0.trimTo - 2.9) < 1e-9 })

        let strong = HookInput(duration: 20, firstTextTime: 0.2, firstText: "وصفة سريعة", firstSpeechTime: 0.3, openingWords: "",
                               cutTimes: [1.2], openingLoudness: 0.8, restLoudness: 0.6, hasMusicAtStart: true, blackOpening: 0)
        let strongReport = HookAnalyzer.local(strong)
        XCTAssertEqual(strongReport.score, 100, accuracy: 1e-9)
        XCTAssertEqual(strongReport.grade, "قوي")
        XCTAssertTrue(strongReport.problems.isEmpty)
    }

    func testHookValidationClamps() throws {
        let input = HookInput(duration: 10, firstTextTime: nil, firstText: "", firstSpeechTime: nil, openingWords: "", cutTimes: [],
                              openingLoudness: nil, restLoudness: nil, hasMusicAtStart: false, blackOpening: 0)
        let raw = HookReport(score: 150, verdict: "", strengths: [], problems: ["x"],
                             suggestions: [HookSuggestion(text: "قص", action: .trimStart, trimTo: 20),
                                           HookSuggestion(text: "عنوان", action: .addTitle, titleText: "  "),
                                           HookSuggestion(text: "", action: .none)])
        let report = HookAnalyzer.validate(raw, input: input)
        XCTAssertEqual(report.score, 100, accuracy: 1e-9)
        XCTAssertFalse(report.verdict.isEmpty)
        XCTAssertEqual(report.suggestions.count, 2)
        XCTAssertEqual(report.suggestions[0].trimTo, 5, accuracy: 1e-9)
        XCTAssertEqual(report.suggestions[1].action, .none)

        let loose = try AIResponseValidator.decode(HookReport.self, from: "{\"score\": 70, \"suggestions\": [{\"text\": \"x\", \"action\": \"teleport\"}]}")
        XCTAssertEqual(loose.score, 70, accuracy: 1e-9)
        XCTAssertEqual(loose.suggestions.first?.action, HookAction.none)
        XCTAssertTrue(loose.strengths.isEmpty)
    }

    func testLocalProviderAnswersHookAndShorten() async throws {
        let input = HookInput(duration: 12, firstTextTime: 0.5, firstText: "مرحبا", firstSpeechTime: 0.2, openingWords: "مرحبا",
                              cutTimes: [], openingLoudness: nil, restLoudness: nil, hasMusicAtStart: false, blackOpening: 0)
        let hookRequest = AIRequest(task: .hookCheck, systemInstruction: "", messages: [], responseSchema: nil, localInput: .hook(input))
        let hookResponse = try await LocalAIProvider().generate(hookRequest, model: "on-device")
        let report = try AIResponseValidator.decode(HookReport.self, from: hookResponse.text)
        XCTAssertEqual(report.score, HookAnalyzer.local(input).score, accuracy: 1e-9)

        let sentences = [sentence(0, "أهلا", 0, 3), sentence(1, "تفاصيل", 4, 9), sentence(2, "خاتمة", 10, 12)]
        let shortenRequest = AIRequest(task: .shorten, systemInstruction: "", messages: [], responseSchema: nil,
                                       localInput: .shorten(ShortenInput(sentences: sentences, target: 6, totalDuration: 12)))
        let shortenResponse = try await LocalAIProvider().generate(shortenRequest, model: "on-device")
        let result = try AIResponseValidator.decode(ShortenResult.self, from: shortenResponse.text)
        XCTAssertTrue(result.keep.contains(0))
        XCTAssertFalse(result.keep.contains(1))
    }

    // MARK: Translation

    func testTranslationBatchesAndValidation() {
        XCTAssertEqual(CaptionTranslator.batches(count: 95, size: 40), [0..<40, 40..<80, 80..<95])
        XCTAssertTrue(CaptionTranslator.batches(count: 0).isEmpty)
        XCTAssertEqual(CaptionTranslator.validate(["a", " ", "c\\nd"], expected: 3, originals: ["x", "y", "z"]), ["a", "y", "c\nd"])
        XCTAssertNil(CaptionTranslator.validate(["a"], expected: 2, originals: ["x", "y"]))
        let prompt = CaptionTranslator.prompt(["سطر\nثاني"], target: TranslationTarget.target("en")!)
        XCTAssertTrue(prompt.contains("1. سطر\\nثاني"))
    }

    // MARK: Assistant memory & history

    func testAssistantMemory() {
        XCTAssertEqual(AssistantMemory.keys(for: .transition(clips: [], kind: .fadeBlack, duration: 0.3)),
                       ["transition:fadeBlack", "transitionLength:short"])
        XCTAssertEqual(AssistantMemory.keys(for: .color(clips: [], exposure: 0, contrast: 0, saturation: 10, temperature: -5)),
                       ["color:cool", "color:vivid"])
        XCTAssertTrue(AssistantMemory.keys(for: .split(time: 2)).isEmpty)
        let counts = ["transition:fadeBlack": 3, "transition:crossDissolve": 2, "placement:top": 1]
        XCTAssertEqual(AssistantMemory.preferredTransition(counts), .fadeBlack)
        XCTAssertNil(AssistantMemory.preferredTransition(["transition:fadeBlack": 1]))
        var data = AssistantMemoryData()
        data.counts = counts
        let summary = AssistantMemory.summary(data)
        XCTAssertTrue(summary.contains(TransitionKind.fadeBlack.title))
        XCTAssertFalse(summary.contains("أعلى الشاشة"))
        XCTAssertEqual(AssistantMemory.summary(AssistantMemoryData()), "")
        data = AssistantMemoryData(isEnabled: true, notes: "عناويني في الأعلى", counts: [:])
        XCTAssertTrue(AssistantMemory.summary(data).contains("عناويني في الأعلى"))
    }

    func testPreferredTransitionReachesPlans() {
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [
            Clip(name: "a", source: .image(UUID()), start: .zero, duration: TimeValue(seconds: 2)),
            Clip(name: "b", source: .image(UUID()), start: TimeValue(seconds: 2), duration: TimeValue(seconds: 2))
        ])])
        let ctx = assistantContext(timeline, preferred: .zoomIn)
        let parsed = LocalCommandParser.parse("أضف انتقالات بين المقاطع", context: ctx)
        let plan = AIResponseValidator.plan(calls: parsed.calls, text: "", context: ctx, styles: [])
        guard case .transition(_, let kind, _) = plan.steps.first?.operation else { return XCTFail("transition") }
        XCTAssertEqual(kind, .zoomIn)
        let call = AIFunctionCall(name: "add_transition", arguments: Data("{}".utf8))
        let modelPlan = AIResponseValidator.plan(calls: [call], text: "", context: ctx, styles: [])
        guard case .transition(_, let modelKind, _) = modelPlan.steps.first?.operation else { return XCTFail("transition") }
        XCTAssertEqual(modelKind, .zoomIn)
    }

    func testPlanRecordRoundTrip() throws {
        let plan = AIPlan(explanation: "تم", steps: [
            AIPlanStep(operation: .addTitle(text: "مرحبا", start: 1, duration: 2, placement: .top), summary: "عنوان"),
            AIPlanStep(operation: .trim(clip: UUID(), start: nil, end: 4), summary: "قص", isEnabled: false),
            AIPlanStep(operation: .openTool(.captions), summary: "ترجمة"),
            AIPlanStep(operation: .removeSilences(minimum: 0.8), summary: "صمت")
        ], warnings: ["w"])
        let record = PlanRecord(date: Date(timeIntervalSince1970: 1_800_000_000), request: "طلب", plan: plan, provider: .gemini, result: "ok")
        let data = try JSONStore.makeEncoder().encode([record])
        let decoded = try JSONStore.makeDecoder().decode([PlanRecord].self, from: data)
        XCTAssertEqual(decoded.first?.plan, plan)
        XCTAssertEqual(decoded.first?.request, "طلب")
        XCTAssertEqual(decoded.first?.plan.steps[1].isEnabled, false)
    }

    // MARK: Speech

    func testSpeechChunksAndWav() {
        let sentenceText = String(repeating: "كلمة ", count: 40) + "."
        let text = Array(repeating: sentenceText, count: 10).joined(separator: " ")
        let parts = SpeechSynthesis.chunks(text, maxLength: 500)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 500 })
        XCTAssertEqual(SpeechSynthesis.chunks("   "), [])
        XCTAssertEqual(SpeechSynthesis.chunks("قصير"), ["قصير"])

        let pcm = Data([1, 2, 3, 4])
        let wav = SpeechSynthesis.wav(pcm16: pcm, sampleRate: 24_000, channels: 1)
        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 24_000)
        XCTAssertEqual(wav.suffix(4), pcm)
        XCTAssertEqual(SpeechSynthesis.geminiText("مرحبا", style: "بحماس"), "بحماس: مرحبا")
    }

    func testGeminiSpeechWireFormat() throws {
        let body = GeminiClient.speechBody(text: "مرحبا", voice: "Kore")
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
        let speech = try XCTUnwrap(config["speechConfig"] as? [String: Any])
        let voice = try XCTUnwrap((speech["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any])
        XCTAssertEqual(voice["voiceName"] as? String, "Kore")

        let json: [String: Any] = ["candidates": [["content": ["parts": [["inlineData": ["mimeType": "audio/L16;codec=pcm;rate=16000",
                                                                                         "data": Data([9, 8, 7, 6]).base64EncodedString()]]]]]],
                                   "usageMetadata": ["promptTokenCount": 3, "candidatesTokenCount": 40]]
        let parsed = try GeminiClient.parseSpeech(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(parsed.pcm, Data([9, 8, 7, 6]))
        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.usage.totalTokens, 43)
        let candidate: [String: Any] = ["content": ["parts": [["text": "x"]]], "finishReason": "STOP"]
        let empty: [String: Any] = ["candidates": [candidate]]
        XCTAssertThrowsError(try GeminiClient.parseSpeech(JSONSerialization.data(withJSONObject: empty)))

        func model(_ id: String) -> GeminiModelInfo {
            GeminiModelInfo(id: id, displayName: id, inputTokenLimit: 0, outputTokenLimit: 0, methods: ["generateContent"])
        }
        XCTAssertEqual(AIModelManager.bestTTS(["gemini-2.5-pro-preview-tts", "gemini-2.5-flash-preview-tts", "gemini-2.5-flash"].map(model)),
                       "gemini-2.5-flash-preview-tts")
        XCTAssertNil(AIModelManager.bestTTS([model("gemini-2.5-flash")]))
    }

    // MARK: Music suggestions

    func testMusicRecommender() {
        XCTAssertEqual(MusicRecommender.tempoMatch(120, target: 120), 1, accuracy: 1e-9)
        XCTAssertEqual(MusicRecommender.tempoMatch(60, target: 120), 0.9, accuracy: 1e-9)
        XCTAssertLessThan(MusicRecommender.tempoMatch(90, target: 120), 0.5)
        XCTAssertEqual(MusicMood.detect(in: "ريلز سريع")?.id, "energetic")
        XCTAssertEqual(MusicMood.detect(in: "إعلان مقهى هادئ")?.id, "calm")
        XCTAssertNil(MusicMood.detect(in: "مشروع"))
        XCTAssertEqual(MusicMood.fromPace(averageShotLength: 1.0).id, "sport")
        XCTAssertEqual(MusicMood.fromPace(averageShotLength: 6).id, "calm")

        let fast = makeAsset(kind: .audio, duration: 60)
        let slow = makeAsset(kind: .audio, duration: 60)
        let ranked = MusicRecommender.rank([(asset: slow, analysis: analysis(slow.id, duration: 60, bpm: 75, energy: [0.3])),
                                            (asset: fast, analysis: analysis(fast.id, duration: 60, bpm: 126, energy: [0.8]))],
                                           mood: MusicMood.mood("energetic")!, projectDuration: 30)
        XCTAssertEqual(ranked.first?.asset.id, fast.id)
        XCTAssertTrue(ranked.first?.reasons.contains("تكفي طول الفيديو") ?? false)
    }

    // MARK: Thumbnail

    func testThumbnailMeasures() {
        let flat = [Float](repeating: 0.5, count: 64)
        XCTAssertEqual(ThumbnailMaker.laplacianVariance(flat, width: 8, height: 8), 0, accuracy: 1e-12)
        let checker = (0..<64).map { Float(($0 % 8 + $0 / 8) % 2) }
        XCTAssertGreaterThan(ThumbnailMaker.laplacianVariance(checker, width: 8, height: 8), 1)

        let gray = [UInt8](repeating: 128, count: 16 * 4)
        let stats = ThumbnailMaker.colorStats(gray, width: 4, height: 4)
        XCTAssertEqual(stats.brightness, 128.0 / 255, accuracy: 1e-6)
        XCTAssertEqual(stats.colorfulness, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.contrast, 0, accuracy: 1e-9)

        let good = FrameMetrics(sharpness: 0.05, brightness: 0.5, colorfulness: 0.4, contrast: 0.5, faceQuality: 0.8, faceCount: 1)
        let dark = FrameMetrics(sharpness: 0.0001, brightness: 0.05, colorfulness: 0.02, contrast: 0.05, faceQuality: 0, faceCount: 0)
        XCTAssertGreaterThan(ThumbnailMaker.score(good), 70)
        XCTAssertEqual(ThumbnailMaker.score(dark), 0, accuracy: 1e-9)

        XCTAssertEqual(ThumbnailMaker.sampleTimes(duration: 10, count: 4), [2, 4, 6, 8])
        XCTAssertEqual(ThumbnailMaker.outputSize(canvas: CGSize(width: 1080, height: 1920)), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ThumbnailMaker.outputSize(canvas: CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
    }

    // MARK: Series

    func testSeriesEpisode() throws {
        let video = makeAsset(kind: .video, duration: 30)
        var options = SeriesOptions()
        options.seriesName = "رحلات"
        options.outroText = "تابعونا"
        options.outroDuration = 2
        let timeline = try SeriesBuilder.episode(video: video, index: 1, options: options, style: nil, music: nil, musicAnalysis: nil,
                                                 settings: ProjectSettings(aspect: .portrait9x16))
        XCTAssertEqual(SeriesBuilder.episodeLabel(options, index: 1), "الحلقة 2")
        let main = timeline.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(main.count, 3)
        XCTAssertNotNil(main[1].transitionIn)
        let titles = timeline.tracks[1].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(titles.count, 2)
        guard case .text(let intro) = titles[0].source else { return XCTFail("intro") }
        XCTAssertEqual(intro.text, "رحلات")
        XCTAssertEqual(intro.subtitle, "الحلقة 2")
        XCTAssertEqual(timeline.tracks.count, 2)

        options.introDuration = 0
        options.outroText = ""
        options.maximumDuration = 10
        options.transition = .none
        let song = makeAsset(kind: .audio, duration: 4)
        let short = try SeriesBuilder.episode(video: video, index: 0, options: options, style: EditingDNA.calmCinematic, music: song,
                                              musicAnalysis: analysis(song.id, duration: 4), settings: ProjectSettings())
        let clips = short.tracks[0].clips
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].duration.seconds, 10, accuracy: 1e-6)
        guard case .text(let lower) = short.tracks[1].clips[0].source else { return XCTFail("title") }
        XCTAssertEqual(lower.design, .lowerThird)
        let music = try XCTUnwrap(short.tracks.first { $0.kind == .audio })
        XCTAssertGreaterThan(music.clips.count, 1)
        XCTAssertLessThanOrEqual(music.clips.reduce(0) { $0 + $1.duration.seconds }, 10 + 1e-6)
    }

    // MARK: Part 6 — performance & accessibility

    func testProxyPolicy() {
        XCTAssertTrue(ProxyPolicy.needsProxy(makeAsset(kind: .video, duration: 10, width: 3840, height: 2160)))
        XCTAssertFalse(ProxyPolicy.needsProxy(makeAsset(kind: .video, duration: 10)))
        XCTAssertTrue(ProxyPolicy.needsProxy(makeAsset(kind: .video, duration: 10, fps: 120)))
        XCTAssertTrue(ProxyPolicy.needsProxy(makeAsset(kind: .video, duration: 10, bitrate: 60_000_000)))
        XCTAssertTrue(ProxyPolicy.needsProxy(makeAsset(kind: .video, duration: 10, codec: "apch")))
        XCTAssertFalse(ProxyPolicy.needsProxy(makeAsset(kind: .audio, duration: 10)))
        let video = makeAsset(kind: .video, duration: 10, width: 3840, height: 2160)
        let record = ProxyRecord(assetID: video.id, fingerprint: video.fingerprint, fileName: "x.mp4", resolution: .p540, bytes: 1, createdAt: Date())
        XCTAssertTrue(ProxyPolicy.isValid(record, for: video, fileExists: true))
        XCTAssertFalse(ProxyPolicy.isValid(record, for: video, fileExists: false))
        var relinked = video
        relinked.fingerprint = "other"
        XCTAssertFalse(ProxyPolicy.isValid(record, for: relinked, fileExists: true))
    }

    func testAdaptivePreviewCap() {
        XCTAssertEqual(PerformanceMonitor.previewCap(thermal: .critical, lowPower: false), 360)
        XCTAssertEqual(PerformanceMonitor.previewCap(thermal: .serious, lowPower: false), 540)
        XCTAssertEqual(PerformanceMonitor.previewCap(thermal: .nominal, lowPower: true), 540)
        XCTAssertNil(PerformanceMonitor.previewCap(thermal: .fair, lowPower: false))
        XCTAssertFalse(PerformanceMonitor.title(.critical).isEmpty)
    }

    func testClipAccessibilityDescription() {
        var clip = Clip(name: "مقابلة", source: .media(asset), start: TimeValue(seconds: 2), duration: TimeValue(seconds: 3),
                        sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: 3))
        clip.speed.rate = 2
        let text = AccessibilityPrefs.clipDescription(clip, trackKind: .video, locked: true)
        XCTAssertTrue(text.hasPrefix("فيديو"))
        XCTAssertTrue(text.contains("×2"))
        XCTAssertTrue(text.contains("مقفل"))
        let caption = Clip(name: "c", source: .text(TextContent(text: "مرحبا")), start: .zero, duration: TimeValue(seconds: 1))
        XCTAssertTrue(AccessibilityPrefs.kindTitle(caption, trackKind: .text).contains("مرحبا"))
        XCTAssertFalse(AccessibilityPrefs.clipDescription(caption, trackKind: .text, locked: false).contains("مقفل"))
    }
}
