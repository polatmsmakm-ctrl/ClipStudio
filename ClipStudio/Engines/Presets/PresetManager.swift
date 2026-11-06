//
//  PresetManager.swift
//  ClipStudio — Engines/Presets (PresetManager module)
//
//  Editable social-media platform presets (persisted). Built-in presets can be
//  edited and reset; custom presets can be added and deleted.
//  Part 4 adds "Editing DNA" style presets to this module.
//

import Foundation

@MainActor
@Observable
final class PresetManager {
    private(set) var platforms: [PlatformPreset] = []
    private let storage = StorageManager.shared
    private var url: URL { storage.presetsDirectory.appendingPathComponent("platforms.json") }

    init() { reload() }

    func reload() {
        var loaded = JSONStore.load([PlatformPreset].self, from: url) ?? PlatformPreset.defaults
        // Add built-ins introduced by newer versions without touching user edits.
        let knownKeys = Set(loaded.map(\.key))
        for preset in PlatformPreset.defaults where !knownKeys.contains(preset.key) { loaded.append(preset) }
        platforms = loaded
    }

    func preset(key: String?) -> PlatformPreset? {
        guard let key else { return nil }
        return platforms.first { $0.key == key }
    }

    func save(_ preset: PlatformPreset) {
        if let index = platforms.firstIndex(where: { $0.id == preset.id }) {
            platforms[index] = preset
        } else {
            platforms.append(preset)
        }
        persist()
    }

    func addCustom() -> PlatformPreset {
        let id = UUID()
        let preset = PlatformPreset(id: id, key: id.uuidString, name: "منصة مخصصة", symbol: "star", maxDuration: 60,
                                    maxFileSizeMB: nil, aspect: .portrait9x16, resolution: .p1080, frameRate: .fps30,
                                    codec: .h264, fitMode: .fitBlur, isBuiltIn: false, notes: "")
        platforms.append(preset)
        persist()
        return preset
    }

    func delete(_ id: UUID) {
        platforms.removeAll { $0.id == id && !$0.isBuiltIn }
        persist()
    }

    func resetBuiltIn(_ id: UUID) {
        guard let index = platforms.firstIndex(where: { $0.id == id }),
              let original = PlatformPreset.defaults.first(where: { $0.id == id }) else { return }
        platforms[index] = original
        persist()
    }

    func resetAll() {
        platforms = PlatformPreset.defaults + platforms.filter { !$0.isBuiltIn }
        persist()
    }

    private func persist() {
        try? JSONStore.save(platforms, to: url)
    }
}

// MARK: - App settings

@MainActor
@Observable
final class AppSettings {
    enum Keys {
        static let haptics = "settings.haptics"
        static let animatedBackground = "settings.animatedBackground"
        static let defaultExport = "settings.defaultExport"
        static let previewQuality = "settings.previewQuality"
    }

    enum PreviewQuality: String, CaseIterable, Codable {
        case performance, balanced, high

        var title: String {
            switch self {
            case .performance: "أداء (540p)"
            case .balanced: "متوازن (720p)"
            case .high: "عالية (1080p)"
            }
        }

        var maxShortSide: CGFloat {
            switch self {
            case .performance: 540
            case .balanced: 720
            case .high: 1080
            }
        }
    }

    private let defaults = UserDefaults.standard

    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    var animatedBackground: Bool { didSet { defaults.set(animatedBackground, forKey: Keys.animatedBackground) } }
    var previewQuality: PreviewQuality { didSet { defaults.set(previewQuality.rawValue, forKey: Keys.previewQuality) } }
    var defaultExport: ExportSettings {
        didSet {
            if let data = try? JSONEncoder().encode(defaultExport) { defaults.set(data, forKey: Keys.defaultExport) }
        }
    }

    init() {
        hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        animatedBackground = defaults.object(forKey: Keys.animatedBackground) as? Bool ?? true
        previewQuality = PreviewQuality(rawValue: defaults.string(forKey: Keys.previewQuality) ?? "") ?? .balanced
        if let data = defaults.data(forKey: Keys.defaultExport),
           let decoded = try? JSONDecoder().decode(ExportSettings.self, from: data) {
            defaultExport = decoded
        } else {
            defaultExport = .standard
        }
    }
}
