//
//  MotionPresetStore.swift
//  ClipStudio — Engines/Presets
//
//  Built-in motion presets plus the ones saved from the user's animated clips.
//  Stored in Presets/motion-presets.json (included in backups).
//

import Foundation

@MainActor
@Observable
final class MotionPresetStore {
    static let shared = MotionPresetStore()

    private(set) var userPresets: [MotionPreset] = []
    private var url: URL { StorageManager.shared.presetsDirectory.appendingPathComponent("motion-presets.json") }

    private init() {
        reload()
    }

    var all: [MotionPreset] { MotionPreset.builtIns + userPresets }

    func preset(_ id: UUID) -> MotionPreset? { all.first { $0.id == id } }

    func reload() {
        userPresets = (JSONStore.load([MotionPreset].self, from: url) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves the clip's transform animation as a preset. Returns nil when the clip has none.
    @discardableResult
    func save(from clip: Clip, name: String) -> MotionPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var preset = MotionPreset.capture(from: clip, name: trimmed.isEmpty ? "حركة " + Fmt.shortDate(Date()) : trimmed) else {
            return nil
        }
        preset.createdAt = Date()
        userPresets.insert(preset, at: 0)
        persist()
        return preset
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        StorageManager.shared.ensureDirectories()
        try? JSONStore.save(userPresets, to: url)
    }
}
