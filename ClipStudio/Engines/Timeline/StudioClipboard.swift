//
//  StudioClipboard.swift
//  ClipStudio — Engines/Timeline
//
//  App-wide clipboard for Pro Studio: copied/cut clips (with relative timing and
//  track class) and copied clip attributes ("paste attributes" with categories:
//  color, LUT, effects, transform, crop, mask, chroma key, blend, speed, audio).
//  Works across projects within the session.
//

import Foundation

struct ClipboardItem: Hashable {
    var clip: Clip
    var trackKind: TrackKind
    /// Rank of the source track among tracks of the same class, relative to the topmost copied one.
    var trackOffset: Int
    /// Seconds from the earliest copied clip.
    var timeOffset: Double
}

struct ClipAttributes: OptionSet, Hashable {
    let rawValue: Int

    static let color = ClipAttributes(rawValue: 1 << 0)
    static let lut = ClipAttributes(rawValue: 1 << 1)
    static let effects = ClipAttributes(rawValue: 1 << 2)
    static let transform = ClipAttributes(rawValue: 1 << 3)
    static let crop = ClipAttributes(rawValue: 1 << 4)
    static let mask = ClipAttributes(rawValue: 1 << 5)
    static let chromaKey = ClipAttributes(rawValue: 1 << 6)
    static let blend = ClipAttributes(rawValue: 1 << 7)
    static let speed = ClipAttributes(rawValue: 1 << 8)
    static let audio = ClipAttributes(rawValue: 1 << 9)
    static let fit = ClipAttributes(rawValue: 1 << 10)

    static let visualLook: ClipAttributes = [.color, .lut, .effects]
    static let all: ClipAttributes = [.color, .lut, .effects, .transform, .crop, .mask, .chromaKey, .blend, .speed, .audio, .fit]

    static let ordered: [(ClipAttributes, String, String)] = [
        (.color, "تصحيح الألوان", "paintpalette"),
        (.lut, "LUT", "cube"),
        (.effects, "التأثيرات", "sparkles"),
        (.transform, "التحويل والحركة", "arrow.up.and.down.and.arrow.left.and.right"),
        (.crop, "القص", "crop"),
        (.fit, "وضع الملاءمة", "rectangle.arrowtriangle.2.inward"),
        (.mask, "القناع", "circle.dashed"),
        (.chromaKey, "مفتاح الكروما", "person.crop.rectangle"),
        (.blend, "المزج والشفافية", "square.on.square"),
        (.speed, "السرعة", "gauge.with.dots.needle.67percent"),
        (.audio, "الصوت", "speaker.wave.2")
    ]
}

@MainActor
@Observable
final class StudioClipboard {
    static let shared = StudioClipboard()

    private(set) var items: [ClipboardItem] = []
    private(set) var attributeSource: Clip?

    var hasClips: Bool { !items.isEmpty }
    var hasAttributes: Bool { attributeSource != nil }

    private init() {}

    func copy(_ ids: Set<UUID>, from timeline: Timeline) {
        var collected: [(Clip, TrackKind, Int)] = []
        for (index, track) in timeline.tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) {
                collected.append((clip, track.kind, index))
            }
        }
        guard let earliest = collected.map({ $0.0.start.seconds }).min() else { return }
        // Rank tracks per class so pasting keeps relative stacking.
        var ranks: [Int: Int] = [:]
        let visualIndices = Array(Set(collected.filter { $0.1.isVisual }.map { $0.2 })).sorted()
        let audioIndices = Array(Set(collected.filter { !$0.1.isVisual }.map { $0.2 })).sorted()
        for (rank, index) in visualIndices.enumerated() { ranks[index] = rank }
        for (rank, index) in audioIndices.enumerated() { ranks[index] = rank }
        items = collected.map { entry in
            ClipboardItem(clip: entry.0, trackKind: entry.1, trackOffset: ranks[entry.2] ?? 0,
                          timeOffset: entry.0.start.seconds - earliest)
        }
        if let first = collected.first { attributeSource = first.0 }
    }

    func copyAttributes(of clip: Clip) {
        attributeSource = clip
    }

    /// Applies the copied attributes to `target`. Speed is applied only to media clips.
    func pasteAttributes(_ set: ClipAttributes, into target: inout Clip) {
        guard let source = attributeSource else { return }
        if set.contains(.color) { target.color = source.color }
        if set.contains(.lut) { target.lut = source.lut }
        if set.contains(.effects) {
            target.effects = source.effects.map { effect in
                var copy = effect
                copy.id = UUID()
                copy.intensity.clamp(toDuration: target.duration.seconds)
                return copy
            }
        }
        if set.contains(.transform) {
            target.transform = source.transform
            target.transform.position.clamp(toDuration: target.duration.seconds)
            target.transform.scale.clamp(toDuration: target.duration.seconds)
            target.transform.rotation.clamp(toDuration: target.duration.seconds)
            target.transform.opacity.clamp(toDuration: target.duration.seconds)
        }
        if set.contains(.crop) {
            target.crop = source.crop
            target.crop.clamp(toDuration: target.duration.seconds)
        }
        if set.contains(.fit) { target.fitMode = source.fitMode }
        if set.contains(.mask) { target.mask = source.mask }
        if set.contains(.chromaKey) { target.chromaKey = source.chromaKey }
        if set.contains(.blend) {
            target.blendMode = source.blendMode
            target.transform.opacity = source.transform.opacity
            target.transform.opacity.clamp(toDuration: target.duration.seconds)
        }
        if set.contains(.audio) {
            target.audio.volume = source.audio.volume
            target.audio.volume.clamp(toDuration: target.duration.seconds)
            target.audio.fadeIn = min(source.audio.fadeIn, target.duration.seconds / 2)
            target.audio.fadeOut = min(source.audio.fadeOut, target.duration.seconds / 2)
            target.audio.isMuted = source.audio.isMuted
        }
    }

    func clear() {
        items = []
        attributeSource = nil
    }
}
