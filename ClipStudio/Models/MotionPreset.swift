//
//  MotionPreset.swift
//  ClipStudio — Models
//
//  Reusable motion: transform keyframes (scale, rotation, opacity, position) stored
//  relative to the clip they are applied to, with times anchored to the clip start,
//  the clip end, or a fraction of its length — so the same preset works on clips of
//  any duration, size and position. Built-in presets (Ken Burns, pans, fades, pop…)
//  plus presets saved from the user's own animated clips.
//

import Foundation

enum MotionAnchor: String, Codable, Hashable {
    /// Seconds after the clip start.
    case fromStart
    /// Seconds before the clip end.
    case fromEnd
    /// 0…1 fraction of the clip length.
    case fraction
}

struct MotionKey<V: Codable & Hashable>: Codable, Hashable {
    var anchor: MotionAnchor
    var time: Double
    var value: V
    var easing: Easing = .easeInOut

    func resolvedTime(duration: Double) -> Double {
        switch anchor {
        case .fromStart: time
        case .fromEnd: duration - time
        case .fraction: duration * time
        }
    }
}

struct MotionPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var isBuiltIn: Bool
    /// Multipliers of the clip's own scale.
    var scale: [MotionKey<Double>]
    /// Degrees added to the clip's rotation.
    var rotation: [MotionKey<Double>]
    /// Absolute opacity factors (multiplied with the clip's opacity).
    var opacity: [MotionKey<Double>]
    /// Normalized canvas offsets added to the clip's position.
    var position: [MotionKey<Vec2>]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbol: String, isBuiltIn: Bool = false,
         scale: [MotionKey<Double>] = [], rotation: [MotionKey<Double>] = [],
         opacity: [MotionKey<Double>] = [], position: [MotionKey<Vec2>] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.position = position
        self.createdAt = Date()
    }

    var isEmpty: Bool { scale.isEmpty && rotation.isEmpty && opacity.isEmpty && position.isEmpty }

    var propertySummary: String {
        var parts: [String] = []
        if !position.isEmpty { parts.append("الموضع") }
        if !scale.isEmpty { parts.append("الحجم") }
        if !rotation.isEmpty { parts.append("الدوران") }
        if !opacity.isEmpty { parts.append("الشفافية") }
        return parts.joined(separator: " • ")
    }

    // MARK: Apply

    /// Writes the preset's keyframes into the clip (replacing keyframes of the
    /// properties the preset animates; other properties are kept).
    func apply(to clip: inout Clip, frame: Double) {
        let duration = clip.duration.seconds
        guard duration > 0 else { return }
        let last = max(0, duration - frame)
        func time(_ raw: Double) -> Double { min(max(0, raw), last) }

        if !scale.isEmpty {
            let base = clip.transform.scale.value(at: 0)
            let keys = scale.map { Keyframe(time: time($0.resolvedTime(duration: duration)),
                                            value: max(0.02, base * $0.value), easing: $0.easing) }
            clip.transform.scale = KeyframedValue(base, keyframes: Self.deduplicated(keys))
        }
        if !rotation.isEmpty {
            let base = clip.transform.rotation.value(at: 0)
            let keys = rotation.map { Keyframe(time: time($0.resolvedTime(duration: duration)),
                                               value: base + $0.value, easing: $0.easing) }
            clip.transform.rotation = KeyframedValue(base, keyframes: Self.deduplicated(keys))
        }
        if !opacity.isEmpty {
            let base = clip.transform.opacity.keyframes.isEmpty ? clip.transform.opacity.base : 1
            let keys = opacity.map { Keyframe(time: time($0.resolvedTime(duration: duration)),
                                              value: min(1, max(0, base * $0.value)), easing: $0.easing) }
            clip.transform.opacity = KeyframedValue(base, keyframes: Self.deduplicated(keys))
        }
        if !position.isEmpty {
            let base = clip.transform.position.value(at: 0)
            let keys = position.map { Keyframe(time: time($0.resolvedTime(duration: duration)),
                                               value: Vec2(x: base.x + $0.value.x, y: base.y + $0.value.y), easing: $0.easing) }
            clip.transform.position = KeyframedValue(base, keyframes: Self.deduplicated(keys))
        }
    }

    /// Keeps the last keyframe when two land on the same time (very short clips).
    private static func deduplicated<V>(_ keys: [Keyframe<V>]) -> [Keyframe<V>] {
        var result: [Keyframe<V>] = []
        for key in keys.sorted(by: { $0.time < $1.time }) {
            if let last = result.last, abs(last.time - key.time) < 0.0005 {
                result[result.count - 1] = key
            } else {
                result.append(key)
            }
        }
        return result
    }

    // MARK: Capture

    /// A preset made from a clip's transform animation (times as fractions of its length,
    /// values relative to the first keyframe). Returns nil when the clip is not animated.
    static func capture(from clip: Clip, name: String) -> MotionPreset? {
        let duration = clip.duration.seconds
        guard duration > 0 else { return nil }
        let t = clip.transform
        func fraction(_ time: Double) -> Double { min(1, max(0, time / duration)) }

        var preset = MotionPreset(name: name, symbol: "wand.and.rays")
        if let first = t.scale.keyframes.first {
            let reference = max(0.02, first.value)
            preset.scale = t.scale.keyframes.map { MotionKey(anchor: .fraction, time: fraction($0.time), value: $0.value / reference, easing: $0.easing) }
        }
        if let first = t.rotation.keyframes.first {
            preset.rotation = t.rotation.keyframes.map { MotionKey(anchor: .fraction, time: fraction($0.time), value: $0.value - first.value, easing: $0.easing) }
        }
        if !t.opacity.keyframes.isEmpty {
            preset.opacity = t.opacity.keyframes.map { MotionKey(anchor: .fraction, time: fraction($0.time), value: $0.value, easing: $0.easing) }
        }
        if let first = t.position.keyframes.first {
            preset.position = t.position.keyframes.map {
                MotionKey(anchor: .fraction, time: fraction($0.time),
                          value: Vec2(x: $0.value.x - first.value.x, y: $0.value.y - first.value.y), easing: $0.easing)
            }
        }
        return preset.isEmpty ? nil : preset
    }

    // MARK: Built-in

    private static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "6D0710A0-0000-4000-8000-%012ld", index)) ?? UUID()
    }

    static let builtIns: [MotionPreset] = [
        MotionPreset(id: builtInID(1), name: "تقريب بطيء (كين بيرنز)", symbol: "plus.magnifyingglass", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.0, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.2, easing: .linear)]),
        MotionPreset(id: builtInID(2), name: "إبعاد بطيء", symbol: "minus.magnifyingglass", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.2, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.0, easing: .linear)]),
        MotionPreset(id: builtInID(3), name: "تحريك لليمين", symbol: "arrow.right.circle", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.15, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.15, easing: .linear)],
                     position: [MotionKey(anchor: .fraction, time: 0, value: Vec2(x: -0.05, y: 0), easing: .linear),
                                MotionKey(anchor: .fraction, time: 1, value: Vec2(x: 0.05, y: 0), easing: .linear)]),
        MotionPreset(id: builtInID(4), name: "تحريك لليسار", symbol: "arrow.left.circle", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.15, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.15, easing: .linear)],
                     position: [MotionKey(anchor: .fraction, time: 0, value: Vec2(x: 0.05, y: 0), easing: .linear),
                                MotionKey(anchor: .fraction, time: 1, value: Vec2(x: -0.05, y: 0), easing: .linear)]),
        MotionPreset(id: builtInID(5), name: "صعود هادئ", symbol: "arrow.up.circle", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.12, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.12, easing: .linear)],
                     position: [MotionKey(anchor: .fraction, time: 0, value: Vec2(x: 0, y: 0.035), easing: .linear),
                                MotionKey(anchor: .fraction, time: 1, value: Vec2(x: 0, y: -0.035), easing: .linear)]),
        MotionPreset(id: builtInID(6), name: "ظهور تدريجي", symbol: "circle.lefthalf.filled", isBuiltIn: true,
                     opacity: [MotionKey(anchor: .fromStart, time: 0, value: 0, easing: .easeOut),
                               MotionKey(anchor: .fromStart, time: 0.6, value: 1, easing: .linear)]),
        MotionPreset(id: builtInID(7), name: "اختفاء تدريجي", symbol: "circle.righthalf.filled", isBuiltIn: true,
                     opacity: [MotionKey(anchor: .fromEnd, time: 0.6, value: 1, easing: .easeIn),
                               MotionKey(anchor: .fromEnd, time: 0, value: 0, easing: .linear)]),
        MotionPreset(id: builtInID(8), name: "ظهور واختفاء", symbol: "circle.dotted", isBuiltIn: true,
                     opacity: [MotionKey(anchor: .fromStart, time: 0, value: 0, easing: .easeOut),
                               MotionKey(anchor: .fromStart, time: 0.5, value: 1, easing: .linear),
                               MotionKey(anchor: .fromEnd, time: 0.5, value: 1, easing: .easeIn),
                               MotionKey(anchor: .fromEnd, time: 0, value: 0, easing: .linear)]),
        MotionPreset(id: builtInID(9), name: "قفزة دخول", symbol: "sparkle", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fromStart, time: 0, value: 0.6, easing: .easeOut),
                             MotionKey(anchor: .fromStart, time: 0.22, value: 1.08, easing: .easeInOut),
                             MotionKey(anchor: .fromStart, time: 0.38, value: 1.0, easing: .linear)],
                     opacity: [MotionKey(anchor: .fromStart, time: 0, value: 0, easing: .easeOut),
                               MotionKey(anchor: .fromStart, time: 0.15, value: 1, easing: .linear)]),
        MotionPreset(id: builtInID(10), name: "دوران دخول", symbol: "arrow.triangle.2.circlepath", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fromStart, time: 0, value: 0.4, easing: .easeOut),
                             MotionKey(anchor: .fromStart, time: 0.5, value: 1, easing: .linear)],
                     rotation: [MotionKey(anchor: .fromStart, time: 0, value: -120, easing: .easeOut),
                                MotionKey(anchor: .fromStart, time: 0.5, value: 0, easing: .linear)],
                     opacity: [MotionKey(anchor: .fromStart, time: 0, value: 0, easing: .easeOut),
                               MotionKey(anchor: .fromStart, time: 0.3, value: 1, easing: .linear)]),
        MotionPreset(id: builtInID(11), name: "دخول من اليسار", symbol: "arrow.right.to.line", isBuiltIn: true,
                     position: [MotionKey(anchor: .fromStart, time: 0, value: Vec2(x: -1, y: 0), easing: .easeOut),
                                MotionKey(anchor: .fromStart, time: 0.5, value: Vec2(x: 0, y: 0), easing: .linear)]),
        MotionPreset(id: builtInID(12), name: "خروج لليمين", symbol: "arrow.right.to.line.compact", isBuiltIn: true,
                     position: [MotionKey(anchor: .fromEnd, time: 0.5, value: Vec2(x: 0, y: 0), easing: .easeIn),
                                MotionKey(anchor: .fromEnd, time: 0, value: Vec2(x: 1, y: 0), easing: .linear)]),
        MotionPreset(id: builtInID(13), name: "كاميرا محمولة", symbol: "camera.metering.unknown", isBuiltIn: true,
                     scale: [MotionKey(anchor: .fraction, time: 0, value: 1.08, easing: .linear),
                             MotionKey(anchor: .fraction, time: 1, value: 1.08, easing: .linear)],
                     position: MotionPreset.handheldPath())
    ]

    /// A smooth pseudo-random wobble (deterministic so previews and exports match).
    private static func handheldPath() -> [MotionKey<Vec2>] {
        let offsets: [(Double, Double)] = [(0, 0), (0.006, -0.004), (-0.004, 0.005), (0.005, 0.003), (-0.006, -0.003),
                                           (0.003, 0.006), (-0.002, -0.005), (0.005, -0.002), (-0.005, 0.004), (0, 0)]
        return offsets.enumerated().map { index, offset in
            MotionKey(anchor: .fraction, time: Double(index) / Double(offsets.count - 1),
                      value: Vec2(x: offset.0, y: offset.1), easing: .easeInOut)
        }
    }
}
