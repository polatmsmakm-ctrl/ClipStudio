//
//  ClipKeyframes.swift
//  ClipStudio — Engines/Timeline
//
//  Keyframe utilities used by editing operations (split, trim, join, speed) and by
//  the keyframe editor: splitting curves at a time, shifting, merging, and a
//  property-level API (add / remove / retime / easing) for every animatable value.
//  Part 3: caption word timing follows splits, joins and retiming.
//  Part 4: masks that follow a subject (center / size tracks) follow too.
//

import Foundation

// MARK: - KeyframedValue helpers

extension KeyframedValue {
    /// Splits the curve at clip-local time `t`. The left part keeps times ≤ t, the
    /// right part is re-based so `t` becomes 0. Values at the cut are preserved.
    func split(at t: Double) -> (left: KeyframedValue<V>, right: KeyframedValue<V>) {
        guard isAnimated else { return (self, self) }
        let mid = value(at: t)

        var leftKeys = keyframes.filter { $0.time <= t + 1e-9 }
        let hasKeyAtCut = leftKeys.last.map { abs($0.time - t) < 1e-6 } ?? false
        if keyframes.contains(where: { $0.time > t + 1e-9 }) && !hasKeyAtCut {
            leftKeys.append(Keyframe(time: t, value: mid, easing: .linear))
        }

        var rightKeys = keyframes.filter { $0.time >= t - 1e-9 }
            .map { Keyframe(time: max(0, $0.time - t), value: $0.value, easing: $0.easing) }
        let startsAtZero = rightKeys.first.map { $0.time < 1e-6 } ?? false
        if let previous = keyframes.last(where: { $0.time < t - 1e-9 }), !startsAtZero {
            rightKeys.insert(Keyframe(time: 0, value: mid, easing: previous.easing == .hold ? .hold : .linear), at: 0)
        }

        var left = self
        left.keyframes = leftKeys
        if leftKeys.isEmpty { left.base = mid }
        var right = self
        right.keyframes = rightKeys
        if rightKeys.isEmpty { right.base = mid }
        return (left, right)
    }

    /// Joins `other` after this curve; `other`'s times are offset by `offset`.
    func joined(with other: KeyframedValue<V>, offset: Double) -> KeyframedValue<V> {
        if !isAnimated && !other.isAnimated { return self }
        var keys: [Keyframe<V>] = isAnimated ? keyframes : [Keyframe(time: 0, value: base, easing: .linear)]
        let shifted: [Keyframe<V>] = other.isAnimated
            ? other.keyframes.map { Keyframe(time: $0.time + offset, value: $0.value, easing: $0.easing) }
            : [Keyframe(time: offset, value: other.base, easing: .linear)]
        for key in shifted where !keys.contains(where: { abs($0.time - key.time) < 1e-6 }) {
            keys.append(key)
        }
        return KeyframedValue(base, keyframes: keys)
    }

    func keyframe(near time: Double, tolerance: Double) -> Keyframe<V>? {
        keyframes.first { abs($0.time - time) <= tolerance }
    }

    mutating func moveKeyframe(id: UUID, to time: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].time = max(0, time)
        keyframes.sort { $0.time < $1.time }
    }

    mutating func setEasing(id: UUID, _ easing: Easing) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].easing = easing
    }

    /// Drops keyframes outside 0…duration (after trims), keeping the value at the edges.
    mutating func clamp(toDuration duration: Double) {
        guard isAnimated else { return }
        if keyframes.contains(where: { $0.time > duration + 1e-6 }) {
            self = split(at: duration).left
        }
    }
}

// MARK: - Properties

enum KeyframeProperty: String, CaseIterable, Identifiable, Hashable {
    case position, scale, rotation, opacity, crop, volume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .position: "الموضع"
        case .scale: "الحجم"
        case .rotation: "الدوران"
        case .opacity: "الشفافية"
        case .crop: "القص"
        case .volume: "مستوى الصوت"
        }
    }

    var symbol: String {
        switch self {
        case .position: "arrow.up.and.down.and.arrow.left.and.right"
        case .scale: "arrow.up.left.and.arrow.down.right"
        case .rotation: "rotate.right"
        case .opacity: "circle.lefthalf.filled"
        case .crop: "crop"
        case .volume: "speaker.wave.2"
        }
    }
}

/// A keyframe as seen by the editor UI (type-erased).
struct KeyframeMark: Identifiable, Hashable {
    let id: UUID
    let property: KeyframeProperty?
    /// Effect instance id when the keyframe animates an effect's intensity.
    let effectID: UUID?
    let time: Double
    let easing: Easing
}

extension Clip {
    func isAnimated(_ property: KeyframeProperty) -> Bool {
        switch property {
        case .position: transform.position.isAnimated
        case .scale: transform.scale.isAnimated
        case .rotation: transform.rotation.isAnimated
        case .opacity: transform.opacity.isAnimated
        case .crop: crop.isAnimated
        case .volume: audio.volume.isAnimated
        }
    }

    func keyframeMarks(_ property: KeyframeProperty) -> [KeyframeMark] {
        func marks<V>(_ value: KeyframedValue<V>) -> [KeyframeMark] {
            value.keyframes.map { KeyframeMark(id: $0.id, property: property, effectID: nil, time: $0.time, easing: $0.easing) }
        }
        switch property {
        case .position: return marks(transform.position)
        case .scale: return marks(transform.scale)
        case .rotation: return marks(transform.rotation)
        case .opacity: return marks(transform.opacity)
        case .crop: return marks(crop)
        case .volume: return marks(audio.volume)
        }
    }

    func effectKeyframeMarks(_ effectID: UUID) -> [KeyframeMark] {
        guard let effect = effects.first(where: { $0.id == effectID }) else { return [] }
        return effect.intensity.keyframes.map { KeyframeMark(id: $0.id, property: nil, effectID: effectID, time: $0.time, easing: $0.easing) }
    }

    /// Every keyframe time on the clip (for timeline ticks and prev/next navigation).
    var allKeyframeTimes: [Double] {
        var times: [Double] = []
        for property in KeyframeProperty.allCases { times += keyframeMarks(property).map(\.time) }
        for effect in effects { times += effect.intensity.keyframes.map(\.time) }
        return Array(Set(times.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }

    func hasKeyframe(_ property: KeyframeProperty, at time: Double, tolerance: Double) -> Bool {
        keyframeMarks(property).contains { abs($0.time - time) <= tolerance }
    }

    /// Adds a keyframe with the current value at `time`, or removes the keyframe there.
    mutating func toggleKeyframe(_ property: KeyframeProperty, at time: Double, tolerance: Double) {
        let t = max(0, min(time, duration.seconds))
        func toggle<V>(_ value: inout KeyframedValue<V>) {
            if let existing = value.keyframe(near: t, tolerance: tolerance) {
                let held = value.value(at: t)
                value.removeKeyframe(id: existing.id)
                if !value.isAnimated { value.base = held }
            } else {
                value.addKeyframe(at: t, value: value.value(at: t), tolerance: tolerance)
            }
        }
        switch property {
        case .position: toggle(&transform.position)
        case .scale: toggle(&transform.scale)
        case .rotation: toggle(&transform.rotation)
        case .opacity: toggle(&transform.opacity)
        case .crop: toggle(&crop)
        case .volume: toggle(&audio.volume)
        }
    }

    mutating func toggleEffectKeyframe(_ effectID: UUID, at time: Double, tolerance: Double) {
        guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
        let t = max(0, min(time, duration.seconds))
        if let existing = effects[index].intensity.keyframe(near: t, tolerance: tolerance) {
            let held = effects[index].intensity.value(at: t)
            effects[index].intensity.removeKeyframe(id: existing.id)
            if !effects[index].intensity.isAnimated { effects[index].intensity.base = held }
        } else {
            effects[index].intensity.addKeyframe(at: t, value: effects[index].intensity.value(at: t), tolerance: tolerance)
        }
    }

    /// Removes animation from a property, keeping the value shown at `time`.
    mutating func clearKeyframes(_ property: KeyframeProperty, keepingValueAt time: Double) {
        switch property {
        case .position: transform.position.removeAllKeyframes(keeping: time)
        case .scale: transform.scale.removeAllKeyframes(keeping: time)
        case .rotation: transform.rotation.removeAllKeyframes(keeping: time)
        case .opacity: transform.opacity.removeAllKeyframes(keeping: time)
        case .crop: crop.removeAllKeyframes(keeping: time)
        case .volume: audio.volume.removeAllKeyframes(keeping: time)
        }
    }

    mutating func removeKeyframe(_ mark: KeyframeMark) {
        if let effectID = mark.effectID, let index = effects.firstIndex(where: { $0.id == effectID }) {
            let held = effects[index].intensity.value(at: mark.time)
            effects[index].intensity.removeKeyframe(id: mark.id)
            if !effects[index].intensity.isAnimated { effects[index].intensity.base = held }
            return
        }
        guard let property = mark.property else { return }
        func remove<V>(_ value: inout KeyframedValue<V>) {
            let held = value.value(at: mark.time)
            value.removeKeyframe(id: mark.id)
            if !value.isAnimated { value.base = held }
        }
        switch property {
        case .position: remove(&transform.position)
        case .scale: remove(&transform.scale)
        case .rotation: remove(&transform.rotation)
        case .opacity: remove(&transform.opacity)
        case .crop: remove(&crop)
        case .volume: remove(&audio.volume)
        }
    }

    mutating func moveKeyframe(_ mark: KeyframeMark, to time: Double) {
        let t = max(0, min(time, duration.seconds))
        if let effectID = mark.effectID, let index = effects.firstIndex(where: { $0.id == effectID }) {
            effects[index].intensity.moveKeyframe(id: mark.id, to: t)
            return
        }
        guard let property = mark.property else { return }
        switch property {
        case .position: transform.position.moveKeyframe(id: mark.id, to: t)
        case .scale: transform.scale.moveKeyframe(id: mark.id, to: t)
        case .rotation: transform.rotation.moveKeyframe(id: mark.id, to: t)
        case .opacity: transform.opacity.moveKeyframe(id: mark.id, to: t)
        case .crop: crop.moveKeyframe(id: mark.id, to: t)
        case .volume: audio.volume.moveKeyframe(id: mark.id, to: t)
        }
    }

    mutating func setEasing(_ mark: KeyframeMark, _ easing: Easing) {
        if let effectID = mark.effectID, let index = effects.firstIndex(where: { $0.id == effectID }) {
            effects[index].intensity.setEasing(id: mark.id, easing)
            return
        }
        guard let property = mark.property else { return }
        switch property {
        case .position: transform.position.setEasing(id: mark.id, easing)
        case .scale: transform.scale.setEasing(id: mark.id, easing)
        case .rotation: transform.rotation.setEasing(id: mark.id, easing)
        case .opacity: transform.opacity.setEasing(id: mark.id, easing)
        case .crop: crop.setEasing(id: mark.id, easing)
        case .volume: audio.volume.setEasing(id: mark.id, easing)
        }
    }

    // MARK: Structural helpers used by TimelineEngine

    /// Copies of this clip whose keyframes are split at clip-local `t` (timing untouched).
    func splitKeyframes(at t: Double) -> (Clip, Clip) {
        var left = self
        var right = self
        let position = transform.position.split(at: t)
        left.transform.position = position.left
        right.transform.position = position.right
        let scale = transform.scale.split(at: t)
        left.transform.scale = scale.left
        right.transform.scale = scale.right
        let rotation = transform.rotation.split(at: t)
        left.transform.rotation = rotation.left
        right.transform.rotation = rotation.right
        let opacity = transform.opacity.split(at: t)
        left.transform.opacity = opacity.left
        right.transform.opacity = opacity.right
        let cropParts = crop.split(at: t)
        left.crop = cropParts.left
        right.crop = cropParts.right
        let volume = audio.volume.split(at: t)
        left.audio.volume = volume.left
        right.audio.volume = volume.right
        for index in effects.indices {
            let parts = effects[index].intensity.split(at: t)
            left.effects[index].intensity = parts.left
            right.effects[index].intensity = parts.right
        }
        if let centerTrack = mask?.centerTrack {
            let parts = centerTrack.split(at: t)
            left.mask?.centerTrack = parts.left
            right.mask?.centerTrack = parts.right
        }
        if let sizeTrack = mask?.sizeTrack {
            let parts = sizeTrack.split(at: t)
            left.mask?.sizeTrack = parts.left
            right.mask?.sizeTrack = parts.right
        }
        if case .text(let content) = source, let caption = content.caption {
            var leftCaption = caption
            var rightCaption = caption
            leftCaption.words = caption.words.filter { $0.start < t }.map { word in
                var copy = word
                copy.end = min(word.end, t)
                return copy
            }
            rightCaption.words = caption.words.filter { $0.end > t }.map { word in
                var copy = word
                copy.start = max(0, word.start - t)
                copy.end = max(copy.start, word.end - t)
                return copy
            }
            if !rightCaption.words.isEmpty { rightCaption.words[0].breaksLine = false }
            var leftContent = content
            leftContent.caption = leftCaption
            leftContent.text = leftCaption.composedText
            var rightContent = content
            rightContent.caption = rightCaption
            rightContent.text = rightCaption.composedText
            left.source = .text(leftContent)
            right.source = .text(rightContent)
        }
        return (left, right)
    }

    /// Joins `other`'s keyframes after this clip's (used when joining split clips).
    func joiningKeyframes(with other: Clip, offset: Double) -> Clip {
        var result = self
        result.transform.position = transform.position.joined(with: other.transform.position, offset: offset)
        result.transform.scale = transform.scale.joined(with: other.transform.scale, offset: offset)
        result.transform.rotation = transform.rotation.joined(with: other.transform.rotation, offset: offset)
        result.transform.opacity = transform.opacity.joined(with: other.transform.opacity, offset: offset)
        result.crop = crop.joined(with: other.crop, offset: offset)
        result.audio.volume = audio.volume.joined(with: other.audio.volume, offset: offset)
        for index in result.effects.indices {
            if let match = other.effects.first(where: { $0.kind == result.effects[index].kind }) {
                result.effects[index].intensity = result.effects[index].intensity.joined(with: match.intensity, offset: offset)
            }
        }
        if let center = mask?.centerTrack, let otherCenter = other.mask?.centerTrack {
            result.mask?.centerTrack = center.joined(with: otherCenter, offset: offset)
        }
        if let size = mask?.sizeTrack, let otherSize = other.mask?.sizeTrack {
            result.mask?.sizeTrack = size.joined(with: otherSize, offset: offset)
        }
        if case .text(var content) = source, let caption = content.caption,
           case .text(let otherContent) = other.source, let otherCaption = otherContent.caption {
            var merged = caption
            merged.words += otherCaption.words.map { word in
                var copy = word
                copy.start += offset
                copy.end += offset
                return copy
            }
            content.caption = merged
            content.text = merged.composedText
            result.source = .text(content)
        }
        return result
    }

    mutating func remapKeyframeTimes(_ transform: (Double) -> Double) {
        self.transform.position.remapTimes(transform)
        self.transform.scale.remapTimes(transform)
        self.transform.rotation.remapTimes(transform)
        self.transform.opacity.remapTimes(transform)
        crop.remapTimes(transform)
        audio.volume.remapTimes(transform)
        for index in effects.indices { effects[index].intensity.remapTimes(transform) }
        mask?.centerTrack?.remapTimes(transform)
        mask?.sizeTrack?.remapTimes(transform)
        if case .text(var content) = source, var caption = content.caption {
            for index in caption.words.indices {
                caption.words[index].start = transform(caption.words[index].start)
                caption.words[index].end = transform(caption.words[index].end)
            }
            content.caption = caption
            source = .text(content)
        }
    }

    /// Freezes every animated value at `t` (used for freeze frames).
    func flattenedAnimation(at t: Double) -> Clip {
        var result = self
        result.transform.position = KeyframedValue(transform.position.value(at: t))
        result.transform.scale = KeyframedValue(transform.scale.value(at: t))
        result.transform.rotation = KeyframedValue(transform.rotation.value(at: t))
        result.transform.opacity = KeyframedValue(transform.opacity.value(at: t))
        result.crop = KeyframedValue(crop.value(at: t))
        result.audio.volume = KeyframedValue(audio.volume.value(at: t))
        for index in result.effects.indices {
            result.effects[index].intensity = KeyframedValue(effects[index].intensity.value(at: t))
        }
        if let mask {
            result.mask = mask.resolved(at: t)
            result.mask?.centerTrack = nil
            result.mask?.sizeTrack = nil
        }
        return result
    }
}
