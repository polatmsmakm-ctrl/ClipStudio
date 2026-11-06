//
//  Part4Tests.swift
//  ClipStudioTests
//
//  Part 4: model decoding (stabilization, Editing DNA), music analysis on synthetic
//  click tracks (tempo, beats, downbeats), beat-sync re-timing and beat-centred
//  transitions, stabilization corrections and interpolation, reframe crops,
//  Editing DNA learn / apply, Quality Inspector checks and fixes, multi-format
//  variants, templates (slots, fill, slow-down) and the voice / background
//  separator (perfect reconstruction, centre vs. side content).
//

import XCTest
import CoreImage
@testable import ClipStudio

final class Part4Tests: XCTestCase {
    private let asset = UUID()

    private func context(magnetic: Bool = false, durations: [UUID: Double]? = nil) -> EditContext {
        EditContext(assetDurations: durations ?? [asset: 100], frameRate: 30, magnetic: magnetic)
    }

    private func media(start: Double, duration: Double, sourceStart: Double = 0, assetID: UUID? = nil) -> Clip {
        Clip(name: "clip", source: .media(assetID ?? asset), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration),
             sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + duration))
    }

    private func image(start: Double, duration: Double, id: UUID = UUID()) -> Clip {
        Clip(name: "image", source: .image(id), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration))
    }

    private func sorted(_ track: Track) -> [Clip] { track.clips.sorted { $0.start < $1.start } }

    private func makeAsset(id: UUID, kind: MediaKind = .video, duration: Double? = 60, width: Int = 1920, height: Int = 1080,
                           fps: Double = 30) -> MediaAsset {
        MediaAsset(id: id, kind: kind, displayName: "asset", originalFilename: "a.mov", storedFileName: "a.mov",
                   importedAt: Date(), fileSize: 1, durationSeconds: duration, pixelWidth: kind == .audio ? nil : width,
                   pixelHeight: kind == .audio ? nil : height, frameRate: kind == .video ? fps : nil, videoCodec: nil,
                   audioCodec: nil, hasAudio: kind != .image, estimatedBitrate: nil, fingerprint: UUID().uuidString)
    }

    private func roundTrip<T: Codable>(_ value: T, removing keys: [String]) throws -> T {
        let data = try JSONStore.makeEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in keys { object.removeValue(forKey: key) }
        let stripped = try JSONSerialization.data(withJSONObject: object)
        return try JSONStore.makeDecoder().decode(T.self, from: stripped)
    }

    /// Short noise bursts on every beat; every 4th beat is louder with a low kick.
    private func clickTrack(bpm: Double, seconds: Double, start: Double = 0.3, sampleRate: Double = 22_050) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var generator = SystemRandomNumberGenerator()
        var t = start
        var index = 0
        while t < seconds - 0.1 {
            let begin = Int(t * sampleRate)
            let length = Int(0.03 * sampleRate)
            let accent: Float = index % 4 == 0 ? 1 : 0.5
            for i in 0..<length where begin + i < samples.count {
                let envelope = Float(exp(-Double(i) / (0.005 * sampleRate)))
                var value = Float.random(in: -0.3...0.3, using: &generator) * envelope * accent
                if index % 4 == 0 { value += 0.8 * Float(sin(2 * Double.pi * 60 * Double(i) / sampleRate)) * envelope }
                samples[begin + i] += value
            }
            t += 60 / bpm
            index += 1
        }
        return samples
    }

    // MARK: Decoding

    func testOldClipDecodesWithoutStabilization() throws {
        var clip = media(start: 0, duration: 2)
        clip.stabilization = StabilizationSettings(assetID: asset)
        let decoded = try roundTrip(clip, removing: ["stabilization"])
        XCTAssertNil(decoded.stabilization)
        let kept = try roundTrip(clip, removing: [])
        XCTAssertEqual(kept.stabilization?.assetID, asset)
        XCTAssertEqual(kept.stabilization?.strength ?? 0, 0.6, accuracy: 1e-9)
    }

    func testStabilizationSettingsDefaults() throws {
        var settings = StabilizationSettings(assetID: asset)
        settings.strength = 0.9
        let decoded = try roundTrip(settings, removing: ["zoom", "isEnabled"])
        XCTAssertEqual(decoded.strength, 0.9, accuracy: 1e-9)
        XCTAssertEqual(decoded.zoom, 1.08, accuracy: 1e-9)
        XCTAssertTrue(decoded.isEnabled)
    }

    func testEditingDNARoundTrip() throws {
        let dna = EditingDNA.fastReels
        let data = try JSONStore.makeEncoder().encode(dna)
        let decoded = try JSONStore.makeDecoder().decode(EditingDNA.self, from: data)
        XCTAssertEqual(decoded.id, dna.id)
        XCTAssertEqual(decoded.averageShotLength, 1.2, accuracy: 1e-9)
        XCTAssertEqual(decoded.transitionKind, .zoomIn)
        XCTAssertEqual(decoded.captionHighlight, dna.captionHighlight)
        XCTAssertEqual(decoded.aspect, .portrait9x16)
    }

    func testBuiltInStylesHaveStableUniqueIDs() {
        let ids = EditingDNA.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(EditingDNA.builtIns.map(\.id), EditingDNA.builtIns.map(\.id))
        XCTAssertTrue(EditingDNA.builtIns.allSatisfy(\.isBuiltIn))
    }

    // MARK: Music analysis

    func testTempoAndBeatsOfClickTrack() {
        for bpm in [90.0, 120.0, 128.0] {
            let analysis = MusicAnalyzer.analyze(samples: clickTrack(bpm: bpm, seconds: 20), sampleRate: 22_050)
            XCTAssertEqual(analysis.bpm, bpm, accuracy: 2.5, "bpm \(bpm)")
            XCTAssertGreaterThan(analysis.beats.count, Int(20 * bpm / 60) - 4)
            let gaps = zip(analysis.beats.dropFirst(), analysis.beats).map { $0 - $1 }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            XCTAssertEqual(mean, 60 / bpm, accuracy: 0.03)
            // The first beat is on the first click, not in the silence before it.
            XCTAssertEqual(analysis.beats.first ?? 0, 0.3, accuracy: 0.06)
        }
    }

    func testDownbeatsFollowAccents() {
        let analysis = MusicAnalyzer.analyze(samples: clickTrack(bpm: 120, seconds: 20), sampleRate: 22_050)
        XCTAssertFalse(analysis.downbeats.isEmpty)
        // Accented clicks are at 0.3 + 2·k seconds.
        for downbeat in analysis.downbeats.prefix(5) {
            let phase = (downbeat - 0.3).truncatingRemainder(dividingBy: 2.0)
            XCTAssertTrue(phase < 0.08 || phase > 1.92, "downbeat \(downbeat)")
        }
    }

    func testSilenceHasNoBeats() {
        let analysis = MusicAnalyzer.analyze(samples: [Float](repeating: 0, count: 22_050 * 5), sampleRate: 22_050)
        XCTAssertTrue(analysis.beats.isEmpty)
        XCTAssertEqual(analysis.sections.count, 1)
    }

    func testEnergyEnvelopeIsNormalized() {
        let rms = (0..<430).map { Double($0 % 43) / 43 }
        let energy = MusicAnalyzer.energyEnvelope(rms: rms, frameRate: 43, rate: 10)
        XCTAssertEqual(energy.count, 108)
        XCTAssertTrue(energy.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testSectionsFindTheDrop() {
        // 10 s quiet then 10 s loud at 10 values per second.
        let energy = [Double](repeating: 0.2, count: 100) + [Double](repeating: 0.9, count: 100)
        let result = MusicAnalyzer.findSections(energy: energy, rate: 10, duration: 20, downbeats: [8, 10, 12])
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.drop ?? 0, 10, accuracy: 0.5)
        XCTAssertEqual(result.sections.last?.energy ?? 0, 1, accuracy: 1e-9)
    }

    // MARK: Beat sync

    func testTimelineBeatsFollowClipSpeed() {
        var clip = media(start: 10, duration: 2, sourceStart: 1)
        clip.sourceRange = TimeRangeValue(startSeconds: 1, endSeconds: 5)
        clip.speed.rate = 2
        clip.recomputeDurationFromSpeed()
        let analysis = MusicAnalysis(assetID: asset, duration: 10, bpm: 120, beats: [0.5, 2, 4.5, 6], downbeats: [2],
                                     energy: [], energyRate: 10, sections: [], dropTime: 4.5)
        let mapped = BeatSync.timelineBeats(analysis, clip: clip)
        XCTAssertEqual(mapped.beats.count, 2)
        XCTAssertEqual(mapped.beats[0], 10.5, accuracy: 1e-6)
        XCTAssertEqual(mapped.beats[1], 11.75, accuracy: 1e-6)
        XCTAssertEqual(BeatSync.timelineDrop(analysis, clip: clip) ?? 0, 11.75, accuracy: 1e-6)
    }

    func testCutToBeatsEveryTwoBeats() throws {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 1.7), image(start: 1.7, duration: 1.7),
                                                                      image(start: 3.4, duration: 1.7)])])
        let beats = stride(from: 0.0, through: 10, by: 0.5).map { $0 }
        var options = BeatSyncOptions()
        options.grid = .every2
        let result = try BeatSync.cutToBeats(track: 0, beats: beats, downbeats: [], options: options, in: &timeline, context: context())
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(result.onBeat, 3)
        assertClose(clips.map(\.start.seconds), [0, 1, 2], accuracy: 1e-6)
        assertClose(clips.map(\.end.seconds), [1, 2, 3], accuracy: 1e-6)
    }

    func testCutToBeatsRespectsSourceLength() throws {
        let short = UUID()
        var clip = media(start: 0, duration: 1.2, assetID: short)
        clip.sourceRange = TimeRangeValue(startSeconds: 0, endSeconds: 1.2)
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [clip])])
        var options = BeatSyncOptions()
        options.grid = .every4
        let result = try BeatSync.cutToBeats(track: 0, beats: [0, 0.5, 1, 1.5, 2, 2.5], downbeats: [], options: options,
                                             in: &timeline, context: context(durations: [short: 1.4]))
        // Four beats (2 s) don't fit in 1.4 s of media: the latest beat that fits is 1.0.
        XCTAssertEqual(timeline.tracks[0].clips[0].end.seconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(result.onBeat, 1)
    }

    func testBeatCentredTransitions() throws {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 2), image(start: 2, duration: 2)])])
        var options = BeatSyncOptions()
        options.grid = .every2
        options.transitionEvery = 1
        options.transitionDuration = 0.3
        let beats = stride(from: 0.0, through: 6, by: 0.5).map { $0 }
        let result = try BeatSync.cutToBeats(track: 0, beats: beats, downbeats: [], options: options, in: &timeline,
                                             context: context(magnetic: true))
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(result.transitions, 1)
        let transition = try XCTUnwrap(clips[1].transitionIn)
        let overlapCentre = clips[1].start.seconds + transition.duration.seconds / 2
        XCTAssertEqual(overlapCentre, 1.0, accuracy: 1 / 30.0)
        XCTAssertEqual(clips[0].end.seconds - clips[1].start.seconds, transition.duration.seconds, accuracy: 1e-6)
    }

    func testBeatMarkers() {
        let markers = BeatSync.markers(beats: [0, 0.5, 1, 1.5], downbeats: [0, 2], everyBeat: false, drop: 1.5)
        XCTAssertEqual(markers.count, 3)
        XCTAssertTrue(markers.contains { $0.name == "ذروة الموسيقى" })
    }

    // MARK: Stabilization

    func testStabilizationCorrectionsRemoveJitterKeepPan() {
        let times = (0..<150).map { Double($0) / 15 }
        // Slow pan + fast alternating shake.
        let pan = times.map { $0 * 0.01 }
        let shake = times.indices.map { $0 % 2 == 0 ? 0.004 : -0.004 }
        let data = StabilizationData(assetID: asset, span: TimeSpan(start: 0, end: 10), times: times,
                                     pathX: zip(pan, shake).map { $0 + $1 }, pathY: pan, sampleRate: 15)
        let corrections = StabilizationAnalyzer.corrections(data, strength: 0.6)
        // Mid-clip: pan is linear so it's untouched; shake is (almost) fully corrected.
        for index in 40..<110 {
            XCTAssertEqual(corrections.y[index], 0, accuracy: 1e-6)
            XCTAssertEqual(corrections.x[index], shake[index], accuracy: 0.0012)
        }
        let zoom = StabilizationAnalyzer.suggestedZoom(data, strength: 0.6)
        XCTAssertGreaterThanOrEqual(zoom, 1.02)
        XCTAssertLessThanOrEqual(zoom, 1.35)
    }

    func testStabilizationStoreInterpolates() throws {
        let id = UUID()
        let data = StabilizationData(assetID: id, span: TimeSpan(start: 0, end: 1), times: [0, 0.5, 1],
                                     pathX: [0, 0.1, 0], pathY: [0, 0, 0], sampleRate: 2)
        StabilizationStore.shared.insert(data)
        let a = try XCTUnwrap(StabilizationStore.shared.correction(assetID: id, strength: 0, at: 0.25))
        let table = StabilizationAnalyzer.corrections(data, strength: 0)
        XCTAssertEqual(a.x, (table.x[0] + table.x[1]) / 2, accuracy: 1e-9)
        XCTAssertNil(StabilizationStore.shared.correction(assetID: UUID(), strength: 0.5, at: 0))
    }

    func testStabilizedFrameKeepsExtent() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let result = LayerRenderer.stabilized(image, dx: 0.05, dy: -0.02, zoom: 1.1)
        XCTAssertEqual(result.extent, image.extent)
    }

    // MARK: Reframe

    func testCropSizeForVerticalCanvas() {
        let size = ReframeEngine.cropSize(sourceAspect: 16.0 / 9, targetAspect: 9.0 / 16)
        XCTAssertEqual(size.height, 1, accuracy: 1e-9)
        XCTAssertEqual(size.width, (9.0 / 16) / (16.0 / 9), accuracy: 1e-9)
    }

    func testCropKeyframesFollowSubject() {
        let clip = media(start: 0, duration: 4)
        let samples = stride(from: 0.0, to: 4, by: 0.125).map {
            SubjectSample(time: $0, rect: RectValue(x: 0.75, y: 0.3, width: 0.1, height: 0.2), confidence: 0.9)
        }
        let track = SubjectTrack(assetID: asset, mode: .faces, span: TimeSpan(start: 0, end: 4), samples: samples,
                                 sourceWidth: 1920, sourceHeight: 1080)
        let crop = ReframeEngine.cropKeyframes(for: clip, track: track, targetAspect: 9.0 / 16, smoothing: 0.5)
        let value = crop.value(at: 2)
        XCTAssertEqual(value.width, 0.31640625, accuracy: 1e-6)
        XCTAssertEqual(value.x + value.width / 2, 0.8, accuracy: 0.01)
        XCTAssertLessThanOrEqual(value.x + value.width, 1 + 1e-9)
        let zoomed = ReframeEngine.cropKeyframes(for: clip, track: track, targetAspect: 9.0 / 16, smoothing: 0.5, zoom: 2)
        XCTAssertEqual(zoomed.value(at: 2).width, 0.31640625 / 2, accuracy: 1e-6)
    }

    func testSmoothedCentersFillGaps() {
        let samples = [SubjectSample(time: 0, rect: RectValue(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0),
                       SubjectSample(time: 0.5, rect: RectValue(x: 0.6, y: 0.4, width: 0.2, height: 0.2), confidence: 0.9),
                       SubjectSample(time: 1, rect: RectValue(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0)]
        let track = SubjectTrack(assetID: asset, mode: .auto, span: TimeSpan(start: 0, end: 1), samples: samples,
                                 sourceWidth: 100, sourceHeight: 100)
        let centers = ReframeEngine.smoothedCenters(track, smoothing: 0.2)
        XCTAssertEqual(centers.count, 3)
        for point in centers {
            XCTAssertEqual(point.x, 0.7, accuracy: 1e-9)
            XCTAssertEqual(point.y, 0.5, accuracy: 1e-9)
        }
    }

    // MARK: Editing DNA

    func testDNAJitterIsDeterministic() {
        for index in 0..<50 {
            XCTAssertEqual(EditingDNAApplier.jitter(index), EditingDNAApplier.jitter(index))
            XCTAssertLessThanOrEqual(abs(EditingDNAApplier.jitter(index)), 1)
        }
        let dna = EditingDNA(name: "t", averageShotLength: 1, shotLengthSpread: 0.5)
        XCTAssertTrue(EditingDNAApplier.shotLengths(dna, count: 20, minimum: 0.4).allSatisfy { $0 >= 0.4 })
    }

    func testTransitionRateSelection() {
        let picked = (1...8).filter { EditingDNAApplier.cutGetsTransition($0, rate: 0.25) }
        XCTAssertEqual(picked, [4, 8])
        XCTAssertEqual((1...5).filter { EditingDNAApplier.cutGetsTransition($0, rate: 1) }.count, 5)
        XCTAssertTrue((1...5).allSatisfy { !EditingDNAApplier.cutGetsTransition($0, rate: 0) })
    }

    func testLearnDNAFromProject() {
        var project = EditProject(name: "Source", kind: .pro, settings: ProjectSettings(aspect: .portrait9x16))
        var clips = [image(start: 0, duration: 2), image(start: 2, duration: 2), image(start: 4, duration: 2)]
        clips[2].transitionIn = TransitionInstance(kind: .fadeBlack, duration: TimeValue(seconds: 0.4))
        var grade = ColorAdjustments()
        grade.contrast = 20
        for index in clips.indices { clips[index].color = grade }
        project.timeline = Timeline(tracks: [Track(kind: .video, clips: clips)])
        let dna = EditingDNAAnalyzer.extract(from: project, name: "Learned")
        XCTAssertEqual(dna.averageShotLength, 2, accuracy: 1e-9)
        XCTAssertEqual(dna.shotLengthSpread, 0, accuracy: 1e-9)
        XCTAssertEqual(dna.transitionRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(dna.transitionKind, .fadeBlack)
        XCTAssertEqual(dna.color?.contrast ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(dna.aspect, .portrait9x16)
    }

    func testApplyDNAPacingColorAndMotion() throws {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: (0..<4).map { image(start: Double($0) * 5, duration: 5) })])
        var dna = EditingDNA(name: "Fast", averageShotLength: 1, shotLengthSpread: 0, transitionRate: 0, stillMotion: true)
        var grade = ColorAdjustments()
        grade.saturation = 15
        dna.color = grade
        let report = try EditingDNAApplier.apply(dna, options: DNAApplyOptions(), colorMatches: [:], beats: nil,
                                                 to: &timeline, context: context(magnetic: true))
        let clips = sorted(timeline.tracks[0])
        assertClose(clips.map(\.duration.seconds), [1, 1, 1, 1], accuracy: 1e-6)
        XCTAssertEqual(timeline.duration.seconds, 4, accuracy: 1e-6)
        XCTAssertTrue(clips.allSatisfy { $0.color.saturation == 15 })
        XCTAssertTrue(clips.allSatisfy { !$0.transform.scale.keyframes.isEmpty || !$0.transform.position.keyframes.isEmpty })
        XCTAssertEqual(report.graded, 4)
        XCTAssertEqual(report.animated, 4)
    }

    func testApplyDNAWithoutPacingKeepsLengths() throws {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 3), image(start: 3, duration: 3)])])
        let dna = EditingDNA(name: "Soft", averageShotLength: 1, transitionRate: 1, transitionKind: .crossDissolve,
                             transitionDuration: 0.5)
        var options = DNAApplyOptions()
        options.pacing = false
        let report = try EditingDNAApplier.apply(dna, options: options, colorMatches: [:], beats: nil, to: &timeline,
                                                 context: context(magnetic: true))
        let clips = sorted(timeline.tracks[0])
        assertClose(clips.map(\.duration.seconds), [3, 3], accuracy: 1e-6)
        XCTAssertEqual(report.transitions, 1)
        XCTAssertEqual(clips[1].transitionIn?.kind, .crossDissolve)
    }

    // MARK: Quality Inspector

    private func qualityInput(_ timeline: Timeline, assets: [MediaAsset] = [], missing: Set<UUID> = []) -> QualityInput {
        QualityInput(timeline: timeline, settings: ProjectSettings(), assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
                     missing: missing)
    }

    func testQualityFindsFlashFrameGapAndMissingMedia() {
        let missingID = UUID()
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [
            image(start: 0, duration: 2),
            image(start: 2, duration: 1.0 / 30),
            image(start: 3, duration: 2),
            Clip(name: "lost", source: .media(missingID), start: TimeValue(seconds: 5), duration: TimeValue(seconds: 1),
                 sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: 1))
        ])])
        let assets = timeline.tracks[0].clips.compactMap { clip -> MediaAsset? in
            guard case .image(let id) = clip.source else { return nil }
            return makeAsset(id: id, kind: .image, duration: nil)
        }
        let issues = QualityInspector.inspect(qualityInput(timeline, assets: assets))
        XCTAssertTrue(issues.contains { if case .removeClip = $0.fix { return true }; return false })
        XCTAssertTrue(issues.contains { if case .closeGap = $0.fix { return true }; return false })
        XCTAssertTrue(issues.contains { if case .replaceMedia = $0.fix { return true }; return false })
        XCTAssertEqual(issues.first?.severity, .problem)
    }

    func testQualityCloseGapFix() {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 2), image(start: 3, duration: 2)]),
                                         Track(kind: .audio, clips: [media(start: 3, duration: 1)])])
        let gaps = QualityInspector.gapIssues(timeline, frame: 1 / 30.0)
        let fix = try? XCTUnwrap(gaps.first?.fix)
        XCTAssertNotNil(fix)
        if let fix { QualityInspector.apply(fix, to: &timeline, canvas: CGSize(width: 1920, height: 1080), context: context()) }
        XCTAssertTrue(QualityInspector.gapIssues(timeline, frame: 1 / 30.0).isEmpty)
        // Audio after the gap moved with the picture (sync kept).
        XCTAssertEqual(timeline.tracks[1].clips[0].start.seconds, 2, accuracy: 1e-6)
    }

    func testQualityLowResolutionAndGain() {
        let small = UUID()
        var clip = Clip(name: "small", source: .image(small), start: .zero, duration: TimeValue(seconds: 2))
        clip.fitMode = .fill
        var loud = media(start: 0, duration: 2)
        loud.audio.effects.gainDB = 18
        loud.audio.effects.limiter = false
        let timeline = Timeline(tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio, clips: [loud])])
        let issues = QualityInspector.inspect(qualityInput(timeline, assets: [makeAsset(id: small, kind: .image, duration: nil,
                                                                                         width: 640, height: 360),
                                                                               makeAsset(id: asset, kind: .audio)]))
        XCTAssertTrue(issues.contains { $0.category == .picture && $0.clipID == clip.id })
        XCTAssertTrue(issues.contains { if case .enableLimiter = $0.fix { return true }; return false })
    }

    func testExposureFixBrightensDarkShots() throws {
        let clip = image(start: 0, duration: 2)
        let fix = try XCTUnwrap(QualityInspector.exposureFix(clip: clip, luma: 0.05))
        guard case .setColor(_, let color) = fix else { return XCTFail("expected color fix") }
        XCTAssertGreaterThan(color.exposure, 0)
        XCTAssertNil(QualityInspector.exposureFix(clip: clip, luma: 0.4))
    }

    // MARK: Multi-format variants

    func testCenteredCropForAspect() {
        let crop = OutputVariants.centeredCrop(in: .full, sourceWidth: 1920, sourceHeight: 1080, targetAspect: 1)
        XCTAssertEqual(crop.width, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(crop.x, (1 - 0.5625) / 2, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 1, accuracy: 1e-9)
    }

    func testVariantReframesFullFrameAndKeepsOriginal() {
        var project = EditProject(name: "Landscape", kind: .pro, settings: ProjectSettings(aspect: .landscape16x9))
        var text = TextContent(text: "Hello")
        text.style.sizeRatio = 0.08
        let title = Clip(name: "title", source: .text(text), start: .zero, duration: TimeValue(seconds: 2))
        project.timeline = Timeline(tracks: [Track(kind: .video, clips: [media(start: 0, duration: 4)]),
                                             Track(kind: .text, clips: [title])])
        var report = VariantReport()
        let variant = OutputVariants.makeVariant(of: project, format: .vertical, options: VariantOptions(method: .center, smoothing: 0.8),
                                                 assets: [asset: makeAsset(id: asset)], subjectTrack: { _ in nil },
                                                 report: &report)
        XCTAssertNotEqual(variant.id, project.id)
        XCTAssertEqual(variant.settings.canvasWidth, 1080)
        XCTAssertEqual(variant.settings.canvasHeight, 1920)
        let clip = variant.timeline.tracks[0].clips[0]
        XCTAssertEqual(clip.crop.base.width, 0.31640625, accuracy: 1e-6)
        XCTAssertEqual(clip.fitMode, .fill)
        XCTAssertEqual(report.reframed, 1)
        if case .text(let content) = variant.timeline.tracks[1].clips[0].source {
            XCTAssertEqual(content.style.sizeRatio, 0.08 * 0.5625, accuracy: 1e-6)
        } else {
            XCTFail("title missing")
        }
        // Source project untouched.
        XCTAssertTrue(project.timeline.tracks[0].clips[0].crop.base.isFull)
    }

    // MARK: Templates

    func testTemplateSlotsAndFill() {
        var project = EditProject(name: "Promo", kind: .pro)
        let music = UUID()
        project.timeline = Timeline(tracks: [
            Track(kind: .video, clips: [media(start: 0, duration: 2), image(start: 2, duration: 3), media(start: 5, duration: 2)]),
            Track(kind: .audio, clips: [media(start: 0, duration: 7, assetID: music)])
        ])
        let template = StudioTemplateLibrary.makeTemplate(from: project, name: "", note: "", keepAudio: true)
        XCTAssertEqual(template.name, "Promo")
        XCTAssertEqual(template.slots.map(\.index), [1, 2, 3])

        let photo = makeAsset(id: UUID(), kind: .image, duration: nil)
        let shortVideo = makeAsset(id: UUID(), kind: .video, duration: 1)
        var report = TemplateFillReport()
        let slots = template.slots.sorted { $0.index < $1.index }
        let filled = StudioTemplateLibrary.fill(template, assignments: [slots[0].clipID: shortVideo, slots[1].clipID: photo],
                                                available: [music], context: context(magnetic: true,
                                                                                    durations: [shortVideo.id: 1, music: 60]),
                                                report: &report)
        XCTAssertEqual(report.filled, 2)
        XCTAssertEqual(report.removedEmpty, 1)
        XCTAssertEqual(report.slowed, 1)
        let video = sorted(filled.tracks[0])
        XCTAssertEqual(video.count, 2)
        XCTAssertEqual(video[0].duration.seconds, 2, accuracy: 1 / 30.0)
        XCTAssertEqual(video[0].speed.rate, 0.5, accuracy: 1e-6)
        if case .image(let id) = video[1].source { XCTAssertEqual(id, photo.id) } else { XCTFail("photo not placed") }
        XCTAssertEqual(filled.tracks[1].clips.count, 1)
    }

    func testTemplateDropsMissingAudio() {
        var project = EditProject(name: "P", kind: .pro)
        project.timeline = Timeline(tracks: [Track(kind: .video, clips: [image(start: 0, duration: 2)]),
                                             Track(kind: .audio, clips: [media(start: 0, duration: 2)])])
        let template = StudioTemplateLibrary.makeTemplate(from: project, name: "T", note: "", keepAudio: true)
        var report = TemplateFillReport()
        let photo = makeAsset(id: UUID(), kind: .image, duration: nil)
        let filled = StudioTemplateLibrary.fill(template, assignments: [template.slots[0].clipID: photo], available: [],
                                                context: context(magnetic: true), report: &report)
        XCTAssertEqual(report.droppedMissingAudio, 1)
        XCTAssertTrue(filled.tracks[1].clips.isEmpty)
    }

    // MARK: Voice / background separation

    private func runSeparator(left: [Float], right: [Float], method: SeparationMethod)
        throws -> (voice: [[Float]], background: [[Float]]) {
        let separator = SpectralVoiceSeparator(channels: 2, sampleRate: 44_100, method: method, model: nil)
        var interleaved = [Float](repeating: 0, count: left.count * 2)
        for i in left.indices {
            interleaved[2 * i] = left[i]
            interleaved[2 * i + 1] = right[i]
        }
        var voice: [[Float]] = [[], []]
        var background: [[Float]] = [[], []]
        let chunk = 4096
        var offset = 0
        while offset < interleaved.count {
            let end = min(interleaved.count, offset + chunk)
            try interleaved[offset..<end].withUnsafeBufferPointer { try separator.append(interleaved: $0) }
            let out = separator.drainOutput()
            for c in 0..<2 { voice[c] += out.voice[c]; background[c] += out.background[c] }
            offset = end
        }
        try separator.finish()
        let out = separator.drainOutput()
        for c in 0..<2 {
            voice[c] = Array((voice[c] + out.voice[c]).prefix(left.count))
            background[c] = Array((background[c] + out.background[c]).prefix(left.count))
        }
        return (voice, background)
    }

    private func energy(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) }
    }

    func testSeparationStemsAddUpToOriginal() throws {
        var generator = SystemRandomNumberGenerator()
        let left = (0..<30_000).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        let right = (0..<30_000).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        let stems = try runSeparator(left: left, right: right, method: .stereo)
        XCTAssertEqual(stems.voice[0].count, left.count)
        for i in stride(from: 0, to: left.count, by: 97) {
            XCTAssertEqual(stems.voice[0][i] + stems.background[0][i], left[i], accuracy: 1e-5)
            XCTAssertEqual(stems.voice[1][i] + stems.background[1][i], right[i], accuracy: 1e-5)
        }
    }

    func testCentreToneIsVoiceSideToneIsBackground() throws {
        let count = 44_100
        let tone = (0..<count).map { Float(0.4 * sin(2 * Double.pi * 1_000 * Double($0) / 44_100)) }
        let centred = try runSeparator(left: tone, right: tone, method: .stereo)
        let middle = 8_000..<36_000
        let voiceShare = energy(centred.voice[0][middle]) / energy(tone[middle])
        XCTAssertGreaterThan(voiceShare, 0.9)

        let inverted = tone.map { -$0 }
        let wide = try runSeparator(left: tone, right: inverted, method: .stereo)
        let wideShare = energy(wide.voice[0][middle]) / energy(tone[middle])
        XCTAssertLessThan(wideShare, 0.05)
    }

    func testAutomaticMethodChoice() {
        XCTAssertEqual(SourceSeparator.resolvedMethod(.stereo, channels: 1, sideRatio: 0), .voiceFocus)
        XCTAssertEqual(SourceSeparator.resolvedMethod(.stereo, channels: 2, sideRatio: 0.0001), .voiceFocus)
        XCTAssertEqual(SourceSeparator.resolvedMethod(.stereo, channels: 2, sideRatio: 0.2), .stereo)
        XCTAssertEqual(SourceSeparator.resolvedMethod(.voiceFocus, channels: 2, sideRatio: 0.2), .voiceFocus)
    }
}

private func assertClose(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
