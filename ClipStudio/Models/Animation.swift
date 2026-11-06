//
//  Animation.swift
//  ClipStudio — Models
//
//  Keyframe animation primitives used by transforms, crop, opacity, volume,
//  effect intensity and (later parts) masks and captions. Part 3 adds the
//  non-uniform stretch / aspect lock of ClipTransform (old files decode unchanged).
//  Keyframe times are clip-local seconds (0 = clip start on the timeline).
//

import Foundation

enum Easing: String, Codable, CaseIterable, Hashable {
    case linear, easeIn, easeOut, easeInOut, hold

    var title: String {
        switch self {
        case .linear: "خطي"
        case .easeIn: "تسارع"
        case .easeOut: "تباطؤ"
        case .easeInOut: "ناعم"
        case .hold: "ثبات"
        }
    }

    func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .hold: return 0
        }
    }
}

struct Keyframe<V: Interpolatable>: Codable, Hashable, Identifiable {
    var id: UUID
    var time: Double
    var value: V
    var easing: Easing

    init(id: UUID = UUID(), time: Double, value: V, easing: Easing = .easeInOut) {
        self.id = id
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// A value that is either static (`base`) or animated by keyframes.
/// Keyframes are always kept sorted by time.
struct KeyframedValue<V: Interpolatable>: Codable, Hashable {
    var base: V
    var keyframes: [Keyframe<V>]

    init(_ base: V, keyframes: [Keyframe<V>] = []) {
        self.base = base
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    var isAnimated: Bool { !keyframes.isEmpty }

    func value(at time: Double) -> V {
        guard let first = keyframes.first, let last = keyframes.last else { return base }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 0..<(keyframes.count - 1) {
            let a = keyframes[index]
            let b = keyframes[index + 1]
            guard time >= a.time && time <= b.time else { continue }
            let span = b.time - a.time
            if span <= 0 { return b.value }
            if a.easing == .hold { return a.value }
            return V.interpolate(a.value, b.value, a.easing.apply((time - a.time) / span))
        }
        return last.value
    }

    /// Sets the value. When animated, writes/updates a keyframe at `time`; otherwise changes `base`.
    mutating func set(_ newValue: V, at time: Double?, tolerance: Double = 1.0 / 120) {
        guard isAnimated, let time else {
            base = newValue
            return
        }
        addKeyframe(at: time, value: newValue, tolerance: tolerance)
    }

    mutating func addKeyframe(at time: Double, value: V, easing: Easing = .easeInOut, tolerance: Double = 1.0 / 120) {
        if let index = keyframes.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            keyframes[index].value = value
            keyframes[index].easing = easing
        } else {
            keyframes.append(Keyframe(time: max(0, time), value: value, easing: easing))
            keyframes.sort { $0.time < $1.time }
        }
    }

    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    mutating func removeAllKeyframes(keeping time: Double) {
        base = value(at: time)
        keyframes.removeAll()
    }

    /// Shifts/scales keyframe times when a clip is trimmed or its speed changes.
    mutating func remapTimes(_ transform: (Double) -> Double) {
        for index in keyframes.indices { keyframes[index].time = transform(keyframes[index].time) }
        keyframes.sort { $0.time < $1.time }
    }
}

struct ClipTransform: Codable, Hashable {
    /// Normalized canvas position of the clip center (0.5, 0.5 = canvas center, top-left origin).
    var position: KeyframedValue<Vec2>
    /// 1.0 = size produced by the clip's fit mode.
    var scale: KeyframedValue<Double>
    /// Degrees, clockwise.
    var rotation: KeyframedValue<Double>
    var opacity: KeyframedValue<Double>
    /// Pivot for scale/rotation in normalized clip space (0.5, 0.5 = clip center).
    var anchor: Vec2
    var flipHorizontal: Bool
    var flipVertical: Bool
    /// Non-uniform width/height factors on top of `scale` (1, 1 = original proportions).
    var stretch: Vec2
    /// When true the canvas handles keep the layer's proportions; when false the
    /// edge handles stretch width and height independently.
    var aspectLocked: Bool

    init(position: KeyframedValue<Vec2> = KeyframedValue(Vec2.center),
         scale: KeyframedValue<Double> = KeyframedValue(1.0),
         rotation: KeyframedValue<Double> = KeyframedValue(0.0),
         opacity: KeyframedValue<Double> = KeyframedValue(1.0),
         anchor: Vec2 = .center, flipHorizontal: Bool = false, flipVertical: Bool = false,
         stretch: Vec2 = .one, aspectLocked: Bool = true) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.anchor = anchor
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.stretch = stretch
        self.aspectLocked = aspectLocked
    }

    static let identity = ClipTransform()

    var isIdentity: Bool { self == .identity }

    var isStretched: Bool { abs(stretch.x - 1) > 0.0001 || abs(stretch.y - 1) > 0.0001 }

    static let stretchRange: ClosedRange<Double> = 0.1...5

    enum CodingKeys: String, CodingKey {
        case position, scale, rotation, opacity, anchor, flipHorizontal, flipVertical, stretch, aspectLocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(position: c.value(.position, default: KeyframedValue(Vec2.center)),
                  scale: c.value(.scale, default: KeyframedValue(1.0)),
                  rotation: c.value(.rotation, default: KeyframedValue(0.0)),
                  opacity: c.value(.opacity, default: KeyframedValue(1.0)),
                  anchor: c.value(.anchor, default: Vec2.center),
                  flipHorizontal: c.value(.flipHorizontal, default: false),
                  flipVertical: c.value(.flipVertical, default: false),
                  stretch: c.value(.stretch, default: Vec2.one),
                  aspectLocked: c.value(.aspectLocked, default: true))
    }
}
