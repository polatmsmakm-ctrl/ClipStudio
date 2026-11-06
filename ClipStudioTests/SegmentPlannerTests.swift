//
//  SegmentPlannerTests.swift
//  ClipStudioTests
//

import XCTest
@testable import ClipStudio

final class SegmentPlannerTests: XCTestCase {
    private func assertContiguous(_ ranges: [PlannedRange], duration: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ranges.first?.start ?? -1, 0, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(ranges.last?.end ?? -1, duration, accuracy: 0.0001, file: file, line: line)
        for i in 1..<ranges.count {
            XCTAssertEqual(ranges[i].start, ranges[i - 1].end, accuracy: 0.0001, file: file, line: line)
        }
    }

    func testMaxDurationBalancesEqualParts() {
        var rule = SplitRule()
        rule.mode = .maxDuration
        rule.seconds = 60
        let ranges = SegmentPlanner.plan(duration: 150, rule: rule)
        XCTAssertEqual(ranges.count, 3)
        for range in ranges { XCTAssertEqual(range.duration, 50, accuracy: 0.0001) }
        assertContiguous(ranges, duration: 150)
    }

    func testMaxDurationExactMultiple() {
        var rule = SplitRule()
        rule.mode = .maxDuration
        rule.seconds = 30
        XCTAssertEqual(SegmentPlanner.plan(duration: 90, rule: rule).count, 3)
    }

    func testShortVideoIsSingleSegment() {
        var rule = SplitRule()
        rule.seconds = 60
        let ranges = SegmentPlanner.plan(duration: 20, rule: rule)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].duration, 20, accuracy: 0.0001)
    }

    func testFixedDurationRemainderAndTailMerge() {
        var rule = SplitRule()
        rule.mode = .fixedDuration
        rule.seconds = 15
        rule.minimumTail = 2
        // 46 s → 15, 15, 15, 1 → tail (1 s) cannot merge (would exceed 15) → stays.
        let ranges = SegmentPlanner.plan(duration: 46, rule: rule)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.last?.duration ?? 0, 1, accuracy: 0.0001)
        assertContiguous(ranges, duration: 46)
    }

    func testTailMergesWhenNoLimit() {
        var rule = SplitRule()
        rule.mode = .customDurations
        rule.customDurations = [10]
        rule.minimumTail = 3
        // 21 s → 10, 10, 1 → tail merges → 10, 11
        let ranges = SegmentPlanner.plan(duration: 21, rule: rule)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.last?.duration ?? 0, 11, accuracy: 0.0001)
    }

    func testEqualParts() {
        var rule = SplitRule()
        rule.mode = .equalParts
        rule.parts = 4
        let ranges = SegmentPlanner.plan(duration: 100, rule: rule)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges[2].start, 50, accuracy: 0.0001)
    }

    func testCustomDurationsRepeatLastValue() {
        var rule = SplitRule()
        rule.mode = .customDurations
        rule.customDurations = [5, 10]
        rule.minimumTail = 0
        let ranges = SegmentPlanner.plan(duration: 30, rule: rule)
        XCTAssertEqual(ranges.map { ($0.duration * 1000).rounded() / 1000 }, [5, 10, 10, 5])
    }

    func testHardMaximumSplitsLongParts() {
        var rule = SplitRule()
        rule.mode = .equalParts
        rule.parts = 2
        rule.hardMaximum = 30
        let ranges = SegmentPlanner.plan(duration: 100, rule: rule)
        XCTAssertTrue(ranges.allSatisfy { $0.duration <= 30.0001 })
        assertContiguous(ranges, duration: 100)
    }

    func testSnappingMovesToNearestPointWithinTolerance() {
        var rule = SplitRule()
        rule.mode = .equalParts
        rule.parts = 2
        rule.snap = .scenes
        rule.snapTolerance = 2
        let ranges = SegmentPlanner.plan(duration: 100, rule: rule, snapPoints: [20, 51.2, 80])
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].end, 51.2, accuracy: 0.0001)
    }

    func testSnappingIgnoresPointsOutsideTolerance() {
        var rule = SplitRule()
        rule.mode = .equalParts
        rule.parts = 2
        rule.snap = .pauses
        rule.snapTolerance = 1
        let ranges = SegmentPlanner.plan(duration: 100, rule: rule, snapPoints: [45])
        XCTAssertEqual(ranges[0].end, 50, accuracy: 0.0001)
    }

    func testSnappingRespectsMaximum() {
        var rule = SplitRule()
        rule.mode = .maxDuration
        rule.seconds = 30
        rule.snap = .scenes
        rule.snapTolerance = 5
        // Base cuts at 30, 60; a snap to 33 would make the first segment 33 s > 30 → rejected.
        let ranges = SegmentPlanner.plan(duration: 90, rule: rule, snapPoints: [33, 58])
        XCTAssertTrue(ranges.allSatisfy { $0.duration <= 30.0001 })
    }

    func testZeroDuration() {
        XCTAssertTrue(SegmentPlanner.plan(duration: 0, rule: SplitRule()).isEmpty)
    }
}
