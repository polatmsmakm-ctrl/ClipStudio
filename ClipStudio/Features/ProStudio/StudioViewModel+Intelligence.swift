//
//  StudioViewModel+Intelligence.swift
//  ClipStudio — Features/ProStudio (Part 4)
//
//  Editor commands for the on-device intelligence features: smart reframe and
//  subject / object tracking, stabilization, music analysis and beat sync,
//  Editing DNA (learn / apply), audio separation, the Quality Inspector, multi-
//  format variants and saving the project as a template. Long analyses run off
//  the main thread with real progress and can be cancelled; every change to the
//  timeline is one undo step.
//

import Foundation
import SwiftUI
import CoreMedia
import CoreImage

extension StudioViewModel {

    // MARK: Shared

    var assetsByID: [UUID: MediaAsset] {
        Dictionary(env.library.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Source-time span a clip plays (forward), for analyses.
    func sourceSpan(of clip: Clip) -> TimeSpan? {
        guard let range = clip.sourceRange else { return nil }
        return TimeSpan(start: range.start.seconds, end: range.end.seconds)
    }

    /// Video clip + its file, or nil with a toast.
    func videoSource(_ clipID: UUID) -> (clip: Clip, asset: MediaAsset, url: URL)? {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), case .media(let id) = clip.source,
              let asset = env.library.asset(id), asset.kind == .video, let url = env.library.url(forID: id),
              !env.library.isMissing(asset) else {
            env.toasts.show("هذه الأداة لمقاطع الفيديو الموجودة في المكتبة.", style: .info)
            return nil
        }
        return (clip: clip, asset: asset, url: url)
    }

    /// The primary clip when it is a video in the library (target of the smart tools).
    var primaryVideoClipID: UUID? {
        guard let clip = primaryClip, case .media(let id) = clip.source, env.library.asset(id)?.kind == .video else { return nil }
        return clip.id
    }

    /// The primary clip when it carries sound (target of audio separation).
    var primarySoundClipID: UUID? {
        guard let clip = primaryClip, case .media(let id) = clip.source, let asset = env.library.asset(id),
              asset.kind == .audio || asset.hasAudio else { return nil }
        return clip.id
    }

    private func finishBusy(_ control: RenderControl) -> Bool {
        busy = nil
        if control.isCancelled {
            env.toasts.show("تم الإلغاء", style: .info)
            return false
        }
        return true
    }

    // MARK: Subject tracking & reframe

    /// Detects the subject across the clip (cached per file + range).
    func detectSubject(clipID: UUID, mode: SubjectMode) async -> SubjectTrack? {
        guard let source = videoSource(clipID), let span = sourceSpan(of: source.clip) else { return nil }
        if let cached = SubjectTracker.cached(assetID: source.asset.id, mode: mode, span: span) { return cached }
        let (control, relay) = startBusy("تحليل العنصر الأساسي", detail: mode.title + " — على جهازك")
        do {
            let track = try await SubjectTracker.detect(assetID: source.asset.id, url: source.url, span: span, mode: mode,
                                                        control: control, progress: { relay.send($0) })
            guard finishBusy(control) else { return nil }
            if track.coverage < 0.05 {
                env.toasts.show("لم يتم العثور على " + mode.title + " في هذا المقطع.", style: .info)
            }
            return track
        } catch {
            busy = nil
            if !control.isCancelled { report(error) }
            return nil
        }
    }

    /// Source time where object selection happens (start of the clip's source range).
    func objectSelectionLocalTime(_ clip: Clip) -> Double {
        guard let range = clip.sourceRange else { return 0 }
        return SpeedMapping.localTime(of: clip, sourceTime: range.start.seconds) ?? 0
    }

    /// Picture at the start of the clip's source range (for drawing the object box).
    func objectSelectionFrame(clipID: UUID) async -> UIImage? {
        guard let clip = TimelineEngine.clip(clipID, in: timeline) else { return nil }
        let media = env.library.urlMap()
        guard let frame = await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: objectSelectionLocalTime(clip),
                                                                       media: media, canvas: canvasSize, maxDimension: 900) else {
            return nil
        }
        return FramePreviewRenderer.shared.uiImage(frame)
    }

    /// Follows a user-drawn box (top-left normalized) through the clip.
    func trackObject(clipID: UUID, initial: RectValue) async -> SubjectTrack? {
        guard let source = videoSource(clipID), let span = sourceSpan(of: source.clip) else { return nil }
        let (control, relay) = startBusy("تتبع العنصر", detail: "Vision على جهازك")
        do {
            let track = try await SubjectTracker.trackObject(assetID: source.asset.id, url: source.url, span: span,
                                                             initial: initial.clamped(), control: control,
                                                             progress: { relay.send($0) })
            guard finishBusy(control) else { return nil }
            let lostAt = track.samples.first { $0.confidence == 0 }?.time
            if let lostAt, let local = SpeedMapping.localTime(of: source.clip, sourceTime: lostAt) {
                env.toasts.show("فُقد العنصر عند " + Fmt.durationPrecise(local) + " — ثُبّت آخر موضع بعدها.", style: .warning)
            } else {
                env.toasts.show("تم تتبع العنصر", style: .success)
            }
            return track
        } catch {
            busy = nil
            if !control.isCancelled { report(error) }
            return nil
        }
    }

    /// Crops the clip so it fills the canvas while following `track`.
    func applyReframe(clipID: UUID, track: SubjectTrack, zoom: Double, smoothing: Double) {
        let aspect = Double(canvasSize.width / max(1, canvasSize.height))
        updateClip(clipID, name: "إعادة تأطير ذكية") { clip in
            clip.crop = ReframeEngine.cropKeyframes(for: clip, track: track, targetAspect: aspect, smoothing: smoothing, zoom: zoom)
            clip.fitMode = .fill
            clip.transform.scale = KeyframedValue(1.0)
            clip.transform.position = KeyframedValue(Vec2.center)
        }
        endContinuousEdit()
        Haptics.success()
        env.toasts.show("الكاميرا تتبع العنصر الآن — عدّل بالإطارات المفتاحية في «القص» إن أردت.", style: .success)
    }

    /// Plain centred crop that fills the canvas.
    func centerReframe(clipID: UUID) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), let asset = asset(for: clip),
              let w = asset.pixelWidth, let h = asset.pixelHeight else { return }
        let aspect = Double(canvasSize.width / max(1, canvasSize.height))
        let crop = OutputVariants.centeredCrop(in: .full, sourceWidth: Double(w), sourceHeight: Double(h), targetAspect: aspect)
        updateClip(clipID, name: "قص من الوسط") { clip in
            clip.crop = KeyframedValue(crop)
            clip.fitMode = .fill
        }
        endContinuousEdit()
    }

    func clearReframe(clipID: UUID) {
        updateClip(clipID, name: "إلغاء إعادة التأطير") { $0.crop = KeyframedValue(RectValue.full) }
        endContinuousEdit()
    }

    /// Text / sticker / shape clips that overlap `clipID` in time (candidates to follow its subject).
    func followCandidates(for clipID: UUID) -> [Clip] {
        guard let base = TimelineEngine.clip(clipID, in: timeline) else { return [] }
        return timeline.tracks.filter { $0.kind.isVisual && !$0.isLocked }.flatMap(\.clips).filter { clip in
            guard clip.id != clipID, clip.start < base.end, base.start < clip.end else { return false }
            switch clip.source {
            case .text, .sticker, .shape: return true
            default: return false
            }
        }
    }

    /// Makes an overlay move with the subject of `baseClipID` (position keyframes).
    func followSubject(overlayID: UUID, baseClipID: UUID, track: SubjectTrack, smoothing: Double) {
        guard let base = TimelineEngine.clip(baseClipID, in: timeline),
              let overlay = TimelineEngine.clip(overlayID, in: timeline) else { return }
        // Keep the overlay's current offset from the subject at its first shared moment.
        let canvas = canvasSize
        let probeOverlay = Clip(name: overlay.name, source: overlay.source, start: overlay.start, duration: overlay.duration)
        guard let path = ReframeEngine.followPositions(track: track, base: base, overlay: probeOverlay, asset: asset(for: base),
                                                       canvas: canvas, smoothing: smoothing, offset: .zero),
              let first = path.keyframes.first else {
            env.toasts.show("لا يوجد تداخل زمني كافٍ بين المقطعين.", style: .info)
            return
        }
        let current = overlay.transform.position.value(at: first.time)
        let offset = Vec2(x: current.x - first.value.x, y: current.y - first.value.y)
        guard let positions = ReframeEngine.followPositions(track: track, base: base, overlay: overlay, asset: asset(for: base),
                                                            canvas: canvas, smoothing: smoothing, offset: offset) else { return }
        updateClip(overlayID, name: "تتبع العنصر") { $0.transform.position = positions }
        endContinuousEdit()
        Haptics.success()
        env.toasts.show("«" + overlay.name + "» يتبع العنصر الآن", style: .success)
    }

    // MARK: Stabilization

    func stabilize(clipID: UUID, strength: Double) {
        guard let source = videoSource(clipID) else { return }
        guard source.clip.speed.ramp.isEmpty else {
            env.toasts.show("التثبيت غير متاح مع منحنى السرعة.", style: .info)
            return
        }
        let assetID = source.asset.id
        let duration = source.asset.durationSeconds ?? 0
        let (control, relay) = startBusy("تثبيت الفيديو", detail: "تحليل حركة الكاميرا على جهازك (مرة واحدة لكل ملف)")
        Task { [weak self] in
            do {
                let data = try await StabilizationAnalyzer.analyze(assetID: assetID, url: source.url, duration: duration,
                                                                   control: control, progress: { relay.send($0) })
                guard let self, self.finishBusy(control) else { return }
                StabilizationStore.shared.insert(data)
                let zoom = StabilizationAnalyzer.suggestedZoom(data, strength: strength)
                self.updateClip(clipID, name: "تثبيت الفيديو") { clip in
                    clip.stabilization = StabilizationSettings(isEnabled: true, strength: strength, zoom: zoom, assetID: assetID)
                }
                self.endContinuousEdit()
                Haptics.success()
                self.env.toasts.show("تم التثبيت — تكبير " + Fmt.number(zoom, digits: 2) + "× لإخفاء الحواف", style: .success)
            } catch {
                self?.busy = nil
                if !control.isCancelled { self?.report(error) }
            }
        }
    }

    func setStabilization(clipID: UUID, _ change: @escaping (inout StabilizationSettings) -> Void) {
        updateClip(clipID, name: "ضبط التثبيت", coalesce: "stabilize-" + clipID.uuidString) { clip in
            guard var settings = clip.stabilization else { return }
            change(&settings)
            settings.strength = min(1, max(0, settings.strength))
            settings.zoom = min(1.5, max(1, settings.zoom))
            clip.stabilization = settings
        }
    }

    /// Suggested zoom for the clip's current strength (analysis must exist).
    func suggestedStabilizationZoom(clipID: UUID) -> Double? {
        guard let settings = TimelineEngine.clip(clipID, in: timeline)?.stabilization,
              let data = JSONStore.load(StabilizationData.self, from: StabilizationAnalyzer.cacheURL(assetID: settings.assetID)) else {
            return nil
        }
        return StabilizationAnalyzer.suggestedZoom(data, strength: settings.strength)
    }

    func removeStabilization(clipID: UUID) {
        updateClip(clipID, name: "إلغاء التثبيت") { $0.stabilization = nil }
        endContinuousEdit()
    }

    // MARK: Music

    /// Sound clips that can drive beat sync (audio-track clips with sound).
    var musicCandidates: [Clip] {
        timeline.tracks.filter { $0.kind == .audio }.flatMap(\.clips).filter { clip in
            guard let id = clip.mediaAssetID, let asset = env.library.asset(id) else { return false }
            return asset.kind == .audio || asset.hasAudio
        }
        .sorted { $0.duration > $1.duration }
    }

    func cachedMusic(for clip: Clip) -> MusicAnalysis? {
        clip.mediaAssetID.flatMap(MusicAnalyzer.cached(assetID:))
    }

    func analyzeMusic(clipID: UUID) async -> MusicAnalysis? {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), let id = clip.mediaAssetID,
              let asset = env.library.asset(id), let url = env.library.url(forID: id) else { return nil }
        if let cached = MusicAnalyzer.cached(assetID: id) { return cached }
        let (control, relay) = startBusy("تحليل الموسيقى", detail: asset.displayName + " — الإيقاع والطاقة على جهازك")
        do {
            let analysis = try await MusicAnalyzer.analyze(assetID: id, url: url, control: control, progress: { relay.send($0) })
            guard finishBusy(control) else { return nil }
            if analysis.beats.isEmpty {
                env.toasts.show("لم يُعثر على إيقاع واضح في هذا الصوت.", style: .info)
            }
            return analysis
        } catch {
            busy = nil
            if !control.isCancelled { report(error) }
            return nil
        }
    }

    /// Visual tracks with clips (targets for cut-to-beat).
    var beatSyncTargets: [IndexedTrack] {
        timeline.tracks.enumerated().compactMap { pair -> IndexedTrack? in
            pair.element.kind.isVisual && pair.element.kind != .subtitle && !pair.element.clips.isEmpty && !pair.element.isLocked
                ? IndexedTrack(index: pair.offset, track: pair.element) : nil
        }
    }

    func cutToBeats(musicClipID: UUID, analysis: MusicAnalysis, trackIndex: Int, options: BeatSyncOptions) {
        guard let music = TimelineEngine.clip(musicClipID, in: timeline) else { return }
        let grid = BeatSync.timelineBeats(analysis, clip: music)
        guard grid.beats.count >= 2 else {
            env.toasts.show("مقطع الموسيقى لا يغطي إيقاعات كافية.", style: .info)
            return
        }
        var result = BeatSyncResult()
        let changed = edit("قص على الإيقاع") { timeline, context in
            result = try BeatSync.cutToBeats(track: trackIndex, beats: grid.beats, downbeats: grid.downbeats,
                                             options: options, in: &timeline, context: context)
        }
        guard changed else {
            env.toasts.show("المقاطع على الإيقاع أصلًا.", style: .info)
            return
        }
        Haptics.success()
        var text = Fmt.int(result.onBeat) + " قطع على الإيقاع"
        if result.transitions > 0 { text += " • " + Fmt.int(result.transitions) + " انتقال" }
        if result.skipped > 0 { text += " • " + Fmt.int(result.skipped) + " مقطع قصير بقي كما هو" }
        env.toasts.show(text, style: .success)
    }

    static let beatMarkerPrefix = "إيقاع "
    static let dropMarkerName = "ذروة الموسيقى"

    var beatMarkerCount: Int {
        project.markers.filter { $0.name.hasPrefix(Self.beatMarkerPrefix) || $0.name == Self.dropMarkerName }.count
    }

    func addBeatMarkers(musicClipID: UUID, analysis: MusicAnalysis, everyBeat: Bool) {
        guard editingCompoundID == nil else {
            env.toasts.show("العلامات متاحة في التسلسل الرئيسي.", style: .info)
            return
        }
        guard let music = TimelineEngine.clip(musicClipID, in: timeline) else { return }
        let grid = BeatSync.timelineBeats(analysis, clip: music)
        let markers = BeatSync.markers(beats: grid.beats, downbeats: grid.downbeats, everyBeat: everyBeat,
                                       drop: BeatSync.timelineDrop(analysis, clip: music))
        guard !markers.isEmpty else { return }
        editProject("علامات الإيقاع") { project in
            project.markers.removeAll { $0.name.hasPrefix(Self.beatMarkerPrefix) || $0.name == Self.dropMarkerName }
            project.markers += markers
            project.markers.sort { $0.time < $1.time }
        }
        env.toasts.show("أُضيفت " + Fmt.int(markers.count) + " علامة — المقاطع تلتصق بها عند السحب", style: .success)
    }

    func removeBeatMarkers() {
        editProject("حذف علامات الإيقاع") { project in
            project.markers.removeAll { $0.name.hasPrefix(Self.beatMarkerPrefix) || $0.name == Self.dropMarkerName }
        }
    }

    // MARK: Editing DNA

    func learnDNAFromProject(name: String) -> EditingDNA {
        var source = project
        if editingCompoundID != nil { source.timeline = project.timeline }
        let dna = EditingDNAAnalyzer.extract(from: source, name: name)
        EditingDNAStore.shared.save(dna)
        env.toasts.show("حُفظ الأسلوب «" + dna.name + "»", style: .success)
        return dna
    }

    /// Learns a style from a video picked in Files (security-scoped) or the library. Nothing is imported.
    func learnDNA(fromReference url: URL, name: String, onDone: @escaping (EditingDNA?) -> Void) {
        let (control, relay) = startBusy("تعلّم أسلوب الفيديو المرجعي", detail: "تحليل محلي — لا يُرفع شيء")
        Task { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let dna = try await ReferenceAnalyzer.analyze(url: url, name: name, control: control,
                                                              progress: { relay.send($0) })
                guard let self, self.finishBusy(control) else { onDone(nil); return }
                EditingDNAStore.shared.save(dna)
                self.env.toasts.show("حُفظ الأسلوب «" + dna.name + "»", style: .success)
                onDone(EditingDNAStore.shared.style(dna.id))
            } catch {
                self?.busy = nil
                if !control.isCancelled { self?.report(error) }
                onDone(nil)
            }
        }
    }

    func applyDNA(_ dna: EditingDNA, options: DNAApplyOptions) {
        let snapshot = timeline
        let media = env.library.urlMap()
        let canvas = canvasSize
        let needsMatching = options.color && dna.referenceFrame != nil
        // Beats of an analyzed music clip, when the style cuts on the beat.
        var beats: (beats: [Double], downbeats: [Double])?
        if dna.cutsOnBeat, let music = musicCandidates.first(where: { cachedMusic(for: $0) != nil }),
           let analysis = cachedMusic(for: music) {
            beats = BeatSync.timelineBeats(analysis, clip: music)
        }
        let beatGrid = beats
        let (control, relay) = startBusy("تطبيق أسلوب «" + dna.name + "»", detail: needsMatching ? "مطابقة الألوان مع الإطار المرجعي" : "")
        Task { [weak self] in
            var matches: [UUID: ColorAdjustments] = [:]
            if needsMatching {
                matches = await EditingDNAApplier.matchColors(dna, timeline: snapshot, media: media, canvas: canvas,
                                                              strength: options.colorStrength, control: control,
                                                              progress: { relay.send($0 * 0.95) })
            }
            guard let self, self.finishBusy(control) else { return }
            var report = DNAApplyReport()
            let changed = self.edit("أسلوب: " + dna.name) { timeline, context in
                report = try EditingDNAApplier.apply(dna, options: options, colorMatches: matches, beats: beatGrid,
                                                     to: &timeline, context: context)
            }
            if changed {
                Haptics.success()
                self.env.toasts.show(report.summary, style: .success, duration: 3.2)
                if dna.cutsOnBeat, beatGrid == nil, options.pacing {
                    self.env.toasts.show("حلّل الموسيقى من «الإيقاع» ليصير القطع على الإيقاع.", style: .info, duration: 3)
                }
            } else {
                self.env.toasts.show("لا يوجد ما يتغير بهذا الأسلوب.", style: .info)
            }
        }
    }

    // MARK: Audio separation

    func separateAudio(clipID: UUID, method: SeparationMethod, duckBackground: Bool = false) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), case .media(let id) = clip.source,
              let asset = env.library.asset(id), asset.kind == .audio || asset.hasAudio,
              let url = env.library.url(forID: id), let range = clip.sourceRange else {
            env.toasts.show("هذا المقطع بدون صوت.", style: .info)
            return
        }
        guard !clip.speed.isReversed else {
            env.toasts.show("ألغِ عكس المقطع قبل فصل الصوت.", style: .info)
            return
        }
        let library = env.library
        let source = CMTimeRangeValue(start: range.start.seconds, end: range.end.seconds)
        let baseName = clip.name
        let (control, relay) = startBusy("فصل الصوت", detail: "الكلام والخلفية — على جهازك")
        Task { [weak self] in
            do {
                let result = try await SourceSeparator.separate(url: url, range: source.cmTimeRange, method: method,
                                                                control: control, progress: { relay.send($0 * 0.92) })
                let voice = try await library.registerGenerated(file: result.voiceURL, displayName: baseName + " — الكلام", kind: .audio)
                let background = try await library.registerGenerated(file: result.backgroundURL,
                                                                     displayName: baseName + " — الخلفية", kind: .audio)
                guard let self, self.finishBusy(control) else { return }
                self.placeStems(original: clipID, voice: voice, background: background, method: result.method,
                                duckBackground: duckBackground)
            } catch {
                self?.busy = nil
                if !control.isCancelled { self?.report(error) }
            }
        }
    }

    /// Two new audio clips aligned with the original (whose own sound is muted).
    private func placeStems(original clipID: UUID, voice: MediaAsset, background: MediaAsset, method: SeparationMethod,
                            duckBackground: Bool) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), let range = clip.sourceRange else { return }
        func stem(_ asset: MediaAsset, _ suffix: String) -> Clip {
            var copy = Clip(name: clip.name + " — " + suffix, source: .media(asset.id), start: clip.start, duration: clip.duration,
                            sourceRange: TimeRangeValue(start: .zero, duration: range.duration))
            copy.speed = clip.speed
            copy.audio = clip.audio
            copy.audio.isMuted = false
            copy.recomputeDurationFromSpeed()
            copy.duration = clip.duration
            return copy
        }
        let voiceClip = stem(voice, "الكلام")
        var backgroundClip = stem(background, "الخلفية")
        backgroundClip.audio.effects.noiseReduction = 0
        var placed: [UUID] = []
        let changed = edit("فصل الصوت") { timeline, context in
            placed.append(try TimelineEngine.insertLayer(voiceClip, kind: .audio, at: clip.start.seconds, in: &timeline, context: context))
            placed.append(try TimelineEngine.insertLayer(backgroundClip, kind: .audio, at: clip.start.seconds, in: &timeline, context: context))
            TimelineEngine.updateClips([clipID], in: &timeline) { $0.audio.isMuted = true }
        }
        guard changed else { return }
        selection = Set(placed)
        Haptics.success()
        env.toasts.show("تم الفصل (" + method.title + ") — الصوت الأصلي مكتوم وموجود كما هو.", style: .success, duration: 3)
        if duckBackground, placed.count == 2,
           let voiceTrack = timeline.tracks.first(where: { $0.clips.contains { $0.id == placed[0] } }),
           let backgroundTrack = timeline.tracks.first(where: { $0.clips.contains { $0.id == placed[1] } }) {
            duckUnderVoice(voiceTrackID: voiceTrack.id, extraTargets: [backgroundTrack.id])
        }
    }

    // MARK: Quality Inspector

    var qualityInput: QualityInput {
        QualityInput(timeline: project.timeline, settings: project.settings, assets: assetsByID, missing: env.library.missingIDs)
    }

    func runQualityCheck() -> [QualityIssue] {
        QualityInspector.inspect(qualityInput)
    }

    func deepQualityScan(onDone: @escaping ([QualityIssue]) -> Void) {
        let input = qualityInput
        let media = env.library.urlMap()
        let (control, relay) = startBusy("الفحص العميق", detail: "قياس الصوت والإضاءة لكل مقطع")
        Task { [weak self] in
            let issues = await QualityInspector.deepScan(input, media: media, control: control, progress: { relay.send($0) })
            guard let self else { return }
            let completed = self.finishBusy(control)
            onDone(completed ? issues : [])
        }
    }

    /// Applies an issue's fix. Returns true when the issue should disappear from the list.
    @discardableResult
    func applyQualityFix(_ issue: QualityIssue) -> Bool {
        guard let fix = issue.fix else { return false }
        if editingCompoundID != nil { closeCompound() }
        switch fix {
        case .replaceMedia(let id):
            activeSheet = .replaceMedia(id)
            return false
        case .normalize(let ids):
            normalizeLoudness(target: .social, clipIDs: ids)
            return true
        case .setWatermark:
            activeSheet = .watermark
            return false
        default:
            let canvas = canvasSize
            let changed = edit(fix.title) { timeline, context in
                QualityInspector.apply(fix, to: &timeline, canvas: canvas, context: context)
            }
            if changed { Haptics.success() }
            return changed
        }
    }

    func jump(to issue: QualityIssue) {
        if let time = issue.time { seek(to: time) }
        if let id = issue.clipID, TimelineEngine.clip(id, in: timeline) != nil { selection = [id] }
    }

    // MARK: Multi-format variants

    /// Full-frame video clips that a smart reframe would analyze (and whether each is cached).
    func variantAnalysisJobs() -> [(clip: Clip, url: URL, span: TimeSpan, cached: Bool)] {
        project.timeline.tracks.filter(\.kind.isVisual).flatMap(\.clips).compactMap { clip -> (clip: Clip, url: URL, span: TimeSpan, cached: Bool)? in
            guard case .media(let id) = clip.source, OutputVariants.isFullFrame(clip), clip.crop.base.isFull,
                  let asset = env.library.asset(id), asset.kind == .video, let url = env.library.url(forID: id),
                  let span = sourceSpan(of: clip) else { return nil }
            return (clip: clip, url: url, span: span, cached: SubjectTracker.anyCached(assetID: id, span: span) != nil)
        }
    }

    func createVariants(formats: [OutputFormat], options: VariantOptions, export settings: ExportSettings?) {
        guard editingCompoundID == nil else {
            env.toasts.show("ارجع للتسلسل الرئيسي أولاً.", style: .info)
            return
        }
        let current = project.settings.aspect
        let targets = formats.filter { $0.aspect != current }
        guard !targets.isEmpty else {
            env.toasts.show("اختر مقاسًا مختلفًا عن مقاس المشروع.", style: .info)
            return
        }
        persistSessionState()
        env.projects.flushAutosave(project)
        let source = project
        let assets = assetsByID
        let jobs = options.method == .smart ? variantAnalysisJobs().filter { !$0.cached } : []
        let (control, relay) = startBusy("إنشاء نسخ بمقاسات أخرى", detail: jobs.isEmpty ? "" : "تحليل العناصر في " + Fmt.int(jobs.count) + " مقطع")
        let jobCount = Double(max(1, jobs.count))
        Task { [weak self] in
            for (index, job) in jobs.enumerated() {
                if control.isCancelled { break }
                guard case .media(let id) = job.clip.source else { continue }
                let base = Double(index)
                _ = try? await SubjectTracker.detect(assetID: id, url: job.url, span: job.span, mode: .auto, control: control,
                                                     progress: { relay.send((base + $0) / jobCount * 0.9) })
            }
            guard let self, self.finishBusy(control) else { return }
            var report = VariantReport()
            var created: [EditProject] = []
            for format in targets {
                let variant = OutputVariants.makeVariant(of: source, format: format, options: options, assets: assets,
                                                         subjectTrack: { clip in
                                                             guard case .media(let id) = clip.source, let range = clip.sourceRange else { return nil }
                                                             return SubjectTracker.anyCached(assetID: id,
                                                                                             span: TimeSpan(start: range.start.seconds,
                                                                                                            end: range.end.seconds))
                                                         }, report: &report)
                self.env.projects.save(variant, makeVersion: true)
                created.append(variant)
            }
            if let settings {
                let jobs = created.map { variant -> ExportJob in
                    let payload = RenderPayload(timeline: variant.timeline, projectSettings: variant.settings, range: nil)
                    var job = ExportJob(title: variant.name, outputBaseName: variant.name, payload: .render(payload), settings: settings)
                    let size = ExportGeometry.outputSize(canvas: variant.settings.canvasSize, resolution: settings.resolution)
                    let fps = settings.frameRate.value ?? variant.settings.frameRate
                    let bitrate = BitrateCalculator.videoBitrate(size: size, fps: fps, settings: settings)
                    job.estimatedBytes = BitrateCalculator.estimatedBytes(durationSeconds: variant.timeline.duration.seconds,
                                                                          videoBitrate: bitrate, audioKbps: settings.audioBitrateKbps)
                    return job
                }
                self.env.exportQueue.enqueue(jobs)
            }
            Haptics.success()
            var text = "أُنشئ " + Fmt.int(created.count) + " مشروع"
            if report.smart > 0 { text += " • تتبع ذكي في " + Fmt.int(report.smart) + " لقطة" }
            if settings != nil { text += " • أُضيفت للتصدير" }
            self.env.toasts.show(text, style: .success, duration: 3.2)
        }
    }

    // MARK: Templates

    func saveAsTemplate(name: String, note: String, keepAudio: Bool) {
        persistSessionState()
        do {
            let template = try StudioTemplateLibrary.shared.save(from: project, name: name, note: note, keepAudio: keepAudio)
            Haptics.success()
            env.toasts.show("حُفظ القالب «" + template.name + "» بـ " + Fmt.int(template.slots.count) + " خانة", style: .success)
        } catch {
            report(error)
        }
    }
}
