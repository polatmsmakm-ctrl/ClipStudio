//
//  StudioViewModel+Audio.swift
//  ClipStudio — Features/ProStudio (Audio Studio, Part 3)
//
//  Editor commands for sound: per-clip effects and presets, track solo / balance,
//  loudness normalization, automatic ducking, voiceover placement, sound effects,
//  audio extraction to a file and audio-only export of the mix. Live levels for
//  the mixer come from the preview's processing taps.
//

import Foundation
import SwiftUI
import AVFoundation

extension StudioViewModel {

    // MARK: Effects

    /// Changes the audio effects of the selected clips (or `clipID`) — heard immediately.
    func updateAudioEffects(_ name: String, clipID: UUID? = nil, coalesce: String? = nil,
                            _ change: @escaping (inout AudioEffects) -> Void) {
        if let clipID, !selection.contains(clipID) {
            updateClip(clipID, name: name, coalesce: coalesce) { change(&$0.audio.effects) }
        } else {
            updateSelection(name, coalesce: coalesce) { change(&$0.audio.effects) }
        }
    }

    func applyAudioPreset(_ preset: AudioEffectPreset, clipID: UUID? = nil) {
        updateAudioEffects("صوت: " + preset.title, clipID: clipID) { preset.apply(to: &$0) }
        endContinuousEdit()
        env.toasts.show("تم تطبيق «" + preset.title + "»", style: .success, duration: 1.3)
    }

    /// Clips of the selection that can carry sound.
    var selectedAudioClips: [Clip] {
        selectedClips.filter { clip in
            switch clip.source {
            case .media(let id):
                guard let asset = env.library.asset(id) else { return false }
                return asset.kind == .audio || asset.hasAudio
            default:
                return false
            }
        }
    }

    // MARK: Tracks

    func toggleSolo(_ index: Int) {
        updateTrack(index, name: "عزل المسار") { $0.isSolo.toggle() }
    }

    func clearSolo() {
        edit("إلغاء العزل") { timeline, _ in
            for index in timeline.tracks.indices { timeline.tracks[index].isSolo = false }
        }
    }

    func setTrackPan(_ index: Int, _ value: Double) {
        updateTrack(index, name: "توازن المسار", coalesce: "track-pan-" + String(index)) { $0.pan = min(max(value, -1), 1) }
    }

    /// Current output level of a track (0…1 peak, RMS) during playback.
    func meterLevel(trackID: UUID) -> (peak: Float, rms: Float) {
        built?.audioMeters.level(for: trackID) ?? (0, 0)
    }

    // MARK: Volume automation

    func addVolumeKeyframe(clipID: UUID, at localTime: Double, value: Double) {
        updateClip(clipID, name: "نقطة مستوى الصوت") { clip in
            clip.audio.volume.addKeyframe(at: min(max(0, localTime), clip.duration.seconds), value: min(max(value, 0), 1))
        }
        endContinuousEdit()
    }

    func moveVolumeKeyframe(clipID: UUID, keyframeID: UUID, time: Double, value: Double) {
        updateClip(clipID, name: "تعديل مستوى الصوت", coalesce: "volume-key-" + keyframeID.uuidString) { clip in
            guard let index = clip.audio.volume.keyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
            let keys = clip.audio.volume.keyframes
            let lower = index > 0 ? keys[index - 1].time + 0.01 : 0
            let upper = index < keys.count - 1 ? keys[index + 1].time - 0.01 : clip.duration.seconds
            clip.audio.volume.keyframes[index].time = min(max(time, lower), max(lower, upper))
            clip.audio.volume.keyframes[index].value = min(max(value, 0), 1)
        }
    }

    func removeVolumeKeyframe(clipID: UUID, keyframeID: UUID) {
        updateClip(clipID, name: "حذف نقطة مستوى الصوت") { $0.audio.volume.removeKeyframe(id: keyframeID) }
        endContinuousEdit()
    }

    func setBaseVolume(clipID: UUID, value: Double) {
        updateClip(clipID, name: "مستوى الصوت", coalesce: "volume-base-" + clipID.uuidString) {
            $0.audio.volume.base = min(max(value, 0), 1)
        }
    }

    // MARK: Loudness normalization

    /// Measures each selected clip (BS.1770) and sets its gain to reach `target`.
    func normalizeLoudness(target: LoudnessTarget, clipIDs: [UUID]? = nil) {
        let ids = clipIDs ?? selectedAudioClips.map(\.id)
        let jobs: [(UUID, URL, CMTimeRangeValue)] = ids.compactMap { id in
            guard let clip = TimelineEngine.clip(id, in: timeline), case .media(let assetID) = clip.source,
                  let url = env.library.url(forID: assetID), let range = clip.sourceRange else { return nil }
            return (id, url, CMTimeRangeValue(start: range.start.seconds, end: range.end.seconds))
        }
        guard !jobs.isEmpty else {
            env.toasts.show("حدّد مقاطع فيها صوت.", style: .info)
            return
        }
        let (control, relay) = startBusy("تسوية مستوى الصوت", detail: "قياس الجهارة على جهازك")
        Task { [weak self] in
            var gains: [UUID: Double] = [:]
            var silent = 0
            for (index, job) in jobs.enumerated() {
                if control.isCancelled { break }
                do {
                    let result = try await LoudnessAnalyzer.measure(url: job.1, range: job.2.cmTimeRange, control: control)
                    if result.isSilent {
                        silent += 1
                    } else {
                        var gain = target.rawValue - result.integrated
                        // Keep the peak under −1 dBFS when the limiter would have too much work.
                        gain = min(gain, -1 - result.peak + 6)
                        gains[job.0] = min(max(gain, -24), 24)
                    }
                } catch {
                    if control.isCancelled { break }
                }
                relay.send(Double(index + 1) / Double(jobs.count))
            }
            guard let self else { return }
            self.busy = nil
            if control.isCancelled {
                self.env.toasts.show("تم الإلغاء", style: .info)
                return
            }
            guard !gains.isEmpty else {
                self.env.toasts.show("المقاطع المختارة صامتة.", style: .info)
                return
            }
            self.edit("تسوية مستوى الصوت") { timeline, _ in
                TimelineEngine.updateClips(Set(gains.keys), in: &timeline) { clip in
                    clip.audio.effects.gainDB = (gains[clip.id] ?? 0)
                    clip.audio.effects.limiter = true
                }
            }
            let note = silent > 0 ? " (" + Fmt.int(silent) + " صامت)" : ""
            self.env.toasts.show("تمت تسوية " + Fmt.int(gains.count) + " مقطع" + note, style: .success)
        }
    }

    // MARK: Ducking

    /// Default ducking setup: voice = audio tracks named for voice + the primary video track, music = the rest.
    func defaultDuckingSettings() -> DuckingSettings {
        var settings = DuckingSettings()
        let audioTracks = timeline.tracks.filter { $0.kind == .audio }
        let voiceWords = ["تعليق", "حوار", "صوت", "متحدث", "voice", "dialog"]
        let musicWords = ["موسيقى", "music", "مؤثر"]
        for track in audioTracks {
            let name = track.name.lowercased()
            if musicWords.contains(where: { name.contains($0) }) {
                settings.targetTrackIDs.insert(track.id)
            } else if voiceWords.contains(where: { name.contains($0) }) {
                settings.triggerTrackIDs.insert(track.id)
            }
        }
        if let primary = TimelineEngine.primaryTrackIndex(timeline, context: editContext) { settings.triggerTrackIDs.insert(timeline.tracks[primary].id) }
        if settings.targetTrackIDs.isEmpty, let last = audioTracks.last, !settings.triggerTrackIDs.contains(last.id) {
            settings.targetTrackIDs.insert(last.id)
        }
        return settings
    }

    func applyDucking(_ settings: DuckingSettings) {
        guard !settings.triggerTrackIDs.isEmpty, !settings.targetTrackIDs.isEmpty else {
            env.toasts.show("اختر مسار الصوت ومسار الموسيقى.", style: .info)
            return
        }
        let current = timeline
        let triggers = current.tracks.filter { settings.triggerTrackIDs.contains($0.id) && !$0.isMuted }
        var jobs: [(Clip, UUID, URL)] = []
        for track in triggers {
            for clip in track.clips {
                guard case .media(let assetID) = clip.source, let asset = env.library.asset(assetID),
                      asset.kind == .audio || asset.hasAudio, let url = env.library.url(forID: assetID) else { continue }
                jobs.append((clip, assetID, url))
            }
        }
        guard !jobs.isEmpty else {
            env.toasts.show("لا يوجد كلام في مسارات الصوت المختارة.", style: .info)
            return
        }
        let (control, relay) = startBusy("خفض الموسيقى تلقائيًا", detail: "تحليل مواضع الكلام")
        Task { [weak self] in
            var regions: [TimeSpan] = []
            for (index, job) in jobs.enumerated() {
                if control.isCancelled { break }
                if let waveform = await WaveformService.shared.waveform(assetID: job.1, url: job.2) {
                    regions += DuckingEngine.speechRegions(of: job.0, waveform: waveform, thresholdDB: settings.thresholdDB)
                }
                relay.send(Double(index + 1) / Double(jobs.count))
            }
            guard let self else { return }
            self.busy = nil
            guard !control.isCancelled else { return }
            let speech = DuckingEngine.consolidate(regions, hold: settings.hold)
            guard !speech.isEmpty else {
                self.env.toasts.show("لم يُعثر على كلام أعلى من الحد المختار.", style: .info)
                return
            }
            var ducked = 0
            self.edit("خفض الموسيقى تلقائيًا") { timeline, _ in
                for t in timeline.tracks.indices where settings.targetTrackIDs.contains(timeline.tracks[t].id) && !timeline.tracks[t].isLocked {
                    for c in timeline.tracks[t].clips.indices {
                        if DuckingEngine.apply(to: &timeline.tracks[t].clips[c], speech: speech, settings: settings) { ducked += 1 }
                    }
                }
            }
            self.showsVolumeAutomation = true
            self.env.toasts.show(ducked > 0 ? "تم خفض الموسيقى في " + Fmt.int(ducked) + " مقطع" : "لا توجد موسيقى تتقاطع مع الكلام.",
                                 style: ducked > 0 ? .success : .info)
        }
    }

    // MARK: Voiceover

    /// Places a recorded take on a voiceover track at `start` (overwrite on a free track).
    func placeVoiceover(fileURL: URL, at start: Double, duration: Double) {
        let library = env.library
        Task { [weak self] in
            do {
                let name = "تعليق صوتي " + Fmt.timecode(start, fps: 30)
                let asset = try await library.registerGenerated(file: fileURL, displayName: name, kind: .audio)
                guard let self else { return }
                let length = max(self.frameDuration, ((asset.durationSeconds ?? duration) * self.frameRate).rounded(.down) / self.frameRate)
                var clip = Clip(name: asset.displayName, source: .media(asset.id), start: TimeValue(seconds: start),
                                duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
                clip.audio.effects.highPassHz = 80
                let preferred = self.timeline.tracks.firstIndex { $0.kind == .audio && $0.name.contains("تعليق") }
                var placedID: UUID?
                self.edit("تسجيل تعليق صوتي") { timeline, context in
                    placedID = try TimelineEngine.insertLayer(clip, kind: .audio, at: start, preferring: preferred,
                                                              in: &timeline, context: context)
                }
                if let placedID { self.selection = [placedID] }
                self.env.toasts.show("تمت إضافة التعليق الصوتي", style: .success)
            } catch {
                self?.report(error)
            }
        }
    }

    // MARK: Sound effects

    func addSoundEffect(_ effect: SoundEffect) {
        let library = env.library
        let start = currentTime
        Task { [weak self] in
            do {
                let asset = try await SoundEffectsLibrary.shared.asset(for: effect, library: library)
                guard let self else { return }
                let length = max(self.frameDuration, ((asset.durationSeconds ?? effect.duration) * self.frameRate).rounded(.down) / self.frameRate)
                let clip = Clip(name: effect.title, source: .media(asset.id), start: TimeValue(seconds: start),
                                duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length))
                let preferred = self.timeline.tracks.firstIndex { $0.kind == .audio && $0.name.contains("مؤثر") }
                var placedID: UUID?
                self.edit("مؤثر صوتي: " + effect.title) { timeline, context in
                    placedID = try TimelineEngine.insertLayer(clip, kind: .audio, at: start, preferring: preferred,
                                                              in: &timeline, context: context)
                }
                if let placedID { self.selection = [placedID] }
                Haptics.success()
            } catch {
                self?.report(error)
            }
        }
    }

    // MARK: Extraction & audio export

    /// Saves the used audio of a clip as a new audio file in the media library.
    func extractAudio(clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), case .media(let assetID) = clip.source,
              let asset = env.library.asset(assetID), asset.hasAudio || asset.kind == .audio,
              let url = env.library.url(forID: assetID), let range = clip.sourceRange else {
            env.toasts.show("هذا المقطع بدون صوت.", style: .info)
            return
        }
        let library = env.library
        let output = StorageManager.shared.stagingURL(extension: "m4a")
        let source = CMTimeRangeValue(start: range.start.seconds, end: range.end.seconds)
        let (control, relay) = startBusy("استخراج الصوت", detail: asset.displayName)
        relay.send(0.1)
        Task { [weak self] in
            do {
                try await AudioExtractor.extract(from: url, range: source.cmTimeRange, to: output, control: control)
                relay.send(0.85)
                let extracted = try await library.registerGenerated(file: output, displayName: "صوت - " + asset.displayName, kind: .audio)
                guard let self else { return }
                self.busy = nil
                self.env.toasts.show("تمت إضافة «" + extracted.displayName + "» لمكتبة الوسائط", style: .success)
            } catch {
                guard let self else { return }
                self.busy = nil
                if case AudioExportError.cancelled = error { return }
                self.report(error)
            }
        }
    }

    /// Exports the mix (whole project or in/out range) to an .m4a in the Exports folder.
    func exportAudioMix(useInOut: Bool, completion: @escaping (URL) -> Void) {
        guard !timeline.isEmpty else {
            env.toasts.show("الخط الزمني فارغ.", style: .info)
            return
        }
        let timeline = self.timeline
        let settings = project.settings
        let media = env.library.urlMap()
        let range = useInOut ? inOutRange.map { TimeSpan(start: $0.0, end: $0.1) } : nil
        let storage = StorageManager.shared
        storage.ensureDirectories()
        let output = storage.uniqueURL(in: storage.exportsDirectory, baseName: storage.sanitizedFileName(project.name + " - صوت"), ext: "m4a")
        let (control, relay) = startBusy("تصدير الصوت", detail: "M4A (AAC) — كل المسارات والمعالجة")
        Task { [weak self] in
            do {
                try await AudioExtractor.exportMix(timeline: timeline, settings: settings, media: media, range: range,
                                                   to: output, control: control) { relay.send($0) }
                guard let self else { return }
                self.busy = nil
                self.env.toasts.show("تم حفظ الصوت في مجلد التصدير", style: .success)
                completion(output)
            } catch {
                guard let self else { return }
                self.busy = nil
                if case AudioExportError.cancelled = error {
                    self.env.toasts.show("تم إلغاء تصدير الصوت", style: .info)
                } else {
                    self.report(error)
                }
            }
        }
    }
}

/// Sendable seconds range that converts to CMTimeRange where needed.
struct CMTimeRangeValue: Hashable, Sendable {
    let start: Double
    let end: Double

    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}
