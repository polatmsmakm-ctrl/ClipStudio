//
//  CoreModelTests.swift
//  ClipStudioTests
//
//  Time math, keyframes, speed ramps, formatting (English digits), geometry,
//  forward-compatible decoding.
//

import XCTest
import CoreMedia
@testable import ClipStudio

final class CoreModelTests: XCTestCase {
    func testTimeValueArithmeticAndEquality() {
        let a = TimeValue(seconds: 1.5)
        let b = TimeValue(value: 3, timescale: 2)
        XCTAssertEqual(a, b)
        XCTAssertEqual((a + b).seconds, 3, accuracy: 0.0001)
        XCTAssertEqual((a - TimeValue(seconds: 0.5)).seconds, 1, accuracy: 0.0001)
        XCTAssertTrue(TimeValue(seconds: 1) < TimeValue(seconds: 2))
    }

    func testFrameSnapping() {
        let t = TimeValue(seconds: 1.019).snapped(toFrameRate: 30)
        XCTAssertEqual(t.seconds, 31.0 / 30.0, accuracy: 0.0001)
    }

    func testKeyframeInterpolationAndHold() {
        var value = KeyframedValue(0.0)
        value.addKeyframe(at: 0, value: 0, easing: .linear)
        value.addKeyframe(at: 2, value: 10, easing: .hold)
        value.addKeyframe(at: 4, value: 20)
        XCTAssertEqual(value.value(at: 1), 5, accuracy: 0.0001)
        XCTAssertEqual(value.value(at: 3), 10, accuracy: 0.0001)
        XCTAssertEqual(value.value(at: 10), 20, accuracy: 0.0001)
        XCTAssertEqual(value.value(at: -1), 0, accuracy: 0.0001)
    }

    func testKeyframeReplacesWithinTolerance() {
        var value = KeyframedValue(1.0)
        value.addKeyframe(at: 1, value: 2)
        value.addKeyframe(at: 1.001, value: 3)
        XCTAssertEqual(value.keyframes.count, 1)
        XCTAssertEqual(value.value(at: 1), 3, accuracy: 0.0001)
    }

    func testSpeedConstantDuration() {
        var speed = SpeedSettings()
        speed.rate = 2
        XCTAssertEqual(speed.timelineDuration(forSource: TimeValue(seconds: 10)).seconds, 5, accuracy: 0.001)
    }

    func testSpeedRampSegmentsCoverSource() {
        var speed = SpeedSettings()
        speed.ramp = [SpeedRampPoint(position: 0, rate: 1), SpeedRampPoint(position: 1, rate: 3)]
        let source = CMTimeRange(start: .zero, duration: CMTime(seconds: 12, preferredTimescale: 600))
        let segments = speed.segments(for: source)
        XCTAssertEqual(segments.count, SpeedSettings.rampSteps)
        let total = segments.reduce(0) { $0 + $1.range.duration.seconds }
        XCTAssertEqual(total, 12, accuracy: 0.01)
        XCTAssertLessThan(speed.timelineDuration(forSource: TimeValue(seconds: 12)).seconds, 12)
    }

    func testFormattingUsesEnglishDigits() {
        XCTAssertEqual(Fmt.duration(3725), "1:02:05")
        XCTAssertEqual(Fmt.timecode(1.5, fps: 30), "00:00:01:15")
        XCTAssertEqual(Fmt.percent(0.426), "43%")
        XCTAssertEqual(Fmt.parseNumber("١٢٫٥"), 12.5)
        XCTAssertEqual(Fmt.parseNumberList("15، 30, 45"), [15, 30, 45])
    }

    func testAspectCanvasSizes() {
        XCTAssertEqual(AspectRatio.portrait9x16.canvasSize(shortSide: 1080), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(AspectRatio.landscape16x9.canvasSize(shortSide: 720), CGSize(width: 1280, height: 720))
        XCTAssertEqual(AspectRatio.reduced(width: 1920, height: 1080), .landscape16x9)
    }

    func testExportGeometryKeepsEvenDimensions() {
        let size = ExportGeometry.outputSize(canvas: CGSize(width: 1081, height: 1921), resolution: .p720)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(size.width, 720)
    }

    func testBitrateScalesWithCodec() {
        var settings = ExportSettings()
        settings.quality = .high
        let size = CGSize(width: 1920, height: 1080)
        settings.codec = .h264
        let h264 = BitrateCalculator.videoBitrate(size: size, fps: 30, settings: settings)
        settings.codec = .hevc
        let hevc = BitrateCalculator.videoBitrate(size: size, fps: 30, settings: settings)
        XCTAssertLessThan(hevc, h264)
        XCTAssertGreaterThan(h264, 3_000_000)
    }

    func testClipDecodesWithMissingNewFields() throws {
        let json = """
        {"id":"9E1F7C52-6C35-4E2B-A5D2-2B6E7C7A3F10","source":{"solidColor":{"_0":{"r":1,"g":0,"b":0,"a":1}}}}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.blendMode, .normal)
        XCTAssertTrue(clip.isEnabled)
        XCTAssertEqual(clip.transform, .identity)
    }

    func testProjectRoundTrip() throws {
        var project = EditProject(name: "اختبار", kind: .story)
        project.story = StoryConfig(sourceAssetID: UUID())
        let data = try JSONStore.makeEncoder().encode(project)
        let decoded = try JSONStore.makeDecoder().decode(EditProject.self, from: data)
        XCTAssertEqual(decoded.name, "اختبار")
        XCTAssertEqual(decoded.kind, .story)
        XCTAssertNotNil(decoded.story)
    }

    func testRectConversionToCoreImageSpace() {
        let rect = RectValue(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let ci = rect.ciRect(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(ci, CGRect(x: 10, y: 30, width: 50, height: 50))
    }

    func testMergeTimelineOverlapsForTransitions() throws {
        let a = MediaAsset(id: UUID(), kind: .video, displayName: "A", originalFilename: "a.mov", storedFileName: "a.mov",
                           importedAt: Date(), fileSize: 1, durationSeconds: 10, pixelWidth: 1920, pixelHeight: 1080,
                           frameRate: 30, videoCodec: "H.264", audioCodec: "AAC", hasAudio: true, estimatedBitrate: nil, fingerprint: "a")
        var b = a
        b.id = UUID()
        var config = MergeConfig()
        config.items = [MergeItem(assetID: a.id), MergeItem(assetID: b.id)]
        config.transition = .crossDissolve
        config.transitionDuration = 1
        let (timeline, settings) = try MergeTimelineFactory.make(config: config, assets: [a.id: a, b.id: b])
        XCTAssertEqual(timeline.duration.seconds, 19, accuracy: 0.001)
        XCTAssertEqual(timeline.tracks[0].clips[1].start.seconds, 9, accuracy: 0.001)
        XCTAssertEqual(settings.canvasWidth, 1920)
    }
}
