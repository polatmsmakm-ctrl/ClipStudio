//
//  TextStyleLibrary.swift
//  ClipStudio — Engines/Presets (Text & graphics, Part 3)
//
//  • TitleTemplate: ready title designs (big title, lower thirds, banner, quote…)
//    that are filled with the user's own text when added.
//  • TextStylePresetStore: built-in text looks plus looks saved from any text
//    layer (Presets/text-styles.json, included in backups).
//

import Foundation

// MARK: - Title templates

struct TitleTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let design: TitleDesign
    let style: TextStyle
    let animationIn: TextAnimation
    let animationOut: TextAnimation
    let loop: LoopAnimation
    let accent: RGBAColor
    /// Default position for left-to-right text (mirrored horizontally for Arabic).
    let position: Vec2
    let duration: Double

    /// Builds the text content with the user's text.
    func content(text: String, subtitle: String) -> TextContent {
        var content = TextContent(text: text, style: style, animationIn: animationIn, animationOut: animationOut)
        content.loop = loop
        content.design = design
        content.subtitle = subtitle
        content.accentColor = accent
        return content
    }

    /// Position adapted to the text direction.
    func position(rightToLeft: Bool) -> Vec2 {
        rightToLeft ? Vec2(x: 1 - position.x, y: position.y) : position
    }

    static let gold = RGBAColor(hex: 0xE3B04B)

    static let all: [TitleTemplate] = {
        var big = TextStyle()
        big.weight = .heavy
        big.sizeRatio = 0.09
        big.shadowRadius = 10

        var elegant = TextStyle()
        elegant.weight = .medium
        elegant.sizeRatio = 0.066
        elegant.kerning = 0.06
        elegant.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.4)

        var boxedText = TextStyle()
        boxedText.weight = .bold
        boxedText.sizeRatio = 0.058
        boxedText.color = RGBAColor(hex: 0x1A1408)
        boxedText.backgroundColor = TitleTemplate.gold
        boxedText.shadowColor = nil
        boxedText.backgroundPadding = 0.4

        var lower = TextStyle()
        lower.weight = .bold
        lower.sizeRatio = 0.048
        lower.shadowColor = nil
        lower.alignment = .leading

        var lowerLight = lower
        lowerLight.color = RGBAColor(hex: 0x15161B)
        lowerLight.backgroundColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.92)

        var banner = TextStyle()
        banner.weight = .heavy
        banner.sizeRatio = 0.055
        banner.color = RGBAColor(hex: 0x1A1408)
        banner.shadowColor = nil

        var framed = TextStyle()
        framed.weight = .semibold
        framed.sizeRatio = 0.06
        framed.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.35)

        var underline = TextStyle()
        underline.weight = .bold
        underline.sizeRatio = 0.065

        var quote = TextStyle()
        quote.weight = .medium
        quote.sizeRatio = 0.05
        quote.alignment = .leading
        quote.maxWidthRatio = 0.7

        var typewriter = TextStyle()
        typewriter.weight = .semibold
        typewriter.sizeRatio = 0.055

        var neon = TextStyle()
        neon.weight = .heavy
        neon.sizeRatio = 0.075
        neon.color = RGBAColor(hex: 0xF2EFEA)
        neon.shadowColor = RGBAColor(hex: 0x39D0FF)
        neon.shadowRadius = 26
        neon.shadowOffsetY = 0

        return [
            TitleTemplate(id: "big", title: "عنوان كبير", symbol: "textformat.size.larger", design: .plain, style: big,
                          animationIn: .pop, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.45), duration: 4),
            TitleTemplate(id: "elegant", title: "عنوان أنيق", symbol: "textformat", design: .plain, style: elegant,
                          animationIn: .blur, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.5), duration: 4),
            TitleTemplate(id: "highlight", title: "نص بخلفية", symbol: "character.textbox", design: .plain, style: boxedText,
                          animationIn: .slideUp, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.72), duration: 3),
            TitleTemplate(id: "lower-dark", title: "شريط سفلي", symbol: "rectangle.bottomthird.inset.filled", design: .lowerThird, style: lower,
                          animationIn: .wipe, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.3, y: 0.82), duration: 5),
            TitleTemplate(id: "lower-light", title: "شريط سفلي فاتح", symbol: "rectangle.bottomhalf.inset.filled", design: .lowerThird,
                          style: lowerLight, animationIn: .slideUp, animationOut: .slideDown, loop: .none, accent: TitleTemplate.gold,
                          position: Vec2(x: 0.3, y: 0.82), duration: 5),
            TitleTemplate(id: "banner", title: "لافتة", symbol: "rectangle.fill", design: .banner, style: banner,
                          animationIn: .wipe, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.12), duration: 4),
            TitleTemplate(id: "framed", title: "إطار", symbol: "rectangle.dashed", design: .boxed, style: framed,
                          animationIn: .zoomIn, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.5), duration: 4),
            TitleTemplate(id: "underline", title: "خط سفلي", symbol: "underline", design: .underline, style: underline,
                          animationIn: .slideUp, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.5), duration: 4),
            TitleTemplate(id: "quote", title: "اقتباس", symbol: "quote.opening", design: .quote, style: quote,
                          animationIn: .fade, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.5), duration: 6),
            TitleTemplate(id: "typewriter", title: "آلة كاتبة", symbol: "keyboard", design: .plain, style: typewriter,
                          animationIn: .typewriter, animationOut: .fade, loop: .none, accent: TitleTemplate.gold, position: Vec2(x: 0.5, y: 0.5), duration: 5),
            TitleTemplate(id: "neon", title: "نيون", symbol: "light.max", design: .plain, style: neon,
                          animationIn: .blur, animationOut: .fade, loop: .blink, accent: RGBAColor(hex: 0x39D0FF),
                          position: Vec2(x: 0.5, y: 0.45), duration: 4)
        ]
    }()
}

// MARK: - Text style presets

struct TextStylePreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var style: TextStyle
    var isBuiltIn: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, style: TextStyle, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.style = style
        self.isBuiltIn = isBuiltIn
        self.createdAt = Date()
    }
}

@MainActor
@Observable
final class TextStylePresetStore {
    static let shared = TextStylePresetStore()

    private(set) var userPresets: [TextStylePreset] = []
    private var url: URL { StorageManager.shared.presetsDirectory.appendingPathComponent("text-styles.json") }

    private init() {
        reload()
    }

    var all: [TextStylePreset] { BuiltInTextStyles.all + userPresets }

    func reload() {
        userPresets = (JSONStore.load([TextStylePreset].self, from: url) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ style: TextStyle, name: String) -> TextStylePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = TextStylePreset(name: trimmed.isEmpty ? "نمط " + Fmt.shortDate(Date()) : trimmed, style: style)
        userPresets.insert(preset, at: 0)
        persist()
        return preset
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

/// Built-in text looks (nonisolated so any context can read them).
enum BuiltInTextStyles {
    private static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "7E57A11E-0000-4000-8000-%012ld", index)) ?? UUID()
    }

    private static func make(_ index: Int, _ name: String, _ configure: (inout TextStyle) -> Void) -> TextStylePreset {
        var style = TextStyle()
        configure(&style)
        return TextStylePreset(id: builtInID(index), name: name, style: style, isBuiltIn: true)
    }

    static let all: [TextStylePreset] = [
        make(1, "كلاسيكي") { _ in },
        make(2, "حدود سوداء") { s in
            s.weight = .heavy
            s.outlineColor = .black
            s.outlineWidth = 8
            s.shadowColor = nil
        },
        make(3, "تمييز ذهبي") { s in
            s.color = RGBAColor(hex: 0x1A1408)
            s.backgroundColor = RGBAColor(hex: 0xE3B04B)
            s.shadowColor = nil
        },
        make(4, "صندوق داكن") { s in
            s.weight = .semibold
            s.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.65)
            s.shadowColor = nil
        },
        make(5, "نيون") { s in
            s.weight = .heavy
            s.shadowColor = RGBAColor(hex: 0x39D0FF)
            s.shadowRadius = 24
            s.shadowOffsetY = 0
        },
        make(6, "أنيق رفيع") { s in
            s.weight = .regular
            s.kerning = 0.08
            s.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.35)
        },
        make(7, "ريترو") { s in
            s.weight = .heavy
            s.color = RGBAColor(hex: 0xE58F4A)
            s.outlineColor = RGBAColor(hex: 0x2B1A0A)
            s.outlineWidth = 6
            s.shadowColor = RGBAColor(hex: 0x2B1A0A)
            s.shadowRadius = 0.5
            s.shadowOffsetY = 6
        },
        make(8, "بسيط") { s in
            s.weight = .medium
            s.shadowColor = nil
        }
    ]
}
