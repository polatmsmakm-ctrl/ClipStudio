//
//  Intelligence.swift
//  ClipStudio — Models (Part 4)
//
//  Data produced and consumed by the local intelligence features:
//  • subject tracks (Vision) for smart reframe and object tracking;
//  • stabilization settings (per clip) and analysis data (per media file);
//  • music analysis (tempo, beats, downbeats, energy, sections);
//  • Editing DNA (a reusable editing style learned from a project or a reference video);
//  • Studio templates (projects saved with fillable media slots);
//  • output formats for multi-format variants;
//  • (suggestions) horizon leveling and privacy styles.
//

import Foundation

// MARK: - Subject tracking

struct SubjectSample: Codable, Hashable {
    /// Source-media seconds.
    var time: Double
    /// Normalized rect, top-left origin, in source pixels space (0…1).
    var rect: RectValue
    var confidence: Double
}

enum SubjectMode: String, Codable, CaseIterable, Hashable {
    /// Faces first, then people, then the most salient object.
    case auto
    case faces
    case people
    case salient
    /// A user-selected object followed with Vision object tracking.
    case object

    var title: String {
        switch self {
        case .auto: "تلقائي"
        case .faces: "الوجوه"
        case .people: "الأشخاص"
        case .salient: "أبرز عنصر"
        case .object: "عنصر تختاره"
        }
    }
}

struct SubjectTrack: Codable, Hashable {
    var assetID: UUID
    var mode: SubjectMode
    /// Source-time span that was analyzed.
    var span: TimeSpan
    var samples: [SubjectSample]
    /// Source pixel size (oriented) — needed to compute crops for another aspect ratio.
    var sourceWidth: Double
    var sourceHeight: Double

    var coverage: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.filter { $0.confidence > 0 }.count) / Double(samples.count)
    }
}

// MARK: - Stabilization

struct StabilizationSettings: Codable, Hashable {
    var isEnabled = true
    /// 0…1 — how much camera movement is removed (smoothing window).
    var strength: Double = 0.6
    /// Extra zoom that hides the moving borders (1 = none). Computed from the analysis, user adjustable.
    var zoom: Double = 1.08
    /// Key of the cached analysis (asset id).
    var assetID: UUID

    enum CodingKeys: String, CodingKey { case isEnabled, strength, zoom, assetID }
}

extension StabilizationSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let assetID = try c.decode(UUID.self, forKey: .assetID)
        self.init(assetID: assetID)
        isEnabled = c.value(.isEnabled, default: true)
        strength = c.value(.strength, default: 0.6)
        zoom = c.value(.zoom, default: 1.08)
    }
}

/// Raw camera path of a media file (cumulative translation, normalized to frame size).
struct StabilizationData: Codable, Hashable {
    var assetID: UUID
    var span: TimeSpan
    /// Source seconds.
    var times: [Double]
    /// Cumulative camera offset (normalized, +x right, +y down).
    var pathX: [Double]
    var pathY: [Double]
    var sampleRate: Double
}

// MARK: - Horizon leveling

struct HorizonSettings: Codable, Hashable {
    var isEnabled = true
    /// 0…1 — how much of the measured tilt is corrected.
    var strength: Double = 1
    /// Seconds of smoothing applied to the measured angle.
    var smoothing: Double = 0.6
    var assetID: UUID

    enum CodingKeys: String, CodingKey { case isEnabled, strength, smoothing, assetID }
}

extension HorizonSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let assetID = try c.decode(UUID.self, forKey: .assetID)
        self.init(assetID: assetID)
        isEnabled = c.value(.isEnabled, default: true)
        strength = c.value(.strength, default: 1.0)
        smoothing = c.value(.smoothing, default: 0.6)
    }
}

/// Measured horizon tilt of a media file (radians, counter-clockwise positive).
struct HorizonData: Codable, Hashable {
    var assetID: UUID
    var times: [Double]
    var angles: [Double]
    /// 0…1 confidence of each sample (0 = no horizon found, value held).
    var confidence: [Double]
}

// MARK: - Privacy

enum PrivacyStyle: String, CaseIterable, Identifiable, Hashable {
    case pixelate, blur

    var id: String { rawValue }
    var title: String { self == .pixelate ? "بكسلة" : "تمويه" }
    var effect: EffectKind { self == .pixelate ? .pixelate : .blur }
}

// MARK: - Music

struct MusicSection: Codable, Hashable {
    var start: Double
    var end: Double
    /// 0…1 relative loudness of the section.
    var energy: Double
}

struct MusicAnalysis: Codable, Hashable {
    var assetID: UUID
    var duration: Double
    var bpm: Double
    /// Source seconds.
    var beats: [Double]
    var downbeats: [Double]
    /// Loudness envelope 0…1 at `energyRate` values per second.
    var energy: [Double]
    var energyRate: Double
    var sections: [MusicSection]
    /// Biggest energy rise (the "drop"), source seconds.
    var dropTime: Double?
}

// MARK: - Editing DNA

struct EditingDNA: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var isBuiltIn: Bool
    var createdAt: Date
    /// Where it came from ("من مشروع …", "من فيديو مرجعي …").
    var origin: String

    /// Seconds.
    var averageShotLength: Double
    /// 0…1 relative variation of shot lengths.
    var shotLengthSpread: Double
    /// 0…1 share of cuts that use a transition.
    var transitionRate: Double
    var transitionKind: TransitionKind?
    var transitionDuration: Double
    var cutsOnBeat: Bool
    /// Look applied to every clip (nil = keep colors).
    var color: ColorAdjustments?
    var lut: LUTReference?
    /// Small JPEG of a reference frame — clips are color-matched to it.
    var referenceFrame: Data?
    var captionStyle: TextStyle?
    var captionHighlight: CaptionHighlight?
    var captionHighlightColor: RGBAColor?
    var titleStyle: TextStyle?
    /// Gentle zoom on still images.
    var stillMotion: Bool
    var musicVolume: Double?
    var aspect: AspectRatio?

    init(id: UUID = UUID(), name: String, symbol: String = "dna", isBuiltIn: Bool = false, origin: String = "",
         averageShotLength: Double = 3, shotLengthSpread: Double = 0.25, transitionRate: Double = 0,
         transitionKind: TransitionKind? = nil, transitionDuration: Double = 0.5, cutsOnBeat: Bool = false,
         stillMotion: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
        self.createdAt = Date()
        self.origin = origin
        self.averageShotLength = averageShotLength
        self.shotLengthSpread = shotLengthSpread
        self.transitionRate = transitionRate
        self.transitionKind = transitionKind
        self.transitionDuration = transitionDuration
        self.cutsOnBeat = cutsOnBeat
        self.stillMotion = stillMotion
    }

    var summary: String {
        var parts = ["لقطة كل " + Fmt.seconds(averageShotLength, digits: 1)]
        if transitionRate > 0.01, let kind = transitionKind { parts.append(kind.title + " " + Fmt.percent(transitionRate)) }
        if cutsOnBeat { parts.append("على الإيقاع") }
        if color != nil || lut != nil || referenceFrame != nil { parts.append("لون") }
        if captionStyle != nil { parts.append("ترجمة") }
        if stillMotion { parts.append("حركة للصور") }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Templates workspace

struct TemplateSlot: Codable, Hashable, Identifiable {
    var id: UUID { clipID }
    var clipID: UUID
    var index: Int
    var duration: Double
    var acceptsVideo: Bool
    var trackName: String
}

struct StudioTemplate: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var settings: ProjectSettings
    var timeline: Timeline
    var markers: [TimelineMarker]
    var slots: [TemplateSlot]
    var note: String

    var duration: Double { timeline.duration.seconds }
}

// MARK: - Output formats

enum OutputFormat: String, CaseIterable, Identifiable, Hashable {
    case vertical, landscape, square, portrait

    var id: String { rawValue }

    var aspect: AspectRatio {
        switch self {
        case .vertical: .portrait9x16
        case .landscape: .landscape16x9
        case .square: .square
        case .portrait: .portrait4x5
        }
    }

    var title: String {
        switch self {
        case .vertical: "طولي 9:16"
        case .landscape: "عرضي 16:9"
        case .square: "مربع 1:1"
        case .portrait: "منشور 4:5"
        }
    }

    var subtitle: String {
        switch self {
        case .vertical: "ريلز • تيك توك • شورتس • ستوري"
        case .landscape: "يوتيوب • التلفاز"
        case .square: "منشورات"
        case .portrait: "منشورات إنستقرام"
        }
    }

    var symbol: String {
        switch self {
        case .vertical: "rectangle.portrait"
        case .landscape: "rectangle"
        case .square: "square"
        case .portrait: "rectangle.portrait.on.rectangle.portrait"
        }
    }
}

enum ReframeMethod: String, CaseIterable, Identifiable, Hashable {
    /// Crop that follows the subject (Vision).
    case smart
    /// Centered crop that fills the frame.
    case center
    /// Whole picture over a blurred copy of itself.
    case fitBlur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "تتبع العنصر (ذكي)"
        case .center: "قص من الوسط"
        case .fitBlur: "الصورة كاملة بخلفية ضبابية"
        }
    }
}

// MARK: - Helpers

extension ClipSource {
    /// Media / image / freeze frame — sources that carry a picture to grade or track.
    var isPicture: Bool {
        switch self {
        case .media, .image, .freezeFrame: true
        default: false
        }
    }
}
