//
//  StudioViewModel+Editing.swift
//  ClipStudio — Features/ProStudio
//
//  Editing commands used by the toolbar, menus, keyboard shortcuts and inspectors.
//  Every command goes through `edit` / `editProject`, so it is undoable, autosaved
//  and refreshes the preview.
//

import Foundation
import SwiftUI

extension StudioViewModel {

    // MARK: Cut / delete / duplicate / join

    func splitAtPlayhead() {
        let time = currentTime
        let ids = selection
        if edit("تقسيم", { timeline, context in
            try TimelineEngine.split(ids, at: time, in: &timeline, context: context)
        }) {
            Haptics.tap()
        }
    }

    func deleteSelection(ripple: Bool? = nil) {
        guard !selection.isEmpty else {
            report(TimelineEditError.nothingSelected)
            return
        }
        let ids = selection
        let useRipple = ripple ?? prefs.rippleDeleteByDefault
        if edit(useRipple ? "حذف متموّج" : "حذف", { timeline, context in
            try TimelineEngine.delete(ids, ripple: useRipple, in: &timeline, context: context)
        }) {
            selection = []
            Haptics.tap()
        }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else {
            report(TimelineEditError.nothingSelected)
            return
        }
        let ids = selection
        var created: [UUID] = []
        if edit("تكرار", { timeline, context in
            created = try TimelineEngine.duplicate(ids, in: &timeline, context: context)
        }) {
            selection = Set(created)
        }
    }

    var canJoinSelection: Bool {
        TimelineEngine.joinCandidate(for: selection, in: timeline, context: editContext) != nil
    }

    func joinSelection() {
        guard let pair = TimelineEngine.joinCandidate(for: selection, in: timeline, context: editContext) else {
            report(TimelineEditError.cannotJoin)
            return
        }
        if edit("دمج المقطعين", { timeline, context in
            try TimelineEngine.join(pair.0, pair.1, in: &timeline, context: context)
        }) {
            selection = [pair.0]
        }
    }

    func nudgeSelection(frames: Int) {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit("تحريك دقيق", coalesce: "nudge") { timeline, context in
            try TimelineEngine.nudge(ids, frames: frames, in: &timeline, context: context)
        }
    }

    func toggleEnabled() {
        guard !selection.isEmpty else { return }
        let enable = selectedClips.contains { !$0.isEnabled }
        updateSelection(enable ? "تفعيل المقاطع" : "تعطيل المقاطع") { $0.isEnabled = enable }
    }

    // MARK: Clipboard

    func copySelection() {
        guard !selection.isEmpty else {
            report(TimelineEditError.nothingSelected)
            return
        }
        clipboard.copy(selection, from: timeline)
        env.toasts.show("تم نسخ " + Fmt.int(selection.count) + " مقطع", style: .info, duration: 1.4)
    }

    func cutSelection() {
        guard !selection.isEmpty else { return }
        clipboard.copy(selection, from: timeline)
        deleteSelection(ripple: false)
    }

    func paste() {
        guard clipboard.hasClips else {
            env.toasts.show("الحافظة فارغة", style: .info)
            return
        }
        let items = clipboard.items
        let time = currentTime
        let anchor = selectedTrackIndex
        var created: [UUID] = []
        if edit("لصق", { timeline, context in
            created = try TimelineEngine.paste(items, at: time, anchorTrack: anchor, in: &timeline, context: context)
        }) {
            selection = Set(created)
        }
    }

    func copyAttributes() {
        guard let clip = primaryClip else {
            report(TimelineEditError.nothingSelected)
            return
        }
        clipboard.copyAttributes(of: clip)
        env.toasts.show("تم نسخ خصائص المقطع", style: .info, duration: 1.4)
    }

    func pasteAttributes(_ attributes: ClipAttributes) {
        guard clipboard.hasAttributes, let source = clipboard.attributeSource else {
            env.toasts.show("انسخ خصائص مقطع أولاً", style: .info)
            return
        }
        guard !selection.isEmpty else {
            report(TimelineEditError.nothingSelected)
            return
        }
        let ids = selection
        let board = clipboard
        edit("لصق الخصائص") { timeline, context in
            TimelineEngine.updateClips(ids, in: &timeline) { clip in board.pasteAttributes(attributes, into: &clip) }
            if attributes.contains(.speed), source.sourceRange != nil {
                for id in ids {
                    guard let clip = TimelineEngine.clip(id, in: timeline), clip.sourceRange != nil, clip.mediaAssetID != nil else { continue }
                    var speed = source.speed
                    speed.isReversed = false
                    speed.reversedAssetID = clip.speed.reversedAssetID
                    try TimelineEngine.setSpeed(speed, forClip: id, in: &timeline, context: context)
                }
            }
        }
    }

    // MARK: Media

    func makeClip(for asset: MediaAsset) -> Clip? {
        let context = editContext
        switch asset.kind {
        case .video, .audio:
            guard let seconds = asset.durationSeconds, seconds > context.frame else { return nil }
            let usable = context.floorToFrame(seconds)
            var clip = Clip(name: asset.displayName, source: .media(asset.id), start: .zero,
                            duration: TimeValue(seconds: usable), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: usable))
            clip.fitMode = .fit
            return clip
        case .image:
            return Clip(name: asset.displayName, source: .image(asset.id), start: .zero,
                        duration: TimeValue(seconds: max(context.frame, context.snap(prefs.defaultImageDuration))))
        }
    }

    /// Adds library media at the playhead (or appends) using the chosen placement mode.
    func add(_ assets: [MediaAsset], mode: PlacementMode? = nil) {
        let placement = mode ?? prefs.placementMode
        let visual = assets.filter { $0.kind != .audio }.compactMap { makeClip(for: $0) }
        let audio = assets.filter { $0.kind == .audio }.compactMap { makeClip(for: $0) }
        guard !visual.isEmpty || !audio.isEmpty else {
            env.toasts.show("لا يمكن إضافة هذه الملفات (مفقودة أو بدون مدة).", style: .warning)
            return
        }
        let time = currentTime
        let preferred = selectedTrackIndex
        var created: [UUID] = []
        let added = edit("إضافة وسائط", { timeline, context in
            if !visual.isEmpty {
                let total = visual.reduce(0) { $0 + $1.duration.seconds }
                let visualPreferred = preferred.flatMap { index -> Int? in
                    timeline.tracks.indices.contains(index) && timeline.tracks[index].kind.isVisual ? index : nil
                }
                let track = TimelineEngine.defaultTrack(for: visual[0].source, kind: .video, preferred: visualPreferred,
                                                        in: &timeline, start: time, end: time + total, context: context)
                created += try TimelineEngine.place(visual, onTrack: track, at: time, mode: placement,
                                                    in: &timeline, context: context)
            }
            if !audio.isEmpty {
                let total = audio.reduce(0) { $0 + $1.duration.seconds }
                let track: Int
                if let preferred, timeline.tracks.indices.contains(preferred), timeline.tracks[preferred].kind == .audio,
                   !timeline.tracks[preferred].isLocked {
                    track = preferred
                } else {
                    track = TimelineEngine.freeTrack(.audio, start: time, end: time + total, in: &timeline, context: context)
                }
                let audioMode: PlacementMode = placement == .insert ? .insert : .overwrite
                created += try TimelineEngine.place(audio, onTrack: track, at: time, mode: audioMode,
                                                    in: &timeline, context: context)
            }
        })
        if added {
            selection = Set(created)
            Haptics.success()
        }
    }

    /// Drag & drop from the media panel onto a track at a time (overwrite on free
    /// tracks, insert on the magnetic storyline). Audio goes to an audio track.
    @discardableResult
    func drop(assetIDs: [UUID], onTrack index: Int, at time: Double) -> Bool {
        let assets = assetIDs.compactMap { env.library.asset($0) }.filter { !env.library.isMissing($0) }
        let visual = assets.filter { $0.kind != .audio }.compactMap { makeClip(for: $0) }
        let audio = assets.filter { $0.kind == .audio }.compactMap { makeClip(for: $0) }
        guard !visual.isEmpty || !audio.isEmpty, timeline.tracks.indices.contains(index) else { return false }
        let start = max(0, time)
        var created: [UUID] = []
        let dropped = edit("إفلات وسائط", { timeline, context in
            if !visual.isEmpty {
                let total = visual.reduce(0) { $0 + $1.duration.seconds }
                let target: Int
                if timeline.tracks[index].kind.isVisual, timeline.tracks[index].kind.accepts(visual[0].source),
                   !timeline.tracks[index].isLocked {
                    target = index
                } else {
                    target = TimelineEngine.defaultTrack(for: visual[0].source, kind: .video, preferred: nil,
                                                         in: &timeline, start: start, end: start + total, context: context)
                }
                let mode: PlacementMode = TimelineEngine.isMagnetic(target, timeline, context: context) ? .insert : .overwrite
                created += try TimelineEngine.place(visual, onTrack: target, at: start, mode: mode, in: &timeline, context: context)
            }
            if !audio.isEmpty {
                let total = audio.reduce(0) { $0 + $1.duration.seconds }
                let target: Int
                if timeline.tracks[index].kind == .audio, !timeline.tracks[index].isLocked {
                    target = index
                } else {
                    target = TimelineEngine.freeTrack(.audio, start: start, end: start + total, in: &timeline, context: context)
                }
                created += try TimelineEngine.place(audio, onTrack: target, at: start, mode: .overwrite, in: &timeline, context: context)
            }
        })
        if dropped {
            selection = Set(created)
            Haptics.success()
        }
        return dropped
    }

    func replace(_ clipID: UUID, with asset: MediaAsset) {
        let source: ClipSource = asset.kind == .image ? .image(asset.id) : .media(asset.id)
        edit("استبدال المقطع") { timeline, context in
            try TimelineEngine.replace(clipID, with: source, name: asset.displayName,
                                       assetDuration: asset.durationSeconds, in: &timeline, context: context)
        }
    }

    // MARK: Generated layers

    /// Range for new generated layers: selection span → in/out → playhead + default duration.
    private var generatedRange: (Double, Double) {
        if !selectedClips.isEmpty, let start = selectedClips.map(\.start.seconds).min(),
           let end = selectedClips.map(\.end.seconds).max() {
            return (start, end - start)
        }
        if let range = inOutRange { return (range.0, range.1 - range.0) }
        return (currentTime, prefs.defaultGeneratedDuration)
    }

    func addAdjustmentLayer() {
        let range = generatedRange
        var created: UUID?
        if edit("طبقة تعديل", { timeline, context in
            created = try TimelineEngine.insertGenerated(.adjustment, name: "طبقة تعديل", at: range.0,
                                                         duration: range.1, in: &timeline, context: context)
        }), let created {
            selection = [created]
            inspectorTab = .color
        }
    }

    func addSolidColor(_ color: RGBAColor = RGBAColor(hex: 0x15161B)) {
        let range = generatedRange
        var created: UUID?
        if edit("لون ثابت", { timeline, context in
            created = try TimelineEngine.insertGenerated(.solidColor(color), name: "لون ثابت", at: range.0,
                                                         duration: range.1, in: &timeline, context: context)
        }), let created {
            selection = [created]
            inspectorTab = .transform
        }
    }

    func setSolidColor(_ color: RGBAColor, for clipID: UUID) {
        updateClip(clipID, name: "لون الطبقة", coalesce: "solid-" + clipID.uuidString) { clip in
            if case .solidColor = clip.source { clip.source = .solidColor(color) }
        }
    }

    // MARK: Transitions

    func setTransition(_ kind: TransitionKind, duration: Double? = nil, for clipID: UUID) {
        let length = duration ?? (TimelineEngine.clip(clipID, in: timeline)?.transitionIn?.duration.seconds ?? prefs.defaultTransitionDuration)
        edit(kind == .none ? "إزالة الانتقال" : "انتقال: " + kind.title,
             coalesce: duration == nil ? nil : "transition-" + clipID.uuidString) { timeline, context in
            try TimelineEngine.setTransition(kind, duration: length, forClip: clipID, in: &timeline, context: context)
        }
    }

    func applyTransitionToTrack(_ kind: TransitionKind, duration: Double, trackOf clipID: UUID) {
        guard let track = TimelineEngine.trackIndex(of: clipID, in: timeline) else { return }
        edit("انتقال لكل القطع") { timeline, context in
            try TimelineEngine.setTransitionForAllCuts(kind, duration: duration, track: track, in: &timeline, context: context)
        }
    }

    // MARK: Speed

    func setSpeed(_ speed: SpeedSettings, for clipID: UUID, coalesce: String? = nil) {
        edit("السرعة", coalesce: coalesce) { timeline, context in
            try TimelineEngine.setSpeed(speed, forClip: clipID, in: &timeline, context: context)
        }
    }

    func setRate(_ rate: Double, for clipID: UUID, coalesce: String? = nil) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return }
        var speed = clip.speed
        speed.rate = min(max(rate, SpeedSettings.minimumRate), 16)
        speed.ramp = []
        setSpeed(speed, for: clipID, coalesce: coalesce)
    }

    func setRamp(_ points: [SpeedRampPoint], for clipID: UUID, coalesce: String? = nil) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return }
        var speed = clip.speed
        speed.ramp = points.sorted { $0.position < $1.position }
        setSpeed(speed, for: clipID, coalesce: coalesce)
    }

    func setPreservePitch(_ value: Bool, for clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return }
        var speed = clip.speed
        speed.preservePitch = value
        setSpeed(speed, for: clipID)
    }

    func insertFreezeFrame() {
        guard let clip = primaryClip ?? TimelineEngine.clips(at: currentTime, in: timeline).first(where: { $0.mediaAssetID != nil }) else {
            report(TimelineEditError.nothingSelected)
            return
        }
        let time = currentTime
        let length = prefs.defaultFreezeDuration
        var created: UUID?
        if edit("إطار ثابت", { timeline, context in
            created = try TimelineEngine.insertFreezeFrame(of: clip.id, at: time, duration: length, in: &timeline, context: context)
        }), let created {
            selection = [created]
        }
    }

    func detachAudio() {
        guard let clip = primaryClip else {
            report(TimelineEditError.nothingSelected)
            return
        }
        if let asset = asset(for: clip), !asset.hasAudio {
            env.toasts.show("هذا المقطع بدون صوت.", style: .info)
            return
        }
        var created: UUID?
        if edit("فصل الصوت", { timeline, context in
            created = try TimelineEngine.detachAudio(of: clip.id, in: &timeline, context: context)
        }), let created {
            selection = [created]
            env.toasts.show("تم فصل الصوت إلى مسار صوت", style: .success)
        }
    }

    // MARK: Tracks

    func addTrack(_ kind: TrackKind) {
        var index = 0
        if edit("مسار جديد", { timeline, _ in index = TimelineEngine.addTrack(kind, to: &timeline) }) {
            selectedTrackIndex = index
        }
    }

    func requestRemoveTrack(_ index: Int) {
        guard timeline.tracks.indices.contains(index) else { return }
        if timeline.tracks[index].clips.isEmpty {
            removeTrack(index)
        } else {
            pendingDeleteTrack = index
        }
    }

    func removeTrack(_ index: Int) {
        pendingDeleteTrack = nil
        let removed = Set(timeline.tracks.indices.contains(index) ? timeline.tracks[index].clips.map(\.id) : [])
        if edit("حذف مسار", { timeline, context in
            TimelineEngine.removeTrack(index, from: &timeline)
            TimelineEngine.finalize(&timeline, context: context)
        }) {
            selection.subtract(removed)
        }
    }

    func updateTrack(_ index: Int, name: String, coalesce: String? = nil, _ change: @escaping (inout Track) -> Void) {
        edit(name, coalesce: coalesce) { timeline, _ in
            guard timeline.tracks.indices.contains(index) else { return }
            change(&timeline.tracks[index])
        }
    }

    func toggleLock(_ index: Int) { updateTrack(index, name: "قفل المسار") { $0.isLocked.toggle() } }
    func toggleHidden(_ index: Int) { updateTrack(index, name: "إخفاء المسار") { $0.isHidden.toggle() } }
    func toggleMuted(_ index: Int) { updateTrack(index, name: "كتم المسار") { $0.isMuted.toggle() } }

    func setTrackVolume(_ index: Int, _ value: Double) {
        updateTrack(index, name: "مستوى المسار", coalesce: "track-volume-" + String(index)) { $0.volume = min(max(value, 0), 1) }
    }

    func renameTrack(_ index: Int, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateTrack(index, name: "إعادة تسمية المسار") { $0.name = trimmed }
    }

    /// Moves a visual track one layer up/down (display direction).
    func moveTrack(_ index: Int, up: Bool) {
        let order = TimelineEngine.displayOrder(timeline)
        guard let row = order.firstIndex(of: index) else { return }
        let targetRow = up ? row - 1 : row + 1
        guard order.indices.contains(targetRow) else { return }
        let target = order[targetRow]
        guard timeline.tracks[target].kind.isVisual == timeline.tracks[index].kind.isVisual else { return }
        if edit("ترتيب المسارات", { timeline, context in
            TimelineEngine.moveTrack(from: index, to: target, in: &timeline)
            TimelineEngine.finalize(&timeline, context: context)
        }) {
            selectedTrackIndex = target
        }
    }

    // MARK: Markers

    func addMarker(named name: String? = nil) {
        guard editingCompoundID == nil else {
            env.toasts.show("العلامات متاحة في التسلسل الرئيسي.", style: .info)
            return
        }
        let time = (currentTime * frameRate).rounded() / frameRate
        let marker = TimelineMarker(time: TimeValue(seconds: time),
                                    name: name ?? "علامة " + String(project.markers.count + 1))
        editProject("إضافة علامة") { project in
            project.markers.append(marker)
            project.markers.sort { $0.time < $1.time }
        }
        Haptics.tap()
    }

    func removeMarker(_ id: UUID) {
        editProject("حذف علامة") { $0.markers.removeAll { $0.id == id } }
    }

    func renameMarker(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editProject("إعادة تسمية علامة") { project in
            if let index = project.markers.firstIndex(where: { $0.id == id }) { project.markers[index].name = trimmed }
        }
    }

    func setMarkerColor(_ id: UUID, _ color: RGBAColor) {
        editProject("لون العلامة") { project in
            if let index = project.markers.firstIndex(where: { $0.id == id }) { project.markers[index].color = color }
        }
    }

    func jumpToMarker(next: Bool) {
        let times = markers.map(\.time.seconds)
        let target = next
            ? times.filter { $0 > currentTime + frameDuration * 0.5 }.min()
            : times.filter { $0 < currentTime - frameDuration * 0.5 }.max()
        if let target { seek(to: target) }
    }

    // MARK: Keyframes

    func toggleKeyframe(_ property: KeyframeProperty, clipID: UUID? = nil) {
        guard let clip = clipID.flatMap({ TimelineEngine.clip($0, in: timeline) }) ?? primaryClip else { return }
        guard isPlayheadInside(clip) else {
            env.toasts.show("ضع رأس التشغيل داخل المقطع لإضافة إطار مفتاحي.", style: .info)
            return
        }
        let t = localTime(for: clip)
        let tolerance = keyframeTolerance
        updateClip(clip.id, name: "إطار مفتاحي") { $0.toggleKeyframe(property, at: t, tolerance: tolerance) }
        Haptics.selection()
    }

    func toggleEffectKeyframe(_ effectID: UUID, clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), isPlayheadInside(clip) else {
            env.toasts.show("ضع رأس التشغيل داخل المقطع لإضافة إطار مفتاحي.", style: .info)
            return
        }
        let t = localTime(for: clip)
        let tolerance = keyframeTolerance
        updateClip(clipID, name: "إطار مفتاحي") { $0.toggleEffectKeyframe(effectID, at: t, tolerance: tolerance) }
    }

    func clearKeyframes(_ property: KeyframeProperty, clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return }
        let t = localTime(for: clip)
        updateClip(clipID, name: "إزالة الحركة") { $0.clearKeyframes(property, keepingValueAt: t) }
    }

    func hasKeyframe(_ property: KeyframeProperty, clip: Clip) -> Bool {
        isPlayheadInside(clip) && clip.hasKeyframe(property, at: localTime(for: clip), tolerance: keyframeTolerance)
    }

    func jumpToKeyframe(next: Bool) {
        guard let clip = primaryClip else { return }
        let local = currentTime - clip.start.seconds
        let times = clip.allKeyframeTimes
        let target = next
            ? times.first { $0 > local + frameDuration * 0.5 }
            : times.last { $0 < local - frameDuration * 0.5 }
        if let target { seek(to: clip.start.seconds + target) }
    }

    // MARK: Clip info

    func renameClip(_ id: UUID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateClip(id, name: "إعادة تسمية") { $0.name = trimmed }
    }

    func setLabel(_ color: RGBAColor?) {
        updateSelection("لون التسمية") { $0.label = color }
    }

    // MARK: Project settings

    func applyProjectSettings(_ settings: ProjectSettings) {
        editProject("إعدادات المشروع") { $0.settings = settings }
        player.frameRate = Double(settings.frameRate)
    }
}
