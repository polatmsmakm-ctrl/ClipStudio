//
//  SplitterViewModel.swift
//  ClipStudio — Features/Stories (Smart Video Splitter)
//
//  Owns one story project: rule editing, platform presets, local smart-cut
//  analysis (scenes / pauses / keyframes), manual cut adjustment, gallery
//  operations (rename, delete, reorder) and one-tap export of all clips.
//  Every change autosaves.
//

import Foundation
import SwiftUI
import CoreGraphics

@MainActor
@Observable
final class SplitterViewModel {
    let env: AppEnvironment
    private(set) var project: EditProject
    let player = PlayerController()
    private(set) var asset: MediaAsset?
    var selectedSegmentID: UUID?

    private(set) var scenes: [Double] = []
    private(set) var pauses: [Double] = []
    private(set) var keyframes: [Double] = []
    private(set) var analysisProgress: Double?
    private(set) var analysisTitle = ""
    private var analysisTask: Task<Void, Never>?

    var customDurationsText: String
    var pendingReplanConfirmation = false

    init?(projectID: UUID, env: AppEnvironment) {
        guard let loaded = env.projects.load(projectID), let story = loaded.story else { return nil }
        self.env = env
        self.project = loaded
        self.asset = env.library.asset(story.sourceAssetID)
        self.customDurationsText = story.rule.customDurations.map { Fmt.number($0, digits: $0.rounded() == $0 ? 0 : 1) }.joined(separator: ", ")
        if let asset, let url = env.library.url(forID: asset.id), !env.library.isMissing(asset) {
            player.frameRate = asset.frameRate ?? 30
            player.load(url: url)
        }
        scenes = AnalysisCache.loadTimes(story.sourceAssetID, kind: "scenes") ?? []
        pauses = AnalysisCache.loadSilences(story.sourceAssetID)?.map(\.midpoint) ?? []
        keyframes = AnalysisCache.loadTimes(story.sourceAssetID, kind: "keyframes") ?? []
        env.projects.beginSession(projectID)
        if story.segments.isEmpty { replan(force: true) }
    }

    // MARK: Accessors

    var story: StoryConfig { project.story ?? StoryConfig(sourceAssetID: UUID()) }
    var duration: Double { asset?.durationSeconds ?? 0 }
    var segments: [StorySegment] { story.segments }
    var includedSegments: [StorySegment] { story.segments.filter(\.isIncluded) }
    var isSourceMissing: Bool { asset.map { env.library.isMissing($0) } ?? true }
    var preset: PlatformPreset? { env.presets.preset(key: story.presetKey) }
    var frameRate: Double { asset?.frameRate ?? 30 }

    var snapPoints: [Double] {
        switch story.rule.snap {
        case .none: []
        case .scenes: scenes
        case .pauses: pauses
        case .keyframes: keyframes
        }
    }

    var hasAnalysis: Bool { !snapPoints.isEmpty || story.rule.snap == .none }

    var canFastCopy: Bool { story.aspect == nil }

    var effectiveMode: StoryExportMode { canFastCopy ? story.exportMode : .reencode }

    var outputSize: CGSize? {
        guard let asset else { return nil }
        if effectiveMode == .fastCopy {
            return CGSize(width: asset.pixelWidth ?? 0, height: asset.pixelHeight ?? 0)
        }
        let canvas = StoryTimelineFactory.canvas(for: asset, aspect: story.aspect, frameRate: outputFrameRate).canvasSize
        return ExportGeometry.outputSize(canvas: canvas, resolution: story.exportSettings.resolution)
    }

    var outputFrameRate: Int {
        story.exportSettings.frameRate.value ?? Int((asset?.frameRate ?? 30).rounded())
    }

    func estimatedBytes(for segment: StorySegment) -> Int64 {
        guard let asset else { return 0 }
        let seconds = segment.range.duration.seconds
        if effectiveMode == .fastCopy {
            let rate = asset.estimatedBitrate ?? (asset.durationSeconds.map { Double(asset.fileSize) * 8 / max($0, 0.1) } ?? 8_000_000)
            return Int64(rate * seconds / 8)
        }
        let size = outputSize ?? CGSize(width: 1080, height: 1920)
        let bitrate = BitrateCalculator.videoBitrate(size: size, fps: outputFrameRate, settings: story.exportSettings)
        return BitrateCalculator.estimatedBytes(durationSeconds: seconds, videoBitrate: bitrate,
                                                audioKbps: story.exportSettings.audioBitrateKbps)
    }

    var totalEstimatedBytes: Int64 { includedSegments.reduce(0) { $0 + estimatedBytes(for: $1) } }

    func exceedsFileLimit(_ segment: StorySegment) -> Bool {
        guard let limit = preset?.maxFileSizeMB else { return false }
        return Double(estimatedBytes(for: segment)) > limit * 1_048_576
    }

    func exceedsDurationLimit(_ segment: StorySegment) -> Bool {
        guard let limit = preset?.maxDuration else { return false }
        return segment.range.duration.seconds > limit + 0.05
    }

    func index(of id: UUID) -> Int? { story.segments.firstIndex { $0.id == id } }

    func displayName(for segment: StorySegment) -> String {
        if !segment.name.isEmpty { return segment.name }
        let number = (index(of: segment.id) ?? 0) + 1
        return "مقطع " + String(format: "%02d", number)
    }

    // MARK: Mutation core

    private func mutate(_ change: (inout StoryConfig) -> Void) {
        guard var story = project.story else { return }
        change(&story)
        project.story = story
        env.projects.scheduleAutosave(project)
    }

    func rename(project name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
        env.projects.scheduleAutosave(project)
    }

    // MARK: Rule

    func applyPreset(_ preset: PlatformPreset?) {
        Haptics.selection()
        mutate { story in
            story.presetKey = preset?.key
            if let preset {
                story.aspect = preset.aspect
                story.fitMode = preset.fitMode
                story.exportSettings = preset.applying(to: story.exportSettings)
                story.rule.hardMaximum = preset.maxDuration
                if let max = preset.maxDuration {
                    story.rule.mode = .maxDuration
                    story.rule.seconds = max
                }
            } else {
                story.rule.hardMaximum = nil
            }
        }
        requestReplan()
    }

    func setMode(_ mode: SplitModeKind) { mutate { $0.rule.mode = mode }; requestReplan() }
    func setSeconds(_ value: Double) { mutate { $0.rule.seconds = max(SegmentPlanner.minimumSegment, value) }; requestReplan() }
    func setParts(_ value: Int) { mutate { $0.rule.parts = min(max(value, 1), 500) }; requestReplan() }

    func commitCustomDurations() {
        let values = Fmt.parseNumberList(customDurationsText)
        guard !values.isEmpty else { return }
        mutate { $0.rule.customDurations = values }
        requestReplan()
    }

    func setSnap(_ target: SnapTarget) {
        mutate { $0.rule.snap = target }
        if target != .none && snapPoints.isEmpty {
            runAnalysis(target)
        } else {
            requestReplan()
        }
    }

    func setTolerance(_ value: Double) { mutate { $0.rule.snapTolerance = value }; requestReplan() }
    func setMinimumTail(_ value: Double) { mutate { $0.rule.minimumTail = value }; requestReplan() }
    func setAspect(_ aspect: AspectRatio?) { mutate { $0.aspect = aspect } }
    func setFitMode(_ mode: FitMode) { mutate { $0.fitMode = mode } }
    func setExportMode(_ mode: StoryExportMode) { mutate { $0.exportMode = mode } }
    func setExportSettings(_ settings: ExportSettings) { mutate { $0.exportSettings = settings } }

    /// Recomputes the plan, asking first when the user has customized cut points.
    func requestReplan() {
        if story.isCustomized {
            pendingReplanConfirmation = true
        } else {
            replan(force: true)
        }
    }

    func replan(force: Bool) {
        guard force || !story.isCustomized else { return }
        let ranges = SegmentPlanner.plan(duration: duration, rule: story.rule, snapPoints: snapPoints)
        mutate { story in
            story.segments = ranges.map { StorySegment(range: TimeRangeValue(startSeconds: $0.start, endSeconds: $0.end)) }
            story.isCustomized = false
        }
        selectedSegmentID = story.segments.first?.id
        pendingReplanConfirmation = false
    }

    // MARK: Analysis (local, cached)

    func runAnalysis(_ target: SnapTarget) {
        guard let asset, let url = env.library.url(forID: asset.id), target != .none else { return }
        analysisTask?.cancel()
        analysisProgress = 0
        analysisTitle = switch target {
        case .scenes: "تحليل تغيّر المشاهد…"
        case .pauses: "تحليل وقفات الكلام…"
        case .keyframes: "فهرسة الإطارات المفتاحية…"
        case .none: ""
        }
        let assetID = asset.id
        let reporter: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.analysisProgress = value }
        }
        analysisTask = Task { [weak self] in
            do {
                switch target {
                case .scenes:
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await SceneDetector.detect(url: url, progress: reporter)
                    }.value
                    AnalysisCache.saveTimes(result, assetID: assetID, kind: "scenes")
                    self?.scenes = result
                case .pauses:
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await SilenceDetector.detect(url: url, progress: reporter)
                    }.value
                    AnalysisCache.saveSilences(result, assetID: assetID)
                    self?.pauses = result.map(\.midpoint)
                case .keyframes:
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await KeyframeIndexer.syncTimes(url: url, progress: reporter)
                    }.value
                    AnalysisCache.saveTimes(result, assetID: assetID, kind: "keyframes")
                    self?.keyframes = result
                case .none:
                    break
                }
                guard let self else { return }
                self.analysisProgress = nil
                let count = self.snapPoints.count
                self.env.toasts.show("تم العثور على " + Fmt.int(count) + " نقطة قطع", style: .success)
                self.requestReplan()
            } catch is CancellationError {
                self?.analysisProgress = nil
            } catch {
                self?.analysisProgress = nil
                self?.env.toasts.show(error.localizedDescription, style: .error)
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisProgress = nil
    }

    // MARK: Manual adjustment

    /// Moves a segment edge. Adjacent segments sharing that edge move with it.
    func setStart(_ id: UUID, to seconds: Double) {
        guard let i = index(of: id) else { return }
        mutate { story in
            var segment = story.segments[i]
            let end = segment.range.end.seconds
            let previousIndex = story.segments.firstIndex { abs($0.range.end.seconds - segment.range.start.seconds) < 0.0005 && $0.id != id }
            var lower = 0.0
            if let p = previousIndex { lower = story.segments[p].range.start.seconds + SegmentPlanner.minimumSegment }
            let value = min(max(seconds, lower), end - SegmentPlanner.minimumSegment)
            segment.range = TimeRangeValue(startSeconds: value, endSeconds: end)
            story.segments[i] = segment
            if let p = previousIndex {
                let pStart = story.segments[p].range.start.seconds
                story.segments[p].range = TimeRangeValue(startSeconds: pStart, endSeconds: value)
            }
            story.isCustomized = true
        }
    }

    func setEnd(_ id: UUID, to seconds: Double) {
        guard let i = index(of: id) else { return }
        mutate { story in
            var segment = story.segments[i]
            let start = segment.range.start.seconds
            let nextIndex = story.segments.firstIndex { abs($0.range.start.seconds - segment.range.end.seconds) < 0.0005 && $0.id != id }
            var upper = duration
            if let n = nextIndex { upper = story.segments[n].range.end.seconds - SegmentPlanner.minimumSegment }
            let value = max(min(seconds, upper), start + SegmentPlanner.minimumSegment)
            segment.range = TimeRangeValue(startSeconds: start, endSeconds: value)
            story.segments[i] = segment
            if let n = nextIndex {
                let nEnd = story.segments[n].range.end.seconds
                story.segments[n].range = TimeRangeValue(startSeconds: value, endSeconds: nEnd)
            }
            story.isCustomized = true
        }
    }

    func nudge(_ id: UUID, edge: SegmentEdge, by delta: Double) {
        guard let segment = story.segments.first(where: { $0.id == id }) else { return }
        Haptics.selection()
        switch edge {
        case .start: setStart(id, to: TimeValue(seconds: segment.range.start.seconds + delta).snapped(toFrameRate: frameRate).seconds)
        case .end: setEnd(id, to: TimeValue(seconds: segment.range.end.seconds + delta).snapped(toFrameRate: frameRate).seconds)
        }
    }

    /// Snaps an edge to the nearest analysis point within 5 s.
    func snapEdge(_ id: UUID, edge: SegmentEdge) -> Bool {
        guard let segment = story.segments.first(where: { $0.id == id }) else { return false }
        let all = (scenes + pauses + keyframes).sorted()
        let current = edge == .start ? segment.range.start.seconds : segment.range.end.seconds
        guard let target = SegmentPlanner.nearest(current, in: all.filter { abs($0 - current) > 0.02 }, tolerance: 5) else { return false }
        switch edge {
        case .start: setStart(id, to: target)
        case .end: setEnd(id, to: target)
        }
        return true
    }

    // MARK: Gallery operations

    func renameSegment(_ id: UUID, to name: String) {
        guard let i = index(of: id) else { return }
        mutate { $0.segments[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func toggleIncluded(_ id: UUID) {
        guard let i = index(of: id) else { return }
        mutate { $0.segments[i].isIncluded.toggle() }
    }

    func deleteSegments(at offsets: IndexSet) {
        mutate { story in
            story.segments.remove(atOffsets: offsets)
            story.isCustomized = true
        }
    }

    func deleteSegment(_ id: UUID) {
        guard let i = index(of: id) else { return }
        deleteSegments(at: IndexSet(integer: i))
    }

    func moveSegments(from source: IndexSet, to destination: Int) {
        mutate { story in
            story.segments.move(fromOffsets: source, toOffset: destination)
            story.isCustomized = true
        }
    }

    func preview(_ segment: StorySegment) {
        selectedSegmentID = segment.id
        player.playRange(start: segment.range.start.seconds, end: segment.range.end.seconds)
    }

    // MARK: Export

    @discardableResult
    func exportAll() -> Int {
        guard let asset, !isSourceMissing else {
            env.toasts.show("ملف المصدر مفقود — اربطه من مكتبة الوسائط أولاً.", style: .error)
            return 0
        }
        let batchID = UUID()
        let batchTitle = project.name
        let settings = story.exportSettings
        var jobs: [ExportJob] = []
        for (order, segment) in includedSegments.enumerated() {
            let base = segment.name.isEmpty ? project.name + " - " + String(format: "%02d", order + 1) : segment.name
            let payload: ExportPayload
            if effectiveMode == .fastCopy {
                payload = .passthrough(assetID: asset.id, range: segment.range)
            } else {
                let (timeline, canvas) = StoryTimelineFactory.make(source: asset, segment: segment.range, aspect: story.aspect,
                                                                   fitMode: story.fitMode, frameRate: outputFrameRate)
                payload = .render(RenderPayload(timeline: timeline, projectSettings: canvas, range: nil))
            }
            var job = ExportJob(batchID: batchID, batchTitle: batchTitle, title: displayName(for: segment),
                                outputBaseName: base, payload: payload, settings: settings)
            job.estimatedBytes = estimatedBytes(for: segment)
            jobs.append(job)
        }
        guard !jobs.isEmpty else {
            env.toasts.show("لا توجد مقاطع محددة للتصدير.", style: .warning)
            return 0
        }
        let needed = jobs.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        if !StorageManager.shared.hasSpace(for: needed) {
            env.toasts.show("المساحة قد لا تكفي (" + Fmt.bytes(needed) + " مطلوبة تقريباً).", style: .warning)
        }
        env.exportQueue.enqueue(jobs)
        env.projects.flushAutosave(project)
        env.toasts.show("أُضيف " + Fmt.int(jobs.count) + " مقطع لقائمة التصدير", style: .success)
        return jobs.count
    }

    func close() {
        analysisTask?.cancel()
        player.pause()
        env.projects.flushAutosave(project)
        env.projects.endSession()
    }
}

enum SegmentEdge {
    case start, end
}
