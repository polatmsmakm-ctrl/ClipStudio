//
//  StudioViewModel.swift
//  ClipStudio — Features/ProStudio (Pro Studio)
//
//  The editor's single source of truth: the project (or the nested sequence
//  being edited), selection, tools, playhead and zoom, undo/redo, autosave and
//  the live preview. Preview rebuilds only when timing/media changed; edits to
//  visual attributes (transform, color, effects…) refresh the current player
//  item's video composition instantly.
//
//  Editing commands live in StudioViewModel+Editing.swift, long-running
//  operations (reverse, nested sequences, export) in StudioViewModel+Operations.swift
//  and gesture state in StudioViewModel+Gestures.swift. Part 3: organizing tools
//  (+Organize), Audio Studio (+Audio), text & graphics (+Text) and captions /
//  transcripts (+Captions). Part 4: on-device intelligence (+Intelligence) —
//  smart reframe, tracking, stabilization, beat sync, Editing DNA, audio
//  separation, Quality Inspector, multi-format variants and templates. Part 5:
//  AI editing assistant and Content Studio (+AI).
//

import Foundation
import SwiftUI
import AVFoundation

enum StudioTool: String, CaseIterable, Identifiable {
    case select, blade

    var id: String { rawValue }
    var title: String { self == .select ? "تحديد" : "شفرة" }
    var symbol: String { self == .select ? "cursorarrow" : "scissors" }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case text, graphic, transform, crop, color, effects, speed, audio, mask, chroma, transition, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "النص"
        case .graphic: "الشكل"
        case .transform: "التحويل"
        case .crop: "القص"
        case .color: "الألوان"
        case .effects: "التأثيرات"
        case .speed: "السرعة"
        case .audio: "الصوت"
        case .mask: "القناع"
        case .chroma: "الكروما"
        case .transition: "الانتقال"
        case .info: "معلومات"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .graphic: "square.on.circle"
        case .transform: "arrow.up.and.down.and.arrow.left.and.right"
        case .crop: "crop"
        case .color: "paintpalette"
        case .effects: "sparkles"
        case .speed: "gauge.with.dots.needle.67percent"
        case .audio: "speaker.wave.2"
        case .mask: "circle.dashed"
        case .chroma: "person.crop.rectangle"
        case .transition: "square.split.diagonal"
        case .info: "info.circle"
        }
    }

    /// Tabs that make sense for a clip on a track of `trackKind`.
    static func available(for clip: Clip, trackKind: TrackKind) -> [InspectorTab] {
        if trackKind == .audio { return [.audio, .speed, .info] }
        switch clip.source {
        case .media: return [.transform, .crop, .color, .effects, .speed, .audio, .mask, .chroma, .transition, .info]
        case .image, .freezeFrame: return [.transform, .crop, .color, .effects, .mask, .chroma, .transition, .info]
        case .adjustment: return [.color, .effects, .transform, .info]
        case .solidColor: return [.transform, .color, .effects, .mask, .transition, .info]
        case .text: return [.text, .transform, .effects, .mask, .transition, .info]
        case .shape, .sticker: return [.graphic, .transform, .effects, .mask, .transition, .info]
        }
    }
}

enum StudioSheet: Identifiable, Equatable {
    case inspector
    case media
    case colorWorkspace(UUID)
    case effects(UUID)
    case transitions(UUID)
    case keyframes(UUID)
    case export
    case projectSettings
    case markers
    case shortcuts
    case preferences
    case pasteAttributes
    case replaceMedia(UUID)
    case compounds
    // Part 3
    case titles
    case graphics
    case captions
    case transcript
    case mixer
    case voiceover
    case soundEffects
    case ducking
    case summary
    case motionPresets
    case watermark
    // Part 4
    case smartTools(UUID)
    case music
    case editingDNA
    case quality
    case outputs
    case separation(UUID)
    case saveTemplate
    // Part 5
    case assistant
    case contentStudio
    // Part 6
    case voiceoverGenerator
    case translateCaptions
    case musicSuggestions
    case thumbnail
    case hookCheck
    case shorten

    var id: String {
        switch self {
        case .inspector: "inspector"
        case .media: "media"
        case .colorWorkspace(let id): "color-" + id.uuidString
        case .effects(let id): "effects-" + id.uuidString
        case .transitions(let id): "transitions-" + id.uuidString
        case .keyframes(let id): "keyframes-" + id.uuidString
        case .export: "export"
        case .projectSettings: "projectSettings"
        case .markers: "markers"
        case .shortcuts: "shortcuts"
        case .preferences: "preferences"
        case .pasteAttributes: "pasteAttributes"
        case .replaceMedia(let id): "replace-" + id.uuidString
        case .compounds: "compounds"
        case .titles: "titles"
        case .graphics: "graphics"
        case .captions: "captions"
        case .transcript: "transcript"
        case .mixer: "mixer"
        case .voiceover: "voiceover"
        case .soundEffects: "soundEffects"
        case .ducking: "ducking"
        case .summary: "summary"
        case .motionPresets: "motionPresets"
        case .watermark: "watermark"
        case .smartTools(let id): "smart-" + id.uuidString
        case .music: "music"
        case .editingDNA: "editingDNA"
        case .quality: "quality"
        case .outputs: "outputs"
        case .separation(let id): "separation-" + id.uuidString
        case .saveTemplate: "saveTemplate"
        case .assistant: "assistant"
        case .contentStudio: "contentStudio"
        case .voiceoverGenerator: "voiceoverGenerator"
        case .translateCaptions: "translateCaptions"
        case .musicSuggestions: "musicSuggestions"
        case .thumbnail: "thumbnail"
        case .hookCheck: "hookCheck"
        case .shorten: "shorten"
        }
    }
}

struct BusyOperation: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var progress: Double
    let control: RenderControl
    var cancellable: Bool
}

/// Everything that requires rebuilding AVFoundation tracks when it changes.
struct PreviewStructureKey: Hashable {
    struct ClipKey: Hashable {
        let id: UUID
        let start: TimeValue
        let duration: TimeValue
        let sourceRange: TimeRangeValue?
        let speed: SpeedSettings
        let isEnabled: Bool
        let audio: ClipAudio
        let source: String
    }

    struct TrackKey: Hashable {
        let id: UUID
        let kind: TrackKind
        let isHidden: Bool
        let isMuted: Bool
        let isSolo: Bool
        let volume: Double
        let clips: [ClipKey]
    }

    let tracks: [TrackKey]
    let width: Int
    let height: Int
    let frameRate: Int
    let previewShortSide: CGFloat
    let watermark: WatermarkSettings?

    /// Audio effects and track balance are NOT part of the key: they update live
    /// through the processing taps (AudioParameterStore).
    init(timeline: Timeline, settings: ProjectSettings, previewShortSide: CGFloat) {
        tracks = timeline.tracks.map { track in
            TrackKey(id: track.id, kind: track.kind, isHidden: track.isHidden, isMuted: track.isMuted, isSolo: track.isSolo,
                     volume: track.volume,
                     clips: track.clips.map { clip in
                         ClipKey(id: clip.id, start: clip.start, duration: clip.duration, sourceRange: clip.sourceRange,
                                 speed: clip.speed, isEnabled: clip.isEnabled, audio: clip.audio.mixSignature,
                                 source: Self.describe(clip.source))
                     })
        }
        width = settings.canvasWidth
        height = settings.canvasHeight
        frameRate = settings.frameRate
        self.previewShortSide = previewShortSide
        watermark = settings.activeWatermark
    }

    private static func describe(_ source: ClipSource) -> String {
        switch source {
        case .media(let id): "m" + id.uuidString
        case .image(let id): "i" + id.uuidString
        case .freezeFrame(let id, let time): "f" + id.uuidString + "@" + String(time.value) + "/" + String(time.timescale)
        case .text: "text"
        case .shape: "shape"
        case .sticker: "sticker"
        case .solidColor: "solid"
        case .adjustment: "adjustment"
        }
    }
}

@MainActor
@Observable
final class StudioViewModel {
    let env: AppEnvironment
    let player = PlayerController()
    let undo = UndoStack()
    let clipboard = StudioClipboard.shared

    var project: EditProject
    /// Nested sequence being edited (nil = main timeline).
    var editingCompoundID: UUID? = nil

    // Selection & tools
    var selection: Set<UUID> = []
    var selectedTrackIndex: Int? = nil
    var tool: StudioTool = .select
    var isMultiSelect = false
    var inspectorTab: InspectorTab = .transform
    var activeSheet: StudioSheet? = nil
    var pendingDeleteTrack: Int? = nil

    // Timeline view state
    var pixelsPerSecond: Double
    var verticalOffset: CGFloat = 0
    var laneWidth: CGFloat = 600
    var scrubTime: Double? = nil
    var hoverTime: Double? = nil
    var inPoint: Double? = nil
    var outPoint: Double? = nil
    var loopsInOut = false
    /// Shows the volume line on audio clips for drawing volume automation (Part 3).
    var showsVolumeAutomation = false
    var moveDrag: MoveDragState? = nil
    var trimDrag: TrimDragState? = nil
    var snapGuide: Double? = nil
    private var hoverReturnTime: Double? = nil

    // Preview
    private(set) var isBuildingPreview = false
    private(set) var previewError: String? = nil
    private(set) var previewWarnings: [String] = []
    private(set) var built: BuiltComposition? = nil
    private var builtKey: PreviewStructureKey? = nil
    private var previewTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var lastRefresh = Date.distantPast
    private var glideTask: Task<Void, Never>? = nil

    // Shuttle (J/K/L)
    private(set) var shuttleRate: Double = 0
    private var shuttleTask: Task<Void, Never>? = nil

    // Long-running work
    var busy: BusyOperation? = nil

    static let minPixelsPerSecond: Double = 2
    static let maxPixelsPerSecond: Double = 900

    init?(projectID: UUID, env: AppEnvironment) {
        guard var loaded = env.projects.load(projectID) else { return nil }
        if loaded.kind != .pro { loaded.kind = .pro }
        self.env = env
        self.project = loaded
        self.pixelsPerSecond = min(max(loaded.studio.pixelsPerSecond, Self.minPixelsPerSecond), Self.maxPixelsPerSecond)
        self.inPoint = loaded.studio.inPoint
        self.outPoint = loaded.studio.outPoint
        env.projects.beginSession(projectID)
        player.frameRate = Double(loaded.settings.frameRate)
        player.seek(to: max(0, loaded.studio.playhead))
        if let first = loaded.timeline.tracks.firstIndex(where: { $0.kind == .video }) { selectedTrackIndex = first }
        rebuildPreview(delay: 0)
    }

    // MARK: Accessors

    var prefs: StudioPreferences { env.studioPrefs }
    var settings: ProjectSettings { project.settings }
    var canvasSize: CGSize { project.settings.canvasSize }
    var frameRate: Double { Double(project.settings.frameRate) }
    var frameDuration: Double { 1 / max(1, frameRate) }

    var timeline: Timeline {
        if let id = editingCompoundID, let compound = project.compounds.first(where: { $0.id == id }) {
            return compound.timeline
        }
        return project.timeline
    }

    var editingCompound: CompoundClip? {
        editingCompoundID.flatMap { id in project.compounds.first { $0.id == id } }
    }

    var duration: Double { timeline.duration.seconds }

    /// The time shown by the playhead (scrub position while scrubbing).
    var currentTime: Double { scrubTime ?? player.currentTime }

    var editContext: EditContext {
        var durations: [UUID: Double] = [:]
        for asset in env.library.assets {
            if let seconds = asset.durationSeconds { durations[asset.id] = seconds }
        }
        return EditContext(assetDurations: durations, frameRate: frameRate, magnetic: prefs.magneticTimeline)
    }

    var markers: [TimelineMarker] {
        editingCompoundID == nil ? project.markers : []
    }

    var selectedClips: [Clip] {
        timeline.tracks.flatMap { $0.clips.filter { selection.contains($0.id) } }.sorted { $0.start < $1.start }
    }

    /// The clip the inspector edits (first selected).
    var primaryClip: Clip? {
        guard !selection.isEmpty else { return nil }
        return selectedClips.first
    }

    var primaryTrackKind: TrackKind? {
        guard let clip = primaryClip, let index = TimelineEngine.trackIndex(of: clip.id, in: timeline) else { return nil }
        return timeline.tracks[index].kind
    }

    func track(of clipID: UUID) -> Track? {
        TimelineEngine.trackIndex(of: clipID, in: timeline).map { timeline.tracks[$0] }
    }

    func asset(for clip: Clip) -> MediaAsset? {
        switch clip.source {
        case .media(let id), .image(let id): env.library.asset(id)
        case .freezeFrame(let id, _): env.library.asset(id)
        default: nil
        }
    }

    /// Clip-local time of the playhead, clamped inside the clip.
    func localTime(for clip: Clip) -> Double {
        min(max(currentTime - clip.start.seconds, 0), max(0, clip.duration.seconds - frameDuration))
    }

    func isPlayheadInside(_ clip: Clip) -> Bool {
        currentTime >= clip.start.seconds - 1e-6 && currentTime < clip.end.seconds
    }

    var keyframeTolerance: Double { frameDuration * 0.75 }

    var missingAssetNames: [String] {
        env.projects.missingAssets(in: project, library: env.library).compactMap { env.library.asset($0)?.displayName ?? "ملف محذوف" }
    }

    // MARK: Edit plumbing

    /// Applies a timeline edit with undo, autosave and preview refresh. Returns false on error or no change.
    @discardableResult
    func edit(_ name: String, coalesce: String? = nil, _ change: (inout Timeline, EditContext) throws -> Void) -> Bool {
        var draft = timeline
        do {
            try change(&draft, editContext)
        } catch {
            report(error)
            return false
        }
        guard draft != timeline else { return false }
        undo.record(before: project, name: name, coalesceKey: coalesce)
        setTimeline(draft)
        didChange()
        return true
    }

    /// Applies a project-level edit (markers, settings, compounds) with undo.
    func editProject(_ name: String, coalesce: String? = nil, _ change: (inout EditProject) -> Void) {
        var draft = project
        change(&draft)
        guard draft != project else { return }
        undo.record(before: project, name: name, coalesceKey: coalesce)
        project = draft
        didChange()
    }

    /// Updates one clip's attributes (keyframe-aware callers pass the clip-local time).
    func updateClip(_ id: UUID, name: String, coalesce: String? = nil, _ change: (inout Clip) -> Void) {
        edit(name, coalesce: coalesce) { timeline, _ in
            TimelineEngine.updateClips([id], in: &timeline, change)
        }
    }

    /// Applies the same change to every selected clip (multi-clip apply).
    func updateSelection(_ name: String, coalesce: String? = nil, _ change: (inout Clip) -> Void) {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit(name, coalesce: coalesce) { timeline, _ in
            TimelineEngine.updateClips(ids, in: &timeline, change)
        }
    }

    func endContinuousEdit() {
        undo.breakCoalescing()
        schedulePreview()
    }

    private func setTimeline(_ newValue: Timeline) {
        if let id = editingCompoundID, let index = project.compounds.firstIndex(where: { $0.id == id }) {
            project.compounds[index].timeline = newValue
            project.compounds[index].needsRender = true
        } else {
            project.timeline = newValue
        }
    }

    /// Installs a project snapshot (undo/redo, restore) without recording.
    func replaceProject(_ newValue: EditProject) {
        project = newValue
        if let id = editingCompoundID, !project.compounds.contains(where: { $0.id == id }) { editingCompoundID = nil }
        didChange()
    }

    private func didChange() {
        pruneSelection()
        project.studio.inPoint = inPoint
        project.studio.outPoint = outPoint
        if let cover = timeline.tracks.first(where: { $0.kind == .video })?.clips.first?.mediaAssetID, editingCompoundID == nil {
            project.coverAssetID = cover
        }
        env.projects.scheduleAutosave(project)
        schedulePreview()
    }

    private func pruneSelection() {
        let existing = Set(timeline.tracks.flatMap { $0.clips.map(\.id) })
        selection = selection.intersection(existing)
        if let index = selectedTrackIndex, !timeline.tracks.indices.contains(index) {
            selectedTrackIndex = timeline.tracks.firstIndex { $0.kind == .video }
        }
        if let primary = primaryClip, let kind = primaryTrackKind,
           !InspectorTab.available(for: primary, trackKind: kind).contains(inspectorTab) {
            inspectorTab = InspectorTab.available(for: primary, trackKind: kind).first ?? .info
        }
    }

    func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        env.toasts.show(message, style: .warning)
    }

    // MARK: Undo

    func performUndo() {
        guard let entry = undo.undo(current: project) else { return }
        replaceProject(entry.snapshot)
        env.toasts.show("تراجع: " + entry.name, style: .info, duration: 1.4)
    }

    func performRedo() {
        guard let entry = undo.redo(current: project) else { return }
        replaceProject(entry.snapshot)
        env.toasts.show("إعادة: " + entry.name, style: .info, duration: 1.4)
    }

    // MARK: Preview

    /// Preview resolution: the chosen quality, capped while the device is hot or in Low Power Mode (Part 6).
    private var previewShortSide: CGFloat {
        let chosen = env.settings.previewQuality.maxShortSide
        guard let cap = env.performance.previewCap else { return chosen }
        return min(chosen, cap)
    }

    func schedulePreview() {
        // Audio effect edits are heard immediately (no rebuild needed).
        built?.audioParameters.update(from: timeline)
        let key = PreviewStructureKey(timeline: timeline, settings: project.settings, previewShortSide: previewShortSide)
        if built != nil, key == builtKey, !isBuildingPreview {
            refreshVisuals()
        } else {
            rebuildPreview(delay: 0.18)
        }
    }

    /// Attribute-only refresh: swaps the video composition of the current item (throttled to ~30 fps).
    private func refreshVisuals() {
        let interval = Date().timeIntervalSince(lastRefresh)
        let minimum = 1.0 / 30
        guard interval >= minimum else {
            if refreshTask == nil {
                refreshTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((minimum - interval) * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.refreshTask = nil
                    self.refreshVisuals()
                }
            }
            return
        }
        lastRefresh = Date()
        guard let built, let item = player.player.currentItem else { return }
        guard let composition = built.refreshedVideoComposition(with: timeline, background: project.settings.backgroundColor) else {
            rebuildPreview(delay: 0)
            return
        }
        item.videoComposition = composition
        if !player.isPlaying && scrubTime == nil {
            player.seek(to: player.currentTime)
        }
    }

    func rebuildPreview(delay: Double) {
        previewTask?.cancel()
        let timeline = self.timeline
        let settings = project.settings
        // Proxies (Part 6) are used for the preview only; exports read the originals.
        let media = env.proxies.previewMap(env.library.urlMap())
        let shortSide = previewShortSide
        let key = PreviewStructureKey(timeline: timeline, settings: settings, previewShortSide: shortSide)
        isBuildingPreview = true
        previewTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            if timeline.duration.seconds < 0.01 {
                guard let self else { return }
                self.built = nil
                self.builtKey = nil
                self.player.load(item: nil)
                self.previewError = nil
                self.previewWarnings = []
                self.isBuildingPreview = false
                return
            }
            let size = CompositionBuilder.previewSize(canvas: settings.canvasSize, maxShortSide: shortSide)
            do {
                let result = try await CompositionBuilder(media: media, audioTapPolicy: .always)
                    .build(timeline: timeline, settings: settings, renderSize: size, frameRate: settings.frameRate)
                guard let self, !Task.isCancelled else { return }
                let time = self.currentTime
                let wasPlaying = self.player.isPlaying
                self.player.frameRate = Double(settings.frameRate)
                self.player.load(item: result.makePlayerItem())
                self.player.seek(to: min(time, max(0, result.duration.seconds - 0.001)))
                if wasPlaying { self.player.play() }
                self.built = result
                self.builtKey = key
                self.previewWarnings = result.warnings
                self.previewError = nil
                self.isBuildingPreview = false
                if self.timeline != timeline { self.schedulePreview() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.built = nil
                self.builtKey = nil
                self.previewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.isBuildingPreview = false
            }
        }
    }

    // MARK: Playback & navigation

    func togglePlay() {
        stopShuttle()
        if player.isPlaying {
            player.pause()
            return
        }
        if loopsInOut, let range = inOutRange {
            player.playRange(start: currentTime >= range.1 - 0.02 || currentTime < range.0 ? range.0 : currentTime,
                             end: range.1, loop: true)
        } else {
            player.clearRange()
            player.play()
        }
    }

    func seek(to time: Double, precise: Bool = true) {
        let clamped = min(max(0, time), max(0, duration))
        player.seek(to: clamped, precise: precise)
    }

    func step(frames: Int) {
        stopShuttle()
        player.pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: max(0, duration - frameDuration)) }

    func previousEditPoint() {
        let points = TimelineEngine.editPoints(timeline)
        if let target = points.last(where: { $0 < currentTime - frameDuration * 0.5 }) { seek(to: target) }
    }

    func nextEditPoint() {
        let points = TimelineEngine.editPoints(timeline)
        if let target = points.first(where: { $0 > currentTime + frameDuration * 0.5 }) { seek(to: min(target, max(0, duration - frameDuration))) }
    }

    // Scrubbing from the timeline (center playhead).
    func beginScrub() {
        hoverReturnTime = nil
        hoverTime = nil
        stopShuttle()
        if player.isPlaying { player.pause() }
        glideTask?.cancel()
        scrubTime = currentTime
    }

    func scrub(to time: Double) {
        let clamped = min(max(0, time), max(0, duration))
        scrubTime = clamped
        player.seek(to: clamped, precise: false)
    }

    func endScrub(glideTo target: Double? = nil) {
        let start = scrubTime ?? currentTime
        guard let target, abs(target - start) > frameDuration else {
            let final = scrubTime ?? currentTime
            scrubTime = nil
            seek(to: final)
            return
        }
        let destination = min(max(0, target), max(0, duration))
        glideTask?.cancel()
        glideTask = Task { [weak self] in
            let steps = 14
            for step in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                self.scrubTime = start + (destination - start) * eased
                self.player.seek(to: self.scrubTime ?? destination, precise: false)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.scrubTime = nil
            self.seek(to: destination)
        }
    }

    /// Apple Pencil / pointer hover scrubbing: the viewer shows the hovered frame while
    /// the timeline stays put; the playhead returns when hover ends.
    func hoverScrub(to time: Double?) {
        guard prefs.pencilHoverScrub, !player.isPlaying, moveDrag == nil, trimDrag == nil else { return }
        if let time {
            if hoverReturnTime == nil {
                guard scrubTime == nil else { return }
                hoverReturnTime = player.currentTime
                scrubTime = player.currentTime
            }
            let clamped = min(max(0, time), max(0, duration))
            hoverTime = clamped
            player.seek(to: clamped, precise: false)
        } else if let back = hoverReturnTime {
            hoverReturnTime = nil
            hoverTime = nil
            scrubTime = nil
            player.seek(to: back)
        }
    }

    // MARK: Shuttle (J/K/L)

    func shuttle(_ direction: Int) {
        if direction == 0 {
            stopShuttle()
            player.pause()
            return
        }
        if direction > 0 {
            shuttleRate = shuttleRate <= 0 ? 1 : min(shuttleRate * 2, 8)
        } else {
            shuttleRate = shuttleRate >= 0 ? -1 : max(shuttleRate * 2, -8)
        }
        shuttleTask?.cancel()
        player.clearRange()
        if shuttleRate > 0 {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.player.rate = Float(shuttleRate)
            player.play()
            player.player.rate = Float(shuttleRate)
            return
        }
        if player.player.currentItem?.canPlayReverse == true {
            player.player.rate = Float(shuttleRate)
            return
        }
        player.pause()
        shuttleTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let next = self.currentTime + self.shuttleRate / 20
                if next <= 0 {
                    self.seek(to: 0)
                    self.shuttleRate = 0
                    return
                }
                self.player.seek(to: next, precise: false)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func stopShuttle() {
        shuttleTask?.cancel()
        shuttleTask = nil
        if shuttleRate != 0 {
            shuttleRate = 0
            if player.player.rate != 0 && player.player.rate != 1 { player.player.rate = 1 }
        }
    }

    // MARK: Zoom

    func setZoom(_ value: Double) {
        pixelsPerSecond = min(max(value, Self.minPixelsPerSecond), Self.maxPixelsPerSecond)
        project.studio.pixelsPerSecond = pixelsPerSecond
    }

    func zoom(by factor: Double) { setZoom(pixelsPerSecond * factor) }

    func zoomToFit() {
        guard duration > 0 else { return }
        setZoom(Double(laneWidth) * 0.45 / duration)
        seek(to: duration / 2)
    }

    // MARK: Selection

    func select(_ id: UUID, extending: Bool = false) {
        if extending || isMultiSelect {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        if let index = TimelineEngine.trackIndex(of: id, in: timeline) { selectedTrackIndex = index }
        if let clip = primaryClip, let kind = primaryTrackKind,
           !InspectorTab.available(for: clip, trackKind: kind).contains(inspectorTab) {
            inspectorTab = InspectorTab.available(for: clip, trackKind: kind).first ?? .info
        }
        Haptics.selection()
    }

    func deselectAll() {
        selection = []
    }

    func selectAll() {
        selection = Set(timeline.tracks.filter { !$0.isLocked }.flatMap { $0.clips.map(\.id) })
    }

    /// Selects every clip that starts at or after the playhead (on the selected track, or all tracks).
    func selectForward(allTracks: Bool) {
        var ids: Set<UUID> = []
        for (index, track) in timeline.tracks.enumerated() where !track.isLocked {
            guard allTracks || index == selectedTrackIndex else { continue }
            for clip in track.clips where clip.end.seconds > currentTime + 1e-6 { ids.insert(clip.id) }
        }
        selection = ids
    }

    func selectTrack(_ index: Int) {
        selectedTrackIndex = index
        Haptics.selection()
    }

    // MARK: In / out

    var inOutRange: (Double, Double)? {
        guard let inPoint, let outPoint, outPoint - inPoint > frameDuration else { return nil }
        return (inPoint, outPoint)
    }

    func markIn() {
        inPoint = currentTime
        if let outPoint, outPoint <= currentTime { self.outPoint = nil }
        project.studio.inPoint = inPoint
        project.studio.outPoint = outPoint
        env.projects.scheduleAutosave(project)
    }

    func markOut() {
        outPoint = min(currentTime + frameDuration, duration)
        if let inPoint, inPoint >= currentTime { self.inPoint = nil }
        project.studio.inPoint = inPoint
        project.studio.outPoint = outPoint
        env.projects.scheduleAutosave(project)
    }

    func clearInOut() {
        inPoint = nil
        outPoint = nil
        loopsInOut = false
        project.studio.inPoint = nil
        project.studio.outPoint = nil
        env.projects.scheduleAutosave(project)
    }

    // MARK: Lifecycle

    func persistSessionState() {
        project.studio.playhead = currentTime
        project.studio.pixelsPerSecond = pixelsPerSecond
        project.studio.inPoint = inPoint
        project.studio.outPoint = outPoint
    }

    func close() {
        previewTask?.cancel()
        refreshTask?.cancel()
        glideTask?.cancel()
        stopShuttle()
        player.pause()
        player.load(item: nil)
        persistSessionState()
        env.projects.flushAutosave(project)
        env.projects.endSession()
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editProject("إعادة تسمية المشروع") { $0.name = trimmed }
    }
}
