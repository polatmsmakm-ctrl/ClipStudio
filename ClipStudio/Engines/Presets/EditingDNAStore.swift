//
//  EditingDNAStore.swift
//  ClipStudio — Engines/Presets (Part 4)
//
//  Built-in editing styles plus the ones learned from the user's projects and
//  reference videos. Stored in Presets/editing-dna.json (included in backups).
//

import Foundation

@MainActor
@Observable
final class EditingDNAStore {
    static let shared = EditingDNAStore()

    private(set) var userStyles: [EditingDNA] = []
    static var fileURL: URL { StorageManager.shared.presetsDirectory.appendingPathComponent("editing-dna.json") }

    private init() {
        reload()
    }

    var all: [EditingDNA] { userStyles + EditingDNA.builtIns }

    func style(_ id: UUID) -> EditingDNA? { all.first { $0.id == id } }

    func reload() {
        userStyles = (JSONStore.load([EditingDNA].self, from: Self.fileURL) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ dna: EditingDNA) {
        var copy = dna
        copy.isBuiltIn = false
        let trimmed = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? "أسلوب " + Fmt.shortDate(Date()) : trimmed
        if let index = userStyles.firstIndex(where: { $0.id == copy.id }) {
            userStyles[index] = copy
        } else {
            copy.createdAt = Date()
            userStyles.insert(copy, at: 0)
        }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = userStyles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userStyles[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        userStyles.removeAll { $0.id == id }
        persist()
    }

    /// A user copy of any style (built-ins can't be edited in place).
    @discardableResult
    func duplicate(_ id: UUID) -> EditingDNA? {
        guard var copy = style(id) else { return nil }
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name += " (نسخة)"
        save(copy)
        return copy
    }

    private func persist() {
        StorageManager.shared.ensureDirectories()
        try? JSONStore.save(userStyles, to: Self.fileURL)
    }
}

// MARK: - Built-in styles

extension EditingDNA {
    private static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "D7A00000-0000-4000-8000-%012ld", index)) ?? UUID()
    }

    static let builtIns: [EditingDNA] = [fastReels, calmCinematic, documentary, dailyVlog]

    static let fastReels: EditingDNA = {
        var dna = EditingDNA(id: builtInID(1), name: "ريلز سريع", symbol: "bolt.fill", isBuiltIn: true,
                             origin: "أسلوب جاهز", averageShotLength: 1.2, shotLengthSpread: 0.3, transitionRate: 0.25,
                             transitionKind: .zoomIn, transitionDuration: 0.25, cutsOnBeat: true, stillMotion: true)
        var color = ColorAdjustments()
        color.contrast = 14
        color.saturation = 12
        color.vibrance = 15
        dna.color = color
        let preset = CaptionStylePreset.bold
        dna.captionStyle = preset.style
        dna.captionHighlight = preset.highlight
        dna.captionHighlightColor = preset.highlightColor
        dna.musicVolume = 0.8
        dna.aspect = .portrait9x16
        return dna
    }()

    static let calmCinematic: EditingDNA = {
        var dna = EditingDNA(id: builtInID(2), name: "سينمائي هادئ", symbol: "film", isBuiltIn: true,
                             origin: "أسلوب جاهز", averageShotLength: 4.5, shotLengthSpread: 0.2, transitionRate: 0.6,
                             transitionKind: .crossDissolve, transitionDuration: 0.8, cutsOnBeat: false, stillMotion: true)
        var color = ColorAdjustments()
        color.contrast = 16
        color.saturation = -12
        color.temperature = -18
        color.blacks = -8
        dna.color = color
        var title = TextStyle()
        title.weight = .semibold
        title.sizeRatio = 0.05
        title.kerning = 4
        title.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.45)
        dna.titleStyle = title
        dna.musicVolume = 0.55
        dna.aspect = .landscape16x9
        return dna
    }()

    static let documentary: EditingDNA = {
        var dna = EditingDNA(id: builtInID(3), name: "وثائقي", symbol: "books.vertical", isBuiltIn: true,
                             origin: "أسلوب جاهز", averageShotLength: 6, shotLengthSpread: 0.35, transitionRate: 0.15,
                             transitionKind: .fadeBlack, transitionDuration: 0.6, cutsOnBeat: false, stillMotion: true)
        var color = ColorAdjustments()
        color.contrast = 8
        color.saturation = -5
        dna.color = color
        let preset = CaptionStylePreset.classic
        dna.captionStyle = preset.style
        dna.captionHighlight = preset.highlight
        dna.captionHighlightColor = preset.highlightColor
        var title = TextStyle()
        title.weight = .bold
        title.sizeRatio = 0.045
        title.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.55)
        dna.titleStyle = title
        dna.musicVolume = 0.35
        dna.aspect = .landscape16x9
        return dna
    }()

    static let dailyVlog: EditingDNA = {
        var dna = EditingDNA(id: builtInID(4), name: "فلوق يومي", symbol: "person.crop.square", isBuiltIn: true,
                             origin: "أسلوب جاهز", averageShotLength: 2.5, shotLengthSpread: 0.4, transitionRate: 0.12,
                             transitionKind: .swipe, transitionDuration: 0.3, cutsOnBeat: false, stillMotion: true)
        var color = ColorAdjustments()
        color.vibrance = 22
        color.temperature = 12
        color.contrast = 6
        dna.color = color
        let preset = CaptionStylePreset.box
        dna.captionStyle = preset.style
        dna.captionHighlight = preset.highlight
        dna.captionHighlightColor = preset.highlightColor
        dna.musicVolume = 0.5
        dna.aspect = .portrait9x16
        return dna
    }()
}
