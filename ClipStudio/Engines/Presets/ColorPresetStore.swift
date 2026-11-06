//
//  ColorPresetStore.swift
//  ClipStudio — Engines/Presets
//
//  Saved color grades ("looks"): built-in looks plus user presets saved from any
//  clip (sliders, curve, wheels and LUT). Stored in Presets/color-presets.json and
//  included in backups.
//

import Foundation

struct ColorPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var adjustments: ColorAdjustments
    var lut: LUTReference?
    var isBuiltIn: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, adjustments: ColorAdjustments, lut: LUTReference? = nil,
         isBuiltIn: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.lut = lut
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
final class ColorPresetStore {
    private(set) var userPresets: [ColorPreset] = []
    private var url: URL { StorageManager.shared.presetsDirectory.appendingPathComponent("color-presets.json") }

    init() {
        reload()
    }

    var all: [ColorPreset] { BuiltInLooks.all + userPresets }

    func reload() {
        userPresets = (JSONStore.load([ColorPreset].self, from: url) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(name: String, adjustments: ColorAdjustments, lut: LUTReference?) -> ColorPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = ColorPreset(name: trimmed.isEmpty ? "مظهر " + Fmt.shortDate(Date()) : trimmed,
                                 adjustments: adjustments, lut: lut)
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
        try? JSONStore.save(userPresets, to: url)
    }
}

// MARK: - Built-in looks

enum BuiltInLooks {

    private static func look(_ suffix: Int, _ name: String, _ configure: (inout ColorAdjustments) -> Void) -> ColorPreset {
        var adjustments = ColorAdjustments()
        configure(&adjustments)
        let id = UUID(uuidString: String(format: "7C2D1A00-0000-4E00-9C00-%012ld", suffix)) ?? UUID()
        return ColorPreset(id: id, name: name, adjustments: adjustments, isBuiltIn: true, createdAt: .distantPast)
    }

    static let all: [ColorPreset] = [
        look(1, "ذهبي دافئ") { $0.temperature = 35; $0.saturation = 10; $0.contrast = 10; $0.highlights = -8 },
        look(2, "سينمائي بارد") { $0.temperature = -30; $0.tint = 5; $0.contrast = 18; $0.saturation = -12; $0.blacks = -10 },
        look(3, "تيل وبرتقالي") { c in
            c.saturation = 12
            c.contrast = 14
            c.wheels.gain = RGBOffset(r: 0.07, g: 0.0, b: -0.05)
            c.wheels.lift = RGBOffset(r: -0.02, g: 0.01, b: 0.05)
        },
        look(4, "أبيض وأسود متباين") { $0.saturation = -100; $0.contrast = 32; $0.blacks = -15; $0.whites = 10 },
        look(5, "باهت ناعم") { c in
            c.curve = ToneCurve(points: [0.08, 0.28, 0.5, 0.72, 0.94])
            c.saturation = -15
            c.contrast = -5
        },
        look(6, "حيوي") { $0.vibrance = 40; $0.contrast = 10; $0.saturation = 5 },
        look(7, "غروب") { $0.temperature = 45; $0.tint = 10; $0.exposure = 5; $0.highlights = -12; $0.saturation = 8 },
        look(8, "ليلي") { $0.temperature = -40; $0.exposure = -15; $0.saturation = -20; $0.contrast = 12 },
        look(9, "فيلم قديم") { c in
            c.saturation = -40
            c.temperature = 25
            c.curve = ToneCurve(points: [0.1, 0.3, 0.52, 0.72, 0.9])
        },
        look(10, "تباين عالٍ") { $0.contrast = 40; $0.blacks = -20; $0.whites = 15; $0.vibrance = 10 },
        look(11, "بشرة طبيعية") { $0.temperature = 10; $0.vibrance = 15; $0.saturation = -5; $0.shadows = 10 },
        look(12, "أخضر طبيعة") { c in
            c.hue = -4
            c.vibrance = 30
            c.wheels.gamma = RGBOffset(r: -0.02, g: 0.04, b: -0.01)
        }
    ]
}
