//
//  StudioEngineTests.swift
//  ClipStudioTests
//
//  Pro Studio editing engine: split (speed / reverse / ramps), trims with source
//  limits, ripple and magnetic deletes, transitions, overwrite, moves between
//  tracks, freeze frames, join, magnetic insert next to transitions, keyframe
//  splitting, snapping, undo coalescing, timecode parsing and project decoding.
//

import XCTest
@testable import ClipStudio

final class StudioEngineTests: XCTestCase {
    private let asset = UUID()

    private func context(magnetic: Bool = false) -> EditContext {
        EditContext(assetDurations: [asset: 100], frameRate: 30, magnetic: magnetic)
    }

    private func media(start: Double, duration: Double, sourceStart: Double = 0, id: UUID = UUID()) -> Clip {
        Clip(id: id, name: "clip", source: .media(asset), start: TimeValue(seconds: start), duration: TimeValue(seconds: duration),
             sourceRange: TimeRangeValue(startSeconds: sourceStart, endSeconds: sourceStart + duration))
    }

    private func sorted(_ track: Track) -> [Clip] { track.clips.sorted { $0.start < $1.start } }

    // MARK: Split

    func testSplitConstantSpeedKeepsSourceContinuity() throws {
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [media(start: 0, duration: 10, sourceStart: 5)])])
        let created = try TimelineEngine.split([], at: 4, in: &timeline, context: context())
        XCTAssertEqual(created.count, 1)
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(clips[0].sourceRange?.end.seconds ?? 0, 9, accuracy: 1e-6)
        XCTAssertEqual(clips[1].start.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(clips[1].sourceRange?.start.seconds ?? 0, 9, accuracy: 1e-6)
        XCTAssertEqual(clips[1].sourceRange?.duration.seconds ?? 0, 6, accuracy: 1e-6)
    }

    func testSplitAtDoubleSpeedMapsSourceTime() throws {
        var clip = Clip(name: "fast", source: .media(asset), start: .zero, duration: TimeValue(seconds: 10),
                        sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: 20))
        clip.speed.rate = 2
        let parts = try TimelineEngine.split(clip, at: 5, context: context())
        XCTAssertEqual(parts.0.sourceRange?.end.seconds ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(parts.1.sourceRange?.start.seconds ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(parts.1.sourceRange?.end.seconds ?? 0, 20, accuracy: 1e-6)
    }

    func testSplitReversedClip() throws {
        var clip = media(start: 0, duration: 10, sourceStart: 10)
        clip.speed.isReversed = true
        let parts = try TimelineEngine.split(clip, at: 3, context: context())
        XCTAssertEqual(parts.0.sourceRange?.start.seconds ?? 0, 17, accuracy: 1e-6)
        XCTAssertEqual(parts.0.sourceRange?.end.seconds ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(parts.1.sourceRange?.start.seconds ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(parts.1.sourceRange?.end.seconds ?? 0, 17, accuracy: 1e-6)
    }

    func testSplitRampKeepsSourceContiguous() throws {
        var clip = Clip(name: "ramp", source: .media(asset), start: .zero, duration: TimeValue(seconds: 8),
                        sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: 12))
        clip.speed.ramp = [SpeedRampPoint(position: 0, rate: 1), SpeedRampPoint(position: 1, rate: 3)]
        clip.recomputeDurationFromSpeed()
        let parts = try TimelineEngine.split(clip, at: clip.duration.seconds / 2, context: context())
        XCTAssertEqual(parts.0.sourceRange?.end.seconds ?? -1, parts.1.sourceRange?.start.seconds ?? -2, accuracy: 1e-6)
        let total = (parts.0.sourceRange?.duration.seconds ?? 0) + (parts.1.sourceRange?.duration.seconds ?? 0)
        XCTAssertEqual(total, 12, accuracy: 1e-6)
        XCTAssertEqual(parts.1.start, parts.0.end)
    }

    func testSplitOutsideClipThrows() {
        let clip = media(start: 0, duration: 2)
        XCTAssertThrowsError(try TimelineEngine.split(clip, at: 5, context: context()))
    }

    // MARK: Trim

    func testTrimStartExtensionIsLimitedBySource() {
        let clip = media(start: 5, duration: 10, sourceStart: 2)
        let trimmed = TimelineEngine.trimmedStart(clip, to: 0, context: context())
        XCTAssertEqual(trimmed.start.seconds, 3, accuracy: 1e-6)
        XCTAssertEqual(trimmed.duration.seconds, 12, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceRange?.start.seconds ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(trimmed.id, clip.id)
    }

    func testTrimEndShortens() {
        let clip = media(start: 5, duration: 10, sourceStart: 2)
        let trimmed = TimelineEngine.trimmedEnd(clip, to: 8, context: context())
        XCTAssertEqual(trimmed.duration.seconds, 3, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceRange?.end.seconds ?? 0, 5, accuracy: 1e-6)
    }

    func testTrimEndExtensionLimitedByAssetDuration() {
        let clip = media(start: 0, duration: 10, sourceStart: 85)
        let trimmed = TimelineEngine.trimmedEnd(clip, to: 30, context: context())
        XCTAssertEqual(trimmed.sourceRange?.end.seconds ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(trimmed.duration.seconds, 15, accuracy: 1e-6)
    }

    // MARK: Delete

    func testRippleDeleteClosesGapOnFreeTrack() throws {
        let a = media(start: 0, duration: 5), b = media(start: 5, duration: 5), c = media(start: 10, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a, b, c])])
        try TimelineEngine.delete([b.id], ripple: true, in: &timeline, context: context())
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[1].start.seconds, 5, accuracy: 1e-6)
    }

    func testPlainDeleteKeepsGapOnFreeTrack() throws {
        let a = media(start: 0, duration: 5), b = media(start: 5, duration: 5), c = media(start: 10, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a, b, c])])
        try TimelineEngine.delete([b.id], ripple: false, in: &timeline, context: context())
        XCTAssertEqual(sorted(timeline.tracks[0])[1].start.seconds, 10, accuracy: 1e-6)
    }

    func testMagneticPrimaryNeverKeepsGaps() throws {
        let a = media(start: 0, duration: 5), b = media(start: 5, duration: 5), c = media(start: 10, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [a, b, c])])
        try TimelineEngine.delete([b.id], ripple: false, in: &timeline, context: context(magnetic: true))
        XCTAssertEqual(sorted(timeline.tracks[0])[1].start.seconds, 5, accuracy: 1e-6)
    }

    // MARK: Transitions

    func testTransitionCreatesOverlapAndRipples() throws {
        let a = media(start: 0, duration: 5), b = media(start: 5, duration: 5), c = media(start: 10, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a, b, c])])
        try TimelineEngine.setTransition(.crossDissolve, duration: 1, forClip: b.id, in: &timeline, context: context())
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips[1].start.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(clips[1].transitionIn?.duration.seconds ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(clips[2].start.seconds, 9, accuracy: 1e-6)

        try TimelineEngine.setTransition(.none, duration: 0, forClip: b.id, in: &timeline, context: context())
        let restored = sorted(timeline.tracks[0])
        XCTAssertNil(restored[1].transitionIn)
        XCTAssertEqual(restored[1].start.seconds, 5, accuracy: 1e-6)
        XCTAssertEqual(restored[2].start.seconds, 10, accuracy: 1e-6)
    }

    func testTransitionNeedsPreviousClip() {
        let a = media(start: 0, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a])])
        XCTAssertThrowsError(try TimelineEngine.setTransition(.crossDissolve, duration: 1, forClip: a.id, in: &timeline, context: context()))
    }

    func testMagneticInsertAtCutDoesNotSplitTransitionedClip() throws {
        let a = media(start: 0, duration: 5)
        var b = media(start: 4.5, duration: 5, sourceStart: 20)
        b.transitionIn = TransitionInstance(kind: .crossDissolve, duration: TimeValue(seconds: 0.5))
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [a, b])])
        let x = Clip(name: "x", source: .solidColor(.white), start: .zero, duration: TimeValue(seconds: 2))
        try TimelineEngine.place([x], onTrack: 0, at: 5, mode: .insert, in: &timeline, context: context(magnetic: true))
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[1].id, x.id)
        XCTAssertEqual(clips[1].start.seconds, 5, accuracy: 1e-6)
        XCTAssertEqual(clips[2].id, b.id)
        XCTAssertEqual(clips[2].start.seconds, 6.5, accuracy: 1e-6)
    }

    // MARK: Overwrite, move, freeze, join

    func testOverwriteCarvesExistingClip() throws {
        let x = media(start: 0, duration: 10)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [x])])
        let y = Clip(name: "y", source: .solidColor(.black), start: .zero, duration: TimeValue(seconds: 2))
        try TimelineEngine.place([y], onTrack: 0, at: 4, mode: .overwrite, in: &timeline, context: context())
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[0].end.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(clips[1].id, y.id)
        XCTAssertEqual(clips[2].start.seconds, 6, accuracy: 1e-6)
        XCTAssertEqual(clips[2].sourceRange?.start.seconds ?? 0, 6, accuracy: 1e-6)
    }

    func testMoveToAnotherTrack() throws {
        let a = media(start: 0, duration: 5)
        var timeline = Timeline(tracks: [Track(kind: .video, clips: [a]), Track(kind: .overlay)])
        try TimelineEngine.move([ClipMove(clipID: a.id, newStart: 2, destination: .existing(1))], in: &timeline, context: context())
        XCTAssertTrue(timeline.tracks[0].clips.isEmpty)
        XCTAssertEqual(timeline.tracks[1].clips.first?.start.seconds ?? 0, 2, accuracy: 1e-6)
    }

    func testMoveRejectsIncompatibleTrack() {
        let text = Clip(name: "t", source: .adjustment, start: .zero, duration: TimeValue(seconds: 2))
        var timeline = Timeline(tracks: [Track(kind: .adjustment, clips: [text]), Track(kind: .audio)])
        XCTAssertThrowsError(try TimelineEngine.move([ClipMove(clipID: text.id, newStart: 0, destination: .existing(1))],
                                                     in: &timeline, context: context()))
    }

    func testFreezeFrameInsertsAndRipples() throws {
        let a = media(start: 0, duration: 10)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a])])
        let freezeID = try TimelineEngine.insertFreezeFrame(of: a.id, at: 4, duration: 2, in: &timeline, context: context())
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[1].id, freezeID)
        XCTAssertEqual(clips[1].duration.seconds, 2, accuracy: 1e-6)
        if case .freezeFrame(_, let time) = clips[1].source {
            XCTAssertEqual(time.seconds, 4, accuracy: 1e-6)
        } else {
            XCTFail("expected freeze frame")
        }
        XCTAssertEqual(clips[2].start.seconds, 6, accuracy: 1e-6)
        XCTAssertEqual(clips[2].end.seconds, 12, accuracy: 1e-6)
    }

    func testJoinUndoesSplit() throws {
        let x = media(start: 0, duration: 10)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [x])])
        let created = try TimelineEngine.split([x.id], at: 4, in: &timeline, context: context())
        let right = try XCTUnwrap(created.first)
        try TimelineEngine.join(x.id, right, in: &timeline, context: context())
        XCTAssertEqual(timeline.tracks[0].clips.count, 1)
        let merged = timeline.tracks[0].clips[0]
        XCTAssertEqual(merged.duration.seconds, 10, accuracy: 1e-6)
        XCTAssertEqual(merged.sourceRange?.start.seconds ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(merged.sourceRange?.end.seconds ?? -1, 10, accuracy: 1e-6)
    }

    func testDuplicatePlacesCopyAfterSelection() throws {
        let a = media(start: 0, duration: 4), b = media(start: 4, duration: 4)
        var timeline = Timeline(tracks: [Track(kind: .overlay, clips: [a, b])])
        let copies = try TimelineEngine.duplicate([a.id], in: &timeline, context: context())
        XCTAssertEqual(copies.count, 1)
        let clips = sorted(timeline.tracks[0])
        XCTAssertEqual(clips[1].id, copies[0])
        XCTAssertEqual(clips[1].start.seconds, 4, accuracy: 1e-6)
        XCTAssertEqual(clips[2].start.seconds, 8, accuracy: 1e-6)
    }

    // MARK: Keyframes, snapping, timecode

    func testKeyframeSplitPreservesValues() {
        var value = KeyframedValue(0.0)
        value.addKeyframe(at: 0, value: 0, easing: .linear)
        value.addKeyframe(at: 4, value: 8, easing: .linear)
        let parts = value.split(at: 2)
        XCTAssertEqual(parts.left.value(at: 2), 4, accuracy: 1e-6)
        XCTAssertEqual(parts.right.value(at: 0), 4, accuracy: 1e-6)
        XCTAssertEqual(parts.right.value(at: 2), 8, accuracy: 1e-6)
    }

    func testSnappingPrefersClosestEdge() {
        let targets = [SnapPoint(time: 10, kind: .clipEdge)]
        XCTAssertEqual(SnapEngine.snapRange(start: 9.9, duration: 2, to: targets, tolerance: 0.2).value, 10, accuracy: 1e-6)
        XCTAssertEqual(SnapEngine.snapRange(start: 7.95, duration: 2, to: targets, tolerance: 0.2).value, 8, accuracy: 1e-6)
        XCTAssertNil(SnapEngine.snap(5, to: targets, tolerance: 0.2).guide)
    }

    func testTimecodeParsing() {
        XCTAssertEqual(TimecodeParser.parse("00:00:01:15", fps: 30, current: 0) ?? -1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(TimecodeParser.parse("1:20", fps: 30, current: 0) ?? -1, 80, accuracy: 1e-6)
        XCTAssertEqual(TimecodeParser.parse("+2s", fps: 30, current: 10) ?? -1, 12, accuracy: 1e-6)
        XCTAssertEqual(TimecodeParser.parse("-10f", fps: 30, current: 1) ?? -1, 1 - 10.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(TimecodeParser.parse("١٢٫٥", fps: 30, current: 0) ?? -1, 12.5, accuracy: 1e-6)
        XCTAssertNil(TimecodeParser.parse("abc", fps: 30, current: 0))
    }

    // MARK: Undo & project model

    @MainActor
    func testUndoCoalescingAndRedo() {
        let stack = UndoStack()
        let project = EditProject(name: "a", kind: .pro)
        XCTAssertTrue(stack.record(before: project, name: "edit", coalesceKey: "slider"))
        XCTAssertFalse(stack.record(before: project, name: "edit", coalesceKey: "slider"))
        stack.breakCoalescing()
        XCTAssertTrue(stack.record(before: project, name: "edit", coalesceKey: "slider"))
        XCTAssertEqual(stack.undoEntries.count, 2)
        var current = project
        current.name = "b"
        let entry = stack.undo(current: current)
        XCTAssertEqual(entry?.snapshot.name, "a")
        XCTAssertTrue(stack.canRedo)
        XCTAssertEqual(stack.redo(current: project)?.snapshot.name, "b")
    }

    func testOldProjectDecodesWithStudioDefaults() throws {
        let json = """
        {"id":"7D3B8E52-1C35-4E2B-A5D2-2B6E7C7A3F10","name":"قديم","kind":"pro"}
        """
        let project = try JSONStore.makeDecoder().decode(EditProject.self, from: Data(json.utf8))
        XCTAssertTrue(project.compounds.isEmpty)
        XCTAssertEqual(project.studio.pixelsPerSecond, 60, accuracy: 1e-6)
        XCTAssertEqual(project.timeline.tracks.count, 2)
    }

    func testCompoundAssetsAreReferenced() {
        var project = EditProject(name: "p", kind: .pro)
        var compound = CompoundClip(name: "c", timeline: Timeline(tracks: [Track(kind: .video, clips: [media(start: 0, duration: 3)])]))
        let rendered = UUID()
        compound.renderedAssetID = rendered
        project.compounds = [compound]
        XCTAssertTrue(project.referencedAssetIDs.contains(asset))
        XCTAssertTrue(project.referencedAssetIDs.contains(rendered))
    }
}
