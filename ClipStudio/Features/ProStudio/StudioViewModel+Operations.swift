//
//  StudioViewModel+Operations.swift
//  ClipStudio — Features/ProStudio
//
//  Long-running operations with real progress and cancellation: reverse
//  rendering, nested sequences (create / open / update / break apart) and export.
//  Also frame grabbing for the color workspace and the crop/mask/chroma editors.
//

import Foundation
import SwiftUI
import CoreImage

enum StudioExportRange: String, CaseIterable, Identifiable {
    case whole, inOut, selection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whole: "المشروع كامل"
        case .inOut: "من نقطة البداية إلى النهاية"
        case .selection: "المقاطع المحددة"
        }
    }
}

/// Throttles progress callbacks from render threads to the main actor.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private let apply: @MainActor (Double) -> Void

    init(_ apply: @escaping @MainActor (Double) -> Void) {
        self.apply = apply
    }

    func send(_ value: Double) {
        let shouldSend: Bool = lock.withLock {
            if value >= 1 || value - last >= 0.005 || value < last {
                last = value
                return true
            }
            return false
        }
        guard shouldSend else { return }
        let apply = self.apply
        Task { @MainActor in apply(value) }
    }
}

extension StudioViewModel {

    // MARK: Busy helper

    func startBusy(_ title: String, detail: String, cancellable: Bool = true) -> (RenderControl, ProgressRelay) {
        let control = RenderControl()
        busy = BusyOperation(title: title, detail: detail, progress: 0, control: control, cancellable: cancellable)
        let relay = ProgressRelay { [weak self] value in
            guard let self, self.busy?.control === control else { return }
            self.busy?.progress = value
        }
        return (control, relay)
    }

    func cancelBusy() {
        guard let busy, busy.cancellable else { return }
        busy.control.cancel()
    }

    // MARK: Reverse

    func toggleReverse(clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), case .media(let assetID) = clip.source,
              let asset = env.library.asset(assetID), asset.kind == .video else {
            env.toasts.show("العكس متاح لمقاطع الفيديو فقط.", style: .info)
            return
        }
        if clip.speed.isReversed {
            var speed = clip.speed
            speed.isReversed = false
            setSpeed(speed, for: clipID)
            return
        }
        let library = env.library
        if let existing = clip.speed.reversedAssetID.flatMap({ library.asset($0) }).map(\.id)
            ?? ReverseLibrary.shared.reversedAssetID(for: assetID, library: library) {
            var speed = clip.speed
            speed.isReversed = true
            speed.reversedAssetID = existing
            setSpeed(speed, for: clipID)
            return
        }
        let (control, relay) = startBusy("عكس المقطع", detail: asset.displayName + " — تتم المعالجة على جهازك")
        Task { [weak self] in
            do {
                let reversed = try await ReverseLibrary.shared.reversed(asset, library: library, control: control) { relay.send($0) }
                guard let self else { return }
                self.busy = nil
                guard let current = TimelineEngine.clip(clipID, in: self.timeline) else { return }
                var speed = current.speed
                speed.isReversed = true
                speed.reversedAssetID = reversed.id
                self.setSpeed(speed, for: clipID)
                self.env.toasts.show("تم عكس المقطع", style: .success)
            } catch {
                guard let self else { return }
                self.busy = nil
                if case ReverseError.cancelled = error {
                    self.env.toasts.show("تم إلغاء العكس", style: .info)
                } else {
                    self.report(error)
                }
            }
        }
    }

    // MARK: Nested sequences

    var canCreateCompound: Bool { editingCompoundID == nil && !selection.isEmpty }

    func compound(for clip: Clip) -> CompoundClip? {
        guard case .media(let assetID) = clip.source else { return nil }
        return project.compound(renderedAs: assetID)
    }

    func createCompound() {
        guard editingCompoundID == nil else {
            env.toasts.show("أنشئ التسلسلات المتداخلة من التسلسل الرئيسي.", style: .info)
            return
        }
        let ids = selection
        guard !ids.isEmpty else {
            report(TimelineEditError.nothingSelected)
            return
        }
        for index in timeline.tracks.indices where timeline.tracks[index].clips.contains(where: { ids.contains($0.id) }) {
            if timeline.tracks[index].isLocked {
                report(TimelineEditError.trackLocked)
                return
            }
        }
        guard let extracted = TimelineEngine.extractSubTimeline(ids, from: timeline) else {
            report(TimelineEditError.needsVisualClip)
            return
        }
        guard let targetTrack = timeline.tracks.indices.first(where: { index in
            timeline.tracks[index].kind.isVisual && timeline.tracks[index].clips.contains { ids.contains($0.id) }
        }) else {
            report(TimelineEditError.needsVisualClip)
            return
        }
        let compound = CompoundClip(name: "تسلسل متداخل " + String(project.compounds.count + 1), timeline: extracted.timeline)
        let settings = project.settings
        let library = env.library
        let (control, relay) = startBusy("إنشاء تسلسل متداخل", detail: Fmt.int(ids.count) + " مقطع • " + Fmt.duration(extracted.end - extracted.start))
        Task { [weak self] in
            do {
                let asset = try await NestedSequenceRenderer.render(compound, projectSettings: settings, library: library,
                                                                    control: control) { relay.send($0) }
                guard let self else { return }
                self.busy = nil
                var rendered = compound
                rendered.renderedAssetID = asset.id
                rendered.renderedAt = Date()
                rendered.needsRender = false
                let context = self.editContext
                let length = context.floorToFrame(min(asset.durationSeconds ?? (extracted.end - extracted.start), extracted.end - extracted.start))
                let clip = Clip(name: rendered.name, source: .media(asset.id), start: TimeValue(seconds: extracted.start),
                                duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
                var failure: Error?
                self.editProject("تسلسل متداخل") { project in
                    do {
                        try TimelineEngine.replaceSelection(ids, with: clip, onTrack: targetTrack, at: extracted.start,
                                                            in: &project.timeline, context: context)
                        project.compounds.append(rendered)
                    } catch {
                        failure = error
                    }
                }
                if let failure {
                    self.report(failure)
                } else {
                    self.selection = [clip.id]
                    self.env.toasts.show("تم إنشاء التسلسل المتداخل — اضغط مرتين لفتحه", style: .success)
                }
            } catch {
                guard let self else { return }
                self.busy = nil
                if error is CancellationError {
                    self.env.toasts.show("تم الإلغاء", style: .info)
                    return
                }
                self.report(error)
            }
        }
    }

    func openCompound(for clipID: UUID) {
        guard editingCompoundID == nil, let clip = TimelineEngine.clip(clipID, in: timeline), let compound = compound(for: clip) else {
            env.toasts.show("هذا المقطع ليس تسلسلًا متداخلًا.", style: .info)
            return
        }
        persistSessionState()
        selection = []
        editingCompoundID = compound.id
        selectedTrackIndex = compound.timeline.tracks.firstIndex { $0.kind == .video }
        player.seek(to: 0)
        rebuildPreview(delay: 0)
    }

    /// Leaves the nested sequence; re-renders it when it changed and re-points every instance.
    func closeCompound(completion: (() -> Void)? = nil) {
        guard let compound = editingCompound else {
            completion?()
            return
        }
        guard compound.needsRender else {
            exitCompound()
            completion?()
            return
        }
        guard compound.timeline.duration.seconds > 0.05,
              compound.timeline.tracks.contains(where: { $0.kind.isVisual && !$0.clips.isEmpty }) else {
            env.toasts.show("التسلسل المتداخل فارغ — أضف مقطعًا مرئيًا أو احذف نسخه من التسلسل الرئيسي.", style: .warning)
            return
        }
        let settings = project.settings
        let library = env.library
        let (control, relay) = startBusy("تحديث التسلسل المتداخل", detail: compound.name)
        Task { [weak self] in
            do {
                let asset = try await NestedSequenceRenderer.render(compound, projectSettings: settings, library: library,
                                                                    control: control) { relay.send($0) }
                guard let self else { return }
                self.busy = nil
                let oldAsset = compound.renderedAssetID
                let newDuration = asset.durationSeconds ?? compound.timeline.duration.seconds
                let context = self.editContext
                self.exitCompound()
                self.editProject("تحديث تسلسل متداخل") { project in
                    if let index = project.compounds.firstIndex(where: { $0.id == compound.id }) {
                        project.compounds[index].renderedAssetID = asset.id
                        project.compounds[index].renderedAt = Date()
                        project.compounds[index].needsRender = false
                    }
                    if let oldAsset {
                        TimelineEngine.repointCompound(from: oldAsset, to: asset.id, newDuration: newDuration,
                                                       in: &project.timeline, context: context)
                    }
                }
                self.env.toasts.show("تم تحديث التسلسل المتداخل", style: .success)
                completion?()
            } catch {
                guard let self else { return }
                self.busy = nil
                if error is CancellationError {
                    self.env.toasts.show("تم إلغاء التحديث — ما زلت داخل التسلسل المتداخل.", style: .info)
                    return
                }
                self.report(error)
            }
        }
    }

    private func exitCompound() {
        editingCompoundID = nil
        selection = []
        selectedTrackIndex = project.timeline.tracks.firstIndex { $0.kind == .video }
        player.seek(to: max(0, project.studio.playhead))
        rebuildPreview(delay: 0)
    }

    func expandCompound(clipID: UUID) {
        guard editingCompoundID == nil, let clip = TimelineEngine.clip(clipID, in: timeline), let compound = compound(for: clip) else {
            env.toasts.show("هذا المقطع ليس تسلسلًا متداخلًا.", style: .info)
            return
        }
        guard clip.speed.isNormal else {
            env.toasts.show("أرجع سرعة المقطع إلى 1x وألغِ العكس قبل التفكيك.", style: .info)
            return
        }
        var created: [UUID] = []
        if edit("تفكيك التسلسل", { timeline, context in
            created = try TimelineEngine.expandCompound(clipID, inner: compound.timeline, in: &timeline, context: context)
        }) {
            selection = Set(created)
        }
    }

    func renameCompound(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editProject("إعادة تسمية تسلسل") { project in
            if let index = project.compounds.firstIndex(where: { $0.id == id }) { project.compounds[index].name = trimmed }
        }
    }

    /// Compounds with no instance on the main timeline (can be removed).
    var unusedCompounds: [CompoundClip] {
        let used = project.timeline.referencedAssetIDs
        return project.compounds.filter { compound in
            guard let rendered = compound.renderedAssetID else { return true }
            return !used.contains(rendered)
        }
    }

    func removeCompound(_ id: UUID) {
        editProject("حذف تسلسل متداخل") { $0.compounds.removeAll { $0.id == id } }
    }

    // MARK: Export

    var exportSettingsForProject: ExportSettings {
        project.studio.exportSettings ?? env.settings.defaultExport
    }

    func exportRangeValue(_ range: StudioExportRange) -> TimeRangeValue? {
        switch range {
        case .whole:
            return nil
        case .inOut:
            guard let range = inOutRange else { return nil }
            return TimeRangeValue(startSeconds: range.0, endSeconds: range.1)
        case .selection:
            guard let start = selectedClips.map(\.start.seconds).min(), let end = selectedClips.map(\.end.seconds).max() else { return nil }
            return TimeRangeValue(startSeconds: start, endSeconds: end)
        }
    }

    func exportDuration(_ range: StudioExportRange) -> Double {
        exportRangeValue(range)?.duration.seconds ?? project.timeline.duration.seconds
    }

    @discardableResult
    func export(settings: ExportSettings, range: StudioExportRange) -> Bool {
        guard editingCompoundID == nil else {
            env.toasts.show("ارجع للتسلسل الرئيسي قبل التصدير.", style: .info)
            return false
        }
        guard project.timeline.duration.seconds > 0.05 else {
            report(CompositionError.emptyTimeline)
            return false
        }
        let missing = env.projects.missingAssets(in: project, library: env.library)
        guard missing.isEmpty else {
            env.toasts.show("بعض الملفات مفقودة — اربطها من مكتبة الوسائط قبل التصدير.", style: .error)
            return false
        }
        if range != .whole && exportRangeValue(range) == nil {
            env.toasts.show(range == .inOut ? "حدّد نقطتي البداية والنهاية (I / O) أولاً." : "حدّد مقاطع أولاً.", style: .info)
            return false
        }
        let payload = RenderPayload(timeline: project.timeline, projectSettings: project.settings, range: exportRangeValue(range))
        var job = ExportJob(title: project.name, outputBaseName: project.name, payload: .render(payload), settings: settings)
        let size = ExportGeometry.outputSize(canvas: project.settings.canvasSize, resolution: settings.resolution)
        let fps = settings.frameRate.value ?? project.settings.frameRate
        let bitrate = BitrateCalculator.videoBitrate(size: size, fps: fps, settings: settings)
        job.estimatedBytes = BitrateCalculator.estimatedBytes(durationSeconds: exportDuration(range), videoBitrate: bitrate,
                                                              audioKbps: settings.audioBitrateKbps)
        env.exportQueue.enqueue([job])
        project.studio.exportSettings = settings
        persistSessionState()
        env.projects.flushAutosave(project)
        env.toasts.show("أُضيف المشروع لقائمة التصدير", style: .success)
        return true
    }

    // MARK: Frames for editors

    /// Ungraded picture for a clip: its own source frame, or for adjustment layers the
    /// composited frame underneath (the layer itself hidden).
    func baseFrame(for clip: Clip, maxDimension: CGFloat = 960) async -> CIImage? {
        if case .adjustment = clip.source {
            guard let built else { return nil }
            let time = isPlayheadInside(clip) ? currentTime : clip.start.seconds + clip.duration.seconds / 2
            return await FramePreviewRenderer.shared.compositeFrame(built: built, timeline: timeline,
                                                                    background: project.settings.backgroundColor,
                                                                    at: time, excluding: [clip.id], maxDimension: maxDimension)
        }
        let local = isPlayheadInside(clip) ? localTime(for: clip) : clip.duration.seconds / 2
        return await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: local, media: env.library.urlMap(),
                                                             canvas: canvasSize, maxDimension: maxDimension)
    }

    /// The clip's picture as graded in the edit (reference for color matching).
    func gradedFrame(for clip: Clip, maxDimension: CGFloat = 640) async -> CIImage? {
        guard let base = await baseFrame(for: clip, maxDimension: maxDimension) else { return nil }
        return FramePreviewRenderer.shared.graded(base, color: clip.color, lut: clip.lut)
    }

    /// The full composite frame at the playhead (preview resolution).
    func compositeFrameAtPlayhead(maxDimension: CGFloat = 640) async -> CIImage? {
        guard let built else { return nil }
        return await FramePreviewRenderer.shared.compositeFrame(built: built, timeline: timeline,
                                                                background: project.settings.backgroundColor,
                                                                at: currentTime, excluding: [], maxDimension: maxDimension)
    }
}
