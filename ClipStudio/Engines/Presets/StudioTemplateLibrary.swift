//
//  StudioTemplateLibrary.swift
//  ClipStudio — Engines/Presets (Part 4)
//
//  Templates workspace: any Pro Studio project can be saved as a template whose
//  picture clips become numbered media slots. Everything else — timing, speed,
//  transitions, color, effects, titles, captions styling, motion, markers and
//  (optionally) the music — is kept. Filling the slots with new photos / videos
//  creates a brand-new project; the template itself never changes.
//  Stored as Presets/Templates/<id>.json (included in backups). Templates can be
//  shared / imported as .cstemplate files (StyleSharing).
//

import Foundation

struct TemplateFillReport: Hashable {
    var filled = 0
    var removedEmpty = 0
    var slowed = 0
    var droppedMissingAudio = 0
}

@MainActor
@Observable
final class StudioTemplateLibrary {
    static let shared = StudioTemplateLibrary()

    private(set) var templates: [StudioTemplate] = []
    nonisolated static var directory: URL { StorageManager.shared.presetsDirectory.appendingPathComponent("Templates", isDirectory: true) }

    private init() {
        reload()
    }

    private static func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        templates = files.filter { $0.pathExtension == "json" }
            .compactMap { JSONStore.load(StudioTemplate.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func template(_ id: UUID) -> StudioTemplate? { templates.first { $0.id == id } }

    @discardableResult
    func save(from project: EditProject, name: String, note: String, keepAudio: Bool) throws -> StudioTemplate {
        let template = Self.makeTemplate(from: project, name: name, note: note, keepAudio: keepAudio)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONStore.save(template, to: Self.url(template.id))
        templates.insert(template, at: 0)
        return template
    }

    /// Adds an imported template (it already has a fresh id).
    func add(_ template: StudioTemplate) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONStore.save(template, to: Self.url(template.id))
        templates.insert(template, at: 0)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        templates[index].name = trimmed
        try? JSONStore.save(templates[index], to: Self.url(id))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.url(id))
        templates.removeAll { $0.id == id }
    }

    // MARK: Pure helpers

    nonisolated static func makeTemplate(from project: EditProject, name: String, note: String, keepAudio: Bool) -> StudioTemplate {
        var timeline = project.timeline
        if !keepAudio {
            for t in timeline.tracks.indices where timeline.tracks[t].kind == .audio { timeline.tracks[t].clips = [] }
        }
        var slots: [TemplateSlot] = []
        var candidates: [(start: Double, track: Int, clip: Clip)] = []
        for (t, track) in timeline.tracks.enumerated() where track.kind == .video || track.kind == .overlay {
            for clip in track.clips {
                switch clip.source {
                case .media, .image, .freezeFrame: candidates.append((clip.start.seconds, t, clip))
                default: continue
                }
            }
        }
        candidates.sort { $0.start != $1.start ? $0.start < $1.start : $0.track < $1.track }
        for (index, candidate) in candidates.enumerated() {
            slots.append(TemplateSlot(clipID: candidate.clip.id, index: index + 1, duration: candidate.clip.duration.seconds,
                                      acceptsVideo: true, trackName: timeline.tracks[candidate.track].name))
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return StudioTemplate(id: UUID(), name: trimmed.isEmpty ? project.name : trimmed, createdAt: Date(),
                              settings: project.settings, timeline: timeline, markers: project.markers, slots: slots,
                              note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The template timeline with slots filled by `assignments` (slot clip id → asset).
    /// Empty slots are removed; audio whose file is gone is dropped.
    nonisolated static func fill(_ template: StudioTemplate, assignments: [UUID: MediaAsset], available: Set<UUID>,
                     context: EditContext, report: inout TemplateFillReport) -> Timeline {
        var timeline = template.timeline
        let slotIDs = Set(template.slots.map(\.clipID))
        for t in timeline.tracks.indices {
            var kept: [Clip] = []
            for var clip in timeline.tracks[t].clips {
                if slotIDs.contains(clip.id) {
                    guard let asset = assignments[clip.id] else {
                        report.removedEmpty += 1
                        continue
                    }
                    if place(asset, in: &clip, context: context) { report.slowed += 1 }
                    clip.id = UUID()
                    report.filled += 1
                    kept.append(clip)
                } else {
                    if !clip.referencedAssetIDs.allSatisfy(available.contains) {
                        if timeline.tracks[t].kind == .audio { report.droppedMissingAudio += 1 }
                        continue
                    }
                    clip.id = UUID()
                    kept.append(clip)
                }
            }
            timeline.tracks[t].clips = kept
            timeline.tracks[t].id = UUID()
        }
        TimelineEngine.finalize(&timeline, context: context)
        return timeline
    }

    /// Puts `asset` into a slot clip. Returns true when a short video had to be slowed down.
    @discardableResult
    nonisolated static func place(_ asset: MediaAsset, in clip: inout Clip, context: EditContext) -> Bool {
        clip.name = asset.displayName
        clip.stabilization = nil
        clip.horizon = nil
        clip.mask?.centerTrack = nil
        clip.mask?.sizeTrack = nil
        if clip.crop.isAnimated { clip.crop = KeyframedValue(RectValue.full) }
        clip.speed.isReversed = false
        clip.speed.reversedAssetID = nil
        if asset.kind == .image {
            clip.source = .image(asset.id)
            clip.sourceRange = nil
            clip.speed = .normal
            return false
        }
        clip.source = .media(asset.id)
        let available = asset.durationSeconds ?? clip.duration.seconds
        let needed = clip.sourceRange?.duration.seconds ?? clip.duration.seconds
        let timelineLength = clip.duration.seconds
        if available + 1e-6 >= needed {
            clip.sourceRange = TimeRangeValue(startSeconds: 0, endSeconds: needed)
            return false
        }
        // Too short: slow it down so the slot keeps its length (rhythm of the template).
        clip.speed.ramp = []
        clip.speed.rate = max(SpeedSettings.minimumRate, available / max(0.05, timelineLength))
        clip.sourceRange = TimeRangeValue(startSeconds: 0, endSeconds: available)
        clip.recomputeDurationFromSpeed()
        clip.duration = TimeValue(seconds: context.snap(clip.duration.seconds))
        return true
    }
}
