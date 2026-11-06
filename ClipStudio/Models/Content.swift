//
//  Content.swift
//  ClipStudio — Models
//
//  Generated layer content: text (titles, lower thirds, captions), shapes and
//  stickers. Rendered by Engines/Rendering/GeneratedContentRenderer with full
//  Arabic (RTL) support. Part 3 adds title designs, loop animations, extra in/out
//  animations, letter spacing, caption word timing and more shapes; every new
//  field has a default so older project files decode unchanged.
//

import Foundation
import UIKit

enum FontWeightOption: String, Codable, CaseIterable, Hashable {
    case regular, medium, semibold, bold, heavy

    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var title: String {
        switch self {
        case .regular: "عادي"
        case .medium: "متوسط"
        case .semibold: "شبه عريض"
        case .bold: "عريض"
        case .heavy: "ثقيل"
        }
    }
}

enum TextAlignmentOption: String, Codable, CaseIterable, Hashable {
    case leading, center, trailing

    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    var title: String {
        switch self {
        case .leading: "بداية السطر"
        case .center: "وسط"
        case .trailing: "نهاية السطر"
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignright"
        case .center: "text.aligncenter"
        case .trailing: "text.alignleft"
        }
    }
}

/// Entrance / exit animations.
enum TextAnimation: String, Codable, CaseIterable, Hashable {
    case none, fade, slideUp, slideDown, pop, zoomIn, typewriter, blur, wipe, bounce, spin

    var title: String {
        switch self {
        case .none: "بدون"
        case .fade: "تلاشي"
        case .slideUp: "انزلاق للأعلى"
        case .slideDown: "انزلاق للأسفل"
        case .pop: "قفزة"
        case .zoomIn: "تكبير"
        case .typewriter: "آلة كاتبة"
        case .blur: "ضبابية"
        case .wipe: "مسح"
        case .bounce: "ارتداد"
        case .spin: "دوران"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .fade: "circle.lefthalf.filled"
        case .slideUp: "arrow.up"
        case .slideDown: "arrow.down"
        case .pop: "sparkle"
        case .zoomIn: "plus.magnifyingglass"
        case .typewriter: "keyboard"
        case .blur: "aqi.medium"
        case .wipe: "rectangle.righthalf.inset.filled"
        case .bounce: "arrow.down.to.line"
        case .spin: "arrow.triangle.2.circlepath"
        }
    }

    /// Exit animations exclude the typewriter effect (it only reveals).
    static var exitCases: [TextAnimation] { allCases.filter { $0 != .typewriter } }
}

/// Continuous animation while the layer is on screen.
enum LoopAnimation: String, Codable, CaseIterable, Hashable {
    case none, pulse, float, shake, swing, blink, rotate

    var title: String {
        switch self {
        case .none: "بدون"
        case .pulse: "نبض"
        case .float: "طفو"
        case .shake: "اهتزاز"
        case .swing: "تأرجح"
        case .blink: "وميض"
        case .rotate: "دوران مستمر"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .pulse: "heart"
        case .float: "cloud"
        case .shake: "waveform.path"
        case .swing: "metronome"
        case .blink: "light.max"
        case .rotate: "arrow.clockwise"
        }
    }
}

/// How a text layer is laid out and decorated.
enum TitleDesign: String, Codable, CaseIterable, Hashable {
    case plain, lowerThird, boxed, underline, banner, quote

    var title: String {
        switch self {
        case .plain: "نص"
        case .lowerThird: "شريط سفلي"
        case .boxed: "إطار"
        case .underline: "خط سفلي"
        case .banner: "لافتة"
        case .quote: "اقتباس"
        }
    }

    var symbol: String {
        switch self {
        case .plain: "textformat"
        case .lowerThird: "rectangle.bottomthird.inset.filled"
        case .boxed: "rectangle.dashed"
        case .underline: "underline"
        case .banner: "rectangle.fill"
        case .quote: "quote.opening"
        }
    }

    /// Designs that show the secondary line.
    var usesSubtitle: Bool { self == .lowerThird || self == .quote || self == .banner }
}

struct TextStyle: Codable, Hashable {
    /// PostScript font name; nil = system font (SF Arabic for Arabic text).
    var fontName: String? = nil
    var weight: FontWeightOption = .bold
    /// Font size relative to canvas height (0.06 ≈ 65 pt on 1080p).
    var sizeRatio: Double = 0.06
    var color = RGBAColor.white
    var alignment: TextAlignmentOption = .center
    var outlineColor: RGBAColor? = nil
    /// Outline width as a percentage of font size (Core Text stroke width).
    var outlineWidth: Double = 0
    var shadowColor: RGBAColor? = RGBAColor(r: 0, g: 0, b: 0, a: 0.55)
    var shadowRadius: Double = 6
    var shadowOffsetY: Double = 2
    var backgroundColor: RGBAColor? = nil
    /// Padding around text inside the background box, relative to font size.
    var backgroundPadding: Double = 0.35
    var cornerRadius: Double = 0.25
    var lineSpacing: Double = 0
    /// Maximum text width relative to canvas width before wrapping.
    var maxWidthRatio: Double = 0.86
    /// Letter spacing relative to font size (0 = font default).
    var kerning: Double = 0

    enum CodingKeys: String, CodingKey {
        case fontName, weight, sizeRatio, color, alignment, outlineColor, outlineWidth, shadowColor, shadowRadius
        case shadowOffsetY, backgroundColor, backgroundPadding, cornerRadius, lineSpacing, maxWidthRatio, kerning
    }
}

extension TextStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        weight = c.value(.weight, default: FontWeightOption.bold)
        sizeRatio = c.value(.sizeRatio, default: 0.06)
        color = c.value(.color, default: RGBAColor.white)
        alignment = c.value(.alignment, default: TextAlignmentOption.center)
        outlineColor = try? c.decodeIfPresent(RGBAColor.self, forKey: .outlineColor)
        outlineWidth = c.value(.outlineWidth, default: 0.0)
        // Optional colors are omitted when nil, so a missing key means "none".
        shadowColor = try? c.decodeIfPresent(RGBAColor.self, forKey: .shadowColor)
        shadowRadius = c.value(.shadowRadius, default: 6.0)
        shadowOffsetY = c.value(.shadowOffsetY, default: 2.0)
        backgroundColor = try? c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
        backgroundPadding = c.value(.backgroundPadding, default: 0.35)
        cornerRadius = c.value(.cornerRadius, default: 0.25)
        lineSpacing = c.value(.lineSpacing, default: 0.0)
        maxWidthRatio = c.value(.maxWidthRatio, default: 0.86)
        kerning = c.value(.kerning, default: 0.0)
    }
}

struct TextContent: Codable, Hashable {
    var text: String
    var style = TextStyle()
    var animationIn: TextAnimation = .fade
    var animationOut: TextAnimation = .fade
    var loop: LoopAnimation = .none
    var design: TitleDesign = .plain
    /// Secondary line (lower thirds, quote attribution, banner subtitle).
    var subtitle: String = ""
    /// Bars, frames and quote marks of title designs.
    var accentColor = RGBAColor(hex: 0xE3B04B)
    /// Word timing for captions (nil = ordinary text layer).
    var caption: CaptionInfo? = nil

    var isCaption: Bool { caption != nil }

    enum CodingKeys: String, CodingKey {
        case text, style, animationIn, animationOut, loop, design, subtitle, accentColor, caption
    }
}

extension TextContent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: c.value(.text, default: ""))
        style = c.value(.style, default: TextStyle())
        animationIn = c.value(.animationIn, default: TextAnimation.fade)
        animationOut = c.value(.animationOut, default: TextAnimation.fade)
        loop = c.value(.loop, default: LoopAnimation.none)
        design = c.value(.design, default: TitleDesign.plain)
        subtitle = c.value(.subtitle, default: "")
        accentColor = c.value(.accentColor, default: RGBAColor(hex: 0xE3B04B))
        caption = try? c.decodeIfPresent(CaptionInfo.self, forKey: .caption)
    }
}

enum ShapeKind: String, Codable, CaseIterable, Hashable {
    case rectangle, roundedRectangle, ellipse, triangle, line, star, arrow, heart, bubble

    var title: String {
        switch self {
        case .rectangle: "مستطيل"
        case .roundedRectangle: "مستطيل مدوّر"
        case .ellipse: "دائرة"
        case .triangle: "مثلث"
        case .line: "خط"
        case .star: "نجمة"
        case .arrow: "سهم"
        case .heart: "قلب"
        case .bubble: "فقاعة كلام"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle.fill"
        case .roundedRectangle: "app.fill"
        case .ellipse: "circle.fill"
        case .triangle: "triangle.fill"
        case .line: "line.diagonal"
        case .star: "star.fill"
        case .arrow: "arrow.right"
        case .heart: "heart.fill"
        case .bubble: "bubble.left.fill"
        }
    }
}

struct ShapeContent: Codable, Hashable {
    var kind: ShapeKind = .roundedRectangle
    /// Size relative to canvas (width ratio, height ratio).
    var size = Vec2(x: 0.4, y: 0.2)
    var fill: RGBAColor? = RGBAColor(hex: 0xE3B04B)
    var stroke: RGBAColor? = nil
    /// Stroke width relative to canvas height.
    var strokeWidth: Double = 0.006
    /// Corner radius relative to the shape's shorter side.
    var cornerRadius: Double = 0.2
}

struct StickerContent: Codable, Hashable {
    /// SF Symbol name or an emoji string.
    var symbolName: String
    var isEmoji: Bool
    var color = RGBAColor.white
    /// Size relative to canvas height.
    var sizeRatio: Double = 0.18
    var loop: LoopAnimation = .none

    enum CodingKeys: String, CodingKey { case symbolName, isEmoji, color, sizeRatio, loop }
}

extension StickerContent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(symbolName: c.value(.symbolName, default: "star.fill"), isEmoji: c.value(.isEmoji, default: false))
        color = c.value(.color, default: RGBAColor.white)
        sizeRatio = c.value(.sizeRatio, default: 0.18)
        loop = c.value(.loop, default: LoopAnimation.none)
    }
}

// MARK: - Script direction

enum ScriptDirection {
    /// True when the first strong character of the text is Arabic / Hebrew (right-to-left).
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x0370...0x058F:
                return false
            default:
                continue
            }
        }
        return false
    }
}
