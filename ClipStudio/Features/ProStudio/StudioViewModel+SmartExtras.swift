//
//  StudioViewModel+SmartExtras.swift
//  ClipStudio — Features/ProStudio (Part 4 suggestions)
//
//  Privacy blur that follows every face, masks / spotlights that follow a subject,
//  horizon leveling, fitting the music to the video, matching every shot's color to
//  one reference shot and ducking music under a separated voice. Analyses run on
//  device with progress + cancel; each timeline change is one undo step.
//

import Foundation
import SwiftUI
import CoreImage

extension StudioViewModel {

    // MARK: Privacy blur

    /// Every face in the clip as its own track (cached per file + range).
    func detectFaces(clipID: UUID) async -> [SubjectTrack]? {
        guard let source = videoSource(clipID), let span = sourceSpan(of: source.clip) else { return nil }
        if let cached = FaceTracker.cached(assetID: source.asset.id, span: span) { return cached }
        let (control, relay) = startBusy("البحث عن الوجوه", detail: "على جهازك — لا يُرفع شيء")
        do {
            let tracks = try await FaceTracker.detect(assetID: source.asset.id, url: source.url, span: span, control: control,
                                                      progress: { relay.send($0) })
            busy = nil
            if control.isCancelled { env.toasts.show("تم الإلغاء", style: .info); return nil }
            if tracks.isEmpty { env.toasts.show("لم يُعثر على وجوه في هذا المقطع.", style: .info) }
            return tracks
        } catch {
            busy = nil
            if !control.isCancelled { report(error) }
            return nil
        }
    }

    /// A blurred / pixelated copy of the clip above it, visible only inside a mask that
    /// follows each face. The original clip is untouched; the copies are silent.
    func addPrivacyBlur(clipID: UUID, tracks: [SubjectTrack], style: PrivacyStyle, amount: Double, padding: Double) {
        guard let base = TimelineEngine.clip(clipID, in: timeline) else { return }
        var copies: [Clip] = []
        for (index, track) in tracks.enumerated() {
            guard var path = ReframeEngine.maskPath(track: track, clip: base, smoothing: 0.25, padding: padding) else { continue }
            hideOutside(&path, duration: base.duration.seconds)
            var copy = base
            copy.id = UUID()
            copy.name = "تمويه " + Fmt.int(index + 1) + " — " + base.name
            copy.transitionIn = nil
            copy.audio.isMuted = true
            copy.audio.volume = KeyframedValue(0)
            var effect = EffectInstance(kind: style.effect)
            effect.intensity = KeyframedValue(min(1, max(0.1, amount)))
            copy.effects = [effect]
            var mask = MaskSettings()
            mask.isEnabled = true
            mask.shape = .ellipse
            mask.center = path.center.base
            mask.size = path.size.base
            mask.feather = 0.2
            mask.centerTrack = path.center
            mask.sizeTrack = path.size
            copy.mask = mask
            copy.label = RGBAColor(hex: 0xE5484D)
            copies.append(copy)
        }
        guard !copies.isEmpty else {
            env.toasts.show("لا توجد وجوه كافية للتمويه.", style: .info)
            return
        }
        var placed: [UUID] = []
        let changed = edit("تمويه الوجوه") { timeline, context in
            for copy in copies {
                placed.append(try TimelineEngine.insertLayer(copy, kind: .overlay, at: base.start.seconds, in: &timeline, context: context))
            }
        }
        guard changed else { return }
        selection = Set(placed)
        Haptics.success()
        env.toasts.show("تمويه " + Fmt.int(placed.count) + " وجه يتبع الحركة — المقطع الأصلي كما هو", style: .success)
    }

    /// Size 0 outside the span where the subject was seen (so the effect disappears with it).
    private func hideOutside(_ path: inout SubjectMaskPath, duration: Double) {
        let lead = path.firstLocal - 0.25, tail = path.lastLocal + 0.25
        var keys = path.size.keyframes.isEmpty ? [Keyframe(time: path.firstLocal, value: path.size.base, easing: .linear)] : path.size.keyframes
        keys = keys.filter { $0.time >= lead && $0.time <= tail }
        if lead > 0 { keys.insert(Keyframe(time: lead, value: Vec2(x: 0, y: 0), easing: .linear), at: 0) }
        if tail < duration { keys.append(Keyframe(time: tail, value: Vec2(x: 0, y: 0), easing: .linear)) }
        keys.sort { $0.time < $1.time }
        path.size = KeyframedValue(keys.first?.value ?? path.size.base, keyframes: keys.count > 1 ? keys : [])
    }

    // MARK: Subject masks

    /// The clip itself is shown only inside a soft mask that follows the subject.
    func applySubjectMask(clipID: UUID, track: SubjectTrack, padding: Double, invert: Bool) {
        guard let base = TimelineEngine.clip(clipID, in: timeline),
              let path = ReframeEngine.maskPath(track: track, clip: base, smoothing: 0.4, padding: padding) else {
            env.toasts.show("لم يُعثر على العنصر لعمل القناع.", style: .info)
            return
        }
        updateClip(clipID, name: "قناع يتبع العنصر") { clip in
            var mask = clip.mask ?? MaskSettings()
            mask.isEnabled = true
            mask.shape = .ellipse
            mask.feather = max(mask.feather, 0.3)
            mask.invert = invert
            mask.center = path.center.base
            mask.size = path.size.base
            mask.centerTrack = path.center
            mask.sizeTrack = path.size
            clip.mask = mask
        }
        endContinuousEdit()
        env.toasts.show("القناع يتبع العنصر — تقدر تعدّل الحواف من «القناع»", style: .success)
    }

    func removeSubjectMask(clipID: UUID) {
        updateClip(clipID, name: "إلغاء قناع التتبع") { clip in
            clip.mask?.centerTrack = nil
            clip.mask?.sizeTrack = nil
        }
        endContinuousEdit()
    }

    /// Spotlight: the clip turns black & white, and a color copy shows only the subject.
    func addSpotlight(clipID: UUID, track: SubjectTrack, padding: Double) {
        guard let base = TimelineEngine.clip(clipID, in: timeline),
              let path = ReframeEngine.maskPath(track: track, clip: base, smoothing: 0.4, padding: padding) else {
            env.toasts.show("لم يُعثر على العنصر.", style: .info)
            return
        }
        var copy = base
        copy.id = UUID()
        copy.name = "إبراز — " + base.name
        copy.transitionIn = nil
        copy.audio.isMuted = true
        copy.audio.volume = KeyframedValue(0)
        copy.effects.removeAll { $0.kind == .monochrome }
        var mask = MaskSettings()
        mask.isEnabled = true
        mask.shape = .ellipse
        mask.feather = 0.35
        mask.center = path.center.base
        mask.size = path.size.base
        mask.centerTrack = path.center
        mask.sizeTrack = path.size
        copy.mask = mask
        var placed: UUID?
        let changed = edit("إبراز العنصر") { timeline, context in
            TimelineEngine.updateClips([clipID], in: &timeline) { clip in
                if !clip.effects.contains(where: { $0.kind == .monochrome }) {
                    clip.effects.append(EffectInstance(kind: .monochrome))
                }
            }
            placed = try TimelineEngine.insertLayer(copy, kind: .overlay, at: base.start.seconds, in: &timeline, context: context)
        }
        guard changed else { return }
        if let placed { selection = [placed] }
        Haptics.success()
        env.toasts.show("الخلفية بالأبيض والأسود والعنصر بالألوان", style: .success)
    }

    // MARK: Horizon

    func levelHorizon(clipID: UUID, strength: Double) {
        guard let source = videoSource(clipID) else { return }
        guard source.clip.speed.ramp.isEmpty else {
            env.toasts.show("ضبط الأفق غير متاح مع منحنى السرعة.", style: .info)
            return
        }
        let assetID = source.asset.id
        let duration = source.asset.durationSeconds ?? 0
        let (control, relay) = startBusy("ضبط الأفق", detail: "قياس ميلان الكاميرا على جهازك (مرة واحدة لكل ملف)")
        Task { [weak self] in
            do {
                let data = try await HorizonAnalyzer.analyze(assetID: assetID, url: source.url, duration: duration,
                                                             control: control, progress: { relay.send($0) })
                guard let self else { return }
                self.busy = nil
                if control.isCancelled { self.env.toasts.show("تم الإلغاء", style: .info); return }
                let found = data.confidence.filter { $0 > 0.05 }.count
                guard found > 0 else {
                    self.env.toasts.show("لم يُعثر على أفق واضح في هذا المقطع.", style: .info)
                    return
                }
                HorizonStore.shared.insert(data)
                self.updateClip(clipID, name: "ضبط الأفق") { clip in
                    clip.horizon = HorizonSettings(isEnabled: true, strength: strength, smoothing: 0.6, assetID: assetID)
                }
                self.endContinuousEdit()
                let measured = zip(data.angles, data.confidence).filter { $0.1 > 0.05 }.map { abs($0.0) }
                let average = measured.reduce(0, +) / Double(max(1, measured.count)) * 180 / .pi
                Haptics.success()
                self.env.toasts.show("تم ضبط الأفق — متوسط الميلان " + Fmt.number(average, digits: 1) + "°", style: .success)
            } catch {
                self?.busy = nil
                if !control.isCancelled { self?.report(error) }
            }
        }
    }

    func setHorizon(clipID: UUID, _ change: @escaping (inout HorizonSettings) -> Void) {
        updateClip(clipID, name: "ضبط الأفق", coalesce: "horizon-" + clipID.uuidString) { clip in
            guard var settings = clip.horizon else { return }
            change(&settings)
            settings.strength = min(1, max(0, settings.strength))
            settings.smoothing = min(3, max(0, settings.smoothing))
            clip.horizon = settings
        }
    }

    func removeHorizon(clipID: UUID) {
        updateClip(clipID, name: "إلغاء ضبط الأفق") { $0.horizon = nil }
        endContinuousEdit()
    }

    // MARK: Music fit

    /// End of the picture (last visual clip).
    var pictureEnd: Double {
        timeline.tracks.filter { $0.kind == .video || $0.kind == .overlay }.map(\.endTime.seconds).max() ?? timeline.duration.seconds
    }

    func fitMusic(clipID: UUID, analysis: MusicAnalysis, mode: MusicFitMode, fadeOut: Double) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), let ref = TimelineEngine.locate(clipID, in: timeline) else { return }
        let end = pictureEnd
        guard end > clip.start.seconds + 0.5 else {
            env.toasts.show("لا يوجد فيديو بعد بداية الموسيقى.", style: .info)
            return
        }
        var placed: [UUID] = []
        let changed = edit("ملاءمة الموسيقى") { timeline, context in
            let pieces = try MusicFit.fit(clip, analysis: analysis, to: end, mode: mode, fadeOut: fadeOut, context: context)
            timeline.tracks[ref.track].clips.removeAll { $0.id == clipID }
            placed = try TimelineEngine.place(pieces, onTrack: ref.track, at: clip.start.seconds, mode: .overwrite,
                                              in: &timeline, context: context)
        }
        guard changed else { return }
        selection = Set(placed)
        Haptics.success()
        let text = placed.count > 1 ? "تكررت الموسيقى " + Fmt.int(placed.count) + " مرات وتنتهي على مازورة" : "الموسيقى تنتهي مع الفيديو على مازورة"
        env.toasts.show(text, style: .success)
    }

    // MARK: Color match all

    func matchAllColors(to referenceClipID: UUID, strength: Double) {
        guard let reference = TimelineEngine.clip(referenceClipID, in: timeline) else { return }
        let targets = EditingDNAApplier.pictureClips(timeline).filter { $0.id != referenceClipID }
        guard !targets.isEmpty else {
            env.toasts.show("لا توجد لقطات أخرى للمطابقة.", style: .info)
            return
        }
        let media = env.library.urlMap()
        let canvas = canvasSize
        let local = min(max(0, currentTime - reference.start.seconds), reference.duration.seconds)
        let referenceTime = (local > 0 && local < reference.duration.seconds) ? local : reference.duration.seconds / 2
        let (control, relay) = startBusy("مطابقة الألوان", detail: Fmt.int(targets.count) + " لقطة مع «" + reference.name + "»")
        Task { [weak self] in
            guard let frame = await ColorMatchBatch.referenceFrame(of: reference, media: media, canvas: canvas, at: referenceTime) else {
                self?.busy = nil
                self?.env.toasts.show("تعذرت قراءة اللقطة المرجعية.", style: .warning)
                return
            }
            let grades = await ColorMatchBatch.match(reference: frame, clips: targets, media: media, canvas: canvas,
                                                     strength: strength, control: control, progress: { relay.send($0) })
            guard let self else { return }
            self.busy = nil
            if control.isCancelled { self.env.toasts.show("تم الإلغاء", style: .info); return }
            let changed = self.edit("مطابقة ألوان كل اللقطات") { timeline, _ in
                TimelineEngine.updateClips(Set(grades.keys), in: &timeline) { clip in
                    if let grade = grades[clip.id] { clip.color = grade }
                }
            }
            if changed {
                Haptics.success()
                self.env.toasts.show("طُوبقت ألوان " + Fmt.int(grades.count) + " لقطة", style: .success)
            }
        }
    }

    // MARK: Ducking under a separated voice

    /// Dips the background stem and music tracks wherever the voice track speaks.
    func duckUnderVoice(voiceTrackID: UUID, extraTargets: Set<UUID>) {
        var targets = extraTargets
        for track in timeline.tracks where track.kind == .audio && track.id != voiceTrackID {
            let lower = track.name.lowercased()
            if EditingDNAAnalyzer.musicWords.contains(where: { lower.contains($0) }) { targets.insert(track.id) }
        }
        guard !targets.isEmpty else { return }
        var settings = DuckingSettings()
        settings.triggerTrackIDs = [voiceTrackID]
        settings.targetTrackIDs = targets
        applyDucking(settings)
    }
}
