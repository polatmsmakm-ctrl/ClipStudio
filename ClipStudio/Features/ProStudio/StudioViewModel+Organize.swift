//
//  StudioViewModel+Organize.swift
//  ClipStudio — Features/ProStudio (Part 3)
//
//  Organizing tools: dragging markers, track colors, selecting every clip of the
//  same file, closing gaps, full-resolution frame snapshots, motion presets,
//  aspect lock / stretch, and the project summary.
//

import Foundation
import SwiftUI

/// Per-track and whole-project statistics for the summary sheet.
struct ProjectSummaryData {
    struct TrackRow: Identifiable {
        let id: UUID
        let index: Int
        let name: String
        let kind: TrackKind
        let color: RGBAColor?
        let clipCount: Int
        let coveredDuration: Double
        let transitions: Int
        let gapCount: Int
        let gapDuration: Double
        let end: Double
        let isMuted: Bool
        let isHidden: Bool
        let isLocked: Bool
    }

    var duration: Double = 0
    var clipCount = 0
    var transitions = 0
    var animatedClips = 0
    var effects = 0
    var gradedClips = 0
    var audioProcessedClips = 0
    var captions = 0
    var textLayers = 0
    var graphics = 0
    var videoClips = 0
    var imageClips = 0
    var audioClips = 0
    var adjustmentLayers = 0
    var mediaFiles = 0
    var missingFiles = 0
    var markers = 0
    var tracks: [TrackRow] = []
}

extension StudioViewModel {

    // MARK: Markers

    /// Moves a marker (dragged on the ruler); snapped to frames, coalesced into one undo step.
    func moveMarker(_ id: UUID, to time: Double, final: Bool) {
        guard editingCompoundID == nil else { return }
        let snapped = max(0, (time * frameRate).rounded() / frameRate)
        editProject("نقل علامة", coalesce: "marker-move-" + id.uuidString) { project in
            if let index = project.markers.firstIndex(where: { $0.id == id }) {
                project.markers[index].time = TimeValue(seconds: snapped)
            }
        }
        if final {
            undo.breakCoalescing()
            Haptics.selection()
        }
    }

    // MARK: Track colors

    static let trackPalette: [UInt32] = [0x5B8DEF, 0xB07CE8, 0xE3B04B, 0xE58F4A, 0xE25C55, 0x5FC48F, 0x4FB3A9, 0x9AA3B5]

    func setTrackColor(_ index: Int, _ color: RGBAColor?) {
        updateTrack(index, name: "لون المسار") { $0.color = color }
    }

    // MARK: Same source

    func selectSameSource(as clipID: UUID) {
        let ids = TimelineEngine.clipsSharingSource(with: clipID, in: timeline)
        guard ids.count > 0 else { return }
        selection = ids
        if ids.count > 1 { isMultiSelect = true }
        env.toasts.show("تم تحديد " + Fmt.int(ids.count) + " مقطع من نفس الملف", style: .info, duration: 1.6)
    }

    // MARK: Gaps

    func gapCount(onTrack index: Int) -> Int {
        guard timeline.tracks.indices.contains(index) else { return 0 }
        return TimelineEngine.gaps(in: timeline.tracks[index], context: editContext).count
    }

    /// Closes gaps on one track, or on every unlocked track when `index` is nil.
    func closeGaps(onTrack index: Int?) {
        var removed = 0.0
        let changed = edit("حذف الفراغات") { timeline, context in
            let targets = index.map { [$0] } ?? Array(timeline.tracks.indices)
            for t in targets where timeline.tracks.indices.contains(t) && !timeline.tracks[t].isLocked {
                removed += try TimelineEngine.closeGaps(onTrack: t, in: &timeline, context: context)
            }
        }
        if changed {
            env.toasts.show("تم حذف فراغات بطول " + Fmt.durationPrecise(removed), style: .success, duration: 1.8)
        } else {
            env.toasts.show("لا توجد فراغات بين المقاطع.", style: .info, duration: 1.6)
        }
    }

    // MARK: Snapshot

    /// Saves the frame under the playhead at full canvas resolution to Photos and the Exports folder.
    func saveSnapshot() {
        guard !timeline.isEmpty else {
            env.toasts.show("الخط الزمني فارغ.", style: .info)
            return
        }
        let timeline = self.timeline
        let settings = project.settings
        let media = env.library.urlMap()
        let time = currentTime
        let projectName = project.name
        let timecode = Fmt.timecode(time, fps: frameRate).replacingOccurrences(of: ":", with: "-")
        let (control, relay) = startBusy("لقطة من الإطار",
                                         detail: "بدقة " + Fmt.resolution(settings.canvasWidth, settings.canvasHeight),
                                         cancellable: false)
        relay.send(0.15)
        Task { [weak self] in
            do {
                let data = try await FrameSnapshot.render(timeline: timeline, settings: settings, media: media, at: time)
                relay.send(0.7)
                let storage = StorageManager.shared
                storage.ensureDirectories()
                let url = storage.uniqueURL(in: storage.exportsDirectory,
                                            baseName: storage.sanitizedFileName(projectName + " " + timecode), ext: "png")
                try data.write(to: url, options: .atomic)
                var savedToPhotos = true
                do {
                    try await PhotosSaver.saveImage(data)
                } catch {
                    savedToPhotos = false
                }
                guard let self, self.busy?.control === control else { return }
                self.busy = nil
                self.env.toasts.show(savedToPhotos ? "تم حفظ اللقطة في الصور وفي مجلد التصدير"
                                                   : "تم حفظ اللقطة في مجلد التصدير (لم يُسمح بالصور)",
                                     style: savedToPhotos ? .success : .warning)
            } catch {
                guard let self else { return }
                self.busy = nil
                self.report(error)
            }
        }
    }

    // MARK: Motion presets

    /// Applies a motion preset to the selected visual clips (one undo step).
    func applyMotionPreset(_ preset: MotionPreset, to ids: Set<UUID>? = nil) {
        let targets = ids ?? selection
        guard !targets.isEmpty else {
            env.toasts.show("حدّد مقطعًا أولاً.", style: .info)
            return
        }
        let frame = frameDuration
        let applied = edit("حركة: " + preset.name) { timeline, _ in
            for t in timeline.tracks.indices where timeline.tracks[t].kind.isVisual && !timeline.tracks[t].isLocked {
                for i in timeline.tracks[t].clips.indices where targets.contains(timeline.tracks[t].clips[i].id) {
                    if case .adjustment = timeline.tracks[t].clips[i].source { continue }
                    preset.apply(to: &timeline.tracks[t].clips[i], frame: frame)
                }
            }
        }
        if applied { env.toasts.show("تم تطبيق «" + preset.name + "»", style: .success, duration: 1.4) }
    }

    /// Saves a clip's transform animation as a reusable preset.
    @discardableResult
    func saveMotionPreset(from clipID: UUID, name: String) -> Bool {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return false }
        guard MotionPresetStore.shared.save(from: clip, name: name) != nil else {
            env.toasts.show("المقطع بدون إطارات مفتاحية للموضع أو الحجم أو الدوران أو الشفافية.", style: .info)
            return false
        }
        env.toasts.show("تم حفظ الحركة", style: .success)
        return true
    }

    /// Removes position/scale/rotation/opacity animation from the selection.
    func clearMotion() {
        updateSelection("إزالة الحركة") { clip in
            clip.transform.position.removeAllKeyframes(keeping: 0)
            clip.transform.scale.removeAllKeyframes(keeping: 0)
            clip.transform.rotation.removeAllKeyframes(keeping: 0)
            clip.transform.opacity.removeAllKeyframes(keeping: 0)
        }
    }

    // MARK: Aspect lock / stretch

    func setAspectLocked(_ locked: Bool, for clipID: UUID) {
        updateClip(clipID, name: locked ? "قفل النسبة" : "فك قفل النسبة") { $0.transform.aspectLocked = locked }
        endContinuousEdit()
    }

    func setStretch(_ stretch: Vec2, for clipID: UUID, coalesce: Bool = true) {
        let range = ClipTransform.stretchRange
        let clamped = Vec2(x: min(max(stretch.x, range.lowerBound), range.upperBound),
                           y: min(max(stretch.y, range.lowerBound), range.upperBound))
        updateClip(clipID, name: "تمديد الطبقة", coalesce: coalesce ? "stretch-" + clipID.uuidString : nil) {
            $0.transform.stretch = clamped
        }
    }

    func resetStretch(for clipID: UUID) {
        updateClip(clipID, name: "إعادة النسبة الأصلية") { $0.transform.stretch = .one }
        endContinuousEdit()
    }

    // MARK: Summary

    var projectSummary: ProjectSummaryData {
        var data = ProjectSummaryData()
        let current = timeline
        let context = editContext
        data.duration = current.duration.seconds
        data.markers = markers.count
        var assets: Set<UUID> = []
        for (index, track) in current.tracks.enumerated() {
            let clips = track.clips.sorted { $0.start < $1.start }
            var covered = 0.0
            var reach = -Double.greatestFiniteMagnitude
            var transitions = 0
            for clip in clips {
                let s = clip.start.seconds, e = clip.end.seconds
                covered += max(0, e - max(s, reach))
                reach = max(reach, e)
                if clip.transitionIn != nil { transitions += 1 }
                data.clipCount += 1
                assets.formUnion(clip.source.assetIDs)
                if clip.isAnimated(.position) || clip.isAnimated(.scale) || clip.isAnimated(.rotation) || clip.isAnimated(.opacity) {
                    data.animatedClips += 1
                }
                data.effects += clip.effects.filter(\.isEnabled).count
                if clip.color != .neutral || clip.lut != nil { data.gradedClips += 1 }
                if !clip.audio.effects.isNeutral { data.audioProcessedClips += 1 }
                switch clip.source {
                case .media:
                    if track.kind == .audio { data.audioClips += 1 } else { data.videoClips += 1 }
                case .image, .freezeFrame: data.imageClips += 1
                case .text(let content):
                    if content.isCaption { data.captions += 1 } else { data.textLayers += 1 }
                case .shape, .sticker, .solidColor: data.graphics += 1
                case .adjustment: data.adjustmentLayers += 1
                }
            }
            data.transitions += transitions
            let gaps = TimelineEngine.gaps(in: track, context: context)
            data.tracks.append(ProjectSummaryData.TrackRow(
                id: track.id, index: index, name: track.name, kind: track.kind, color: track.color,
                clipCount: clips.count, coveredDuration: max(0, covered), transitions: transitions,
                gapCount: gaps.count, gapDuration: gaps.reduce(0) { $0 + $1.duration },
                end: track.endTime.seconds, isMuted: track.isMuted, isHidden: track.isHidden, isLocked: track.isLocked))
        }
        let rows = data.tracks
        data.tracks = TimelineEngine.displayOrder(current).compactMap { index in rows.first { $0.index == index } }
        data.mediaFiles = assets.count
        data.missingFiles = assets.filter { id in env.library.asset(id).map { env.library.isMissing($0) } ?? true }.count
        return data
    }
}
