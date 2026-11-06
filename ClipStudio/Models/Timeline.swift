//
//  Timeline.swift
//  ClipStudio — Models
//
//  The multi-track timeline data model shared by Smart Stories, the merger,
//  export jobs and (Part 2) Pro Studio. Tracks are ordered bottom → top:
//  index 0 is drawn first (lowest layer). Part 3 adds track color, solo, balance
//  and the per-clip Audio Studio settings; Part 4 adds clip stabilization and
//  horizon leveling (old files decode unchanged).
//

import Foundation
import CoreMedia

// MARK: - Track

enum TrackKind: String, Codable, CaseIterable, Hashable {
    case video, overlay, audio, text, adjustment, subtitle

    var isVisual: Bool { self != .audio }

    var title: String {
        switch self {
        case .video: "فيديو"
        case .overlay: "طبقة علوية"
        case .audio: "صوت"
        case .text: "نص"
        case .adjustment: "طبقة تعديل"
        case .subtitle: "ترجمة"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .overlay: "square.on.square"
        case .audio: "waveform"
        case .text: "textformat"
        case .adjustment: "slider.horizontal.3"
        case .subtitle: "captions.bubble"
        }
    }
}

struct Track: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: TrackKind
    var name: String
    var isLocked: Bool
    var isHidden: Bool
    var isMuted: Bool
    /// 0…1 track gain.
    var volume: Double
    /// −1 (left) … +1 (right) balance, applied by the Audio Studio processor (Part 3).
    var pan: Double
    /// When any track is soloed, only soloed tracks are heard.
    var isSolo: Bool
    /// Organizational color shown on the track header and its clips.
    var color: RGBAColor?
    var clips: [Clip]

    init(id: UUID = UUID(), kind: TrackKind, name: String? = nil, clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.isLocked = false
        self.isHidden = false
        self.isMuted = false
        self.volume = 1
        self.pan = 0
        self.isSolo = false
        self.color = nil
        self.clips = clips
    }

    var endTime: TimeValue { clips.map(\.end).max() ?? .zero }

    /// Tracks whose clips can carry sound.
    var carriesAudio: Bool { kind == .audio || kind == .video || kind == .overlay }

    enum CodingKeys: String, CodingKey { case id, kind, name, isLocked, isHidden, isMuted, volume, pan, isSolo, color, clips }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, default: TrackKind.video)
        name = c.value(.name, default: kind.title)
        isLocked = c.value(.isLocked, default: false)
        isHidden = c.value(.isHidden, default: false)
        isMuted = c.value(.isMuted, default: false)
        volume = c.value(.volume, default: 1.0)
        pan = c.value(.pan, default: 0.0)
        isSolo = c.value(.isSolo, default: false)
        color = try? c.decodeIfPresent(RGBAColor.self, forKey: .color)
        clips = c.value(.clips, default: [Clip]())
    }
}

// MARK: - Clip source

enum ClipSource: Codable, Hashable {
    /// Video or audio file from the media library.
    case media(UUID)
    /// Still image from the media library.
    case image(UUID)
    /// A single frame of a video held for the clip's duration.
    case freezeFrame(assetID: UUID, time: TimeValue)
    case text(TextContent)
    case shape(ShapeContent)
    case sticker(StickerContent)
    case solidColor(RGBAColor)
    /// Applies the clip's color/effects to everything below it.
    case adjustment

    var title: String {
        switch self {
        case .media: "مقطع"
        case .image: "صورة"
        case .freezeFrame: "إطار ثابت"
        case .text: "نص"
        case .shape: "شكل"
        case .sticker: "ملصق"
        case .solidColor: "لون"
        case .adjustment: "تعديل"
        }
    }

    var assetIDs: [UUID] {
        switch self {
        case .media(let id), .image(let id): [id]
        case .freezeFrame(let id, _): [id]
        default: []
        }
    }
}

// MARK: - Speed

struct SpeedRampPoint: Codable, Hashable {
    /// 0…1 position within the clip's source range.
    var position: Double
    var rate: Double
}

struct SpeedSegment {
    let range: CMTimeRange
    let rate: Double
}

struct SpeedSettings: Codable, Hashable {
    var rate: Double = 1
    /// When non-empty, overrides `rate` with a piecewise-linear speed curve.
    var ramp: [SpeedRampPoint] = []
    var isReversed = false
    /// Media asset holding the reversed render of the source (created by the reverse engine).
    var reversedAssetID: UUID? = nil
    var preservePitch = true

    static let normal = SpeedSettings()
    static let minimumRate = 0.05
    static let rampSteps = 12

    var isNormal: Bool { abs(rate - 1) < 0.0001 && ramp.isEmpty && !isReversed }

    func rate(atPosition position: Double) -> Double {
        guard !ramp.isEmpty else { return rate }
        let points = ramp.sorted { $0.position < $1.position }
        guard let first = points.first, let last = points.last else { return rate }
        if position <= first.position { return first.rate }
        if position >= last.position { return last.rate }
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            if position >= a.position && position <= b.position {
                let span = b.position - a.position
                return span <= 0 ? b.rate : a.rate + (b.rate - a.rate) * (position - a.position) / span
            }
        }
        return last.rate
    }

    /// Splits a source range into constant-speed pieces that AVFoundation can scale.
    func segments(for source: CMTimeRange) -> [SpeedSegment] {
        guard !ramp.isEmpty else {
            return [SpeedSegment(range: source, rate: max(SpeedSettings.minimumRate, rate))]
        }
        let steps = SpeedSettings.rampSteps
        var result: [SpeedSegment] = []
        for step in 0..<steps {
            let p0 = Double(step) / Double(steps)
            let p1 = Double(step + 1) / Double(steps)
            let s0 = CMTimeAdd(source.start, CMTimeMultiplyByFloat64(source.duration, multiplier: p0))
            let s1 = CMTimeAdd(source.start, CMTimeMultiplyByFloat64(source.duration, multiplier: p1))
            let r = max(SpeedSettings.minimumRate, (rate(atPosition: p0) + rate(atPosition: p1)) / 2)
            result.append(SpeedSegment(range: CMTimeRange(start: s0, end: s1), rate: r))
        }
        return result
    }

    func timelineDuration(forSource sourceDuration: TimeValue) -> TimeValue {
        let pieces = segments(for: CMTimeRange(start: .zero, duration: sourceDuration.cm))
        let seconds = pieces.reduce(0.0) { $0 + $1.range.duration.seconds / $1.rate }
        return TimeValue(seconds: seconds)
    }
}

// MARK: - Fit, audio

enum FitMode: String, Codable, CaseIterable, Hashable {
    case fit, fill, stretch, fitBlur

    var title: String {
        switch self {
        case .fit: "احتواء"
        case .fill: "ملء (قص)"
        case .stretch: "تمديد"
        case .fitBlur: "احتواء بخلفية ضبابية"
        }
    }

    var symbol: String {
        switch self {
        case .fit: "rectangle.arrowtriangle.2.inward"
        case .fill: "rectangle.arrowtriangle.2.outward"
        case .stretch: "arrow.up.left.and.arrow.down.right"
        case .fitBlur: "rectangle.on.rectangle"
        }
    }
}

struct ClipAudio: Codable, Hashable {
    /// 0…1, keyframable volume automation.
    var volume = KeyframedValue(1.0)
    /// Seconds.
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var isMuted = false
    /// Audio Studio processing chain (Part 3).
    var effects = AudioEffects()

    enum CodingKeys: String, CodingKey { case volume, fadeIn, fadeOut, isMuted, effects }
}

extension ClipAudio {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        volume = c.value(.volume, default: KeyframedValue(1.0))
        fadeIn = c.value(.fadeIn, default: 0.0)
        fadeOut = c.value(.fadeOut, default: 0.0)
        isMuted = c.value(.isMuted, default: false)
        effects = c.value(.effects, default: AudioEffects())
    }
}

struct TimelineMarker: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: TimeValue
    var name: String
    var color = RGBAColor(hex: 0xE3B04B)
}

// MARK: - Clip

struct Clip: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var source: ClipSource
    /// Position on the timeline.
    var start: TimeValue
    /// Duration on the timeline (after speed changes).
    var duration: TimeValue
    /// Range inside the source media (media / audio clips only).
    var sourceRange: TimeRangeValue?
    var speed: SpeedSettings
    var transform: ClipTransform
    /// Normalized crop rectangle (top-left origin), keyframable for reframing.
    var crop: KeyframedValue<RectValue>
    var fitMode: FitMode
    var color: ColorAdjustments
    var lut: LUTReference?
    var effects: [EffectInstance]
    var mask: MaskSettings?
    var chromaKey: ChromaKeySettings?
    var blendMode: BlendMode
    /// Transition from the previous clip on the same track (clips overlap by its duration).
    var transitionIn: TransitionInstance?
    var audio: ClipAudio
    var isEnabled: Bool
    var label: RGBAColor?
    /// Video stabilization (Part 4). nil = off.
    var stabilization: StabilizationSettings?
    /// Horizon leveling (Part 4). nil = off.
    var horizon: HorizonSettings?

    init(id: UUID = UUID(), name: String, source: ClipSource, start: TimeValue, duration: TimeValue,
         sourceRange: TimeRangeValue? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.start = start
        self.duration = duration
        self.sourceRange = sourceRange
        self.speed = .normal
        self.transform = .identity
        self.crop = KeyframedValue(RectValue.full)
        self.fitMode = .fit
        self.color = .neutral
        self.lut = nil
        self.effects = []
        self.mask = nil
        self.chromaKey = nil
        self.blendMode = .normal
        self.transitionIn = nil
        self.audio = ClipAudio()
        self.isEnabled = true
        self.label = nil
    }

    var end: TimeValue { start + duration }
    var range: TimeRangeValue { TimeRangeValue(start: start, duration: duration) }

    var mediaAssetID: UUID? {
        if case .media(let id) = source { return id }
        return nil
    }

    var referencedAssetIDs: [UUID] {
        var ids = source.assetIDs
        if let reversed = speed.reversedAssetID { ids.append(reversed) }
        return ids
    }

    /// Keeps `duration` consistent with `sourceRange` and the speed settings.
    mutating func recomputeDurationFromSpeed() {
        guard let sourceRange else { return }
        duration = speed.timelineDuration(forSource: sourceRange.duration)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, source, start, duration, sourceRange, speed, transform, crop, fitMode
        case color, lut, effects, mask, chromaKey, blendMode, transitionIn, audio, isEnabled, label, stabilization, horizon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(ClipSource.self, forKey: .source)
        name = c.value(.name, default: source.title)
        start = c.value(.start, default: TimeValue.zero)
        duration = c.value(.duration, default: TimeValue(seconds: 3))
        sourceRange = try? c.decodeIfPresent(TimeRangeValue.self, forKey: .sourceRange)
        speed = c.value(.speed, default: SpeedSettings.normal)
        transform = c.value(.transform, default: ClipTransform.identity)
        crop = c.value(.crop, default: KeyframedValue(RectValue.full))
        fitMode = c.value(.fitMode, default: FitMode.fit)
        color = c.value(.color, default: ColorAdjustments.neutral)
        lut = try? c.decodeIfPresent(LUTReference.self, forKey: .lut)
        effects = c.value(.effects, default: [EffectInstance]())
        mask = try? c.decodeIfPresent(MaskSettings.self, forKey: .mask)
        chromaKey = try? c.decodeIfPresent(ChromaKeySettings.self, forKey: .chromaKey)
        blendMode = c.value(.blendMode, default: BlendMode.normal)
        transitionIn = try? c.decodeIfPresent(TransitionInstance.self, forKey: .transitionIn)
        audio = c.value(.audio, default: ClipAudio())
        isEnabled = c.value(.isEnabled, default: true)
        label = try? c.decodeIfPresent(RGBAColor.self, forKey: .label)
        stabilization = try? c.decodeIfPresent(StabilizationSettings.self, forKey: .stabilization)
        horizon = try? c.decodeIfPresent(HorizonSettings.self, forKey: .horizon)
    }
}

// MARK: - Timeline

struct Timeline: Codable, Hashable {
    var tracks: [Track]

    init(tracks: [Track] = []) {
        self.tracks = tracks
    }

    static func standard() -> Timeline {
        Timeline(tracks: [Track(kind: .video, name: "فيديو 1"), Track(kind: .audio, name: "صوت 1")])
    }

    var duration: TimeValue { tracks.map(\.endTime).max() ?? .zero }
    var clipCount: Int { tracks.reduce(0) { $0 + $1.clips.count } }
    var isEmpty: Bool { clipCount == 0 }

    var referencedAssetIDs: Set<UUID> {
        Set(tracks.flatMap { $0.clips.flatMap(\.referencedAssetIDs) })
    }
}
