//
//  Effects.swift
//  ClipStudio — Models
//
//  Color grading, LUTs, effects, masks, chroma key, blend modes and transitions.
//  All are rendered by the GPU pipeline in Engines/Rendering.
//  Part 4 (suggestions): masks can follow a tracked subject (center / size tracks).
//

import Foundation

// MARK: - Color grading

struct ToneCurve: Codable, Hashable {
    /// Output levels for inputs 0, 0.25, 0.5, 0.75, 1.0.
    var points: [Double]

    init(points: [Double] = [0, 0.25, 0.5, 0.75, 1]) {
        self.points = points.count == 5 ? points : [0, 0.25, 0.5, 0.75, 1]
    }

    static let identity = ToneCurve()
    var isIdentity: Bool { zip(points, ToneCurve.identity.points).allSatisfy { abs($0 - $1) < 0.0001 } }
}

struct RGBOffset: Codable, Hashable {
    var r: Double = 0
    var g: Double = 0
    var b: Double = 0

    var isZero: Bool { abs(r) < 0.0001 && abs(g) < 0.0001 && abs(b) < 0.0001 }
}

/// Lift / gamma / gain color wheels (per-channel offsets, typically −0.5…0.5).
struct ColorWheels: Codable, Hashable {
    var lift = RGBOffset()
    var gamma = RGBOffset()
    var gain = RGBOffset()

    var isNeutral: Bool { lift.isZero && gamma.isZero && gain.isZero }
}

/// All sliders use −100…100 with 0 = neutral.
struct ColorAdjustments: Codable, Hashable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var hue: Double = 0
    var curve = ToneCurve.identity
    var wheels = ColorWheels()

    static let neutral = ColorAdjustments()

    var isNeutral: Bool { self == .neutral }

    var needsToneCurve: Bool {
        !curve.isIdentity || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case exposure, brightness, contrast, highlights, shadows, whites, blacks
        case saturation, vibrance, temperature, tint, hue, curve, wheels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = c.value(.exposure, default: 0)
        brightness = c.value(.brightness, default: 0)
        contrast = c.value(.contrast, default: 0)
        highlights = c.value(.highlights, default: 0)
        shadows = c.value(.shadows, default: 0)
        whites = c.value(.whites, default: 0)
        blacks = c.value(.blacks, default: 0)
        saturation = c.value(.saturation, default: 0)
        vibrance = c.value(.vibrance, default: 0)
        temperature = c.value(.temperature, default: 0)
        tint = c.value(.tint, default: 0)
        hue = c.value(.hue, default: 0)
        curve = c.value(.curve, default: ToneCurve.identity)
        wheels = c.value(.wheels, default: ColorWheels())
    }
}

struct LUTReference: Codable, Hashable {
    var lutID: UUID
    /// 0…1
    var intensity: Double = 1
}

// MARK: - Effects

enum EffectKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case blur, sharpen, vignette, grain, glow, monochrome, sepia, pixelate
    case motionBlur, zoomBlur, chromaticAberration, letterbox, filmLook, fadedFilm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: "تمويه"
        case .sharpen: "حدّة"
        case .vignette: "تظليل الأطراف"
        case .grain: "حبيبات فيلم"
        case .glow: "توهّج"
        case .monochrome: "أبيض وأسود"
        case .sepia: "سيبيا"
        case .pixelate: "بكسلة"
        case .motionBlur: "ضبابية الحركة"
        case .zoomBlur: "ضبابية تقريب"
        case .chromaticAberration: "انزياح لوني"
        case .letterbox: "أشرطة سينمائية"
        case .filmLook: "مظهر سينمائي"
        case .fadedFilm: "فيلم باهت"
        }
    }

    var symbol: String {
        switch self {
        case .blur: "drop.halffull"
        case .sharpen: "triangle"
        case .vignette: "circle.dashed"
        case .grain: "circle.grid.3x3.fill"
        case .glow: "sun.max"
        case .monochrome: "circle.lefthalf.filled"
        case .sepia: "photo.artframe"
        case .pixelate: "square.grid.3x3"
        case .motionBlur: "wind"
        case .zoomBlur: "scope"
        case .chromaticAberration: "camera.filters"
        case .letterbox: "rectangle.inset.filled"
        case .filmLook: "film"
        case .fadedFilm: "camera.aperture"
        }
    }

    var defaultIntensity: Double {
        switch self {
        case .blur, .pixelate, .motionBlur, .zoomBlur: 0.3
        case .letterbox: 0.5
        default: 0.6
        }
    }
}

struct EffectInstance: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: EffectKind
    /// 0…1, keyframable.
    var intensity: KeyframedValue<Double>
    var isEnabled: Bool = true

    init(kind: EffectKind) {
        self.kind = kind
        self.intensity = KeyframedValue(kind.defaultIntensity)
    }
}

// MARK: - Masks

enum MaskShape: String, Codable, CaseIterable, Hashable {
    case rectangle, ellipse, linear

    var title: String {
        switch self {
        case .rectangle: "مستطيل"
        case .ellipse: "دائري"
        case .linear: "خطي"
        }
    }
}

struct MaskSettings: Codable, Hashable {
    var isEnabled = true
    var shape: MaskShape = .ellipse
    /// Normalized within the clip (top-left origin).
    var center = Vec2.center
    var size = Vec2(x: 0.6, y: 0.6)
    var rotation: Double = 0
    /// 0…1 softness of the edge.
    var feather: Double = 0.15
    var invert = false
    /// Part 4: center / size that follow a tracked subject (clip-local times). nil = static.
    var centerTrack: KeyframedValue<Vec2>? = nil
    var sizeTrack: KeyframedValue<Vec2>? = nil

    /// The mask at clip-local time `t` (tracks applied).
    func resolved(at t: Double) -> MaskSettings {
        guard centerTrack != nil || sizeTrack != nil else { return self }
        var copy = self
        if let centerTrack { copy.center = centerTrack.value(at: t) }
        if let sizeTrack { copy.size = sizeTrack.value(at: t) }
        return copy
    }

    var followsSubject: Bool { centerTrack != nil }
}

// MARK: - Chroma key

struct ChromaKeySettings: Codable, Hashable {
    var isEnabled = true
    var keyColor = RGBAColor.chromaGreen
    /// 0…1 hue distance accepted as key.
    var tolerance: Double = 0.3
    /// 0…1 edge softness.
    var softness: Double = 0.12
    /// 0…1 removes key-color spill from remaining pixels.
    var spillSuppression: Double = 0.5
}

// MARK: - Blend modes

enum BlendMode: String, Codable, CaseIterable, Hashable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten
    case colorDodge, colorBurn, difference, add, luminosity, color, hue, saturation

    var title: String {
        switch self {
        case .normal: "عادي"
        case .multiply: "مضاعفة"
        case .screen: "شاشة"
        case .overlay: "تراكب"
        case .softLight: "ضوء ناعم"
        case .hardLight: "ضوء قوي"
        case .darken: "تغميق"
        case .lighten: "تفتيح"
        case .colorDodge: "تفادي اللون"
        case .colorBurn: "حرق اللون"
        case .difference: "اختلاف"
        case .add: "إضافة"
        case .luminosity: "إضاءة"
        case .color: "لون"
        case .hue: "صبغة"
        case .saturation: "تشبّع"
        }
    }

    /// Core Image filter name (nil for normal source-over).
    var ciFilterName: String? {
        switch self {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .add: "CIAdditionCompositing"
        case .luminosity: "CILuminosityBlendMode"
        case .color: "CIColorBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        }
    }
}

// MARK: - Transitions

enum TransitionKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case none, crossDissolve, fadeBlack, fadeWhite
    case wipeLeft, wipeRight, wipeUp, wipeDown
    case slideLeft, slideRight, slideUp, slideDown, push
    case zoomIn, zoomOut, blur, swipe, bars, copyMachine, flash, circleReveal, spin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "بدون"
        case .crossDissolve: "تلاشي متقاطع"
        case .fadeBlack: "تلاشي للأسود"
        case .fadeWhite: "تلاشي للأبيض"
        case .wipeLeft: "مسح لليسار"
        case .wipeRight: "مسح لليمين"
        case .wipeUp: "مسح للأعلى"
        case .wipeDown: "مسح للأسفل"
        case .slideLeft: "انزلاق لليسار"
        case .slideRight: "انزلاق لليمين"
        case .slideUp: "انزلاق للأعلى"
        case .slideDown: "انزلاق للأسفل"
        case .push: "دفع"
        case .zoomIn: "تقريب"
        case .zoomOut: "تبعيد"
        case .blur: "تمويه"
        case .swipe: "سحب"
        case .bars: "أشرطة"
        case .copyMachine: "ناسخة"
        case .flash: "وميض"
        case .circleReveal: "كشف دائري"
        case .spin: "دوران"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .crossDissolve: "circle.lefthalf.filled"
        case .fadeBlack: "moon.fill"
        case .fadeWhite: "sun.max.fill"
        case .wipeLeft: "arrow.left.to.line"
        case .wipeRight: "arrow.right.to.line"
        case .wipeUp: "arrow.up.to.line"
        case .wipeDown: "arrow.down.to.line"
        case .slideLeft: "arrow.left"
        case .slideRight: "arrow.right"
        case .slideUp: "arrow.up"
        case .slideDown: "arrow.down"
        case .push: "arrow.left.arrow.right"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .blur: "aqi.medium"
        case .swipe: "hand.draw"
        case .bars: "line.3.horizontal"
        case .copyMachine: "doc.on.doc"
        case .flash: "bolt.fill"
        case .circleReveal: "circle.circle"
        case .spin: "arrow.triangle.2.circlepath"
        }
    }
}

struct TransitionInstance: Codable, Hashable {
    var kind: TransitionKind
    var duration: TimeValue

    init(kind: TransitionKind, duration: TimeValue = TimeValue(seconds: 0.5)) {
        self.kind = kind
        self.duration = duration
    }
}
