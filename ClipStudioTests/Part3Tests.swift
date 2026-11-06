//
//  Part3Tests.swift
//  ClipStudioTests
//
//  Part 3: backward-compatible decoding of the new model fields, close gaps,
//  ripple range removal (text-based editing), same-source selection, inverse
//  speed mapping, caption grouping / line breaks / word timing through splits,
//  SRT & VTT, motion presets, EQ filter math, BS.1770 loudness, ducking keyframes,
//  transcript coverage and project templates.
//

import XCTest
@testable import ClipStudio

final class Part3Tests: XCTestCase {
    private let asset = UUID()

    private func context(magnetic: Bool = false) -> EditContext {
        EditContext(assetDurations: [asset: 100], frameRate: 30, magnetic: magnetic)
    }

    private func media(start: Double, duration: Double, sourceStart: Double = 0, assetID: UUID? = nil) -> Clip {
        Clip(name: "clip", source: .media(assetID ?? asset), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration),
             sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + duration))
    }

    private func sorted(_ track: Track) -> [Clip] { track.clips.sorted { $0.start < $1.start } }

    /// Encodes `value`, removes `keys` from the top-level JSON object and decodes it again.
    private func roundTrip<T: Codable>(_ value: T, removing keys: [String]) throws -> T {
        let data = try JSONStore.makeEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in keys { object.removeValue(forKey: key) }
        let stripped = try JSONSerialization.data(withJSONObject: object)
        return try JSONStore.makeDecoder().decode(T.self, from: stripped)
    }

    // MARK: Decoding

    func testOldTrackDecodesWithDefaults() throws {
        var track = Track(kind: .audio, name: "Music")
        track.volume = 0.5
        let decoded = try roundTrip(track, removing: ["pan", "isSolo", "color"])
        XCTAssertEqual(decoded.volume, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.pan, 0)
        XCTAssertFalse(decoded.isSolo)
        XCTAssertNil(decoded.color)
    }

    func testOldClipAudioKeepsVolumeAndGetsNeutralEffects() throws {
        var audio = ClipAudio()
        audio.volume = KeyframedValue(0.3)
        audio.fadeIn = 1.5
        let decoded = try roundTrip(audio, removing: ["effects"])
        XCTAssertEqual(decoded.volume.base, 0.3, accuracy: 1e-9)
        XCTAssertEqual(decoded.fadeIn, 1.5, accuracy: 1e-9)
        XCTAssertTrue(decoded.effects.isNeutral)
    }

    func testOldTransformAndTextDecode() throws {
        var transform = ClipTransform()
        transform.scale = KeyframedValue(0.7)
        let decodedTransform = try roundTrip(transform, removing: ["stretch", "aspectLocked"])
        XCTAssertEqual(decodedTransform.scale.base, 0.7, accuracy: 1e-9)
        XCTAssertEqual(decodedTransform.stretch, .one)
        XCTAssertTrue(decodedTransform.aspectLocked)

        let text = TextContent(text: "مرحبا")
        let decodedText = try roundTrip(text, removing: ["loop", "design", "subtitle", "accentColor", "caption"])
        XCTAssertEqual(decodedText.text, "مرحبا")
        XCTAssertEqual(decodedText.design, .plain)
        XCTAssertNil(decodedText.caption)

        let settings = try roundTrip(ProjectSettings(canvasWidth: 1080, canvasHeight: 1920, frameRate: 30), removing: ["watermark"])
        XCTAssertNil(settings.watermark)
        XCTAssertEqual(settings.canvasHeight, 1920)
    }

    // MARK: Gaps & ranges

    func testCloseGapsKeepsOrderAndFirstStart() throws {
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [media(start: 2, duration: 3), media(start: 8, duration: 2),
                                                                        media(start: 20, duration: 1)])])
        XCTAssertEqual(TimelineEngine.gaps(in: timeline.tracks[0], context: context()).count, 2)
        let removed = try TimelineEngine.closeGaps(onTrack: 0, in: &timeline, context: context())
        XCTAssertEqual(removed, 13, accuracy: 1e-6)
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips[0].start.seconds, 2, accuracy: 1e-6)
        XCTAssertEqual(clips[1].start.seconds, 5, accuracy: 1e-6)
        XCTAssertEqual(clips[2].start.seconds, 7, accuracy: 1e-6)
    }

    func testRemoveRangesRipplesAllTracksInSync() {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [media(start: 0, duration: 10)]),
                                         Track(kind: .audio, clips: [media(start: 0, duration: 10)])])
        let removed = TimelineEngine.removeRanges([TimeSpan(start: 2, end: 3), TimeSpan(start: 6, end: 8)], in: &timeline, context: context())
        XCTAssertEqual(removed, 3, accuracy: 1e-6)
        for track in timeline.tracks {
            let clips = sorted(track)
            XCTAssertEqual(clips.count, 3)
            XCTAssertEqual(track.endTime.seconds, 7, accuracy: 1e-6)
            XCTAssertEqual(clips[1].start.seconds, 2, accuracy: 1e-6)
            XCTAssertEqual(clips[1].sourceRange?.start.seconds ?? 0, 3, accuracy: 1e-6)
            XCTAssertEqual(clips[2].start.seconds, 5, accuracy: 1e-6)
            XCTAssertEqual(clips[2].sourceRange?.start.seconds ?? 0, 8, accuracy: 1e-6)
        }
    }

    func testMergedSpans() {
        let merged = TimelineEngine.mergedSpans([TimeSpan(start: 5, end: 6), TimeSpan(start: 1, end: 2), TimeSpan(start: 1.5, end: 3)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].end, 3, accuracy: 1e-9)
    }

    func testClipsSharingSource() {
        let other = UUID()
        let a = media(start: 0, duration: 2)
        let b = media(start: 5, duration: 2)
        let c = media(start: 0, duration: 2, assetID: other)
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [a, b]), Track(kind: .overlay, clips: [c])])
        XCTAssertEqual(TimelineEngine.clipsSharingSource(with: a.id, in: timeline), [a.id, b.id])
    }

    func testInverseSpeedMapping() {
        var clip = Clip(name: "c", source: .media(asset), start: .zero, duration: TimeValue(seconds: 5),
                        sourceRange: TimeRangeValue(startSeconds: 10, endSeconds: 20))
        clip.speed.rate = 2
        XCTAssertEqual(SpeedMapping.localTime(of: clip, sourceTime: 14) ?? -1, 2, accuracy: 1e-6)
        clip.speed.isReversed = true
        XCTAssertEqual(SpeedMapping.localTime(of: clip, sourceTime: 14) ?? -1, 3, accuracy: 1e-6)
        XCTAssertNil(SpeedMapping.localTime(of: clip, sourceTime: 25))
    }

    // MARK: Captions

    private func words(_ items: [(String, Double, Double)]) -> [TimelineWord] {
        items.map { TimelineWord(text: $0.0, start: $0.1, end: $0.2, confidence: 1, clipID: UUID()) }
    }

    func testCaptionCuesBreakOnPausesAndSentences() {
        let input = words([("مرحبا", 0, 0.4), ("بكم.", 0.45, 0.9), ("هذا", 1.0, 1.3), ("مثال", 1.35, 1.7), ("بعد", 3.0, 3.3)])
        let cues = CaptionBuilder.cues(from: input, options: CaptionLayoutOptions())
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].text, "مرحبا بكم.")
        XCTAssertEqual(cues[1].words.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(cues[1].end, cues[2].start)
    }

    func testBalancedLineBreak() {
        let breaks = CaptionBuilder.lineBreaks(["one", "two", "three", "four", "five", "six"], maxChars: 16, maxLines: 2)
        XCTAssertEqual(breaks, [3])
    }

    func testCaptionActiveWordAndRetext() {
        var info = CaptionInfo(words: [CaptionWord(text: "a", start: 0, end: 0.5), CaptionWord(text: "b", start: 0.6, end: 1)])
        XCTAssertNil(CaptionInfo(words: [CaptionWord(text: "x", start: 0.2, end: 0.4)]).activeWordIndex(at: 0.1))
        XCTAssertEqual(info.activeWordIndex(at: 0.55), 0)
        XCTAssertEqual(info.activeWordIndex(at: 0.7), 1)
        info.retext("A B", duration: 1)
        XCTAssertEqual(info.words[1].text, "B")
        XCTAssertEqual(info.words[1].start, 0.6, accuracy: 1e-9)
        info.retext("one two three", duration: 1)
        XCTAssertEqual(info.words.count, 3)
        XCTAssertEqual(info.words.last?.end ?? 0, 1, accuracy: 1e-9)
    }

    func testCaptionWordsFollowSplit() throws {
        let cue = CaptionCue(start: 0, end: 2, words: [CaptionWord(text: "a", start: 0, end: 0.8),
                                                       CaptionWord(text: "b", start: 1.2, end: 1.9)])
        let clip = CaptionBuilder.makeClip(cue, preset: .classic)
        let parts = try TimelineEngine.split(clip, at: 1, context: context())
        guard case .text(let left) = parts.0.source, case .text(let right) = parts.1.source else { return XCTFail("text expected") }
        XCTAssertEqual(left.caption?.words.map(\.text), ["a"])
        XCTAssertEqual(right.caption?.words.map(\.text), ["b"])
        XCTAssertEqual(right.caption?.words.first?.start ?? -1, 0.2, accuracy: 1e-6)
    }

    func testSRTAndVTTRoundTrip() {
        let srt = "\u{FEFF}1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>مرحبا</i>\r\nبكم\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,250\r\nثانية\r\n"
        let cues = SubtitleCodec.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cues[0].text, "مرحبا\nبكم")
        let vtt = SubtitleCodec.encode(cues, format: .vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        let again = SubtitleCodec.parse(vtt)
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again[1].end, 5.25, accuracy: 1e-9)
        XCTAssertEqual(SubtitleCodec.timestamp(3725.5, format: .srt), "01:02:05,500")
        XCTAssertEqual(SubtitleCodec.parseTimestamp("02:03.5") ?? 0, 123.5, accuracy: 1e-9)
    }

    func testFillerDetectionNormalizesArabic() {
        XCTAssertTrue(CaptionBuilder.isFiller("اممم،"))
        XCTAssertTrue(CaptionBuilder.isFiller("Um,"))
        XCTAssertFalse(CaptionBuilder.isFiller("مرحبا"))
    }

    func testTranscriptCoverage() {
        var transcript = AssetTranscript(assetID: asset, localeID: "ar-SA")
        transcript.merge([TranscriptWord(text: "x", start: 1, end: 2, confidence: 1)], span: TimeSpan(start: 0, end: 10), server: false)
        let missing = transcript.missing(in: TimeSpan(start: 5, end: 20))
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing[0].start, 10, accuracy: 1e-9)
        transcript.merge([], span: TimeSpan(start: 10, end: 20), server: true)
        XCTAssertTrue(transcript.missing(in: TimeSpan(start: 0, end: 20)).isEmpty)
        XCTAssertTrue(transcript.usedServer)
    }

    // MARK: Motion presets

    func testMotionPresetAnchorsAndRelativeValues() throws {
        var clip = media(start: 0, duration: 4)
        clip.transform.scale = KeyframedValue(0.5)
        let fade = try XCTUnwrap(MotionPreset.builtIns.first { $0.name == "اختفاء تدريجي" })
        fade.apply(to: &clip, frame: 1.0 / 30)
        XCTAssertEqual(clip.transform.opacity.keyframes.first?.time ?? 0, 3.4, accuracy: 1e-6)
        XCTAssertEqual(clip.transform.opacity.value(at: 4), 0, accuracy: 0.05)

        let zoom = MotionPreset.builtIns[0]
        zoom.apply(to: &clip, frame: 1.0 / 30)
        XCTAssertEqual(clip.transform.scale.value(at: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(clip.transform.scale.keyframes.last?.value ?? 0, 0.6, accuracy: 1e-6)

        let captured = try XCTUnwrap(MotionPreset.capture(from: clip, name: "mine"))
        XCTAssertEqual(captured.scale.last?.value ?? 0, 1.2, accuracy: 1e-6)
    }

    // MARK: Audio DSP

    func testPeakingFilterGainAtCenter() {
        let filter = BiquadCoefficients.peaking(frequency: 1000, gainDB: 6, q: 1, sampleRate: 48_000)
        XCTAssertEqual(filter.magnitudeDB(at: 1000, sampleRate: 48_000), 6, accuracy: 0.05)
        XCTAssertEqual(filter.magnitudeDB(at: 50, sampleRate: 48_000), 0, accuracy: 0.2)
        let highPass = BiquadCoefficients.highPass(frequency: 200, sampleRate: 48_000)
        XCTAssertLessThan(highPass.magnitudeDB(at: 30, sampleRate: 48_000), -25)
        XCTAssertEqual(highPass.magnitudeDB(at: 5000, sampleRate: 48_000), 0, accuracy: 0.1)
    }

    func testLoudnessOfStereoSine() {
        var meter = KWeightedMeter(channels: 2, sampleRate: 48_000,
                                   shelf: BiquadCoefficients(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                                             a1: -1.69065929318241, a2: 0.73248077421585),
                                   rlb: BiquadCoefficients(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621))
        let frames = 48_000 * 3
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(0.1 * sin(2 * Double.pi * 997 * Double(i) / 48_000))
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        samples.withUnsafeBufferPointer { meter.consume($0.baseAddress!, count: frames * 2) }
        let result = meter.result()
        XCTAssertEqual(result.integrated, -20.0, accuracy: 0.5)
        XCTAssertEqual(result.peak, -20, accuracy: 0.1)
    }

    func testDuckingWritesRampsAroundSpeech() {
        var music = media(start: 0, duration: 10)
        var settings = DuckingSettings()
        settings.reductionDB = 12
        settings.attack = 0.5
        settings.release = 1
        let changed = DuckingEngine.apply(to: &music, speech: [TimeSpan(start: 3, end: 5)], settings: settings)
        XCTAssertTrue(changed)
        XCTAssertEqual(music.audio.volume.value(at: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(music.audio.volume.value(at: 4), pow(10, -12.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(music.audio.volume.value(at: 7), 1, accuracy: 1e-6)
        XCTAssertEqual(DuckingEngine.consolidate([TimeSpan(start: 0, end: 1), TimeSpan(start: 1.2, end: 2)], hold: 0.5).count, 1)
    }

    func testAudioPresetKeepsBalance() {
        var effects = AudioEffects()
        effects.pan = -0.4
        AudioEffectPreset.podcast.apply(to: &effects)
        XCTAssertEqual(effects.pan, -0.4, accuracy: 1e-9)
        XCTAssertTrue(effects.compressorEnabled)
        XCTAssertFalse(effects.isNeutral)
        AudioEffectPreset.reset.apply(to: &effects)
        XCTAssertFalse(effects.compressorEnabled)
    }

    // MARK: Templates

    func testTemplatesBuildOrganizedTracks() {
        let reels = ProjectTemplate.reels.makeTimeline()
        XCTAssertTrue(reels.tracks.contains { $0.kind == .subtitle })
        XCTAssertTrue(reels.tracks.allSatisfy { $0.color != nil })
        let index = ProjectTemplate.reels.audioTrackIndex(in: reels)
        XCTAssertEqual(reels.tracks[index ?? 0].name, "الموسيقى")
        XCTAssertEqual(ProjectTemplate.reels.aspect, .portrait9x16)
    }

    func testScriptDirection() {
        XCTAssertTrue(ScriptDirection.isRightToLeft("123 مرحبا"))
        XCTAssertFalse(ScriptDirection.isRightToLeft("Hello مرحبا"))
    }
}
